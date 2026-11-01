import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_state.dart';
import '../services/pharmacy_info.dart';
import '../services/updater.dart';
import 'common.dart';
import 'pin_screen.dart';
import 'shell.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final name = TextEditingController(text: context.app.pharmacy.name);
  late final phone = TextEditingController(text: context.app.pharmacy.phone);
  late final address = TextEditingController(text: context.app.pharmacy.address);
  String _version = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((p) => mounted ? setState(() => _version = '${p.version} (${p.buildNumber})') : null);
  }

  Future<void> _pickLogo() async {
    // نصغّر الصورة (≤ 400px) فتبقى خفيفة وتدخل في النسخ الاحتياطي.
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 400, maxHeight: 400, imageQuality: 85);
    if (x == null || !mounted) return;
    final bytes = await x.readAsBytes();
    if (!mounted) return;
    final p = context.app.pharmacy;
    await context.app.savePharmacy(PharmacyInfo(name: p.name, phone: p.phone, address: p.address, logo: bytes));
  }

  Future<void> _save() async {
    final p = context.app.pharmacy;
    await context.app.savePharmacy(PharmacyInfo(name: name.text.trim(), phone: phone.text.trim(), address: address.text.trim(), logo: p.logo));
    if (mounted) snack(context, 'تم الحفظ');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final logo = app.pharmacy.logo;
    return Centered(
      maxWidth: 640,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Text('بيانات الصيدلية', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(children: [
          InkWell(
            onTap: _pickLogo,
            child: CircleAvatar(radius: 36, backgroundImage: logo == null ? null : MemoryImage(logo), child: logo == null ? const Icon(Icons.add_a_photo) : null),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Text('الشعار يظهر في الفواتير')),
          if (logo != null)
            TextButton(
                onPressed: () => app.savePharmacy(PharmacyInfo(name: app.pharmacy.name, phone: app.pharmacy.phone, address: app.pharmacy.address)),
                child: const Text('إزالة')),
        ]),
        formField('اسم الصيدلية', name),
        formField('الهاتف', phone, type: TextInputType.phone),
        formField('العنوان', address),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
        const Divider(height: 40),
        Text('الأمان', style: Theme.of(context).textTheme.titleMedium),
        ListTile(
          leading: const Icon(Icons.pin_outlined),
          title: Text(app.pinRequired ? 'تغيير رمز PIN' : 'تفعيل رمز PIN'),
          subtitle: const Text('قفل محلي من 6 أرقام عند فتح التطبيق'),
          onTap: () => showSetPinDialog(context),
        ),
        if (app.pinRequired)
          ListTile(
            leading: const Icon(Icons.lock_open),
            title: const Text('إيقاف رمز PIN'),
            onTap: () async {
              if (await confirm(context, 'إيقاف الرمز؟')) await app.removePin();
            },
          ),
        const Divider(height: 40),
        Text('حول التطبيق', style: Theme.of(context).textTheme.titleMedium),
        ListTile(leading: const Icon(Icons.info_outline), title: const Text('الإصدار'), subtitle: Text(_version)),
        ListTile(
          leading: const Icon(Icons.verified_user_outlined),
          title: const Text('الحساب المفعّل'),
          subtitle: Text(app.licenseInfo?.email ?? '—'),
        ),
        ListTile(
          leading: const Icon(Icons.system_update),
          title: const Text('التحقق من وجود تحديث'),
          onTap: () async {
            try {
              final u = await UpdateService().check(throwOnError: true);
              if (!context.mounted) return;
              if (u == null) {
                snack(context, 'أنت تستخدم أحدث إصدار');
              } else {
                showUpdateDialog(context, u);
              }
            } catch (_) {
              if (context.mounted) snack(context, 'تعذّر التحقق. تأكد من الاتصال بالإنترنت.', error: true);
            }
          },
        ),
      ]),
    );
  }
}
