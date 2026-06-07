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

  /// Returns the first non-loopback, non-link-local IPv4 address
  /// (preferring wlan/WiFi interfaces).
  static Future<String?> getLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );
      // Prefer WiFi / mobile data interfaces.
      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.startsWith('wlan') ||
            name.startsWith('rmnet') ||
            name.startsWith('eth')) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback && !addr.isLinkLocal) return addr.address;
          }
        }
      }
      // Fallback: any non-loopback address.
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && !addr.isLinkLocal) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }
}
