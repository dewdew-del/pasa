import 'package:flutter_test/flutter_test.dart';
import 'package:pasa/api.dart';
import 'package:pasa/pairing.dart';
import 'package:pasa/wifi.dart';

void main() {
  final k = 'a' * 64;
  final withWifi = parseQr(
    'pasa://connect?v=1&h=1.2.3.4&p=5&k=$k&n=X&s=Pasa-X&w=0123456789abcdef',
  )!;
  final noWifi = parseQr('pasa://connect?v=1&h=1.2.3.4&p=5&k=$k&n=X')!;
  final api = PasaApi('http://1.2.3.4:5', k);

  test('same Wi-Fi: connects directly, never asks to join', () async {
    var joins = 0;
    final r = await reachLaptop(
      withWifi,
      join: (_, _) async => ++joins > 0,
      connect: (_, _) async => api,
    );
    expect(r, api);
    expect(joins, 0);
  });

  test('not reachable and no laptop network: gives up', () async {
    var joins = 0;
    final r = await reachLaptop(
      noWifi,
      join: (_, _) async => ++joins > 0,
      connect: (_, _) async => null,
    );
    expect(r, isNull);
    expect(joins, 0);
  });

  test('not reachable: joins the laptop network, then connects', () async {
    String? joined;
    var tries = 0;
    final r = await reachLaptop(
      withWifi,
      join: (s, p) async {
        joined = '$s/$p';
        return true;
      },
      connect: (_, _) async =>
          ++tries >= 3 ? api : null, // address takes a moment after joining
      retryEvery: Duration.zero,
    );
    expect(r, api);
    expect(joined, 'Pasa-X/0123456789abcdef');
  });

  test('user cancels the join prompt: gives up', () async {
    var left = false;
    final r = await reachLaptop(
      withWifi,
      join: (_, _) async => false,
      connect: (_, _) async => null,
      leave: () async => left = true,
    );
    expect(r, isNull);
    expect(left, isFalse);
  });

  test('joined but laptop never answers: leaves the network', () async {
    var left = false;
    final r = await reachLaptop(
      withWifi,
      join: (_, _) async => true,
      connect: (_, _) async => null,
      leave: () async => left = true,
      retryEvery: Duration.zero,
    );
    expect(r, isNull);
    expect(left, isTrue);
  });
}
