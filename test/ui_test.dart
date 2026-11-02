import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasaq_pharma/app_state.dart';
import 'package:nasaq_pharma/data/database.dart';
import 'package:nasaq_pharma/services/kv_store.dart';
import 'package:nasaq_pharma/ui/app.dart';

Future<AppController> boot(WidgetTester t, {Size size = const Size(420, 900), bool activated = true, KvStore? kv}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  final c = AppController(database: AppDatabase.memory(), kvStore: kv ?? MemoryKv(), forceActivated: activated);
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
    for (final label in ['المخزون', 'المبيعات', 'المشتريات', 'البيانات', 'الإعدادات', 'الرئيسية']) {
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

  testWidgets('بدون تفعيل تظهر شاشة تسجيل الدخول', (t) async {
    final c = await boot(t, activated: false);
    expect(find.text('تسجيل الدخول بحساب Google'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
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
    await t.enterText(find.widgetWithText(TextFormField, 'الاسم التجاري *'), 'أموكسيل 500');
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

  testWidgets('لوحة التحكم تعرض الدفعات القريبة من الانتهاء والأصناف المنخفضة', (t) async {
    final db = AppDatabase.memory();
    final pid = await t.runAsync(() async {
      final p = await db.into(db.products).insert(ProductsCompanion.insert(name: 'دواء تجريبي', minStock: const Value(20)));
      await db.into(db.batches).insert(BatchesCompanion.insert(
          productId: p, quantity: const Value(5), expiry: Value(DateTime.now().add(const Duration(days: 20))), batchNo: const Value('Z9')));
      return p;
    });
    expect(pid, isNotNull);
    t.view.physicalSize = const Size(420, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final c = AppController(database: db, kvStore: MemoryKv(), forceActivated: true);
    await t.pumpWidget(NasaqApp(controller: c));
    await t.runAsync(() => c.init());
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await t.pump(const Duration(milliseconds: 300));
    await settle(t, rounds: 4);
    expect(find.text('دواء تجريبي'), findsNWidgets(2)); // في قسم الانتهاء وقسم الانخفاض
    expect(t.takeException(), isNull);
    await finish(t, c);
  });
}
