import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../api.dart';
import '../files.dart';
import '../pairing.dart';
import '../transfers.dart';
import 'connect_screen.dart';

class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key, required this.api, required this.info});
  final PasaApi api;
  final LaptopInfo info;

  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  TransferQueue? _q;

  @override
  void initState() {
    super.initState();
    receiveDir().then((dir) {
      if (!mounted) return;
      setState(() => _q = TransferQueue(widget.api, saveDir: dir)..start());
    });
  }

  @override
  void dispose() {
    _q?.dispose();
    super.dispose();
  }

  void _leave({required bool forget}) async {
    if (forget) await forgetLaptop();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const ConnectScreen()));
  }

  Future<void> _pick() async {
    final picked = await FilePicker.pickFiles();
    final files = [for (final f in picked) if (f.path != null) File(f.path!)];
    if (files.isNotEmpty) _q?.addUploads(files);
  }

  @override
  Widget build(BuildContext context) {
    final q = _q;
    if (q == null) return const Scaffold(body: SizedBox());
    final t = Theme.of(context);
    return ListenableBuilder(
      listenable: q, // fires on list or connection changes only; progress rebuilds single rows
      builder: (context, _) {
        final items = q.items;
        return Scaffold(
          appBar: AppBar(
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(widget.info.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
              Row(children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: q.connected ? t.colorScheme.primary : t.colorScheme.outlineVariant),
                ),
                const SizedBox(width: 6),
                Text(q.connected ? 'Connected' : 'Not reachable', style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant)),
              ]),
            ]),
            actions: [
              PopupMenuButton<bool>(
                onSelected: (forget) => _leave(forget: forget),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: false, child: Text('Disconnect')),
                  PopupMenuItem(value: true, child: Text('Forget this laptop')),
                ],
              ),
            ],
          ),
          body: Column(children: [
            if (!q.connected) const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Notice("Can't reach laptop. Retrying…")),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: Row(children: [
                const Text('Transfers', style: TextStyle(fontWeight: FontWeight.w600)),
                const Spacer(),
                Text(_summary(items), style: TextStyle(fontSize: 12, color: t.colorScheme.onSurfaceVariant)),
              ]),
            ),
            Expanded(
              child: items.isEmpty
                  ? Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        margin: const EdgeInsets.all(16),
                        padding: const EdgeInsets.all(14),
                        width: double.infinity,
                        decoration: BoxDecoration(
                          border: Border.all(color: t.colorScheme.outlineVariant),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text('Nothing yet', style: TextStyle(color: t.colorScheme.onSurfaceVariant)),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: items.length,
                      itemBuilder: (_, i) => TransferRow(key: ValueKey(items[i].id), t: items[i], onCancel: () => q.cancel(items[i].id)),
                    ),
            ),
          ]),
          bottomNavigationBar: SafeArea(
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: t.colorScheme.outlineVariant))),
              child: FilledButton.icon(
                onPressed: q.connected ? _pick : null,
                icon: const Icon(Icons.arrow_upward, size: 18),
                label: const Text('Send files'),
              ),
            ),
          ),
        );
      },
    );
  }
}

String _summary(List<Transfer> items) {
  final left = items.where((t) => t.live).toList();
  if (left.isEmpty) return '';
  final active = left.where((t) => t.status == TStatus.active).firstOrNull;
  final remaining = left.fold<int>(0, (a, t) => a + t.size - t.bytes);
  final speed = active?.speed ?? 0;
  if (speed == 0) return '${left.length} left';
  final s = (remaining / speed).ceil();
  return '${left.length} left · ${s < 60 ? '$s s' : '${s ~/ 60} min ${s % 60} s'}';
}

class TransferRow extends StatelessWidget {
  const TransferRow({super.key, required this.t, required this.onCancel});
  final Transfer t;
  final VoidCallback onCancel;

  String get _sub => switch (t.status) {
        TStatus.queued => formatBytes(t.size),
        TStatus.active => '${t.size == 0 ? 0 : (t.bytes * 100 ~/ t.size)}% · ${formatSpeed(t.speed)}',
        TStatus.done => '${t.dir == Dir.toPhone ? 'Saved' : 'Sent'} · ${formatBytes(t.size)}',
        TStatus.cancelled => 'Cancelled',
        TStatus.failed => 'Failed',
      };

  @override
  Widget build(BuildContext context) {
    final th = Theme.of(context);
    return ListenableBuilder(
      listenable: t,
      builder: (context, _) => Container(
        constraints: const BoxConstraints(minHeight: 56),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: th.colorScheme.outlineVariant))),
        child: Stack(alignment: Alignment.bottomLeft, children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Icon(t.dir == Dir.toPhone ? Icons.arrow_downward : Icons.arrow_upward, size: 16, color: th.colorScheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(_sub,
                      style: TextStyle(
                        fontSize: 12,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: t.status == TStatus.failed ? th.colorScheme.error : th.colorScheme.onSurfaceVariant,
                      )),
                ]),
              ),
              if (t.live)
                IconButton(onPressed: onCancel, tooltip: 'Cancel', icon: const Icon(Icons.close, size: 18), color: th.colorScheme.onSurfaceVariant),
            ]),
          ),
          if (t.live)
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: LinearProgressIndicator(
                value: t.size == 0 ? 0 : t.bytes / t.size,
                minHeight: 2,
                backgroundColor: th.colorScheme.outlineVariant,
              ),
            ),
        ]),
      ),
    );
  }
}
