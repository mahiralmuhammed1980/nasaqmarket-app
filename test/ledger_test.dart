import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:nasaq_market/data/database.dart';
import 'package:nasaq_market/data/repository.dart';

void main() {
  late AppDatabase db;
  late Repository repo;
  setUp(() {
    db = AppDatabase.memory();
    repo = Repository(db);
  });
  tearDown(() => db.close());

  Future<int> product(String name, {int price = 1000, int cost = 0, String size = '', String color = '', bool expiry = false}) =>
      repo.saveProduct(ProductsCompanion.insert(
          name: name, salePrice: Value(price), costPrice: Value(cost), size: Value(size), color: Value(color), trackExpiry: Value(expiry)));
  Future<void> stock(int pid, double qty) =>
      repo.saveBatch(BatchesCompanion.insert(productId: pid, quantity: Value(qty))).then((_) {});
  Future<List<CashEntry>> entries() => db.select(db.cashEntries).get();
  int sum(List<CashEntry> e) => e.fold(0, (a, b) => a + b.amount);

  group('الصندوق والمبيعات', () {
    test('فاتورة مدفوعة تدخل الصندوق بوسيلة الدفع', () async {
      final p = await product('أ');
      await stock(p, 10);
      final inv = await repo.createInvoice(
          customerName: 'س', lines: [InvoiceLine(p, 3, 1000)], discount: 500, paymentMethod: 'card');
      final e = await entries();
      expect(e.single.kind, 'sale');
      expect(e.single.amount, 2500);
      expect(e.single.method, 'card');
      expect(e.single.refId, inv.id);
      final s = await repo.cashSummary();
      expect(s.balanceByMethod['card'], 2500);
      expect(s.cashBalance, 0);
      expect(s.totalIn, 2500);
    });

    test('دفع جزئي ثم سداد المتبقي: لا يتكرر الدخول', () async {
      final p = await product('ب');
      await stock(p, 10);
      final inv = await repo.createInvoice(
          customerName: 'س', lines: [InvoiceLine(p, 4, 1000)], paidAmount: 1500);
      expect(sum(await entries()), 1500);
      await repo.settleInvoice(inv.id);
      expect(sum(await entries()), 4000);
      await repo.settleInvoice(inv.id); // مرة ثانية: لا شيء متبقٍ
      expect(sum(await entries()), 4000);
    });

    test('فاتورة آجلة بلا دفع لا تُنشئ حركة', () async {
      final p = await product('ج');
      await stock(p, 5);
      await repo.createInvoice(customerName: 'س', lines: [InvoiceLine(p, 1, 1000)], paymentMethod: 'credit', paidAmount: 0);
      expect(await entries(), isEmpty);
    });

    test('فشل الفاتورة (مخزون غير كافٍ) لا يترك أثراً مالياً', () async {
      final p = await product('د');
      await stock(p, 1);
      await expectLater(repo.createInvoice(customerName: 'س', lines: [InvoiceLine(p, 5, 1000)]), throwsA(isA<InsufficientStock>()));
      expect(await entries(), isEmpty);
    });

    test('حذف الفاتورة يعكس الحركات ويبقيها في السجل', () async {
      final p = await product('هـ');
      await stock(p, 10);
      final inv = await repo.createInvoice(customerName: 'س', lines: [InvoiceLine(p, 2, 1000)], paidAmount: 1200);
      await repo.settleInvoice(inv.id, method: 'transfer');
      expect((await repo.cashSummary()).totalBalance, 2000);
      await repo.voidInvoice(inv.id);
      final e = await entries();
      expect(e.length, 4); // بيع + سداد + عكسان
      expect(sum(e), 0);
      expect((await repo.cashSummary()).totalBalance, 0);
      expect(e.where((x) => x.kind == 'void').length, 2);
    });

    test('حركات يدوية وإغلاق اليوم', () async {
      await repo.addManualEntry(kind: 'opening', amount: 100000);
      await repo.addManualEntry(kind: 'expense', amount: 15000, category: 'إيجار');
      await repo.addManualEntry(kind: 'owner_out', amount: 5000, method: 'cash');
      await repo.addManualEntry(kind: 'owner_in', amount: 2000, method: 'transfer');
      var s = await repo.cashSummary();
      expect(s.cashBalance, 80000);
      expect(s.balanceByMethod['transfer'], 2000);
      expect(s.totalOut, 20000); // الافتتاحي لا يُحسب دخلاً
      expect(s.totalIn, 2000);
      await expectLater(repo.addManualEntry(kind: 'expense', amount: 0), throwsArgumentError);
      await expectLater(repo.addManualEntry(kind: 'sale', amount: 5), throwsArgumentError);

      final c = await repo.closeDay(79000, note: 'نقص');
      expect(c.systemBalance, 80000);
      expect(c.difference, -1000);
      s = await repo.cashSummary();
      expect(s.cashBalance, 79000); // سُوّي ليطابق الفعلي
      final c2 = await repo.closeDay(79000);
      expect(c2.difference, 0);
      expect((await entries()).where((e) => e.kind == 'adjustment').length, 1);
    });

    test('فلترة الحركات: دخل/خرج', () async {
      await repo.addManualEntry(kind: 'owner_in', amount: 10);
      await repo.addManualEntry(kind: 'expense', amount: 4);
      expect((await repo.watchCash(filter: 'in').first).length, 1);
      expect((await repo.watchCash(filter: 'out').first).single.amount, -4);
      expect((await repo.watchCash().first).length, 2);
    });
  });

  group('المشتريات وكشف حساب المورد', () {
    Future<int> order(int sup, int pid, double qty, int cost) => repo.createOrder(supplierId: sup, items: [
          (oid) => PurchaseOrdersItemHelper.item(oid, pid, qty, cost)
        ]);

    test('رصيد افتتاحي + مشتريات - دفعات', () async {
      final sup = await repo.saveSupplier(SuppliersCompanion.insert(name: 'مورد', openingBalance: const Value(1000)));
      final p = await product('و');
      final o1 = await order(sup, p, 20, 700); // 14000
      await repo.receiveOrder(o1, paid: 4000);
      var st = await repo.supplierStatement(sup);
      expect(st.openingBalance, 1000);
      expect(st.totalPurchases, 14000);
      expect(st.totalPaid, 4000);
      expect(st.balance, 11000);
      expect(await repo.stockOf(p), 20);
      // دفعة مستقلة
      await repo.addSupplierPayment(supplierId: sup, amount: 6000, note: 'دفعة نقدية');
      st = await repo.supplierStatement(sup);
      expect(st.balance, 5000);
      expect(st.rows.first.kind, 'opening');
      expect(st.rows.map((r) => r.balance).toList(), [1000, 15000, 11000, 5000]);
      // أمر ثانٍ آجل بالكامل
      final o2 = await order(sup, p, 10, 500); // 5000
      await repo.receiveOrder(o2);
      expect((await repo.supplierStatement(sup)).balance, 10000);
      expect((await repo.supplierBalances())[sup], 10000);
      // الصندوق: خرج 10000 فقط
      expect((await repo.cashSummary()).cashBalance, -10000);
    });

    test('أمر غير مستلم لا يظهر في الكشف، والدفع الزائد مرفوض بلا أثر', () async {
      final sup = await repo.saveSupplier(SuppliersCompanion.insert(name: 'مورد'));
      final p = await product('ز');
      final o = await order(sup, p, 10, 100); // 1000
      expect((await repo.supplierStatement(sup)).rows, isEmpty);
      await expectLater(repo.receiveOrder(o, paid: 1500), throwsStateError);
      expect(await repo.stockOf(p), 0);
      expect(await entries(), isEmpty);
      await repo.receiveOrder(o, paid: 1000);
      expect((await repo.supplierStatement(sup)).balance, 0);
    });

    test('موردون مختلفون لا تختلط أرصدتهم', () async {
      final a = await repo.saveSupplier(SuppliersCompanion.insert(name: 'أ'));
      final b = await repo.saveSupplier(SuppliersCompanion.insert(name: 'ب'));
      final p = await product('ح');
      await repo.receiveOrder(await order(a, p, 1, 1000));
      await repo.addSupplierPayment(supplierId: b, amount: 300);
      final bal = await repo.supplierBalances();
      expect(bal[a], 1000);
      expect(bal[b], -300); // دفعنا مقدماً
    });
  });

  group('المتغيّرات (مقاس/لون)', () {
    test('إنشاء توليفات المقاسات × الألوان بكمية ابتدائية لكل منها', () async {
      final ids = await repo.createVariants(
        base: ProductsCompanion.insert(name: 'قميص', salePrice: const Value(15000), costPrice: const Value(8000)),
        sizes: ['S', 'M'],
        colors: ['أزرق', 'أسود', 'أبيض'],
        initialQty: 4,
      );
      expect(ids.length, 6);
      final all = await repo.watchProducts().first;
      expect(all.length, 6);
      expect(all.every((p) => p.stock == 4), isTrue);
      expect(all.map((p) => p.product.displayName).toSet().length, 6);
      expect((await repo.watchProducts(query: 'أزرق').first).length, 2);
      expect((await repo.watchProducts(query: 'M').first).length, 3);
    });

    test('بدون ألوان: مقاسات فقط، وبدون كمية لا تُنشأ دفعات', () async {
      final ids = await repo.createVariants(base: ProductsCompanion.insert(name: 'حذاء'), sizes: ['40', '41', '42'], colors: []);
      expect(ids.length, 3);
      expect(await db.select(db.batches).get(), isEmpty);
    });

    test('البيع يخصم من المتغيّر المحدد ويحمل اسمه في الفاتورة', () async {
      final m = await product('قميص', size: 'M', color: 'أزرق');
      final l = await product('قميص', size: 'L', color: 'أزرق');
      await stock(m, 3);
      await stock(l, 3);
      final inv = await repo.createInvoice(lines: [InvoiceLine(m, 2, 1000)]);
      expect(await repo.stockOf(m), 1);
      expect(await repo.stockOf(l), 3);
      expect((await repo.invoiceItems(inv.id)).single.productName, 'قميص - M - أزرق');
    });
  });

  group('الكميات العشرية (البيع بالوزن)', () {
    test('بيع 0.75 كغ يخصم بدقة ويحسب المجموع بالتقريب', () async {
      final p = await product('أرز', price: 12000);
      await stock(p, 10.5);
      final inv = await repo.createInvoice(lines: [InvoiceLine(p, 0.75, 12000)]);
      expect(inv.total, 9000);
      expect(await repo.stockOf(p), 9.75);
    });

    test('لا تتراكم أخطاء الفاصلة العائمة', () async {
      final p = await product('سكر', price: 100);
      await stock(p, 1);
      for (var i = 0; i < 10; i++) {
        await repo.createInvoice(lines: [InvoiceLine(p, 0.1, 100)]);
      }
      expect(await repo.stockOf(p), 0);
      await expectLater(repo.createInvoice(lines: [InvoiceLine(p, 0.001, 100)]), throwsA(isA<InsufficientStock>()));
    });

    test('إلغاء فاتورة عشرية يعيد الكمية بدقة', () async {
      final p = await product('جبنة', price: 50000);
      await stock(p, 2.3);
      final inv = await repo.createInvoice(lines: [InvoiceLine(p, 1.35, 50000)]);
      expect(inv.total, 67500);
      await repo.voidInvoice(inv.id);
      expect(await repo.stockOf(p), 2.3);
    });
  });

  group('الصلاحية الاختيارية', () {
    test('التنبيهات للأصناف ذات الصلاحية فقط', () async {
      final milk = await product('حليب', expiry: true);
      final shirt = await product('قميص');
      final soon = DateTime.now().add(const Duration(days: 10));
      await repo.saveBatch(BatchesCompanion.insert(productId: milk, quantity: const Value(5), expiry: Value(soon)));
      await repo.saveBatch(BatchesCompanion.insert(productId: shirt, quantity: const Value(5), expiry: Value(soon)));
      final exp = await repo.expiringBatches(withinDays: 30);
      expect(exp.length, 1);
      expect(exp.single.product.name, 'حليب');
    });

    test('صنف بلا تاريخ يُباع عادياً، والمنتهي لا يُباع', () async {
      final a = await product('أ');
      await stock(a, 3);
      await repo.createInvoice(lines: [InvoiceLine(a, 3, 100)]);
      final b = await product('ب', expiry: true);
      await repo.saveBatch(BatchesCompanion.insert(productId: b, quantity: const Value(3), expiry: Value(DateTime.now().subtract(const Duration(days: 2)))));
      await expectLater(repo.createInvoice(lines: [InvoiceLine(b, 1, 100)]), throwsA(isA<InsufficientStock>()));
    });
  });

  group('الزبون الاختياري والأرباح والديون', () {
    test('فاتورة بلا اسم زبون مقبولة', () async {
      final p = await product('س');
      await stock(p, 5);
      final inv = await repo.createInvoice(lines: [InvoiceLine(p, 1, 100)]);
      expect(inv.customerName, '');
    });

    test('ربح الفترة = المبيعات بعد الخصم − التكلفة، وديون الزبائن = المتبقي', () async {
      final p = await product('ب', price: 1000, cost: 600);
      await stock(p, 10);
      final start = DateTime.now().subtract(const Duration(hours: 1));
      await repo.createInvoice(customerName: 'علي', lines: [InvoiceLine(p, 4, 1000)], discount: 200, paidAmount: 1000);
      // المبيعات 3800، التكلفة 2400، الربح 1400
      expect(await repo.profitSince(start), 1400);
      expect(await repo.customerReceivables(), 2800);
      final inv = (await db.select(db.invoices).get()).single;
      await repo.settleInvoice(inv.id);
      expect(await repo.customerReceivables(), 0);
    });
  });
}

/// مساعد لبناء بند أمر شراء في الاختبارات.
class PurchaseOrdersItemHelper {
  static PurchaseOrderItemsCompanion item(int oid, int pid, double qty, int cost) =>
      PurchaseOrderItemsCompanion.insert(orderId: oid, productId: pid, quantity: qty, unitCost: cost);
}
