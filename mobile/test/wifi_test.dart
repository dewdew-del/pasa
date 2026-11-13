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
  Future<bool> on() async => true;

  test('same Wi-Fi: connects directly, never asks to join', () async {
    var joins = 0;
    final r = await reachLaptop(
      withWifi,
      ensureWifi: on,
      join: (_, _) async => ++joins > 0,
      connect: (_, _) async => api,
    );
    expect(r.api, api);
    expect(r.error, isNull);
    expect(joins, 0);
  });

  test('not reachable and no laptop network: not found', () async {
    var joins = 0;
    final r = await reachLaptop(
      noWifi,
      ensureWifi: on,
      join: (_, _) async => ++joins > 0,
      connect: (_, _) async => null,
    );
    expect(r.api, isNull);
    expect(r.error, notFound);
    expect(joins, 0);
  });

  test('Wi-Fi stays off after asking: says so, never tries to join', () async {
    var joins = 0;
    final r = await reachLaptop(
      withWifi,
      ensureWifi: () async => false,
      join: (_, _) async => ++joins > 0,
      connect: (_, _) async => null,
    );
    expect(r.error, wifiOff);
    expect(joins, 0);
  });

  test('not reachable: joins the laptop network, then connects', () async {
    String? joined;
    var tries = 0;
    final r = await reachLaptop(
      withWifi,
      ensureWifi: on,
      join: (s, p) async {
        joined = '$s/$p';
        return true;
      },
      connect: (_, _) async =>
          ++tries >= 3 ? api : null, // address takes a moment after joining
      retryEvery: Duration.zero,
    );
    expect(r.api, api);
    expect(joined, 'Pasa-X/0123456789abcdef');
  });

  test('user cancels the join prompt: says to tap Connect', () async {
    var left = false;
    final r = await reachLaptop(
      withWifi,
      ensureWifi: on,
      join: (_, _) async => false,
      connect: (_, _) async => null,
      leave: () async => left = true,
    );
    expect(r.error, joinCancelled);
    expect(left, isFalse);
  });

  test(
    'joined but laptop never answers: leaves the network, not found',
    () async {
      var left = false;
      final r = await reachLaptop(
        withWifi,
        ensureWifi: on,
        join: (_, _) async => true,
        connect: (_, _) async => null,
        leave: () async => left = true,
        retryEvery: Duration.zero,
      );
      expect(r.error, notFound);
      expect(left, isTrue);
    },
  );

  test(
    'Wi-Fi off at scan: asks, user turns it on, carries on to join',
    () async {
      var asked = 0;
      var joins = 0;
      final r = await reachLaptop(
        withWifi,
        ensureWifi: () async =>
            ++asked > 0, // the switch was shown and turned on
        join: (_, _) async => ++joins > 0,
        connect: (_, _) async => joins > 0 ? api : null,
        retryEvery: Duration.zero,
      );
      expect(r.api, api);
      expect(asked, 1);
      expect(joins, 1);
    },
  );

  test(
    'waitForWifi: opens the switch once, returns when Wi-Fi comes on',
    () async {
      var checks = 0;
      var opened = 0;
      final on = await waitForWifi(
        isOn: () async => ++checks >= 3, // off, off, then on
        open: () async => opened++,
        every: Duration.zero,
      );
      expect(on, isTrue);
      expect(opened, 1);
    },
  );

  test('waitForWifi: gives up if Wi-Fi never comes on', () async {
    final on = await waitForWifi(
      isOn: () async => false,
      open: () async {},
      every: Duration.zero,
      tries: 5,
    );
    expect(on, isFalse);
  });

  test('waitForWifi: already on, never opens the switch', () async {
    var opened = 0;
    final on = await waitForWifi(
      isOn: () async => true,
      open: () async => opened++,
    );
    expect(on, isTrue);
    expect(opened, 0);
  });
}
