import 'package:drift/drift.dart';

import 'database.dart';

class InsufficientStock implements Exception {
  final String productName;
  final int requested, available;
  InsufficientStock(this.productName, this.requested, this.available);
  @override
  String toString() =>
      'الكمية غير كافية للصنف "$productName": المطلوب $requested والمتاح $available';
}

class InvoiceLine {
  final int productId;
  final int quantity;
  final int unitPrice;
  const InvoiceLine(this.productId, this.quantity, this.unitPrice);
}

class ProductStock {
  final Product product;
  final int stock;
  final DateTime? nearestExpiry;
  const ProductStock(this.product, this.stock, this.nearestExpiry);
  bool get low => stock <= product.minStock;
}

class BatchInfo {
  final StockBatch batch;
  final Product product;
  const BatchInfo(this.batch, this.product);
  int get daysToExpiry => batch.expiry == null
      ? 99999
      : batch.expiry!.difference(DateTime.now()).inDays;
}

/// طبقة العمليات على قاعدة البيانات: المخزون، المبيعات، المشتريات.
class Repository {
  final AppDatabase db;
  Repository(this.db);

  // ───────── الموردون ─────────
  Stream<List<Supplier>> watchSuppliers() =>
      (db.select(db.suppliers)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();
  Future<int> saveSupplier(SuppliersCompanion s) =>
      db.into(db.suppliers).insertOnConflictUpdate(s);
  Future<void> deleteSupplier(int id) async {
    final used = await (db.select(db.purchaseOrders)..where((t) => t.supplierId.equals(id))).get();
    if (used.isNotEmpty) {
      throw StateError('لا يمكن حذف مورد لديه أوامر شراء');
    }
    await (db.update(db.products)..where((t) => t.defaultSupplierId.equals(id)))
        .write(const ProductsCompanion(defaultSupplierId: Value(null)));
    await (db.update(db.batches)..where((t) => t.supplierId.equals(id)))
        .write(const BatchesCompanion(supplierId: Value(null)));
    await (db.delete(db.suppliers)..where((t) => t.id.equals(id))).go();
  }

  // ───────── الأصناف ─────────
  Future<int> saveProduct(ProductsCompanion p) =>
      db.into(db.products).insertOnConflictUpdate(p);

  Future<Product?> productById(int id) =>
      (db.select(db.products)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Product?> productByBarcode(String code) async {
    for (final v in _variants(code)) {
      final r = await (db.select(db.products)
            ..where((t) => t.barcode.equals(v) & t.archived.equals(false)))
          .get();
      if (r.isNotEmpty) return r.first;
    }
    return null;
  }

  List<String> _variants(String code) {
    final c = code.trim();
    final out = <String>{c};
    if (c.length == 14 && c.startsWith('0')) out.add(c.substring(1));
    if (c.length == 13) out.add('0$c');
    return out.toList();
  }

  /// يؤرشف الصنف إن كانت له حركات، وإلا يحذفه.
  Future<void> deleteProduct(int id) async {
    final hasItems = await (db.select(db.invoiceItems)..where((t) => t.productId.equals(id))).get();
    final hasPo = await (db.select(db.purchaseOrderItems)..where((t) => t.productId.equals(id))).get();
    await db.transaction(() async {
      if (hasItems.isNotEmpty || hasPo.isNotEmpty) {
        await (db.update(db.products)..where((t) => t.id.equals(id)))
            .write(const ProductsCompanion(archived: Value(true)));
        await (db.update(db.batches)..where((t) => t.productId.equals(id)))
            .write(const BatchesCompanion(quantity: Value(0)));
      } else {
        await (db.delete(db.batches)..where((t) => t.productId.equals(id))).go();
        await (db.delete(db.products)..where((t) => t.id.equals(id))).go();
      }
    });
  }

  /// الأصناف مع مجموع الكمية وأقرب انتهاء، مع بحث اختياري (اسم/علمي/باركود).
  Stream<List<ProductStock>> watchProducts({String query = ''}) {
    final q = db.select(db.products)
      ..where((t) => t.archived.equals(false))
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);
    final qs = query.trim();
    if (qs.isNotEmpty) {
      q.where((t) =>
          t.name.like('%$qs%') |
          t.scientificName.like('%$qs%') |
          t.barcode.like('%$qs%'));
    }
    return q.watch().asyncMap((products) async {
      final batches = await db.select(db.batches).get();
      final qty = <int, int>{};
      final exp = <int, DateTime>{};
      for (final b in batches) {
        if (b.quantity <= 0) continue;
        qty[b.productId] = (qty[b.productId] ?? 0) + b.quantity;
        if (b.expiry != null) {
          final cur = exp[b.productId];
          if (cur == null || b.expiry!.isBefore(cur)) exp[b.productId] = b.expiry!;
        }
      }
      return [for (final p in products) ProductStock(p, qty[p.id] ?? 0, exp[p.id])];
    });
  }

  Future<int> stockOf(int productId) async {
    final r = await (db.select(db.batches)..where((t) => t.productId.equals(productId))).get();
    return r.fold<int>(0, (a, b) => a + b.quantity);
  }

  // ───────── الدفعات ─────────
  Stream<List<StockBatch>> watchBatches(int productId) => (db.select(db.batches)
        ..where((t) => t.productId.equals(productId))
        ..orderBy([(t) => OrderingTerm.asc(t.expiry)]))
      .watch();
  Future<int> saveBatch(BatchesCompanion b) =>
      db.into(db.batches).insertOnConflictUpdate(b);
  Future<void> deleteBatch(int id) async {
    final used = await (db.select(db.invoiceItemBatches)..where((t) => t.batchId.equals(id))).get();
    if (used.isNotEmpty) {
      // دفعة سبق البيع منها: نصفّر الكمية بدل الحذف لحفظ سجل الفواتير.
      await (db.update(db.batches)..where((t) => t.id.equals(id)))
          .write(const BatchesCompanion(quantity: Value(0)));
    } else {
      await (db.delete(db.batches)..where((t) => t.id.equals(id))).go();
    }
  }

  // ───────── لوحة التحكم ─────────
  Future<List<BatchInfo>> expiringBatches({int withinDays = 90}) async {
    final limit = DateTime.now().add(Duration(days: withinDays));
    final rows = await (db.select(db.batches).join([
      innerJoin(db.products, db.products.id.equalsExp(db.batches.productId)),
    ])
          ..where(db.batches.quantity.isBiggerThanValue(0) &
              db.batches.expiry.isNotNull() &
              db.batches.expiry.isSmallerOrEqualValue(limit) &
              db.products.archived.equals(false))
          ..orderBy([OrderingTerm.asc(db.batches.expiry)]))
        .get();
    return [for (final r in rows) BatchInfo(r.readTable(db.batches), r.readTable(db.products))];
  }

  Future<List<ProductStock>> lowStock() async {
    final all = await watchProducts().first;
    return all.where((p) => p.low && p.product.minStock > 0).toList();
  }

  Future<int> inventoryValueAtCost() async {
    final bs = await db.select(db.batches).get();
    return bs.fold<int>(0, (a, b) => a + b.quantity * b.cost);
  }

  // ───────── المبيعات ─────────

  /// إنشاء فاتورة: داخل معاملة واحدة، يخصم من الدفعات الأقرب انتهاءً (FEFO)
  /// متجاهلاً المنتهية. أي فشل يُلغي كل شيء.
  Future<Invoice> createInvoice({
    required String patientName,
    String patientPhone = '',
    required List<InvoiceLine> lines,
    int discount = 0,
    String paymentMethod = 'cash',
    int? paidAmount,
    String notes = '',
    DateTime? now,
  }) {
    if (lines.isEmpty) throw ArgumentError('الفاتورة بلا أصناف');
    final when = now ?? DateTime.now();
    return db.transaction(() async {
      var subtotal = 0;
      final number = await db.nextInvoiceNumber();
      // نحجز رقم الفاتورة بإدراج رأسها أولاً بقيم مؤقتة ثم نحدّثها.
      final invId = await db.into(db.invoices).insert(InvoicesCompanion.insert(
            number: number,
            createdAt: when,
            patientName: patientName,
            patientPhone: Value(patientPhone),
            subtotal: 0,
            total: 0,
            paymentMethod: Value(paymentMethod),
            notes: Value(notes),
          ));
      for (final l in lines) {
        if (l.quantity <= 0) throw ArgumentError('كمية غير صالحة');
        final product = await productById(l.productId);
        if (product == null) throw StateError('صنف غير موجود');
        final batches = await (db.select(db.batches)
              ..where((t) => t.productId.equals(l.productId) & t.quantity.isBiggerThanValue(0))
              ..orderBy([
                // الأقرب انتهاءً أولاً، والبلا تاريخ في الآخر
                (t) => OrderingTerm(expression: t.expiry.isNull()),
                (t) => OrderingTerm.asc(t.expiry),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
        final usable = batches.where((b) => b.expiry == null || !b.expiry!.isBefore(DateTime(when.year, when.month, when.day))).toList();
        final available = usable.fold<int>(0, (a, b) => a + b.quantity);
        if (available < l.quantity) {
          throw InsufficientStock(product.name, l.quantity, available);
        }
        final itemId = await db.into(db.invoiceItems).insert(InvoiceItemsCompanion.insert(
              invoiceId: invId,
              productId: Value(l.productId),
              productName: product.name,
              quantity: l.quantity,
              unitPrice: l.unitPrice,
              unitCost: Value(product.costPrice),
              lineTotal: l.quantity * l.unitPrice,
            ));
        var remaining = l.quantity;
        for (final b in usable) {
          if (remaining == 0) break;
          final take = remaining < b.quantity ? remaining : b.quantity;
          await (db.update(db.batches)..where((t) => t.id.equals(b.id)))
              .write(BatchesCompanion(quantity: Value(b.quantity - take)));
          await db.into(db.invoiceItemBatches).insert(InvoiceItemBatchesCompanion.insert(
              invoiceItemId: itemId, batchId: b.id, quantity: take));
          remaining -= take;
        }
        subtotal += l.quantity * l.unitPrice;
      }
      if (discount < 0 || discount > subtotal) {
        throw ArgumentError('خصم غير صالح');
      }
      final total = subtotal - discount;
      final paid = paidAmount ?? total;
      final status = paid >= total ? 'paid' : (paid <= 0 ? 'unpaid' : 'partial');
      await (db.update(db.invoices)..where((t) => t.id.equals(invId))).write(
          InvoicesCompanion(
              subtotal: Value(subtotal),
              discount: Value(discount),
              total: Value(total),
              paidAmount: Value(paid > total ? total : paid),
              paymentStatus: Value(status)));
      return (db.select(db.invoices)..where((t) => t.id.equals(invId))).getSingle();
    });
  }

  /// حذف فاتورة مع إرجاع الكميات إلى الدفعات التي خُصمت منها.
  Future<void> voidInvoice(int invoiceId) => db.transaction(() async {
        final items = await (db.select(db.invoiceItems)..where((t) => t.invoiceId.equals(invoiceId))).get();
        for (final it in items) {
          final allocs = await (db.select(db.invoiceItemBatches)..where((t) => t.invoiceItemId.equals(it.id))).get();
          for (final a in allocs) {
            final b = await (db.select(db.batches)..where((t) => t.id.equals(a.batchId))).getSingleOrNull();
            if (b != null) {
              await (db.update(db.batches)..where((t) => t.id.equals(b.id)))
                  .write(BatchesCompanion(quantity: Value(b.quantity + a.quantity)));
            }
          }
          await (db.delete(db.invoiceItemBatches)..where((t) => t.invoiceItemId.equals(it.id))).go();
        }
        await (db.delete(db.invoiceItems)..where((t) => t.invoiceId.equals(invoiceId))).go();
        await (db.delete(db.invoices)..where((t) => t.id.equals(invoiceId))).go();
      });

  Future<void> settleInvoice(int invoiceId) async {
    final inv = await (db.select(db.invoices)..where((t) => t.id.equals(invoiceId))).getSingle();
    await (db.update(db.invoices)..where((t) => t.id.equals(invoiceId))).write(
        InvoicesCompanion(paidAmount: Value(inv.total), paymentStatus: const Value('paid')));
  }

  Stream<List<Invoice>> watchInvoices({String query = ''}) {
    final q = db.select(db.invoices)..orderBy([(t) => OrderingTerm.desc(t.createdAt), (t) => OrderingTerm.desc(t.id)]);
    final qs = query.trim();
    if (qs.isNotEmpty) {
      q.where((t) => t.patientName.like('%$qs%') | t.number.like('%$qs%') | t.patientPhone.like('%$qs%'));
    }
    return q.watch();
  }

  Future<List<InvoiceItem>> invoiceItems(int invoiceId) =>
      (db.select(db.invoiceItems)..where((t) => t.invoiceId.equals(invoiceId))).get();

  Future<int> salesTotalSince(DateTime from) async {
    final r = await (db.select(db.invoices)..where((t) => t.createdAt.isBiggerOrEqualValue(from))).get();
    return r.fold<int>(0, (a, b) => a + b.total);
  }

  // ───────── المشتريات ─────────
  Stream<List<PurchaseOrder>> watchOrders() => (db.select(db.purchaseOrders)
        ..orderBy([(t) => OrderingTerm.desc(t.createdAt), (t) => OrderingTerm.desc(t.id)]))
      .watch();

  Future<List<PurchaseOrderItem>> orderItems(int orderId) =>
      (db.select(db.purchaseOrderItems)..where((t) => t.orderId.equals(orderId))).get();

  Future<int> createOrder({
    required int supplierId,
    required List<PurchaseOrderItemsCompanion Function(int orderId)> items,
    String notes = '',
    String status = 'draft',
  }) =>
      db.transaction(() async {
        final id = await db.into(db.purchaseOrders).insert(PurchaseOrdersCompanion.insert(
            supplierId: supplierId,
            createdAt: DateTime.now(),
            status: Value(status),
            notes: Value(notes)));
        for (final f in items) {
          await db.into(db.purchaseOrderItems).insert(f(id));
        }
        return id;
      });

  Future<void> setOrderStatus(int orderId, String status) async {
    final o = await (db.select(db.purchaseOrders)..where((t) => t.id.equals(orderId))).getSingle();
    if (o.status == 'received') throw StateError('الأمر مستلم سابقاً');
    await (db.update(db.purchaseOrders)..where((t) => t.id.equals(orderId)))
        .write(PurchaseOrdersCompanion(status: Value(status)));
  }

  Future<void> deleteOrder(int orderId) async {
    final o = await (db.select(db.purchaseOrders)..where((t) => t.id.equals(orderId))).getSingle();
    if (o.status == 'received') throw StateError('لا يمكن حذف أمر مستلم');
    await db.transaction(() async {
      await (db.delete(db.purchaseOrderItems)..where((t) => t.orderId.equals(orderId))).go();
      await (db.delete(db.purchaseOrders)..where((t) => t.id.equals(orderId))).go();
    });
  }

  /// استلام الأمر: كل بند يتحول إلى دفعة في المخزون، مرة واحدة فقط.
  Future<void> receiveOrder(int orderId) => db.transaction(() async {
        final o = await (db.select(db.purchaseOrders)..where((t) => t.id.equals(orderId))).getSingle();
        if (o.status == 'received') throw StateError('الأمر مستلم سابقاً');
        if (o.status == 'cancelled') throw StateError('الأمر ملغى');
        final items = await orderItems(orderId);
        for (final it in items) {
          await db.into(db.batches).insert(BatchesCompanion.insert(
                productId: it.productId,
                batchNo: Value(it.batchNo),
                quantity: Value(it.quantity),
                expiry: Value(it.expiry),
                cost: Value(it.unitCost),
                supplierId: Value(o.supplierId),
                notes: Value('أمر شراء #$orderId'),
              ));
          // تحديث آخر تكلفة للصنف
          await (db.update(db.products)..where((t) => t.id.equals(it.productId)))
              .write(ProductsCompanion(costPrice: Value(it.unitCost)));
        }
        await (db.update(db.purchaseOrders)..where((t) => t.id.equals(orderId))).write(
            PurchaseOrdersCompanion(status: const Value('received'), receivedAt: Value(DateTime.now())));
      });

  int orderTotal(List<PurchaseOrderItem> items) =>
      items.fold<int>(0, (a, i) => a + i.quantity * i.unitCost);
}
