import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasaq_market/app_state.dart';
import 'package:nasaq_market/core/business.dart';
import 'package:nasaq_market/data/database.dart';
import 'package:nasaq_market/services/kv_store.dart';
import 'package:nasaq_market/services/license.dart';
import 'package:nasaq_market/services/profile.dart';
import 'package:nasaq_market/ui/contact_screen.dart';
import 'package:nasaq_market/ui/redeem_screen.dart';
import 'package:nasaq_market/ui/app.dart';

void main() {
  group('الأكواد', () {
    test('الصيغة والتوليد: 16 حرفاً بلا أحرف ملتبسة', () {
      final rng = Random(1);
      final seen = <String>{};
      for (var i = 0; i < 2000; i++) {
        final c = generateCode(rng);
        expect(RegExp(r'^[A-Z2-9]{4}(-[A-Z2-9]{4}){3}$').hasMatch(c), isTrue, reason: c);
        expect(c.contains(RegExp('[01IO]')), isFalse);
        expect(isValidCodeFormat(c), isTrue);
        seen.add(c);
      }
      expect(seen.length, 2000);
    });

    test('التطبيع يقبل الأحرف الصغيرة والشرطات والمسافات', () {
      expect(normalizeCode(' abcd-efgh jklm_npqr '), 'ABCDEFGHJKLMNPQR');
      expect(codeHash('abcd-efgh-jklm-npqr'), codeHash('ABCDEFGHJKLMNPQR'));
      expect(isValidCodeFormat('ABCD-EFGH-JKLM'), isFalse);
      expect(isValidCodeFormat('ABCD-EFGH-JKLM-NPQ0'), isFalse); // 0 غير مسموح
    });

    test('البصمة تطابق أداة tool/gen_codes.py (نفس المتجه)', () {
      expect(codeHash('ABCD-EFGH-JKLM-NPQR'), '7cf629bb82226bfb6356859edb341b8f36a74d8997c4fe385dbef6dc85c5c4bb');
    });

    test('أنواع الأكواد الثلاثة', () {
      expect(LicensePlan.values.length, 3);
      expect(LicensePlan.parse('6m')!.days, 183);
      expect(LicensePlan.parse('12m')!.days, 365);
      expect(LicensePlan.parse('life'), LicensePlan.lifetime);
      expect(LicensePlan.parse('x'), isNull);
    });
  });

  group('الاستحقاق', () {
    test('ساري حتى التاريخ، ومدى الحياة دائم', () {
      final e = Entitlement(paidUntil: DateTime(2027, 6, 1));
      expect(e.active(DateTime(2027, 5, 31)), isTrue);
      expect(e.active(DateTime(2027, 6, 1)), isFalse);
      expect(const Entitlement().active(DateTime(2027)), isFalse);
      expect(const Entitlement(lifetime: true).active(DateTime(2100)), isTrue);
    });
  });

  group('نقل الجهاز', () {
    final now = DateTime(2027, 1, 1);
    test('نفس الجهاز', () => expect(decideTransfer(existing: {'deviceId': 'A', 'transferCount': 2, 'windowStart': now}, deviceId: 'A', now: now).kind, TransferKind.sameDevice));
    test('نقل ضمن الحد يزيد العداد', () {
      final d = decideTransfer(existing: {'deviceId': 'A', 'transferCount': 1, 'windowStart': now.subtract(const Duration(days: 3))}, deviceId: 'B', now: now);
      expect((d.kind, d.transferCount, d.resetWindow), (TransferKind.transfer, 2, false));
    });
    test('تجاوز الحد خلال 30 يوماً يُرفض', () {
      expect(decideTransfer(existing: {'deviceId': 'A', 'transferCount': 3, 'windowStart': now.subtract(const Duration(days: 10))}, deviceId: 'B', now: now).kind, TransferKind.tooManyTransfers);
    });
    test('بعد انتهاء النافذة يبدأ عدّاد جديد', () {
      final d = decideTransfer(existing: {'deviceId': 'A', 'transferCount': 3, 'windowStart': now.subtract(const Duration(days: 31))}, deviceId: 'B', now: now);
      expect((d.kind, d.transferCount, d.resetWindow), (TransferKind.transfer, 1, true));
    });
  });

  group('الترخيص المحلي الموقّع', () {
    test('يُقبل على نفس الجهاز ويرفض جهازاً آخر أو تعديلاً يدوياً', () async {
      final kv = MemoryKv();
      final v = LicenseVault(kv);
      await v.save(LocalLicense('u1', 'a@b.com', 'DEV1', Entitlement(paidUntil: DateTime(2027, 6, 1)), DateTime(2027, 1, 1)));
      final l = (await v.load('DEV1'))!;
      expect(l.entitlement.paidUntil, DateTime(2027, 6, 1));
      expect(l.email, 'a@b.com');
      expect(await v.load('DEV2'), isNull);
      // تمديد الاشتراك يدوياً في التخزين يُبطل التوقيع
      final raw = kv.data['license_v2']!;
      kv.data['license_v2'] = raw.replaceFirst('${DateTime(2027, 6, 1).millisecondsSinceEpoch}', '${DateTime(2099, 6, 1).millisecondsSinceEpoch}');
      expect(await v.load('DEV1'), isNull);
    });

    test('مدى الحياة يُحفظ ويُقرأ', () async {
      final v = LicenseVault(MemoryKv());
      await v.save(LocalLicense('u', 'e', 'D', const Entitlement(lifetime: true), DateTime(2027)));
      expect((await v.load('D'))!.entitlement.lifetime, isTrue);
    });
  });

  group('شاشة إدخال الكود', () {
    testWidgets('تنسيق أثناء الكتابة وتفعيل الزر عند اكتمال الكود فقط', (t) async {
      t.view.physicalSize = const Size(420, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final c = AppController(database: AppDatabase.memory(), kvStore: MemoryKv(), forceSignedIn: true, presetType: BusinessType.general, freeUntil: DateTime(2100));
      await t.pumpWidget(NasaqApp(controller: c));
      await t.runAsync(() => c.init());
      await t.pump(const Duration(milliseconds: 200));
      Navigator.of(t.element(find.byType(Scaffold).first)).push(MaterialPageRoute(builder: (_) => const RedeemScreen()));
      for (var i = 0; i < 3; i++) {
        await t.runAsync(() => Future.delayed(const Duration(milliseconds: 120)));
        await t.pump(const Duration(milliseconds: 350));
      }
      FilledButton btn() => t.widget<FilledButton>(find.descendant(of: find.byType(RedeemScreen), matching: find.byWidgetPredicate((w) => w is FilledButton)));
      expect(btn().onPressed, isNull);
      await t.enterText(find.byType(TextField), 'abcdefghjkl');
      expect(t.widget<TextField>(find.byType(TextField)).controller!.text, 'ABCD-EFGH-JKL');
      expect(btn().onPressed, isNull);
      await t.enterText(find.byType(TextField), 'abcdefghjklmnpqr');
      await t.pump();
      expect(t.widget<TextField>(find.byType(TextField)).controller!.text, 'ABCD-EFGH-JKLM-NPQR');
      expect(btn().onPressed, isNotNull);
      expect(find.textContaining('فترة مجانية حتى'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(milliseconds: 50));
    });
  });

  group('التواصل الاختياري', () {
    test('تطبيع رقم الهاتف', () {
      expect(normalizePhone(''), '');
      expect(normalizePhone('  '), '');
      expect(normalizePhone('0933 123 456'), '0933123456');
      expect(normalizePhone('+963 933-123-456'), '+963933123456');
      expect(normalizePhone('00963933123456'), '+963933123456');
      expect(normalizePhone('٠٩٣٣١٢٣٤٥٦'), '0933123456');
      expect(normalizePhone('123'), isNull);
      expect(normalizePhone('1' * 20), isNull);
    });

    Future<AppController> boot(WidgetTester t, {bool first = true, Future<void> Function(ContactPrefs)? save}) async {
      t.view.physicalSize = const Size(420, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      final c = AppController(database: AppDatabase.memory(), kvStore: MemoryKv(), forceSignedIn: true, presetType: BusinessType.general, freeUntil: DateTime(2100));
      await t.pumpWidget(NasaqApp(controller: c));
      await t.runAsync(() => c.init());
      await t.pump(const Duration(milliseconds: 200));
      Navigator.of(t.element(find.byType(Scaffold).first)).push(MaterialPageRoute(builder: (_) => ContactScreen(firstRun: false, onSave: save)));
      for (var i = 0; i < 3; i++) {
        await t.runAsync(() => Future.delayed(const Duration(milliseconds: 120)));
        await t.pump(const Duration(milliseconds: 350));
      }
      return c;
    }

    testWidgets('الخانات غير مفعّلة افتراضياً والحفظ يرسل ما اختاره المستخدم فقط', (t) async {
      ContactPrefs? saved;
      final c = await boot(t, save: (p) async => saved = p);
      final boxes = t.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
      expect(boxes.length, 2);
      expect(boxes.every((b) => b.value == false), isTrue);
      await t.enterText(find.byType(TextFormField), '0933 123 456');
      await t.tap(find.byType(CheckboxListTile).first);
      await t.pump();
      await t.tap(find.text('حفظ'));
      await t.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
      await t.pump(const Duration(milliseconds: 300));
      expect(saved!.phone, '0933123456');
      expect(saved!.marketingEmail, isTrue);
      expect(saved!.marketingWhatsapp, isFalse);
      expect(c.contactAsked, isTrue);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(milliseconds: 50));
    });

    testWidgets('واتساب بلا رقم يُرفض، والرقم الخاطئ يُرفض، ولا يُحفظ شيء', (t) async {
      var calls = 0;
      await boot(t, save: (p) async => calls++);
      await t.tap(find.byType(CheckboxListTile).last);
      await t.pump();
      await t.tap(find.text('حفظ'));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('أدخل رقم الهاتف لنراسلك على واتساب'), findsOneWidget);
      await t.enterText(find.byType(TextFormField), '12');
      await t.tap(find.text('حفظ'));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('غير صالح'), findsOneWidget);
      expect(calls, 0);
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(milliseconds: 50));
    });
  });
}
