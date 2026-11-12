import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pasa/api.dart';
import 'package:pasa/transfers.dart';

/// Fake laptop with an outbox, an upload endpoint and file downloads.
class FakeLaptop {
  late HttpServer server;
  final uploads = <String>[];
  var outbox = <Map<String, dynamic>>[];
  final files = <String, List<int>>{};
  final fileGets = <String, int>{};
  Duration uploadDelay = Duration.zero;

  Future<PasaApi> start() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((r) async {
      final path = r.uri.path;
      if (path == '/api/outbox') {
        r.response.write(jsonEncode(outbox));
      } else if (path == '/api/upload') {
        await Future<void>.delayed(uploadDelay);
        await r.drain<void>();
        uploads.add(r.uri.queryParameters['name']!);
        r.response.statusCode = 201;
        r.response.write('{}');
      } else if (path.startsWith('/api/files/')) {
        final id = path.split('/').last;
        fileGets[id] = (fileGets[id] ?? 0) + 1;
        r.response.contentLength = files[id]!.length;
        r.response.add(files[id]!);
      }
      await r.response.close();
    });
    return PasaApi('http://127.0.0.1:${server.port}', 'k');
  }
}

Future<void> until(
  bool Function() ok, {
  Duration max = const Duration(seconds: 5),
}) async {
  final end = DateTime.now().add(max);
  while (!ok()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory dir;
  late FakeLaptop laptop;
  late TransferQueue q;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync();
    laptop = FakeLaptop();
    q = TransferQueue(
      await laptop.start(),
      saveDir: dir,
      pollEvery: const Duration(milliseconds: 100),
      keepAwake: (_) {},
    );
  });
  tearDown(() async {
    q.dispose();
    await laptop.server.close(force: true);
    await Future<void>.delayed(
      const Duration(milliseconds: 300),
    ); // let an aborted upload release its file
    dir.deleteSync(recursive: true);
  });

  File temp(String name, String body) =>
      File('${dir.path}/$name')..writeAsStringSync(body);

  test('uploads run in order and finish', () async {
    q.start();
    q.addUploads([temp('a.txt', 'a'), temp('b.txt', 'b')]);
    await until(() => q.items.every((t) => t.status == TStatus.done));
    expect(laptop.uploads, ['a.txt', 'b.txt']);
  });

  test('outbox items download automatically', () async {
    laptop.outbox = [
      {'id': 'x1', 'name': 'hi.txt', 'size': 2},
    ];
    laptop.files['x1'] = utf8.encode('hi');
    q.start();
    await until(
      () => q.items.isNotEmpty && q.items.first.status == TStatus.done,
    );
    expect(File('${dir.path}/hi.txt').readAsStringSync(), 'hi');
    expect(q.items.first.dir, Dir.toPhone);
  });

  test('outbox item is not downloaded twice', () async {
    laptop.outbox = [
      {'id': 'x1', 'name': 'hi.txt', 'size': 2},
    ];
    laptop.files['x1'] = utf8.encode('hi');
    q.start();
    await until(
      () => q.items.isNotEmpty && q.items.first.status == TStatus.done,
    );
    await Future<void>.delayed(
      const Duration(milliseconds: 400),
    ); // several more polls still list x1
    expect(laptop.fileGets['x1'], 1);
    expect(q.items.length, 1);
  });

  test('cancel active upload', () async {
    laptop.uploadDelay = const Duration(seconds: 2);
    q.start();
    q.addUploads([temp('slow.txt', 'x'), temp('next.txt', 'y')]);
    await until(
      () => q.items.any(
        (t) => t.name == 'slow.txt' && t.status == TStatus.active,
      ),
    );
    q.cancel(q.items.firstWhere((t) => t.name == 'slow.txt').id);
    await until(
      () =>
          q.items.firstWhere((t) => t.name == 'slow.txt').status ==
          TStatus.cancelled,
    );
    laptop.uploadDelay = Duration.zero;
    await until(
      () =>
          q.items.firstWhere((t) => t.name == 'next.txt').status ==
          TStatus.done,
    );
  });

  test('items: live first, finished newest first', () async {
    q.start();
    q.addUploads([temp('a.txt', 'a'), temp('b.txt', 'b')]);
    await until(() => q.items.every((t) => t.status == TStatus.done));
    laptop.uploadDelay = const Duration(seconds: 2);
    q.addUploads([temp('c.txt', 'c')]);
    expect(q.items.map((t) => t.name), ['c.txt', 'b.txt', 'a.txt']);
  });

  test('laptop forgetting the phone sets forgotten', () async {
    final api = PasaApi('http://127.0.0.1:${laptop.server.port}', 'k');
    final forgot = await HttpServer.bind('127.0.0.1', 0);
    forgot.listen((r) async {
      r.response.statusCode = 401;
      await r.response.close();
    });
    final q2 = TransferQueue(
      PasaApi('http://127.0.0.1:${forgot.port}', api.key),
      saveDir: dir,
      pollEvery: const Duration(milliseconds: 100),
      keepAwake: (_) {},
    );
    q2.start();
    await until(() => q2.forgotten);
    q2.dispose();
    await forgot.close(force: true);
  });

  test('connected follows polling', () async {
    q.start();
    await until(() => q.connected);
    await laptop.server.close(force: true);
    await until(() => !q.connected, max: const Duration(seconds: 5));
  });
}
