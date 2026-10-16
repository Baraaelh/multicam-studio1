# Multicam Studio

Multi-camera live production system for Android — LAN WebRTC, Firebase control plane, Active Stream Switching, and timeline-based video merging.

## Overview

Multicam Studio lets you run a live multi-camera production using Android phones as cameras and a director (admin) device:

- **Admin device** creates a session, generates a 6-digit code, and controls the live production.
- **Camera devices** join via the session code, stream video over LAN WebRTC, and record locally.
- **Active Stream Switching** lets the admin cut between cameras instantly without renegotiation.
- **Timeline-based rendering** merges all camera recordings into a single video following the admin's switching history.

## Features

- 📱 **Multi-camera live production** — up to 8 cameras
- 🔗 **LAN WebRTC** — no internet required, low latency
- ⏱️ **Clock-synchronized commands** — all cameras start/stop recording simultaneously
- 🎬 **Active Stream Switching** — instant camera cuts
- 🎥 **Local recording** — native I420VideoRecorder (no EGL dependency)
- 📡 **LAN file transfer** — recordings auto-download to the admin device
- 🎞️ **Timeline-based merge** — FFmpeg merges recordings following the switch history
- 🎙️ **Studio Audio Mode** — admin mic replaces all camera audio in the render
- 👥 **Co-Admin support** — promote a camera to switch cameras remotely
- 📊 **Session analyzer** — estimates bitrate and storage requirements

## Architecture

The project follows **Clean Architecture** with three layers:

```
lib/
├── core/          # Shared services, DI, error handling, constants
├── features/
│   ├── admin/     # Director side — session management, live view, rendering
│   ├── camera/    # Camera side — capture, local recording, LAN transfer
│   └── session/   # Shared — signaling, clock sync, commands, recordings
└── main.dart      # App entry point
```

### Key Components

| Component | Description |
|---|---|
| `WebRtcService` | Manages P2P connections between admin and cameras |
| `SignalingController` | Handles SDP offer/answer and ICE candidate exchange via Firestore |
| `ClockSyncService` | Measures clock offset between device and Firebase server |
| `ClockController` | Schedules timed commands across all cameras |
| `RecordingService` | Records local camera stream via native I420VideoRecorder |
| `TransferServer` | Serves recorded files over LAN HTTP |
| `RenderService` | Merges recordings into a single video using FFmpeg |

## Getting Started

### Prerequisites

- Flutter SDK ^3.11.5
- Android device(s) with camera and microphone
- Firebase project with Firestore enabled

### Setup

1. Clone the repository
2. Run `flutter pub get`
3. Configure Firebase:
   - Update `lib/firebase_options.dart` with your Firebase project credentials
   - Enable Firestore in your Firebase console
4. Run on Android devices: `flutter run`

### Usage

1. **Admin**: Open the app → tap **Admin Mode** → **Create Session** → share the 6-digit code
2. **Cameras**: Open the app → tap **Camera Mode** → enter the session code → grant permissions
3. **Admin**: Tap **Go Live** → cameras appear in the preview strip
4. **Record**: Tap **START REC** → select quality → cameras start recording simultaneously
5. **Stop**: Tap **STOP REC** → recordings auto-download to the admin device
6. **Render**: Tap **Recordings** → **Render to Video** → merged video is created

## Security Notes

- The 6-digit session code acts as the access key for cameras
- The admin ID is verified before sending commands
- Firestore security rules should restrict access to session data
- Session codes expire after 24 hours and are freed when a session ends

## Data Cleanup

- Ending a session deletes all of its Firestore data (peers, ICE candidates, commands, recordings, timeline, and the session itself)
- Every document also carries an `expiresAt` field (7 days), which deletes data of sessions that were never ended. This needs Firestore TTL policies, enabled once per project:

  ```bash
  tool/enable_firestore_ttl.sh multicam-studio
  ```

- The admin needs **delete** permission on these collections in the Firestore security rules

## Testing

```bash
flutter test
```

## License

Private project — all rights reserved.