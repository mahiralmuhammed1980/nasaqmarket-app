import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'kv_store.dart';

enum PinResult { ok, wrong, locked }

/// قفل PIN من 6 أرقام. يُخزَّن ملح + بصمة (PBKDF2-HMAC-SHA256) في التخزين الآمن.
/// حماية محلية فقط؛ لا تغني عن هوية Google. الاستعادة تكون بإعادة تسجيل الدخول بـ Google.
class PinManager {
  final KvStore kv;
  final DateTime Function() now;
  static const maxAttempts = 5;
  static const lockMinutes = 5;
  static const _iterations = 20000;

  PinManager(this.kv, {DateTime Function()? now}) : now = now ?? DateTime.now;

  Future<bool> get isSet async => (await kv.read('pin_hash')) != null;

  static bool isValidFormat(String pin) => RegExp(r'^\d{6}$').hasMatch(pin);

  Future<void> setPin(String pin) async {
    if (!isValidFormat(pin)) throw ArgumentError('يجب أن يتكون الرمز من 6 أرقام');
    final rnd = Random.secure();
    final salt = base64.encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    await kv.write('pin_salt', salt);
    await kv.write('pin_hash', _derive(pin, salt));
    await kv.delete('pin_fails');
    await kv.delete('pin_locked_until');
  }

  Future<void> clear() async {
    for (final k in ['pin_hash', 'pin_salt', 'pin_fails', 'pin_locked_until']) {
      await kv.delete(k);
    }
  }

  Future<Duration?> lockRemaining() async {
    final until = int.tryParse(await kv.read('pin_locked_until') ?? '');
    if (until == null) return null;
    final rem = DateTime.fromMillisecondsSinceEpoch(until).difference(now());
    return rem.isNegative ? null : rem;
  }

  Future<PinResult> verify(String pin) async {
    if (await lockRemaining() != null) return PinResult.locked;
    final salt = await kv.read('pin_salt');
    final hash = await kv.read('pin_hash');
    if (salt == null || hash == null) return PinResult.ok;
    if (_constEq(_derive(pin, salt), hash)) {
      await kv.delete('pin_fails');
      await kv.delete('pin_locked_until');
      return PinResult.ok;
    }
    final fails = (int.tryParse(await kv.read('pin_fails') ?? '0') ?? 0) + 1;
    if (fails >= maxAttempts) {
      await kv.delete('pin_fails');
      await kv.write('pin_locked_until',
          '${now().add(const Duration(minutes: lockMinutes)).millisecondsSinceEpoch}');
      return PinResult.locked;
    }
    await kv.write('pin_fails', '$fails');
    return PinResult.wrong;
  }

  static String _derive(String pin, String salt) {
    final key = utf8.encode(pin);
    var block = Hmac(sha256, key).convert([...utf8.encode(salt), 0, 0, 0, 1]).bytes;
    final out = List<int>.from(block);
    for (var i = 1; i < _iterations; i++) {
      block = Hmac(sha256, key).convert(block).bytes;
      for (var j = 0; j < out.length; j++) {
        out[j] ^= block[j];
      }
    }
    return base64.encode(out);
  }

  static bool _constEq(String a, String b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return r == 0;
  }
}
