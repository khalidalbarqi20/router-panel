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
