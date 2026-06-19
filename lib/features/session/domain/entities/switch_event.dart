import 'package:equatable/equatable.dart';

class SwitchEvent extends Equatable {
  final DateTime timestamp;
  final String peerId;

  const SwitchEvent({required this.timestamp, required this.peerId});

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'peerId': peerId,
      };

  factory SwitchEvent.fromJson(Map<String, dynamic> map) => SwitchEvent(
        timestamp: DateTime.parse(map['timestamp'] as String),
        peerId: map['peerId'] as String,
      );

  @override
  List<Object?> get props => [timestamp, peerId];
}
