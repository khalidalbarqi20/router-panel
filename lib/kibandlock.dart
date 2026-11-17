import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const Color _kGreen = Color(0xFF39D353);
const FlutterSecureStorage _store = FlutterSecureStorage();

/// قوائم احتياطية إذا الراوتر ما أعطى قائمة نطاقاته (نفس نطاقات تطبيق 5GCtrl).
const List<int> _kNrDefault = <int>[1, 2, 3, 5, 20, 25, 28, 40, 41, 66, 71, 77, 78, 260, 261];
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
      final nrFound = <int>{
        for (final m in RegExp(r'(?<![A-Za-z0-9])[Nn](\d{1,3})(?![0-9A-Za-z])').allMatches(l))
          if (int.parse(m[1]!) >= 1 && int.parse(m[1]!) <= 300) int.parse(m[1]!)
      };
      final nrList = (nrFound.length >= 3 ? nrFound.toList() : _kNrDefault.toList())..sort();

      listRaw = l;
      orig = n;
      firstOrig ??= Map<String, String>.from(n);
      sig = s;
      nrKey = key;
      nrOk = ok;
      lteAll = lteList;
      nrAll = nrList;
      lte = _bitsOf(n['LTEBand'] ?? '0', 64).intersection(lteList.toSet());
      nr = ok ? _bitsOf(n[key]!, 300).intersection(nrList.toSet()) : <int>{};
    } catch (e) {
      msg = 'ما قدرت أقرأ الراوتر: $e';
    }
    if (mounted) setState(() => busy = false);
  }

  /// يبني جسم الطلب: كل حقول النطاق والوضع من قراءة الراوتر، مع استبدال ماسك 4G و5G.
  Map<String, String> _body(Set<int> l, Set<int> n) {
    final out = <String, String>{};
    for (final e in orig.entries) {
      final k = e.key.toLowerCase();
      if (k.contains('band') || k.contains('mode')) out[e.key] = e.value;
    }
    out['LTEBand'] = _hexOf(l, orig['LTEBand'] ?? '');
    if (nrKey != null && nrOk) out[nrKey!] = _hexOf(n, orig[nrKey!] ?? '');
    return out;
  }

  String _xml(Map<String, String> m) => m.entries.map((e) => '<${e.key}>${e.value}</${e.key}>').join();

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
  Future<bool> _verify(Set<int> l, Set<int> n) async {
    await Future<void>.delayed(const Duration(seconds: 12));
    for (var i = 0; i < 8; i++) {
      try {
        await widget.relogin();
        final c = _kv(await widget.rd('net/net-mode'));
        final okL = _parse(c['LTEBand'] ?? '') == _mask(l);
        final okN = !(nrKey != null && nrOk) || _parse(c[nrKey!] ?? '') == _mask(n);
        return okL && okN;
      } catch (_) {
        await Future<void>.delayed(const Duration(seconds: 6));
      }
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
    final m = <String, String>{};
    for (final e in f.entries) {
      final k = e.key.toLowerCase();
      if (k.contains('band') || k.contains('mode')) m[e.key] = e.value;
    }
    await _send(_xml(m));
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
      final r = await _send(_xml(_body(lte, nr)));
      final e = _errCode(r);
      if (e != null) {
        _say('الراوتر رفض الطلب (كود $e). ما تغيّر شي.');
        return;
      }
      final ok = await _verify(lte, nr);
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
      _say('تم التطبيق وتأكدت القراءة، والراوتر متصل.');
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
      b.writeln('## device/signal\n${cut(_hide(await widget.rd('device/signal')), 1800)}');
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
    final nb = sig['nrband'] ?? '';
    final parts = <String>[
      if (b.isNotEmpty) '4G: B$b',
      if (nb.isNotEmpty && nb != 'None') '5G: $nb',
      if ((sig['rsrp'] ?? '').isNotEmpty) 'RSRP ${sig['rsrp']}',
      if ((sig['nrrsrp'] ?? '').isNotEmpty && sig['nrrsrp'] != 'None') 'NR RSRP ${sig['nrrsrp']}',
    ];
    return _card('المتصل الآن', [Text(parts.isEmpty ? 'لا توجد قراءة' : parts.join('   ·   '))]);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('قفل النطاقات'), actions: [
        IconButton(onPressed: busy ? null : _load, icon: const Icon(Icons.refresh), tooltip: 'تحديث'),
        IconButton(onPressed: busy ? null : _diag, icon: const Icon(Icons.bug_report), tooltip: 'تشخيص'),
      ]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (busy) const LinearProgressIndicator(),
        _status(),
        if (nrKey == null)
          _card('نطاقات 5G', [
            const Text('الراوتر ما أرجع حقل نطاقات 5G داخل net-mode، فما أقدر أقفلها من هنا. اضغط أيقونة التشخيص وأرسل لي النتيجة.')
          ])
        else if (!nrOk)
          _card('نطاقات 5G', [
            Text('الحقل $nrKey موجود لكن صيغته غير مفهومة: ${orig[nrKey!] ?? ''}. أرسل لي نتيجة التشخيص.')
          ])
        else
          _section('نطاقات 5G (NR)', nrAll, nr, 'N'),
        _section('نطاقات 4G (LTE)', lteAll, lte, 'B'),
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
