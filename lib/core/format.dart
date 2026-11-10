import 'package:intl/intl.dart';

final _numFmt = NumberFormat('#,##0', 'en');

/// رمز العملة المعروض بجانب المبالغ (يُضبط من إعدادات المحل).
String kCurrency = 'ل.س';

/// تنسيق المبلغ (أعداد صحيحة بلا كسور).
String money(int v) => '${_numFmt.format(v)} $kCurrency';
String numFmt(int v) => _numFmt.format(v);

/// الكميات تُخزَّن كأعداد عشرية مقرّبة إلى 3 منازل لتفادي أخطاء الفاصلة العائمة.
double q3(double v) => (v * 1000).round() / 1000;

/// يعرض الكمية: صحيحة بلا كسر، وعشرية بحد أقصى 3 منازل بلا أصفار زائدة.
String qtyFmt(num v) {
  final d = q3(v.toDouble());
  if (d == d.roundToDouble()) return _numFmt.format(d.round());
  return d.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

/// يقرأ كمية عشرية (تقبل الفاصلة العربية والأرقام العربية). null إن فشل.
double? parseQty(String? s) {
  if (s == null) return null;
  var t = normalizeDigits(s).replaceAll(RegExp(r'[\s٬]'), '').replaceAll('٫', '.');
  // فاصلة واحدة بعدها ليس 3 أرقام تُعامل كفاصلة عشرية (0,5)، وإلا فهي فاصل آلاف (1,000).
  final comma = RegExp(r'^[^,]*,(\d*)$').firstMatch(t);
  if (comma != null && !t.contains('.') && comma[1]!.length != 3) t = t.replaceFirst(',', '.');
  t = t.replaceAll(',', '');
  if (t.isEmpty) return null;
  final v = double.tryParse(t);
  return v == null || v.isNaN || v.isInfinite ? null : q3(v);
}

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
/// تاريخ "شهر/سنة" يُعتبر آخر يوم في الشهر (كما هو متعارف في المواد الغذائية).
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

/// لتطبيع مفاتيح المطابقة (أسماء الأصناف): أحرف صغيرة، بلا مسافات زائدة.
String normKey(String s) => normalizeDigits(s)
    .toLowerCase()
    .replaceAll(RegExp(r'[ً-ْـ]'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
