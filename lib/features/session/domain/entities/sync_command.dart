import 'package:equatable/equatable.dart';

enum CommandType {
  startRecording,
  stopRecording,
  muteCamera,
  unmuteCamera,
  setZoom;

  static CommandType? tryFromString(String s) =>
      CommandType.values.cast<CommandType?>().firstWhere(
            (e) => e?.name == s,
            orElse: () => null,
          );
}

class SyncCommand extends Equatable {
  final String id;
  final CommandType type;
  final DateTime issuedAt;
  final int bufferMs;
  /// Null means the command targets all cameras; non-null targets one camera.
  final String? targetPeerId;
  /// Type-specific extra data (e.g. `{'zoom': 2.0}` for setZoom).
  final Map<String, dynamic>? payload;

  const SyncCommand({
    required this.id,
    required this.type,
    required this.issuedAt,
    required this.bufferMs,
    this.targetPeerId,
    this.payload,
  });

  DateTime get executeAtServer => issuedAt.add(Duration(milliseconds: bufferMs));

  @override
  List<Object?> get props => [id, type, issuedAt, bufferMs, targetPeerId];
}
