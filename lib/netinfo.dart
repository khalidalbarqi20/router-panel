import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'game.dart';
import 'measure.dart';
import 'netcheck.dart';
import 'probe.dart';
import 'pubg.dart' show kPubgTargets;

const Color _green = Color(0xFF39D353);
const FlutterSecureStorage _store = FlutterSecureStorage();

/// نطاقات LTE الشائعة في السعودية: تُفحص حتى لو ما ظهرت في قائمة الراوتر (مثل B28).
const List<int> kSaudiBands = <int>[1, 3, 5, 7, 8, 20, 28, 38, 40, 41, 42, 43];

/// آخر نتيجة للاختبار القصير (تبقى طول الجلسة).
List<BandProbe> gQuick = <BandProbe>[];
DateTime? gQuickAt;

String _g(Map<String, String> m, List<String> keys) {
  for (final k in keys) {
    final v = m[k];
    if (v != null && v.isNotEmpty && v != '--') return v;
  }
  return '';
}

String _cellTxt(String id) {
  final v = int.tryParse(id);
  if (v == null) return id.isEmpty ? '-' : id;
  if (v > 255) return 'برج ${v >> 8} · خلية ${v & 255}';
  return 'خلية $v';
}

String _netType(String t) {
  switch (t) {
    case '1011':
      return '4G+ (تجميع نطاقات)';
    case '101':
      return '4G';
    case '46':
      return '3G+ (DC-HSPA+)';
    case '45':
      return '3G+ (HSPA+)';
    case '41':
      return '3G (WCDMA)';
    case '':
      return '-';
    default:
      return 'نوع $t';
  }
}

bool _snapCa(Map<String, String> m) =>
    isCaMap(<String, String>{'CurrentNetworkTypeEx': m['st_CurrentNetworkTypeEx'] ?? ''}, m);

String _maskOf(Iterable<int> b) => b.fold<int>(0, (a, x) => a | (1 << (x - 1))).toRadixString(16);

String _f(double? v) => v == null ? '-' : v.toStringAsFixed(0);

class DRow {
  final String label, mask;
  PingStats? t;
  double? score, mbps;
  bool ca = false;
  String cell = '', note = '';
  DRow(this.label, this.mask);
}

double? _dscore(PingStats st, double rp) {
  if (st.ok.length < 5) return null;
  if (st.lost * 10 > st.sent) return null;
  final p50 = st.p50 ?? 0.0;
  final p95 = st.p95 ?? 0.0;
  return max(1.0, p50 - rp) + (p95 - p50) + 2.0 * st.jitter + 12.0 * st.lost;
}

class NetInfoPage extends StatefulWidget {
  final GameCtl ctl;
  const NetInfoPage({super.key, required this.ctl});
  @override
  State<NetInfoPage> createState() => _NIState();
}

class _NIState extends State<NetInfoPage> {
  Map<String, String> snap = <String, String>{};
  List<Map<String, String>> hosts = <Map<String, String>>[];
  bool loading = false, running = false, cancel = false, applying = false;
  String step = '', applyMsg = '';
  final List<String> logs = <String>[];
  List<DRow> rows = <DRow>[];
  String bestPingLabel = '', bestPingMask = '', bestSpeedLabel = '', bestSpeedMask = '';
  final Map<int, int> roles = <int, int>{};
  String roleMsg = '';
  Pinger? rp;
  final List<Pinger> tp = <Pinger>[];
  final List<String> tn = <String>[];

  bool stop() => cancel;

  void _set(void Function() f) {
    if (mounted) setState(f);
  }

  void log(String s) {
    _set(() {
      logs.add(s);
      if (logs.length > 25) logs.removeAt(0);
    });
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    _loadRoles();
  }

  Future<void> _refresh() async {
    _set(() => loading = true);
    Map<String, String> s = snap;
    List<Map<String, String>> h = hosts;
    try {
      final f = widget.ctl.snap;
      if (f != null) s = await f();
    } catch (_) {}
    try {
      final f = widget.ctl.hosts;
      if (f != null) h = await f();
    } catch (_) {}
    _set(() {
      snap = s;
      hosts = h;
      loading = false;
    });
  }

  List<int> get _bands => <int>{...widget.ctl.scan}.toList()..sort();

  Future<bool> _confirm(String title, String body) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('ابدأ')),
        ],
      ),
    );
    return r ?? false;
  }

  Future<void> _begin() async {
    _set(() {
      running = true;
      cancel = false;
      applyMsg = '';
      logs.clear();
    });
    try {
      await WakelockPlus.enable();
    } catch (_) {}
  }

  Future<void> _end(String msg) async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
    _set(() {
      running = false;
      step = cancel ? 'أُوقف' : msg;
    });
    await _refresh();
  }

  // ---------- الاختبار القصير ----------
  Future<void> _quickTest() async {
    if (running || applying) return;
    final bands = _bands;
    final mins = (bands.length * 25 / 60).ceil();
    final ok = await _confirm('الاختبار القصير',
        'يفحص ${bands.length} نطاقًا سريعًا (يشمل B28) ويعرف أيها يشتغل. الإنترنت ينقطع عن كل الأجهزة أثناءه، والمدة التقريبية من $mins إلى ${mins * 2 + 2} دقيقة. في النهاية يرجع إعدادك الحالي.');
    if (!ok) return;
    await _begin();
    try {
      await _quickRun();
    } catch (e) {
      log('خطأ غير متوقع: $e');
    }
    await _end('انتهى الاختبار القصير');
  }

  /// يفحص كل النطاقات ويحفظ النتيجة في gQuick ثم يرجّع الإعداد الأول.
  Future<bool> _quickRun() async {
    final ctl = widget.ctl;
    if (!await ensureInternet(ctl, log, stop, () async => mounted && await askRepair(context))) {
      log('أوقفت الفحص: ما فيه إنترنت.');
      return false;
    }
    final baseMask = ctl.curMask();
    final baseMode = ctl.curMode();
    if (baseMask.isEmpty) {
      log('ما قدرت أقرأ إعداد النطاقات الحالي.');
      return false;
    }
    final pr = await probeAll(
      bands: _bands,
      probe: ctl.probe,
      stop: stop,
      log: log,
      step: (s) => _set(() => step = s),
      tick: () {},
    );
    gQuick = pr;
    gQuickAt = DateTime.now();
    _set(() => step = 'رجوع للإعداد الحالي');
    final back = await ctl.apply(baseMask, baseMode);
    if (!back) log('تنبيه: ما تأكدت من الرجوع للإعداد الأول. افحص تبويب ROUTER.');
    return true;
  }

  // ---------- الفحص الشامل ----------
  Future<bool> _waitNet(Pinger p, {int maxSec = 60}) async {
    final end = DateTime.now().add(Duration(seconds: maxSec));
    while (DateTime.now().isBefore(end) && !cancel) {
      if (await p.once() != null) return true;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return false;
  }

  Future<void> _deepTest() async {
    if (running || applying) return;
    final stale = gQuick.isEmpty || gQuickAt == null || DateTime.now().difference(gQuickAt!).inMinutes > 30;
    final ok = await _confirm('الفحص الشامل',
        stale
            ? 'ما فيه نتيجة حديثة للاختبار القصير، فيشغّله أولًا ثم يقيس كل نطاق شغّال (بنق وتذبذب وفقد وسرعة تنزيل) وكل الشغّالة معًا. يأخذ وقتًا طويلًا (قد يصل لساعة)، والإنترنت ينقطع أثناءه.'
            : 'يقيس كل نطاق شغّال حسب آخر اختبار قصير (بنق وتذبذب وفقد وسرعة تنزيل) وكل الشغّالة معًا. والإنترنت ينقطع أثناءه.');
    if (!ok) return;
    await _begin();
    _set(() {
      rows = <DRow>[];
      bestPingMask = '';
      bestSpeedMask = '';
    });
    try {
      await _deepRun(stale);
    } catch (e) {
      log('خطأ غير متوقع: $e');
    }
    await _end('انتهى الفحص الشامل');
  }

  Future<void> _deepRun(bool stale) async {
    final ctl = widget.ctl;
    if (stale) {
      if (!await _quickRun() || cancel) return;
    } else if (!await ensureInternet(ctl, log, stop, () async => mounted && await askRepair(context))) {
      return;
    }
    final baseMask = ctl.curMask();
    final baseMode = ctl.curMode();
    final work = workingBands(gQuick, max: 40);
    if (work.isEmpty) {
      log('ما فيه نطاق شغّال حسب الاختبار القصير.');
      return;
    }
    _set(() => step = 'تجهيز');
    await PingEngine.detect(ctl.routerHost);
    final r = Pinger(ctl.routerHost, tcpPort: 80);
    await r.resolve();
    rp = r;
    tp.clear();
    tn.clear();
    for (final t in kPubgTargets) {
      final p = Pinger(t.host, tcpPort: t.port);
      if (await p.resolve()) {
        tp.add(p);
        tn.add(t.name);
      }
    }
    final gulf = <int>[for (var i = 0; i < tp.length; i++) if (tn[i].startsWith('AWS')) i];
    final pool = gulf.isNotEmpty ? gulf : <int>[for (var i = 0; i < tp.length; i++) i];
    if (pool.isEmpty) {
      log('ما قدرت أحل عناوين القياس.');
      return;
    }
    var bi = pool.first;
    double? bp;
    for (final i in pool) {
      final s = await tp[i].series(8, gapMs: 100, stop: stop);
      final p = s.p50;
      if (p != null && (bp == null || p < bp)) {
        bp = p;
        bi = i;
      }
    }
    final target = tp[bi];
    log('هدف القياس: ${tn[bi]}');
    final src = await pickDownSource(log, stop);
    final rBase = await r.series(15, gapMs: 100, stop: stop);
    final rp0 = rBase.p50 ?? 0.0;

    final cands = <DRow>[DRow('الحالي', baseMask)];
    for (final b in work) {
      cands.add(DRow('B$b', maskOne(b)));
    }
    if (work.length >= 2) cands.add(DRow('كل الشغّالة معًا', _maskOf(work)));

    var touched = false;
    for (var i = 0; i < cands.length && !cancel; i++) {
      final c = cands[i];
      _set(() => step = 'قياس ${c.label} (${i + 1}/${cands.length})');
      if (i > 0) {
        touched = true;
        final applied = await ctl.apply(c.mask, '00');
        if (!applied) {
          c.note = 'الراوتر لم يطبّقه';
          _set(() => rows = List<DRow>.from(cands.sublist(0, i + 1)));
          continue;
        }
        if (!await _waitNet(target)) {
          c.note = 'ما رجع الإنترنت';
          _set(() => rows = List<DRow>.from(cands.sublist(0, i + 1)));
          continue;
        }
        await Future<void>.delayed(const Duration(seconds: 8));
      }
      try {
        final f = ctl.snap;
        if (f != null) {
          final m = await f();
          c.ca = _snapCa(m);
          c.cell = _g(m, <String>['cell_id']);
        }
      } catch (_) {}
      final s = await target.series(40, gapMs: 120, stop: stop);
      final rr = await r.series(15, gapMs: 100, stop: stop);
      c.t = s;
      c.score = _dscore(s, rr.p50 ?? rp0);
      if (src.isNotEmpty) {
        final tput = await measureDown(stop, conns: 4, secs: 6);
        c.mbps = tput.mbps;
        if (tput.bytes < 50000 && tput.note.isNotEmpty) c.note = 'سرعة: ${tput.note}';
      }
      _set(() => rows = List<DRow>.from(cands.sublist(0, i + 1)));
    }
    if (touched) {
      _set(() => step = 'رجوع للإعداد الحالي');
      final back = await ctl.apply(baseMask, baseMode);
      if (!back) log('تنبيه: ما تأكدت من الرجوع للإعداد الأول. افحص تبويب ROUTER.');
      await _waitNet(target);
    }
    final withScore = cands.where((c) => c.score != null && c.mask != baseMask).toList()
      ..sort((a, b) => a.score!.compareTo(b.score!));
    final withSpeed = cands.where((c) => (c.mbps ?? 0) > 0.5 && c.mask != baseMask).toList()
      ..sort((a, b) => b.mbps!.compareTo(a.mbps!));
    _set(() {
      rows = List<DRow>.from(cands);
      if (withScore.isNotEmpty) {
        bestPingLabel = withScore.first.label;
        bestPingMask = withScore.first.mask;
      }
      if (withSpeed.isNotEmpty) {
        bestSpeedLabel = withSpeed.first.label;
        bestSpeedMask = withSpeed.first.mask;
      }
    });
  }

  Future<void> _apply(String mask, String label) async {
    if (running || applying || mask.isEmpty) return;
    _set(() {
      applying = true;
      applyMsg = 'جارٍ التطبيق...';
    });
    final ok = await widget.ctl.apply(mask, '00');
    _set(() {
      applying = false;
      applyMsg = ok ? 'تم تطبيق $label وتأكّدت القراءة.' : 'ما تأكدت من التطبيق. افحص تبويب ROUTER.';
    });
    await _refresh();
  }

  // ---------- أساسي وثانوي ----------
  Future<void> _loadRoles() async {
    try {
      final s = await _store.read(key: 'band_roles');
      if (s == null) return;
      final m = jsonDecode(s) as Map<String, dynamic>;
      _set(() {
        roles.clear();
        m.forEach((k, v) {
          final b = int.tryParse(k);
          if (b != null && v is int && (v == 1 || v == 2)) roles[b] = v;
        });
      });
    } catch (_) {}
  }

  Future<void> _saveRoles() async {
    try {
      await _store.write(
          key: 'band_roles', value: jsonEncode(<String, int>{for (final e in roles.entries) '${e.key}': e.value}));
    } catch (_) {}
  }

  void _cycle(int b) {
    if (running || applying) return;
    setState(() {
      final v = roles[b] ?? 0;
      if (v == 0) {
        roles[b] = 1;
      } else if (v == 1) {
        roles[b] = 2;
      } else {
        roles.remove(b);
      }
    });
    _saveRoles();
  }

  Future<bool> _waitNet2() async {
    for (var i = 0; i < 20; i++) {
      if (await netDiag() == 'OK') return true;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return false;
  }

  Future<void> _applyRoles() async {
    if (running || applying) return;
    final pri = roles.entries.where((e) => e.value == 1).map((e) => e.key).toList()..sort();
    final sec = roles.entries.where((e) => e.value == 2).map((e) => e.key).toList()..sort();
    if (pri.isEmpty) {
      _set(() => roleMsg = 'اختر نطاقًا أساسيًا واحدًا على الأقل.');
      return;
    }
    final ctl = widget.ctl;
    final names = (List<int> l) => l.map((b) => 'B$b').join(' ');
    final lines = <String>[];
    for (final b in <int>[...pri, ...sec]) {
      final hit = gQuick.where((p) => p.band == b).toList();
      if (hit.isNotEmpty && !hit.first.res.ok) lines.add('تنبيه: B$b ما اشتغل في الاختبار القصير.');
    }
    _set(() {
      applying = true;
      roleMsg = 'تطبيق الأساسي: ${names(pri)} ...';
    });
    try {
      final ok1 = await ctl.apply(_maskOf(pri), '00');
      lines.add(ok1 ? 'تم تطبيق الأساسي: ${names(pri)}' : 'الراوتر لم يطبّق الأساسي.');
      if (ok1 && sec.isNotEmpty) {
        _set(() => roleMsg = 'انتظار الاتصال على الأساسي...');
        await _waitNet2();
        await Future<void>.delayed(const Duration(seconds: 5));
        _set(() => roleMsg = 'إضافة الثانوي: ${names(sec)} ...');
        final ok2 = await ctl.apply(_maskOf(<int>[...pri, ...sec]), '00');
        lines.add(ok2 ? 'تمت إضافة الثانوي: ${names(sec)}' : 'الراوتر لم يطبّق إضافة الثانوي.');
      }
      if (ok1) {
        _set(() => roleMsg = 'انتظار الاستقرار والتحقق...');
        await _waitNet2();
        await Future<void>.delayed(const Duration(seconds: 8));
        final f = ctl.snap;
        final m = f == null ? <String, String>{} : await f();
        final cur = int.tryParse(_g(m, <String>['band']));
        if (cur != null) {
          lines.add(pri.contains(cur)
              ? 'النطاق الأساسي الفعلي الآن: B$cur (من اختيارك).'
              : 'النطاق الأساسي الفعلي الآن: B$cur، وهو ليس من الأساسي اللي اخترته. الشبكة هي اللي تقرر الأساسي في النهاية.');
        }
        lines.add(sec.isEmpty
            ? 'ما اخترت ثانوي، فما فيه تجميع مطلوب.'
            : (_snapCa(m)
                ? 'تجميع النطاقات شغّال (+).'
                : 'التجميع غير ظاهر الآن. قد يحتاج وقتًا، أو الشبكة ما تدعم هذي التركيبة في موقعك.'));
      }
    } catch (e) {
      lines.add('خطأ: $e');
    }
    _set(() {
      applying = false;
      roleMsg = lines.join('\n');
    });
    await _refresh();
  }

  Widget _roleChip(int b) {
    final r = roles[b] ?? 0;
    final hit = gQuick.where((p) => p.band == b).toList();
    final mark = hit.isEmpty ? '' : (hit.first.res.ok ? ' ✓' : ' ✗');
    final bg = r == 1 ? _green : (r == 2 ? Colors.lightBlueAccent : Colors.transparent);
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _cycle(b),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: r == 0 ? Colors.white24 : bg),
        ),
        child: Text('B$b$mark${r == 1 ? ' · أساسي' : (r == 2 ? ' · ثانوي' : '')}',
            style: TextStyle(fontSize: 13, color: r == 0 ? Colors.white70 : Colors.black, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _rolesCard() => _card('نطاق أساسي وثانوي', [
        const Text(
            'اضغط على النطاق: مرة = أساسي (أخضر)، مرتين = ثانوي (أزرق)، ثالثة = إلغاء. يجوز أكثر من أساسي، والثانوي يدعم الأساسي بالتجميع.',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [for (final b in _bands) _roleChip(b)]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: FilledButton(
              onPressed: running || applying || roles.isEmpty ? null : _applyRoles,
              child: const Text('طبّق الأساسي والثانوي'),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: running || applying || roles.isEmpty
                ? null
                : () {
                    setState(roles.clear);
                    _saveRoles();
                  },
            child: const Text('مسح'),
          ),
        ]),
        if (roleMsg.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(roleMsg, style: const TextStyle(fontSize: 13)),
        ],
        const SizedBox(height: 8),
        const Text(
            'ملاحظة: الراوتر ما يسمح بتحديد النطاق الأساسي مباشرة. التطبيق يقفل الأساسي أولًا ثم يوسّع للثانوي ويتحقق من النتيجة، لكن الشبكة هي اللي تقرر في النهاية.',
            style: TextStyle(fontSize: 11, color: Colors.white38)),
      ]);

  // ---------- واجهة ----------
  Widget _card(String t, List<Widget> c, {Widget? trailing}) => Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold))),
              if (trailing != null) trailing,
            ]),
            const SizedBox(height: 8),
            ...c,
          ]),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(k, style: const TextStyle(color: Colors.white60, fontSize: 13))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
        ]),
      );

  Widget _caChip(bool ca) => Chip(
        visualDensity: VisualDensity.compact,
        avatar: Icon(ca ? Icons.add_circle : Icons.remove_circle_outline, size: 16, color: ca ? _green : Colors.white38),
        label: Text(ca ? 'تجميع نطاقات +' : 'بدون تجميع', style: TextStyle(fontSize: 12, color: ca ? _green : Colors.white54)),
      );

  int _neiCount() {
    final v = _g(snap, <String>['nei_cellid', 'neighbor_cellid']);
    if (v.isEmpty) return 0;
    return v.split(RegExp(r'[,;\s]+')).where((x) => x.isNotEmpty && x != '0' && x != '-').length;
  }

  String _towers() {
    final okp = gQuick.where((p) => p.res.ok).toList();
    final cells = <String>{};
    final enbs = <int>{};
    for (final p in okp) {
      final c = p.res.cell;
      if (c.isEmpty) continue;
      cells.add(c);
      final v = int.tryParse(c);
      if (v != null && v > 255) enbs.add(v >> 8);
    }
    if (okp.isEmpty) return 'شغّل الاختبار القصير';
    if (cells.isEmpty) return 'الراوتر ما يعرض رقم الخلية';
    final nei = _neiCount();
    final towers = enbs.isEmpty ? '' : '${enbs.length} برج · ';
    return '$towers${cells.length} خلية على النطاقات الشغّالة${nei > 0 ? ' · $nei خلية مجاورة ظاهرة' : ''}';
  }

  Widget _statusCard() {
    final ca = _snapCa(snap);
    final cell = _g(snap, <String>['cell_id']);
    final extra = <Widget>[];
    void add(String k, String v) {
      if (v.isNotEmpty) extra.add(_kv(k, v));
    }

    add('الشبكة', _netType(snap['st_CurrentNetworkTypeEx'] ?? ''));
    final band = _g(snap, <String>['band']);
    add('النطاق', band.isEmpty ? '' : 'B$band');
    add('الخلية', cell.isEmpty ? '' : _cellTxt(cell));
    add('PCI', _g(snap, <String>['pci']));
    add('التردد (EARFCN)', _g(snap, <String>['earfcn', 'dlearfcn', 'ltedlfreq']));
    add('عرض النطاق', _g(snap, <String>['dlbandwidth']));
    add('RSRP', _g(snap, <String>['rsrp']));
    add('SINR', _g(snap, <String>['sinr']));
    add('RSRQ', _g(snap, <String>['rsrq']));
    final nei = _g(snap, <String>['nei_cellid', 'neighbor_cellid']);
    add('خلايا مجاورة', nei);
    return _card('حالة الراوتر الآن', [
      if (snap.isEmpty) const Text('ما قدرت أقرأ حالة الراوتر.', style: TextStyle(color: Colors.white54)),
      ...extra,
      const SizedBox(height: 4),
      _kv('الأبراج', _towers()),
      const Text(
          'الراوتر يكشف الخلية المتصل بها فقط. عدد الأبراج هنا هو الأبراج اللي سجّل عليها أثناء الاختبار القصير، مو كل الأبراج اللي حولك.',
          style: TextStyle(fontSize: 11, color: Colors.white38)),
    ], trailing: Row(mainAxisSize: MainAxisSize.min, children: [
      if (snap.isNotEmpty) _caChip(ca),
      IconButton(onPressed: loading || running ? null : _refresh, icon: const Icon(Icons.refresh)),
    ]));
  }

  Widget _hostsCard() {
    final wifiN = int.tryParse(snap['st_CurrentWifiUser'] ?? '');
    return _card('الأجهزة المتصلة (${hosts.length}${wifiN != null ? ' · واي فاي $wifiN' : ''})', [
      if (hosts.isEmpty) const Text('ما رجعت قائمة أجهزة من الراوتر.', style: TextStyle(color: Colors.white54)),
      for (final h in hosts)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            Icon(h['_t'] == 'wifi' ? Icons.wifi : Icons.cable, size: 18, color: Colors.white54),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${_g(h, <String>['HostName', 'ActualName']).isEmpty ? 'بدون اسم' : _g(h, <String>['HostName', 'ActualName'])}'
                '  ·  ${_g(h, <String>['IpAddress'])}',
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ]),
        ),
    ]);
  }

  Widget _quickCard() {
    final list = [...gQuick]..sort((a, b) => a.band.compareTo(b.band));
    final okN = list.where((p) => p.res.ok).length;
    final sup = widget.ctl.sup;
    return _card('الاختبار القصير', [
      if (list.isEmpty)
        const Text('لسا ما شغّلته. يفحص كل النطاقات سريعًا ويعرف أيها يشتغل.', style: TextStyle(color: Colors.white54))
      else ...[
        Text('شغّال $okN من ${list.length} نطاق تم فحصه', style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        for (final p in list)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(p.res.ok ? Icons.check_circle : Icons.cancel, size: 18, color: p.res.ok ? _green : Colors.redAccent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  p.res.ok
                      ? 'B${p.band}${sup.contains(p.band) ? '' : ' (خارج قائمة الراوتر)'} · RSRP ${_f(p.res.rsrp)} · SINR ${_f(p.res.sinr)}'
                          '${p.res.cell.isEmpty ? '' : ' · ${_cellTxt(p.res.cell)}'}${p.res.ca ? ' · +' : ''}'
                      : 'B${p.band}${sup.contains(p.band) ? '' : ' (خارج قائمة الراوتر)'} · ${p.res.note}',
                  style: TextStyle(fontSize: 13, color: p.res.ok ? null : Colors.white54),
                ),
              ),
            ]),
          ),
      ],
      const SizedBox(height: 10),
      FilledButton(
        onPressed: running || applying ? null : _quickTest,
        child: const Text('اختبار قصير للنطاقات'),
      ),
    ]);
  }

  Widget _deepCard() {
    final sorted = [...rows];
    return _card('الفحص الشامل', [
      if (rows.isEmpty)
        const Text('يقيس كل نطاق شغّال: بنق، تذبذب، فقد، سرعة تنزيل، ثم كل الشغّالة معًا لمعرفة فائدة التجميع.',
            style: TextStyle(color: Colors.white54)),
      for (final c in sorted)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(c.label, style: const TextStyle(fontWeight: FontWeight.bold)),
              if (c.ca) const Text('  +', style: TextStyle(color: _green, fontWeight: FontWeight.bold)),
              if (c.mbps != null) Text('   ${c.mbps!.toStringAsFixed(1)} Mbps', style: const TextStyle(color: Colors.lightBlueAccent)),
            ]),
            Text(
              c.t == null
                  ? (c.note.isEmpty ? '...' : c.note)
                  : 'بنق ${_f(c.t!.p50)} ms · ذروة ${_f(c.t!.p95)} · تذبذب ${_f(c.t!.jitter)} · فقد ${c.t!.lossPct.toStringAsFixed(1)}%'
                      '${c.score == null ? '' : ' · نتيجة ${_f(c.score)}'}${c.note.isEmpty ? '' : ' · ${c.note}'}',
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ]),
        ),
      const SizedBox(height: 4),
      FilledButton.tonal(
        onPressed: running || applying ? null : _deepTest,
        child: const Text('فحص شامل لكل نطاق شغّال'),
      ),
      if (bestPingMask.isNotEmpty) ...[
        const SizedBox(height: 8),
        FilledButton(
          onPressed: running || applying ? null : () => _apply(bestPingMask, bestPingLabel),
          child: Text('طبّق الأفضل بنقًا: $bestPingLabel'),
        ),
      ],
      if (bestSpeedMask.isNotEmpty && bestSpeedMask != bestPingMask) ...[
        const SizedBox(height: 8),
        FilledButton(
          onPressed: running || applying ? null : () => _apply(bestSpeedMask, bestSpeedLabel),
          child: Text('طبّق الأفضل سرعة: $bestSpeedLabel'),
        ),
      ],
      if (applyMsg.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(applyMsg, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !running && !applying,
        child: Scaffold(
          appBar: AppBar(title: const Text('الشبكة والنطاقات')),
          body: ListView(padding: const EdgeInsets.all(12), children: [
            if (running)
              _card('التقدم', [
                const LinearProgressIndicator(),
                const SizedBox(height: 6),
                Text(step),
                const SizedBox(height: 6),
                for (final l in logs) Text(l, style: const TextStyle(fontSize: 12, color: Colors.white60)),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: cancel ? null : () => setState(() => cancel = true),
                  child: Text(cancel ? 'جارٍ الإيقاف...' : 'إيقاف'),
                ),
              ]),
            _statusCard(),
            _hostsCard(),
            _quickCard(),
            _rolesCard(),
            _deepCard(),
          ]),
        ),
      );
}
