import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:multicam_studio/core/services/clock_sync_service.dart';
import 'package:multicam_studio/core/services/ffmpeg_service.dart';
import 'package:multicam_studio/core/services/webrtc_service.dart';
import 'package:multicam_studio/features/admin/domain/entities/session.dart';
import 'package:multicam_studio/features/admin/domain/repositories/session_repository.dart';
import 'package:multicam_studio/features/admin/domain/usecases/create_session.dart';
import 'package:multicam_studio/features/admin/domain/usecases/end_session.dart';
import 'package:multicam_studio/features/admin/domain/usecases/watch_device_name.dart';
import 'package:multicam_studio/features/admin/presentation/controllers/admin_controller.dart';
import 'package:multicam_studio/features/admin/presentation/services/render_service.dart';
import 'package:multicam_studio/features/session/domain/entities/peer_connection_state.dart';
import 'package:multicam_studio/features/session/domain/entities/peer_info.dart';
import 'package:multicam_studio/features/session/domain/usecases/publish_command.dart';
import 'package:multicam_studio/features/session/domain/usecases/sync_clock.dart';
import 'package:multicam_studio/features/session/domain/usecases/watch_commands.dart';
import 'package:multicam_studio/features/session/domain/usecases/watch_peers.dart';
import 'package:multicam_studio/features/session/domain/usecases/watch_recordings.dart';
import 'package:multicam_studio/features/session/presentation/controllers/clock_controller.dart';
import 'package:multicam_studio/features/session/presentation/controllers/signaling_controller.dart';

class _Fake {
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

class _FCreate extends _Fake implements CreateSession {}
class _FEnd extends _Fake implements EndSession {}
class _FRec extends _Fake implements WatchRecordings {}
class _FPeers extends _Fake implements WatchPeers {}
class _FRepo extends _Fake implements SessionRepository {}
class _FSync extends _Fake implements SyncClock {}
class _FPub extends _Fake implements PublishCommand {}
class _FWatch extends _Fake implements WatchCommands {}
class _FCss extends _Fake implements ClockSyncService {}
class _FFfmpeg extends _Fake implements FfmpegService {}

class _FRtc extends _Fake implements WebRtcService {
  @override
  Stream<RemoteStreamEvent> get remoteStreamStream => const Stream.empty();
}

class _FName extends _Fake implements WatchDeviceName {
  @override
  Stream<String?> call(WatchDeviceNameParams params) => const Stream.empty();
}

class _FSignaling extends _Fake implements SignalingController {
  final connected = <String>[];
  final disconnected = <String>[];

  @override
  final peers = <String, PeerConnectionState>{}.obs;

  @override
  Future<void> connectToCamera(String sessionId, String peerId, String deviceName) async =>
      connected.add(peerId);

  @override
  Future<void> disconnect(String sessionId, String peerId) async => disconnected.add(peerId);

  @override
  void switchActiveCamera(String peerId) {}
}

class _Clock extends ClockController {
  _Clock()
      : super(
          syncClock: _FSync(),
          publishCommand: _FPub(),
          watchCommands: _FWatch(),
          clockSyncService: _FCss(),
        );
}

PeerInfo _peer(String peerId, String? uid, [String? name]) =>
    (peerId: peerId, uid: uid, deviceName: name, capabilities: const []);

void main() {
  late _FSignaling signaling;
  late AdminController admin;

  setUp(() {
    Get.put(RenderService(ffmpegService: _FFfmpeg()));
    signaling = _FSignaling();
    admin = Get.put(AdminController(
      createSession: _FCreate(),
      endSession: _FEnd(),
      webRtcService: _FRtc(),
      signalingController: signaling,
      watchDeviceName: _FName(),
      clockController: _Clock(),
      watchRecordings: _FRec(),
      watchPeers: _FPeers(),
      sessionRepository: _FRepo(),
    ));
    admin.session.value =
        Session(sessionId: 's1', adminId: admin.adminId, status: SessionStatus.live);
  });

  tearDown(Get.reset);

  test('new cameras get a slot each', () {
    admin.onPeerListChanged([_peer('a', 'u1', 'Pixel 7'), _peer('b', 'u2')]);

    expect(admin.slots.map((s) => s.peerId), ['a', 'b']);
    expect(admin.slots.first.label, 'Pixel 7');
    expect(signaling.connected, ['a', 'b']);
  });

  test('a phone that rejoins takes back its slot and settings', () {
    admin.onPeerListChanged([_peer('a', 'u1', 'Pixel 7'), _peer('b', 'u2')]);
    admin.switchActiveCamera('a');
    admin.masterAudioCameraId.value = 'a';
    admin.mutedCameras['a'] = true;

    // Same account (u1), new peerId; the old peer doc is still listed.
    admin.onPeerListChanged([
      _peer('a', 'u1', 'Pixel 7'),
      _peer('b', 'u2'),
      _peer('c', 'u1', 'Pixel 7'),
    ]);

    expect(admin.slots.map((s) => s.peerId), ['c', 'b']);
    expect(admin.slots.first.label, 'Pixel 7');
    expect(signaling.disconnected, ['a']);
    expect(signaling.connected, ['a', 'b', 'c']);
    expect(admin.activePeerId.value, 'c');
    expect(admin.masterAudioCameraId.value, 'c');
    expect(admin.mutedCameras.containsKey('a'), isFalse);
  });

  test('the replaced peer never gets a slot again', () {
    final list = [_peer('a', 'u1'), _peer('c', 'u1')];
    admin.onPeerListChanged([_peer('a', 'u1')]);
    admin.onPeerListChanged(list);
    admin.onPeerListChanged(list);

    expect(admin.slots.map((s) => s.peerId), ['c']);
    expect(signaling.connected, ['a', 'c']);
  });

  test('different phones, or ones without an account, are new cameras', () {
    admin.onPeerListChanged([_peer('a', 'u1'), _peer('b', null)]);
    admin.onPeerListChanged([_peer('a', 'u1'), _peer('b', null), _peer('c', 'u3'), _peer('d', null)]);

    expect(admin.slots.map((s) => s.peerId), ['a', 'b', 'c', 'd']);
    expect(signaling.disconnected, isEmpty);
  });
}
