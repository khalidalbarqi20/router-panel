import sys, re

def load(p):
    return open(p, encoding='utf-8').read()

def save(p, s):
    open(p, 'w', encoding='utf-8').write(s)

def rep(s, old, new, name):
    if s.count(old) != 1:
        print('NOT FOUND/AMBIGUOUS:', name)
        sys.exit(1)
    return s.replace(old, new, 1)

# ---------- main.dart ----------
m = load('lib/main.dart')
if 'num_(s[\'band\'])?.toInt()' in m:
    print('already patched'); sys.exit(0)
m = rep(m, 'keepAwake: awake,,', 'keepAwake: awake,', 'awake,,')
m = rep(m, 'while (sw.elapsed < const Duration(seconds: 40)) {',
        'while (sw.elapsed < const Duration(seconds: 55)) {', 'probe window')
m = rep(m, "final b = int.tryParse(s['band'] ?? '');",
        "final b = num_(s['band'])?.toInt();", 'band parse')
m = rep(m, "final applied = norm(n['LTEBand'] ?? '') == mask && n['NetworkMode'] == mode;",
        "final applied = norm(n['LTEBand'] ?? '') == norm(mask) && n['NetworkMode'] == mode;", 'applied')
m = rep(m, 'if (applied && connected && b != null && want.contains(b) && r != null) {',
        'if (applied && connected && b != null && want.contains(b)) {', 'cond')
save('lib/main.dart', m)

# ---------- game.dart / download.dart ----------
for p in ('lib/game.dart', 'lib/download.dart'):
    s = load(p)
    s = rep(s, 'final work = workingBands(pr);', 'final work = workingBands(pr, max: 8);', p)
    save(p, s)

# ---------- probe.dart ----------
save('lib/probe.dart', r'''/// نتيجة الفحص السريع لنطاق واحد: هل سجّل الراوتر عليه واتصل بالشبكة؟
class ProbeRes {
  final bool ok, reachable;
  final String band, note;
  final double? rsrp, sinr;
  final int secs;
  ProbeRes(this.ok, this.reachable, this.band, this.rsrp, this.sinr, this.secs, this.note);
}

class BandProbe {
  final int band;
  final ProbeRes res;
  BandProbe(this.band, this.res);
}

String maskOne(int b) => (1 << (b - 1)).toRadixString(16);

/// المرحلة 1: يجرّب كل نطاق بسرعة ويسجّل الشغّال منها.
/// - إذا ما ردّ الراوتر أثناء نطاق: ينتظر ويعيد المحاولة مرة، ولا يوقف الفحص إلا بعد 4 نطاقات متتالية.
/// - النطاقات التي لم يردّ الراوتر أثناءها تُعاد في تمريرة ثانية في النهاية.
Future<List<BandProbe>> probeAll({
  required List<int> bands,
  required Future<ProbeRes> Function(String mask, String mode) probe,
  required bool Function() stop,
  required void Function(String) log,
  required void Function(String) step,
  required void Function() tick,
}) async {
  final res = <int, ProbeRes>{};
  var offline = 0;

  Future<bool> pass(List<int> list, String tag, bool counts) async {
    for (var i = 0; i < list.length; i++) {
      if (stop()) return false;
      final b = list[i];
      step('$tag: النطاق B$b (${i + 1}/${list.length})');
      var r = await probe(maskOne(b), '00');
      if (!r.ok && !r.reachable) {
        log('B$b: الراوتر ما ردّ، أنتظر رجوعه ثم أعيد المحاولة...');
        await Future<void>.delayed(const Duration(seconds: 25));
        if (stop()) return false;
        r = await probe(maskOne(b), '00');
      }
      res[b] = r;
      if (counts) tick();
      if (r.ok) {
        log('B$b شغّال (${r.secs}ث): RSRP ${r.rsrp?.toStringAsFixed(0) ?? '-'} · SINR ${r.sinr?.toStringAsFixed(0) ?? '-'}');
      } else {
        log('B$b ما اشتغل: ${r.note}');
      }
      offline = r.reachable ? 0 : offline + 1;
      if (offline >= 4) {
        log('الراوتر ما يردّ بعد عدة محاولات، أوقفت الفحص السريع.');
        return false;
      }
    }
    return true;
  }

  final completed = await pass(bands, 'فحص سريع', true);
  if (completed && !stop()) {
    final retry = <int>[for (final b in bands) if (res[b] != null && !res[b]!.ok && !res[b]!.reachable) b];
    if (retry.isNotEmpty) {
      log('إعادة فحص ${retry.length} نطاق لم يردّ الراوتر أثناءها...');
      offline = 0;
      await pass(retry, 'إعادة فحص', false);
    }
  }
  final skipped = <int>[for (final b in bands) if (!res.containsKey(b)) b];
  if (skipped.isNotEmpty) {
    log('لم يُفحص: ${skipped.map((b) => 'B$b').join(' ')}');
  }
  return <BandProbe>[for (final b in bands) if (res.containsKey(b)) BandProbe(b, res[b]!)];
}

/// أفضل النطاقات الشغّالة (حسب SINR ثم RSRP)، بحد أقصى [max] للتعمّق.
List<int> workingBands(List<BandProbe> ps, {int max = 8}) {
  final w = ps.where((p) => p.res.ok).toList();
  w.sort((a, b) {
    final c = (b.res.sinr ?? -99.0).compareTo(a.res.sinr ?? -99.0);
    if (c != 0) return c;
    return (b.res.rsrp ?? -200.0).compareTo(a.res.rsrp ?? -200.0);
  });
  return <int>[for (final p in w.take(max)) p.band];
}
''')

# ---------- measure.dart: measureDown أثبت ----------
ms = load('lib/measure.dart')
i = ms.index('/// يقيس سرعة التنزيل بعدة اتصالات متوازية')
ms = ms[:i] + r'''/// يقيس سرعة التنزيل بعدة اتصالات متوازية، ويتجاهل أول [warm] ثانية (بداية بطيئة).
/// كل اتصال يبدأ متأخرًا قليلًا، ولو فشل المصدر (HTTP غير 200 أو انقطاع) ينتقل للمصدر التالي.
Future<Tput> measureDown(bool Function() stop, {int conns = 4, int secs = 8, int warm = 2}) async {
  final sw = Stopwatch()..start();
  final end = Duration(seconds: secs);
  final warmD = Duration(seconds: warm);
  var total = 0;
  var atWarm = -1;
  var warmMs = 0.0;
  var note = '';
  final urls = <String>[gDownUrl, for (final s in kDownSrcs) if (s.url != gDownUrl) s.url];

  Future<void> worker(int id) async {
    if (id > 0) await Future<void>.delayed(Duration(milliseconds: 300 * id));
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    var ui = 0, fails = 0;
    try {
      while (sw.elapsed < end && !stop() && fails < 4) {
        final url = urls[ui % urls.length];
        var got = 0;
        try {
          final req = await c.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 8));
          final res = await req.close().timeout(const Duration(seconds: 8));
          if (res.statusCode != 200) {
            if (note.isEmpty) note = 'HTTP ${res.statusCode}';
            fails++;
            ui++;
            await Future<void>.delayed(const Duration(milliseconds: 500));
            continue;
          }
          await for (final chunk in res.timeout(const Duration(seconds: 6))) {
            got += chunk.length;
            total += chunk.length;
            if (atWarm < 0 && sw.elapsed >= warmD) {
              atWarm = total;
              warmMs = sw.elapsedMicroseconds / 1000.0;
            }
            if (sw.elapsed >= end || stop()) break;
          }
        } catch (e) {
          if (note.isEmpty) note = 'خطأ: ${e.runtimeType}';
        }
        if (got > 0) {
          fails = 0;
        } else {
          fails++;
          ui++;
          await Future<void>.delayed(const Duration(milliseconds: 500));
        }
      }
    } finally {
      c.close(force: true);
    }
  }

  await Future.wait(<Future<void>>[for (var i = 0; i < conns; i++) worker(i)]);
  sw.stop();
  final totalMs = sw.elapsedMicroseconds / 1000.0;
  var mbps = 0.0;
  if (atWarm >= 0 && totalMs > warmMs + 500) {
    mbps = (total - atWarm) * 8 / ((totalMs - warmMs) * 1000.0);
  } else if (total > 0 && totalMs > 0) {
    mbps = total * 8 / (totalMs * 1000.0);
  }
  return Tput(mbps, total, note);
}
'''
save('lib/measure.dart', ms)
print('patched OK')
