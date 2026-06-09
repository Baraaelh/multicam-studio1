import 'dart:io';

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
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.listen(
      _handleRequest,
      onError: (Object _, StackTrace __) {},
      cancelOnError: false,
    );
  }

  /// Registers a file to be served by [filename].
  void register(String filename, String absolutePath) {
    _files[filename] = absolutePath;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final res = request.response;
    try {
      final segments = request.uri.pathSegments;
      if (segments.isEmpty) {
        res.statusCode = HttpStatus.ok;
        res.write('Multicam Transfer Server\n');
        await res.close();
        return;
      }

      final filename = segments.last;
      final path = _files[filename];
      if (path == null) {
        res.statusCode = HttpStatus.notFound;
        res.write('File not found\n');
        await res.close();
        return;
      }

      final file = File(path);
      if (!await file.exists()) {
        res.statusCode = HttpStatus.notFound;
        res.write('File gone\n');
        await res.close();
        return;
      }

      final length = await file.length();
      res.statusCode = HttpStatus.ok;
      res.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      res.headers.contentLength = length;
      res.headers.set(
        'content-disposition',
        'attachment; filename="$filename"',
      );
      // pipe() streams every byte from the file into the socket and closes the
      // response when the file stream ends — the canonical dart:io approach.
      await file.openRead().pipe(res);
    } catch (_) {
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
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

      bool valid(InternetAddress a) => !a.isLoopback && !a.isLinkLocal;

      // 1. WiFi (wlan0, wlan1, …)
      for (final iface in interfaces) {
        if (!iface.name.toLowerCase().startsWith('wlan')) continue;
        for (final addr in iface.addresses) {
          if (valid(addr)) return addr.address;
        }
      }
      // 2. Wired Ethernet (eth0, …)
      for (final iface in interfaces) {
        if (!iface.name.toLowerCase().startsWith('eth')) continue;
        for (final addr in iface.addresses) {
          if (valid(addr)) return addr.address;
        }
      }
      // 3. Last resort: any non-loopback, non-link-local address
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (valid(addr)) return addr.address;
        }
      }
    } catch (_) {}
    return null;
  }
}
