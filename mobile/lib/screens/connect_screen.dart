import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../api.dart';
import '../pairing.dart';
import 'transfer_screen.dart';

class ConnectScreen extends StatefulWidget {
  const ConnectScreen({super.key, this.error});
  final String? error;

  @override
  State<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends State<ConnectScreen> {
  LaptopInfo? _saved;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _error = widget.error;
    loadLaptop().then((l) => mounted ? setState(() => _saved = l) : null);
  }

  Future<void> _connect(LaptopInfo info, String failMessage) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final api = await PasaApi.connect(info);
    if (!mounted) return;
    if (api == null) {
      setState(() {
        _busy = false;
        _error = failMessage;
      });
      return;
    }
    await saveLaptop(info);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => TransferScreen(api: api, info: info)));
  }

  Future<void> _scan() async {
    final info = await Navigator.of(context).push<LaptopInfo>(MaterialPageRoute(builder: (_) => const ScanScreen()));
    if (info != null) await _connect(info, 'Laptop not found. Same Wi-Fi?');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final saved = _saved;
    return Scaffold(
      appBar: AppBar(title: const Text('Pasa', style: TextStyle(fontWeight: FontWeight.w600))),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(saved != null ? 'Welcome back' : "Scan your laptop's QR",
                  style: t.textTheme.headlineSmall!.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              if (_error != null) ...[Notice(_error!), const SizedBox(height: 12)],
              if (saved != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: t.colorScheme.surface,
                    border: Border.all(color: t.colorScheme.outlineVariant),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(children: [
                    Icon(Icons.laptop_outlined, size: 18, color: t.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 12),
                    Text(saved.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ]),
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: _busy ? null : () => _connect(saved, 'Laptop not found. Scan again.'),
                  child: Text(_busy ? 'Connecting…' : 'Reconnect'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(onPressed: _busy ? null : _scan, icon: const Icon(Icons.qr_code_scanner, size: 18), label: const Text('Scan QR code')),
              ] else
                FilledButton.icon(
                  onPressed: _busy ? null : _scan,
                  icon: const Icon(Icons.qr_code_scanner, size: 18),
                  label: Text(_busy ? 'Connecting…' : 'Scan QR code'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class Notice extends StatelessWidget {
  const Notice(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF241C0B) : const Color(0xFFFFFBEB),
        border: Border.all(color: dark ? const Color(0xFF5A4718) : const Color(0xFFFDE68A)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: TextStyle(fontSize: 13, color: dark ? const Color(0xFFF2C36B) : const Color(0xFF92400E))),
    );
  }
}

/// Full-screen camera; pops with the laptop's info once a Pasa QR is seen.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  bool _wrong = false;
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final info = parseQr(b.rawValue ?? '');
      if (info != null) {
        _done = true;
        Navigator.of(context).pop(info);
        return;
      }
    }
    if (!_wrong) setState(() => _wrong = true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white),
        extendBodyBehindAppBar: true,
        body: Stack(children: [
          MobileScanner(onDetect: _onDetect),
          Center(
            child: Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(border: Border.all(color: Colors.white, width: 2), borderRadius: BorderRadius.circular(12)),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: _wrong
                ? const Center(child: Notice('Not a Pasa code'))
                : const Text('Scan the QR on your laptop', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 14)),
          ),
        ]),
      );
}
