import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'measure.dart';
import 'probe.dart';

const Color _green = Color(0xFF39D353);

/// ما تحتاجه صفحة الألعاب من التطبيق الرئيسي.
class GameCtl {
  final String routerHost;
  final List<int> sup;
  final List<String> modes;
  final String Function() curMask;
  final String Function() curMode;
  final Future<bool> Function(String mask, String mode) apply;
  final Future<ProbeRes> Function(String mask, String mode) probe;
  final bool keepAwake;
  GameCtl({
    required this.routerHost,
    required this.sup,
    required this.modes,
    required this.curMask,
    required this.curMode,
    required this.apply,
    required this.probe,
    required this.keepAwake,
  });
}

class GameTarget {
  final String name, host;
  final int port;
  const GameTarget(this.name, this.host, {this.port = 443});
}

/// عناوين اختبار البنق الرسمية لمنطقة الشرق الأوسط في فورتنايت (صفحة دعم Epic).
const List<GameTarget> kFortniteTargets = <GameTarget>[
  GameTarget('البحرين', 'ping-bah.ds.on.epicgames.com'),
  GameTarget('مومباي', 'ping-mum.ds.on.epicgames.com'),
];

List<int> _bandsOf(String hex) {
  final m = int.tryParse(hex, radix: 16) ?? 0;
  return <int>[for (var i = 0; i < 63; i++) if ((m >> i) & 1 == 1) i + 1];
}

String _maskOf(Iterable<int> b) => b.fold<int>(0, (a, x) => a | (1 << (x - 1))).toRadixString(16);

String _f0(double? v) => v == null ? '-' : v.toStringAsFixed(0);

class Cand {
  final String mask, mode, label;
  final bool isBase;
  Cand(this.mask, this.mode, this.label, {this.isBase = false});
  bool applied = true;
  String note = '';
  PingStats? router;
  final Map<String, PingStats> t = <String, PingStats>{};
  double? score, p50, p95, jit, loss;
  String best = '';
}

/// النتيجة المركبة (الأقل أفضل): البنق بعد طرح بنق الراوتر + فرق الذروة + التذبذب + عقوبة الفقد.
double? _score(PingStats st, double rp) {
  if (st.ok.length < 5) return null;
  if (st.lost * 10 > st.sent) return null;
  final p50 = st.p50 ?? 0.0;
  final p95 = st.p95 ?? 0.0;
  final lat = max(1.0, p50 - rp);
  return lat + (p95 - p50) + 2.0 * st.jitter + 12.0 * st.lost;
}

void _eval(Cand c) {
  final rp = c.router?.p50 ?? 0.0;
  double? bestScore;
  String bestName = '';
  PingStats? bs;
  for (final e in c.t.entries) {
    final s = _score(e.value, rp);
    if (s != null && (bestScore == null || s < bestScore)) {
      bestScore = s;
      bestName = e.key;
      bs = e.value;
    }
  }
  c.score = bestScore;
  c.best = bestName;
  if (bs != null) {
    c.p50 = bs.p50;
    c.p95 = bs.p95;
    c.jit = bs.jitter;
    c.loss = bs.lossPct;
  }
}

class _LR {
  final PingStats st;
  final int bytes;
  _LR(this.st, this.bytes);
}

class GamePage extends StatefulWidget {
  final GameCtl ctl;
  const GamePage({super.key, required this.ctl});
  @override
  State<GamePage> createState() => _GameState();
}

class _GameState extends State<GamePage> {
  bool running = false, cancel = false, done = false, applying = false;
  String step = '', advice = '', recSub = '', bloatTxt = '', warn = '', applyMsg = '';
  int total = 0, doneN = 0;
  final List<String> logs = <String>[];
  List<Cand> ranked = <Cand>[];
  List<Cand> _cands = <Cand>[];
  List<BandProbe> probes = <BandProbe>[];
  Cand? best;
  String _curMask = '', _curMode = '';

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

  List<Cand> _gen(List<int> work, String baseMask, String baseMode) {
    final ms = <String>[for (final m in const ['00', '03']) if (widget.ctl.modes.contains(m)) m];
    final out = <Cand>[];
    for (final m in ms) {
      for (final b in work) {
        final mask = _maskOf(<int>[b]);
        if (mask == baseMask && m == baseMode) continue;
        out.add(Cand(mask, m, '${m == '03' ? '4G فقط' : 'تلقائي'} · B$b'));
      }
    }
    return out;
  }

  Future<void> _measure(Cand c, Pinger rp, List<Pinger> tp, List<String> names) async {
    final fs = <Future<PingStats>>[rp.series(12, gapMs: 120, stop: stop)];
    for (final p in tp) {
      fs.add(p.series(30, gapMs: 150, stop: stop));
    }
    final res = await Future.wait(fs);
    c.router = res[0];
    for (var i = 0; i < tp.length; i++) {
      c.t[names[i]] = res[i + 1];
    }
    _eval(c);
  }

  Future<bool> _waitNet(Pinger p, {int maxSec = 60}) async {
    final end = DateTime.now().add(Duration(seconds: maxSec));
    while (DateTime.now().isBefore(end)) {
      final v = await p.once();
      if (v != null) return true;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return false;
  }

  Future<_LR> _loaded(Pinger p, bool up) async {
    const secs = 8;
    final load = up
        ? loadUp(const Duration(seconds: secs), stop)
        : loadDown(const Duration(seconds: secs), stop);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final st = await p.series(((secs - 2) * 1000) ~/ 220, gapMs: 100, stop: stop);
    final bytes = await load;
    return _LR(st, bytes);
  }

  String _bloatLine(String what, PingStats idle, _LR r) {
    final i50 = idle.p50;
    if (r.bytes < 300000) return '$what: ما قدرت أولّد حملًا كافيًا لقياسه.';
    final l50 = r.st.p50;
    if (i50 == null) return '$what: تعذّر القياس.';
    if (l50 == null || r.st.ok.length < 3) {
      return '$what: انقطع الاتصال تقريبًا أثناء الحمل (سيئ جدًا).';
    }
    final inc = l50 - i50;
    final tag = inc <= 30 ? 'جيد' : (inc <= 100 ? 'متوسط' : 'سيئ');
    return '$what: ارتفع البنق ${inc >= 0 ? '+' : ''}${inc.toStringAsFixed(0)} ms ($tag).';
  }

  Future<void> start() async {
    final ctl = widget.ctl;
    final baseMask = ctl.curMask();
    final baseMode = ctl.curMode();
    if (baseMask.isEmpty || ctl.sup.isEmpty) {
      _set(() => step = 'ما قدرت أقرأ نطاقات الراوتر. ارجع وادخل من جديد.');
      return;
    }
    final mins = (ctl.sup.length * 25 / 60).ceil() + 8;
    final ok = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('بدء الفحص'),
            content: Text(
                'المرحلة 1: فحص سريع لكل النطاقات المدعومة (${ctl.sup.length}) لمعرفة أيها يشتغل.\n'
                'المرحلة 2: قياس البنق والتذبذب والفقد للنطاقات الشغّالة فقط.\n\n'
                'المدة المتوقعة: من $mins إلى ${mins + 10} دقيقة.\n\n'
                '• الإنترنت ينقطع عند كل تبديل، وعن كل الأجهزة (حتى الكمبيوتر).\n'
                '• لا تقفل التطبيق ولا تبتعد عن الراوتر.\n'
                '• في النهاية يرجع الراوتر لإعدادك الحالي، ولا يتغير شيء إلا إذا ضغطت «طبّق».'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ابدأ')),
            ],
          ),
        ) ??
        false;
    if (!ok) return;
    _set(() {
      running = true;
      cancel = false;
      done = false;
      ranked = <Cand>[];
      probes = <BandProbe>[];
      best = null;
      advice = '';
      recSub = '';
      bloatTxt = '';
      warn = '';
      applyMsg = '';
      logs.clear();
      total = ctl.sup.length + 4;
      doneN = 0;
      step = 'تجهيز';
    });
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    try {
      await _scan(baseMask, baseMode);
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
      step = cancel ? 'أُوقف الفحص' : 'انتهى الفحص';
    });
  }

  Future<void> _scan(String baseMask, String baseMode) async {
    final ctl = widget.ctl;
    _curMask = baseMask;
    _curMode = baseMode;
    await PingEngine.detect(ctl.routerHost);
    log(PingEngine.tcpOnly ? 'القياس بطريقة TCP (أمر ping غير متاح)' : 'القياس بأمر ping');

    final rp = Pinger(ctl.routerHost, tcpPort: 80);
    await rp.resolve();
    final tp = <Pinger>[];
    final names = <String>[];
    for (final t in kFortniteTargets) {
      final p = Pinger(t.host, tcpPort: t.port);
      if (await p.resolve()) {
        tp.add(p);
        names.add(t.name);
      } else {
        log('تعذّر الوصول لعنوان ${t.name}');
      }
    }
    if (tp.isEmpty) {
      log('لا إنترنت أو DNS لا يعمل. لا أقدر أبدأ.');
      return;
    }

    _set(() => step = 'قياس الإعداد الحالي');
    final base = Cand(baseMask, baseMode, 'الحالي', isBase: true);
    await _measure(base, rp, tp, names);
    _set(() => doneN++);
    if (base.score == null) {
      log('الإعداد الحالي فيه فقد كبير أو الأهداف لا تردّ. أوقفت الفحص.');
      _set(() => ranked = <Cand>[base]);
      return;
    }

    _set(() => step = 'المرحلة 1: فحص الترددات السريع');
    final pr = await probeAll(
      bands: ctl.sup,
      probe: ctl.probe,
      stop: stop,
      log: log,
      step: (s) => _set(() => step = s),
      tick: () => _set(() => doneN++),
    );
    var touched = pr.isNotEmpty;
    _curMask = '';
    final work = workingBands(pr);
    _set(() => probes = pr);
    log(work.isEmpty ? 'ما لقيت نطاقًا شغّالًا للتعمّق.' : 'النطاقات الشغّالة للتعمّق: ${work.map((b) => 'B$b').join(' ')}');
    final cands = _gen(work, baseMask, baseMode);
    _cands = cands;
    _set(() => total = doneN + cands.length + 2);

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
          c.applied = false;
          c.note = 'الراوتر لم يطبّق هذا الإعداد';
          fails++;
          log('لم يتأكد تطبيق ${c.label}');
          if (fails >= 3) {
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
      final up = await _waitNet(tp[0]);
      if (!up) {
        c.note = 'ما رجع الإنترنت بعد التبديل';
        log('ما رجع الإنترنت مع ${c.label}');
        _set(() => doneN++);
        continue;
      }
      await Future<void>.delayed(const Duration(seconds: 8));
      if (cancel) break;
      log('قياس ${c.label}...');
      await _measure(c, rp, tp, names);
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
      await _waitNet(tp[0]);
      await Future<void>.delayed(const Duration(seconds: 8));
    }

    if (!cancel) {
      _set(() => step = 'قياس الحالي مرة ثانية');
      final base2 = Cand(baseMask, baseMode, 'الحالي', isBase: true);
      await _measure(base2, rp, tp, names);
      final s1 = base.score;
      final s2 = base2.score;
      if (s1 != null && s2 != null) base.score = (s1 + s2) / 2;
      _set(() => doneN++);
    }

    if (!cancel && base.best.isNotEmpty) {
      _set(() => step = 'اختبار الحمل (تنزيل ثم رفع)');
      log('اختبار الحمل...');
      Pinger? bp;
      for (var i = 0; i < names.length; i++) {
        if (names[i] == base.best) bp = tp[i];
      }
      if (bp != null) {
        final idle = await bp.series(15, gapMs: 100, stop: stop);
        final dn = await _loaded(bp, false);
        final up = await _loaded(bp, true);
        _set(() => bloatTxt = '${_bloatLine('تحت التنزيل', idle, dn)}\n${_bloatLine('تحت الرفع', idle, up)}');
      }
      _set(() => doneN++);
    }

    _finish(base, _cands);
  }

  void _finish(Cand base, List<Cand> cands) {
    final all = <Cand>[base, ...cands];
    final valid = all.where((c) => c.score != null).toList()
      ..sort((a, b) => a.score!.compareTo(b.score!));
    final invalid = all.where((c) => c.score == null).toList();
    Cand? top;
    for (final c in valid) {
      if (!c.isBase) {
        top = c;
        break;
      }
    }
    final bs = base.score;
    Cand? rec;
    var adv = '';
    if (bs == null) {
      adv = 'ما قدرت أقيس الإعداد الحالي بشكل موثوق.';
    } else if (top == null) {
      adv = 'ما لقيت إعدادًا بديلًا قابلًا للقياس.';
    } else {
      final gain = bs - top.score!;
      final pct = bs > 0 ? gain / bs * 100 : 0.0;
      if (gain >= 5 && pct >= 15) {
        rec = top;
        adv = 'الأفضل: ${top.label}. تحسّن النتيجة المركبة بحوالي ${gain.toStringAsFixed(0)} نقطة (${pct.toStringAsFixed(0)}%). النقطة تعادل تقريبًا ملي ثانية.';
      } else {
        adv = 'إعدادك الحالي كافٍ. أفضل بديل (${top.label}) ما يتفوق عليه بفارق واضح.';
      }
    }
    final ref = rec ?? base;
    var sub = '';
    if (ref.t.isNotEmpty) {
      final lines = <String>[];
      for (final e in ref.t.entries) {
        lines.add('${e.key}: متوسط ${_f0(e.value.p50)} ms، فقد ${e.value.lossPct.toStringAsFixed(1)}%');
      }
      sub = lines.join('\n');
      if (ref.best.isNotEmpty) {
        sub += '\n\nفي فورتنايت: Settings ثم Game ثم Language and Region، واختر Subregion Preference = ${ref.best}.';
      }
    }
    final rr = base.router;
    var w = warn;
    if (rr != null && ((rr.p50 ?? 0) > 15 || rr.lost > 0)) {
      w += '${w.isEmpty ? '' : '\n'}الواي فاي بين الجوال والراوتر غير مستقر وقت الفحص، فالنتائج أقل ثقة. قرّب الجوال من الراوتر وأعد الفحص.';
    }
    if (cancel) w += '${w.isEmpty ? '' : '\n'}الفحص أُوقف قبل اكتماله.';
    _set(() {
      ranked = <Cand>[...valid, ...invalid];
      best = rec;
      advice = adv;
      recSub = sub;
      warn = w;
    });
  }

  Future<void> applyBest() async {
    final b = best;
    if (b == null) return;
    _set(() {
      applying = true;
      applyMsg = 'جارٍ التطبيق...';
    });
    final ok = await widget.ctl.apply(b.mask, b.mode);
    _set(() {
      applying = false;
      applyMsg = ok ? 'تم تطبيق ${b.label} وتأكّدت القراءة.' : 'ما تأكدت من التطبيق. افحص تبويب ROUTER.';
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

  Widget _row(int rank, Cand c, bool isBest) {
    final s = c.score;
    final head = '${rank > 0 ? '$rank. ' : ''}${c.label}${c.isBase ? '  (الحالي)' : ''}';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: isBest ? _green : Colors.white24, width: isBest ? 2 : 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(head, style: const TextStyle(fontWeight: FontWeight.bold)),
        if (s == null)
          Text(c.note.isEmpty ? 'ما قدرت أقيسه (فقد كبير أو لا ردّ)' : c.note,
              style: const TextStyle(color: Colors.white54))
        else
          Text('${c.best}: متوسط ${_f0(c.p50)} ms · ذروة ${_f0(c.p95)} · تذبذب ${_f0(c.jit)} · '
              'فقد ${(c.loss ?? 0).toStringAsFixed(1)}%\nالنتيجة: ${s.toStringAsFixed(0)} (الأقل أفضل)'),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final b = best;
    return PopScope(
      canPop: !running && !applying,
      child: Scaffold(
        appBar: AppBar(title: const Text('وضع الألعاب')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          _card('البروفايل', [
            Wrap(spacing: 8, children: [
              const ChoiceChip(label: Text('فورتنايت (كمبيوتر بكابل)'), selected: true, onSelected: null),
              const ChoiceChip(label: Text('ببجي (جوال) - قريبًا'), selected: false, onSelected: null),
            ]),
            const SizedBox(height: 8),
            const Text(
                'أولًا يفحص بسرعة أي النطاقات تشتغل عندك، ثم يقيس البنق والتذبذب وفقد الحزم لسيرفرات فورتنايت الرسمية (البحرين ومومباي) عبر الشغّالة فقط، ثم يقترح الأفضل. القياس من جوالك عبر الواي فاي، ويطرح بنق الراوتر من النتيجة.',
                style: TextStyle(color: Colors.white70)),
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
              const SizedBox(height: 6),
              for (final l in logs)
                Text(l, style: const TextStyle(fontSize: 12, color: Colors.white60)),
            ]),
          if (done && ranked.isNotEmpty) ...[
            _card('التوصية', [
              Text(advice),
              if (warn.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(warn, style: const TextStyle(color: Colors.orangeAccent)),
              ],
              if (b != null) ...[
                const SizedBox(height: 10),
                FilledButton(onPressed: applying ? null : applyBest, child: Text('طبّق: ${b.label}')),
              ],
              if (applyMsg.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(applyMsg),
              ],
            ]),
            if (probes.isNotEmpty)
              _card('الترددات الشغّالة (فحص سريع)', [
                for (final p in probes)
                  Text(
                      p.res.ok
                          ? '✓ B${p.band}: RSRP ${p.res.rsrp?.toStringAsFixed(0) ?? '-'} · SINR ${p.res.sinr?.toStringAsFixed(0) ?? '-'}'
                          : '✗ B${p.band}: ${p.res.note}',
                      style: TextStyle(fontSize: 13, color: p.res.ok ? _green : Colors.white54)),
              ]),
            if (recSub.isNotEmpty) _card('سيرفرات فورتنايت', [Text(recSub)]),
            if (bloatTxt.isNotEmpty)
              _card('الأداء تحت الحمل', [
                Text(bloatTxt),
                const SizedBox(height: 6),
                const Text('تقدير تقريبي لما يحدث لو أحد حمّل أو رفع وأنت تلعب. العلاج الحقيقي هو QoS أو تحديد السرعة، وهذا غير متاح في هذا الراوتر.',
                    style: TextStyle(fontSize: 12, color: Colors.white54)),
              ]),
            _card('كل النتائج', [
              for (var i = 0; i < ranked.length; i++)
                _row(ranked[i].score == null ? 0 : ranked.take(i + 1).where((x) => x.score != null).length, ranked[i],
                    identical(ranked[i], b)),
              TextButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: _plain())),
                child: const Text('نسخ النتائج'),
              ),
            ]),
          ],
        ]),
      ),
    );
  }

  String _plain() {
    final sb = StringBuffer();
    for (final c in ranked) {
      sb.writeln('${c.label}${c.isBase ? ' (الحالي)' : ''}: '
          '${c.score == null ? 'غير صالح ${c.note}' : 'score=${c.score!.toStringAsFixed(0)} p50=${_f0(c.p50)} p95=${_f0(c.p95)} jit=${_f0(c.jit)} loss=${(c.loss ?? 0).toStringAsFixed(1)}% target=${c.best}'}');
    }
    sb.writeln(advice);
    sb.writeln(bloatTxt);
    return sb.toString();
  }
}
