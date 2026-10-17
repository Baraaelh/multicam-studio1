package com.multicamstudio.multicam_studio

/**
 * What a recorder observed during a take, returned to Dart when recording
 * stops. A 0-byte file always means the muxer never started; these fields say
 * why (no frames arrived, the encoder never produced output, audio failed…),
 * so the cause shows up in the app on any device without adb.
 */
interface RecorderDiagnostics {
    val diagnostics: Map<String, Any?>
}
