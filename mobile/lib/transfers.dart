import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'api.dart';
import 'package:flutter/foundation.dart';

enum Dir { toLaptop, toPhone }

enum TStatus { queued, active, done, cancelled, failed }

/// One file moving either way. Rows listen to it, so progress rebuilds only that row.
class Transfer extends ChangeNotifier {
  Transfer({required this.id, required this.name, required this.size, required this.dir, this.file, this.item});

  final String id;
  final String name;
  final int size;
  final Dir dir;
  final File? file; // upload source
  final OutboxItem? item; // download source
  int bytes = 0;
  TStatus status = TStatus.queued;
  DateTime? startedAt;
  DateTime? finishedAt;
  bool _cancelRequested = false;

  bool get live => status == TStatus.queued || status == TStatus.active;

  int get speed {
    final s = startedAt;
    if (s == null) return 0;
    final secs = (finishedAt ?? DateTime.now()).difference(s).inMicroseconds / 1e6;
    return secs < 0.2 ? 0 : (bytes / secs).round();
  }

  void changed() => notifyListeners();
}

void _wakelock(bool on) {
  try {
    WakelockPlus.toggle(enable: on).catchError((_) {});
  } catch (_) {}
}

/// Runs transfers one at a time (both directions, first in first out) and polls the laptop's outbox.
class TransferQueue extends ChangeNotifier {
  TransferQueue(this.api, {required this.saveDir, this.pollEvery = const Duration(seconds: 1), this.keepAwake = _wakelock});

  final PasaApi api;
  final Directory saveDir;
  final Duration pollEvery;
  final void Function(bool on) keepAwake;

  final List<Transfer> _all = [];
  final Set<String> _seen = {};
  DateTime? _lastOk;
  bool _wasConnected = false;
  Timer? _poll;
  Completer<void>? _abort;
  bool _running = false;
  bool _disposed = false;
  int _uploadSeq = 0;

  /// Live first in send order, then finished newest first.
  List<Transfer> get items {
    final fin = _all.where((t) => !t.live).toList()..sort((a, b) => b.finishedAt!.compareTo(a.finishedAt!));
    return [..._all.where((t) => t.live), ...fin];
  }

  /// The laptop rejected our key ("Forget phones" was pressed): the phone must scan again.
  bool forgotten = false;

  bool get connected => _lastOk != null && DateTime.now().difference(_lastOk!) < const Duration(seconds: 3);

  void start() {
    _poll = Timer.periodic(pollEvery, (_) => _pollOnce());
    _pollOnce();
  }

  Future<void> _pollOnce() async {
    var added = false;
    try {
      final items = await api.outbox();
      if (_disposed) return;
      _lastOk = DateTime.now();
      for (final it in items) {
        if (_seen.add(it.id)) {
          _all.add(Transfer(id: it.id, name: it.name, size: it.size, dir: Dir.toPhone, item: it));
          added = true;
        }
      }
    } on PasaException catch (e) {
      if (e.status == 401 && !forgotten) {
        forgotten = true;
        added = true; // forces a notify
      }
    } catch (_) {
      // laptop unreachable: only the connection flag changes
    }
    if (_disposed) return;
    if (added || connected != _wasConnected) {
      _wasConnected = connected;
      notifyListeners();
    }
    _run();
  }

  void addUploads(List<File> files) {
    for (final f in files) {
      _all.add(Transfer(id: 'u${_uploadSeq++}', name: p.basename(f.path), size: f.lengthSync(), dir: Dir.toLaptop, file: f));
    }
    notifyListeners();
    _run();
  }

  void cancel(String id) {
    final t = _all.where((t) => t.id == id).firstOrNull;
    if (t == null || !t.live) return;
    if (t.status == TStatus.queued) {
      t.status = TStatus.cancelled;
      t.finishedAt = DateTime.now();
      t.changed();
      notifyListeners();
    } else {
      t._cancelRequested = true;
      if (_abort != null && !_abort!.isCompleted) _abort!.complete();
    }
  }

  Future<void> _run() async {
    if (_running || _disposed) return;
    _running = true;
    try {
      while (!_disposed && connected) {
        // Waits while disconnected; the next good poll restarts the loop.
        final next = _all.where((t) => t.status == TStatus.queued).firstOrNull;
        if (next == null) break;
        keepAwake(true);
        await _runOne(next);
      }
    } finally {
      _running = false;
      if (!_all.any((t) => t.live)) keepAwake(false);
    }
  }

  Future<void> _runOne(Transfer t) async {
    t
      ..status = TStatus.active
      ..startedAt = DateTime.now();
    final abort = _abort = Completer<void>();
    notifyListeners();
    final tick = Timer.periodic(const Duration(milliseconds: 150), (_) => t.changed());
    try {
      if (t.dir == Dir.toLaptop) {
        await api.upload(t.file!, onProgress: (n) => t.bytes = n, abort: abort.future);
      } else {
        await api.download(t.item!, saveDir, onProgress: (n) => t.bytes = n, abort: abort.future);
      }
      t
        ..bytes = t.size
        ..status = TStatus.done;
    } catch (_) {
      t.status = t._cancelRequested ? TStatus.cancelled : TStatus.failed;
    } finally {
      tick.cancel();
      t.finishedAt = DateTime.now();
      if (!_disposed) {
        t.changed();
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    if (_abort != null && !_abort!.isCompleted) _abort!.complete();
    keepAwake(false);
    super.dispose();
  }
}
