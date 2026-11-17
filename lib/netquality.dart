import 'dbg.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'game.dart';
import 'measure.dart';
import 'netcheck.dart';
import 'netinfo.dart' show gQuick;
import 'probe.dart';

const Color _nqGreen = Color(0xFF39D353);

double? _n(String? s) {
  final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(s ?? '');
  return m == null ? null : double.parse(m[0]!);
}

String _f0(double? v) => v == null ? '-' : v.toStringAsFixed(0);
String _f1(double? v) => v == null ? '-' : v.toStringAsFixed(1);
String _norm(String h) => h.toLowerCase().replaceFirst(RegExp('^0+'), '');

String _g(Map<String, String> m, List<String> ks) {
  for (final k in ks) {
    final v = m[k];
    if (v != null && v.isNotEmpty && v != '--') return v;
  }
  return '';
}

double _mean(List<double> v) => v.isEmpty ? 0.0 : v.reduce((a, b) => a + b) / v.length;

double _std(List<double> v) {
  if (v.length < 2) return 0.0;
  final m = _mean(v);
  var s = 0.0;
  for (final x in v) {
    s += (x - m) * (x - m);
  }
  return sqrt(s / v.length);
}

/// تقدير تقريبي لأقصى سرعة تنزيل متوقعة من عرض النطاق وSINR (للمقارنة فقط).
double? _expected(Map<String, String> sg) {
  final bw = _n(sg['dlbandwidth']);
  final sinr = _n(sg['sinr']);
  if (bw == null || sinr == null || bw <= 0) return null;
  final eff = (0.6 * (log(1 + pow(10, sinr / 10)) / ln2)).clamp(0.5, 4.5).toDouble();
  return bw * eff * 1.2;
}

class _Dl {
  final double mbps;
  final int bytes;
  final List<double> samples;
  _Dl(this.mbps, this.bytes, this.samples);
}

/// قياس تنزيل بعدة اتصالات، يتجاهل أول ثانية، ويقدر يوقف بدري إذا السرعة فوق [stopAbove].
Future<_Dl> _dlTest({
  required Duration maxD,
  required bool Function() stop,
  double? stopAbove,
  Duration minD = const Duration(milliseconds: 2000),
  int conns = 3,
  void Function(double mbps)? onTick,
}) async {
  final sw = Stopwatch()..start();
  var total = 0;
  var end = false;
  var alive = conns;
  final clients = <HttpClient>[];
  final urls = <String>[gDownUrl, for (final s in kDownSrcs) if (s.url != gDownUrl) s.url];

  Future<void> worker(int id) async {
    if (id > 0) await Future<void>.delayed(Duration(milliseconds: 150 * id));
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    clients.add(c);
    var ui = 0, fails = 0;
    try {
      while (!end && !stop() && fails < 3) {
        var got = 0;
        try {
          final req = await c.getUrl(Uri.parse(urls[ui % urls.length])).timeout(const Duration(seconds: 6));
          final res = await req.close().timeout(const Duration(seconds: 6));
          if (res.statusCode == 200) {
            await for (final chunk in res.timeout(const Duration(seconds: 5))) {
              got += chunk.length;
              total += chunk.length;
              if (end || stop()) break;
            }
          }
        } catch (e) {
      dbg('netquality.dart:92', e);
    }
        if (got > 0) {
          fails = 0;
        } else {
          fails++;
          ui++;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    } finally {
      alive--;
    }
  }

  final ws = <Future<void>>[for (var i = 0; i < conns; i++) worker(i)];
  final hist = <List<num>>[];
  final samples = <double>[];
  var atWarm = -1;
  var warmT = 0.0;
  var avg = 0.0;
  final maxS = maxD.inMilliseconds / 1000.0;
  final minS = minD.inMilliseconds / 1000.0;
  while (true) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    final t = sw.elapsedMilliseconds / 1000.0;
    if (atWarm < 0 && t >= 1.0) {
      atWarm = total;
      warmT = t;
    }
    if (atWarm >= 0 && t - warmT >= 0.5) {
      avg = (total - atWarm) * 8 / ((t - warmT) * 1e6);
      onTick?.call(avg);
    }
    hist.add(<num>[t, total]);
    if (hist.length >= 5) {
      final a = hist[hist.length - 5], b = hist.last;
      final dt = (b[0] - a[0]).toDouble();
      if (dt > 0) samples.add((b[1] - a[1]) * 8 / (dt * 1e6));
    }
    if (stop() || alive <= 0 || t >= maxS) break;
    if (stopAbove != null && atWarm >= 0 && t >= minS && avg >= stopAbove) break;
  }
  end = true;
  for (final c in clients) {
    c.close(force: true);
  }
  await Future.wait(ws).timeout(const Duration(seconds: 2), onTimeout: () => <void>[]);
  final t = sw.elapsedMilliseconds / 1000.0;
  var mbps = 0.0;
  if (atWarm >= 0 && t - warmT >= 0.5) {
    mbps = (total - atWarm) * 8 / ((t - warmT) * 1e6);
  } else if (total > 0 && t > 0) {
    mbps = total * 8 / (t * 1e6);
  }
  return _Dl(mbps, total, samples);
}

Future<PingStats?> _pingSeries(int n, int gapMs, bool Function() stop) async {
  final p = Pinger('1.1.1.1');
  if (!await p.resolve()) return null;
  return p.series(n, gapMs: gapMs, stop: stop);
}

enum NqLevel { idle, testing, good, ok, weak, veryWeak }

/// فحص الشبكة عند الدخول: خفيف (حوالي 5 ثواني) إذا الشبكة قوية، ويطوّل ويشخّص السبب إذا ضعيفة.
class NqController extends ChangeNotifier {
  final Map<String, String> Function() getSig;
  final Map<String, String> Function() getSt;
  final GameCtl Function() ctl;
  final Future<bool> Function(String) confirm;
  final void Function(bool) hold;

  NqController({
    required this.getSig,
    required this.getSt,
    required this.ctl,
    required this.confirm,
    required this.hold,
  });

  NqLevel level = NqLevel.idle;
  String stage = '', isoMsg = '', summary = '';
  final List<String> facts = <String>[];
  final List<String> reasons = <String>[];
  double? dl, up;
  bool running = false, expanded = false, isoRunning = false, canIso = false;
  bool _dead = false;
  int _gen = 0;
  double _goodThr = 20.0;

  void _notify() {
    if (!_dead) notifyListeners();
  }

  void toggle() {
    expanded = !expanded;
    _notify();
  }

  void reset() {
    _gen++;
    running = false;
    level = NqLevel.idle;
    facts.clear();
    reasons.clear();
    summary = '';
    isoMsg = '';
    canIso = false;
    dl = null;
    up = null;
    _notify();
  }

  @override
  void dispose() {
    _dead = true;
    super.dispose();
  }

  Future<void> start() async {
    if (running || isoRunning || _dead) return;
    final my = ++_gen;
    bool stop() => _dead || my != _gen;
    running = true;
    level = NqLevel.testing;
    stage = 'يجهّز الفحص...';
    facts.clear();
    reasons.clear();
    isoMsg = '';
    summary = '';
    canIso = false;
    expanded = false;
    dl = null;
    up = null;
    _notify();
    try {
      final exp = _expected(Map<String, String>.from(getSig()));
      _goodThr = exp == null ? 20.0 : (0.4 * exp).clamp(8.0, 25.0).toDouble();

      stage = 'فحص التأخر (البنق)...';
      _notify();
      final ps = await _pingSeries(6, 100, stop);
      if (stop()) return;

      stage = 'قياس سرعة التنزيل...';
      _notify();
      final d1 = await _dlTest(
        maxD: const Duration(seconds: 5),
        stopAbove: _goodThr,
        stop: stop,
        onTick: (m) {
          dl = m;
          _notify();
        },
      );
      if (stop()) return;
      dl = d1.mbps;

      stage = 'قياس سرعة الرفع...';
      _notify();
      final sw = Stopwatch()..start();
      final ub = await loadUp(const Duration(seconds: 2), stop);
      up = ub * 8 / (max(sw.elapsedMilliseconds, 1) * 1000.0);
      if (stop()) return;

      final p50 = ps?.p50;
      final strong = d1.bytes > 0 && (dl ?? 0) >= _goodThr && (ps?.lost ?? 99) <= 1 && (p50 == null || p50 < 90);

      var dFinal = d1;
      PingStats? loaded;
      final samples = <Map<String, String>>[];
      if (!strong) {
        final secs = (dl ?? 0) < _goodThr * 0.3 ? 14 : 8;
        stage = 'السرعة أقل من المطلوب، يفحص السبب ($secs ثانية)...';
        _notify();
        final tm = Timer.periodic(const Duration(milliseconds: 500), (_) {
          samples.add(Map<String, String>.from(getSig()));
        });
        try {
          final dF = _dlTest(
            maxD: Duration(seconds: secs),
            conns: 4,
            stop: stop,
            onTick: (m) {
              dl = m;
              _notify();
            },
          );
          final pF = _pingSeries(secs * 2 - 2, 500, stop);
          dFinal = await dF;
          loaded = await pF;
        } finally {
          tm.cancel();
        }
        if (stop()) return;
        if (dFinal.bytes > 0) dl = dFinal.mbps;
      }
      await _conclude(d: dFinal, idle: ps, loaded: loaded, samples: samples, deep: !strong);
    } catch (e) {
      if (my == _gen) {
        level = NqLevel.veryWeak;
        reasons.add('تعذّر إكمال الفحص: $e');
        expanded = true;
      }
    } finally {
      if (my == _gen) {
        running = false;
        _notify();
      }
    }
  }

  Future<void> _conclude({
    required _Dl d,
    PingStats? idle,
    PingStats? loaded,
    required List<Map<String, String>> samples,
    required bool deep,
  }) async {
    final sg = getSig();
    final st = getSt();
    final rsrp = _n(sg['rsrp']), sinr = _n(sg['sinr']), rsrq = _n(sg['rsrq']);
    final band = (sg['band'] ?? '').trim();
    final bw = _n(sg['dlbandwidth']);
    final ca = isCaMap(st, sg);
    final exp = _expected(sg);
    final speed = dl ?? 0.0;
    final hasData = d.bytes > 50000 && speed > 0;
    final sigGood = rsrp != null && rsrp >= -95 && (sinr ?? 0) >= 8;

    if (!hasData) {
      level = NqLevel.veryWeak;
    } else if (speed >= _goodThr) {
      level = NqLevel.good;
    } else if (speed >= _goodThr * 0.5) {
      level = NqLevel.ok;
    } else if (speed >= _goodThr * 0.15) {
      level = NqLevel.weak;
    } else {
      level = NqLevel.veryWeak;
    }

    final freq = _g(sg, <String>['earfcn', 'dlearfcn', 'ltedlfreq']);
    facts.add('تنزيل ${_f1(dl)} Mbps · رفع ${_f1(up)} Mbps (الرفع تقريبي) · بنق ${_f0(idle?.p50)}ms · فقد ${_f0(idle?.lossPct)}%');
    facts.add('الإشارة: RSRP ${_f0(rsrp)} dBm · SINR ${_f0(sinr)} dB · RSRQ ${_f0(rsrq)} dB');
    facts.add('النطاق ${band.isEmpty ? '-' : 'B$band'}${bw == null ? '' : ' · ${_f0(bw)}MHz'}'
        '${freq.isEmpty ? '' : ' · EARFCN $freq'}${ca ? ' · تجميع نطاقات شغّال' : ' · بدون تجميع'}');
    if (exp != null) {
      facts.add('المتوقع نظريًا لهذا النطاق مع هذي الإشارة: حوالي ${_f0(exp)} Mbps (تقدير تقريبي للمقارنة فقط)');
    }
    summary = 'تنزيل ${_f1(dl)} · رفع ${_f1(up)} Mbps · بنق ${_f0(idle?.p50)}ms';

    if (level == NqLevel.good) {
      reasons.add('الشبكة تعطي سرعة جيدة على ${band.isEmpty ? 'النطاق الحالي' : 'B$band'}، وما فيه مشكلة ظاهرة.');
      canIso = false;
      expanded = false;
      return;
    }

    if (!hasData) {
      final nd = await netDiag();
      reasons.add(nd == 'OK'
          ? 'ما وصلت بيانات من مصادر الفحص مع أن الإنترنت يبان شغّال. أعد الفحص.'
          : 'ما فيه إنترنت فعلي ($nd). الراوتر متصل بالبرج لكن البيانات ما تمر: الشريحة أو الرصيد أو ازدحام شديد.');
    }
    if (hasData && sigGood && (level == NqLevel.weak || level == NqLevel.veryWeak)) {
      reasons.add('المؤشرات تبين ممتازة (RSRP ${_f0(rsrp)} / SINR ${_f0(sinr)}) لكن السرعة الفعلية ضعيفة، فالمشكلة مو في قوة الإشارة نفسها.');
    }
    if (rsrp != null && rsrp < -105) {
      reasons.add('RSRP ضعيف (${_f0(rsrp)} dBm): الإشارة ضعيفة فعلًا، وجّه الانتينا لين يتحسن.');
    }
    if (sinr != null && sinr < 8) {
      reasons.add('SINR منخفض (${_f0(sinr)} dB): فيه تداخل أو ضجيج، مثل خلية قريبة بنفس التردد أو نطاق مدموج يخرّب أو انعكاسات. حرّك الانتينا ببطء وراقب SINR.');
    }
    if (sigGood && rsrq != null && rsrq <= -12) {
      reasons.add('RSRQ سيئ (${_f0(rsrq)} dB) مع RSRP قوي: علامة ازدحام على البرج أو تداخل.');
    }

    final rs = <double>[for (final s in samples) if (_n(s['rsrp']) != null) _n(s['rsrp'])!];
    final qs = <double>[for (final s in samples) if (_n(s['sinr']) != null) _n(s['sinr'])!];
    var unstable = false;
    if (rs.length >= 6 && (_std(rs) > 3 || _std(qs) > 3)) {
      unstable = true;
      reasons.add('الإشارة تتذبذب أثناء الفحص (RSRP ±${_f1(_std(rs))} dB · SINR ±${_f1(_std(qs))} dB): انعكاسات أو الانتينا ما هي ثابتة أو تداخل متغيّر.');
    }
    final bands = <String>{for (final s in samples) if ((s['band'] ?? '').isNotEmpty) s['band']!};
    final cells = <String>{for (final s in samples) if ((s['cell_id'] ?? '').isNotEmpty) s['cell_id']!};
    if (bands.length > 1) {
      unstable = true;
      reasons.add('الراوتر بدّل النطاق أثناء الفحص (${bands.map((b) => 'B$b').join(' ← ')}): هذا يقطع السرعة. ثبّت نطاق واحد.');
    } else if (cells.length > 1) {
      unstable = true;
      reasons.add('الراوتر بدّل الخلية/البرج أثناء الفحص (${cells.length} خلايا): الإشارة على حدود برجين.');
    }

    if (d.samples.length >= 8) {
      final m = _mean(d.samples);
      if (m > 0 && _std(d.samples) / m > 0.5) {
        reasons.add('السرعة تقفز كثير من لحظة للثانية: ازدحام على البرج أو الخط غير مستقر.');
      }
    }
    final ip = idle?.p50, lp = loaded?.p50;
    if (ip != null && lp != null && lp - ip > 150) {
      reasons.add('البنق يرتفع من ${_f0(ip)} إلى ${_f0(lp)}ms وقت التحميل: الخط ما يستوعب الضغط (ازدحام).');
    }
    if ((idle?.lossPct ?? 0) >= 15 || (loaded?.lossPct ?? 0) >= 10) {
      reasons.add('فيه فقد حزم (${_f0(idle?.lossPct)}% عادي · ${_f0(loaded?.lossPct)}% وقت التحميل).');
    }
    final u = up;
    if (hasData && u != null && u < 1) {
      reasons.add('الرفع ضعيف جدًا (${_f1(u)} Mbps).');
    }
    if (hasData && sigGood && !unstable && (rsrq == null || rsrq > -12) &&
        (level == NqLevel.weak || level == NqLevel.veryWeak)) {
      reasons.add('الإشارة قوية ومستقرة والسرعة منخفضة: غالبًا ازدحام على البرج (خصوصًا وقت الذروة) أو ضعف الربط الخلفي عند المشغّل، مو من الراوتر ولا الانتينا.');
    }
    if (ca) {
      reasons.add('تجميع النطاقات (4G+) شغّال: لو أحد النطاقات المدموجة ضعيف أو مزدحم يسحب الأداء ويخرّب على الأساسي. اضغط «افحص التجميع» أدناه للتأكد.');
    }
    if (exp != null && hasData && band.isNotEmpty) {
      final ratio = speed / exp;
      reasons.add(ratio >= 0.5
          ? 'التردد الحالي (B$band) يشتغل بشكل جيد.'
          : (ratio >= 0.25
              ? 'التردد الحالي (B$band) أداؤه أقل من المتوقع (${_f0(ratio * 100)}% من المتوقع).'
              : 'التردد الحالي (B$band) ما يعطي المتوقع أبدًا (${_f0(ratio * 100)}% فقط)، فيه ما يعيقه.'));
    }
    BandProbe? best;
    for (final p in gQuick) {
      if (!p.res.ok || p.res.sinr == null || '${p.band}' == band) continue;
      if (best == null || p.res.sinr! > best.res.sinr!) best = p;
    }
    if (best != null && sinr != null && best.res.sinr! >= sinr + 4) {
      reasons.add('حسب الاختبار القصير السابق: B${best.band} كان SINR أعلى (${_f0(best.res.sinr)} مقابل ${_f0(sinr)}) فجرّب تقفل عليه.');
    }

    canIso = band.isNotEmpty;
    expanded = true;
  }

  Future<bool> _waitNet() async {
    for (var i = 0; i < 12; i++) {
      final t = await _dlTest(maxD: const Duration(seconds: 3), conns: 1, stop: () => _dead);
      if (t.bytes > 50000) return true;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return false;
  }

  /// يقفل مؤقتًا على النطاق الحالي فقط ويقارن السرعة بالإعداد الأصلي (التجميع/كل النطاقات)، ثم يرجّع الإعداد.
  Future<void> isolate() async {
    if (running || isoRunning || _dead) return;
    final sg = getSig();
    final b = int.tryParse((sg['band'] ?? '').trim());
    if (b == null) {
      isoMsg = 'ما قدرت أعرف النطاق الحالي.';
      _notify();
      return;
    }
    final g = ctl();
    final curMask = g.curMask();
    final curMode = g.curMode();
    final one = (1 << (b - 1)).toRadixString(16);
    if (_norm(curMask) == _norm(one)) {
      isoMsg = 'الراوتر مقفول أصلًا على B$b فقط، فما فيه نطاقات ثانية تخرّب عليه.';
      _notify();
      return;
    }
    final ok = await confirm('يقفل الراوتر مؤقتًا على النطاق الحالي B$b فقط ويقيس السرعة، ثم يرجّع إعدادك الأصلي.\n\n'
        'ينقطع الإنترنت من 20 إلى 60 ثانية عن كل الأجهزة، ويستهلك قرابة 100 إلى 300 ميجا. متأكد؟');
    if (!ok) return;
    isoRunning = true;
    isoMsg = '';
    hold(true);
    _notify();
    var changed = false, restored = false;
    final lines = <String>[];
    try {
      stage = 'قياس السرعة الحالية قبل العزل...';
      _notify();
      final a1 = await _dlTest(maxD: const Duration(seconds: 8), conns: 4, stop: () => _dead);

      stage = 'يقفل على B$b فقط...';
      _notify();
      changed = true;
      await g.apply(one, curMode);
      await _waitNet();

      stage = 'قياس السرعة على B$b لحاله...';
      _notify();
      final s = await _dlTest(maxD: const Duration(seconds: 8), conns: 4, stop: () => _dead);
      var sn = <String, String>{};
      try {
        final f = g.snap;
        if (f != null) sn = await f();
      } catch (e) {
      dbg('netquality.dart:488', e);
    }

      stage = 'يرجّع إعدادك الأصلي...';
      _notify();
      restored = await g.apply(curMask, curMode);
      await _waitNet();

      stage = 'قياس السرعة بعد الرجوع...';
      _notify();
      final a2 = await _dlTest(maxD: const Duration(seconds: 8), conns: 4, stop: () => _dead);

      final aggs = <double>[if (a1.bytes > 50000) a1.mbps, if (a2.bytes > 50000) a2.mbps];
      final agg = _mean(aggs);
      final sinrS = _n(sn['sinr']);
      lines.add('على B$b لحاله: ${_f1(s.mbps)} Mbps${sinrS == null ? '' : ' (SINR ${_f0(sinrS)} dB)'}');
      lines.add('بالإعداد الأصلي (كل النطاقات/التجميع): ${_f1(agg)} Mbps');
      if (s.bytes < 50000 || aggs.isEmpty) {
        lines.add('ما قدرت أقيس بشكل كامل (الإنترنت ما رجع بسرعة). أعد الفحص.');
      } else if (s.mbps >= agg * 1.3 && s.mbps - agg >= 2) {
        lines.add('النتيجة: النطاقات الثانية أو التجميع تخرّب على B$b. الأفضل تخلّي B$b أساسي فقط (من تبويب ROUTER ← نطاقات 4G).');
      } else if (s.mbps <= agg * 0.7) {
        lines.add('النتيجة: التجميع يرفع السرعة عندك، فهو ما يخرّب. خلّه.');
      } else {
        lines.add('النتيجة: ما فيه فرق واضح، التجميع ما يخرّب على B$b ولا يفيد كثير. (القياس تقريبي ويتأثر بالازدحام)');
      }
    } catch (e) {
      lines.add('تعذّر إكمال الفحص: $e');
    } finally {
      if (changed && !restored) {
        try {
          restored = await g.apply(curMask, curMode);
        } catch (e) {
      dbg('netquality.dart:519', e);
    }
      }
      lines.add(restored
          ? 'تم إرجاع إعدادك الأصلي.'
          : 'تنبيه: ما تأكدت من رجوع الإعداد الأصلي. افتح تبويب ROUTER واضغط «رجوع للإعداد الأول».');
      isoMsg = lines.join('\n');
      isoRunning = false;
      hold(false);
      _notify();
    }
  }
}

Color _nqColor(NqLevel l) {
  switch (l) {
    case NqLevel.good:
      return _nqGreen;
    case NqLevel.ok:
      return Colors.amber;
    case NqLevel.weak:
      return Colors.orange;
    case NqLevel.veryWeak:
      return Colors.redAccent;
    default:
      return Colors.lightBlueAccent;
  }
}

String _nqLabel(NqLevel l) {
  switch (l) {
    case NqLevel.good:
      return 'قوية';
    case NqLevel.ok:
      return 'متوسطة';
    case NqLevel.weak:
      return 'ضعيفة';
    case NqLevel.veryWeak:
      return 'ضعيفة جدًا';
    default:
      return 'جاري الفحص...';
  }
}

/// شريط «حالة الشبكة» أعلى الشاشة: يضغط عليه ليفتح التفاصيل.
class NetQualityBanner extends StatelessWidget {
  final NqController c;
  const NetQualityBanner(this.c, {super.key});

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: c,
        builder: (ctx, _) {
          if (c.level == NqLevel.idle) return const SizedBox.shrink();
          final col = _nqColor(c.level);
          final busy = c.running || c.isoRunning;
          return Container(
            width: double.infinity,
            color: col.withAlpha(45),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              InkWell(
                onTap: c.toggle,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(children: [
                    Icon(c.level == NqLevel.good ? Icons.network_check : Icons.warning_amber_rounded, color: col, size: 22),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('حالة الشبكة: ${_nqLabel(c.level)}',
                            style: TextStyle(fontWeight: FontWeight.bold, color: col, fontSize: 15)),
                        Text(busy ? c.stage : c.summary,
                            style: const TextStyle(fontSize: 12, color: Colors.white70)),
                      ]),
                    ),
                    if (!busy)
                      IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: 'أعد الفحص',
                          onPressed: () => c.start(),
                          icon: const Icon(Icons.refresh)),
                    Icon(c.expanded ? Icons.expand_less : Icons.expand_more, color: Colors.white54),
                  ]),
                ),
              ),
              if (busy) const LinearProgressIndicator(minHeight: 2),
              if (c.expanded && !c.running)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final f in c.facts)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(f, style: const TextStyle(fontSize: 12, color: Colors.white70)),
                      ),
                    if (c.reasons.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      const Text('التشخيص', style: TextStyle(fontWeight: FontWeight.bold)),
                      for (final r in c.reasons)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('• $r', style: const TextStyle(fontSize: 13)),
                        ),
                    ],
                    if (c.canIso) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: c.isoRunning ? null : () => c.isolate(),
                        icon: const Icon(Icons.call_split),
                        label: const Text('افحص التجميع (عزل النطاق الحالي)'),
                      ),
                    ],
                    if (c.isoMsg.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SelectableText(c.isoMsg, style: const TextStyle(fontSize: 13)),
                    ],
                  ]),
                ),
            ]),
          );
        },
      );
}
