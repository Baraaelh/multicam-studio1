/// Contents of the join QR the admin shows: a prefix, so the camera can tell
/// it apart from unrelated codes, then the 6-digit session code.
const _joinQrPrefix = 'MULTICAM:';

String joinQrData(String sessionCode) => '$_joinQrPrefix$sessionCode';

/// The session code in a scanned QR, or null when it isn't a join QR. A bare
/// 6-digit code is accepted too, e.g. a QR someone made from the shared code.
String? sessionCodeFromQr(String raw) =>
    RegExp(r'^(?:MULTICAM:)?(\d{6})$').firstMatch(raw.trim())?.group(1);
