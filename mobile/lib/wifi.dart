import 'package:flutter/services.dart';

import 'api.dart';
import 'pairing.dart';

const _channel = MethodChannel('pasa/wifi');

const wifiOff = 'Wi-Fi is off. Turn it on to connect.';
const joinCancelled = 'Tap Connect to join the laptop.';
const notFound = 'Laptop not found. Is Pasa open on it?';

/// Asks Android to join the laptop's network (one "Connect" prompt). False if cancelled or not found.
Future<bool> joinLaptopWifi(String ssid, String pass) async =>
    await _channel.invokeMethod<bool>('join', {'ssid': ssid, 'pass': pass}) ??
    false;

Future<void> leaveLaptopWifi() => _channel.invokeMethod<void>('leave');

Future<bool> wifiIsOn() async =>
    await _channel.invokeMethod<bool>('wifiOn') ?? true;

/// Android's Wi-Fi sheet with the on/off switch (apps may not switch Wi-Fi on by themselves).
Future<void> openWifiPanel() => _channel.invokeMethod<void>('openWifiPanel');

Future<PasaApi?> _connect(LaptopInfo info, Duration timeout) =>
    PasaApi.connect(info, timeout: timeout);

/// Shows Android's Wi-Fi switch if Wi-Fi is off, then waits (up to ~30 s) for the user to turn it on.
Future<bool> waitForWifi({
  Future<bool> Function() isOn = wifiIsOn,
  Future<void> Function() open = openWifiPanel,
  Duration every = const Duration(milliseconds: 500),
  int tries = 60,
}) async {
  if (await isOn()) return true;
  await open();
  for (var i = 0; i < tries; i++) {
    await Future<void>.delayed(every);
    if (await isOn()) return true;
  }
  return false;
}

/// The laptop, or the one-line reason it couldn't be reached.
class Reach {
  const Reach(this.api, [this.error]);
  final PasaApi? api;
  final String? error;
}

/// Same Wi-Fi first; if the laptop isn't there, join the laptop's own network and try again.
Future<Reach> reachLaptop(
  LaptopInfo info, {
  Future<bool> Function() ensureWifi = waitForWifi,
  Future<bool> Function(String ssid, String pass) join = joinLaptopWifi,
  Future<PasaApi?> Function(LaptopInfo info, Duration timeout) connect =
      _connect,
  Future<void> Function() leave = leaveLaptopWifi,
  Duration retryEvery = const Duration(seconds: 1),
}) async {
  final direct = await connect(info, const Duration(milliseconds: 1500));
  if (direct != null) return Reach(direct);
  if (info.ssid == null || info.wifiPass == null) {
    return const Reach(null, notFound);
  }
  if (!await ensureWifi()) return const Reach(null, wifiOff);
  if (!await join(info.ssid!, info.wifiPass!)) {
    return const Reach(null, joinCancelled);
  }
  // The phone needs a moment to get its address on the new network.
  for (var i = 0; i < 6; i++) {
    final api = await connect(info, const Duration(seconds: 2));
    if (api != null) return Reach(api);
    await Future<void>.delayed(retryEvery);
  }
  await leave();
  return const Reach(null, notFound);
}
