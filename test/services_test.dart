import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasaq_pharma/data/database.dart';
import 'package:nasaq_pharma/data/repository.dart';
import 'package:nasaq_pharma/services/backup.dart';
import 'package:nasaq_pharma/services/invoice_pdf.dart';
import 'package:nasaq_pharma/services/kv_store.dart';
import 'package:nasaq_pharma/services/license.dart';
import 'package:nasaq_pharma/services/pharmacy_info.dart';
import 'package:nasaq_pharma/services/pin.dart';
import 'package:nasaq_pharma/services/updater.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  group('قرار التفعيل ونقل الترخيص', () {
    final now = DateTime(2026, 11, 1);
    test('أول تفعيل', () {
      expect(decideActivation(existing: null, deviceId: 'A', now: now).kind, ActivationKind.create);
    });
    test('نفس الجهاز لا يغيّر شيئاً', () {
      final d = decideActivation(
          existing: {'deviceId': 'A', 'transferCount': 2, 'windowStart': now}, deviceId: 'A', now: now);
      expect(d.kind, ActivationKind.sameDevice);
    });
    test('نقل تلقائي لجهاز جديد يزيد العداد', () {
      final d = decideActivation(
          existing: {'deviceId': 'A', 'transferCount': 1, 'windowStart': now.subtract(const Duration(days: 3))},
          deviceId: 'B',
          now: now);
      expect(d.kind, ActivationKind.transfer);
      expect(d.transferCount, 2);
      expect(d.resetWindow, isFalse);
    });
    test('تجاوز الحد خلال 30 يوماً يُرفض', () {
      final d = decideActivation(
          existing: {'deviceId': 'A', 'transferCount': 3, 'windowStart': now.subtract(const Duration(days: 10))},
          deviceId: 'B',
          now: now);
      expect(d.kind, ActivationKind.tooManyTransfers);
    });
    test('بعد انتهاء النافذة يُسمح ويبدأ عدّاد جديد', () {
      final d = decideActivation(
          existing: {'deviceId': 'A', 'transferCount': 3, 'windowStart': now.subtract(const Duration(days: 31))},
          deviceId: 'B',
          now: now);
      expect(d.kind, ActivationKind.transfer);
      expect(d.transferCount, 1);
      expect(d.resetWindow, isTrue);
    });
  });

  group('الرخصة المحلية', () {
    test('تُقبل على نفس الجهاز وترفض جهازاً آخر أو توقيعاً مزوراً', () async {
      final kv = MemoryKv();
      final v = LicenseVault(kv);
      await v.save(LocalLicense('a@b.com', 'DEV1', DateTime(2026, 1, 1)));
      expect((await v.load('DEV1'))!.email, 'a@b.com');
      expect(await v.load('DEV2'), isNull);
      final m = jsonDecode(kv.data['license']!) as Map<String, dynamic>;
      m['email'] = 'evil@x.com';
      kv.data['license'] = jsonEncode(m);
      expect(await v.load('DEV1'), isNull);
    });
  });

  group('PIN', () {
    test('تعيين وتحقق وقفل بعد 5 محاولات خاطئة', () async {
      var t = DateTime(2026, 1, 1, 12);
      final pm = PinManager(MemoryKv(), now: () => t);
      expect(await pm.isSet, isFalse);
      await expectLater(pm.setPin('123'), throwsArgumentError);
      await pm.setPin('123456');
      expect(await pm.isSet, isTrue);
      expect(await pm.verify('123456'), PinResult.ok);
      for (var i = 0; i < 4; i++) {
        expect(await pm.verify('000000'), PinResult.wrong);
      }
      expect(await pm.verify('000000'), PinResult.locked);
      expect(await pm.verify('123456'), PinResult.locked); // حتى الصحيح مرفوض أثناء القفل
      t = t.add(const Duration(minutes: 6));
      expect(await pm.verify('123456'), PinResult.ok);
    });
    test('الـ PIN لا يُخزَّن نصاً صريحاً', () async {
      final kv = MemoryKv();
      await PinManager(kv).setPin('654321');
      expect(kv.data.values.any((v) => v.contains('654321')), isFalse);
    });
  });

  group('النسخ الاحتياطي', () {
    test('لقطة ثم تحقق ثم استعادة تعيد البيانات نفسها', () async {
      final tmp = await Directory.systemTemp.createTemp('nq');
      final db = AppDatabase.memory();
      final repo = Repository(db);
      final p = await repo.saveProduct(ProductsCompanion.insert(name: 'بنادول'));
      await repo.saveBatch(BatchesCompanion.insert(productId: p, quantity: const Value(7)));
      await db.setSetting('pharmacy_name', 'صيدلية الأمل');

      final packed = await BackupFile.snapshot(db, tmp);
      final raw = BackupFile.validate(packed, tmp);
      final f = File('${tmp.path}/restored.sqlite')..writeAsBytesSync(raw);
      final db2 = AppDatabase(NativeDatabase(f));
      expect((await db2.select(db2.products).get()).single.name, 'بنادول');
      expect(await Repository(db2).stockOf(p), 7);
      expect(await db2.getSetting('pharmacy_name'), 'صيدلية الأمل');
      await db2.close();
      await db.close();
      await tmp.delete(recursive: true);
    });

    test('ملف عشوائي أو تالف يُرفض', () async {
      final tmp = await Directory.systemTemp.createTemp('nq');
      expect(() => BackupFile.validate(Uint8List.fromList([1, 2, 3]), tmp),
          throwsA(isA<BackupException>()));
      final fake = Uint8List.fromList(gzip.encode(List.filled(500, 65)));
      expect(() => BackupFile.validate(fake, tmp), throwsA(isA<BackupException>()));
      await tmp.delete(recursive: true);
    });
  });

  group('التحديثات', () {
    test('تحليل version.json ومقارنة الإصدار', () {
      final u = UpdateInfo.fromJson({
        'versionCode': 5,
        'versionName': '1.0.4',
        'apkUrl': 'https://example.com/a.apk',
        'notes': 'تحسينات'
      });
      expect(u.isNewerThan(4), isTrue);
      expect(u.isNewerThan(5), isFalse);
      expect(() => UpdateInfo.fromJson({'versionCode': 5, 'apkUrl': 'http://x/a.apk'}),
          throwsFormatException);
      expect(() => UpdateInfo.fromJson({'apkUrl': 'https://x/a.apk'}), throwsFormatException);
    });
  });

  group('PDF الفاتورة', () {
    test('يُنشأ ملف PDF صالح', () async {
      final db = AppDatabase.memory();
      final repo = Repository(db);
      final p = await repo.saveProduct(
          ProductsCompanion.insert(name: 'بنادول إكسترا 500 ملغ', salePrice: const Value(5000)));
      await repo.saveBatch(BatchesCompanion.insert(productId: p, quantity: const Value(50)));
      final inv = await repo.createInvoice(
          patientName: 'محمد الأحمد',
          patientPhone: '0933123456',
          lines: [InvoiceLine(p, 3, 5000)],
          discount: 1000,
          paidAmount: 10000);
      final items = await repo.invoiceItems(inv.id);
      pw.Font font(String n) =>
          pw.Font.ttf(ByteData.sublistView(File('assets/fonts/$n').readAsBytesSync()));
      final bytes = await buildInvoicePdf(
          inv, items, const PharmacyInfo(name: 'صيدلية الأمل', phone: '011-1234567', address: 'دمشق - المزة'),
          regular: font('Amiri-Regular.ttf'), bold: font('Amiri-Bold.ttf'));
      expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
      expect(bytes.length, greaterThan(2000));
      Directory('build').createSync();
      File('build/sample_invoice.pdf').writeAsBytesSync(bytes);
      await db.close();
    });
  });
}
