import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/format.dart';
import '../data/database.dart';
import 'pharmacy_info.dart';

String paymentMethodLabel(String m) => switch (m) {
      'cash' => 'نقداً',
      'card' => 'بطاقة',
      'transfer' => 'حوالة',
      'credit' => 'آجل',
      _ => m,
    };

String paymentStatusLabel(String s) => switch (s) {
      'paid' => 'مدفوعة',
      'partial' => 'مدفوعة جزئياً',
      'unpaid' => 'غير مدفوعة',
      _ => s,
    };

Future<Uint8List> buildInvoicePdf(
  Invoice inv,
  List<InvoiceItem> items,
  PharmacyInfo ph, {
  pw.Font? regular,
  pw.Font? bold,
}) async {
  regular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Regular.ttf'));
  bold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Bold.ttf'));
  final theme = pw.ThemeData.withFont(base: regular, bold: bold);
  final doc = pw.Document(theme: theme, title: 'فاتورة ${inv.number}');
  final logo = ph.logo == null ? null : pw.MemoryImage(ph.logo!);

  pw.Widget cell(String t, {bool b = false, pw.TextAlign align = pw.TextAlign.right}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 6),
        child: pw.Text(t,
            textAlign: align,
            style: pw.TextStyle(fontSize: 11, fontWeight: b ? pw.FontWeight.bold : null)),
      );

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a5,
    textDirection: pw.TextDirection.rtl,
    margin: const pw.EdgeInsets.all(24),
    build: (ctx) => [
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        if (logo != null)
          pw.Container(
              width: 56, height: 56, margin: const pw.EdgeInsets.only(left: 12),
              child: pw.Image(logo, fit: pw.BoxFit.contain)),
        pw.Expanded(
          child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text(ph.name.isEmpty ? 'صيدلية' : ph.name,
                style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold)),
            if (ph.address.isNotEmpty) pw.Text(ph.address, style: const pw.TextStyle(fontSize: 10)),
            if (ph.phone.isNotEmpty)
              pw.Text('هاتف: ${ph.phone}', style: const pw.TextStyle(fontSize: 10)),
          ]),
        ),
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
          pw.Text('فاتورة', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.Text(inv.number, style: const pw.TextStyle(fontSize: 11)),
          pw.Text(dateTimeFmt(inv.createdAt), style: const pw.TextStyle(fontSize: 10)),
        ]),
      ]),
      pw.Divider(),
      pw.Text('المريض: ${inv.patientName}', style: const pw.TextStyle(fontSize: 12)),
      if (inv.patientPhone.isNotEmpty)
        pw.Text('الهاتف: ${inv.patientPhone}', style: const pw.TextStyle(fontSize: 11)),
      pw.SizedBox(height: 8),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
        columnWidths: {
          0: const pw.FlexColumnWidth(4),
          1: const pw.FlexColumnWidth(1.2),
          2: const pw.FlexColumnWidth(2),
          3: const pw.FlexColumnWidth(2),
        },
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey200),
            children: [
              cell('الصنف', b: true),
              cell('الكمية', b: true, align: pw.TextAlign.center),
              cell('السعر', b: true, align: pw.TextAlign.center),
              cell('الإجمالي', b: true, align: pw.TextAlign.center),
            ],
          ),
          for (final it in items)
            pw.TableRow(children: [
              cell(it.productName),
              cell(numFmt(it.quantity), align: pw.TextAlign.center),
              cell(numFmt(it.unitPrice), align: pw.TextAlign.center),
              cell(numFmt(it.lineTotal), align: pw.TextAlign.center),
            ]),
        ],
      ),
      pw.SizedBox(height: 8),
      pw.Align(
        alignment: pw.Alignment.centerLeft,
        child: pw.Container(
          width: 200,
          child: pw.Column(children: [
            _kv('المجموع', money(inv.subtotal)),
            if (inv.discount > 0) _kv('الخصم', money(inv.discount)),
            _kv('الإجمالي', money(inv.total), bold: true),
            _kv('طريقة الدفع', paymentMethodLabel(inv.paymentMethod)),
            _kv('حالة الدفع', paymentStatusLabel(inv.paymentStatus)),
            if (inv.paymentStatus != 'paid') _kv('المتبقي', money(inv.total - inv.paidAmount)),
          ]),
        ),
      ),
      if (inv.notes.isNotEmpty) ...[
        pw.SizedBox(height: 6),
        pw.Text('ملاحظات: ${inv.notes}', style: const pw.TextStyle(fontSize: 10)),
      ],
      pw.SizedBox(height: 12),
      pw.Center(child: pw.Text('نتمنى لكم الشفاء العاجل', style: const pw.TextStyle(fontSize: 10))),
    ],
  ));
  return doc.save();
}

pw.Widget _kv(String k, String v, {bool bold = false}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
      child: pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
        pw.Text(k, style: pw.TextStyle(fontSize: 11, fontWeight: bold ? pw.FontWeight.bold : null)),
        pw.Text(v, style: pw.TextStyle(fontSize: 11, fontWeight: bold ? pw.FontWeight.bold : null)),
      ]),
    );
