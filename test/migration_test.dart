import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nasaq_pharma/data/database.dart';

import 'generated_migrations/schema.dart';

void main() {
  late SchemaVerifier verifier;
  setUpAll(() => verifier = SchemaVerifier(GeneratedHelper()));

  test('الترحيل من الإصدار 1 إلى 2 يحفظ بيانات الزبون كاملة', () async {
    final schema = await verifier.schemaAt(1);
    final raw = schema.rawDatabase;
    raw.execute("INSERT INTO suppliers(name, phone) VALUES ('مورد قديم', '011')");
    raw.execute("INSERT INTO products(name, sale_price, cost_price, barcode) VALUES ('بنادول', 5000, 4000, '6221000000011')");
    raw.execute("INSERT INTO batches(product_id, batch_no, quantity, expiry) VALUES (1, 'B1', 25, strftime('%s','2027-12-31'))");
    raw.execute("INSERT INTO invoices(number, created_at, patient_name, subtotal, total, paid_amount) "
        "VALUES ('INV-000001', strftime('%s','now'), 'أحمد', 10000, 10000, 10000)");
    raw.execute("INSERT INTO invoice_items(invoice_id, product_id, product_name, quantity, unit_price, line_total) "
        "VALUES (1, 1, 'بنادول', 2, 5000, 10000)");
    raw.execute("INSERT INTO app_settings(key, value) VALUES ('pharmacy_name', 'صيدلية الأمل')");
    raw.execute("INSERT INTO app_settings(key, value) VALUES ('invoice_counter', '1')");

    final db = AppDatabase(schema.newConnection());
    await verifier.migrateAndValidate(db, 2); // يتحقق أيضاً أن المخطط النهائي مطابق تماماً
    // البيانات القديمة سليمة
    final p = await db.select(db.products).getSingle();
    expect(p.name, 'بنادول');
    expect(p.salePrice, 5000);
    expect(p.isRestricted, isFalse); // قيمة افتراضية للأعمدة الجديدة
    expect(p.companyId, isNull);
    expect((await db.select(db.batches).getSingle()).quantity, 25);
    expect((await db.select(db.invoices).getSingle()).total, 10000);
    expect((await db.select(db.invoiceItems).getSingle()).lineTotal, 10000);
    expect((await db.select(db.suppliers).getSingle()).openingBalance, 0);
    expect(await db.getSetting('pharmacy_name'), 'صيدلية الأمل');
    // الجداول الجديدة موجودة وفارغة
    expect(await db.select(db.cashEntries).get(), isEmpty);
    expect(await db.select(db.restrictedRecords).get(), isEmpty);
    expect(await db.select(db.cashClosings).get(), isEmpty);
    // ترقيم الفواتير يستمر دون تكرار
    expect(await db.nextInvoiceNumber(), 'INV-000002');
    await db.close();
  });
}
