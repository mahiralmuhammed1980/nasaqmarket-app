import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import 'schema_versions.dart';
import 'tables.dart';

part 'database.g.dart';

/// رقم مخطط قاعدة البيانات. ارفعه عند كل تعديل في الجداول وأضف خطوة في [onUpgrade].
const int kSchemaVersion = 2;

@DriftDatabase(tables: [
  CatalogCompanies,
  CatalogDrugs,
  Suppliers,
  Products,
  Batches,
  PurchaseOrders,
  PurchaseOrderItems,
  Invoices,
  InvoiceItems,
  InvoiceItemBatches,
  AppSettings,
  CashEntries,
  CashClosings,
  RestrictedRecords,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// قاعدة بيانات في ذاكرة مؤقتة للاختبارات.
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => kSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createIndexes();
        },
        // ترحيل خطوة بخطوة يحفظ بيانات الزبائن. عند رفع kSchemaVersion:
        //  1) عدّل tables.dart  2) dart run drift_dev schema dump ... drift_schemas/drift_schema_vN.json
        //  3) dart run drift_dev schema steps drift_schemas lib/data/schema_versions.dart
        //  4) أضف الخطوة هنا  5) dart run drift_dev schema generate drift_schemas test/generated_migrations
        onUpgrade: (m, from, to) async {
          await stepByStep(
            from1To2: (m, schema) async {
              await m.addColumn(schema.suppliers, schema.suppliers.openingBalance);
              await m.addColumn(schema.products, schema.products.companyId);
              await m.addColumn(schema.products, schema.products.isRestricted);
              await m.createTable(schema.cashEntries);
              await m.createTable(schema.cashClosings);
              await m.createTable(schema.restrictedRecords);
            },
          )(m, from, to);
          await _createIndexes();
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  Future<void> _createIndexes() async {
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_batches_product ON batches(product_id)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_batches_expiry ON batches(expiry)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_products_barcode ON products(barcode)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_invoice_items_invoice ON invoice_items(invoice_id)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_cash_created ON cash_entries(created_at)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_cash_supplier ON cash_entries(supplier_id)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_restricted_created ON restricted_records(created_at)');
  }

  // ───────── إعدادات ─────────
  Future<String?> getSetting(String key) async {
    final row = await (select(appSettings)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String value) =>
      into(appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: key, value: value));

  /// ينشئ رقم الفاتورة التالي داخل المعاملة الحالية.
  Future<String> nextInvoiceNumber() async {
    final cur = int.tryParse(await getSetting('invoice_counter') ?? '0') ?? 0;
    final next = cur + 1;
    await setSetting('invoice_counter', '$next');
    return 'INV-${next.toString().padLeft(6, '0')}';
  }
}

Future<File> databaseFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File(p.join(dir.path, 'nasaq_pharma.sqlite'));
}

AppDatabase openAppDatabase() =>
    AppDatabase(LazyDatabase(() async => NativeDatabase.createInBackground(await databaseFile())));
