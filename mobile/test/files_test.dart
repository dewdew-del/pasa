import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pasa/files.dart';

void main() {
  test('uniqueName', () {
    final d = Directory.systemTemp.createTempSync();
    expect(uniqueName(d, 'a.jpg'), 'a.jpg');
    File('${d.path}/a.jpg').createSync();
    expect(uniqueName(d, 'a.jpg'), 'a (1).jpg');
    File('${d.path}/a (1).jpg').createSync();
    expect(uniqueName(d, 'a.jpg'), 'a (2).jpg');
    File('${d.path}/.env').createSync();
    expect(uniqueName(d, '.env'), '.env (1)');
    d.deleteSync(recursive: true);
  });

  test('safeName strips paths', () {
    expect(safeName('../../x.txt'), 'x.txt');
    expect(safeName('a\\b.txt'), 'b.txt');
    expect(safeName(''), 'file');
    expect(safeName('..'), 'file');
  });

  test('format', () {
    expect(formatBytes(512), '512 B');
    expect(formatBytes(1536), '1.5 KB');
    expect(formatBytes(5242880), '5.0 MB');
    expect(formatSpeed(12897484), '12.3 MB/s');
  });
}
