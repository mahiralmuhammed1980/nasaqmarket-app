import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:nasaq_market/core/format.dart';
import 'package:nasaq_market/core/gs1.dart';
import 'package:nasaq_market/data/database.dart';
import 'package:nasaq_market/data/importers.dart';
import 'package:nasaq_market/data/repository.dart';
import 'package:nasaq_market/data/table_reader.dart';

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
  Future<int> batch(int pid, double qty, DateTime? exp, {String no = 'B'}) =>
      repo.saveBatch(BatchesCompanion.insert(
          productId: pid, quantity: Value(qty), expiry: Value(exp), batchNo: Value(no)));

  group('الفواتير والمخزون', () {
    test('الخصم من الأقرب انتهاءً أولاً (FEFO) وحساب الإجمالي', () async {
      final p = await product('بنادول');
      final late = await batch(p, 10, DateTime.now().add(const Duration(days: 400)), no: 'late');
      final soon = await batch(p, 5, DateTime.now().add(const Duration(days: 60)), no: 'soon');
      final inv = await repo.createInvoice(
          customerName: 'أحمد', lines: [InvoiceLine(p, 8, 1000)], discount: 500);
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
          () => repo.createInvoice(customerName: 'س', lines: [InvoiceLine(p, 1, 1000)]),
          throwsA(isA<InsufficientStock>()));
    });

    test('فشل الفاتورة يلغي كل شيء (لا خصم جزئي ولا رقم مستهلك)', () async {
      final a = await product('أ');
      final b = await product('ب');
      await batch(a, 10, null);
      await batch(b, 1, null);
      await expectLater(
          repo.createInvoice(
              customerName: 'س', lines: [InvoiceLine(a, 5, 100), InvoiceLine(b, 3, 100)]),
          throwsA(isA<InsufficientStock>()));
      expect(await repo.stockOf(a), 10);
      expect(await db.select(db.invoices).get(), isEmpty);
      expect(await db.select(db.invoiceItems).get(), isEmpty);
      final ok = await repo.createInvoice(customerName: 'س', lines: [InvoiceLine(a, 1, 100)]);
      expect(ok.number, 'INV-000001');
    });

    test('إلغاء الفاتورة يعيد الكميات لنفس الدفعات', () async {
      final p = await product('ج');
      final b1 = await batch(p, 3, DateTime.now().add(const Duration(days: 30)));
      final b2 = await batch(p, 10, DateTime.now().add(const Duration(days: 300)));
      final inv = await repo.createInvoice(customerName: 'س', lines: [InvoiceLine(p, 5, 10)]);
      await repo.voidInvoice(inv.id);
      final bs = {for (final b in await db.select(db.batches).get()) b.id: b.quantity};
      expect(bs[b1], 3);
      expect(bs[b2], 10);
    });

    test('دفع جزئي وغير مدفوع', () async {
      final p = await product('د');
      await batch(p, 10, null);
      final inv = await repo.createInvoice(
          customerName: 'س', lines: [InvoiceLine(p, 2, 1000)], paidAmount: 500);
      expect(inv.paymentStatus, 'partial');
      await repo.settleInvoice(inv.id);
      final r = await (db.select(db.invoices)..where((t) => t.id.equals(inv.id))).getSingle();
      expect(r.paymentStatus, 'paid');
      expect(r.paidAmount, 2000);
    });

    test('لقطة اسم الصنف وسعره لا تتغير بتعديل الصنف لاحقاً', () async {
      final p = await product('الاسم القديم');
      await batch(p, 5, null);
      final inv = await repo.createInvoice(customerName: 'س', lines: [InvoiceLine(p, 1, 1000)]);
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

  group('استيراد الجرد', () {
    test('ينشئ الأصناف والدفعات ولا يغيّر سعر صنف موجود', () async {
      final p = await product('أرز', price: 5000);
      final t = readTable(
          csv('اسم الصنف,رقم الدفعة,الكمية,تاريخ الانتهاء,التكلفة,السعر\n'
              'أرز,B1,10,12/2027,4000,9999\n'
              'سكر,B2,5.5,2028-01-31,3000,7000\n'
              'سيئ,B3,abc,2028-01-31,1,1\n'),
          'inv.csv');
      final imp = InventoryImporter(db);
      final pv = await imp.preview(t);
      expect(pv.count(ImportAction.create), 1);
      expect(pv.count(ImportAction.update), 1);
      expect(pv.count(ImportAction.invalid), 1);
      final res = await imp.apply(t);
      expect(res.products, 1);
      expect(res.batches, 2);
      expect(res.skipped, 1);
      expect((await repo.productById(p))!.salePrice, 5000);
      expect(await repo.stockOf(p), 10);
      final sugar = (await db.select(db.products).get()).firstWhere((x) => x.name == 'سكر');
      expect(await repo.stockOf(sugar.id), 5.5);
      expect(sugar.trackExpiry, isTrue); // وجود تاريخ يفعّل تتبع الصلاحية
      final b = (await db.select(db.batches).get()).firstWhere((b) => b.batchNo == 'B1');
      expect(b.expiry, DateTime(2027, 12, 31));
    });

    test('المقاس واللون: توليفات مختلفة أصناف مستقلة وإعادة الاستيراد تضيف للمطابق', () async {
      final t = readTable(
          csv('اسم الصنف,المقاس,اللون,الكمية,السعر\n'
              'قميص,M,أزرق,5,15000\n'
              'قميص,L,أزرق,3,15000\n'),
          'v.csv');
      final imp = InventoryImporter(db);
      expect((await imp.apply(t)).products, 2);
      expect((await imp.apply(t)).products, 0);
      final all = await repo.watchProducts().first;
      expect(all.length, 2);
      expect(all.every((p) => p.product.trackExpiry == false), isTrue);
      expect(all.map((p) => p.stock).toSet(), {10.0, 6.0});
    });

    test('ملف بلا عمود الاسم يُرفض بوضوح', () async {
      final t = readTable(csv('x,y\n1,2\n'), 'c.csv');
      final pv = await InventoryImporter(db).preview(t);
      expect(pv.fatalError, isNotNull);
      expect(pv.canApply, isFalse);
    });

    test('فاصلة منقوطة وأرقام عربية', () async {
      final t = readTable(csv('اسم الصنف;الكمية;السعر\nمنتج;٣;٣٬٠٠٠\n'), 'd.csv');
      await InventoryImporter(db).apply(t);
      final p = (await db.select(db.products).get()).single;
      expect(p.salePrice, 3000);
      expect(await repo.stockOf(p.id), 3);
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
    test('الكميات العشرية', () {
      expect(parseQty('0,5'), 0.5);
      expect(parseQty('1,000'), 1000);
      expect(parseQty('٢٫٧٥'), 2.75);
      expect(parseQty('1,234.5'), 1234.5);
      expect(parseQty('abc'), isNull);
      expect(qtyFmt(3), '3');
      expect(qtyFmt(2.5), '2.5');
      expect(qtyFmt(0.1 + 0.2), '0.3');
      expect(q3(0.30000000000000004), 0.3);
    });
  });
}
