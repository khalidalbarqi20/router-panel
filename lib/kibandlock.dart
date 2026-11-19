import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'bands.dart';

const Color _kGreen = Color(0xFF39D353);
const Map<String, String> _modeName = <String, String>{'00': 'تلقائي (4G+5G)', '03': '4G فقط', '08': '5G فقط', '01': '2G فقط', '02': '3G فقط'};
const FlutterSecureStorage _store = FlutterSecureStorage();

/// قوائم احتياطية إذا الراوتر ما أعطى قائمة نطاقاته (نفس نطاقات تطبيق 5GCtrl).
const List<int> _kNrDefault = <int>[1, 2, 3, 5, 7, 8, 20, 25, 28, 38, 40, 41, 66, 71, 77, 78, 79, 260, 261];
const List<int> _kLteDefault = <int>[1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 20, 25, 26, 28, 29, 38, 39, 40, 41];

Map<String, String> _kv(String x) =>
    <String, String>{for (final m in RegExp(r'<(\w+)>([^<]*)</\1>').allMatches(x)) m[1]!: m[2]!};

String? _errCode(String x) {
  if (!x.contains('<error>')) return null;
  return RegExp(r'<code>([^<]*)</code>').firstMatch(x)?[1] ?? '?';
}

/// معنى أكواد أخطاء الراوتر الشائعة (هواوي).
String _errText(String c) {
  switch (c) {
    case '100001':
      return 'خطأ غير محدد في الراوتر';
    case '100002':
      return 'هذا الأمر غير مدعوم في فيرموير الراوتر';
    case '100003':
      return 'ما عندك صلاحية (انتهت جلسة الدخول، ادخل من جديد)';
    case '100004':
      return 'الراوتر مشغول، أعد المحاولة بعد شوي';
    case '100006':
      return 'الراوتر رفض القيم أو الصيغة المرسلة';
    case '125001':
    case '125002':
    case '125003':
      return 'انتهت جلسة الدخول أو التوكن، أعد الدخول';
    default:
      return 'رفض الراوتر الطلب';
  }
}

String _hide(String x) => x.replaceAllMapped(
    RegExp(r'<(\w*(?:imei|imsi|serial|mac|iccid|msisdn|phone|number|ssid)\w*)>[^<]+</', caseSensitive: false),
    (m) => '<${m[1]}>***</');

double? _n(String? s) {
  if (s == null) return null;
  final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(s);
  return m == null ? null : double.tryParse(m[0]!);
}

BigInt _parse(String h) => BigInt.tryParse(h.trim(), radix: 16) ?? BigInt.zero;

Set<int> _bitsOf(String hex, int maxBand) {
  final m = _parse(hex);
  final out = <int>{};
  for (var b = 1; b <= maxBand; b++) {
    if (((m >> (b - 1)) & BigInt.one) == BigInt.one) out.add(b);
  }
  return out;
}

BigInt _mask(Iterable<int> bands) {
  var m = BigInt.zero;
  for (final b in bands) {
    m |= BigInt.one << (b - 1);
  }
  return m;
}

String _hexOf(Iterable<int> bands, String like) {
  final s = _mask(bands).toRadixString(16);
  return like.contains(RegExp(r'[A-F]')) ? s.toUpperCase() : s;
}

/// يلقى اسم حقل نطاقات 5G داخل رد net-mode (مثل NRBand) بدون تخمين اسم ثابت.
const List<String> _kNrCand = <String>[
  'NRBand', 'NrBand', 'NSABand', 'SABand', 'NRNSABand', 'NRSABand', 'NR5GBand', 'Band5G', 'NR_Band', 'NRLockBand', 'NRBandMask',
];

String? _nrKey(Map<String, String> n) {
  for (final k in n.keys) {
    final l = k.toLowerCase();
    if (_kNrCand.any((c) => c.toLowerCase() == l)) return k;
    if (l == 'lteband' || l == 'networkband') continue;
    if (l.contains('band') && (l.contains('nr') || l.contains('5g') || l.startsWith('sa') || l.startsWith('nsa'))) {
      return k;
    }
  }
  return null;
}

class KiBandLock extends StatefulWidget {
  final Future<String> Function(String) rd;
  final Future<String> Function(String, String) wr;
  final Future<void> Function() relogin;
  /// عنوان الراوتر (لاستيراد ملفات الشرائح القديمة من صفحة 5G السابقة).
  final String routerHost;
  /// يرجّع الإعداد الأول المحفوظ لهذا الراوتر (يوفّرها التطبيق الرئيسي).
  final Future<(bool, String)> Function()? restoreOriginal;
  final String originalText;
  const KiBandLock({
    super.key,
    required this.rd,
    required this.wr,
    required this.relogin,
    this.routerHost = '',
    this.restoreOriginal,
    this.originalText = '',
  });

  @override
  State<KiBandLock> createState() => _KiBandLockState();
}

class _KiBandLockState extends State<KiBandLock> {
  bool busy = true;
  String msg = '';
  Map<String, String> orig = <String, String>{};
  Map<String, String>? firstOrig;
  Map<String, String> sig = <String, String>{};
  String? nrKey;
  bool nrOk = false;
  bool nrForce = false;
  String mode = '00';
  List<String> modes = <String>[];
  String listRaw = '';
  List<int> lteAll = <int>[], nrAll = <int>[];
  Set<int> lte = <int>{}, nr = <int>{};
  Map<String, Map<String, List<int>>> profiles = <String, Map<String, List<int>>>{};
  final Map<String, String> profMode = <String, String>{};

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _loadProfiles();
    await _load();
  }

  void _say(String s) {
    if (mounted) setState(() => msg = s);
  }

  Future<bool> _ask(String t) async =>
      await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(content: Text(t), actions: [
                TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')),
                FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('متأكد')),
              ])) ??
      false;

  /// رسالة تنبيه بنتيجة العملية: kind 0 = تم، 1 = تم جزئيًا/تنبيه، 2 = ما تم.
  Future<void> _alert(int kind, String title, List<String> lines) async {
    if (mounted) setState(() => msg = '$title\n${lines.join('\n')}');
    if (!mounted) return;
    final color = kind == 0 ? _kGreen : (kind == 1 ? Colors.orangeAccent : Colors.redAccent);
    final icon = kind == 0 ? Icons.check_circle : (kind == 1 ? Icons.warning_amber_rounded : Icons.cancel);
    await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
              title: Row(children: [
                Icon(icon, color: color, size: 30),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 18))),
              ]),
              content: SizedBox(
                  width: double.maxFinite,
                  child: SingleChildScrollView(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(l)),
                  ]))),
              actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('حسنًا'))],
            ));
  }

  Future<void> _loadProfiles() async {
    try {
      final raw = await _store.read(key: 'band_profiles');
      if (raw != null) {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final out = <String, Map<String, List<int>>>{};
        for (final e in j.entries) {
          final v = e.value as Map<String, dynamic>;
          out[e.key] = <String, List<int>>{
            'lte': <int>[for (final x in (v['lte'] as List)) x as int],
            'nr': <int>[for (final x in (v['nr'] as List)) x as int],
          };
          final m = v['m'];
          if (m is String && m.isNotEmpty) profMode[e.key] = m;
        }
        profiles = out;
      }
    } catch (_) {}
    await _importOldProfiles();
  }

  /// ملفات الشرائح (STC / Zain ...) اللي كانت محفوظة في صفحة 5G القديمة تنضم هنا مرة وحدة.
  Future<void> _importOldProfiles() async {
    if (widget.routerHost.isEmpty) return;
    final key = 'nr_profiles_${widget.routerHost}';
    try {
      final raw = await _store.read(key: key);
      if (raw == null) return;
      for (final e in (jsonDecode(raw) as List)) {
        final p = Map<String, dynamic>.from(e as Map);
        final n = '${p['n'] ?? ''}';
        if (n.isEmpty || profiles.containsKey(n)) continue;
        profiles[n] = <String, List<int>>{
          'lte': <int>[for (final x in ((p['s4'] as List?) ?? <dynamic>[])) x as int],
          'nr': <int>[for (final x in ((p['s5'] as List?) ?? <dynamic>[])) x as int],
        };
        final m = p['m'];
        if (m is String && m.isNotEmpty) profMode[n] = m;
      }
      await _writeProfiles();
      await _store.delete(key: key);
    } catch (_) {}
  }

  Future<void> _writeProfiles() async {
    final out = <String, dynamic>{
      for (final e in profiles.entries)
        e.key: <String, dynamic>{
          'lte': e.value['lte'] ?? <int>[],
          'nr': e.value['nr'] ?? <int>[],
          if (profMode[e.key] != null) 'm': profMode[e.key],
        },
    };
    await _store.write(key: 'band_profiles', value: jsonEncode(out));
  }

  Future<void> _load() async {
    if (mounted) setState(() => busy = true);
    try {
      final l = await widget.rd('net/net-mode-list');
      final n = _kv(await widget.rd('net/net-mode'));
      Map<String, String> s = sig;
      try {
        s = _kv(await widget.rd('device/signal'));
      } catch (_) {}

      final lteSup = <int>{
        for (final m in RegExp(r'BC(\d+)').allMatches(l))
          if (int.parse(m[1]!) >= 1 && int.parse(m[1]!) <= 64) int.parse(m[1]!)
      };
      final lteList = (lteSup.isEmpty ? _kLteDefault.toList() : lteSup.toList())..sort();

      final key = _nrKey(n);
      final ok = key != null && RegExp(r'^[0-9a-fA-F]+$').hasMatch(n[key] ?? '');
      final force = key == null;
      final nrFound = <int>{
        for (final m in RegExp(r'(?<![A-Za-z0-9])[Nn](\d{1,3})(?![0-9A-Za-z])').allMatches(l))
          if (int.parse(m[1]!) >= 1 && int.parse(m[1]!) <= 300) int.parse(m[1]!)
      };
      final nrList = (nrFound.length >= 3 ? nrFound.toList() : _kNrDefault.toList())..sort();

      final ml = <String>[for (final m in RegExp(r'<Access>(\w+)</Access>').allMatches(l)) m[1]!];
      modes = ml.isEmpty ? <String>['00', '03', '08'] : ml;
      mode = n['NetworkMode'] ?? '00';
      listRaw = l;
      orig = n;
      firstOrig ??= Map<String, String>.from(n);
      sig = s;
      nrKey = key ?? 'NRBand';
      nrOk = ok || force;
      nrForce = force;
      lteAll = lteList;
      nrAll = nrList;
      lte = _bitsOf(n['LTEBand'] ?? '0', 64).intersection(lteList.toSet());
      nr = force ? nrList.toSet() : (ok ? _bitsOf(n[key]!, 300).intersection(nrList.toSet()) : <int>{});
    } catch (e) {
      msg = 'ما قدرت أقرأ الراوتر: $e';
    }
    if (mounted) setState(() => busy = false);
  }

  /// الراوتر يرجّع NetworkBand=0 في القراءة لكنه يرفضه عند الكتابة (كود 100006)، فنستبدله بقيمة All bands.
  void _fixNb(Map<String, String> m) {
    final cur = m['NetworkBand'] ?? '';
    if (cur.isEmpty || RegExp(r'^0+$').hasMatch(cur)) {
      m['NetworkBand'] = RegExp(r'<Band>.*?<Value>([0-9a-fA-F]+)</Value>', dotAll: true).firstMatch(listRaw)?[1] ?? '3fffffff';
    }
  }

  /// يبني جسم الطلب: كل حقول النطاق والوضع من قراءة الراوتر، مع استبدال ماسك 4G و5G.
  Map<String, String> _body(Set<int> l, Set<int> n, {bool withNr = true}) {
    final out = <String, String>{};
    for (final e in orig.entries) {
      final k = e.key.toLowerCase();
      if (k.contains('band') || k.contains('mode')) out[e.key] = e.value;
    }
    out['LTEBand'] = _hexOf(l, orig['LTEBand'] ?? '');
    _fixNb(out);
    if (withNr && nrKey != null && nrOk) out[nrKey!] = _hexOf(n, orig[nrKey!] ?? '');
    return out;
  }

  String _xml(Map<String, String> m) => m.entries.map((e) => '<${e.key}>${e.value}</${e.key}>').join();

  int _vOk = 0;

  Map<String, String> _over(Set<int> l, Set<int> n, {bool withNr = true}) {
    final o = <String, String>{'LTEBand': _hexOf(l, orig['LTEBand'] ?? ''), 'NetworkMode': mode};
    if (withNr && nrKey != null && nrOk) o[nrKey!] = _hexOf(n, orig[nrKey!] ?? '');
    return o;
  }

  /// يجرّب أشكال طلب مختلفة لأن بعض الفيرمويرات ترفض الشكل الأول بكود 100006.
  List<String> _variants(Map<String, String> base, Map<String, String> over) {
    final all = Map<String, String>.from(base)..addAll(over);
    final fixed = Map<String, String>.from(all);
    _fixNb(fixed);
    bool bm(String k) {
      final x = k.toLowerCase();
      return x.contains('band') || x.contains('mode');
    }

    final core = <String, String>{for (final e in fixed.entries) if (bm(e.key)) e.key: e.value};
    final slim = <String, String>{
      for (final e in fixed.entries)
        if (e.key == 'NetworkMode' || e.key == 'LTEBand' || e.key.toLowerCase() == 'networkoption') e.key: e.value
    };
    return <String>[_xml(core), _xml(fixed), _xml(all), _xml(slim)];
  }

  Future<String> _sendAny(List<String> xs) async {
    try {
      await widget.relogin();
    } catch (_) {}
    var last = '';
    for (var i = 0; i < xs.length; i++) {
      try {
        last = await widget.wr('net/net-mode', xs[i]);
      } catch (_) {
        await widget.relogin();
        last = await widget.wr('net/net-mode', xs[i]);
      }
      if (_errCode(last) != '100006') {
        _vOk = i;
        return last;
      }
    }
    return last;
  }

  Future<String> _send(String xml) async {
    try {
      await widget.relogin();
    } catch (_) {}
    try {
      return await widget.wr('net/net-mode', xml);
    } catch (_) {
      await widget.relogin();
      return await widget.wr('net/net-mode', xml);
    }
  }

  /// يتأكد أن الراوتر أخذ الماسك المطلوب فعلًا.
  Future<bool> _verify(Set<int> l, Set<int> n, {required bool nrToo}) async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration(seconds: i == 0 ? 6 : 5));
      try {
        var c = _kv(await widget.rd('net/net-mode'));
        if (!c.containsKey('LTEBand')) {
          await widget.relogin();
          c = _kv(await widget.rd('net/net-mode'));
        }
        final okL = _parse(c['LTEBand'] ?? '') == _mask(l);
        final okM = (c['NetworkMode'] ?? mode) == mode;
        final okN = !(nrToo && nrKey != null && nrOk) || _parse(c[nrKey!] ?? '') == _mask(n);
        if (okL && okM && okN) return true;
      } catch (_) {}
    }
    return false;
  }

  Future<bool> _connected(int secs) async {
    final end = DateTime.now().add(Duration(seconds: secs));
    while (DateTime.now().isBefore(end)) {
      try {
        final st = _kv(await widget.rd('monitoring/status'));
        if (st['ConnectionStatus'] == '901') return true;
      } catch (_) {
        try {
          await widget.relogin();
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(seconds: 4));
    }
    return false;
  }

  Future<void> _restore() async {
    final f = firstOrig;
    if (f == null) return;
    await _sendAny(_variants(f, <String, String>{}));
    await Future<void>.delayed(const Duration(seconds: 12));
  }

  /// بعد تطبيق نطاقات 5G: ينتظر تسجيل الراوتر على 5G (حتى 45 ثانية) ويرجّع وصف الحالة.
  Future<(bool, String)> _waitFive() async {
    final end = DateTime.now().add(const Duration(seconds: 45));
    Map<String, String> last = <String, String>{};
    while (DateTime.now().isBefore(end)) {
      try {
        last = _kv(await widget.rd('device/signal'));
        if (_n(last['nrrsrp']) != null) {
          final nb = nrBandNum(last);
          return (
            true,
            'سجّل على 5G${nb == null ? '' : ' (n$nb)'} · RSRP ${last['nrrsrp']} · SINR ${last['nrsinr'] ?? '-'}'
          );
        }
      } catch (_) {
        try {
          await widget.relogin();
        } catch (_) {}
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return (false, '');
  }

  Future<void> _apply() async {
    if (lte.isEmpty) {
      await _alert(2, 'ما تم التطبيق', <String>['اختر نطاق 4G واحد على الأقل.']);
      return;
    }
    if (nrKey != null && nrOk && nr.isEmpty) {
      await _alert(2, 'ما تم التطبيق', <String>[
        'اختر نطاق 5G واحد على الأقل.',
        'لإيقاف 5G اختر وضع «4G فقط» من هذي الصفحة.'
      ]);
      return;
    }
    final risky = !<String>['00', '03'].contains(mode);
    final go = await _ask(
        'سيُطبَّق القفل وقد ينقطع الإنترنت قرابة دقيقة. إذا ما رجع الاتصال خلال دقيقتين يرجع الإعداد الأصلي تلقائيًا.'
        '${risky ? '\n\nتحذير: وضع «${_modeName[mode] ?? mode}» قد يقطع الإنترنت إذا لم تتوفر الشبكة.' : ''}'
        '\n\nمتأكد؟');
    if (!go) return;
    setState(() {
      busy = true;
      msg = 'جاري التطبيق، لا تقفل الصفحة...';
    });
    var kind = 0;
    var title = 'تم التطبيق';
    final lines = <String>[];
    try {
      final force = nrForce;
      final want5 = nrKey != null && nr.isNotEmpty && (nrOk || force);
      final r = await _sendAny(_variants(orig, _over(lte, nr, withNr: !force)));
      final e = _errCode(r);
      if (e != null) {
        kind = 2;
        title = 'ما تم التطبيق';
        lines
          ..add('الراوتر رفض الطلب (كود $e): ${_errText(e)}.')
          ..add('ما تغيّر شي في إعدادات الراوتر.');
      } else {
        final ok = await _verify(lte, nr, nrToo: !force);
        if (!ok) {
          kind = 2;
          title = 'ما تأكدت من التطبيق';
          lines
            ..add('الراوتر استلم الطلب لكن القيمة اللي قرأتها منه بعدها تختلف عن المطلوبة.')
            ..add('السبب المحتمل: الراوتر تجاهل نطاقات 5G أو بعض النطاقات غير مدعومة فيه.')
            ..add('اضغط أيقونة التشخيص (الحشرة) في الأعلى وأرسل لي النتيجة.');
        } else {
          final up = await _connected(120);
          if (!up) {
            await _restore();
            kind = 2;
            title = 'ما رجع الاتصال، رجّعت الإعداد الأصلي';
            lines
              ..add('الراوتر طبّق القفل لكن الاتصال ما رجع خلال دقيقتين.')
              ..add('السبب المحتمل: ما فيه تغطية على النطاقات المحددة في موقعك، أو أن وضع «5G فقط» ما لقى 5G.')
              ..add('رجّعت الإعداد الأصلي تلقائيًا.');
          } else {
            lines.add('الراوتر أخذ الإعداد وتأكدت منه بالقراءة، والاتصال شغّال (شكل الطلب ${_vOk + 1}).');
            var five5 = true;
            if (force && nr.isNotEmpty) {
              final r2 = await _sendAny(_variants(orig, _over(lte, nr)));
              final e2 = _errCode(r2);
              if (e2 != null) {
                five5 = false;
                lines.add('نطاقات 5G: الراوتر رفض حقل 5G (كود $e2): ${_errText(e2)}. تم قفل 4G فقط.');
              } else {
                await Future<void>.delayed(const Duration(seconds: 8));
                final c = _kv(await widget.rd('net/net-mode'));
                final k = _nrKey(c);
                if (k != null && _parse(c[k] ?? '') == _mask(nr)) {
                  lines.add('نطاقات 5G: الراوتر قبل القفل وأرجعه بالقراءة.');
                } else {
                  five5 = false;
                  lines.add('نطاقات 5G: الراوتر ما أعاد حقل 5G بعد الإرسال، فالأغلب تجاهله ولا يدعم قفل 5G من هذي الواجهة. تم قفل 4G فقط. جرّب أيقونة البحث (اكتشاف قفل 5G) في الأعلى.');
                }
              }
            }
            if (want5 && five5) {
              if (mode == '03') {
                five5 = false;
                lines
                  ..add('نطاقات 5G انحفظت، لكن الوضع «4G فقط» فما راح يشتغل 5G.')
                  ..add('غيّر الوضع إلى «تلقائي (4G+5G)» أو «5G فقط» وطبّق من جديد.');
              } else {
                _say('ينتظر تسجيل الراوتر على 5G (حتى 45 ثانية)...');
                final fr = await _waitFive();
                if (fr.$1) {
                  lines.add('نطاقات 5G: ${fr.$2}');
                } else {
                  five5 = false;
                  lines
                    ..add('نطاقات 5G: انحفظت في الراوتر لكنه ما سجّل على 5G خلال 45 ثانية.')
                    ..add('الأسباب المحتملة:')
                    ..add('• ما فيه تغطية 5G على النطاقات المختارة في موقعك.')
                    ..add('• شبكة 5G من نوع NSA تحتاج نطاق 4G مساعد مفعّل مع نطاق 5G.')
                    ..add('• إشارة 5G ضعيفة جدًا أو الشريحة/الباقة ما تدعم 5G.')
                    ..add('انتظر دقيقة وافحص من صفحة «الفحص»، أو جرّب نطاقات 5G ثانية.');
                }
              }
            }
            if (want5 && !five5) {
              kind = 1;
              title = 'تم تطبيق 4G، لكن 5G ما اشتغل';
            } else if (want5) {
              title = 'تم تطبيق 4G و 5G';
            }
          }
        }
      }
    } catch (e) {
      kind = 2;
      title = 'تعذّر الاتصال بالراوتر';
      lines.add('$e');
    } finally {
      await _load();
    }
    await _alert(kind, title, lines);
  }

  Future<void> _restoreTap() async {
    if (firstOrig == null) return;
    if (!await _ask('ترجيع النطاقات للإعداد اللي كان وقت فتح هذي الصفحة؟')) return;
    setState(() {
      busy = true;
      msg = 'جاري الترجيع...';
    });
    try {
      await _restore();
      _say('أُرسل الإعداد الأصلي.');
    } catch (e) {
      _say('تعذّر الترجيع: $e');
    } finally {
      await _load();
    }
  }

  Future<void> _restoreFirst() async {
    final f = widget.restoreOriginal;
    if (f == null) return;
    if (!await _ask('الرجوع للإعداد الأول المحفوظ لهذا الراوتر؟\n${widget.originalText}')) return;
    setState(() {
      busy = true;
      msg = 'جاري الرجوع للإعداد الأول...';
    });
    var ok = false;
    var text = '';
    try {
      final r = await f();
      ok = r.$1;
      text = r.$2;
    } catch (e) {
      text = 'تعذّر الرجوع: $e';
    }
    await _load();
    await _alert(ok ? 0 : 2, ok ? 'تم الرجوع للإعداد الأول' : 'ما تم الرجوع', <String>[text]);
  }


  Future<void> _showReport(String title, String out) async {
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
              title: Text(title),
              content: SizedBox(
                  width: double.maxFinite,
                  child: SingleChildScrollView(
                      child: SelectableText(out, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 11)))),
              actions: [
                TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: out)), child: const Text('نسخ')),
                TextButton(onPressed: () => Navigator.pop(d), child: const Text('إغلاق')),
              ],
            ));
  }

  /// يكتشف اسم وصيغة حقل قفل 5G اللي يقبله الراوتر فعلًا: يرسل كل نطاقات 5G (بدون تقييد، فما يتغير سلوك الراوتر)
  /// بأسماء وصيغ محتملة، ثم يقرأ net-mode ويشوف أي حقل جديد ظهر. الحقل اللي يرجع بالقراءة هو الحقل الحقيقي.
  Future<void> _discover5g() async {
    if (!await _ask('راح أجرّب أسماء وصيغ حقل 5G على الراوتر لأعرف أيها يقبله.\n'
        'التجربة ترسل كل نطاقات 5G بدون تقييد مع نفس وضعك ونطاقات 4G الحالية، فما يتغير شي فعليًا، لكن قد ينقطع الاتصال لحظات.\n\nأكمل؟')) {
      return;
    }
    setState(() {
      busy = true;
      msg = 'جاري اكتشاف طريقة قفل 5G، لا تقفل الصفحة...';
    });
    final rep = StringBuffer();
    String? foundKey;
    try {
      final base = _kv(await widget.rd('net/net-mode'));
      rep.writeln('حقول net-mode قبل: ${base.keys.join(', ')}');
      final core = <String, String>{
        for (final e in base.entries)
          if (e.key.toLowerCase().contains('band') || e.key.toLowerCase().contains('mode')) e.key: e.value
      };
      _fixNb(core);
      final allNr = nrAll.isEmpty ? _kNrDefault.toList() : List<int>.from(nrAll);
      final fmts = <String, String>{
        'hex': _hexOf(allNr, ''),
        'n+': allNr.map((b) => 'n$b').join('+'),
        'csv': allNr.join(','),
      };
      var allErr = true;
      for (final f in fmts.entries) {
        final m = Map<String, String>.from(core);
        for (final k in _kNrCand) {
          m[k] = f.value;
        }
        String r;
        try {
          r = await _send(_xml(m));
        } catch (e) {
          r = 'خطأ: $e';
        }
        final er = _errCode(r);
        rep.writeln('إرسال كل الأسماء بصيغة [${f.key}] -> ${er != null ? 'error $er' : 'تم القبول بدون خطأ'}');
        if (er != null) continue;
        allErr = false;
        await Future<void>.delayed(const Duration(seconds: 6));
        var c = <String, String>{};
        try {
          c = _kv(await widget.rd('net/net-mode'));
          if (!c.containsKey('LTEBand')) {
            await widget.relogin();
            c = _kv(await widget.rd('net/net-mode'));
          }
        } catch (e) {
          rep.writeln('قراءة net-mode: $e');
        }
        final nw = c.entries.where((e) => !base.containsKey(e.key)).toList();
        if (nw.isNotEmpty) {
          foundKey = nw.first.key;
          rep.writeln('ظهر حقل جديد بعد الإرسال: ${nw.map((e) => '${e.key}=${e.value}').join(' | ')}  (الصيغة: ${f.key})');
          break;
        }
        rep.writeln('ما ظهر أي حقل 5G جديد بعد القراءة.');
      }
      if (foundKey == null && allErr) {
        rep.writeln('الراوتر رفض الإرسال الجماعي، أجرّب كل اسم لحاله بصيغة hex:');
        for (final k in _kNrCand) {
          final m = Map<String, String>.from(core)..[k] = fmts['hex']!;
          String r;
          try {
            r = await _send(_xml(m));
          } catch (e) {
            r = 'خطأ: $e';
          }
          final er = _errCode(r);
          rep.writeln('$k -> ${er != null ? 'error $er' : 'مقبول'}');
          if (er != null) continue;
          await Future<void>.delayed(const Duration(seconds: 6));
          try {
            final c = _kv(await widget.rd('net/net-mode'));
            final nw = c.entries.where((e) => !base.containsKey(e.key)).toList();
            if (nw.isNotEmpty) {
              foundKey = nw.first.key;
              rep.writeln('ظهر حقل جديد: ${nw.map((e) => '${e.key}=${e.value}').join(' | ')}');
              break;
            }
          } catch (e) {
            rep.writeln('قراءة: $e');
          }
        }
      }
      rep.writeln('\nالنتيجة: ${foundKey == null ? 'الراوتر ما قبل أي حقل 5G في net-mode.' : 'الحقل المقبول: $foundKey'}');
      rep.writeln('\n## net-mode-list\n${_hide(listRaw.length > 3000 ? listRaw.substring(0, 3000) : listRaw)}');
      try {
        final sg = _hide(await widget.rd('device/signal'));
        rep.writeln('\n## device/signal\n${sg.length > 1800 ? sg.substring(0, 1800) : sg}');
      } catch (_) {}
      for (final p in const [
        'net/nr-band', 'net/nrband', 'net/nsa-band', 'net/sa-band', 'net/net-nr-band', 'net/nr-net-mode',
        'net/net-feature-switch', 'net/network', 'net/lte-band-lock', 'device/antenna_type',
      ]) {
        String r;
        try {
          final x = await widget.rd(p);
          final e = _errCode(x);
          r = e != null ? 'error $e' : (_hide(x).length > 300 ? _hide(x).substring(0, 300) : _hide(x));
        } catch (_) {
          r = 'خطأ اتصال';
        }
        rep.writeln('## GET $p -> $r');
      }
    } catch (e) {
      rep.writeln('خطأ: $e');
    } finally {
      await _load();
    }
    await _showReport(foundKey == null ? 'الراوتر ما قبل حقل 5G' : 'لقيت حقل قفل 5G: $foundKey', rep.toString());
  }

  Future<void> _diag() async {
    String cut(String x, int n) => x.length > n ? x.substring(0, n) : x;
    final b = StringBuffer();
    try {
      b.writeln('## net-mode\n${cut(_hide(await widget.rd('net/net-mode')), 1500)}\n');
      b.writeln('## net-mode-list\n${cut(_hide(listRaw), 3000)}\n');
      b.writeln('## device/signal\n${cut(_hide(await widget.rd('device/signal')), 1800)}\n');
      for (final p in const ['net/nr-band', 'net/nrband', 'net/net-nr-band', 'net/nsa-band', 'net/net-feature-switch', 'net/network']) {
        String r;
        try {
          final x = await widget.rd(p);
          final e = _errCode(x);
          r = e != null ? 'error $e' : cut(_hide(x), 300);
        } catch (_) {
          r = 'خطأ اتصال';
        }
        b.writeln('## GET $p -> $r');
      }
    } catch (e) {
      b.writeln('خطأ: $e');
    }
    final out = b.toString();
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
              title: const Text('تشخيص'),
              content: SizedBox(
                  width: double.maxFinite,
                  child: SingleChildScrollView(
                      child: SelectableText(out, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 11)))),
              actions: [
                TextButton(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: out));
                    },
                    child: const Text('نسخ')),
                TextButton(onPressed: () => Navigator.pop(d), child: const Text('إغلاق')),
              ],
            ));
  }

  Future<void> _saveProfile() async {
    final c = TextEditingController();
    final name = await showDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
              title: const Text('اسم الإعداد (مثلًا STC)'),
              content: TextField(controller: c, autofocus: true),
              actions: [
                TextButton(onPressed: () => Navigator.pop(d), child: const Text('إلغاء')),
                FilledButton(onPressed: () => Navigator.pop(d, c.text.trim()), child: const Text('حفظ')),
              ],
            ));
    if (name == null || name.isEmpty) return;
    final l = lte.toList()..sort();
    final n = nr.toList()..sort();
    profiles[name] = <String, List<int>>{'lte': l, 'nr': n};
    profMode[name] = mode;
    try {
      await _writeProfiles();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _delProfile(String name) async {
    profiles.remove(name);
    profMode.remove(name);
    try {
      await _writeProfiles();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Widget _card(String t, List<Widget> kids) => Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...kids,
          ])));

  Widget _section(String title, List<int> all, Set<int> sel, String prefix) {
    return _card(title, [
      Wrap(spacing: 6, runSpacing: 2, children: [
        for (final b in all)
          FilterChip(
            label: Text('$prefix$b'),
            selected: sel.contains(b),
            selectedColor: _kGreen,
            checkmarkColor: Colors.black,
            labelStyle: TextStyle(color: sel.contains(b) ? Colors.black : null),
            onSelected: busy
                ? null
                : (v) => setState(() {
                      if (v) {
                        sel.add(b);
                      } else {
                        sel.remove(b);
                      }
                    }),
          ),
      ]),
      Row(children: [
        TextButton(onPressed: busy ? null : () => setState(() => sel.addAll(all)), child: const Text('تحديد الكل')),
        TextButton(onPressed: busy ? null : () => setState(sel.clear), child: const Text('مسح')),
      ]),
    ]);
  }

  Widget _status() {
    final b = sig['band'] ?? '';
    final hasLte = b.isNotEmpty && (sig['rsrp'] ?? '').isNotEmpty;
    final hasNr = (sig['nrrsrp'] ?? '').isNotEmpty;
    final t = hasLte && hasNr ? '4G + 5G معًا' : hasNr ? '5G فقط' : hasLte ? '4G فقط' : 'لا توجد إشارة (قد يكون الراوتر يعيد الاتصال)';
    final parts = <String>[
      if (hasLte) 'رئيسي: B$b',
      if (hasNr) '5G: ${nrBandNum(sig) == null ? (sig['nrdlfreq'] ?? '') : 'n${nrBandNum(sig)}'}',
      if ((sig['rsrp'] ?? '').isNotEmpty) 'RSRP ${sig['rsrp']}',
      if ((sig['sinr'] ?? '').isNotEmpty) 'SINR ${sig['sinr']}',
    ];
    return _card('الشبكة الآن: $t', [Text(parts.isEmpty ? '-' : parts.join('   ·   '))]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('النطاقات (تعديل وقفل)'), actions: [
        IconButton(onPressed: busy ? null : _load, icon: const Icon(Icons.refresh), tooltip: 'تحديث'),
        IconButton(onPressed: busy ? null : _diag, icon: const Icon(Icons.bug_report), tooltip: 'تشخيص'),
        IconButton(onPressed: busy ? null : _discover5g, icon: const Icon(Icons.manage_search), tooltip: 'اكتشاف قفل 5G'),
      ]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (busy) const LinearProgressIndicator(),
        _status(),
        _card('وضع الشبكة', [
          Wrap(spacing: 6, children: [
            for (final m in modes)
              ChoiceChip(
                label: Text(_modeName[m] ?? m),
                selected: mode == m,
                selectedColor: _kGreen,
                labelStyle: TextStyle(color: mode == m ? Colors.black : null),
                onSelected: busy ? null : (_) => setState(() => mode = m),
              ),
          ]),
        ]),
        _section('نطاقات 4G (LTE)', lteAll, lte, 'B'),
        if (nrKey == null)
          _card('نطاقات 5G', [
            const Text('الراوتر ما أرجع حقل نطاقات 5G داخل net-mode، فما أقدر أقفلها من هنا. اضغط أيقونة التشخيص وأرسل لي النتيجة.')
          ])
        else if (!nrOk)
          _card('نطاقات 5G', [
            Text('الحقل $nrKey موجود لكن صيغته غير مفهومة: ${orig[nrKey!] ?? ''}. أرسل لي نتيجة التشخيص.')
          ])
        else ...[
          if (nrForce)
            _card('تنبيه', [
              const Text('الراوتر ما يعلن نطاقات 5G في net-mode، فالقفل هنا تجريبي: أرسل الحقل وأتأكد من القراءة. إذا تجاهله الراوتر ما يصير قفل 5G ويبقى قفل 4G.')
            ]),
          _section('نطاقات 5G (NR)', nrAll, nr, 'N'),
        ],
        _card('إعدادات محفوظة', [
          if (profiles.isEmpty) const Text('احفظ اختيارك باسم الشركة (STC / Zain / Mobily) وبدّل بينها بضغطة.'),
          Wrap(spacing: 6, children: [
            for (final e in profiles.entries)
              InputChip(
                label: Text(e.key),
                onPressed: busy
                    ? null
                    : () => setState(() {
                          lte = (e.value['lte'] ?? <int>[]).toSet().intersection(lteAll.toSet());
                          nr = (e.value['nr'] ?? <int>[]).toSet().intersection(nrAll.toSet());
                          final pm = profMode[e.key];
                          if (pm != null && modes.contains(pm)) mode = pm;
                        }),
                onDeleted: () => _delProfile(e.key),
              ),
          ]),
          TextButton.icon(
              onPressed: busy ? null : _saveProfile, icon: const Icon(Icons.save), label: const Text('حفظ الاختيار الحالي')),
        ]),
        FilledButton.icon(
            onPressed: busy ? null : _apply, icon: const Icon(Icons.lock), label: const Text('تطبيق القفل')),
        const SizedBox(height: 8),
        OutlinedButton.icon(
            onPressed: (busy || firstOrig == null) ? null : _restoreTap,
            icon: const Icon(Icons.undo),
            label: const Text('استعادة الإعداد الأصلي')),
        if (widget.restoreOriginal != null) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
              onPressed: busy ? null : _restoreFirst,
              icon: const Icon(Icons.settings_backup_restore),
              label: const Text('رجوع للإعداد الأول (المحفوظ للراوتر)')),
          if (widget.originalText.isNotEmpty)
            Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('المحفوظ: ${widget.originalText}', style: const TextStyle(fontSize: 11, color: Colors.white54))),
        ],
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText(msg)),
      ]),
    );
  }
}
