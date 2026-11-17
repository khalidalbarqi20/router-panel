import 'package:flutter/foundation.dart';

/// سجل أخطاء بسيط: بدل ما نبلع الأخطاء بـ catch فاضي نسجّلها هنا (آخر 200 سطر).
final List<String> kErrLog = <String>[];

void dbg(String where, Object e) {
  final t = DateTime.now().toIso8601String().substring(11, 19);
  kErrLog.add('$t $where: $e');
  if (kErrLog.length > 200) kErrLog.removeAt(0);
  debugPrint('[$where] $e');
}
