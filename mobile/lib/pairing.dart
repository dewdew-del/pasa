import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What the laptop's QR code says: where it is and the key to talk to it.
class LaptopInfo {
  const LaptopInfo({
    required this.hosts,
    required this.port,
    required this.key,
    required this.name,
  });

  final List<String> hosts;
  final int port;
  final String key;
  final String name;

  Map<String, dynamic> toJson() => {
    'hosts': hosts,
    'port': port,
    'key': key,
    'name': name,
  };

  factory LaptopInfo.fromJson(Map<String, dynamic> j) => LaptopInfo(
    hosts: List<String>.from(j['hosts'] as List),
    port: j['port'] as int,
    key: j['key'] as String,
    name: j['name'] as String,
  );
}

final _hexKey = RegExp(r'^[0-9a-f]{64}$');

/// Null unless [raw] is a v1 Pasa QR with hosts, a valid port and a 64-hex key.
LaptopInfo? parseQr(String raw) {
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.scheme != 'pasa' || uri.host != 'connect') return null;
  final q = uri.queryParameters;
  if (q['v'] != '1') return null;
  final hosts = (q['h'] ?? '').split(',').where((h) => h.isNotEmpty).toList();
  final port = int.tryParse(q['p'] ?? '');
  final key = q['k'] ?? '';
  if (hosts.isEmpty ||
      port == null ||
      port < 1 ||
      port > 65535 ||
      !_hexKey.hasMatch(key)) {
    return null;
  }
  return LaptopInfo(
    hosts: hosts,
    port: port,
    key: key,
    name: q['n']?.isNotEmpty == true ? q['n']! : 'Laptop',
  );
}

const _prefKey = 'laptop';

Future<void> saveLaptop(LaptopInfo info) async =>
    (await SharedPreferences.getInstance()).setString(
      _prefKey,
      jsonEncode(info.toJson()),
    );

Future<LaptopInfo?> loadLaptop() async {
  final s = (await SharedPreferences.getInstance()).getString(_prefKey);
  if (s == null) return null;
  try {
    return LaptopInfo.fromJson(jsonDecode(s) as Map<String, dynamic>);
  } catch (_) {
    return null;
  }
}

Future<void> forgetLaptop() async =>
    (await SharedPreferences.getInstance()).remove(_prefKey);
