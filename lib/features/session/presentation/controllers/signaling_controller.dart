import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:get/get.dart';

import '../../../../core/services/webrtc_service.dart';
import '../../domain/entities/ice_candidate_entity.dart';
import '../../domain/entities/peer_connection_state.dart';
import '../../domain/entities/sdp_info.dart';
import '../../domain/usecases/clear_signaling.dart';
import '../../domain/usecases/publish_answer.dart';
import '../../domain/usecases/publish_ice_candidate.dart';
import '../../domain/usecases/publish_offer.dart';
import '../../domain/usecases/watch_answer.dart';
import '../../domain/usecases/watch_ice_candidates.dart';
import '../../domain/usecases/watch_offer.dart';

class _PeerMeta {
  final String sessionId;
  final bool isAdmin;
  _PeerMeta({required this.sessionId, required this.isAdmin});
}

class SignalingController extends GetxController {
  final WebRtcService _webRtcService;
  final PublishOffer _publishOffer;
  final PublishAnswer _publishAnswer;
  final WatchOffer _watchOffer;
  final WatchAnswer _watchAnswer;
  final PublishIceCandidate _publishIceCandidate;
  final WatchIceCandidates _watchIceCandidates;
  final ClearSignaling _clearSignaling;

  SignalingController({
    required WebRtcService webRtcService,
    required PublishOffer publishOffer,
    required PublishAnswer publishAnswer,
    required WatchOffer watchOffer,
    required WatchAnswer watchAnswer,
    required PublishIceCandidate publishIceCandidate,
    required WatchIceCandidates watchIceCandidates,
    required ClearSignaling clearSignaling,
  })  : _webRtcService = webRtcService,
        _publishOffer = publishOffer,
        _publishAnswer = publishAnswer,
        _watchOffer = watchOffer,
        _watchAnswer = watchAnswer,
        _publishIceCandidate = publishIceCandidate,
        _watchIceCandidates = watchIceCandidates,
        _clearSignaling = clearSignaling;

  // --- Observable state ---
  final peers = <String, PeerConnectionState>{}.obs;
  final activePeerId = Rx<String?>(null);

  // --- Internal tracking ---
  final _peerMeta = <String, _PeerMeta>{};

  // ICE candidates buffered per peer until remote description is set.
  final _pendingCandidates = <String, List<IceCandidateEntity>>{};
  final _remoteDescSet = <String, bool>{};

  // Subscriptions: keyed by peerId → list of active stream subs.
  final _peerSubs = <String, List<StreamSubscription>>{};
  StreamSubscription? _iceSub;
  StreamSubscription? _connStateSub;

  @override
  void onInit() {
    super.onInit();
    _listenToWebRtcService();
  }

  void _listenToWebRtcService() {
    _iceSub = _webRtcService.iceCandidateStream.listen(_onLocalIceCandidate);
    _connStateSub =
        _webRtcService.connectionStateStream.listen(_onConnectionStateChange);
  }

  // ---------------------------------------------------------------------------
  // ADMIN: initiate WebRTC P2P connection to a camera device.
  // Call this after the camera device has joined the session.
  // ---------------------------------------------------------------------------
  Future<void> connectToCamera(
    String sessionId,
    String peerId,
    String deviceName,
  ) async {
    _updateStatus(peerId, deviceName, PeerStatus.connecting);
    // Register meta before createOffer so ICE candidates can be published
    // as soon as setLocalDescription triggers ICE gathering.
    _peerMeta[peerId] = _PeerMeta(sessionId: sessionId, isAdmin: true);
    _remoteDescSet[peerId] = false;

    final offer = await _webRtcService.createOffer(peerId);

    final result = await _publishOffer(PublishOfferParams(
      sessionId: sessionId,
      peerId: peerId,
      sdp: offer.sdp!,
      type: offer.type!,
    ));

    if (result.isFailure) {
      _updateStatus(peerId, deviceName, PeerStatus.failed);
      return;
    }

    final answerSub = _watchAnswer(WatchAnswerParams(
      sessionId: sessionId,
      peerId: peerId,
    )).listen(
      (answer) => _onRemoteAnswer(peerId, answer),
      onError: (_) => _updateStatus(peerId, deviceName, PeerStatus.failed),
    );

    final iceSub = _watchIceCandidates(WatchIceCandidatesParams(
      sessionId: sessionId,
      peerId: peerId,
      fromAdmin: false, // watching camera → admin direction
    )).listen(
      (candidate) => _onRemoteIceCandidate(peerId, candidate),
      onError: (_) {}, // non-fatal: tolerate individual ICE failures
    );

    _peerSubs[peerId] = [answerSub, iceSub];
  }

  // ---------------------------------------------------------------------------
  // CAMERA: join session and await Admin's offer.
  // ---------------------------------------------------------------------------
  Future<void> joinSession(
    String sessionId,
    String peerId,
    String deviceName,
  ) async {
    _updateStatus(peerId, deviceName, PeerStatus.connecting);
    _peerMeta[peerId] = _PeerMeta(sessionId: sessionId, isAdmin: false);
    _remoteDescSet[peerId] = false;

    final offerSub = _watchOffer(WatchOfferParams(
      sessionId: sessionId,
      peerId: peerId,
    )).listen(
      (offer) => _onRemoteOffer(sessionId, peerId, deviceName, offer),
      onError: (_) => _updateStatus(peerId, deviceName, PeerStatus.failed),
    );

    final iceSub = _watchIceCandidates(WatchIceCandidatesParams(
      sessionId: sessionId,
      peerId: peerId,
      fromAdmin: true, // watching admin → camera direction
    )).listen(
      (candidate) => _onRemoteIceCandidate(peerId, candidate),
      onError: (_) {},
    );

    _peerSubs[peerId] = [offerSub, iceSub];
  }

  // ---------------------------------------------------------------------------
  // ADMIN: switch active camera (P2P renderer switching — no renegotiation).
  // ---------------------------------------------------------------------------
  void switchActiveCamera(String peerId) {
    if (!peers.containsKey(peerId)) return;
    activePeerId.value = peerId;
    peers.updateAll(
      (id, state) => state.copyWith(isActiveCamera: id == peerId),
    );
  }

  // ---------------------------------------------------------------------------
  // Both sides: tear down a peer connection and clean Firestore signaling data.
  // ---------------------------------------------------------------------------
  Future<void> disconnect(String sessionId, String peerId) async {
    _cancelPeerSubs(peerId);
    _peerMeta.remove(peerId);
    _pendingCandidates.remove(peerId);
    _remoteDescSet.remove(peerId);

    await _webRtcService.closeConnection(peerId);
    await _clearSignaling(ClearSignalingParams(
      sessionId: sessionId,
      peerId: peerId,
    ));

    peers.remove(peerId);
    if (activePeerId.value == peerId) activePeerId.value = null;
  }

  // ---------------------------------------------------------------------------
  // Internal handlers
  // ---------------------------------------------------------------------------

  // Camera side: received admin's offer → create and publish answer.
  Future<void> _onRemoteOffer(
    String sessionId,
    String peerId,
    String deviceName,
    SdpInfo offer,
  ) async {
    final answer = await _webRtcService.createAnswer(
      peerId,
      webrtc.RTCSessionDescription(offer.sdp, offer.type.name),
    );

    _remoteDescSet[peerId] = true;
    await _drainPendingCandidates(peerId);

    final result = await _publishAnswer(PublishAnswerParams(
      sessionId: sessionId,
      peerId: peerId,
      sdp: answer.sdp!,
      type: answer.type!,
    ));

    if (result.isFailure) {
      _updateStatus(peerId, deviceName, PeerStatus.failed);
    }
  }

  // Admin side: received camera's answer → set remote description.
  Future<void> _onRemoteAnswer(String peerId, SdpInfo answer) async {
    await _webRtcService.setRemoteDescription(
      peerId,
      webrtc.RTCSessionDescription(answer.sdp, answer.type.name),
    );
    _remoteDescSet[peerId] = true;
    await _drainPendingCandidates(peerId);
  }

  // Both sides: received a remote ICE candidate from Firestore.
  Future<void> _onRemoteIceCandidate(
    String peerId,
    IceCandidateEntity candidate,
  ) async {
    if (_remoteDescSet[peerId] != true) {
      // Buffer until setRemoteDescription completes.
      _pendingCandidates.putIfAbsent(peerId, () => []).add(candidate);
      return;
    }
    await _applyCandidate(peerId, candidate);
  }

  Future<void> _drainPendingCandidates(String peerId) async {
    final pending = _pendingCandidates.remove(peerId) ?? [];
    for (final c in pending) {
      await _applyCandidate(peerId, c);
    }
  }

  Future<void> _applyCandidate(String peerId, IceCandidateEntity c) =>
      _webRtcService.addIceCandidate(
        peerId,
        webrtc.RTCIceCandidate(c.candidate, c.sdpMid, c.sdpMLineIndex),
      );

  // WebRtcService emitted a local ICE candidate → publish to Firestore.
  Future<void> _onLocalIceCandidate(IceCandidateEvent event) async {
    final meta = _peerMeta[event.peerId];
    if (meta == null || event.candidate.candidate == null) return;

    await _publishIceCandidate(PublishIceCandidateParams(
      sessionId: meta.sessionId,
      peerId: event.peerId,
      candidate: IceCandidateEntity(
        peerId: event.peerId,
        candidate: event.candidate.candidate!,
        sdpMid: event.candidate.sdpMid ?? '',
        sdpMLineIndex: event.candidate.sdpMLineIndex ?? 0,
      ),
      isAdmin: meta.isAdmin,
    ));
  }

  void _onConnectionStateChange(ConnectionStateEvent event) {
    final current = peers[event.peerId];
    if (current == null) return;
    peers[event.peerId] = current.copyWith(
      status: switch (event.state) {
        webrtc.RTCPeerConnectionState.RTCPeerConnectionStateConnected =>
          PeerStatus.connected,
        webrtc.RTCPeerConnectionState.RTCPeerConnectionStateConnecting =>
          PeerStatus.connecting,
        webrtc.RTCPeerConnectionState.RTCPeerConnectionStateDisconnected =>
          PeerStatus.disconnected,
        webrtc.RTCPeerConnectionState.RTCPeerConnectionStateFailed =>
          PeerStatus.failed,
        _ => current.status,
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void _updateStatus(String peerId, String deviceName, PeerStatus status) {
    peers[peerId] = peers[peerId]?.copyWith(status: status) ??
        PeerConnectionState(
          peerId: peerId,
          deviceName: deviceName,
          status: status,
        );
  }

  void _cancelPeerSubs(String peerId) {
    final subs = _peerSubs.remove(peerId) ?? [];
    for (final sub in subs) {
      sub.cancel();
    }
  }

  @override
  void onClose() {
    _iceSub?.cancel();
    _connStateSub?.cancel();
    for (final peerId in List.of(_peerSubs.keys)) {
      _cancelPeerSubs(peerId);
    }
    super.onClose();
  }
}
