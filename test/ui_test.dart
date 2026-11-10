import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasaq_market/app_state.dart';
import 'package:nasaq_market/core/business.dart';
import 'package:nasaq_market/data/database.dart';
import 'package:nasaq_market/data/repository.dart';
import 'package:nasaq_market/ui/supplier_statement_page.dart';
import 'package:nasaq_market/services/kv_store.dart';
import 'package:nasaq_market/ui/app.dart';

const money6000 = '6,000 ل.س';

Future<AppController> boot(WidgetTester t,
    {Size size = const Size(420, 900), bool activated = true, KvStore? kv, BusinessType? type = BusinessType.general}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final c = AppController(database: AppDatabase.memory(), kvStore: kv ?? MemoryKv(), forceSignedIn: activated, presetType: type);
  await t.pumpWidget(NasaqApp(controller: c));
  await t.runAsync(() => c.init());
  await t.pump(const Duration(milliseconds: 100));
  return c;
}

/// بديل pumpAndSettle: المؤشرات الدوّارة تمنع الاستقرار، وقاعدة البيانات تحتاج وقتاً حقيقياً.
Future<void> settle(WidgetTester t, {int rounds = 3}) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 120)));
    await t.pump(const Duration(milliseconds: 350));
  }
}

Future<void> finish(WidgetTester t, AppController c) async {
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  testWidgets('الهاتف: شريط سفلي وكل التبويبات تُفتح بلا أخطاء', (t) async {
    final c = await boot(t);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(NavigationRail), findsNothing);
    for (final label in ['المخزون', 'المبيعات', 'المشتريات', 'الصندوق', 'المزيد', 'الرئيسية']) {
      await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
      await t.pump(const Duration(milliseconds: 300));
      expect(t.takeException(), isNull, reason: label);
    }
    await finish(t, c);
  });

  testWidgets('التابلت: شريط جانبي', (t) async {
    final c = await boot(t, size: const Size(1100, 800));
    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(t.takeException(), isNull);
    await finish(t, c);
  });

  testWidgets('بدون تسجيل دخول تظهر شاشة Google ولا يُفتح التطبيق', (t) async {
    final c = await boot(t, activated: false);
    expect(find.text('تسجيل الدخول بحساب Google'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    await finish(t, c);
  });

  testWidgets('بعد تسجيل الدخول أول مرة يُطلب اختيار نوع النشاط ثم يُفتح التطبيق', (t) async {
    final c = await boot(t, type: null);
    expect(find.text('ما نوع نشاطك؟'), findsOneWidget);
    await t.tap(find.text('ملابس'));
    await t.pump();
    await t.enterText(find.widgetWithText(TextFormField, 'اسم المحل (يظهر في الفواتير)'), 'محل الأناقة');
    await t.tap(find.text('ابدأ'));
    await settle(t);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(c.cfg.type, BusinessType.clothes);
    expect(c.cfg.variants, isTrue);
    expect(c.store.name, 'محل الأناقة');
    // يُحفظ في قاعدة البيانات (فيدخل في النسخ الاحتياطي)
    expect((await t.runAsync(() => StoreConfig.load(c.db)))!.type, BusinessType.clothes);
    await finish(t, c);
  });

  testWidgets('عند تفعيل PIN يُطلب قبل الدخول', (t) async {
    final kv = MemoryKv();
    final c0 = AppController(kvStore: kv);
    await c0.pin.setPin('123456');
    final c = await boot(t, kv: kv);
    expect(find.text('أدخل رمز الدخول'), findsOneWidget);
    for (final d in '123456'.split('')) {
      await t.tap(find.text(d));
      await t.pump();
    }
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.byType(NavigationBar), findsOneWidget);
    await finish(t, c);
  });

  testWidgets('إضافة صنف من الواجهة يظهر في القائمة', (t) async {
    final c = await boot(t);
    await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('المخزون')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('صنف جديد'));
    await settle(t);
    await t.enterText(find.widgetWithText(TextFormField, 'اسم الصنف *'), 'أموكسيل 500');
    await t.enterText(find.widgetWithText(TextFormField, 'سعر البيع'), '7500');
    await t.tap(find.text('حفظ'));
    await settle(t);
    expect(find.text('أموكسيل 500'), findsOneWidget);
    final rows = await t.runAsync(() => c.db.select(c.db.products).get());
    expect(rows!.single.salePrice, 7500);
    await finish(t, c);
  });

  testWidgets('الحقل المطلوب يمنع الحفظ', (t) async {
    final c = await boot(t);
    await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text('المخزون')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.text('صنف جديد'));
    await settle(t);
    await t.tap(find.text('حفظ'));
    await settle(t);
    expect(find.text('هذا الحقل مطلوب'), findsOneWidget);
    await finish(t, c);
  });

  testWidgets('لوحة التحكم تعرض الأصناف القريبة من الانتهاء والأصناف المنخفضة', (t) async {
    final db = AppDatabase.memory();
    final pid = await t.runAsync(() async {
      final p = await db.into(db.products).insert(ProductsCompanion.insert(name: 'حليب تجريبي', minStock: const Value(20), trackExpiry: const Value(true)));
      await db.into(db.batches).insert(BatchesCompanion.insert(
          productId: p, quantity: const Value(5), expiry: Value(DateTime.now().add(const Duration(days: 20))), batchNo: const Value('Z9')));
      return p;
    });
    expect(pid, isNotNull);
    t.view.physicalSize = const Size(420, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final c = AppController(database: db, kvStore: MemoryKv(), forceSignedIn: true, presetType: BusinessType.supermarket);
    await t.pumpWidget(NasaqApp(controller: c));
    await t.runAsync(() => c.init());
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await t.pump(const Duration(milliseconds: 300));
    await settle(t, rounds: 4);
    expect(find.text('حليب تجريبي'), findsNWidgets(2)); // في قسم الانتهاء وقسم الانخفاض
    expect(t.takeException(), isNull);
    await finish(t, c);
  });

  Future<void> tab(WidgetTester t, String label) async {
    await t.tap(find.descendant(of: find.byType(NavigationBar), matching: find.text(label)));
    await settle(t);
  }

  testWidgets('الصندوق: إدخال رصيد افتتاحي ومصروف من الواجهة', (t) async {
    final c = await boot(t);
    await tab(t, 'الصندوق');
    expect(find.text('لا توجد حركات.\nابدأ بإدخال الرصيد الافتتاحي من «حركة جديدة».'), findsOneWidget);
    await t.tap(find.text('حركة جديدة'));
    await settle(t);
    await t.tap(find.text('رصيد افتتاحي'));
    await settle(t);
    await t.enterText(find.widgetWithText(TextFormField, 'المبلغ *'), '100000');
    await t.tap(find.text('حفظ'));
    await settle(t);
    await t.tap(find.text('حركة جديدة'));
    await settle(t);
    await t.tap(find.text('مصروف'));
    await settle(t);
    await t.enterText(find.widgetWithText(TextFormField, 'المبلغ *'), '15000');
    await t.tap(find.text('حفظ'));
    await settle(t);
    final s = await t.runAsync(() => c.repo.cashSummary());
    expect(s!.cashBalance, 85000);
    expect(find.textContaining('85,000'), findsWidgets);
    expect(t.takeException(), isNull);
    await finish(t, c);
  });

  testWidgets('الصندوق: مبلغ فارغ يُرفض', (t) async {
    final c = await boot(t);
    await tab(t, 'الصندوق');
    await t.tap(find.text('حركة جديدة'));
    await settle(t);
    await t.tap(find.text('مصروف'));
    await settle(t);
    await t.tap(find.text('حفظ'));
    await settle(t);
    expect(find.text('أدخل مبلغاً أكبر من صفر'), findsOneWidget);
    expect((await t.runAsync(() => c.repo.cashSummary()))!.totalBalance, 0);
    await finish(t, c);
  });

  testWidgets('ملابس: إنشاء توليفات المقاس واللون من نموذج الصنف', (t) async {
    final c = await boot(t, type: BusinessType.clothes);
    await tab(t, 'المخزون');
    await t.tap(find.text('صنف جديد'));
    await settle(t);
    await t.enterText(find.widgetWithText(TextFormField, 'اسم الصنف *'), 'قميص');
    await t.enterText(find.widgetWithText(TextFormField, 'سعر البيع'), '15000');
    await t.ensureVisible(find.text('M'));
    await t.tap(find.text('M'));
    await t.tap(find.text('L'));
    await t.ensureVisible(find.text('أزرق'));
    await t.tap(find.text('أزرق'));
    await t.pump();
    expect(find.text('سيُنشأ 2 صنفاً'), findsOneWidget);
    await t.enterText(find.widgetWithText(TextFormField, 'الكمية لكل متغيّر'), '4');
    await t.tap(find.text('حفظ'));
    await settle(t);
    final rows = await t.runAsync(() => Repository(c.db).watchProducts().first);
    expect(rows!.length, 2);
    expect(rows.map((r) => r.product.displayName).toSet(), {'قميص - L - أزرق', 'قميص - M - أزرق'});
    expect(rows.every((r) => r.stock == 4), isTrue);
    expect(find.text('قميص - M - أزرق'), findsOneWidget);
    expect(t.takeException(), isNull);
    await finish(t, c);
  });

  testWidgets('سوبر ماركت: فاتورة بلا اسم زبون وبكمية عشرية من الواجهة', (t) async {
    final db = AppDatabase.memory();
    await t.runAsync(() async {
      final p = await db.into(db.products).insert(ProductsCompanion.insert(name: 'جبنة', salePrice: const Value(40000), unit: const Value('كغ')));
      await db.into(db.batches).insert(BatchesCompanion.insert(productId: p, quantity: const Value(10)));
    });
    t.view.physicalSize = const Size(700, 1800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final c = AppController(database: db, kvStore: MemoryKv(), forceSignedIn: true, presetType: BusinessType.supermarket);
    await t.pumpWidget(NasaqApp(controller: c));
    await t.runAsync(() => c.init());
    await settle(t);
    await tab(t, 'المبيعات');
    await t.tap(find.text('فاتورة جديدة'));
    await settle(t);
    await t.tap(find.text('إضافة صنف'));
    await settle(t);
    await t.tap(find.text('جبنة').last);
    await settle(t);
    // تعديل الكمية إلى 2.5 كغ بالضغط على الرقم
    await t.tap(find.text('1').first);
    await settle(t);
    await t.enterText(find.byType(TextField).last, '2.5');
    await t.tap(find.text('حفظ'));
    await settle(t);
    await t.ensureVisible(find.text('حفظ الفاتورة'));
    await t.tap(find.text('حفظ الفاتورة'));
    await settle(t, rounds: 5);
    final inv = await t.runAsync(() => db.select(db.invoices).get());
    expect(inv!.length, 1);
    expect(inv.single.customerName, '');
    expect(inv.single.total, 100000);
    expect(await t.runAsync(() => c.repo.stockOf(1)), 7.5);
    expect((await t.runAsync(() => c.repo.cashSummary()))!.cashBalance, 100000);
    expect(t.takeException(), isNull);
    await finish(t, c);
  });

  testWidgets('كشف حساب المورد يعرض الرصيد المحسوب', (t) async {
    final db = AppDatabase.memory();
    late int sup;
    await t.runAsync(() async {
      final repo = Repository(db);
      sup = await repo.saveSupplier(SuppliersCompanion.insert(name: 'مورد الشام', openingBalance: const Value(1000)));
      final p = await repo.saveProduct(ProductsCompanion.insert(name: 'منتج'));
      final o = await repo.createOrder(supplierId: sup, items: [(oid) => PurchaseOrderItemsCompanion.insert(orderId: oid, productId: p, quantity: 10, unitCost: 700)]);
      await repo.receiveOrder(o, paid: 2000);
    });
    t.view.physicalSize = const Size(420, 1200);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final c = AppController(database: db, kvStore: MemoryKv(), forceSignedIn: true, presetType: BusinessType.supermarket);
    await t.pumpWidget(NasaqApp(controller: c));
    await t.runAsync(() => c.init());
    await settle(t);
    // 1000 + 7000 - 2000 = 6000
    final nav = Navigator.of(t.element(find.byType(Scaffold).first));
    nav.push(MaterialPageRoute(builder: (_) => SupplierStatementPage(supplierId: sup)));
    await settle(t, rounds: 4);
    expect(find.text('كشف حساب: مورد الشام'), findsOneWidget);
    expect(find.text(money6000), findsWidgets);
    expect(find.text('رصيد افتتاحي (ذمم سابقة)'), findsOneWidget);
    expect(find.text('أمر شراء #1'), findsOneWidget);
    expect(t.takeException(), isNull);
    await finish(t, c);
  });
}
