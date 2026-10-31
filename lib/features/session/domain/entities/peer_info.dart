import 'recording_profile.dart';

/// A camera's entry in the session's peer list. [uid] is the Firebase account
/// the camera signed in with; it stays the same when that phone rejoins.
typedef PeerInfo = ({
  String peerId,
  String? uid,
  String? deviceName,
  List<RecordingProfile> capabilities,
});
