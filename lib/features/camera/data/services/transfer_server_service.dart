import 'dart:developer' as dev;
import 'dart:io';

/// Runs a minimal HTTP file server so the Admin device can download recordings
/// directly from this camera over LAN.
///
/// URL scheme: `http://[cameraIp]:8080/[filename]`
class TransferServer {
  static const int port = 8080;
  static const String _tag = 'TransferServer';

  HttpServer? _server;
  final _files = <String, String>{}; // filename → absolute path

  bool get isRunning => _server != null;

  /// Starts the server (idempotent — safe to call if already running).
  Future<void> start() async {
    if (_server != null) {
      dev.log('already running on port $port', name: _tag);
      return;
    }
    try {
      _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
      dev.log(
        'bound to 0.0.0.0:$port — server is UP',
        name: _tag,
      );
      _server!.listen(
        _handleRequest,
        onError: (Object e, StackTrace st) {
          dev.log('server stream error: $e', name: _tag, error: e, stackTrace: st);
        },
        cancelOnError: false,
      );
    } catch (e, st) {
      _server = null;
      dev.log('FAILED to bind on port $port: $e', name: _tag, error: e, stackTrace: st);
      rethrow;
    }
  }

  /// Registers a file to be served by [filename].
  void register(String filename, String absolutePath) {
    _files[filename] = absolutePath;
    dev.log('registered "$filename" → $absolutePath', name: _tag);
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final res = request.response;
    final remote = request.connectionInfo?.remoteAddress.address ?? '?';
    dev.log(
      '← ${request.method} ${request.uri.path} from $remote',
      name: _tag,
    );
    try {
      final segments = request.uri.pathSegments;
      if (segments.isEmpty) {
        res.statusCode = HttpStatus.ok;
        res.write('Multicam Transfer Server\n');
        await res.close();
        return;
      }

      final filename = segments.last;
      final filePath = _files[filename];
      if (filePath == null) {
        dev.log(
          '404 "$filename" — registered files: [${_files.keys.join(', ')}]',
          name: _tag,
        );
        res.statusCode = HttpStatus.notFound;
        res.write('File not found\n');
        await res.close();
        return;
      }

      final file = File(filePath);
      if (!await file.exists()) {
        dev.log('404 file gone at path: $filePath', name: _tag);
        res.statusCode = HttpStatus.notFound;
        res.write('File gone\n');
        await res.close();
        return;
      }

      final length = await file.length();
      dev.log('→ serving "$filename" ($length bytes)', name: _tag);

      res.statusCode = HttpStatus.ok;
      res.headers.set(HttpHeaders.contentTypeHeader, 'video/mp4');
      res.headers.contentLength = length;
      res.headers.set('content-disposition', 'attachment; filename="$filename"');
      await file.openRead().pipe(res);

      dev.log('✓ finished sending "$filename"', name: _tag);
    } catch (e, st) {
      dev.log('handler error: $e', name: _tag, error: e, stackTrace: st);
      try {
        res.statusCode = HttpStatus.internalServerError;
        await res.close();
      } catch (_) {}
    }
  }

  /// Stops the server and clears registered files.
  Future<void> stop() async {
    dev.log('stopping', name: _tag);
    await _server?.close(force: true);
    _server = null;
    _files.clear();
  }

  /// Returns the WiFi/Ethernet LAN IPv4 address of this device.
  ///
  /// Logs all found interfaces so IP-selection issues are visible in logcat.
  static Future<String?> getLanIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      );

      // Log every interface so the correct one is visible in logcat.
      for (final iface in interfaces) {
        final addrs = iface.addresses.map((a) => a.address).join(', ');
        dev.log('  iface ${iface.name}: [$addrs]', name: _tag);
      }

      bool valid(InternetAddress a) => !a.isLoopback && !a.isLinkLocal;

      // 1. WiFi (wlan0, wlan1, …)
      for (final iface in interfaces) {
        if (!iface.name.toLowerCase().startsWith('wlan')) continue;
        for (final addr in iface.addresses) {
          if (valid(addr)) {
            dev.log('getLanIp → ${addr.address} (${iface.name}, WiFi)', name: _tag);
            return addr.address;
          }
        }
      }
      // 2. Wired Ethernet (eth0, …)
      for (final iface in interfaces) {
        if (!iface.name.toLowerCase().startsWith('eth')) continue;
        for (final addr in iface.addresses) {
          if (valid(addr)) {
            dev.log('getLanIp → ${addr.address} (${iface.name}, Ethernet)', name: _tag);
            return addr.address;
          }
        }
      }
      // 3. Last resort: any non-loopback, non-link-local address
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          if (valid(addr)) {
            dev.log('getLanIp → ${addr.address} (${iface.name}, fallback)', name: _tag);
            return addr.address;
          }
        }
      }
      dev.log('getLanIp → null (no usable IPv4 found)', name: _tag);
    } catch (e) {
      dev.log('getLanIp error: $e', name: _tag);
    }
    return null;
  }
}
