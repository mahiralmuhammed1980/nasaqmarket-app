import 'dart:convert';

import 'package:http/http.dart' as http;

import 'kv_store.dart';
import 'license.dart';

/// نهاية الفترة المجانية (نهاية هذا اليوم). غيّره عند النشر.
/// التطبيق مجاني التحميل دائماً؛ بعد هذا التاريخ يصبح الدخول للقراءة والتصدير فقط
/// إلى أن يُفعَّل الاشتراك عبر Google Play (المرحلة التالية).
final DateTime kFreeUntil = DateTime(2027, 3, 1);

/// رابط اختياري لملف JSON عام يحدد التاريخ بلا إصدار جديد: {"freeUntil":"2027-03-01"}.
/// يُمرَّر عند البناء: --dart-define=FREE_UNTIL_URL=https://.../free_until.json
const kFreeUntilUrl = String.fromEnvironment('FREE_UNTIL_URL');

/// حالة الوصول: فترة مجانية، أو مدفوع (كود مندوب)، أو قراءة فقط.
class AccessPolicy {
  final DateTime freeUntil;

  /// استحقاق مدفوع من كود تفعيل (null = لا يوجد).
  final Entitlement? paid;
  const AccessPolicy(this.freeUntil, {this.paid});

  /// يوم آخر يوم مجاني ينتهي عند نهايته.
  DateTime get _end => DateTime(freeUntil.year, freeUntil.month, freeUntil.day + 1);

  bool isFree(DateTime now) => now.isBefore(_end);
  bool isPaid(DateTime now) => paid?.active(now) ?? false;
  bool get lifetime => paid?.lifetime ?? false;
  DateTime? get paidUntil => paid?.paidUntil;

  /// قراءة فقط: انتهت الفترة المجانية وليس هناك استحقاق مدفوع ساري.
  bool readOnly(DateTime now) => !isPaid(now) && !isFree(now);

  /// الأيام المتبقية في الفترة المجانية (0 = آخر يوم).
  int daysLeft(DateTime now) {
    final d = DateTime(freeUntil.year, freeUntil.month, freeUntil.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    return d < 0 ? 0 : d;
  }

  /// الأيام المتبقية في الاشتراك المدفوع (null لمدى الحياة أو بلا اشتراك).
  int? paidDaysLeft(DateTime now) {
    final u = paidUntil;
    if (lifetime || u == null || !now.isBefore(u)) return null;
    return u.difference(now).inDays;
  }
}

/// يخزّن آخر وقت شوهد ويمنع الالتفاف على الفترة بإرجاع ساعة الهاتف إلى الوراء.
class ClockGuard {
  final KvStore kv;
  final DateTime Function() _clock;
  ClockGuard(this.kv, [DateTime Function()? clock]) : _clock = clock ?? DateTime.now;
  static const _k = 'last_seen_ms';

  /// الوقت الفعلي = الأكبر بين ساعة الهاتف وآخر وقت شوهد، ويُحدَّث المخزَّن.
  Future<DateTime> now() async {
    final real = _clock();
    final last = int.tryParse(await kv.read(_k) ?? '');
    final lastT = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
    final eff = (lastT != null && lastT.isAfter(real)) ? lastT : real;
    await kv.write(_k, '${eff.millisecondsSinceEpoch}');
    return eff;
  }
}

/// يقرأ تاريخ نهاية الفترة المجانية من الملف العام ويحفظه محلياً؛
/// عند غياب الاتصال يُستعمل آخر قيمة محفوظة ثم [kFreeUntil].
class FreeUntilSource {
  final KvStore kv;
  final http.Client? client;
  final String url;
  FreeUntilSource(this.kv, {this.client, this.url = kFreeUntilUrl});
  static const _k = 'free_until';

  static DateTime? parse(String body) {
    try {
      final m = jsonDecode(body) as Map<String, dynamic>;
      final d = DateTime.tryParse('${m['freeUntil']}');
      return d == null ? null : DateTime(d.year, d.month, d.day);
    } catch (_) {
      return null;
    }
  }

  /// آخر قيمة محفوظة أو [kFreeUntil] (فوري، بلا شبكة).
  Future<DateTime> cached() async => DateTime.tryParse(await kv.read(_k) ?? '') ?? kFreeUntil;

  /// يجلب القيمة من الإنترنت إن ضُبط الرابط؛ يعيد null عند الفشل أو بلا رابط.
  Future<DateTime?> refresh() async {
    if (url.isEmpty) return null;
    try {
      final c = client ?? http.Client();
      final r = await c.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
      final d = r.statusCode == 200 ? parse(r.body) : null;
      if (d != null) await kv.write(_k, d.toIso8601String());
      return d;
    } catch (_) {
      return null;
    }
  }
}
