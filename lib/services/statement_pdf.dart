import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/format.dart';
import '../data/repository.dart';
import 'store_info.dart';

/// كشف حساب مورد بصيغة PDF عربية.
Future<Uint8List> buildSupplierStatementPdf(
  SupplierStatement st,
  StoreInfo ph, {
  pw.Font? regular,
  pw.Font? bold,
}) async {
  regular ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Regular.ttf'));
  bold ??= pw.Font.ttf(await rootBundle.load('assets/fonts/Amiri-Bold.ttf'));
  final doc = pw.Document(theme: pw.ThemeData.withFont(base: regular, bold: bold), title: 'كشف حساب ${st.supplier.name}');

  pw.Widget cell(String t, {bool b = false, pw.TextAlign align = pw.TextAlign.right}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 5),
        child: pw.Text(t, textAlign: align, style: pw.TextStyle(fontSize: 10.5, fontWeight: b ? pw.FontWeight.bold : null)),
      );

  final owe = st.balance;
  final balanceText = owe > 0 ? 'المستحق للمورد: ${money(owe)}' : (owe < 0 ? 'رصيد لنا عند المورد: ${money(-owe)}' : 'الحساب مسدّد');

  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    textDirection: pw.TextDirection.rtl,
    margin: const pw.EdgeInsets.all(28),
    build: (ctx) => [
      pw.Text(ph.name.isEmpty ? 'نسق ماركت' : ph.name, style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
      pw.Text('كشف حساب مورد', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
      pw.Text('المورد: ${st.supplier.name}', style: const pw.TextStyle(fontSize: 12)),
      pw.Text('تاريخ الطباعة: ${dateTimeFmt(DateTime.now())}', style: const pw.TextStyle(fontSize: 10)),
      pw.Divider(),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
        columnWidths: {
          0: const pw.FlexColumnWidth(2.2),
          1: const pw.FlexColumnWidth(4),
          2: const pw.FlexColumnWidth(2),
          3: const pw.FlexColumnWidth(2),
          4: const pw.FlexColumnWidth(2.2),
        },
        children: [
          pw.TableRow(
            decoration: const pw.BoxDecoration(color: PdfColors.grey200),
            children: [
              cell('التاريخ', b: true),
              cell('البيان', b: true),
              cell('مشتريات', b: true, align: pw.TextAlign.center),
              cell('دفعات', b: true, align: pw.TextAlign.center),
              cell('الرصيد', b: true, align: pw.TextAlign.center),
            ],
          ),
          for (final r in st.rows)
            pw.TableRow(children: [
              cell(r.kind == 'opening' ? '—' : dateFmt(r.date)),
              cell(r.description),
              cell(r.debit == 0 ? '' : numFmt(r.debit), align: pw.TextAlign.center),
              cell(r.credit == 0 ? '' : numFmt(r.credit), align: pw.TextAlign.center),
              cell(numFmt(r.balance), align: pw.TextAlign.center),
            ]),
        ],
      ),
      pw.SizedBox(height: 10),
      pw.Text('إجمالي المشتريات: ${money(st.totalPurchases)}', style: const pw.TextStyle(fontSize: 11)),
      pw.Text('إجمالي الدفعات: ${money(st.totalPaid)}', style: const pw.TextStyle(fontSize: 11)),
      pw.SizedBox(height: 4),
      pw.Text(balanceText, style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
    ],
  ));
  return doc.save();
}
