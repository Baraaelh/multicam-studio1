sealed class AppFailure {
  final String message;
  const AppFailure(this.message);
}

final class FirestoreFailure extends AppFailure {
  const FirestoreFailure(super.message);
}

final class WebRtcFailure extends AppFailure {
  const WebRtcFailure(super.message);
}

final class SignalingFailure extends AppFailure {
  const SignalingFailure(super.message);
}

final class CameraFailure extends AppFailure {
  const CameraFailure(super.message);
}
