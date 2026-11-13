import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../core/format.dart';
import '../services/license.dart';
import 'common.dart';

/// يحوّل ما يكتبه المستخدم إلى XXXX-XXXX-XXXX-XXXX أثناء الكتابة.
class CodeFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue old, TextEditingValue v) {
    final n = normalizeCode(v.text);
    final t = n.length > 16 ? n.substring(0, 16) : n;
    final out = [for (var i = 0; i < t.length; i += 4) t.substring(i, i + 4 > t.length ? t.length : i + 4)].join('-');
    return TextEditingValue(text: out, selection: TextSelection.collapsed(offset: out.length));
  }
}

/// نص يصف حالة الوصول الحالية.
String accessStatusText(AppController app) {
  final now = app.effectiveNow;
  final p = app.policy;
  if (p.lifetime) return 'مفعّل مدى الحياة';
  if (p.isPaid(now)) return 'مدفوع حتى ${dateFmt(p.paidUntil)}';
  if (p.isFree(now)) return 'فترة مجانية حتى ${dateFmt(p.freeUntil)}';
  return 'منتهٍ: للقراءة والتصدير فقط';
}

/// شاشة إدخال كود التفعيل الذي يسلّمه المندوب.
class RedeemScreen extends StatefulWidget {
  const RedeemScreen({super.key});
  @override
  State<RedeemScreen> createState() => _RedeemScreenState();
}

class _RedeemScreenState extends State<RedeemScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _done = false;

  Future<void> _redeem() async {
    final app = context.appRead;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await app.redeemCode(_code.text);
      if (mounted) {
        setState(() => _done = true);
        _code.clear();
      }
    } on LicenseException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'تعذّر التفعيل: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('تفعيل الاشتراك')),
      body: Centered(
        maxWidth: 520,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.verified_outlined),
              title: const Text('الحالة الحالية'),
              subtitle: Text(accessStatusText(app)),
            ),
          ),
          const SizedBox(height: 12),
          const Text('أدخل الكود الذي استلمته من المندوب. يرتبط الاشتراك بحساب Google الحالي وبهذا الجهاز، ويمكن نقله إلى هاتف جديد بتسجيل الدخول بالحساب نفسه.'),
          const SizedBox(height: 12),
          TextField(
            controller: _code,
            textDirection: TextDirection.ltr,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [CodeFormatter()],
            decoration: const InputDecoration(labelText: 'كود التفعيل', hintText: 'XXXX-XXXX-XXXX-XXXX', border: OutlineInputBorder()),
            onChanged: (_) => setState(() {
              _error = null;
              _done = false;
            }),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy || !isValidCodeFormat(_code.text) ? null : _redeem,
            icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.key),
            label: const Text('تفعيل'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card(color: cs.errorContainer, child: Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: TextStyle(color: cs.onErrorContainer)))),
            ),
          if (_done)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card(
                color: cs.primaryContainer,
                child: Padding(padding: const EdgeInsets.all(12), child: Text('تم التفعيل بنجاح: ${accessStatusText(app)}', style: TextStyle(color: cs.onPrimaryContainer))),
              ),
            ),
        ]),
      ),
    );
  }
}
