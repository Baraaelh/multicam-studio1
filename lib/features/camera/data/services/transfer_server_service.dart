import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// Runs a minimal HTTP file server so the Admin device can download recordings
/// directly from this camera over LAN.
///
/// URL scheme: `http://[cameraIp]:8080/[filename]`
class TransferServer {
  static const int port = 8080;

  HttpServer? _server;
  final _files = <String, String>{}; // filename → absolute path

  bool get isRunning => _server != null;

  /// Starts the server (idempotent — safe to call if already running).
  Future<void> start() async {
    if (_server != null) return;
    _server = await shelf_io.serve(
      _handler,
      InternetAddress.anyIPv4,
      port,
      poweredByHeader: null,
    );
  }

  /// Registers a file to be served by [filename].
  void register(String filename, String absolutePath) {
    _files[filename] = absolutePath;
  }

  Future<Response> _handler(Request request) async {
    final filename = request.url.pathSegments.lastOrNull;
    if (filename == null || filename.isEmpty) {
      return Response.ok('Multicam Transfer Server\n');
    }
    final path = _files[filename];
    if (path == null) return Response.notFound('File not found\n');
    final file = File(path);
    if (!await file.exists()) return Response.notFound('File gone\n');
    final length = await file.length();
    return Response.ok(
      file.openRead(),
      headers: {
        HttpHeaders.contentTypeHeader: 'video/mp4',
        HttpHeaders.contentLengthHeader: length.toString(),
        'content-disposition': 'attachment; filename="$filename"',
      },
    );
  }

  /// Stops the server and clears registered files.
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _files.clear();
  }

  /// Returns the WiFi/Ethernet LAN IPv4 address of this device.
  ///
  /// Intentionally excludes rmnet (mobile data) — those IPs are not
  /// reachable from other devices on the same WiFi network.
  static Future<String?> getLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );

      bool _valid(InternetAddress a) => !a.isLoopback && !a.isLinkLocal;

      // 1. WiFi (wlan0, wlan1, …)
      for (final iface in interfaces) {
        if (!iface.name.toLowerCase().startsWith('wlan')) continue;
        for (final addr in iface.addresses) {
          if (_valid(addr)) return addr.address;
        }
      }
      // 2. Wired Ethernet (eth0, …)
      for (final iface in interfaces) {
        if (!iface.name.toLowerCase().startsWith('eth')) continue;
        for (final addr in iface.addresses) {
          if (_valid(addr)) return addr.address;
        }
      }
      // 3. Last resort: any non-loopback, non-link-local address
      //    (excludes rmnet/mobile-data via the priority above)
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (_valid(addr)) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }
}
