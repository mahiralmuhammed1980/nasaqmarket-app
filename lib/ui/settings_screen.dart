import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app_state.dart';
import '../services/store_info.dart';
import 'common.dart';
import 'contact_screen.dart';
import 'pin_screen.dart';
import 'redeem_screen.dart';
import 'shell.dart';
import '../services/updater.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final name = TextEditingController(text: context.app.store.name);
  late final phone = TextEditingController(text: context.app.store.phone);
  late final address = TextEditingController(text: context.app.store.address);
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
    final p = context.app.store;
    await context.app.saveStore(StoreInfo(name: p.name, phone: p.phone, address: p.address, logo: bytes));
  }

  Future<void> _save() async {
    final p = context.app.store;
    await context.app.saveStore(StoreInfo(name: name.text.trim(), phone: phone.text.trim(), address: address.text.trim(), logo: p.logo));
    if (mounted) snack(context, 'تم الحفظ');
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    final logo = app.store.logo;
    return Centered(
      maxWidth: 640,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        Text('بيانات المحل', style: Theme.of(context).textTheme.titleMedium),
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
                onPressed: () => app.saveStore(StoreInfo(name: app.store.name, phone: app.store.phone, address: app.store.address)),
                child: const Text('إزالة')),
        ]),
        formField('اسم المحل', name),
        formField('الهاتف', phone, type: TextInputType.phone),
        formField('العنوان', address),
        FilledButton(onPressed: _save, child: const Text('حفظ')),
        const Divider(height: 40),
        Text('الميزات (${app.cfg.type.label})', style: Theme.of(context).textTheme.titleMedium),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('المقاس واللون'),
          subtitle: const Text('للألبسة والأحذية: كل توليفة صنف مستقل'),
          value: app.cfg.variants,
          onChanged: (v) => app.saveConfig(app.cfg.copyWith(variants: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('كميات عشرية (البيع بالوزن)'),
          subtitle: const Text('مثل 0.5 كغ أو 2.75 متر'),
          value: app.cfg.decimal,
          onChanged: (v) => app.saveConfig(app.cfg.copyWith(decimal: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('تاريخ الصلاحية'),
          subtitle: const Text('اختياري لكل صنف؛ يفعّل تنبيهات الانتهاء'),
          value: app.cfg.expiry,
          onChanged: (v) => app.saveConfig(app.cfg.copyWith(expiry: v)),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.payments_outlined),
          title: const Text('رمز العملة'),
          subtitle: Text(app.cfg.currency),
          onTap: () async {
            final c = TextEditingController(text: app.cfg.currency);
            final v = await showDialog<String>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('رمز العملة'),
                content: TextField(controller: c, autofocus: true),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('حفظ'))],
              ),
            );
            if (v != null && v.isNotEmpty) await app.saveConfig(app.cfg.copyWith(currency: v));
          },
        ),
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
          leading: const Icon(Icons.key),
          title: const Text('الاشتراك والتفعيل'),
          subtitle: Text(accessStatusText(app)),
          trailing: const Icon(Icons.chevron_left),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RedeemScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.mark_email_unread_outlined),
          title: const Text('التواصل والعروض'),
          subtitle: const Text('رقم الهاتف وموافقتك على التحديثات والعروض'),
          trailing: const Icon(Icons.chevron_left),
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ContactScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: const Text('حساب Google'),
          subtitle: Text(app.account?.email ?? '—'),
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
        ListTile(
          leading: const Icon(Icons.logout),
          title: const Text('تسجيل الخروج'),
          subtitle: const Text('تبقى البيانات على الهاتف؛ يلزم تسجيل الدخول مجدداً للمتابعة'),
          onTap: () async {
            if (await confirm(context, 'تسجيل الخروج؟', body: 'سيُرفع الآن نسخة احتياطية إلى Drive قبل الخروج إن أمكن.', ok: 'خروج')) {
              try {
                await app.backupToDrive();
              } catch (_) {}
              await app.signOut();
            }
          },
        ),
      ]),
    );
  }
}
