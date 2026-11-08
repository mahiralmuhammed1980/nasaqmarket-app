import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';

/// يحفظ نصاً (CSV غالباً) في ملف مؤقت ويفتح قائمة المشاركة.
Future<void> shareText(BuildContext context, String content, String filename) async {
  final dir = await context.appRead.tmpDir();
  final f = File('${dir.path}/$filename')..writeAsBytesSync(utf8.encode(content));
  await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
}

/// تهريب حقل CSV.
String csvCell(Object? v) => '"${(v ?? '').toString().replaceAll('"', '""')}"';
