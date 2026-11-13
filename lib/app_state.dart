import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'data/database.dart';
import 'data/repository.dart';
import 'services/backup.dart';
import 'services/kv_store.dart';
import 'core/business.dart';
import 'core/format.dart';
import 'services/access.dart';
import 'services/auth.dart';
import 'services/store_info.dart';
import 'services/pin.dart';

/// تجاوز تسجيل الدخول لأغراض التطوير فقط (يعمل في وضع debug فقط ولا أثر له في نسخة الإصدار).
const _devBypass = bool.fromEnvironment('DEV_BYPASS_LOGIN');

class AppController extends ChangeNotifier {
  late AppDatabase db;
  late Repository repo;
  final KvStore kv;
  final AppDatabase? _injectedDb;
  final bool _forceSignedIn;
  final BusinessType? _presetType;
  final DateTime? _freeUntilOverride;
  final DateTime Function() _clock;
  AccessPolicy policy = AccessPolicy(kFreeUntil);
  DateTime _seen = DateTime.fromMillisecondsSinceEpoch(0);

  /// للاختبارات: يمكن حقن قاعدة بيانات وتخزين وتجاوز تسجيل الدخول وتحديد نوع النشاط مسبقاً.
  AppController({
    AppDatabase? database,
    KvStore? kvStore,
    @visibleForTesting bool forceSignedIn = false,
    @visibleForTesting BusinessType? presetType,
    @visibleForTesting DateTime? freeUntil,
    @visibleForTesting DateTime Function()? clock,
  })  : kv = kvStore ?? SecureKv(),
        _injectedDb = database,
        _forceSignedIn = forceSignedIn,
        _presetType = presetType,
        _freeUntilOverride = freeUntil,
        _clock = clock ?? DateTime.now;
  final DriveBackupService drive = DriveBackupService();
  late final AuthService auth = AuthService(kv, drive);
  late final PinManager pin = PinManager(kv);

  bool ready = false;
  Account? account;
  StoreConfig? config;
  bool pinRequired = false;
  bool unlocked = false;
  StoreInfo store = const StoreInfo();

  bool get devBypass => kDebugMode && _devBypass;
  bool get signedIn => account != null || devBypass || _forceSignedIn;
  bool get onboarded => config != null;

  /// الوقت الفعلي: الأكبر بين ساعة الهاتف وآخر وقت شوهد (يمنع إرجاع الساعة للالتفاف).
  DateTime get effectiveNow {
    final t = _clock();
    return t.isAfter(_seen) ? t : _seen;
  }

  /// وضع القراءة فقط بعد انتهاء الفترة المجانية (ما لم يكن هناك اشتراك).
  bool get readOnly => policy.readOnly(effectiveNow);
  bool get inFreePeriod => policy.isFree(effectiveNow);
  int get freeDaysLeft => policy.daysLeft(effectiveNow);

  /// يحدّث آخر وقت شوهد (يُستدعى عند فتح التطبيق وعند العودة من الخلفية).
  Future<void> touchClock() async {
    final before = readOnly;
    try {
      _seen = await ClockGuard(kv, _clock).now();
    } catch (_) {}
    if (readOnly != before) notifyListeners();
  }

  Future<void> _refreshFreeUntil() async {
    final src = FreeUntilSource(kv);
    final d = await src.refresh();
    if (d != null) {
      policy = AccessPolicy(d, subscribed: policy.subscribed);
      notifyListeners();
    }
  }

  /// إعدادات المحل الحالية (نوع افتراضي «عام» قبل الإعداد الأول).
  StoreConfig get cfg => config ?? StoreConfig.forType(BusinessType.general);

  Future<void> init() async {
    db = _injectedDb ?? openAppDatabase();
    repo = Repository(db, isLocked: () => readOnly);
    try {
      account = await auth.current();
    } catch (_) {
      account = null;
    }
    pinRequired = await pin.isSet;
    unlocked = !pinRequired;
    policy = AccessPolicy(_freeUntilOverride ?? await FreeUntilSource(kv).cached());
    await touchClock();
    await _loadStore();
    if (_presetType != null && config == null) {
      await saveConfig(StoreConfig.forType(_presetType));
    }
    ready = true;
    notifyListeners();
    if (_freeUntilOverride == null) _refreshFreeUntil();
    _autoBackup();
  }

  Future<void> _loadStore() async {
    config = await StoreConfig.load(db);
    store = await StoreInfo.load(db);
    kCurrency = cfg.currency;
  }

  /// تسجيل الدخول بـ Google (يتحقق من Drive). يرمي [AuthException].
  Future<void> signIn() async {
    account = await auth.signIn();
    notifyListeners();
  }

  Future<void> signOut() async {
    await auth.signOut();
    account = null;
    notifyListeners();
  }

  Future<void> saveConfig(StoreConfig c) async {
    await c.save(db);
    config = c;
    kCurrency = c.currency;
    notifyListeners();
  }

  Future<void> setPin(String p) async {
    await pin.setPin(p);
    pinRequired = true;
    unlocked = true;
    notifyListeners();
  }

  Future<void> removePin() async {
    await pin.clear();
    pinRequired = false;
    unlocked = true;
    notifyListeners();
  }

  void unlock() {
    unlocked = true;
    notifyListeners();
  }

  void lock() {
    if (pinRequired) {
      unlocked = false;
      notifyListeners();
    }
  }

  Future<void> saveStore(StoreInfo p) async {
    await p.save(db);
    store = p;
    notifyListeners();
  }

  // ───────── النسخ الاحتياطي ─────────

  Future<Directory> _backupDir() async {
    final d = Directory('${(await getApplicationDocumentsDirectory()).path}/backups');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<Directory> tmpDir() => getTemporaryDirectory();

  Future<Uint8List> snapshot() async => BackupFile.snapshot(db, await tmpDir());

  /// نسخة أمان محلية قبل العمليات الخطرة (استيراد، استعادة، تحديث). نحتفظ بآخر 5.
  Future<void> safetyBackup(String reason) async {
    try {
      final dir = await _backupDir();
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.').first;
      await File('${dir.path}/safety_${reason}_$stamp.${BackupFile.ext}')
          .writeAsBytes(await snapshot());
      final files = dir.listSync().whereType<File>().toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final f in files.skip(5)) {
        f.deleteSync();
      }
    } catch (_) {}
  }

  Future<DateTime?> lastDriveBackup() async {
    final v = await db.getSetting('last_drive_backup');
    return v == null ? null : DateTime.tryParse(v);
  }

  /// النسخ التلقائي على Drive مفعّل افتراضياً (التسجيل بـ Google إلزامي)، ويمكن إيقافه.
  Future<bool> driveBackupEnabled() async => (await db.getSetting('drive_backup')) != '0';

  Future<void> setDriveBackup(bool on) async {
    await db.setSetting('drive_backup', on ? '1' : '0');
    notifyListeners();
  }

  Future<RemoteBackup> backupToDrive({bool interactive = false}) async {
    final r = await drive.upload(await snapshot(), interactive: interactive);
    await db.setSetting('last_drive_backup', DateTime.now().toIso8601String());
    notifyListeners();
    return r;
  }

  /// نسخة تلقائية صامتة مرة كل 24 ساعة عند فتح التطبيق، إن كانت مفعّلة.
  Future<void> _autoBackup() async {
    try {
      if (!await driveBackupEnabled()) return;
      final last = await lastDriveBackup();
      if (last != null && DateTime.now().difference(last) < const Duration(hours: 24)) return;
      await backupToDrive();
    } catch (_) {
      // صامت: سيظهر تاريخ آخر نسخة ناجحة في شاشة النسخ الاحتياطي.
    }
  }

  /// استعادة من بايتات مضغوطة (من Drive أو ملف محلي). تستبدل قاعدة البيانات كلها.
  Future<void> restore(Uint8List packed) async {
    final tmp = await tmpDir();
    final raw = BackupFile.validate(packed, tmp); // يرمي إن كانت غير صالحة
    await safetyBackup('before_restore');
    final file = await databaseFile();
    await db.close();
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final f = File('${file.path}$suffix');
      if (await f.exists()) await f.delete();
    }
    await file.writeAsBytes(raw, flush: true);
    db = openAppDatabase();
    repo = Repository(db, isLocked: () => readOnly);
    await _loadStore();
    notifyListeners();
  }
}

class AppScope extends InheritedNotifier<AppController> {
  const AppScope({super.key, required AppController controller, required super.child})
      : super(notifier: controller);
  /// يشترك في التغييرات (يُعاد البناء عند notifyListeners). لا يُستخدم داخل initState.
  static AppController of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  /// قراءة بلا اشتراك؛ آمنة داخل initState والدوال غير المتزامنة.
  static AppController read(BuildContext c) =>
      c.getInheritedWidgetOfExactType<AppScope>()!.notifier!;
}

extension AppCtx on BuildContext {
  AppController get app => AppScope.of(this);
  Repository get repo => AppScope.of(this).repo;
  AppController get appRead => AppScope.read(this);
  Repository get repoRead => AppScope.read(this).repo;
}
