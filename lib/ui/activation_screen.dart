import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/license.dart';
import 'data_screen.dart';

class ActivationScreen extends StatefulWidget {
  const ActivationScreen({super.key});
  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _activate() async {
    final app = context.app;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final lic = await app.license.activate();
      app.onActivated(lic);
      if (!mounted) return;
      // جهاز جديد أو إعادة تفعيل: اعرض استعادة آخر نسخة إن وُجدت.
      await offerRestoreFromDrive(context);
    } on ActivationException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'تعذّر تسجيل الدخول: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.medication_liquid, size: 84, color: cs.primary),
                const SizedBox(height: 12),
                Text('نسق فارما', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('إدارة الصيدلية: المخزون والمبيعات والمشتريات', textAlign: TextAlign.center),
                const SizedBox(height: 32),
                const Text(
                  'سجّل الدخول بحساب Google المصرّح له لتفعيل التطبيق على هذا الجهاز. '
                  'يحتاج التفعيل اتصالاً بالإنترنت مرة واحدة فقط.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy ? null : _activate,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.login),
                  label: const Text('تسجيل الدخول بحساب Google'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: cs.errorContainer,
                    child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: cs.onErrorContainer))),
                  ),
                ],
                if (context.app.devBypass)
                  TextButton(onPressed: () {}, child: const Text('وضع التطوير مفعّل')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
