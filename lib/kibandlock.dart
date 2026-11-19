import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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

String _hide(String x) => x.replaceAllMapped(
    RegExp(r'<(\w*(?:imei|imsi|serial|mac|iccid|msisdn|phone|number|ssid)\w*)>[^<]+</', caseSensitive: false),
    (m) => '<${m[1]}>***</');

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
String? _nrKey(Map<String, String> n) {
  for (final k in n.keys) {
    final l = k.toLowerCase();
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
  const KiBandLock({super.key, required this.rd, required this.wr, required this.relogin});

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

  Future<void> _loadProfiles() async {
    try {
      final raw = await _store.read(key: 'band_profiles');
      if (raw == null) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final out = <String, Map<String, List<int>>>{};
      for (final e in j.entries) {
        final v = e.value as Map<String, dynamic>;
        out[e.key] = <String, List<int>>{
          'lte': <int>[for (final x in (v['lte'] as List)) x as int],
          'nr': <int>[for (final x in (v['nr'] as List)) x as int],
        };
      }
      profiles = out;
    } catch (_) {}
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

  Future<void> _apply() async {
    if (lte.isEmpty) {
      _say('اختر نطاق 4G واحد على الأقل.');
      return;
    }
    if (nrKey != null && nrOk && nr.isEmpty) {
      _say('اختر نطاق 5G واحد على الأقل. (لإيقاف 5G استخدم وضع 4G فقط من صفحة MODES.)');
      return;
    }
    final go = await _ask(
        'سيُطبَّق القفل وقد ينقطع الإنترنت قرابة دقيقة. إذا ما رجع الاتصال خلال دقيقتين يرجع الإعداد الأصلي تلقائيًا. متأكد؟');
    if (!go) return;
    setState(() {
      busy = true;
      msg = 'جاري التطبيق، لا تقفل الصفحة...';
    });
    try {
      final force = nrForce;
      final r = await _sendAny(_variants(orig, _over(lte, nr, withNr: !force)));
      final e = _errCode(r);
      if (e != null) {
        _say('الراوتر رفض الطلب (كود $e). ما تغيّر شي.');
        return;
      }
      final ok = await _verify(lte, nr, nrToo: !force);
      if (!ok) {
        _say('ما قدرت أتأكد أن الراوتر أخذ القفل كما هو. اضغط أيقونة التشخيص وأرسل لي النتيجة.');
        return;
      }
      final up = await _connected(120);
      if (!up) {
        await _restore();
        _say('الاتصال ما رجع خلال دقيقتين، فرجّعت الإعداد الأصلي.');
        return;
      }
      var extra = '';
      if (force) {
        final r2 = await _sendAny(_variants(orig, _over(lte, nr)));
        final e2 = _errCode(r2);
        if (e2 != null) {
          extra = '\nالراوتر رفض حقل 5G (كود $e2)، فتم قفل 4G فقط.';
        } else {
          await Future<void>.delayed(const Duration(seconds: 8));
          final c = _kv(await widget.rd('net/net-mode'));
          final k = _nrKey(c);
          if (k != null && _parse(c[k] ?? '') == _mask(nr)) {
            extra = '\nالراوتر قبل قفل 5G وأرجعه بالقراءة.';
          } else {
            extra = '\nالراوتر ما أعاد حقل 5G بعد الإرسال، فالأغلب تجاهله ولا يدعم قفل 5G من هذي الواجهة. تم قفل 4G فقط.';
          }
        }
      }
      _say('تم التطبيق وتأكدت القراءة، والراوتر متصل. (شكل الطلب ${_vOk + 1})$extra');
    } catch (e) {
      _say('تعذّر الاتصال بالراوتر: $e');
    } finally {
      await _load();
    }
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
    try {
      await _store.write(key: 'band_profiles', value: jsonEncode(profiles));
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _delProfile(String name) async {
    profiles.remove(name);
    try {
      await _store.write(key: 'band_profiles', value: jsonEncode(profiles));
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
      if (hasNr) '5G: ${sig['nrband'] ?? ''}',
      if ((sig['rsrp'] ?? '').isNotEmpty) 'RSRP ${sig['rsrp']}',
      if ((sig['sinr'] ?? '').isNotEmpty) 'SINR ${sig['sinr']}',
    ];
    return _card('الشبكة الآن: $t', [Text(parts.isEmpty ? '-' : parts.join('   ·   '))]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الراوتر والنطاقات'), actions: [
        IconButton(onPressed: busy ? null : _load, icon: const Icon(Icons.refresh), tooltip: 'تحديث'),
        IconButton(onPressed: busy ? null : _diag, icon: const Icon(Icons.bug_report), tooltip: 'تشخيص'),
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
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText(msg)),
      ]),
    );
  }
}
