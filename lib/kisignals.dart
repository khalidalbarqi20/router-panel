import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const FlutterSecureStorage _st = FlutterSecureStorage();
const List<int> _lteAll = <int>[1, 2, 3, 4, 5, 7, 8, 12, 13, 14, 17, 20, 25, 26, 28, 29, 32, 34, 38, 39, 40, 41, 42, 43];
const List<int> _nrAll = <int>[1, 2, 3, 5, 7, 8, 20, 25, 28, 38, 40, 41, 66, 71, 77, 78, 79, 260, 261];

Map<String, String> _kv(String x) =>
    <String, String>{for (final m in RegExp(r'<(\w+)>([^<]*)</\1>').allMatches(x)) m[1]!: m[2]!};

String? _err(String x) =>
    x.contains('<error>') ? (RegExp(r'<code>([^<]*)</code>').firstMatch(x)?[1] ?? '?') : null;

double? _n(String? s) {
  if (s == null) return null;
  final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(s);
  return m == null ? null : double.tryParse(m[0]!);
}

double? _mhz(String? s) {
  final v = _n(s);
  if (v == null) return null;
  final t = (s ?? '').toLowerCase();
  if (t.contains('ghz')) return v * 1000;
  if (t.contains('khz') || v > 100000) return v / 1000;
  return v;
}

/// تقدير نطاق 5G من التردد (الراوتر ما يعطي اسم النطاق مباشرة).
String _nrBand(double mhz) {
  const t = <List<int>>[
    [1, 2110, 2170], [3, 1805, 1880], [5, 869, 894], [7, 2620, 2690], [8, 925, 960],
    [20, 791, 821], [28, 758, 803], [38, 2570, 2620], [40, 2300, 2400], [41, 2496, 2690],
    [66, 2110, 2200], [71, 617, 652], [77, 3300, 4200], [78, 3300, 3800], [79, 4400, 5000],
    [260, 37000, 40000], [261, 27500, 28350],
  ];
  int? best;
  var w = 1 << 30;
  for (final x in t) {
    if (mhz >= x[1] && mhz <= x[2] && (x[2] - x[1]) < w) {
      w = x[2] - x[1];
      best = x[0];
    }
  }
  return best == null ? 'N?' : 'N$best';
}

String _xml(Map<String, String> m) => m.entries.map((e) => '<${e.key}>${e.value}</${e.key}>').join();

Color _col(double? v, double good, double ok) {
  if (v == null) return Colors.white38;
  if (v >= good) return const Color(0xFF39D353);
  if (v >= ok) return Colors.amber;
  return Colors.redAccent;
}

class KiSignals extends StatefulWidget {
  final Future<String> Function(String) rd;
  final Future<String> Function(String, String) wr;
  final Future<void> Function() relogin;
  const KiSignals({super.key, required this.rd, required this.wr, required this.relogin});

  @override
  State<KiSignals> createState() => _KiSignalsState();
}

class _KiSignalsState extends State<KiSignals> {
  Timer? _t;
  bool busy = false;
  bool _tickBusy = false;
  DateTime _lastLogin = DateTime.fromMillisecondsSinceEpoch(0);
  String msg = '';
  String net = 'جاري القراءة...';
  List<String> roles = <String>[];
  List<String> rows = <String>[];
  Set<String> live = <String>{};
  final Map<String, Map<String, double?>> data = <String, Map<String, double?>>{};
  final Map<String, DateTime> when = <String, DateTime>{};

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final raw = await _st.read(key: 'ki_sig_rows');
      if (raw != null) rows = (jsonDecode(raw) as List).map((e) => e.toString()).toList();
    } catch (_) {}
    await _tick();
    _t = Timer.periodic(const Duration(seconds: 3), (_) => _tick());
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

  Future<void> _tick() async {
    if (busy || _tickBusy || !mounted) return;
    _tickBusy = true;
    try {
      _ingest(_kv(await widget.rd('device/signal')));
    } catch (_) {
      if (DateTime.now().difference(_lastLogin).inSeconds > 30) {
        _lastLogin = DateTime.now();
        try {
          await widget.relogin();
        } catch (_) {}
      }
    }
    _tickBusy = false;
    if (mounted) setState(() {});
  }

  void _ingest(Map<String, String> s) {
    final lv = <String>{};
    final b = s['band'] ?? '';
    final hasLte = b.isNotEmpty && _n(s['rsrp']) != null;
    final hasNr = _n(s['nrrsrp']) != null;
    if (hasLte) {
      final k = 'B$b';
      data[k] = <String, double?>{'sinr': _n(s['sinr']), 'rsrq': _n(s['rsrq']), 'rsrp': _n(s['rsrp']), 'rssi': _n(s['rssi'])};
      when[k] = DateTime.now();
      lv.add(k);
    }
    var nk = 'N?';
    if (hasNr) {
      final f = _mhz(s['nrdlfreq']);
      nk = f == null ? 'N?' : _nrBand(f);
      data[nk] = <String, double?>{'sinr': _n(s['nrsinr']), 'rsrq': _n(s['nrrsrq']), 'rsrp': _n(s['nrrsrp']), 'rssi': null};
      when[nk] = DateTime.now();
      lv.add(nk);
    }
    final r = <String>[];
    if (hasLte) {
      r.add('رئيسي (4G): B$b · ${s['dlfrequency'] ?? ''} · عرض ${s['dlbandwidth'] ?? ''} · PCI ${s['pci'] ?? ''}');
    }
    final scc = <String>[
      for (final e in s.entries)
        if (e.key.toLowerCase().startsWith('scc') && e.value.isNotEmpty) '${e.key}=${e.value}'
    ];
    if (scc.isNotEmpty) r.add('ثانوي (تجميع 4G): ${scc.join(' · ')}');
    if (hasNr) {
      r.add('ثانوي (5G): $nk · ${s['nrdlfreq'] ?? ''} · عرض ${s['nrdlbandwidth'] ?? ''}');
    }
    live = lv;
    roles = r;
    net = hasLte && hasNr ? '4G + 5G معًا (NSA)' : hasNr ? '5G فقط' : hasLte ? '4G فقط' : 'لا توجد إشارة';
  }

  Future<void> _saveRows() async {
    try {
      await _st.write(key: 'ki_sig_rows', value: jsonEncode(rows));
    } catch (_) {}
  }

  void _toggle(String k, bool on) {
    if (on) {
      if (!rows.contains(k)) rows.add(k);
    } else {
      rows.remove(k);
    }
    _saveRows();
    if (mounted) setState(() {});
  }

  Future<void> _addSheet() async {
    await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (c) => StatefulBuilder(builder: (c2, setS) {
              Widget chip(String k) => FilterChip(
                  label: Text(k),
                  selected: rows.contains(k),
                  onSelected: (v) {
                    _toggle(k, v);
                    setS(() {});
                  });
              return SafeArea(
                  child: SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const Text('نطاقات 5G', style: TextStyle(fontWeight: FontWeight.bold)),
                        Wrap(spacing: 6, children: [for (final b in _nrAll) chip('N$b')]),
                        const SizedBox(height: 12),
                        const Text('نطاقات 4G', style: TextStyle(fontWeight: FontWeight.bold)),
                        Wrap(spacing: 6, children: [for (final b in _lteAll) chip('B$b')]),
                      ])));
            }));
  }

  List<String> _variants(Map<String, String> base, Map<String, String> over, String list) {
    final all = Map<String, String>.from(base)..addAll(over);
    final fixed = Map<String, String>.from(all);
    final cur = fixed['NetworkBand'] ?? '';
    if (cur.isEmpty || RegExp(r'^0+$').hasMatch(cur)) {
      fixed['NetworkBand'] = RegExp(r'<Band>.*?<Value>([0-9a-fA-F]+)</Value>', dotAll: true).firstMatch(list)?[1] ?? '3fffffff';
    }
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
    for (final x in xs) {
      try {
        last = await widget.wr('net/net-mode', x);
      } catch (_) {
        await widget.relogin();
        last = await widget.wr('net/net-mode', x);
      }
      if (_err(last) != '100006') return last;
    }
    return last;
  }

  /// يقفل الراوتر على كل نطاق 4G في القائمة، يقرأ الإشارة، ثم يرجّع الإعداد الأصلي.
  Future<void> _measure() async {
    final targets = <int>[for (final k in rows) if (k.startsWith('B')) int.tryParse(k.substring(1)) ?? 0]
      ..removeWhere((b) => b < 1 || b > 64);
    if (targets.isEmpty) {
      _say('أضف نطاق 4G واحد على الأقل (يبدأ بـ B).');
      return;
    }
    if (!await _ask('سأقفل الراوتر على كل نطاق 4G في القائمة واحدًا واحدًا لقياسه، ثم أرجّع الإعداد الأصلي. قد ينقطع الإنترنت عدة دقائق. متأكد؟')) return;
    setState(() {
      busy = true;
      msg = 'جاري القياس...';
    });
    var base = <String, String>{};
    var list = '';
    final notes = <String>[];
    try {
      list = await widget.rd('net/net-mode-list');
      base = _kv(await widget.rd('net/net-mode'));
      for (final b in targets) {
        _say('يقيس B$b ...');
        final mask = (BigInt.one << (b - 1)).toRadixString(16);
        final r = await _sendAny(_variants(base, <String, String>{'LTEBand': mask}, list));
        final e = _err(r);
        if (e != null) {
          notes.add('B$b: الراوتر رفض القفل (كود $e)');
          break;
        }
        var got = false;
        for (var i = 0; i < 20 && !got; i++) {
          await Future<void>.delayed(const Duration(seconds: 3));
          try {
            final s = _kv(await widget.rd('device/signal'));
            if (s['band'] == '$b' && _n(s['rsrp']) != null) {
              await Future<void>.delayed(const Duration(seconds: 4));
              _ingest(_kv(await widget.rd('device/signal')));
              got = true;
            }
          } catch (_) {
            try {
              await widget.relogin();
            } catch (_) {}
          }
        }
        notes.add(got ? 'B$b: تم' : 'B$b: ما اتصل خلال دقيقة (ربما غير متوفر عندك)');
      }
    } catch (e) {
      notes.add('تعذّر القياس: $e');
    } finally {
      try {
        if (base.isNotEmpty) await _sendAny(_variants(base, <String, String>{}, list));
        notes.add('أُرسل الإعداد الأصلي.');
      } catch (_) {
        notes.add('تعذّر إرجاع الإعداد الأصلي، رجّعه من صفحة قفل النطاقات.');
      }
      if (mounted) {
        setState(() {
          busy = false;
          msg = notes.join('\n');
        });
      }
    }
  }

  String _age(String k) {
    final t = when[k];
    if (t == null) return 'لم تُقرأ بعد';
    final d = DateTime.now().difference(t).inSeconds;
    if (d < 5) return 'الآن';
    if (d < 90) return 'قبل ${d}ث';
    return 'قبل ${d ~/ 60}د';
  }

  Widget _cell(double? v, double good, double ok) => Expanded(
      child: Text(v == null ? '-' : v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1),
          textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, color: _col(v, good, ok))));

  Widget _head() => const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(children: [
        SizedBox(width: 78, child: Text('النطاق', style: TextStyle(fontSize: 11, color: Colors.white54))),
        Expanded(child: Text('SINR', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.white54))),
        Expanded(child: Text('RSRQ', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.white54))),
        Expanded(child: Text('RSRP', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.white54))),
        Expanded(child: Text('RSSI', textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: Colors.white54))),
        SizedBox(width: 32),
      ]));

  Widget _row(String k) {
    final d = data[k];
    final on = live.contains(k);
    return Card(
        margin: const EdgeInsets.only(bottom: 6),
        child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(children: [
              SizedBox(
                  width: 78,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      if (on) const Icon(Icons.circle, size: 9, color: Color(0xFF39D353)),
                      if (on) const SizedBox(width: 4),
                      Text(k, style: const TextStyle(fontWeight: FontWeight.bold)),
                    ]),
                    Text(on ? 'متصل الآن' : _age(k), style: const TextStyle(fontSize: 10, color: Colors.white54)),
                  ])),
              _cell(d?['sinr'], 13, 0),
              _cell(d?['rsrq'], -10, -15),
              _cell(d?['rsrp'], -90, -105),
              _cell(d?['rssi'], -65, -80),
              SizedBox(
                  width: 32,
                  child: IconButton(
                      padding: EdgeInsets.zero,
                      onPressed: busy ? null : () => _toggle(k, false),
                      icon: const Icon(Icons.close, size: 18))),
            ])));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('إشارات الترددات'), actions: [
        IconButton(onPressed: busy ? null : _addSheet, icon: const Icon(Icons.add), tooltip: 'إضافة تردد'),
      ]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (busy) const LinearProgressIndicator(),
        Card(
            child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('الشبكة الآن', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  Text(net, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  for (final r in roles) Padding(padding: const EdgeInsets.only(top: 2), child: Text(r, style: const TextStyle(fontSize: 12))),
                ]))),
        const SizedBox(height: 8),
        if (rows.isEmpty)
          const Padding(
              padding: EdgeInsets.all(16),
              child: Text('اضغط + وأضف الترددات اللي تبي تقارنها. كل تردد يظهر بسطر.', textAlign: TextAlign.center))
        else ...[
          _head(),
          for (final k in rows) _row(k),
        ],
        const SizedBox(height: 8),
        FilledButton.icon(onPressed: busy ? null : _measure, icon: const Icon(Icons.speed), label: const Text('قياس نطاقات 4G في القائمة')),
        const SizedBox(height: 6),
        const Text(
            'القيم تتحدث تلقائيًا للنطاق المتصل الآن. نطاقات 5G تُقرأ فقط حين يتصل الراوتر بها، لأن راوترك ما يسمح بقفلها.',
            style: TextStyle(fontSize: 11, color: Colors.white54)),
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: SelectableText(msg)),
      ]),
    );
  }
}
