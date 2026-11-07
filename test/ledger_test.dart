import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:nasaq_pharma/data/database.dart';
import 'package:nasaq_pharma/data/repository.dart';

void main() {
  late AppDatabase db;
  late Repository repo;
  setUp(() {
    db = AppDatabase.memory();
    repo = Repository(db);
  });
  tearDown(() => db.close());

  Future<int> product(String name, {int price = 1000, bool restricted = false, int? companyId}) =>
      repo.saveProduct(ProductsCompanion.insert(
          name: name, salePrice: Value(price), isRestricted: Value(restricted), companyId: Value(companyId)));
  Future<void> stock(int pid, int qty) =>
      repo.saveBatch(BatchesCompanion.insert(productId: pid, quantity: Value(qty))).then((_) {});
  Future<List<CashEntry>> entries() => db.select(db.cashEntries).get();
  int sum(List<CashEntry> e) => e.fold(0, (a, b) => a + b.amount);

  group('الصندوق والمبيعات', () {
    test('فاتورة مدفوعة تدخل الصندوق بوسيلة الدفع', () async {
      final p = await product('أ');
      await stock(p, 10);
      final inv = await repo.createInvoice(
          patientName: 'س', lines: [InvoiceLine(p, 3, 1000)], discount: 500, paymentMethod: 'card');
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
          patientName: 'س', lines: [InvoiceLine(p, 4, 1000)], paidAmount: 1500);
      expect(sum(await entries()), 1500);
      await repo.settleInvoice(inv.id);
      expect(sum(await entries()), 4000);
      await repo.settleInvoice(inv.id); // مرة ثانية: لا شيء متبقٍ
      expect(sum(await entries()), 4000);
    });

    test('فاتورة آجلة بلا دفع لا تُنشئ حركة', () async {
      final p = await product('ج');
      await stock(p, 5);
      await repo.createInvoice(patientName: 'س', lines: [InvoiceLine(p, 1, 1000)], paymentMethod: 'credit', paidAmount: 0);
      expect(await entries(), isEmpty);
    });

    test('فشل الفاتورة (مخزون غير كافٍ) لا يترك أثراً مالياً', () async {
      final p = await product('د');
      await stock(p, 1);
      await expectLater(repo.createInvoice(patientName: 'س', lines: [InvoiceLine(p, 5, 1000)]), throwsA(isA<InsufficientStock>()));
      expect(await entries(), isEmpty);
    });

    test('حذف الفاتورة يعكس الحركات ويبقيها في السجل', () async {
      final p = await product('هـ');
      await stock(p, 10);
      final inv = await repo.createInvoice(patientName: 'س', lines: [InvoiceLine(p, 2, 1000)], paidAmount: 1200);
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
    Future<int> order(int sup, int pid, int qty, int cost) => repo.createOrder(supplierId: sup, items: [
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

  group('الأدوية المقيّدة', () {
    const rx = PrescriptionInfo(prescriptionNo: 'R-77', doctorName: 'د. سمير', patientName: 'خالد', patientNationalId: '٠١٢٣٤٥٦٧٨٩٠١');

    test('البيع بلا بيانات الوصفة مرفوض ولا يغيّر شيئاً', () async {
      final p = await product('مقيّد', restricted: true);
      await stock(p, 10);
      await expectLater(repo.createInvoice(patientName: 'خالد', lines: [InvoiceLine(p, 1, 1000)]), throwsA(isA<PrescriptionRequired>()));
      await expectLater(
          repo.createInvoice(
              patientName: 'خالد',
              lines: [InvoiceLine(p, 1, 1000)],
              prescription: const PrescriptionInfo(prescriptionNo: '', doctorName: 'د', patientName: 'خ', patientNationalId: '1')),
          throwsA(isA<PrescriptionRequired>()));
      expect(await repo.stockOf(p), 10);
      expect(await db.select(db.invoices).get(), isEmpty);
      expect(await entries(), isEmpty);
      expect(await db.select(db.restrictedRecords).get(), isEmpty);
    });

    test('البيع بوصفة يسجّل في السجل (والرقم الوطني يُوحَّد)، والعادي لا يتطلب شيئاً', () async {
      final r = await product('مقيّد', restricted: true);
      final n = await product('عادي');
      await stock(r, 10);
      await stock(n, 10);
      final inv = await repo.createInvoice(patientName: 'خالد', lines: [InvoiceLine(r, 2, 1000), InvoiceLine(n, 1, 500)], prescription: rx);
      final recs = await db.select(db.restrictedRecords).get();
      expect(recs.length, 1); // سطر المقيّد فقط
      expect(recs.single.productName, 'مقيّد');
      expect(recs.single.quantity, 2);
      expect(recs.single.prescriptionNo, 'R-77');
      expect(recs.single.patientNationalId, '012345678901');
      expect(recs.single.invoiceNumber, inv.number);
      expect(recs.single.voided, isFalse);
      // فاتورة عادية بلا وصفة
      await repo.createInvoice(patientName: 'س', lines: [InvoiceLine(n, 1, 500)]);
      expect((await db.select(db.restrictedRecords).get()).length, 1);
      // حذف الفاتورة يُعلّم السجل ولا يمحوه
      await repo.voidInvoice(inv.id);
      final after = await db.select(db.restrictedRecords).get();
      expect(after.single.voided, isTrue);
    });

    test('بحث السجل بالرقم الوطني واسم المريض والوصفة', () async {
      final r = await product('مقيّد', restricted: true);
      await stock(r, 10);
      await repo.createInvoice(patientName: 'خالد', lines: [InvoiceLine(r, 1, 1000)], prescription: rx);
      expect((await repo.watchRestricted(query: '012345678901').first).length, 1);
      expect((await repo.watchRestricted(query: 'خالد').first).length, 1);
      expect((await repo.watchRestricted(query: 'R-77').first).length, 1);
      expect((await repo.watchRestricted(query: 'غير موجود').first), isEmpty);
    });
  });

  group('الشركات', () {
    test('إضافة وتعديل ومنع التكرار وربط الأصناف وفصلها عند الحذف', () async {
      final c = await repo.saveCompany(name: 'الأمل', country: 'سوريا');
      await expectLater(repo.saveCompany(name: ' الأمل '), throwsStateError);
      await expectLater(repo.saveCompany(name: '  '), throwsArgumentError);
      await repo.saveCompany(id: c, name: 'الأمل للأدوية', country: 'سوريا'); // تعديل بنفس المعرف مسموح
      final p1 = await product('أ', companyId: c);
      await product('ب', companyId: c);
      await product('ج');
      var list = await repo.watchCompanies().first;
      expect(list.single.company.name, 'الأمل للأدوية');
      expect(list.single.productCount, 2);
      expect((await repo.watchProducts(companyId: c).first).length, 2);
      await repo.deleteCompany(c);
      expect(await repo.watchCompanies().first, isEmpty);
      expect((await repo.productById(p1))!.companyId, isNull);
      expect((await repo.watchProducts().first).length, 3); // لم يُحذف أي صنف
    });
  });
}

/// مساعد لبناء بند أمر شراء في الاختبارات.
class PurchaseOrdersItemHelper {
  static PurchaseOrderItemsCompanion item(int oid, int pid, int qty, int cost) =>
      PurchaseOrderItemsCompanion.insert(orderId: oid, productId: pid, quantity: qty, unitCost: cost);
}
