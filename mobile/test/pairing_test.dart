import 'package:flutter_test/flutter_test.dart';
import 'package:pasa/pairing.dart';

void main() {
  final k = 'a' * 64;

  test('parses valid QR', () {
    final i = parseQr('pasa://connect?v=1&h=192.168.1.5,10.0.0.2&p=47800&k=$k&n=DEWDEW-PC')!;
    expect(i.hosts, ['192.168.1.5', '10.0.0.2']);
    expect(i.port, 47800);
    expect(i.key, k);
    expect(i.name, 'DEWDEW-PC');
  });

  test('rejects other QR codes', () {
    for (final s in [
      'https://example.com',
      'pasa://connect?v=2&h=1.1.1.1&p=1&k=$k',
      'pasa://connect?v=1&h=&p=1&k=$k',
      'pasa://connect?v=1&h=1.1.1.1&p=0&k=$k',
      'pasa://connect?v=1&h=1.1.1.1&p=1&k=xyz',
      'hello',
      '',
    ]) {
      expect(parseQr(s), isNull, reason: s);
    }
  });

  test('json round trip', () {
    final i = parseQr('pasa://connect?v=1&h=1.2.3.4&p=5&k=$k&n=X')!;
    final j = LaptopInfo.fromJson(i.toJson());
    expect(j.hosts, ['1.2.3.4']);
    expect(j.port, 5);
    expect(j.key, k);
    expect(j.name, 'X');
  });
}
