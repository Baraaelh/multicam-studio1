abstract final class FirestoreConstants {
  // Collections
  static const String sessions = 'sessions';
  static const String sessionCodes = 'session_codes';
  static const String peers = 'peers';
  static const String adminCandidates = 'admin_candidates';
  static const String cameraCandidates = 'camera_candidates';

  // Session document fields
  static const String status = 'status';
  static const String adminId = 'adminId';
  // Firebase Auth UID of the admin device; the security rules check it.
  static const String adminUid = 'adminUid';
  static const String code = 'code';
  static const String createdAt = 'createdAt';
  static const String expiresAt = 'expiresAt';

  // Peer document fields
  static const String offer = 'offer';
  static const String answer = 'answer';
  static const String deviceName = 'deviceName';
  // Firebase Auth UID of the camera device that owns the peer document.
  static const String peerUid = 'uid';
  static const String joinedAt = 'joinedAt';

  // SDP fields (nested under offer/answer)
  static const String sdp = 'sdp';
  static const String type = 'type';

  // ICE candidate fields
  static const String candidate = 'candidate';
  static const String sdpMid = 'sdpMid';
  static const String sdpMLineIndex = 'sdpMLineIndex';

  // Timed commands subcollection + fields
  static const String commands = 'commands';
  static const String commandType = 'type';
  static const String issuedAt = 'issuedAt';
  static const String bufferMs = 'bufferMs';
  static const String executeAtMs = 'executeAtMs';

  // Recording subcollection + fields
  static const String recordings = 'recordings';
  static const String peerId = 'peerId';
  static const String recordingFilename = 'filename';
  static const String localIp = 'localIp';
  static const String recordingPort = 'port';
  static const String sizeBytes = 'sizeBytes';
  static const String recordedAt = 'recordedAt';
  static const String recordingFailure = 'failure';

  // Recording capabilities field on peer document
  static const String capabilities = 'capabilities';

  // Timeline subcollection + fields
  static const String timeline = 'timeline';
  static const String timelineTimestamp = 'timestamp';
  static const String timelinePeerId = 'peerId';
}
