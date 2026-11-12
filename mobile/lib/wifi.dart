import 'package:flutter/services.dart';

import 'api.dart';
import 'pairing.dart';

const _channel = MethodChannel('pasa/wifi');

/// Asks Android to join the laptop's network (one "Connect" prompt). False if cancelled or not found.
Future<bool> joinLaptopWifi(String ssid, String pass) async =>
    await _channel.invokeMethod<bool>('join', {'ssid': ssid, 'pass': pass}) ??
    false;

Future<void> leaveLaptopWifi() => _channel.invokeMethod<void>('leave');

Future<PasaApi?> _connect(LaptopInfo info, Duration timeout) =>
    PasaApi.connect(info, timeout: timeout);

/// Same Wi-Fi first; if the laptop isn't there, join the laptop's own network and try again.
Future<PasaApi?> reachLaptop(
  LaptopInfo info, {
  Future<bool> Function(String ssid, String pass) join = joinLaptopWifi,
  Future<PasaApi?> Function(LaptopInfo info, Duration timeout) connect =
      _connect,
  Future<void> Function() leave = leaveLaptopWifi,
  Duration retryEvery = const Duration(seconds: 1),
}) async {
  final direct = await connect(info, const Duration(milliseconds: 1500));
  if (direct != null || info.ssid == null || info.wifiPass == null) {
    return direct;
  }
  if (!await join(info.ssid!, info.wifiPass!)) return null;
  // The phone needs a moment to get its address on the new network.
  for (var i = 0; i < 6; i++) {
    final api = await connect(info, const Duration(seconds: 2));
    if (api != null) return api;
    await Future<void>.delayed(retryEvery);
  }
  await leave();
  return null;
}
