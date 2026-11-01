import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:excel/excel.dart';

import '../core/format.dart';

/// جدول مقروء من CSV أو Excel: ترويسة + صفوف كخرائط (اسم العمود → قيمة نصية).
class ParsedTable {
  final List<String> headers;
  final List<Map<String, String>> rows;
  const ParsedTable(this.headers, this.rows);
}

ParsedTable readTable(Uint8List bytes, String fileName) {
  final lower = fileName.toLowerCase();
  if (lower.endsWith('.xlsx')) return _fromExcel(bytes);
  return _fromCsv(bytes);
}

ParsedTable _fromCsv(Uint8List bytes) {
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.startsWith('﻿')) text = text.substring(1);
  // اكتشاف الفاصل: فاصلة أو فاصلة منقوطة أو tab
  final firstLine = text.split(RegExp(r'\r?\n')).first;
  String delim = ',';
  final counts = {',': ','.allMatches(firstLine).length, ';': ';'.allMatches(firstLine).length, '\t': '\t'.allMatches(firstLine).length};
  var best = 0;
  counts.forEach((k, v) {
    if (v > best) {
      best = v;
      delim = k;
    }
  });
  final rows = Csv(fieldDelimiter: delim, lineDelimiter: '\n')
      .decode(text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'));
  return _build([for (final r in rows) [for (final c in r) c?.toString() ?? '']]);
}

ParsedTable _fromExcel(Uint8List bytes) {
  final ex = Excel.decodeBytes(bytes);
  if (ex.tables.isEmpty) return const ParsedTable([], []);
  final sheet = ex.tables.values.first;
  final rows = <List<String>>[];
  for (final r in sheet.rows) {
    rows.add([for (final c in r) _cell(c?.value)]);
  }
  return _build(rows);
}

String _cell(CellValue? v) {
  if (v == null) return '';
  if (v is DateCellValue) {
    return '${v.year.toString().padLeft(4, '0')}-${v.month.toString().padLeft(2, '0')}-${v.day.toString().padLeft(2, '0')}';
  }
  if (v is DateTimeCellValue) {
    return '${v.year.toString().padLeft(4, '0')}-${v.month.toString().padLeft(2, '0')}-${v.day.toString().padLeft(2, '0')}';
  }
  if (v is DoubleCellValue) {
    final d = v.value;
    return d == d.roundToDouble() ? d.round().toString() : d.toString();
  }
  return v.toString().trim();
}

ParsedTable _build(List<List<String>> all) {
  final nonEmpty = all.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();
  if (nonEmpty.isEmpty) return const ParsedTable([], []);
  final headers = [for (final h in nonEmpty.first) h.trim()];
  final rows = <Map<String, String>>[];
  for (final r in nonEmpty.skip(1)) {
    final m = <String, String>{};
    for (var i = 0; i < headers.length; i++) {
      m[headers[i]] = i < r.length ? r[i].trim() : '';
    }
    rows.add(m);
  }
  return ParsedTable(headers, rows);
}

/// أسماء الأعمدة المقبولة (عربي/إنجليزي) لكل حقل.
const Map<String, List<String>> columnAliases = {
  'barcode': ['الباركود', 'باركود', 'barcode', 'gtin', 'ean'],
  'tradeName': ['الاسم التجاري', 'الاسم', 'اسم الصنف', 'trade_name', 'tradename', 'name', 'product'],
  'scientificName': ['الاسم العلمي', 'المادة الفعالة', 'scientific_name', 'scientific', 'generic'],
  'category': ['التصنيف', 'الفئة', 'category'],
  'unit': ['الوحدة', 'unit'],
  'company': ['الشركة', 'الشركة المصنعة', 'company', 'manufacturer'],
  'country': ['بلد الشركة', 'البلد', 'country'],
  'price': ['السعر المرجعي', 'السعر', 'سعر البيع', 'price', 'sale_price'],
  'cost': ['التكلفة', 'سعر التكلفة', 'cost', 'cost_price'],
  'batchNo': ['رقم الدفعة', 'الدفعة', 'التشغيلة', 'batch', 'batch_no', 'lot'],
  'quantity': ['الكمية', 'quantity', 'qty'],
  'expiry': ['تاريخ الانتهاء', 'الانتهاء', 'الصلاحية', 'expiry', 'expiry_date', 'exp'],
  'minStock': ['الحد الأدنى', 'حد الطلب', 'min_stock', 'min'],
  'location': ['موقع التخزين', 'الموقع', 'location'],
};

/// يعيد القيمة لحقل منطقي من صف، بمطابقة اسم العمود المرن.
String field(Map<String, String> row, String key) {
  final aliases = columnAliases[key] ?? [key];
  for (final h in row.keys) {
    final n = normKey(h);
    if (aliases.any((a) => normKey(a) == n)) return row[h] ?? '';
  }
  return '';
}

bool hasColumn(ParsedTable t, String key) {
  final aliases = columnAliases[key] ?? [key];
  return t.headers.any((h) => aliases.any((a) => normKey(a) == normKey(h)));
}
