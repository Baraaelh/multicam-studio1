import 'package:equatable/equatable.dart';

class SwitchEvent extends Equatable {
  final DateTime timestamp;
  final String peerId;

  const SwitchEvent({required this.timestamp, required this.peerId});

  @override
  List<Object?> get props => [timestamp, peerId];
}
