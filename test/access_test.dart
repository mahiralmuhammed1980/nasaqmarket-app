import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nasaq_market/app_state.dart';
import 'package:nasaq_market/core/business.dart';
import 'package:nasaq_market/data/database.dart';
import 'package:nasaq_market/data/repository.dart';
import 'package:nasaq_market/services/access.dart';
import 'package:nasaq_market/services/kv_store.dart';
import 'package:nasaq_market/ui/app.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('سياسة الفترة المجانية', () {
    final p = AccessPolicy(DateTime(2027, 3, 1));
    test('آخر يوم مجاني يبقى مجانياً حتى نهايته', () {
      expect(p.isFree(DateTime(2027, 3, 1, 23, 59)), isTrue);
      expect(p.isFree(DateTime(2027, 3, 2)), isFalse);
      expect(p.readOnly(DateTime(2027, 3, 2)), isTrue);
      expect(p.readOnly(DateTime(2027, 1, 1)), isFalse);
    });
    test('المشترك لا يدخل وضع القراءة فقط', () {
      expect(AccessPolicy(DateTime(2027, 3, 1), subscribed: true).readOnly(DateTime(2030)), isFalse);
    });
    test('الأيام المتبقية', () {
      expect(p.daysLeft(DateTime(2027, 2, 20, 15)), 9);
      expect(p.daysLeft(DateTime(2027, 3, 1)), 0);
      expect(p.daysLeft(DateTime(2028)), 0);
    });
  });

  group('حارس الساعة', () {
    test('إرجاع ساعة الهاتف للوراء لا يعيد الفترة المجانية', () async {
      final kv = MemoryKv();
      var t = DateTime(2027, 3, 5);
      final g = ClockGuard(kv, () => t);
      expect(await g.now(), DateTime(2027, 3, 5));
      t = DateTime(2026, 12, 1); // تلاعب بالساعة
      expect(await g.now(), DateTime(2027, 3, 5));
      t = DateTime(2027, 3, 6);
      expect(await g.now(), DateTime(2027, 3, 6));
    });
  });

  group('تاريخ النهاية من الملف العام', () {
    test('التحليل والتخزين المحلي والعودة للقيمة الافتراضية', () async {
      expect(FreeUntilSource.parse('{"freeUntil":"2027-06-30"}'), DateTime(2027, 6, 30));
      expect(FreeUntilSource.parse('x'), isNull);
      expect(FreeUntilSource.parse('{"freeUntil":"bad"}'), isNull);
      final kv = MemoryKv();
      final ok = MockClient((_) async => http.Response('{"freeUntil":"2027-06-30"}', 200));
      final src = FreeUntilSource(kv, client: ok, url: 'https://x/free.json');
      expect(await src.cached(), kFreeUntil);
      expect(await src.refresh(), DateTime(2027, 6, 30));
      expect(await src.cached(), DateTime(2027, 6, 30));
      // فشل الشبكة يُبقي آخر قيمة
      final bad = FreeUntilSource(kv, client: MockClient((_) async => throw Exception('offline')), url: 'https://x/free.json');
      expect(await bad.refresh(), isNull);
      expect(await bad.cached(), DateTime(2027, 6, 30));
    });
  });

  group('وضع القراءة فقط في المستودع', () {
    test('يرفض الإضافة والتعديل ويسمح بالقراءة', () async {
      final db = AppDatabase.memory();
      var locked = false;
      final repo = Repository(db, isLocked: () => locked);
      final p = await repo.saveProduct(ProductsCompanion.insert(name: 'أ', salePrice: const Value(100)));
      await repo.saveBatch(BatchesCompanion.insert(productId: p, quantity: const Value(5)));
      locked = true;
      expect(() => repo.saveProduct(ProductsCompanion.insert(name: 'ب')), throwsA(isA<ReadOnlyMode>()));
      expect(() => repo.saveBatch(BatchesCompanion.insert(productId: p)), throwsA(isA<ReadOnlyMode>()));
      expect(() => repo.createInvoice(lines: [InvoiceLine(p, 1, 100)]), throwsA(isA<ReadOnlyMode>()));
      expect(() => repo.addManualEntry(kind: 'expense', amount: 5), throwsA(isA<ReadOnlyMode>()));
      expect(() => repo.saveSupplier(SuppliersCompanion.insert(name: 'م')), throwsA(isA<ReadOnlyMode>()));
      expect(() => repo.closeDay(0), throwsA(isA<ReadOnlyMode>()));
      expect(await repo.stockOf(p), 5); // القراءة تعمل
      expect((await repo.watchProducts().first).length, 1);
      locked = false;
      await repo.createInvoice(lines: [InvoiceLine(p, 1, 100)]);
      expect(await repo.stockOf(p), 4);
      await db.close();
    });
  });

  Future<AppController> boot(WidgetTester t, DateTime now, {DateTime? until}) async {
    t.view.physicalSize = const Size(420, 900);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final c = AppController(
        database: AppDatabase.memory(),
        kvStore: MemoryKv(),
        forceSignedIn: true,
        presetType: BusinessType.general,
        freeUntil: until ?? DateTime(2027, 3, 1),
        clock: () => now);
    await t.pumpWidget(NasaqApp(controller: c));
    await t.runAsync(() => c.init());
    await t.pump(const Duration(milliseconds: 200));
    return c;
  }

  testWidgets('خلال الفترة المجانية يظهر شريط «مجاني حتى»', (t) async {
    final c = await boot(t, DateTime(2027, 2, 20));
    expect(find.textContaining('مجاني حتى 2027-03-01 (باقي 9 يوم)'), findsOneWidget);
    expect(c.readOnly, isFalse);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 50));
  });

  testWidgets('بعد الانتهاء: شريط القراءة فقط ومنع زر الإضافة', (t) async {
    final c = await boot(t, DateTime(2027, 3, 10));
    expect(c.readOnly, isTrue);
    expect(find.textContaining('انتهت الفترة المجانية'), findsOneWidget);
    await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('المبيعات')));
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 120)));
    await t.pump(const Duration(milliseconds: 350));
    await t.tap(find.text('فاتورة جديدة'));
    await t.pump(const Duration(milliseconds: 350));
    expect(find.text('حفظ الفاتورة'), findsNothing); // لم تُفتح شاشة الفاتورة
    expect(find.textContaining('للقراءة والتصدير فقط'), findsWidgets);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 50));
  });
}
