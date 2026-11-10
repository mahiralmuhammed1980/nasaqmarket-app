import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/auth.dart';
import 'data_screen.dart';

/// تسجيل الدخول بحساب Google إلزامي: يضمن وجود Google Drive للنسخ الاحتياطي والمزامنة.
class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});
  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    final app = context.app;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await app.signIn();
      if (!mounted) return;
      // جهاز جديد: اعرض استعادة آخر نسخة من Drive إن وُجدت.
      await offerRestoreFromDrive(context);
    } on AuthException catch (e) {
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
                Icon(Icons.storefront, size: 84, color: cs.primary),
                const SizedBox(height: 12),
                Text('نسق ماركت', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                const Text('محاسبة ومخزون لمحلك: بقالية، ملابس، أحذية، كهربائيات وغيرها', textAlign: TextAlign.center),
                const SizedBox(height: 32),
                const Text(
                  'سجّل الدخول بحساب Google. تُحفظ بياناتك على هاتفك، وتُنسخ تلقائياً إلى Google Drive الخاص بك '
                  'فلا تضيع إن تعطّل الهاتف أو بدّلته.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _busy ? null : _signIn,
                  icon: _busy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.login),
                  label: const Text('تسجيل الدخول بحساب Google'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                ),
                const SizedBox(height: 8),
                Text('يلزم السماح بالوصول إلى مجلد التطبيق المخفي في Drive (لا نرى أي ملفات أخرى).',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: cs.errorContainer,
                    child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: cs.onErrorContainer))),
                  ),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
