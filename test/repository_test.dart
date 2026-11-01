import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:nasaq_pharma/core/format.dart';
import 'package:nasaq_pharma/core/gs1.dart';
import 'package:nasaq_pharma/data/database.dart';
import 'package:nasaq_pharma/data/importers.dart';
import 'package:nasaq_pharma/data/repository.dart';
import 'package:nasaq_pharma/data/table_reader.dart';

Uint8List csv(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  late AppDatabase db;
  late Repository repo;
  setUp(() {
    db = AppDatabase.memory();
    repo = Repository(db);
  });
  tearDown(() => db.close());

  Future<int> product(String name, {int price = 1000, int cost = 600, String? barcode}) =>
      repo.saveProduct(ProductsCompanion.insert(
          name: name, salePrice: Value(price), costPrice: Value(cost), barcode: Value(barcode)));
  Future<int> batch(int pid, int qty, DateTime? exp, {String no = 'B'}) =>
      repo.saveBatch(BatchesCompanion.insert(
          productId: pid, quantity: Value(qty), expiry: Value(exp), batchNo: Value(no)));

  group('الفواتير والمخزون', () {
    test('الخصم من الأقرب انتهاءً أولاً (FEFO) وحساب الإجمالي', () async {
      final p = await product('بنادول');
      final late = await batch(p, 10, DateTime.now().add(const Duration(days: 400)), no: 'late');
      final soon = await batch(p, 5, DateTime.now().add(const Duration(days: 60)), no: 'soon');
      final inv = await repo.createInvoice(
          patientName: 'أحمد', lines: [InvoiceLine(p, 8, 1000)], discount: 500);
      expect(inv.subtotal, 8000);
      expect(inv.total, 7500);
      expect(inv.paymentStatus, 'paid');
      final bs = {for (final b in await db.select(db.batches).get()) b.id: b.quantity};
      expect(bs[soon], 0); // استُنفدت الأقرب أولاً
      expect(bs[late], 7);
      expect(await repo.stockOf(p), 7);
    });

    test('الدفعات المنتهية لا تُباع', () async {
      final p = await product('منتهٍ');
      await batch(p, 10, DateTime.now().subtract(const Duration(days: 5)));
      expect(
          () => repo.createInvoice(patientName: 'س', lines: [InvoiceLine(p, 1, 1000)]),
          throwsA(isA<InsufficientStock>()));
    });

    test('فشل الفاتورة يلغي كل شيء (لا خصم جزئي ولا رقم مستهلك)', () async {
      final a = await product('أ');
      final b = await product('ب');
      await batch(a, 10, null);
      await batch(b, 1, null);
      await expectLater(
          repo.createInvoice(
              patientName: 'س', lines: [InvoiceLine(a, 5, 100), InvoiceLine(b, 3, 100)]),
          throwsA(isA<InsufficientStock>()));
      expect(await repo.stockOf(a), 10);
      expect(await db.select(db.invoices).get(), isEmpty);
      expect(await db.select(db.invoiceItems).get(), isEmpty);
      final ok = await repo.createInvoice(patientName: 'س', lines: [InvoiceLine(a, 1, 100)]);
      expect(ok.number, 'INV-000001');
    });

    test('إلغاء الفاتورة يعيد الكميات لنفس الدفعات', () async {
      final p = await product('ج');
      final b1 = await batch(p, 3, DateTime.now().add(const Duration(days: 30)));
      final b2 = await batch(p, 10, DateTime.now().add(const Duration(days: 300)));
      final inv = await repo.createInvoice(patientName: 'س', lines: [InvoiceLine(p, 5, 10)]);
      await repo.voidInvoice(inv.id);
      final bs = {for (final b in await db.select(db.batches).get()) b.id: b.quantity};
      expect(bs[b1], 3);
      expect(bs[b2], 10);
    });

    test('دفع جزئي وغير مدفوع', () async {
      final p = await product('د');
      await batch(p, 10, null);
      final inv = await repo.createInvoice(
          patientName: 'س', lines: [InvoiceLine(p, 2, 1000)], paidAmount: 500);
      expect(inv.paymentStatus, 'partial');
      await repo.settleInvoice(inv.id);
      final r = await (db.select(db.invoices)..where((t) => t.id.equals(inv.id))).getSingle();
      expect(r.paymentStatus, 'paid');
      expect(r.paidAmount, 2000);
    });

    test('لقطة اسم الصنف وسعره لا تتغير بتعديل الصنف لاحقاً', () async {
      final p = await product('الاسم القديم');
      await batch(p, 5, null);
      final inv = await repo.createInvoice(patientName: 'س', lines: [InvoiceLine(p, 1, 1000)]);
      await repo.saveProduct(ProductsCompanion(
          id: Value(p), name: const Value('اسم جديد'), salePrice: const Value(9999)));
      final items = await repo.invoiceItems(inv.id);
      expect(items.single.productName, 'الاسم القديم');
      expect(items.single.unitPrice, 1000);
    });
  });

  group('المشتريات', () {
    test('استلام الأمر يضيف الدفعات مرة واحدة فقط', () async {
      final sup = await repo.saveSupplier(SuppliersCompanion.insert(name: 'مورد'));
      final p = await product('هـ', cost: 100);
      final id = await repo.createOrder(supplierId: sup, items: [
        (oid) => PurchaseOrderItemsCompanion.insert(
            orderId: oid,
            productId: p,
            quantity: 20,
            unitCost: 700,
            batchNo: const Value('X1'),
            expiry: Value(DateTime(2028, 1, 1)))
      ]);
      await repo.receiveOrder(id);
      expect(await repo.stockOf(p), 20);
      expect((await repo.productById(p))!.costPrice, 700);
      await expectLater(repo.receiveOrder(id), throwsStateError);
      expect(await repo.stockOf(p), 20);
    });
  });

  group('استيراد الكتالوج لا يمس البيانات المالية والمخزون', () {
    test('إنشاء وتحديث دون لمس الأصناف والدفعات والفواتير', () async {
      // بيانات الصيدلية قبل الاستيراد
      final p = await product('بنادول', price: 5000, barcode: '6221000000011');
      await batch(p, 12, DateTime(2027, 12, 31));
      await repo.createInvoice(patientName: 'س', lines: [InvoiceLine(p, 2, 5000)]);
      final before = (
        await db.select(db.products).get(),
        await db.select(db.batches).get(),
        await db.select(db.invoices).get(),
        await db.select(db.invoiceItems).get(),
      );

      final imp = CatalogImporter(db);
      final t1 = readTable(
          csv('الباركود,الاسم التجاري,الاسم العلمي,الشركة,السعر المرجعي\n'
              '6221000000011,بنادول 500,Paracetamol,الأمل,9999\n'
              '6221000000028,أموكسيل,Amoxicillin,الأمل,7000\n'
              ',,x,y,1\n'),
          'a.csv');
      final pv = await imp.preview(t1);
      expect(pv.count(ImportAction.create), 2);
      expect(pv.count(ImportAction.invalid), 1);
      final r1 = await imp.apply(t1);
      expect(r1.created, 2);
      // إعادة نفس الملف: لا تغيير
      final pv2 = await imp.preview(t1);
      expect(pv2.count(ImportAction.unchanged), 2);
      // تحديث السعر المرجعي
      final t2 = readTable(csv('الباركود,الاسم التجاري,السعر المرجعي\n6221000000028,أموكسيل,7500\n'), 'b.csv');
      expect((await imp.preview(t2)).count(ImportAction.update), 1);
      expect((await imp.apply(t2)).updated, 1);
      expect((await imp.search('أموكسيل')).single.referencePrice, 7500);
      expect((await db.select(db.catalogCompanies).get()).length, 1);

      final after = (
        await db.select(db.products).get(),
        await db.select(db.batches).get(),
        await db.select(db.invoices).get(),
        await db.select(db.invoiceItems).get(),
      );
      expect(after.$1, before.$1);
      expect(after.$2, before.$2);
      expect(after.$3, before.$3);
      expect(after.$4, before.$4);
    });

    test('ملف بلا عمود الاسم يُرفض بوضوح', () async {
      final t = readTable(csv('x,y\n1,2\n'), 'c.csv');
      final pv = await CatalogImporter(db).preview(t);
      expect(pv.fatalError, isNotNull);
      expect(pv.canApply, isFalse);
    });

    test('فاصلة منقوطة وأرقام عربية', () async {
      final t = readTable(csv('الاسم التجاري;السعر المرجعي\nدواء;٣٬٠٠٠\n'), 'd.csv');
      await CatalogImporter(db).apply(t);
      expect((await db.select(db.catalogDrugs).get()).single.referencePrice, 3000);
    });
  });

  group('استيراد الجرد', () {
    test('ينشئ الأصناف والدفعات ولا يغيّر سعر صنف موجود', () async {
      final p = await product('بنادول', price: 5000);
      final t = readTable(
          csv('الاسم التجاري,رقم الدفعة,الكمية,تاريخ الانتهاء,التكلفة,السعر\n'
              'بنادول,B1,10,12/2027,4000,9999\n'
              'أموكسيل,B2,5,2028-01-31,3000,7000\n'
              'سيئ,B3,abc,2028-01-31,1,1\n'),
          'inv.csv');
      final res = await InventoryImporter(db).apply(t);
      expect(res.products, 1);
      expect(res.batches, 2);
      expect(res.skipped, 1);
      expect((await repo.productById(p))!.salePrice, 5000);
      expect(await repo.stockOf(p), 10);
      final b = (await db.select(db.batches).get()).firstWhere((b) => b.batchNo == 'B1');
      expect(b.expiry, DateTime(2027, 12, 31));
    });
  });

  group('أدوات', () {
    test('تواريخ بصيغ مختلفة', () {
      expect(parseDate('2027-03-15'), DateTime(2027, 3, 15));
      expect(parseDate('15/03/2027'), DateTime(2027, 3, 15));
      expect(parseDate('02/2028'), DateTime(2028, 2, 29));
      expect(parseDate('٢٠٢٧-٠١-٣١'), DateTime(2027, 1, 31));
      expect(parseDate('31/02/2027'), isNull);
      expect(parseDate('x'), isNull);
    });
    test('GS1', () {
      final a = parseGs1('(01)06221000000011(17)271231(10)AB12');
      expect(a.gtin, '06221000000011');
      expect(a.batch, 'AB12');
      expect(a.expiry, DateTime(2027, 12, 31));
      final b = parseGs1('010622100000001117271200\u001d10LOT7\u001d21SN9');
      expect(b.gtin, '06221000000011');
      expect(b.expiry, DateTime(2027, 12, 31)); // 00 = آخر الشهر
      expect(b.batch, 'LOT7');
      expect(b.serial, 'SN9');
      expect(parseGs1('6221000000011').isGs1, isFalse);
      expect(barcodeVariants('06221000000011'), contains('6221000000011'));
    });
    test('تنسيق المبلغ', () => expect(money(1234567), '1,234,567 ل.س'));
  });
}
