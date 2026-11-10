import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/pin.dart';
import 'common.dart';

/// شاشة إدخال PIN (6 أرقام) عند فتح التطبيق.
class PinEntryScreen extends StatefulWidget {
  const PinEntryScreen({super.key});
  @override
  State<PinEntryScreen> createState() => _PinEntryScreenState();
}

class _PinEntryScreenState extends State<PinEntryScreen> {
  String _pin = '';
  String? _msg;

  Future<void> _tap(String d) async {
    if (_pin.length >= 6) return;
    setState(() {
      _pin += d;
      _msg = null;
    });
    if (_pin.length == 6) {
      final app = context.app;
      final r = await app.pin.verify(_pin);
      if (!mounted) return;
      switch (r) {
        case PinResult.ok:
          app.unlock();
        case PinResult.wrong:
          setState(() {
            _pin = '';
            _msg = 'الرمز غير صحيح';
          });
        case PinResult.locked:
          final rem = await app.pin.lockRemaining();
          setState(() {
            _pin = '';
            _msg = 'تم قفل المحاولات. أعد المحاولة بعد ${(rem?.inMinutes ?? 0) + 1} دقيقة.';
          });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.lock_outline, size: 56),
                const SizedBox(height: 8),
                const Text('أدخل رمز الدخول', style: TextStyle(fontSize: 20)),
                const SizedBox(height: 20),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < 6; i++)
                    Container(
                      margin: const EdgeInsets.all(6),
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i < _pin.length ? Theme.of(context).colorScheme.primary : Colors.transparent,
                          border: Border.all(color: Theme.of(context).colorScheme.primary, width: 2)),
                    ),
                ]),
                SizedBox(height: 28, child: _msg == null ? null : Text(_msg!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                TextButton(
                  onPressed: () async {
                    final app = context.app;
                    try {
                      if (await app.auth.confirmOwner()) {
                        await app.removePin();
                        if (mounted) snack(context, 'تم إيقاف الرمز. يمكنك تعيين رمز جديد من الإعدادات.');
                      } else if (mounted) {
                        snack(context, 'الحساب لا يطابق حساب التطبيق', error: true);
                      }
                    } catch (_) {
                      if (mounted) snack(context, 'تعذّر التحقق. تأكد من الاتصال بالإنترنت.', error: true);
                    }
                  },
                  child: const Text('نسيت الرمز؟'),
                ),
                _Keypad(onDigit: _tap, onBackspace: () => setState(() => _pin = _pin.isEmpty ? '' : _pin.substring(0, _pin.length - 1))),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Keypad extends StatelessWidget {
  final void Function(String) onDigit;
  final VoidCallback onBackspace;
  const _Keypad({required this.onDigit, required this.onBackspace});
  @override
  Widget build(BuildContext context) {
    Widget key(String label, VoidCallback? f, {IconData? icon}) => Padding(
          padding: const EdgeInsets.all(6),
          child: SizedBox(
            width: 76,
            height: 60,
            child: f == null
                ? const SizedBox()
                : OutlinedButton(
                    onPressed: f,
                    child: icon != null ? Icon(icon) : Text(label, style: const TextStyle(fontSize: 22)),
                  ),
          ),
        );
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(children: [
        for (final row in [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9']])
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final d in row) key(d, () => onDigit(d))]),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          key('', null),
          key('0', () => onDigit('0')),
          key('', onBackspace, icon: Icons.backspace_outlined),
        ]),
      ]),
    );
  }
}

/// حوار إنشاء/تغيير PIN: إدخال مرتين.
Future<void> showSetPinDialog(BuildContext context) async {
  final a = TextEditingController(), b = TextEditingController();
  final app = context.app;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('تعيين رمز PIN'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: a, keyboardType: TextInputType.number, obscureText: true, maxLength: 6, decoration: const InputDecoration(labelText: 'الرمز (6 أرقام)')),
        TextField(controller: b, keyboardType: TextInputType.number, obscureText: true, maxLength: 6, decoration: const InputDecoration(labelText: 'أعد إدخال الرمز')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(
            onPressed: () {
              if (!PinManager.isValidFormat(a.text)) {
                snack(ctx, 'يجب أن يتكون الرمز من 6 أرقام', error: true);
              } else if (a.text != b.text) {
                snack(ctx, 'الرمزان غير متطابقين', error: true);
              } else {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('حفظ')),
      ],
    ),
  );
  if (ok == true) {
    await app.setPin(a.text);
    if (context.mounted) snack(context, 'تم تعيين الرمز');
  }
}
