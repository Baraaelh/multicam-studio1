abstract final class FirestoreConstants {
  // Collections
  static const String sessions = 'sessions';
  static const String peers = 'peers';
  static const String adminCandidates = 'admin_candidates';
  static const String cameraCandidates = 'camera_candidates';

  // Session document fields
  static const String status = 'status';
  static const String adminId = 'adminId';
  static const String createdAt = 'createdAt';

  // Peer document fields
  static const String offer = 'offer';
  static const String answer = 'answer';
  static const String deviceName = 'deviceName';
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

  // Recording subcollection + fields
  static const String recordings = 'recordings';
  static const String peerId = 'peerId';
  static const String recordingFilename = 'filename';
  static const String localIp = 'localIp';
  static const String recordingPort = 'port';
  static const String sizeBytes = 'sizeBytes';
  static const String recordedAt = 'recordedAt';
}
