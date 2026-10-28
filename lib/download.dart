import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'game.dart';
import 'measure.dart';

const Color _green = Color(0xFF39D353);

List<int> _bandsOf(String hex) {
  final m = int.tryParse(hex, radix: 16) ?? 0;
  return <int>[for (var i = 0; i < 63; i++) if ((m >> i) & 1 == 1) i + 1];
}

String _maskOf(Iterable<int> b) => b.fold<int>(0, (a, x) => a | (1 << (x - 1))).toRadixString(16);

String _f1(double? v) => v == null ? '-' : v.toStringAsFixed(1);

class DCand {
  final String mask, mode, label;
  final bool isBase;
  DCand(this.mask, this.mode, this.label, {this.isBase = false});
  double? mbps;
  String note = '';
}

class DownloadPage extends StatefulWidget {
  final GameCtl ctl;
  const DownloadPage({super.key, required this.ctl});
  @override
  State<DownloadPage> createState() => _DownState();
}

class _DownState extends State<DownloadPage> {
  bool running = false, cancel = false, ext = false, auto = true, done = false, applying = false;
  String step = '', advice = '', autoMsg = '', warn = '';
  int total = 0, doneN = 0, usedBytes = 0;
  final List<String> logs = <String>[];
  List<DCand> ranked = <DCand>[];
  DCand? rec;
  String _curMask = '', _curMode = '', _baseMask = '', _baseMode = '';
  double _baseAvg = 0.0;
  bool _changed = false;

  bool stop() => cancel;

  void _set(void Function() f) {
    if (mounted) setState(f);
  }

  void log(String s) {
    _set(() {
      logs.add(s);
      if (logs.length > 40) logs.removeAt(0);
    });
  }

  String _lbl(List<int> bands, String mode) =>
      '${mode == '03' ? '4G فقط' : 'تلقائي'} · ${bands.map((b) => 'B$b').join('+')}';

  List<DCand> _gen(bool extended) {
    final ctl = widget.ctl;
    final baseMask = ctl.curMask();
    final baseMode = ctl.curMode();
    final en = _bandsOf(baseMask);
    final out = <DCand>[];
    final seen = <String>{'$baseMask|$baseMode'};

    void add(String mask, String mode, String label) {
      if (mask.isEmpty || mask == '0') return;
      final k = '$mask|$mode';
      if (seen.contains(k)) return;
      seen.add(k);
      out.add(DCand(mask, mode, label));
    }

    if (en.length <= 4) {
      final n = en.length;
      for (var m = 1; m < (1 << n); m++) {
        final sub = <int>[for (var i = 0; i < n; i++) if ((m >> i) & 1 == 1) en[i]];
        add(_maskOf(sub), '00', _lbl(sub, '00'));
      }
    } else {
      for (final b in en) {
        add(_maskOf(<int>[b]), '00', _lbl(<int>[b], '00'));
      }
    }
    if (ctl.modes.contains('03') && en.isNotEmpty) add(baseMask, '03', _lbl(en, '03'));
    if (extended) {
      for (final b in ctl.sup) {
        add(_maskOf(<int>[b]), '00', _lbl(<int>[b], '00'));
      }
      add(_maskOf(ctl.sup), '00', 'تلقائي · كل النطاقات المدعومة');
    }
    return out;
  }

  Future<void> _run(DCand c) async {
    final t = await measureDown(stop);
    c.mbps = t.mbps;
    _set(() => usedBytes += t.bytes);
  }

  Future<bool> _waitNet() async {
    final end = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(end)) {
      final t = await measureDown(() => false, conns: 1, secs: 3, warm: 1);
      _set(() => usedBytes += t.bytes);
      if (t.bytes > 50000) return true;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return false;
  }

  Future<void> start() async {
    final ctl = widget.ctl;
    final baseMask = ctl.curMask();
    final baseMode = ctl.curMode();
    if (baseMask.isEmpty || ctl.sup.isEmpty) {
      _set(() => step = 'ما قدرت أقرأ نطاقات الراوتر. ارجع وادخل من جديد.');
      return;
    }
    final cands = _gen(ext);
    final mins = ((cands.length + 4) * 65 / 60).ceil();
    final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('بدء فحص التنزيل'),
            content: Text(
                'سيجرّب ${cands.length} إعدادًا، ويستغرق حوالي $mins دقيقة.\n\n'
                '• الفحص ينزّل ملفات اختبار، وقد يستهلك من 0.5 إلى 3 جيجابايت من باقتك حسب سرعتك.\n'
                '• الإنترنت ينقطع 20 إلى 45 ثانية عند كل تبديل، وعن كل الأجهزة.\n'
                '• لا تنزّل شيئًا أثناء الفحص، لأنه يخرّب القياس.\n'
                '${auto ? '• بعد الفحص يطبّق الأفضل تلقائيًا إذا تفوّق بوضوح، ويتأكد بقياس ثانٍ، وإن لم يتأكد التحسن يرجّع إعدادك الأول.' : '• لن يتغير شيء إلا إذا ضغطت «طبّق».'}'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ابدأ')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    _baseMask = baseMask;
    _baseMode = baseMode;
    _changed = false;
    _set(() {
      running = true;
      cancel = false;
      done = false;
      ranked = <DCand>[];
      rec = null;
      advice = '';
      autoMsg = '';
      warn = '';
      logs.clear();
      total = cands.length + 3;
      doneN = 0;
      usedBytes = 0;
      step = 'تجهيز';
    });
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    try {
      await _scan(cands, baseMask, baseMode);
    } catch (e) {
      log('خطأ غير متوقع: $e');
    }
    if (!widget.ctl.keepAwake) {
      try {
        await WakelockPlus.disable();
      } catch (_) {}
    }
    _set(() {
      running = false;
      done = true;
      step = cancel ? 'أُوقف الفحص' : 'انتهى';
    });
  }

  Future<void> _scan(List<DCand> cands, String baseMask, String baseMode) async {
    final ctl = widget.ctl;
    _curMask = baseMask;
    _curMode = baseMode;

    _set(() => step = 'قياس الإعداد الحالي');
    final base = DCand(baseMask, baseMode, 'الحالي', isBase: true);
    await _run(base);
    _set(() => doneN++);
    if ((base.mbps ?? 0) < 0.5) {
      log('ما قدرت أنزّل ملف الاختبار. تأكد من وجود إنترنت ثم أعد المحاولة.');
      _set(() => ranked = <DCand>[base]);
      return;
    }
    log('الحالي: ${_f1(base.mbps)} Mbps');

    var touched = false;
    var fails = 0;
    for (var i = 0; i < cands.length; i++) {
      if (cancel) break;
      final c = cands[i];
      _set(() => step = 'تجربة ${c.label} (${i + 1}/${cands.length})');
      if (c.mask != _curMask || c.mode != _curMode) {
        log('تطبيق ${c.label}...');
        touched = true;
        final applied = await ctl.apply(c.mask, c.mode);
        if (!applied) {
          c.note = 'الراوتر لم يطبّق هذا الإعداد';
          fails++;
          log('لم يتأكد تطبيق ${c.label}');
          if (fails >= 2) {
            log('فشل متكرر، أوقفت الفحص.');
            break;
          }
          continue;
        }
        fails = 0;
        _curMask = c.mask;
        _curMode = c.mode;
      }
      if (cancel) break;
      log('انتظار رجوع الإنترنت...');
      if (!await _waitNet()) {
        c.note = 'ما رجع الإنترنت بعد التبديل';
        log('ما رجع الإنترنت مع ${c.label}');
        _set(() => doneN++);
        continue;
      }
      await Future<void>.delayed(const Duration(seconds: 6));
      if (cancel) break;
      log('قياس ${c.label}...');
      await _run(c);
      log('${c.label}: ${_f1(c.mbps)} Mbps');
      _set(() => doneN++);
    }

    if (touched) {
      _set(() => step = 'رجوع للإعداد الحالي');
      log('رجوع للإعداد الحالي...');
      final back = await ctl.apply(baseMask, baseMode);
      if (back) {
        _curMask = baseMask;
        _curMode = baseMode;
      } else {
        warn = 'تنبيه: ما تأكدت من الرجوع للإعداد الأول. افحص تبويب ROUTER.';
      }
      await _waitNet();
      await Future<void>.delayed(const Duration(seconds: 6));
    }

    var b2 = base.mbps ?? 0.0;
    if (!cancel) {
      _set(() => step = 'قياس الحالي مرة ثانية');
      final base2 = DCand(baseMask, baseMode, 'الحالي', isBase: true);
      await _run(base2);
      b2 = base2.mbps ?? b2;
      _set(() => doneN++);
    }
    final b1 = base.mbps ?? 0.0;
    _baseAvg = (b1 + b2) / 2;
    base.mbps = _baseAvg;
    if (b1 > 0 && (b1 - b2).abs() / _baseAvg > 0.3) {
      warn += '${warn.isEmpty ? '' : '\n'}سرعة خطك تتذبذب كثيرًا بين قياسين، فالنتائج أقل ثقة.';
    }

    DCand? top;
    for (final c in cands) {
      final m = c.mbps;
      if (m != null && (top == null || m > top.mbps!)) top = c;
    }
    final all = <DCand>[base, ...cands];
    final valid = all.where((c) => c.mbps != null).toList()..sort((a, b) => b.mbps!.compareTo(a.mbps!));
    final invalid = all.where((c) => c.mbps == null).toList();
    DCand? r;
    var adv = '';
    if (top == null) {
      adv = 'ما لقيت إعدادًا بديلًا قابلًا للقياس.';
    } else {
      final gain = top.mbps! - _baseAvg;
      final pct = _baseAvg > 0 ? gain / _baseAvg * 100 : 0.0;
      if (gain >= 5 && pct >= 15) {
        r = top;
        adv = 'الأفضل: ${top.label} بسرعة ${_f1(top.mbps)} Mbps مقابل ${_f1(_baseAvg)} للحالي (+${pct.toStringAsFixed(0)}%).';
      } else {
        adv = 'إعدادك الحالي (${_f1(_baseAvg)} Mbps) كافٍ. أفضل بديل (${top.label}) لا يتفوق عليه بفارق واضح.';
      }
    }
    if (cancel) warn += '${warn.isEmpty ? '' : '\n'}الفحص أُوقف قبل اكتماله.';
    _set(() {
      ranked = <DCand>[...valid, ...invalid];
      rec = r;
      advice = adv;
    });

    if (!cancel && r != null && auto) {
      await _applyVerify(r);
    }
  }

  /// يطبّق الإعداد ثم يقيس للتأكد، وإن لم يتحسن يرجّع الإعداد الأول.
  Future<void> _applyVerify(DCand r) async {
    final ctl = widget.ctl;
    _set(() => step = 'تطبيق الأفضل والتأكد منه');
    log('تطبيق ${r.label}...');
    final ok = await ctl.apply(r.mask, r.mode);
    if (!ok) {
      final back = await ctl.apply(_baseMask, _baseMode);
      _set(() => autoMsg =
          'ما تأكد تطبيق الإعداد الجديد، فرجعت للإعداد الأول${back ? '' : ' (تنبيه: ما تأكدت من الرجوع، افحص تبويب ROUTER)'}.');
      return;
    }
    _curMask = r.mask;
    _curMode = r.mode;
    _changed = true;
    await _waitNet();
    await Future<void>.delayed(const Duration(seconds: 6));
    final v = DCand(r.mask, r.mode, r.label);
    await _run(v);
    final vm = v.mbps ?? 0.0;
    log('بعد التطبيق: ${_f1(vm)} Mbps');
    if (vm >= _baseAvg * 1.10) {
      _set(() => autoMsg =
          'تم تطبيق ${r.label} وتأكد التحسن: ${_f1(vm)} Mbps بدل ${_f1(_baseAvg)}.');
    } else {
      log('التحسن ما تأكد، رجوع للإعداد الأول...');
      final back = await ctl.apply(_baseMask, _baseMode);
      if (back) {
        _curMask = _baseMask;
        _curMode = _baseMode;
        _changed = false;
      }
      await _waitNet();
      _set(() => autoMsg =
          'القياس بعد التطبيق (${_f1(vm)} Mbps) ما تفوق على الحالي (${_f1(_baseAvg)})، فرجعت للإعداد الأول${back ? '' : ' (تنبيه: ما تأكدت من الرجوع، افحص تبويب ROUTER)'}.');
    }
  }

  Future<void> applyManual() async {
    final r = rec;
    if (r == null) return;
    _set(() {
      applying = true;
      autoMsg = '';
      cancel = false;
    });
    try {
      await _applyVerify(r);
    } catch (e) {
      _set(() => autoMsg = 'خطأ: $e');
    }
    _set(() => applying = false);
  }

  Future<void> undo() async {
    _set(() {
      applying = true;
      autoMsg = 'جارٍ الرجوع للإعداد الأول...';
    });
    final ok = await widget.ctl.apply(_baseMask, _baseMode);
    _set(() {
      applying = false;
      if (ok) _changed = false;
      autoMsg = ok ? 'رجعت للإعداد الأول.' : 'ما تأكدت من الرجوع. افحص تبويب ROUTER.';
    });
  }

  Widget _card(String t, List<Widget> c) => Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...c,
          ]),
        ),
      );

  Widget _row(int rank, DCand c, bool isBest) {
    final m = c.mbps;
    final rel = (m != null && _baseAvg > 0 && !c.isBase) ? '  (${m >= _baseAvg ? '+' : ''}${((m - _baseAvg) / _baseAvg * 100).toStringAsFixed(0)}%)' : '';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: isBest ? _green : Colors.white24, width: isBest ? 2 : 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${rank > 0 ? '$rank. ' : ''}${c.label}${c.isBase ? '  (الحالي)' : ''}',
            style: const TextStyle(fontWeight: FontWeight.bold)),
        if (m == null)
          Text(c.note.isEmpty ? 'ما قدرت أقيسه' : c.note, style: const TextStyle(color: Colors.white54))
        else
          Text('${_f1(m)} Mbps$rel'),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = rec;
    return PopScope(
      canPop: !running && !applying,
      child: Scaffold(
        appBar: AppBar(title: const Text('وضع التنزيل')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          _card('وضع التنزيل', [
            const Text(
                'يقيس سرعة التنزيل بعدة اتصالات متوازية لكل إعداد (مجموعات النطاقات المفعّلة عندك، بوضع تلقائي ثم 4G فقط). '
                'ملاحظة: قفل نطاق واحد قد يلغي تجميع النطاقات (Carrier Aggregation)، فنجرّب مجموعات وليس نطاقات منفردة فقط.',
                style: TextStyle(color: Colors.white70)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: auto,
              onChanged: running || applying ? null : (v) => setState(() => auto = v),
              title: const Text('تطبيق الأفضل تلقائيًا'),
              subtitle: const Text('يتأكد بقياس ثانٍ ويرجّع الأول إن لم يتحسن'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: ext,
              onChanged: running || applying ? null : (v) => setState(() => ext = v),
              title: const Text('فحص موسّع'),
              subtitle: const Text('يضيف كل النطاقات المدعومة. أطول، ويستهلك أكثر.'),
            ),
            Wrap(spacing: 8, children: [
              FilledButton(onPressed: running || applying ? null : start, child: const Text('ابدأ الفحص')),
              if (running)
                OutlinedButton(
                    onPressed: cancel ? null : () => setState(() => cancel = true),
                    child: Text(cancel ? 'جارٍ الإيقاف...' : 'إيقاف')),
            ]),
          ]),
          if (running || logs.isNotEmpty)
            _card('التقدم', [
              if (running) LinearProgressIndicator(value: total > 0 ? (doneN / total).clamp(0.0, 1.0).toDouble() : null),
              const SizedBox(height: 6),
              Text(step),
              Text('استهلاك الفحص حتى الآن: ${(usedBytes / 1048576).toStringAsFixed(0)} MB',
                  style: const TextStyle(fontSize: 12, color: Colors.white54)),
              const SizedBox(height: 6),
              for (final l in logs) Text(l, style: const TextStyle(fontSize: 12, color: Colors.white60)),
            ]),
          if (done && ranked.isNotEmpty) ...[
            _card('النتيجة', [
              Text(advice),
              if (warn.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(warn, style: const TextStyle(color: Colors.orangeAccent)),
              ],
              if (autoMsg.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(autoMsg, style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
              if (r != null && !auto && !_changed) ...[
                const SizedBox(height: 10),
                FilledButton(onPressed: applying ? null : applyManual, child: Text('طبّق: ${r.label}')),
              ],
              if (_changed) ...[
                const SizedBox(height: 10),
                OutlinedButton(onPressed: applying ? null : undo, child: const Text('رجوع للإعداد الأول')),
              ],
            ]),
            _card('كل النتائج', [
              for (var i = 0; i < ranked.length; i++)
                _row(ranked[i].mbps == null ? 0 : ranked.take(i + 1).where((x) => x.mbps != null).length,
                    ranked[i], identical(ranked[i], r)),
              const Text('كل رقم قياس واحد، والشبكة المحمولة تتذبذب ±20% بين قياس وآخر. ولهذا نشترط فرقًا واضحًا ثم نتأكد بقياس ثانٍ.',
                  style: TextStyle(fontSize: 12, color: Colors.white54)),
            ]),
          ],
        ]),
      ),
    );
  }
}
