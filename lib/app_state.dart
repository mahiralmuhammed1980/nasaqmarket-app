import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'data/database.dart';
import 'data/repository.dart';
import 'services/backup.dart';
import 'services/kv_store.dart';
import 'services/license.dart';
import 'services/pharmacy_info.dart';
import 'services/pin.dart';

/// تجاوز التفعيل لأغراض التطوير فقط (يعمل في وضع debug فقط ولا أثر له في APK الإصدار).
const _devBypass = bool.fromEnvironment('DEV_BYPASS_LICENSE');

class AppController extends ChangeNotifier {
  late AppDatabase db;
  late Repository repo;
  final KvStore kv;
  final AppDatabase? _injectedDb;
  final bool _forceActivated;

  /// للاختبارات: يمكن حقن قاعدة بيانات وتخزين وتجاوز التفعيل.
  AppController({AppDatabase? database, KvStore? kvStore, @visibleForTesting bool forceActivated = false})
      : kv = kvStore ?? SecureKv(),
        _injectedDb = database,
        _forceActivated = forceActivated;
  late final LicenseService license = LicenseService(LicenseVault(kv));
  late final PinManager pin = PinManager(kv);
  final DriveBackupService drive = DriveBackupService();

  bool ready = false;
  LocalLicense? licenseInfo;
  bool pinRequired = false;
  bool unlocked = false;
  PharmacyInfo pharmacy = const PharmacyInfo();

  bool get devBypass => kDebugMode && _devBypass;
  bool get activated => licenseInfo != null || devBypass || _forceActivated;

  Future<void> init() async {
    db = _injectedDb ?? openAppDatabase();
    repo = Repository(db);
    try {
      licenseInfo = await license.current();
    } catch (_) {
      licenseInfo = null;
    }
    pinRequired = await pin.isSet;
    unlocked = !pinRequired;
    pharmacy = await PharmacyInfo.load(db);
    ready = true;
    notifyListeners();
    _autoBackup();
  }

  void onActivated(LocalLicense l) {
    licenseInfo = l;
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

  Future<void> savePharmacy(PharmacyInfo p) async {
    await p.save(db);
    pharmacy = p;
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

  Future<bool> driveBackupEnabled() async => (await db.getSetting('drive_backup')) == '1';

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
    repo = Repository(db);
    pharmacy = await PharmacyInfo.load(db);
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
