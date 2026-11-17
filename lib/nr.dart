import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'bands.dart';
import 'dbg.dart';
import 'game.dart';

const FlutterSecureStorage _nst = FlutterSecureStorage();
const Color _nrGreen = Color(0xFF39D353);

Map<String, String> _kv(String x) {
  final m = <String, String>{};
  for (final r in RegExp(r'<(\w+)>([^<]*)</\1>').allMatches(x)) {
    m[r[1]!] = r[2]!;
  }
  return m;
}


/// صفحة 5G والدمج: قوائم النطاقات تتولّد من اللي يدعمه الراوتر فعليًا (من ردّه)، ولا شيء ثابت أو مخمَّن.
class NrPage extends StatefulWidget {
  final GameCtl ctl;
  const NrPage({super.key, required this.ctl});

  @override
  State<NrPage> createState() => _NrPageState();
}

class _NrPageState extends State<NrPage> {
  Map<String, String> nm = <String, String>{};
  Map<String, String> snap = <String, String>{};
  String rawList = '', rawNet = '', rawSig = '';
  String? nrKey;
  List<int> supNr = <int>[], supLte = <int>[];
  final Set<int> s5 = <int>{}, s4 = <int>{};
  String mode = '00';
  bool loading = true, busy = false, cancel = false;
  String err = '';
  final List<String> log = <String>[];
  List<Map<String, dynamic>> profiles = <Map<String, dynamic>>[];

  String get _okey => 'nr_orig_${widget.ctl.routerHost}';
  String get _pkey => 'nr_profiles_${widget.ctl.routerHost}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    cancel = true;
    super.dispose();
  }

  void _log(String t) {
    if (mounted) setState(() => log.add(t));
  }

  Future<bool> _confirm(String t) async =>
      await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(content: Text(t), actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('متأكد')),
              ])) ??
      false;

  Future<void> _load() async {
    final g = widget.ctl.rawGet;
    if (g == null) {
      setState(() {
        loading = false;
        err = 'هذي النسخة ما تدعم القراءة المباشرة من الراوتر.';
      });
      return;
    }
    try {
      final rn = await g('net/net-mode');
      var rl = '', rs = '';
      try {
        rl = await g('net/net-mode-list');
      } catch (e) {
        dbg('nr.list', e);
      }
      try {
        rs = await g('device/signal');
      } catch (e) {
        dbg('nr.signal', e);
      }
      final n = _kv(rn);
      final key = findNrKey(n);
      final o = await _nst.read(key: _okey);
      if (o == null) await _nst.write(key: _okey, value: jsonEncode(n));
      final orig = o == null ? n : Map<String, String>.from(jsonDecode(o) as Map);
      var sn = <String, String>{};
      try {
        final f = widget.ctl.snap;
        if (f != null) sn = await f();
      } catch (e) {
        dbg('nr.snap', e);
      }
      var pl = <Map<String, dynamic>>[];
      try {
        final p = await _nst.read(key: _pkey);
        if (p != null) pl = (jsonDecode(p) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      } catch (e) {
        dbg('nr.profiles', e);
      }
      var s = parseNrSupported(rl);
      if (s.isEmpty) s = List<int>.from(widget.ctl.nrSup);
      if (s.isEmpty && key != null) {
        final fromOrig = decodeBands(orig[key] ?? '');
        if (fromOrig.length > 1) s = fromOrig.toList()..sort();
      }
      var l = <int>{...widget.ctl.sup}.toList()..sort();
      if (l.isEmpty) l = bandsOfHex(orig['LTEBand'] ?? '');
      if (!mounted) return;
      setState(() {
        nm = n;
        rawNet = rn;
        rawList = rl;
        rawSig = rs;
        snap = sn;
        nrKey = key;
        supNr = s;
        supLte = l;
        profiles = pl;
        mode = n['NetworkMode'] ?? '00';
        s5
          ..clear()
          ..addAll(key == null ? <int>{} : decodeBands(n[key] ?? '').where(s.contains));
        s4
          ..clear()
          ..addAll(bandsOfHex(n['LTEBand'] ?? '').where(l.contains));
        loading = false;
      });
    } catch (e) {
      dbg('nr.load', e);
      if (mounted) {
        setState(() {
          loading = false;
          err = 'ما قدرت أقرأ إعدادات الراوتر: $e';
        });
      }
    }
  }

  Future<Map<String, String>?> _waitReg(int secs) async {
    final f = widget.ctl.snap;
    if (f == null) return null;
    final sw = Stopwatch()..start();
    while (sw.elapsed.inSeconds < secs && !cancel && mounted) {
      try {
        final s = await f();
        if (mounted) setState(() => snap = s);
        if (hasNrSignal(s)) return s;
      } catch (e) {
        dbg('nr.waitReg', e);
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return null;
  }

  String _regText(Map<String, String>? s) {
    if (s == null) return 'ما سجّل على 5G (ما ظهرت إشارة 5G)';
    final b4 = (s['band'] ?? '').trim();
    final nb = nrBandNum(s);
    return '4G المساعد: ${b4.isEmpty ? '-' : 'B$b4'} · 5G: ${nb == null ? '' : 'n$nb '}RSRP ${s['nrrsrp']} · SINR ${s['nrsinr'] ?? '-'}';
  }

  /// يطبّق عبر دالة الإرسال الوحيدة (setBands) وإذا الاتصال ما رجع خلال ~90 ثانية يرجّع تلقائيًا.
  Future<bool> _doApply({String? lte, String? nr, required String md}) async {
    final c = widget.ctl;
    final prev = Map<String, String>.from(nm);
    _log('يطبّق الإعداد وينتظر رجوع الاتصال (حتى 90 ثانية)...');
    final r = await c.setBands!(lte: lte, nr: nr, mode: md);
    if (mounted) {
      try {
        final n = _kv(await c.rawGet!('net/net-mode'));
        setState(() => nm = n);
      } catch (e) {
        dbg('nr.verify', e);
      }
    }
    if (r.ok && r.connected) {
      _log('تم التطبيق وتأكّدت القراءة، والاتصال رجع.');
      return true;
    }
    _log(r.ok
        ? 'طُبّق الإعداد لكن الاتصال ما رجع خلال 90 ثانية. يرجّع تلقائيًا للإعداد السابق...'
        : 'الراوتر ما طبّق الإعداد (${r.note}). يتأكد من الإعداد السابق...');
    final k = nrKey;
    final back = await c.setBands!(
        lte: prev['LTEBand'], nr: k == null ? null : prev[k], mode: prev['NetworkMode'] ?? '00');
    if (back.ok && back.connected) {
      _log('تم الرجوع تلقائيًا للإعداد السابق والاتصال رجع.');
    } else {
      final o = await _nst.read(key: _okey);
      if (o != null) {
        final orig = Map<String, String>.from(jsonDecode(o) as Map);
        _log('الرجوع للسابق ما نجح، يجرّب الإعداد الأصلي المحفوظ...');
        final b2 = await c.setBands!(
            lte: orig['LTEBand'], nr: k == null ? null : orig[k], mode: orig['NetworkMode'] ?? '00');
        _log(b2.ok && b2.connected ? 'تم إرجاع الإعداد الأصلي.' : 'ما قدرت أرجّع الاتصال. اضغط «استعادة الأصل» أو أعد تشغيل الراوتر.');
      } else {
        _log('ما قدرت أرجّع الاتصال. اضغط «استعادة الأصل» أو أعد تشغيل الراوتر.');
      }
    }
    await _load();
    return false;
  }

  Future<void> _applySel() async {
    if (busy) return;
    if (s5.isEmpty && s4.isEmpty) {
      setState(() => err = 'ما حدّدت أي نطاق. فعّل نطاق واحد على الأقل (5G أو 4G).');
      return;
    }
    if (s5.isNotEmpty && nrKey == null) {
      setState(() => err = 'ما لقيت حقل نطاقات 5G في رد الراوتر، فما أقدر أرسل نطاقات 5G. أرسل لي الرد الخام من الأعلى.');
      return;
    }
    final t5 = (s5.toList()..sort()).map((b) => 'n$b').join(' ');
    final t4 = (s4.toList()..sort()).map((b) => 'B$b').join(' ');
    final warn = mode == '08'
        ? '\n\nتحذير: وضع «5G فقط» ينقطع فيه الإنترنت لو ما لقى 5G، وشبكات NSA تحتاج نطاق 4G مساعد.'
        : (s5.isNotEmpty && s4.isEmpty ? '\n\nتنبيه: ما اخترت نطاق 4G، وشبكات NSA تحتاج نطاق 4G مساعد.' : '');
    if (!await _confirm('يطبّق على الراوتر:\n5G: ${s5.isEmpty ? 'بدون تغيير' : t5}\n4G: ${s4.isEmpty ? 'بدون تغيير' : t4}\nالوضع: $mode$warn\n\nينقطع الإنترنت من 20 ثانية إلى دقيقة ونص، وإذا ما رجع يرجّع الإعداد السابق تلقائيًا.')) {
      return;
    }
    setState(() {
      busy = true;
      cancel = false;
      err = '';
      log.clear();
    });
    try {
      final k = nrKey;
      final ok = await _doApply(
          lte: s4.isEmpty ? null : maskOfBands(s4),
          nr: s5.isEmpty || k == null ? null : encodeBands(s5, nm[k] ?? ''),
          md: mode);
      if (ok && s5.isNotEmpty) {
        _log('ينتظر تسجيل 5G (حتى 45 ثانية)...');
        _log(_regText(await _waitReg(45)));
      } else if (ok) {
        final s = await widget.ctl.snap?.call();
        if (s != null && mounted) _log(_regText(hasNrSignal(s) ? s : null));
      }
    } catch (e) {
      dbg('nr.apply', e);
      _log('خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _scanSel() async {
    if (busy) return;
    final k = nrKey;
    if (s5.isEmpty || k == null) {
      setState(() => err = k == null ? 'ما لقيت حقل نطاقات 5G في رد الراوتر.' : 'فعّل نطاق 5G واحد على الأقل لاختباره.');
      return;
    }
    final list = s5.toList()..sort();
    if (!await _confirm('يختبر كل نطاق 5G مفعّل (${list.map((b) => 'n$b').join(' ')}) لحاله بنطاقات 4G المفعّلة، ويشوف هل يسجّل عليه ويقيس إشارته، ثم يرجّع إعدادك الحالي.\n\nينقطع الإنترنت أثناءه ويأخذ تقريبًا دقيقة لكل نطاق.')) {
      return;
    }
    setState(() {
      busy = true;
      cancel = false;
      err = '';
      log.clear();
    });
    final prev = Map<String, String>.from(nm);
    final md = mode == '03' ? '00' : mode;
    final lteMask = s4.isEmpty ? widget.ctl.curMask() : maskOfBands(s4);
    try {
      for (final b in list) {
        if (cancel || !mounted) break;
        _log('يختبر n$b...');
        final r = await widget.ctl.probe(lteMask, md, nr: encodeBands(<int>{b}, prev[k] ?? ''));
        _log(r.ok
            ? 'n$b: ✓ ${r.band != 'n$b' ? '(سجّل فعليًا على ${r.band}) ' : ''}RSRP ${r.rsrp?.toStringAsFixed(0) ?? '-'} · SINR ${r.sinr?.toStringAsFixed(0) ?? '-'}'
            : 'n$b: ✗ ${r.note}');
      }
    } catch (e) {
      dbg('nr.scan', e);
      _log('خطأ: $e');
    } finally {
      _log('يرجّع إعدادك السابق...');
      final back = await widget.ctl.setBands!(
          lte: prev['LTEBand'], nr: prev[k], mode: prev['NetworkMode'] ?? '00');
      _log(back.ok && back.connected ? 'تم إرجاع الإعداد.' : 'تنبيه: ما تأكدت من رجوع الإعداد، اضغط «استعادة الأصل».');
      await _load();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _restore() async {
    if (busy) return;
    final o = await _nst.read(key: _okey);
    if (o == null) {
      setState(() => err = 'ما فيه إعداد أصلي محفوظ.');
      return;
    }
    final orig = Map<String, String>.from(jsonDecode(o) as Map);
    if (!await _confirm('يرجّع الوضع ونطاقات 4G و5G للقيم اللي كانت أول ما فتحت هذي الصفحة. متأكد؟')) return;
    setState(() {
      busy = true;
      err = '';
      log.clear();
    });
    try {
      final k = nrKey;
      final r = await widget.ctl.setBands!(
          lte: orig['LTEBand'], nr: k == null ? null : orig[k], mode: orig['NetworkMode'] ?? '00');
      _log(r.ok && r.connected ? 'تم إرجاع الإعداد الأصلي.' : 'الراوتر ما رجّع كل القيم (${r.note}). راجع الرد الخام.');
      await _load();
    } catch (e) {
      dbg('nr.restore', e);
      _log('خطأ: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _saveProfiles() => _nst.write(key: _pkey, value: jsonEncode(profiles));

  Future<void> _saveProfile() async {
    if (s5.isEmpty && s4.isEmpty) {
      setState(() => err = 'ما حدّدت أي نطاق لحفظه.');
      return;
    }
    final c = TextEditingController();
    final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('اسم الملف (الشريحة)'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: c, decoration: const InputDecoration(hintText: 'مثال: STC')),
                const SizedBox(height: 8),
                Wrap(spacing: 6, children: [
                  for (final n in <String>['STC', 'Zain', 'Mobily']) ActionChip(label: Text(n), onPressed: () => c.text = n),
                ]),
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
                FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: const Text('حفظ')),
              ],
            ));
    if (name == null || name.isEmpty) return;
    setState(() {
      profiles.removeWhere((p) => p['n'] == name);
      profiles.add(<String, dynamic>{'n': name, 's5': s5.toList()..sort(), 's4': s4.toList()..sort(), 'm': mode});
    });
    await _saveProfiles();
  }

  Future<void> _delProfile(Map<String, dynamic> p) async {
    setState(() => profiles.remove(p));
    await _saveProfiles();
  }

  Future<void> _applyProfile(Map<String, dynamic> p) async {
    if (busy) return;
    setState(() {
      s5
        ..clear()
        ..addAll((p['s5'] as List).map((e) => e as int).where(supNr.contains));
      s4
        ..clear()
        ..addAll((p['s4'] as List).map((e) => e as int).where(supLte.contains));
      mode = (p['m'] as String?) ?? mode;
    });
    await _applySel();
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

  Widget _switches(List<int> bands, Set<int> sel, String prefix) => Column(children: [
        for (final b in bands)
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('$prefix$b'),
            value: sel.contains(b),
            activeColor: _nrGreen,
            onChanged: busy
                ? null
                : (v) => setState(() {
                      if (v) {
                        sel.add(b);
                      } else {
                        sel.remove(b);
                      }
                    }),
          ),
      ]);

  Widget _quick(Set<int> sel, List<int> all) => Wrap(spacing: 8, children: [
        TextButton(
            onPressed: busy
                ? null
                : () => setState(() {
                      sel
                        ..clear()
                        ..addAll(all);
                    }),
            child: const Text('تفعيل الكل')),
        TextButton(onPressed: busy || sel.isEmpty ? null : () => setState(sel.clear), child: const Text('إلغاء الكل')),
      ]);

  @override
  Widget build(BuildContext context) {
    final cur5 = nrKey == null ? <int>[] : (decodeBands(nm[nrKey!] ?? '').toList()..sort());
    final cur4 = bandsOfHex(nm['LTEBand'] ?? '').where(supLte.contains).toList()..sort();
    final modes = widget.ctl.modes.isEmpty ? <String>['00', '03', '08'] : widget.ctl.modes;
    const names = <String, String>{'00': 'تلقائي (4G+5G)', '03': '4G فقط', '08': '5G فقط', '01': '2G فقط', '02': '3G فقط'};
    final tail = kErrLog.length > 25 ? kErrLog.sublist(kErrLog.length - 25) : kErrLog;
    final raw = StringBuffer()
      ..writeln('### حقل 5G المكتشف: ${nrKey ?? 'ما لقيته'}')
      ..writeln('### نطاقات 5G المستخرجة: ${supNr.isEmpty ? 'لا شيء' : supNr.map((b) => 'n$b').join(' ')}')
      ..writeln('### net/net-mode-list')
      ..writeln(rawList)
      ..writeln('### net/net-mode')
      ..writeln(rawNet)
      ..writeln('### device/signal')
      ..writeln(rawSig)
      ..writeln('### سجل الأخطاء')
      ..writeln(tail.join('\n'));
    final rawText = raw.toString();

    return Scaffold(
      appBar: AppBar(title: const Text('5G والدمج')),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(12), children: [
              _card('الرد الخام من الراوتر (أرسله لي أول)', [
                const Text('هذا اللي يرجّعه الراوتر فعليًا. القوائم تحت تتولّد منه، واسم حقل 5G وصيغة الماسك ينقرؤون منه بدون تخمين.',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
                Wrap(spacing: 8, children: [
                  TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: rawText));
                        if (mounted) setState(() => err = '');
                        _log('تم نسخ الرد الخام.');
                      },
                      icon: const Icon(Icons.copy),
                      label: const Text('نسخ الكل')),
                  TextButton.icon(
                      onPressed: busy
                          ? null
                          : () {
                              setState(() => loading = true);
                              _load();
                            },
                      icon: const Icon(Icons.refresh),
                      label: const Text('تحديث')),
                ]),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  initiallyExpanded: nrKey == null || supNr.isEmpty,
                  title: const Text('عرض الرد الخام', style: TextStyle(fontSize: 14)),
                  children: [SelectableText(rawText, style: const TextStyle(fontSize: 11))],
                ),
              ]),
              _card('الحالي', [
                Text('الوضع: ${names[nm['NetworkMode']] ?? nm['NetworkMode'] ?? '-'}'),
                Text('4G: ${cur4.isEmpty ? '-' : cur4.map((b) => 'B$b').join(' ')}'),
                Text(nrKey == null
                    ? '5G: ما لقيت حقل نطاقات 5G في رد الراوتر'
                    : '5G: ${cur5.isEmpty ? '-' : cur5.map((b) => 'n$b').join(' ')}'),
                Text(_regText(hasNrSignal(snap) ? snap : null), style: TextStyle(color: hasNrSignal(snap) ? _nrGreen : Colors.white70)),
              ]),
              if (mode == '08')
                _card('تحذير', [
                  const Text(
                      'وضع «5G فقط» (08): شبكات NSA تحتاج نطاق 4G مساعد، فلو ما لقى 5G ينقطع الإنترنت. الأفضل تثبّت نطاق 5G مع نطاق 4G المناسب له بالوضع التلقائي.',
                      style: TextStyle(color: Colors.orangeAccent, fontSize: 13)),
                ]),
              _card('5G Bands', [
                if (supNr.isEmpty)
                  const Text('ما قدرت أستخرج نطاقات 5G من رد الراوتر. أرسل لي الرد الخام من الأعلى.',
                      style: TextStyle(color: Colors.orangeAccent, fontSize: 13))
                else ...[
                  _switches(supNr, s5, 'n'),
                  _quick(s5, supNr),
                ],
              ]),
              _card('4G Bands', [
                if (supLte.isEmpty)
                  const Text('ما قدرت أستخرج نطاقات 4G من رد الراوتر.', style: TextStyle(color: Colors.orangeAccent, fontSize: 13))
                else ...[
                  const Text('اختر نطاقات 4G للدمج مع 5G (NSA يحتاج نطاق 4G مساعد). لو ما فعّلت شيء ما أغيّر نطاقات 4G.',
                      style: TextStyle(color: Colors.white54, fontSize: 13)),
                  _switches(supLte, s4, 'B'),
                  _quick(s4, supLte),
                ],
              ]),
              _card('الوضع', [
                Wrap(spacing: 6, children: [
                  for (final m in modes)
                    ChoiceChip(
                      label: Text(names[m] ?? 'وضع $m'),
                      selected: mode == m,
                      onSelected: busy ? null : (_) => setState(() => mode = m),
                    ),
                ]),
              ]),
              if (err.isNotEmpty)
                Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(err, style: const TextStyle(color: Colors.redAccent))),
              FilledButton.icon(
                onPressed: busy ? null : _applySel,
                icon: const Icon(Icons.check),
                label: Text('تطبيق (5G ${s5.length} · 4G ${s4.length})'),
              ),
              const SizedBox(height: 8),
              FilledButton.tonalIcon(
                onPressed: busy || s5.isEmpty ? null : _scanSel,
                icon: const Icon(Icons.fact_check),
                label: Text('اختبر كل نطاق 5G مفعّل لحاله (${s5.length})'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: busy ? null : _restore,
                icon: const Icon(Icons.restore),
                label: const Text('استعادة الأصل'),
              ),
              if (busy)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(children: [
                    const Expanded(child: LinearProgressIndicator()),
                    TextButton(onPressed: () => setState(() => cancel = true), child: const Text('إيقاف')),
                  ]),
                ),
              _card('ملفات جاهزة (لكل شريحة)', [
                const Text('احفظ التفعيل الحالي باسم (STC / Zain / Mobily) وبدّل بينها بضغطة.',
                    style: TextStyle(color: Colors.white54, fontSize: 13)),
                if (profiles.isNotEmpty)
                  Wrap(spacing: 6, children: [
                    for (final p in profiles)
                      InputChip(
                        label: Text('${p['n']}'),
                        onPressed: busy ? null : () => _applyProfile(p),
                        onDeleted: busy ? null : () => _delProfile(p),
                      ),
                  ]),
                TextButton.icon(
                    onPressed: busy ? null : _saveProfile, icon: const Icon(Icons.save), label: const Text('حفظ الحالي كملف')),
              ]),
              if (log.isNotEmpty) _card('السجل', [for (final l in log) Text(l)]),
              const SizedBox(height: 20),
            ]),
    );
  }
}
