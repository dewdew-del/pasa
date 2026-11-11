import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pasa/api.dart';
import 'package:pasa/pairing.dart';

/// Fake laptop: checks the key, then hands the request to [handle].
Future<HttpServer> fakeLaptop(Future<void> Function(HttpRequest r) handle) async {
  final s = await HttpServer.bind('127.0.0.1', 0);
  s.listen((r) async {
    if (r.headers.value('authorization') != 'Bearer k') {
      r.response.statusCode = 401;
      await r.response.close();
      return;
    }
    await handle(r);
  });
  return s;
}

LaptopInfo info(List<String> hosts, int port) => LaptopInfo(hosts: hosts, port: port, key: 'k', name: 'T');

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync());
  tearDown(() => dir.deleteSync(recursive: true));

  test('connect_picks_reachable_host', () async {
    final s = await fakeLaptop((r) async {
      r.response.write('{"name":"T","v":1}');
      await r.response.close();
    });
    final sw = Stopwatch()..start();
    final api = await PasaApi.connect(info(['10.255.255.1', '127.0.0.1'], s.port));
    expect(api, isNotNull);
    expect(api!.baseUrl, 'http://127.0.0.1:${s.port}');
    expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    await s.close(force: true);
  });

  test('connect returns null when nothing answers', () async {
    final api = await PasaApi.connect(info(['10.255.255.1'], 47800), timeout: const Duration(milliseconds: 500));
    expect(api, isNull);
  });

  test('upload sends bytes and progress', () async {
    final got = <int>[];
    String? query;
    final s = await fakeLaptop((r) async {
      query = r.uri.query;
      await for (final c in r) {
        got.addAll(c);
      }
      r.response.statusCode = 201;
      r.response.write('{"saved_as":"x.bin"}');
      await r.response.close();
    });
    final f = File('${dir.path}/x.bin')..writeAsBytesSync(List.generate(300 * 1024, (i) => i % 251));
    var last = 0;
    await PasaApi('http://127.0.0.1:${s.port}', 'k').upload(f, onProgress: (n) => last = n, abort: Completer<void>().future);
    expect(got, f.readAsBytesSync());
    expect(Uri.splitQueryString(query!), {'name': 'x.bin', 'size': '${300 * 1024}'});
    expect(last, 300 * 1024);
    await s.close(force: true);
  });

  test('upload throws on 401', () async {
    final s = await fakeLaptop((r) async {});
    final f = File('${dir.path}/a')..writeAsStringSync('a');
    expect(
      PasaApi('http://127.0.0.1:${s.port}', 'wrong').upload(f, onProgress: (_) {}, abort: Completer<void>().future),
      throwsA(isA<PasaException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await s.close(force: true);
  });

  test('outbox parses items', () async {
    final s = await fakeLaptop((r) async {
      r.response.write(jsonEncode([
        {'id': 'ab', 'name': 'x.txt', 'size': 2}
      ]));
      await r.response.close();
    });
    final items = await PasaApi('http://127.0.0.1:${s.port}', 'k').outbox();
    expect(items.single.id, 'ab');
    expect(items.single.name, 'x.txt');
    expect(items.single.size, 2);
    await s.close(force: true);
  });

  test('download writes file and renames', () async {
    final s = await fakeLaptop((r) async {
      r.response.contentLength = 2;
      r.response.write('hi');
      await r.response.close();
    });
    final f = await PasaApi('http://127.0.0.1:${s.port}', 'k')
        .download(const OutboxItem('ab', 'x.txt', 2), dir, onProgress: (_) {}, abort: Completer<void>().future);
    expect(f.path, '${dir.path}/x.txt');
    expect(f.readAsStringSync(), 'hi');
    expect(dir.listSync().length, 1);
    await s.close(force: true);
  });

  test('download_interrupted_leaves_no_file', () async {
    final s = await fakeLaptop((r) async {
      r.response.contentLength = 1000;
      final sock = await r.response.detachSocket(); // sends headers, then hands over the raw socket
      sock.add(List.filled(100, 1));
      await sock.flush();
      sock.destroy(); // Wi-Fi drops after 100 of 1000 bytes
    });
    await expectLater(
      PasaApi('http://127.0.0.1:${s.port}', 'k')
          .download(const OutboxItem('ab', 'x.txt', 1000), dir, onProgress: (_) {}, abort: Completer<void>().future),
      throwsA(isA<PasaException>()),
    );
    expect(dir.listSync(), isEmpty);
    await s.close(force: true);
  });

  test('abort mid-download deletes partial', () async {
    final s = await fakeLaptop((r) async {
      r.response.contentLength = 100000;
      for (var i = 0; i < 100; i++) {
        r.response.add(List.filled(1000, 1));
        await r.response.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await r.response.close();
    });
    final abort = Completer<void>();
    await expectLater(
      PasaApi('http://127.0.0.1:${s.port}', 'k').download(const OutboxItem('ab', 'x.txt', 100000), dir, onProgress: (n) {
        if (!abort.isCompleted) abort.complete();
      }, abort: abort.future),
      throwsA(isA<PasaException>()),
    );
    expect(dir.listSync(), isEmpty);
    await s.close(force: true);
  });
}
