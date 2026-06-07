import 'package:equatable/equatable.dart';

enum CameraStatus { idle, requestingPermission, starting, active, switchingLens, error }

enum LensDirection { front, back }

class LocalCameraState extends Equatable {
  final CameraStatus status;
  final LensDirection lens;
  final String? errorMessage;

  const LocalCameraState({
    required this.status,
    this.lens = LensDirection.back,
    this.errorMessage,
  });

  LocalCameraState copyWith({
    CameraStatus? status,
    LensDirection? lens,
    String? errorMessage,
  }) =>
      LocalCameraState(
        status: status ?? this.status,
        lens: lens ?? this.lens,
        errorMessage: errorMessage ?? this.errorMessage,
      );

  @override
  List<Object?> get props => [status, lens, errorMessage];
}
