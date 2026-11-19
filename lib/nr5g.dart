import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'bands.dart';
import 'dbg.dart';
import 'game.dart';

const FlutterSecureStorage _n5St = FlutterSecureStorage();
const Color _n5Green = Color(0xFF39D353);

Map<String, String> _n5kv(String x) {
  final m = <String, String>{};
  for (final r in RegExp(r'<(\w+)>([^<]*)</\1>').allMatches(x)) {
    m[r[1]!] = r[2]!;
  }
  return m;
}

String _n5tag(String x, String t) => RegExp('<$t>([^<]*)</$t>').firstMatch(x)?[1] ?? '';

String? _n5err(String x) {
  if (!x.contains('<error>')) return null;
  return RegExp(r'<code>([^<]*)</code>').firstMatch(x)?[1] ?? '?';
}

/// تصنيف رد الراوتر: ok = XML طبيعي، errNNN = كود خطأ، html = صفحة (مسار غير موجود يحوّل للصفحة الرئيسية).
String _n5cls(String x) {
  final e = _n5err(x);
  if (e != null) return 'err$e';
  if (x.contains('<response')) return 'ok';
  return 'html';
}

double? _n5num(String? s) {
  final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(s ?? '');
  return m == null ? null : double.tryParse(m[0]!);
}

String _n5f(double? v) => v == null ? '-' : v.toStringAsFixed(0);

List<List<String>> _n5rows(String v) {
  final out = <List<String>>[];
  for (final r in v.split(';')) {
    if (r.trim().isEmpty) continue;
    out.add(r.split(',').map((e) => e.trim()).toList());
  }
  return out;
}

class _N5Nr {
  final int? band;
  final double? rsrp, sinr;
  final String bw, arfcn;
  _N5Nr(this.band, this.rsrp, this.sinr, this.bw, this.arfcn);
}

/// حالة 5G الحالية من device/signal (null إذا ما فيه إشارة 5G).
_N5Nr? _n5nr(Map<String, String> s) {
  if (!hasNrSignal(s)) return null;
  var b = nrBandNum(s);
  if (b == null) {
    final m = RegExp(r'\(N(\d+)\)', caseSensitive: false).firstMatch(s['band'] ?? '');
    if (m != null) b = int.tryParse(m[1]!);
  }
  return _N5Nr(b, _n5num(s['nrrsrp']), _n5num(s['nrsinr']), s['nrdlbandwidth'] ?? '', s['nrearfcn'] ?? '');
}

/// نطاق 4G المسجَّل عليه الآن.
int? _n5lte(Map<String, String> s) {
  final a = RegExp(r'^\s*(\d+)\s*$').firstMatch(s['band'] ?? '');
  if (a != null) return int.tryParse(a[1]!);
  final m = RegExp(r'\(B(\d+)\)', caseSensitive: false).firstMatch(s['band'] ?? '');
  if (m != null) return int.tryParse(m[1]!);
  final c = RegExp(r'^B?(\d+)$', caseSensitive: false).firstMatch((s['bandInfo'] ?? '').trim());
  if (c != null) return int.tryParse(c[1]!);
  return null;
}

class _N5Res {
  final int lteBand;
  bool lteOk = false;
  String lteSeen = '', note = '';
  _N5Nr? nr;
  int secs = 0;
  _N5Res(this.lteBand);
}

/// فحص 5G: (1) قراءة فقط: قدرات الراوتر وإشارة 5G الحالية وجداول خلايا 5G.
/// (2) اختبار مرساة 4G: يقفل كل نطاق 4G لحاله ويشوف هل 5G يشتغل معه وعلى أي نطاق n وبأي إشارة، ثم يرجّع إعدادك.
class Nr5gScanPage extends StatefulWidget {
  final GameCtl ctl;
  final Future<String> Function(String) rd;
  final Future<void> Function() relogin;
  const Nr5gScanPage({super.key, required this.ctl, required this.rd, required this.relogin});

  @override
  State<Nr5gScanPage> createState() => _Nr5gState();
}

class _Nr5gState extends State<Nr5gScanPage> {
  bool busy = false, cancel = false, scanned = false;
  String err = '';
  String model = '', modeText = '';
  Map<String, String> sig = <String, String>{};
  _N5Nr? nrNow;
  List<List<String>> sccNr = <List<String>>[], nbrNr = <List<String>>[];
  String sccNote = '', nbrNote = '';
  final List<String> cap = <String>[];
  final Set<int> sel = <int>{};
  final Map<int, _N5Res> res = <int, _N5Res>{};
  final List<String> log = <String>[];
  String pendMask = '', pendMode = '';

  String get _rkey => 'n5g_restore_${widget.ctl.routerHost}';

  @override
  void initState() {
    super.initState();
    sel.addAll(widget.ctl.sup);
    _loadPending();
  }

  @override
  void dispose() {
    cancel = true;
    super.dispose();
  }

  void _log(String t) {
    if (mounted) setState(() => log.add(t));
  }

  Future<void> _loadPending() async {
    try {
      final v = await _n5St.read(key: _rkey);
      if (v == null) return;
      final m = jsonDecode(v) as Map;
      if (mounted) {
        setState(() {
          pendMask = (m['m'] ?? '').toString();
          pendMode = (m['d'] ?? '').toString();
        });
      }
    } catch (e) {
      dbg('nr5g.pending', e);
    }
  }

  Future<bool> _confirm(String t) async =>
      await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(content: Text(t), actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('متأكد')),
              ])) ??
      false;

  Future<String> _read(String p) async {
    try {
      return await widget.rd(p);
    } catch (e) {
      dbg('nr5g.read.$p', e);
      return '<error><code>net</code></error>';
    }
  }

  Future<void> _pause() => Future<void>.delayed(const Duration(milliseconds: 400));

  /// يقرأ الإشارة، وإذا الجلسة انتهت يسجّل دخول مرة وحدة ويعيد القراءة.
  Future<Map<String, String>> _sigFresh() async {
    var x = await _read('device/signal');
    final e = _n5err(x);
    if (e == '100003' || e == '125002' || e == '125003') {
      try {
        await widget.relogin();
      } catch (er) {
        dbg('nr5g.relogin', er);
      }
      x = await _read('device/signal');
    }
    return _n5kv(x);
  }

  bool _sigBad(Map<String, String> s) => s.containsKey('code') && !s.containsKey('rsrp') && !s.containsKey('nrrsrp');

  // ---------------------------------------------------------------- 1) قراءة فقط
  Future<void> _scan() async {
    if (busy) return;
    setState(() {
      busy = true;
      err = '';
      cap.clear();
      sccNr = <List<String>>[];
      nbrNr = <List<String>>[];
      sccNote = '';
      nbrNote = '';
    });
    try {
      final s = await _sigFresh();
      if (_sigBad(s)) {
        setState(() => err = 'ما قدرت أقرأ من الراوتر (كود ${s['code']}). ارجع للرئيسية وسجّل دخول ثم أعد المحاولة.');
        return;
      }
      await _pause();
      final basic = await _read('device/basic_information');
      await _pause();
      final nmX = await _read('net/net-mode');
      final nm = _n5kv(nmX);
      await _pause();
      final fsX = await _read('net/net-feature-switch');
      final fs = _n5kv(fsX);
      await _pause();
      final listX = await _read('net/net-mode-list');
      await _pause();
      final seccX = await _read('device/seccellinfo');
      await _pause();
      final nbrX = await _read('device/nbrcellinfo');

      final lines = <String>[];
      final nrKey = findNrKey(nm);
      lines.add(nrKey == null
          ? '• net-mode ما فيه حقل نطاقات 5G (حقوله: ${nm.keys.join(', ')}). هذا طبيعي: نطاقات 5G في هذي الأجهزة ما تنضبط من net-mode.'
          : '• net-mode فيه حقل 5G: $nrKey');
      final nrInList = parseNrSupported(listX);
      lines.add(nrInList.isEmpty
          ? '• قائمة الراوتر (net-mode-list) ما تذكر أي نطاق 5G، فقراءة نطاقات 5G المدعومة ما تجي منها.'
          : '• قائمة الراوتر تذكر نطاقات 5G: ${nrInList.map((b) => 'n$b').join(' ')}');
      final acc = RegExp(r'<Access>(\w+)</Access>').allMatches(listX).map((m) => m[1]!).toList();
      lines.add('• الأوضاع اللي يعرضها الراوتر: ${acc.isEmpty ? '-' : acc.join(' ')} (00 تلقائي، 03 4G فقط، 08 5G فقط)');
      lines.add('• مفاتيح الميزات: select_band_switch=${fs['select_band_switch'] ?? '-'} · lock_freq_switch=${fs['lock_freq_switch'] ?? '-'} · net_premode_switch=${fs['net_premode_switch'] ?? '-'}');
      lines.add('• حقل networkOption في net-mode: ${nm.containsKey('networkOption') ? 'موجود (قيمته ${nm['networkOption']})' : 'غير موجود'}');

      // قفل 5G المباشر: نقارن رد كل مسار برد مسار وهمي. نفس الرد = ما نقدر نجزم، رد مختلف = المسار موجود.
      await _pause();
      final ctrl = _n5cls(await _read('net/zz-no-such-path-check'));
      final found = <String>[];
      final unsure = <String>[];
      for (final p in const <String>['net/lock-freq', 'net/lock-cell', 'ntwk/celllock']) {
        await _pause();
        final c = _n5cls(await _read(p));
        if (c != ctrl) {
          found.add('$p ($c)');
        } else {
          unsure.add(p);
        }
      }
      await _pause();
      final after = await _sigFresh();
      final trusted = !_sigBad(after);
      lines.add('• مسار وهمي للمقارنة رده: $ctrl');
      if (!trusted) {
        lines.add('• انقطعت الجلسة أثناء الفحص، فنتيجة مسارات القفل أدناه غير موثوقة. أعد الفحص.');
      } else if (found.isNotEmpty) {
        lines.add('• مسارات قفل مؤشرها إيجابي (رده يختلف عن المسار الوهمي): ${found.join(' · ')}. هذا مؤشر وجود فقط، مو إثبات إن الراوتر يقبل قفل نطاقات 5G.');
      } else {
        lines.add('• ما ظهر أي مسار قفل 5G مباشر (${unsure.join(' · ')} رده نفس المسار الوهمي). لا نرسل أي قفل 5G للراوتر.');
      }

      final scc = _n5tag(seccX, 'nrseccell_list');
      final nbr = _n5tag(nbrX, 'nbrcell_nrlist');
      final se = _n5err(seccX), ne = _n5err(nbrX);
      if (!mounted) return;
      setState(() {
        sig = s;
        nrNow = _n5nr(s);
        model = _n5tag(basic, 'devicename');
        modeText = nm['NetworkMode'] ?? '';
        cap.addAll(lines);
        sccNr = _n5rows(scc);
        nbrNr = _n5rows(nbr);
        sccNote = se != null ? 'هذا الراوتر ما يعرض جدول خلايا التجميع (كود $se)' : (sccNr.isEmpty ? 'ما فيه خلايا 5G مجمّعة الآن' : '');
        nbrNote = ne != null ? 'هذا الراوتر ما يعرض جدول الخلايا المجاورة (كود $ne)' : (nbrNr.isEmpty ? 'ما فيه خلايا 5G مجاورة ظاهرة الآن' : '');
        scanned = true;
      });
    } catch (e) {
      dbg('nr5g.scan', e);
      if (mounted) setState(() => err = 'خطأ أثناء الفحص: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // ---------------------------------------------------------------- 2) اختبار مرساة 4G
  Future<void> _anchorScan() async {
    if (busy) return;
    final g = widget.ctl;
    final setB = g.setBands;
    final snapF = g.snap;
    if (setB == null || snapF == null) {
      setState(() => err = 'هذي النسخة ما تدعم هذا الاختبار.');
      return;
    }
    final list = sel.toList()..sort();
    if (list.isEmpty) {
      setState(() => err = 'اختر نطاق 4G واحد على الأقل.');
      return;
    }
    final origMask = g.curMask();
    final origMode = g.curMode();
    if (origMask.isEmpty) {
      setState(() => err = 'ما قدرت أقرأ نطاقاتك الحالية، ارجع للرئيسية وحدّث ثم أعد المحاولة.');
      return;
    }
    if (!await _confirm('يختبر كل نطاق 4G من (${list.map((b) => 'B$b').join(' ')}) لحاله بوضع تلقائي، وينتظر هل يطلع 5G معه وعلى أي نطاق وبأي إشارة، ثم يرجّع إعدادك الحالي.\n\nينقطع الإنترنت أثناءه ويأخذ تقريبًا دقيقة إلى دقيقتين لكل نطاق. لا تقفل التطبيق.')) {
      return;
    }
    setState(() {
      busy = true;
      cancel = false;
      err = '';
      res.clear();
      log.clear();
    });
    try {
      await _n5St.write(key: _rkey, value: jsonEncode(<String, String>{'m': origMask, 'd': origMode}));
    } catch (e) {
      dbg('nr5g.savepend', e);
    }
    try {
      await WakelockPlus.enable();
    } catch (e) {
      dbg('nr5g.wake', e);
    }
    try {
      for (final b in list) {
        if (cancel || !mounted) break;
        _log('يختبر B$b...');
        final r = _N5Res(b);
        final t = Stopwatch()..start();
        final st = await setB(lte: maskOneBand(b), mode: '00');
        if (!st.ok) {
          r.note = st.note.isEmpty ? 'الراوتر ما قبل هذا النطاق' : st.note;
          r.secs = t.elapsed.inSeconds;
          if (mounted) setState(() => res[b] = r);
          _log('B$b: ✗ ${r.note}');
          continue;
        }
        final end = DateTime.now().add(const Duration(seconds: 55));
        while (DateTime.now().isBefore(end) && !cancel && mounted) {
          try {
            final s = await snapF();
            final lb = _n5lte(s);
            r.lteSeen = lb == null ? '' : 'B$lb';
            if (lb == b) r.lteOk = true;
            final n = _n5nr(s);
            if (r.lteOk && n != null) {
              r.nr = n;
              await Future<void>.delayed(const Duration(seconds: 4));
              final s2 = await snapF();
              final n2 = _n5nr(s2);
              if (n2 != null) r.nr = n2;
              break;
            }
          } catch (e) {
            dbg('nr5g.poll', e);
          }
          await Future<void>.delayed(const Duration(seconds: 3));
        }
        r.secs = t.elapsed.inSeconds;
        if (!r.lteOk) {
          r.note = r.lteSeen.isEmpty ? 'ما سجّل على هذا النطاق' : 'بقي على ${r.lteSeen}';
        } else if (r.nr == null) {
          r.note = 'سجّل 4G لكن ما طلع 5G';
        }
        if (mounted) setState(() => res[b] = r);
        final got = r.nr;
        _log(got != null
            ? 'B$b: 5G ✓ n${got.band ?? '?'} · RSRP ${_n5f(got.rsrp)} · SINR ${_n5f(got.sinr)}'
            : 'B$b: ${r.lteOk ? 'بدون 5G' : '✗ ${r.note}'}');
      }
    } catch (e) {
      dbg('nr5g.anchor', e);
      _log('خطأ: $e');
    } finally {
      _log('يرجّع إعدادك السابق...');
      var restored = false;
      try {
        final back = await setB(lte: origMask, mode: origMode);
        restored = back.ok && back.connected;
      } catch (e) {
        dbg('nr5g.restore', e);
      }
      if (restored) {
        try {
          await _n5St.delete(key: _rkey);
        } catch (e) {
          dbg('nr5g.delpend', e);
        }
        _log('تم إرجاع الإعداد.');
      } else {
        _log('تنبيه: ما تأكدت من رجوع الإعداد. اضغط «استعادة الإعداد السابق» أدناه.');
        await _loadPending();
      }
      try {
        await WakelockPlus.disable();
      } catch (e) {
        dbg('nr5g.wakeoff', e);
      }
      if (mounted) {
        setState(() {
          busy = false;
          if (restored) {
            pendMask = '';
            pendMode = '';
          }
        });
      }
    }
  }

  Future<void> _restorePending() async {
    final setB = widget.ctl.setBands;
    if (busy || setB == null || pendMask.isEmpty) return;
    setState(() => busy = true);
    try {
      final back = await setB(lte: pendMask, mode: pendMode.isEmpty ? '00' : pendMode);
      if (back.ok && back.connected) {
        await _n5St.delete(key: _rkey);
        if (mounted) {
          setState(() {
            pendMask = '';
            pendMode = '';
            err = '';
          });
        }
        _log('تم إرجاع الإعداد السابق.');
      } else if (mounted) {
        setState(() => err = back.note.isEmpty ? 'ما تأكدت من رجوع الإعداد.' : back.note);
      }
    } catch (e) {
      dbg('nr5g.restorePending', e);
      if (mounted) setState(() => err = 'خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // ---------------------------------------------------------------- عرض
  _N5Res? _best() {
    final l = res.values.where((r) => r.nr != null).toList();
    if (l.isEmpty) return null;
    l.sort((a, b) {
      final c = (b.nr!.sinr ?? -99.0).compareTo(a.nr!.sinr ?? -99.0);
      if (c != 0) return c;
      return (b.nr!.rsrp ?? -200.0).compareTo(a.nr!.rsrp ?? -200.0);
    });
    return l.first;
  }

  String _nrLine(_N5Nr n) =>
      'n${n.band ?? '?'} · RSRP ${_n5f(n.rsrp)} · SINR ${_n5f(n.sinr)}${n.bw.isEmpty ? '' : ' · ${n.bw}'}';

  String _reportText() {
    final b = StringBuffer();
    b.writeln('### فحص 5G');
    b.writeln('الموديل: ${model.isEmpty ? '-' : model} · الوضع: ${modeText.isEmpty ? '-' : modeText}');
    final n = nrNow;
    b.writeln('5G الآن: ${n == null ? 'لا' : _nrLine(n)}');
    for (final l in cap) {
      b.writeln(l);
    }
    b.writeln('خلايا 5G المجمّعة: ${sccNr.isEmpty ? (sccNote.isEmpty ? '-' : sccNote) : sccNr.map((r) => r.join(',')).join(' | ')}');
    b.writeln('خلايا 5G المجاورة: ${nbrNr.isEmpty ? (nbrNote.isEmpty ? '-' : nbrNote) : nbrNr.map((r) => r.join(',')).join(' | ')}');
    final keys = sig.keys.where((k) => k.toLowerCase().contains('nr') || k == 'band' || k == 'bandInfo' || k == 'mode').toList()..sort();
    b.writeln('حقول إشارة 5G في device/signal: ${keys.isEmpty ? 'ما فيه' : keys.map((k) => '$k=${sig[k]}').join(' | ')}');
    if (res.isNotEmpty) {
      b.writeln('### اختبار المرساة');
      final ks = res.keys.toList()..sort();
      for (final k in ks) {
        final r = res[k]!;
        final x = r.nr;
        b.writeln('B$k: ${x != null ? '5G ${_nrLine(x)}' : (r.lteOk ? 'بدون 5G' : r.note)} (${r.secs}ث)');
      }
    }
    return b.toString();
  }

  Widget _card(String t, List<Widget> c) => Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...c
          ])));

  Widget _small(String t) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(t, style: const TextStyle(color: Colors.white70, fontSize: 13)));

  Widget _cellRows(List<List<String>> rows, bool scc) {
    // التجميع: earfcn,band,bw,pci,rsrp,rsrq,rssi,sinr  ·  المجاورة: earfcn,band,pci,rsrp,rsrq,rssi,sinr
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final r in rows)
        Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(
                scc && r.length >= 8
                    ? '${r[1]} · ${r[2]} · ARFCN ${r[0]} · PCI ${r[3]} · RSRP ${r[4]} · SINR ${r[7]}'
                    : (!scc && r.length >= 7
                        ? '${r[1]} · ARFCN ${r[0]} · PCI ${r[2]} · RSRP ${r[3]} · SINR ${r[6]}'
                        : r.join(' , ')),
                style: const TextStyle(fontSize: 13))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final lteAll = List<int>.from(widget.ctl.sup)..sort();
    final best = _best();
    final keys = res.keys.toList()..sort();
    return Scaffold(
      appBar: AppBar(title: const Text('فحص 5G')),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (pendMask.isNotEmpty)
          _card('فحص سابق ما انتهى', [
            const Text('إعداداتك ممكن تكون ما رجعت لأصلها. اضغط للاستعادة.', style: TextStyle(color: Colors.orangeAccent, fontSize: 13)),
            const SizedBox(height: 6),
            FilledButton(onPressed: busy ? null : _restorePending, child: const Text('استعادة الإعداد السابق')),
          ]),
        _card('كيف يشتغل', [
          _small('الزر الأول يقرأ فقط ولا يغيّر شي في الراوتر: يعرض إشارة 5G الحالية، وخلايا 5G اللي يشوفها الراوتر، وهل الراوتر يوفّر قفل مباشر لنطاقات 5G.'),
          _small('الزر الثاني يختبر كل نطاق 4G لحاله ويشوف هل يطلع معه 5G (لأن 5G NSA يحتاج نطاق 4G مساعد) وعلى أي نطاق n، ثم يرجّع إعدادك.'),
        ]),
        FilledButton.icon(
          onPressed: busy ? null : _scan,
          icon: const Icon(Icons.radar),
          label: const Text('فحص 5G (قراءة فقط)'),
        ),
        if (err.isNotEmpty)
          Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(err, style: const TextStyle(color: Colors.redAccent))),
        if (busy && res.isEmpty && log.isEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
        if (scanned) ...[
          _card('الحالي', [
            Text('الموديل: ${model.isEmpty ? '-' : model}'),
            Text('الوضع: ${_n5ML[modeText] ?? (modeText.isEmpty ? '-' : modeText)}'),
            Text(nrNow == null ? '5G: ما فيه إشارة 5G الآن' : '5G: ${_nrLine(nrNow!)}',
                style: TextStyle(color: nrNow == null ? Colors.white70 : _n5Green)),
          ]),
          _card('خلايا 5G المجمّعة مع اتصالك', [
            if (sccNr.isEmpty) _small(sccNote) else _cellRows(sccNr, true),
          ]),
          _card('خلايا 5G المجاورة (يشوفها الراوتر)', [
            if (nbrNr.isEmpty) _small(nbrNote) else _cellRows(nbrNr, false),
          ]),
          _card('قدرات الراوتر (من رده الفعلي)', [for (final l in cap) _small(l)]),
        ],
        _card('اختبار 5G حسب نطاق 4G المساعد', [
          if (lteAll.isEmpty)
            _small('ما قدرت أستخرج نطاقات 4G من رد الراوتر.')
          else ...[
            _small('اختر نطاقات 4G اللي تبي تختبرها:'),
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final b in lteAll)
                FilterChip(
                  label: Text('B$b'),
                  selected: sel.contains(b),
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
            Wrap(spacing: 8, children: [
              TextButton(
                  onPressed: busy ? null : () => setState(() => sel..clear()..addAll(lteAll)),
                  child: const Text('تحديد الكل')),
              TextButton(onPressed: busy || sel.isEmpty ? null : () => setState(sel.clear), child: const Text('إلغاء الكل')),
            ]),
          ],
          const SizedBox(height: 6),
          FilledButton.tonalIcon(
            onPressed: busy || sel.isEmpty ? null : _anchorScan,
            icon: const Icon(Icons.fact_check),
            label: Text('اختبر 5G على كل نطاق 4G مختار (${sel.length})'),
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(children: [
                const Expanded(child: LinearProgressIndicator()),
                TextButton(onPressed: () => setState(() => cancel = true), child: const Text('إيقاف')),
              ]),
            ),
        ]),
        if (res.isNotEmpty)
          _card('النتيجة', [
            for (final k in keys)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  res[k]!.nr != null
                      ? 'B$k ← 5G ✓ ${_nrLine(res[k]!.nr!)}'
                      : 'B$k ← ${res[k]!.lteOk ? 'بدون 5G' : '✗ ${res[k]!.note}'}',
                  style: TextStyle(color: res[k]!.nr != null ? _n5Green : Colors.white70),
                ),
              ),
            if (!busy && best != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('الأفضل: B${best.lteBand} مع ${_nrLine(best.nr!)}. لتثبيته: اقفل B${best.lteBand} من صفحة «النطاقات».',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            if (!busy && best == null && keys.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('ما طلع 5G مع أي نطاق مختبَر. ممكن ما فيه تغطية 5G عندك، أو الاختبار انقطع بدري. شغّل «فحص 5G» وأرسل لي النسخة.',
                    style: TextStyle(color: Colors.orangeAccent)),
              ),
          ]),
        if (log.isNotEmpty) _card('السجل', [for (final l in log) Text(l, style: const TextStyle(fontSize: 13))]),
        if (scanned || res.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _reportText()));
                _log('تم نسخ التقرير.');
              },
              icon: const Icon(Icons.copy),
              label: const Text('نسخ التقرير'),
            ),
          ),
        const SizedBox(height: 20),
      ]),
    );
  }
}

const Map<String, String> _n5ML = <String, String>{
  '00': 'تلقائي (4G+5G)',
  '03': '4G فقط',
  '08': '5G فقط',
  '01': '2G فقط',
  '02': '3G فقط',
};
