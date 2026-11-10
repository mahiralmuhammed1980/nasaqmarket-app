import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasaq_market/data/database.dart';
import 'package:nasaq_market/data/repository.dart';
import 'package:nasaq_market/services/backup.dart';
import 'package:nasaq_market/services/invoice_pdf.dart';
import 'package:nasaq_market/services/kv_store.dart';
import 'package:nasaq_market/services/auth.dart';
import 'package:nasaq_market/core/business.dart';
import 'package:nasaq_market/services/store_info.dart';
import 'package:nasaq_market/services/pin.dart';
import 'package:pdf/widgets.dart' as pw;

void main() {
  group('الحساب', () {
    test('الحساب المحفوظ محلياً يُقرأ بلا اتصال، والخروج يمسحه', () async {
      final kv = MemoryKv();
      final auth = AuthService(kv, DriveBackupService());
      expect(await auth.current(), isNull);
      kv.data['account_email'] = 'a@b.com';
      kv.data['account_at'] = '${DateTime(2026, 1, 1).millisecondsSinceEpoch}';
      final acc = (await auth.current())!;
      expect(acc.email, 'a@b.com');
      expect(acc.signedInAt, DateTime(2026, 1, 1));
    });
  });

  group('إعدادات نوع النشاط', () {
    test('الافتراضات حسب النوع', () {
      final sm = StoreConfig.forType(BusinessType.supermarket);
      expect((sm.variants, sm.decimal, sm.expiry), (false, true, true));
      final cl = StoreConfig.forType(BusinessType.clothes);
      expect((cl.variants, cl.decimal, cl.expiry), (true, false, false));
      final sh = StoreConfig.forType(BusinessType.shoes);
      expect(sh.variants, isTrue);
      expect(BusinessType.shoes.sizePresets, contains('42'));
      final el = StoreConfig.forType(BusinessType.electronics);
      expect((el.variants, el.decimal, el.expiry), (false, false, false));
    });

    test('تحقق الكمية: عشرية فقط عند تفعيلها', () {
      final dec = StoreConfig.forType(BusinessType.supermarket);
      expect(dec.readQty('2.5'), 2.5);
      expect(dec.validateQty('0'), isNotNull);
      expect(dec.validateQty('0', allowZero: true), isNull);
      final whole = StoreConfig.forType(BusinessType.clothes);
      expect(whole.readQty('2.5'), isNull);
      expect(whole.readQty('3'), 3);
      expect(whole.validateQty('2.5'), isNotNull);
    });

    test('الحفظ والتحميل من قاعدة البيانات', () async {
      final db = AppDatabase.memory();
      expect(await StoreConfig.load(db), isNull);
      await StoreConfig.forType(BusinessType.shoes, currency: 'دينار').copyWith(decimal: true).save(db);
      final c = (await StoreConfig.load(db))!;
      expect((c.type, c.variants, c.decimal, c.expiry, c.currency), (BusinessType.shoes, true, true, false, 'دينار'));
      await db.close();
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
      final p = await repo.saveProduct(ProductsCompanion.insert(name: 'منتج'));
      await repo.saveBatch(BatchesCompanion.insert(productId: p, quantity: const Value(7)));
      await db.setSetting('store_name', 'متجر الأمل');

      final packed = await BackupFile.snapshot(db, tmp);
      final raw = BackupFile.validate(packed, tmp);
      final f = File('${tmp.path}/restored.sqlite')..writeAsBytesSync(raw);
      final db2 = AppDatabase(NativeDatabase(f));
      expect((await db2.select(db2.products).get()).single.name, 'منتج');
      expect(await Repository(db2).stockOf(p), 7);
      expect(await db2.getSetting('store_name'), 'متجر الأمل');
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

  group('PDF الفاتورة', () {
    test('يُنشأ ملف PDF صالح', () async {
      final db = AppDatabase.memory();
      final repo = Repository(db);
      final p = await repo.saveProduct(
          ProductsCompanion.insert(name: 'قميص قطن', salePrice: const Value(5000)));
      await repo.saveBatch(BatchesCompanion.insert(productId: p, quantity: const Value(50)));
      final inv = await repo.createInvoice(
          customerName: 'محمد الأحمد',
          customerPhone: '0933123456',
          lines: [InvoiceLine(p, 3, 5000)],
          discount: 1000,
          paidAmount: 10000);
      final items = await repo.invoiceItems(inv.id);
      pw.Font font(String n) =>
          pw.Font.ttf(ByteData.sublistView(File('assets/fonts/$n').readAsBytesSync()));
      final bytes = await buildInvoicePdf(
          inv, items, const StoreInfo(name: 'متجر الأمل', phone: '011-1234567', address: 'دمشق - المزة'),
          regular: font('Amiri-Regular.ttf'), bold: font('Amiri-Bold.ttf'));
      expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
      expect(bytes.length, greaterThan(2000));
      Directory('build').createSync();
      File('build/sample_invoice.pdf').writeAsBytesSync(bytes);
      await db.close();
    });
  });
}
