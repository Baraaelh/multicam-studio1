import 'dart:convert';

import '../../../../core/error/failures.dart';
import '../../../../core/error/result.dart';
import '../../../../core/usecases/use_case.dart';
import '../entities/qr_payload.dart';

class ParseQrPayload implements UseCase<QrPayload, String> {
  const ParseQrPayload();

  @override
  Future<Result<QrPayload>> call(String rawValue) async {
    try {
      final map = jsonDecode(rawValue) as Map<String, dynamic>;
      final payload = QrPayload(
        sessionId: map['sessionId'] as String,
        peerId: map['peerId'] as String,
        adminId: map['adminId'] as String,
        label: (map['label'] as String?) ?? 'Camera',
        expiresAt: (map['expiresAt'] as num?)?.toInt() ?? 0,
        pin: (map['pin'] as String?) ?? '',
      );
      if (payload.expiresAt > 0 &&
          DateTime.now().isAfter(
            DateTime.fromMillisecondsSinceEpoch(payload.expiresAt),
          )) {
        return const Failure(
          SignalingFailure('QR code has expired. Ask the admin to regenerate.'),
        );
      }
      return Success(payload);
    } catch (_) {
      return const Failure(SignalingFailure('Invalid QR code format'));
    }
  }
}
