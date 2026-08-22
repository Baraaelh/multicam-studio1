import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../error/exceptions.dart';

typedef IceCandidateEvent = ({
  String peerId,
  webrtc.RTCIceCandidate candidate
});
typedef ConnectionStateEvent = ({
  String peerId,
  webrtc.RTCPeerConnectionState state
});
typedef RemoteStreamEvent = ({String peerId, webrtc.MediaStream stream});
typedef DataChannelMessageEvent = ({String peerId, String message});

class WebRtcService {
  // No STUN/TURN → LAN host candidates only; unified-plan required for addTrack API.
  static const Map<String, dynamic> _peerConfig = {
    'iceServers': [],
    'sdpSemantics': 'unified-plan',
  };

  final _connections = <String, webrtc.RTCPeerConnection>{};
  final _dataChannels = <String, webrtc.RTCDataChannel>{};

  final _iceCandidateCtrl =
      StreamController<IceCandidateEvent>.broadcast();
  final _connectionStateCtrl =
      StreamController<ConnectionStateEvent>.broadcast();
  final _remoteStreamCtrl =
      StreamController<RemoteStreamEvent>.broadcast();
  final _dataChannelMessageCtrl =
      StreamController<DataChannelMessageEvent>.broadcast();

  Stream<IceCandidateEvent> get iceCandidateStream =>
      _iceCandidateCtrl.stream;
  Stream<ConnectionStateEvent> get connectionStateStream =>
      _connectionStateCtrl.stream;
  Stream<RemoteStreamEvent> get remoteStreamStream =>
      _remoteStreamCtrl.stream;
  Stream<DataChannelMessageEvent> get dataChannelMessageStream =>
      _dataChannelMessageCtrl.stream;

  Future<webrtc.RTCPeerConnection> _getOrCreate(String peerId) async {
    if (_connections.containsKey(peerId)) return _connections[peerId]!;

    final pc = await webrtc.createPeerConnection(_peerConfig);

    pc.onIceCandidate = (c) {
      if (c.candidate != null && _isHostCandidate(c)) {
        _iceCandidateCtrl.add((peerId: peerId, candidate: c));
      }
    };

    pc.onConnectionState = (s) =>
        _connectionStateCtrl.add((peerId: peerId, state: s));

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        final stream = event.streams.first;
        // Disable all incoming audio tracks immediately — before the stream is
        // emitted to AdminController. The native WebRTC engine starts rendering
        // audio the moment onTrack fires, so any delay (Dart event loop +
        // MethodChannel round-trip) lets audio play through the speaker briefly,
        // which causes acoustic feedback in the room. AdminController re-enables
        // specific tracks explicitly via toggleLiveAudio.
        for (final track in stream.getAudioTracks()) {
          track.enabled = false;
        }
        _remoteStreamCtrl.add((peerId: peerId, stream: stream));
      }
    };

    // Camera (answerer) side: admin opens the data channel, camera receives it here.
    pc.onDataChannel = (dc) {
      _dataChannels[peerId] = dc;
      dc.onMessage = (msg) => _dataChannelMessageCtrl.add(
            (peerId: peerId, message: msg.text),
          );
    };

    _connections[peerId] = pc;
    return pc;
  }

  // Admin calls this to initiate the connection for a given camera peerId.
  Future<webrtc.RTCSessionDescription> createOffer(String peerId) async {
    final pc = await _getOrCreate(peerId);
    // Open the data channel before createOffer so it appears in the SDP.
    await _openDataChannel(peerId, pc);
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    return offer;
  }

  Future<void> _openDataChannel(
      String peerId, webrtc.RTCPeerConnection pc) async {
    final init = webrtc.RTCDataChannelInit()..ordered = true;
    final dc = await pc.createDataChannel('commands', init);
    _dataChannels[peerId] = dc;
    dc.onMessage = (msg) => _dataChannelMessageCtrl.add(
          (peerId: peerId, message: msg.text),
        );
  }

  /// Sends [message] to the named peer via the LAN data channel.
  /// Silently no-ops if the channel is not yet open (Firestore fallback handles it).
  Future<void> sendToDataChannel(String peerId, String message) async {
    final dc = _dataChannels[peerId];
    if (dc == null ||
        dc.state != webrtc.RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    await dc.send(webrtc.RTCDataChannelMessage(message));
  }

  // Camera calls this after receiving the admin's offer.
  Future<webrtc.RTCSessionDescription> createAnswer(
    String peerId,
    webrtc.RTCSessionDescription remoteOffer,
  ) async {
    final pc = await _getOrCreate(peerId);
    await pc.setRemoteDescription(remoteOffer);
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    return answer;
  }

  // Admin calls this after receiving the camera's answer from Firestore.
  Future<void> setRemoteDescription(
    String peerId,
    webrtc.RTCSessionDescription sdp,
  ) async {
    final pc = _connections[peerId] ??
        (throw WebRtcException('No PC for peerId: $peerId'));
    await pc.setRemoteDescription(sdp);
  }

  Future<void> addIceCandidate(
    String peerId,
    webrtc.RTCIceCandidate candidate,
  ) async {
    final pc = _connections[peerId] ??
        (throw WebRtcException('No PC for peerId: $peerId'));
    await pc.addCandidate(candidate);
  }

  // Step 3+: used by Camera to add its local video/audio tracks.
  Future<void> addTrack(
    String peerId,
    webrtc.MediaStreamTrack track,
    webrtc.MediaStream stream,
  ) async {
    final pc = _connections[peerId] ??
        (throw WebRtcException('No PC for peerId: $peerId'));
    await pc.addTrack(track, stream);
  }

  /// Camera side: pre-adds all tracks from [stream] to the PC before
  /// the signaling dance starts. Must be called before [createAnswer] so
  /// that the SDP answer contains the camera's audio/video m-lines.
  Future<void> prepareForIncomingCall(
    String peerId,
    webrtc.MediaStream stream,
  ) async {
    final pc = await _getOrCreate(peerId);
    for (final track in stream.getTracks()) {
      await pc.addTrack(track, stream);
    }
  }

  /// Replaces the outgoing video track on a live connection.
  /// Uses RTCRtpSender.replaceTrack which does not trigger SDP renegotiation
  /// under unified-plan — safe to call mid-stream for lens switching.
  Future<void> replaceVideoTrack(
    String peerId,
    webrtc.MediaStreamTrack newTrack,
  ) async {
    final pc = _connections[peerId] ??
        (throw WebRtcException('No PC for peerId: $peerId'));
    final senders = await pc.getSenders();
    final videoSender = senders
        .where((s) => s.track?.kind == 'video')
        .firstOrNull;
    if (videoSender == null) {
      throw WebRtcException('No video sender for peerId: $peerId');
    }
    await videoSender.replaceTrack(newTrack);
  }

  /// Sets the enabled state on the audio RTCRtpSender for a peer.
  /// More reliable than setting track.enabled on the MediaStream track because
  /// the sender's track reference stays valid even after replaceTrack (lens switch).
  Future<void> setAudioSenderEnabled(String peerId, bool enabled) async {
    final pc = _connections[peerId];
    if (pc == null) return;
    final senders = await pc.getSenders();
    for (final sender in senders) {
      if (sender.track?.kind == 'audio') {
        sender.track?.enabled = enabled;
      }
    }
  }

  Future<void> closeConnection(String peerId) async {
    _dataChannels.remove(peerId)?.close();
    final pc = _connections.remove(peerId);
    if (pc == null) return;
    await pc.close();
  }

  // Active Stream Switching is handled at the presentation layer by swapping
  // which RTCVideoRenderer is displayed. Remote receivers stay active on all
  // connections — this avoids renegotiation on every cut.
  bool hasConnection(String peerId) => _connections.containsKey(peerId);

  // Defensive host-only filter. Without STUN servers the stack will only
  // gather host candidates anyway, but we filter explicitly for clarity.
  bool _isHostCandidate(webrtc.RTCIceCandidate c) =>
      c.candidate?.contains('typ host') ?? false;

  Future<void> dispose() async {
    for (final dc in _dataChannels.values) {
      dc.close();
    }
    _dataChannels.clear();
    for (final pc in _connections.values) {
      await pc.close();
    }
    _connections.clear();
    await _iceCandidateCtrl.close();
    await _connectionStateCtrl.close();
    await _remoteStreamCtrl.close();
    await _dataChannelMessageCtrl.close();
  }
}
