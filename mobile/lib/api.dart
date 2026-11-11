import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'files.dart';
import 'pairing.dart';

class OutboxItem {
  const OutboxItem(this.id, this.name, this.size);
  final String id;
  final String name;
  final int size;
}

class PasaException implements Exception {
  PasaException(this.message, {this.status});
  final String message;
  final int? status; // HTTP status, when the laptop answered
  @override
  String toString() => message;
}

/// Talks to one laptop's Pasa server.
class PasaApi {
  PasaApi(this.baseUrl, this.key, {http.Client? client})
    : _client = client ?? http.Client();

  final String baseUrl;
  final String key;
  final http.Client _client;

  Map<String, String> get _auth => {'Authorization': 'Bearer $key'};

  /// Pings every host at once; the first that answers wins. Null if none do.
  static Future<PasaApi?> connect(
    LaptopInfo info, {
    Duration timeout = const Duration(seconds: 2),
  }) {
    final done = Completer<PasaApi?>();
    var pending = info.hosts.length;
    for (final host in info.hosts) {
      final base = 'http://$host:${info.port}';
      () async {
        try {
          final r = await http
              .get(
                Uri.parse('$base/api/ping'),
                headers: {'Authorization': 'Bearer ${info.key}'},
              )
              .timeout(timeout);
          if (r.statusCode == 200 && !done.isCompleted) {
            done.complete(PasaApi(base, info.key));
          }
        } catch (_) {
          // unreachable host: try the others
        } finally {
          if (--pending == 0 && !done.isCompleted) done.complete(null);
        }
      }();
    }
    if (info.hosts.isEmpty) done.complete(null);
    return done.future;
  }

  Future<List<OutboxItem>> outbox() async {
    final r = await _client
        .get(Uri.parse('$baseUrl/api/outbox'), headers: _auth)
        .timeout(const Duration(seconds: 3));
    if (r.statusCode != 200) {
      throw PasaException(
        'Outbox failed (${r.statusCode})',
        status: r.statusCode,
      );
    }
    return (jsonDecode(r.body) as List)
        .map(
          (j) => OutboxItem(
            j['id'] as String,
            j['name'] as String,
            j['size'] as int,
          ),
        )
        .toList();
  }

  /// Streams [file] to the laptop. Throws [PasaException] unless the laptop saved it.
  Future<void> upload(
    File file, {
    required void Function(int sent) onProgress,
    required Future<void> abort,
  }) async {
    final size = await file.length();
    final uri = Uri.parse('$baseUrl/api/upload').replace(
      queryParameters: {'name': p.basename(file.path), 'size': '$size'},
    );
    final req = http.AbortableStreamedRequest('POST', uri, abortTrigger: abort)
      ..headers.addAll(_auth)
      ..contentLength = size;
    var sent = 0;
    try {
      final response = _client.send(req);
      // addStream respects backpressure, so a big file is never held in memory.
      unawaited(
        req.sink
            .addStream(
              file.openRead().map((c) {
                sent += c.length;
                onProgress(sent);
                return c;
              }),
            )
            .then((_) => req.sink.close(), onError: (_) => req.sink.close()),
      );
      final res = await response;
      await res.stream.drain<void>();
      if (res.statusCode != 201) {
        throw PasaException('Upload failed (${res.statusCode})');
      }
    } on PasaException {
      rethrow;
    } catch (e) {
      throw PasaException('Upload stopped: $e');
    }
  }

  /// Streams an outbox file into [dir] via a temp file; on any failure the partial file is deleted.
  Future<File> download(
    OutboxItem item,
    Directory dir, {
    required void Function(int got) onProgress,
    required Future<void> abort,
  }) async {
    final tmp = File('${dir.path}/.${item.id}.pasa-part');
    final req = http.AbortableRequest(
      'GET',
      Uri.parse('$baseUrl/api/files/${item.id}'),
      abortTrigger: abort,
    )..headers.addAll(_auth);
    try {
      final res = await _client.send(req);
      if (res.statusCode != 200) {
        await res.stream.drain<void>();
        throw PasaException('Download failed (${res.statusCode})');
      }
      var got = 0;
      final raf = await tmp.open(mode: FileMode.write);
      try {
        await for (final c in res.stream) {
          await raf.writeFrom(c); // awaiting each write keeps memory flat
          got += c.length;
          onProgress(got);
        }
      } finally {
        await raf.close(); // always closed, even when the stream breaks
      }
      if (got != item.size) throw PasaException('Download incomplete');
      return await tmp.rename(
        '${dir.path}/${uniqueName(dir, safeName(item.name))}',
      );
    } catch (e) {
      if (await tmp.exists()) await tmp.delete();
      throw e is PasaException ? e : PasaException('Download stopped: $e');
    }
  }
}
