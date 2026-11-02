import 'package:intl/intl.dart';

final _numFmt = NumberFormat('#,##0', 'en');

/// تنسيق المبلغ بالليرة السورية (أعداد صحيحة بلا كسور).
String money(int v) => '${_numFmt.format(v)} ل.س';
String numFmt(int v) => _numFmt.format(v);

String _2(int n) => n.toString().padLeft(2, '0');

String dateFmt(DateTime? d) =>
    d == null ? '—' : '${d.year.toString().padLeft(4, '0')}-${_2(d.month)}-${_2(d.day)}';
String dateTimeFmt(DateTime d) => '${dateFmt(d)} ${_2(d.hour)}:${_2(d.minute)}';

/// يحوّل الأرقام العربية/الفارسية إلى لاتينية.
String normalizeDigits(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  const fa = '۰۱۲۳۴۵۶۷۸۹';
  final b = StringBuffer();
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    var i = ar.indexOf(c);
    if (i < 0) i = fa.indexOf(c);
    b.write(i >= 0 ? '$i' : c);
  }
  return b.toString();
}

/// يقرأ عدداً صحيحاً من نص (يتجاهل الفواصل والمسافات). null إن فشل.
int? parseInt(String? s) {
  if (s == null) return null;
  final t = normalizeDigits(s).replaceAll(RegExp(r'[,\s٬]'), '');
  if (t.isEmpty) return null;
  return int.tryParse(t) ?? double.tryParse(t)?.round();
}

/// يقرأ تاريخاً بصيغ: yyyy-MM-dd، dd/MM/yyyy، MM/yyyy، yyyy/MM. null إن فشل.
/// تاريخ "شهر/سنة" يُعتبر آخر يوم في الشهر (كما هو متعارف في الأدوية).
DateTime? parseDate(String? s) {
  if (s == null) return null;
  final t = normalizeDigits(s).trim();
  if (t.isEmpty) return null;
  var m = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})').firstMatch(t);
  if (m != null) return _safe(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));
  m = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$').firstMatch(t);
  if (m != null) return _safe(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!));
  m = RegExp(r'^(\d{1,2})[-/.](\d{4})$').firstMatch(t);
  if (m != null) return _endOfMonth(int.parse(m[2]!), int.parse(m[1]!));
  m = RegExp(r'^(\d{4})[-/.](\d{1,2})$').firstMatch(t);
  if (m != null) return _endOfMonth(int.parse(m[1]!), int.parse(m[2]!));
  return null;
}

DateTime? _safe(int y, int mo, int d) {
  if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
  final dt = DateTime(y, mo, d);
  return dt.month == mo ? dt : null;
}

DateTime? _endOfMonth(int y, int mo) {
  if (mo < 1 || mo > 12) return null;
  return DateTime(y, mo + 1, 0);
}

/// لتطبيع مفاتيح المطابقة (أسماء الأدوية): أحرف صغيرة، بلا مسافات زائدة.
String normKey(String s) => normalizeDigits(s)
    .toLowerCase()
    .replaceAll(RegExp(r'[ً-ْـ]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
