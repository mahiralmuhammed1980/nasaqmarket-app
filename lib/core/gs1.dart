/// نتيجة تحليل باركود GS1 (DataMatrix) الموجود على بعض عبوات المواد الغذائية.
class Gs1Data {
  final String? gtin;
  final String? batch;
  final DateTime? expiry;
  final String? serial;
  const Gs1Data({this.gtin, this.batch, this.expiry, this.serial});
  bool get isGs1 => gtin != null;
}

/// يحلّل نص GS1: إما بمعرّفات التطبيق بين أقواس "(01)...(17)..." أو بالصيغة
/// الخام مع فاصل FNC1 (الرمز 0x1D).
/// المعرّفات: 01 GTIN(14)، 17 انتهاء YYMMDD(6)، 10 دفعة (متغير)، 21 رقم تسلسلي (متغير).
Gs1Data parseGs1(String raw) {
  final s = raw.replaceAll('è', '\u001d').trim();
  if (s.contains('(')) return _parseBracketed(s);
  return _parseRaw(s);
}

Gs1Data _parseBracketed(String s) {
  final re = RegExp(r'\((\d{2,4})\)([^(]*)');
  String? gtin, batch, serial;
  DateTime? exp;
  for (final m in re.allMatches(s)) {
    final ai = m[1]!, v = m[2]!.replaceAll('\u001d', '').trim();
    switch (ai) {
      case '01':
        gtin = v;
      case '17':
        exp = _yymmdd(v);
      case '10':
        batch = v;
      case '21':
        serial = v;
    }
  }
  return Gs1Data(gtin: gtin, batch: batch, expiry: exp, serial: serial);
}

Gs1Data _parseRaw(String s) {
  String? gtin, batch, serial;
  DateTime? exp;
  var i = 0;
  while (i < s.length) {
    if (s[i] == '\u001d') {
      i++;
      continue;
    }
    if (i + 2 > s.length) break;
    final ai = s.substring(i, i + 2);
    i += 2;
    int fixed;
    switch (ai) {
      case '01':
        fixed = 14;
      case '17':
      case '11':
      case '15':
        fixed = 6;
      case '10':
      case '21':
        fixed = -1;
      default:
        return Gs1Data(gtin: gtin, batch: batch, expiry: exp, serial: serial);
    }
    String v;
    if (fixed > 0) {
      if (i + fixed > s.length) break;
      v = s.substring(i, i + fixed);
      i += fixed;
    } else {
      final end = s.indexOf('\u001d', i);
      v = end < 0 ? s.substring(i) : s.substring(i, end);
      i = end < 0 ? s.length : end + 1;
    }
    switch (ai) {
      case '01':
        gtin = v;
      case '17':
        exp = _yymmdd(v);
      case '10':
        batch = v;
      case '21':
        serial = v;
    }
  }
  return Gs1Data(gtin: gtin, batch: batch, expiry: exp, serial: serial);
}

DateTime? _yymmdd(String v) {
  if (v.length != 6) return null;
  final y = int.tryParse(v.substring(0, 2)), m = int.tryParse(v.substring(2, 4));
  var d = int.tryParse(v.substring(4, 6));
  if (y == null || m == null || d == null || m < 1 || m > 12) return null;
  final year = 2000 + y;
  if (d == 0) d = DateTime(year, m + 1, 0).day; // 00 = آخر يوم في الشهر
  return DateTime(year, m, d);
}

/// أرقام GTIN-14 تبدأ عادة بـ 0 يقابل EAN-13؛ نولّد صيغ المطابقة الممكنة.
List<String> barcodeVariants(String code) {
  final c = code.trim();
  final out = <String>{c};
  if (c.length == 14 && c.startsWith('0')) out.add(c.substring(1));
  if (c.length == 13) out.add('0$c');
  return out.toList();
}
