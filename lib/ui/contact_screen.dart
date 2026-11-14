import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/profile.dart';
import 'common.dart';

/// موافقة اختيارية على التواصل (إيميل/واتساب) مع رقم هاتف اختياري.
/// تظهر مرة واحدة بعد أول تسجيل دخول، وتُعدَّل لاحقاً من الإعدادات.
class ContactScreen extends StatefulWidget {
  final bool firstRun;

  /// للاختبار: بديل عن الحفظ في Firestore.
  final Future<void> Function(ContactPrefs)? onSave;
  const ContactScreen({super.key, this.firstRun = false, this.onSave});
  @override
  State<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends State<ContactScreen> {
  final _phone = TextEditingController();
  bool _email = false, _wa = false, _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!widget.firstRun && widget.onSave == null) {
      ProfileService()
          .load()
          .then((p) {
            if (p != null && mounted) {
              setState(() {
                _phone.text = p.phone;
                _email = p.marketingEmail;
                _wa = p.marketingWhatsapp;
              });
            }
          })
          .catchError((_) {});
    }
  }

  Future<void> _save() async {
    final app = context.appRead;
    final nav = Navigator.of(context);
    final phone = normalizePhone(_phone.text);
    if (phone == null) {
      setState(() => _error = 'رقم الهاتف غير صالح (7 إلى 15 رقماً)');
      return;
    }
    if (_wa && phone.isEmpty) {
      setState(() => _error = 'أدخل رقم الهاتف لنراسلك على واتساب');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final prefs = ContactPrefs(
        phone: phone,
        marketingEmail: _email,
        marketingWhatsapp: _wa,
      );
      await (widget.onSave ?? ProfileService().save)(prefs);
      await app.markContactAsked();
      if (!widget.firstRun && mounted) nav.pop();
    } catch (_) {
      if (mounted)
        setState(
          () => _error =
              'تعذّر الحفظ. تأكد من الاتصال بالإنترنت أو اضغط «تخطّي».',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.firstRun ? 'ابقَ على اطّلاع' : 'التواصل والعروض'),
      automaticallyImplyLeading: !widget.firstRun,
    ),
    body: Centered(
      maxWidth: 520,
      child: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'كل ما في هذه الشاشة اختياري ولا يؤثر على استخدامك للتطبيق. نستعمل بياناتك فقط لإرسال التحديثات والعروض إن وافقت، ويمكنك تغيير اختيارك أو طلب حذف بياناتك في أي وقت.',
            ),
            const SizedBox(height: 12),
            formField(
              'رقم الهاتف / واتساب (اختياري)',
              _phone,
              type: TextInputType.phone,
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _email,
              onChanged: (v) => setState(() => _email = v ?? false),
              title: const Text('أوافق على تلقي التحديثات والعروض على بريدي'),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _wa,
              onChanged: (v) => setState(() => _wa = v ?? false),
              title: const Text('أوافق على تلقي التحديثات والعروض على واتساب'),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('حفظ'),
            ),
            if (widget.firstRun)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => context.appRead.markContactAsked(),
                child: const Text('تخطّي'),
              ),
          ],
        ),
      ),
    ),
  );
}
