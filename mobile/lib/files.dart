import 'dart:io';

/// Last path part only, so a name from the laptop can't escape the save folder.
String safeName(String raw) {
  final base = raw.split(RegExp(r'[/\\]')).last.trim();
  return (base.isEmpty || base == '.' || base == '..') ? 'file' : base;
}

/// "a.jpg" -> "a (1).jpg" -> "a (2).jpg"; dotfiles and extensionless names get " (n)" at the end.
String uniqueName(Directory dir, String name) {
  if (!File('${dir.path}/$name').existsSync()) return name;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  for (var n = 1;; n++) {
    final candidate = '$stem ($n)$ext';
    if (!File('${dir.path}/$candidate').existsSync()) return candidate;
  }
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  var v = bytes / 1024;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(1)} ${units[i]}';
}

String formatSpeed(int bytesPerSec) => '${formatBytes(bytesPerSec)}/s';

/// Public Download/Pasa; apps may write their own files there without a permission on Android 11+.
Future<Directory> receiveDir() => Directory('/storage/emulated/0/Download/Pasa').create(recursive: true);
