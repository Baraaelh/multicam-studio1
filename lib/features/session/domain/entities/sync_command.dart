import 'package:equatable/equatable.dart';

enum CommandType {
  startRecording,
  stopRecording;

  static CommandType fromString(String s) =>
      CommandType.values.firstWhere((e) => e.name == s);
}

class SyncCommand extends Equatable {
  final String id;
  final CommandType type;
  final DateTime issuedAt; // server time
  final int bufferMs;      // ms after issuedAt before execution

  const SyncCommand({
    required this.id,
    required this.type,
    required this.issuedAt,
    required this.bufferMs,
  });

  /// Target execution time in server clock coordinates.
  DateTime get executeAtServer => issuedAt.add(Duration(milliseconds: bufferMs));

  @override
  List<Object?> get props => [id, type, issuedAt, bufferMs];
}
