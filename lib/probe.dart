/// نتيجة الفحص السريع لنطاق واحد: هل سجّل الراوتر عليه واتصل بالشبكة؟
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

/// المرحلة 1: يجرّب كل نطاق بسرعة (بدون قياسات ثقيلة) ويسجّل الشغّال منها.
Future<List<BandProbe>> probeAll({
  required List<int> bands,
  required Future<ProbeRes> Function(String mask, String mode) probe,
  required bool Function() stop,
  required void Function(String) log,
  required void Function(String) step,
  required void Function() tick,
}) async {
  final out = <BandProbe>[];
  var dead = 0;
  for (var i = 0; i < bands.length; i++) {
    if (stop()) break;
    final b = bands[i];
    step('فحص سريع: النطاق B$b (${i + 1}/${bands.length})');
    final r = await probe(maskOne(b), '00');
    out.add(BandProbe(b, r));
    tick();
    if (r.ok) {
      log('B$b شغّال (${r.secs}ث): RSRP ${r.rsrp?.toStringAsFixed(0) ?? '-'} · SINR ${r.sinr?.toStringAsFixed(0) ?? '-'}');
      dead = 0;
    } else {
      log('B$b ما اشتغل: ${r.note}');
      dead = r.reachable ? 0 : dead + 1;
      if (dead >= 3) {
        log('الراوتر ما يردّ، أوقفت الفحص السريع.');
        break;
      }
    }
  }
  return out;
}

/// أفضل النطاقات الشغّالة (حسب SINR ثم RSRP)، بحد أقصى [max] للتعمّق.
List<int> workingBands(List<BandProbe> ps, {int max = 6}) {
  final w = ps.where((p) => p.res.ok).toList();
  w.sort((a, b) {
    final c = (b.res.sinr ?? -99.0).compareTo(a.res.sinr ?? -99.0);
    if (c != 0) return c;
    return (b.res.rsrp ?? -200.0).compareTo(a.res.rsrp ?? -200.0);
  });
  return <int>[for (final p in w.take(max)) p.band];
}
