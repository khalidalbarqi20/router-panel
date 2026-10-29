import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'game.dart';

Future<bool> _tcp(String ip, int port) async {
  try {
    final s = await Socket.connect(ip, port, timeout: const Duration(seconds: 3));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// 'OK' إذا فيه إنترنت، وإلا وصف المشكلة.
Future<String> netDiag() async {
  final ipOk = await _tcp('1.1.1.1', 443) || await _tcp('8.8.8.8', 443);
  if (!ipOk) return 'لا يوجد اتصال بالإنترنت (حتى بدون DNS)';
  try {
    final l = await InternetAddress.lookup('example.com').timeout(const Duration(seconds: 5));
    if (l.isEmpty) return 'DNS لا يردّ';
  } catch (_) {
    return 'DNS لا يعمل (الاتصال موجود لكن أسماء المواقع ما تُحل)';
  }
  return 'OK';
}

Future<bool> askRepair(BuildContext context) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('لا يوجد إنترنت'),
      content: const Text(
          'غالبًا الراوتر بقي مقفولًا على نطاق بدون تغطية (من فحص سابق انقطع).\n\n'
          'أطبّق كل النطاقات المدعومة بوضع «تلقائي» لإرجاع الإنترنت؟ هذا يغيّر إعداد النطاقات الحالي.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('لا')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('نعم، أصلح')),
      ],
    ),
  );
  return r ?? false;
}

/// يتأكد أن فيه إنترنت قبل أي فحص. إذا ما فيه: ينتظر قليلًا، ثم (بموافقتك) يرجّع الراوتر لكل النطاقات.
Future<bool> ensureInternet(
  GameCtl ctl,
  void Function(String) log,
  bool Function() stop,
  Future<bool> Function() askRepairFn,
) async {
  var d = await netDiag();
  if (d == 'OK') return true;
  log('فحص الاتصال: $d');
  for (var i = 0; i < 6 && !stop(); i++) {
    await Future<void>.delayed(const Duration(seconds: 5));
    d = await netDiag();
    if (d == 'OK') {
      log('رجع الإنترنت.');
      return true;
    }
  }
  if (stop() || ctl.sup.isEmpty) return false;
  if (!await askRepairFn()) {
    log('ما فيه إنترنت، والإصلاح مرفوض: $d');
    return false;
  }
  final mask = ctl.sup.fold<int>(0, (a, x) => a | (1 << (x - 1))).toRadixString(16);
  log('تطبيق كل النطاقات المدعومة بوضع تلقائي...');
  final ok = await ctl.apply(mask, '00');
  log(ok ? 'تم تطبيق الإعداد الآمن.' : 'ما تأكدت من تطبيق الإعداد الآمن.');
  for (var i = 0; i < 20 && !stop(); i++) {
    await Future<void>.delayed(const Duration(seconds: 3));
    d = await netDiag();
    if (d == 'OK') {
      log('رجع الإنترنت.');
      return true;
    }
  }
  log('ما زال الإنترنت مقطوع: $d. افحص الشريحة والرصيد وتبويب ROUTER.');
  return false;
}
