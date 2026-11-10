import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:nasaq_market/data/database.dart';
import 'package:nasaq_market/data/repository.dart';

/// اختبار أداء: 10 آلاف صنف و30 ألف دفعة. الحدود واسعة عمداً لتجنب عدم الاستقرار على CI.
void main() {
  test('أداء البحث ولوحة التحكم والفاتورة مع 10 آلاف صنف', () async {
    final db = AppDatabase.memory();
    final repo = Repository(db);
    final now = DateTime.now();
    await db.batch((b) {
      b.insertAll(db.products, [
        for (var i = 0; i < 10000; i++)
          ProductsCompanion.insert(
              name: 'صنف $i', barcode: Value('62210${i.toString().padLeft(8, '0')}'), salePrice: const Value(1000), minStock: const Value(5), trackExpiry: const Value(true))
      ]);
    });
    await db.batch((b) {
      b.insertAll(db.batches, [
        for (var i = 1; i <= 10000; i++)
          for (var k = 0; k < 3; k++)
            BatchesCompanion.insert(
                productId: i,
                quantity: const Value(10),
                batchNo: Value('B$k'),
                expiry: Value(now.add(Duration(days: 30 + i % 700 + k * 100))))
      ]);
    });

    final sw = Stopwatch()..start();
    final found = await repo.watchProducts(query: 'صنف 777').first;
    final tSearch = sw.elapsedMilliseconds;
    expect(found, isNotEmpty);

    sw.reset();
    final byCode = await repo.productByBarcode('6221000005000');
    final tBarcode = sw.elapsedMilliseconds;
    expect(byCode, isNotNull);

    sw.reset();
    final expiring = await repo.expiringBatches();
    final tDash = sw.elapsedMilliseconds;
    expect(expiring, isNotEmpty);

    sw.reset();
    final inv = await repo.createInvoice(customerName: 'س', lines: [for (var i = 1; i <= 20; i++) InvoiceLine(i * 100, 2, 1000)]);
    final tInvoice = sw.elapsedMilliseconds;
    expect(inv.total, 40000);

    // ignore: avoid_print
    print('أداء (مللي ثانية): بحث=$tSearch باركود=$tBarcode لوحة=$tDash فاتورة20بنداً=$tInvoice');
    expect(tSearch, lessThan(3000));
    expect(tBarcode, lessThan(500));
    expect(tDash, lessThan(3000));
    expect(tInvoice, lessThan(3000));
    await db.close();
  });
}
