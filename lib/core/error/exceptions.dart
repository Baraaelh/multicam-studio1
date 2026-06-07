class AppException implements Exception {
  final String message;
  const AppException(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

class FirestoreException extends AppException {
  const FirestoreException(super.message);
}

class WebRtcException extends AppException {
  const WebRtcException(super.message);
}

class SignalingException extends AppException {
  const SignalingException(super.message);
}

class CameraException extends AppException {
  const CameraException(super.message);
}

class PermissionDeniedException extends AppException {
  const PermissionDeniedException(super.message);
}
