import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'game.dart';
import 'measure.dart';
import 'netcheck.dart';
import 'probe.dart';
import 'wifi.dart';

const Color _green = Color(0xFF39D353);

/// أهداف القياس. ببجي ما له عناوين بنق رسمية معلنة، فهذه تقريب لمسار الخليج وأوروبا.
const List<GameTarget> kPubgTargets = <GameTarget>[
  GameTarget('كلاود فلير (1.1.1.1)', '1.1.1.1'),
  GameTarget('AWS البحرين', 'dynamodb.me-south-1.amazonaws.com'),
  GameTarget('AWS الإمارات', 'dynamodb.me-central-1.amazonaws.com'),
  GameTarget('AWS فرانكفورت', 'dynamodb.eu-central-1.amazonaws.com'),
];

enum St { idle, running, good, warn, bad }

class TDef {
  final String id, title, sub;
  final IconData icon;
  final bool disruptive;
  const TDef(this.id, this.title, this.sub, this.icon, {this.disruptive = false});
}

const List<TDef> kTests = <TDef>[
  TDef('link', 'إشارة الواي فاي', 'القوة والنطاق والقناة والسرعة', Icons.wifi),
  TDef('chan', 'ازدحام القنوات', 'الشبكات المجاورة وأفضل قناة', Icons.stacked_bar_chart),
  TDef('router', 'الجوال ← الراوتر', 'بنق وتذبذب وفقد على الواي فاي', Icons.router),
  TDef('net', 'الإنترنت والسيرفرات', 'DNS وبنق للمنطقة', Icons.public),
  TDef('stable', 'الثبات (45 ث)', 'تقطعات وقفزات البنق', Icons.show_chart),
  TDef('load', 'تحت الحمل', 'تنزيل ورفع أثناء اللعب', Icons.swap_vert),
  TDef('bands', 'نطاقات الراوتر', 'أفضل نطاق خلوي (يقطع الإنترنت)', Icons.cell_tower, disruptive: true),
];

class TRes {
  St st = St.idle;
  String head = '';
  final List<String> lines = <String>[];
}

String _f(double? v) => v == null ? '-' : v.toStringAsFixed(0);

String _ps(PingStats s) =>
    'متوسط ${_f(s.p50)} ms · ذروة ${_f(s.p95)} · تذبذب ${_f(s.jitter)} · فقد ${s.lossPct.toStringAsFixed(1)}%';

St _worst(St a, St b) => a.index > b.index ? a : b;

bool _ov(Ap a, int c, bool b24) {
  if ((a.freq < 3000) != b24) return false;
  final ac = a.channel;
  return b24 ? (ac - c).abs() < 5 : ac == c;
}

double? _bscore(PingStats st, double rp) {
  if (st.ok.length < 5) return null;
  if (st.lost * 10 > st.sent) return null;
  final p50 = st.p50 ?? 0.0;
  final p95 = st.p95 ?? 0.0;
  final lat = max(1.0, p50 - rp);
  return lat + (p95 - p50) + 2.0 * st.jitter + 12.0 * st.lost;
}

class _BC {
  final String mask, label;
  PingStats? t;
  double? score;
  _BC(this.mask, this.label);
}

class _Ld {
  final PingStats target, router;
  final List<int> rssi;
  final int bytes;
  _Ld(this.target, this.router, this.rssi, this.bytes);
}

class PubgPage extends StatefulWidget {
  final GameCtl ctl;
  const PubgPage({super.key, required this.ctl});
  @override
  State<PubgPage> createState() => _PubgState();
}

class _PubgState extends State<PubgPage> {
  final Map<String, bool> sel = <String, bool>{for (final t in kTests) t.id: !t.disruptive};
  final Map<String, TRes> res = <String, TRes>{for (final t in kTests) t.id: TRes()};
  bool running = false, cancel = false, applying = false;
  String step = '', summary = '', applyMsg = '';
  String bestMask = '', bestMode = '00', bestLabel = '';
  final List<String> logs = <String>[];
  Pinger? rp;
  final List<Pinger> tp = <Pinger>[];
  final List<String> tn = <String>[];
  double? _rp50;
  int _bi = -1;
  int _myFreq = 0;
  String _myBssid = '';
  bool _wifiLoadBad = false;

  bool stop() => cancel;

  void _set(void Function() f) {
    if (mounted) setState(f);
  }

  void log(String s) {
    _set(() {
      logs.add(s);
      if (logs.length > 30) logs.removeAt(0);
    });
  }

  void _fin(String id, St st, String head, List<String> lines) {
    _set(() {
      final r = res[id]!;
      r.st = st;
      r.head = head;
      r.lines
        ..clear()
        ..addAll(lines);
    });
  }

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

  // ---------- تشغيل ----------
  Future<void> _runList(List<String> ids) async {
    if (running || applying || ids.isEmpty) return;
    if (ids.contains('bands')) {
      final ok = await _confirm('فحص نطاقات الراوتر',
          'هذا الفحص يبدّل نطاقات الراوتر واحدًا واحدًا، والإنترنت ينقطع عن كل الأجهزة عدة دقائق (قد تصل إلى 20 دقيقة أو أكثر). '
          'في النهاية يرجع إعدادك الحالي، ولا يتغير شيء إلا إذا ضغطت «طبّق».');
      if (!ok) ids = ids.where((i) => i != 'bands').toList();
      if (ids.isEmpty) return;
    }
    _set(() {
      running = true;
      cancel = false;
      summary = '';
      applyMsg = '';
      bestMask = '';
      logs.clear();
      for (final id in ids) {
        res[id]!.st = St.idle;
        res[id]!.head = '';
        res[id]!.lines.clear();
      }
    });
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    try {
      await _runAll(ids);
    } catch (e) {
      log('خطأ غير متوقع: $e');
    }
    try {
      await WakelockPlus.disable();
    } catch (_) {}
    _set(() {
      for (final r in res.values) {
        if (r.st == St.running) r.st = St.idle;
      }
      running = false;
      step = cancel ? 'أُوقف الفحص' : 'انتهى الفحص';
      summary = _diagnose();
    });
  }

  Future<bool> _prep() async {
    await PingEngine.detect(widget.ctl.routerHost);
    final r = Pinger(widget.ctl.routerHost, tcpPort: 80);
    await r.resolve();
    rp = r;
    final s = await r.series(10, gapMs: 80, stop: stop);
    _rp50 = s.p50;
    tp.clear();
    tn.clear();
    for (final t in kPubgTargets) {
      final p = Pinger(t.host, tcpPort: t.port);
      if (await p.resolve()) {
        tp.add(p);
        tn.add(t.name);
      } else {
        log('تعذّر حل ${t.name}');
      }
    }
    return tp.isNotEmpty;
  }

  Future<void> _runAll(List<String> ids) async {
    _bi = -1;
    _wifiLoadBad = false;
    bool needsNet(String id) => id != 'link' && id != 'chan' && id != 'router';
    var net = true;
    if (ids.any(needsNet)) {
      net = await ensureInternet(widget.ctl, log, stop, () async => mounted && await askRepair(context));
    }
    _set(() => step = 'تجهيز');
    await _prep();
    for (final t in kTests) {
      if (!ids.contains(t.id) || cancel) continue;
      _set(() {
        step = t.title;
        res[t.id]!.st = St.running;
      });
      if (needsNet(t.id) && (!net || tp.isEmpty)) {
        _fin(t.id, St.bad, 'لا يوجد إنترنت', <String>['ما أقدر أقيس بدون إنترنت.']);
        continue;
      }
      if (!Platform.isAndroid && (t.id == 'link' || t.id == 'chan')) {
        _fin(t.id, St.warn, 'متاح على الجوال فقط', <String>['قياس إشارة الواي فاي والقنوات يحتاج أندرويد.']);
        continue;
      }
      try {
        switch (t.id) {
          case 'link':
            await _tLink();
            break;
          case 'chan':
            await _tChan();
            break;
          case 'router':
            await _tRouter();
            break;
          case 'net':
            await _tNet();
            break;
          case 'stable':
            await _tStable();
            break;
          case 'load':
            await _tLoad();
            break;
          case 'bands':
            await _tBands();
            break;
        }
      } catch (e) {
        _fin(t.id, St.bad, 'خطأ أثناء الفحص', <String>['$e']);
      }
    }
  }

  Future<int> _pickTarget() async {
    if (_bi >= 0) return _bi;
    final gulf = <int>[for (var i = 0; i < tp.length; i++) if (tn[i].startsWith('AWS')) i];
    final pool = gulf.isNotEmpty ? gulf : <int>[for (var i = 0; i < tp.length; i++) i];
    double? bp;
    for (final i in pool) {
      if (cancel) break;
      final s = await tp[i].series(8, gapMs: 100, stop: stop);
      final p = s.p50;
      if (p != null && s.lost <= 2 && (bp == null || p < bp)) {
        bp = p;
        _bi = i;
      }
    }
    return _bi;
  }

  Future<bool> _waitNet(Pinger p, {int maxSec = 60}) async {
    final end = DateTime.now().add(Duration(seconds: maxSec));
    while (DateTime.now().isBefore(end) && !cancel) {
      final v = await p.once();
      if (v != null) return true;
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return false;
  }

  // ---------- 1) إشارة الواي فاي ----------
  Future<void> _tLink() async {
    await wifiPerm();
    final rs = <int>[];
    WifiLink? last;
    for (var i = 0; i < 24 && !cancel; i++) {
      final w = await wifiLink();
      if (w != null && w.rssi < 0 && w.rssi > -127) {
        rs.add(w.rssi);
        last = w;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    final l = last;
    if (l == null || rs.isEmpty) {
      _fin('link', St.bad, 'ما قدرت أقرأ الواي فاي', <String>['تأكد أن الجوال متصل بالواي فاي (مو بيانات الجوال).']);
      return;
    }
    _myFreq = l.freq;
    _myBssid = l.bssid;
    final avg = rs.reduce((a, b) => a + b) / rs.length;
    final mn = rs.reduce((a, b) => a < b ? a : b);
    final mx = rs.reduce((a, b) => a > b ? a : b);
    var st = St.good;
    final lines = <String>[];
    final name = l.ssid.replaceAll('"', '');
    if (name.isNotEmpty && !name.contains('unknown')) lines.add('الشبكة: $name');
    lines.add('القوة: متوسط ${avg.round()} dBm (أضعف $mn · أقوى $mx)');
    if (avg < -70) {
      st = _worst(st, St.bad);
      lines.add('الإشارة ضعيفة. قرّب من الراوتر أو قلّل الحواجز.');
    } else if (avg < -60) {
      st = _worst(st, St.warn);
      lines.add('الإشارة متوسطة. الأفضل أقوى من -60 للألعاب.');
    }
    if (mx - mn > 12) {
      st = _worst(st, St.warn);
      lines.add('الإشارة تتذبذب بين القياسات، وهذا يسبب قفزات بنق.');
    }
    lines.add('النطاق: ${l.bandName} · القناة ${l.channel}${l.stdName.isEmpty ? '' : ' · ${l.stdName}'}');
    if (l.freq > 0 && l.freq < 3000) {
      st = _worst(st, St.warn);
      lines.add('2.4GHz مزدحم وعرضة للتشويش. لببجي الأفضل 5GHz إذا راوترك يدعمه وأنت قريب منه.');
    }
    if (l.speed > 0) {
      final extra = (l.tx > 0 && l.rx > 0) ? ' (إرسال ${l.tx} · استقبال ${l.rx})' : '';
      lines.add('سرعة الرابط: ${l.speed} Mbps$extra');
      if (l.speed < 72) {
        st = _worst(st, St.warn);
        lines.add('سرعة الرابط منخفضة، غالبًا بسبب ضعف الإشارة أو التشويش.');
      }
    }
    _fin('link', st, '${l.bandName} · قناة ${l.channel} · ${avg.round()} dBm', lines);
  }

  // ---------- 2) ازدحام القنوات ----------
  Future<void> _tChan() async {
    var granted = await wifiPerm();
    for (var i = 0; i < 8 && !granted && !cancel; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      granted = await wifiPerm(ask: false);
    }
    final link = await wifiLink();
    final myF = (link != null && link.freq > 0) ? link.freq : _myFreq;
    final myB = (link != null && link.bssid.isNotEmpty) ? link.bssid : _myBssid;
    _set(() => step = 'مسح الشبكات المجاورة...');
    final scan = await wifiScan();
    if (scan.isEmpty) {
      _fin('chan', St.warn, 'ما رجعت أي شبكات', <String>[
        'فعّل الموقع (GPS) من إعدادات الجوال وامنح التطبيق إذن الموقع، ثم أعد الفحص.',
        'أندرويد يحدّ عدد مرات المسح (حوالي 4 كل دقيقتين).',
      ]);
      return;
    }
    if (myF == 0) {
      _fin('chan', St.warn, 'ما عرفت قناتك', <String>['شغّل فحص «إشارة الواي فاي» أولًا، وتأكد أنك متصل بالواي فاي.']);
      return;
    }
    final is24 = myF < 3000;
    final myC = channelOf(myF);
    final others = scan.where((a) => a.bssid.toLowerCase() != myB.toLowerCase()).toList();
    final near = others.where((a) => _ov(a, myC, is24) && a.level > -80).toList();
    final strong = near.where((a) => a.level > -70).length;
    final cands = is24 ? <int>[1, 6, 11] : <int>[36, 40, 44, 48, 149, 153, 157, 161, 165];
    final scores = <int, int>{};
    for (final c in cands) {
      var s = 0;
      for (final a in others) {
        if (_ov(a, c, is24)) s += max(0, a.level + 100);
      }
      scores[c] = s;
    }
    final order = scores.keys.toList()..sort((a, b) => scores[a]!.compareTo(scores[b]!));
    final top = order.take(3).toList();
    var st = St.good;
    if (strong >= 3 || near.length >= 6) {
      st = St.bad;
    } else if (strong >= 1 || near.length >= 3) {
      st = St.warn;
    }
    final lines = <String>[
      'قناتك: $myC على ${bandNameOf(myF)}',
      '${others.length} شبكة مجاورة ظاهرة، منها ${near.length} على نفس القناة أو المتداخلة (${strong} قوية).',
      'الأقل ازدحامًا: ${top.join('، ')}',
    ];
    if (is24 && !<int>[1, 6, 11].contains(myC)) {
      st = _worst(st, St.warn);
      lines.add('قناتك تتداخل مع غيرها. على 2.4GHz استخدم 1 أو 6 أو 11 فقط.');
    }
    if (!is24) lines.add('القنوات 52 إلى 140 قد تنقطع عند رصد رادار (DFS)، فضّل 36-48 أو 149-165.');
    if (st != St.good && !top.contains(myC)) {
      lines.add('غيّر القناة يدويًا من إعدادات الراوتر (Wi-Fi ← القناة) إلى ${top.first}.');
    }
    _fin('chan', st, 'قناة $myC · ${near.length} متداخلة', lines);
  }

  // ---------- 3) الجوال ← الراوتر ----------
  Future<void> _tRouter() async {
    final r = rp;
    if (r == null || r.addr == null) {
      _fin('router', St.bad, 'ما قدرت أصل للراوتر', <String>['تأكد أنك متصل بواي فاي الراوتر.']);
      return;
    }
    final s = await r.series(60, gapMs: 100, stop: stop);
    if (s.ok.length < 5) {
      _fin('router', St.bad, 'الراوتر ما يردّ على القياس', <String>['فقد ${s.lossPct.toStringAsFixed(0)}%. الواي فاي ضعيف جدًا أو منقطع.']);
      return;
    }
    _rp50 = s.p50;
    final p50 = s.p50 ?? 0.0;
    final p95 = s.p95 ?? 0.0;
    var st = St.good;
    if (p50 > 15 || p95 > 60 || s.lossPct > 2) {
      st = St.bad;
    } else if (p50 > 8 || p95 > 30 || s.lossPct > 0.5) {
      st = St.warn;
    }
    final lines = <String>[_ps(s)];
    lines.add(st == St.good
        ? 'الواي فاي سليم: الرابط بين جوالك والراوتر ثابت.'
        : 'الواي فاي نفسه فيه مشكلة. جرّب: تقرّب من الراوتر، 5GHz، قناة أقل ازدحامًا، أو إيقاف توفير الطاقة.');
    _fin('router', st, 'متوسط ${_f(s.p50)} ms · فقد ${s.lossPct.toStringAsFixed(1)}%', lines);
  }

  // ---------- 4) الإنترنت والسيرفرات ----------
  Future<void> _tNet() async {
    final lines = <String>[];
    var st = St.good;
    final dns = <int>[];
    for (final h in const <String>['example.com', 'wikipedia.org', 'amazon.com']) {
      final sw = Stopwatch()..start();
      try {
        await InternetAddress.lookup(h).timeout(const Duration(seconds: 5));
        dns.add(sw.elapsedMilliseconds);
      } catch (_) {}
    }
    if (dns.isEmpty) {
      st = St.bad;
      lines.add('DNS: فشل حل الأسماء.');
    } else {
      final d = dns.reduce((a, b) => a + b) / dns.length;
      lines.add('DNS: متوسط ${d.round()} ms');
      if (d > 250) {
        st = _worst(st, St.warn);
        lines.add('DNS بطيء. جرّب 1.1.1.1 أو 8.8.8.8 في DNS الخاص بالجوال.');
      }
    }
    double? gulfBest;
    double? anyBest;
    for (var i = 0; i < tp.length && !cancel; i++) {
      _set(() => step = 'بنق ${tn[i]}');
      final s = await tp[i].series(25, gapMs: 120, stop: stop);
      final p = s.p50;
      lines.add('${tn[i]}: ${s.ok.isEmpty ? 'لا ردّ' : _ps(s)}');
      if (s.lossPct > 5) st = _worst(st, St.bad);
      if (p != null) {
        if (anyBest == null || p < anyBest) anyBest = p;
        final gulf = tn[i].contains('البحرين') || tn[i].contains('الإمارات');
        if (gulf && (gulfBest == null || p < gulfBest)) gulfBest = p;
      }
    }
    final g = gulfBest ?? anyBest;
    if (g == null) {
      _fin('net', St.bad, 'لا ردّ من أي هدف', lines);
      return;
    }
    if (g > 110) {
      st = _worst(st, St.bad);
    } else if (g > 60) {
      st = _worst(st, St.warn);
    }
    final rp50 = _rp50;
    if (rp50 != null) lines.add('بعد طرح بنق الراوتر: حوالي ${(g - rp50).clamp(0.0, 9999.0).toStringAsFixed(0)} ms للمنطقة.');
    lines.add('ملاحظة: هذه أهداف تقريبية، ببجي ما يعلن عناوين بنق رسمية.');
    _fin('net', st, 'أفضل بنق للمنطقة ${_f(g)} ms', lines);
  }

  // ---------- 5) الثبات ----------
  Future<void> _tStable() async {
    final bi = await _pickTarget();
    if (bi < 0) {
      _fin('stable', St.bad, 'ما قدرت أقيس', <String>['الأهداف ما تردّ.']);
      return;
    }
    final p = tp[bi];
    final sw = Stopwatch()..start();
    final ok = <double>[];
    var sent = 0;
    var lastStep = -1;
    while (sw.elapsed < const Duration(seconds: 45) && !cancel) {
      sent++;
      final v = await p.once();
      if (v != null) ok.add(v);
      final sec = sw.elapsed.inSeconds ~/ 5;
      if (sec != lastStep) {
        lastStep = sec;
        _set(() => step = 'ثبات ${tn[bi]}: ${sw.elapsed.inSeconds}/45 ث');
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final s = PingStats(sent, ok);
    if (ok.length < 10) {
      _fin('stable', St.bad, 'اتصال غير ثابت', <String>['فقد ${s.lossPct.toStringAsFixed(0)}% من القياسات.']);
      return;
    }
    final base = s.p50 ?? 0.0;
    final spikes = ok.where((v) => v > base * 2 + 40).length;
    final perMin = spikes * 60.0 / max(1, sw.elapsed.inSeconds);
    final mx = ok.reduce((a, b) => a > b ? a : b);
    var st = St.good;
    if (s.lossPct > 2 || perMin >= 6 || (s.p95 ?? 0) - base > 100) {
      st = St.bad;
    } else if (s.lossPct > 0.5 || perMin >= 2 || (s.p95 ?? 0) - base > 40) {
      st = St.warn;
    }
    final lines = <String>[
      '${tn[bi]}: ${_ps(s)}',
      'أعلى قيمة: ${_f(mx)} ms · قفزات حادة: $spikes (${perMin.toStringAsFixed(1)} بالدقيقة)',
    ];
    if (st != St.good) {
      lines.add('لو الراوتر سليم في فحص «الجوال ← الراوتر»، فالقفزات من الشبكة الخلوية أو النطاق.');
    }
    _fin('stable', st, 'فقد ${s.lossPct.toStringAsFixed(1)}% · قفزات $spikes', lines);
  }

  // ---------- 6) تحت الحمل ----------
  Future<List<int>> _rssiLoop(int seconds) async {
    final out = <int>[];
    final end = DateTime.now().add(Duration(seconds: seconds));
    while (DateTime.now().isBefore(end) && !cancel) {
      final w = await wifiLink();
      if (w != null && w.rssi < 0 && w.rssi > -127) out.add(w.rssi);
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    return out;
  }

  Future<_Ld> _loaded(Pinger target, Pinger router, bool up) async {
    const secs = 8;
    final load = up ? loadUp(const Duration(seconds: secs), stop) : loadDown(const Duration(seconds: secs), stop);
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    final n = ((secs - 2) * 1000) ~/ 220;
    final fT = target.series(n, gapMs: 100, stop: stop);
    final fR = router.series(n, gapMs: 100, stop: stop);
    final fW = _rssiLoop(secs - 2);
    final t = await fT;
    final r = await fR;
    final w = await fW;
    final bytes = await load;
    return _Ld(t, r, w, bytes);
  }

  Future<void> _tLoad() async {
    final bi = await _pickTarget();
    final r = rp;
    if (bi < 0 || r == null) {
      _fin('load', St.bad, 'ما قدرت أقيس', <String>['الأهداف ما تردّ.']);
      return;
    }
    final target = tp[bi];
    final idleT = await target.series(15, gapMs: 100, stop: stop);
    final idleR = await r.series(15, gapMs: 100, stop: stop);
    final i50 = idleT.p50;
    final r50 = idleR.p50;
    if (i50 == null) {
      _fin('load', St.bad, 'تعذّر القياس', <String>['الهدف ما يردّ وقت الراحة.']);
      return;
    }
    var st = St.good;
    final lines = <String>[];
    for (final up in <bool>[false, true]) {
      if (cancel) break;
      final what = up ? 'تحت الرفع' : 'تحت التنزيل';
      _set(() => step = 'اختبار الحمل: $what');
      final d = await _loaded(target, r, up);
      if (d.bytes < 300000) {
        lines.add('$what: ما قدرت أولّد حملًا كافيًا لقياسه.');
        continue;
      }
      final t50 = d.target.p50;
      if (t50 == null || d.target.ok.length < 3) {
        st = _worst(st, St.bad);
        lines.add('$what: انقطع الاتصال تقريبًا أثناء الحمل (سيئ جدًا).');
        continue;
      }
      final inc = t50 - i50;
      final tag = inc <= 30 ? 'جيد' : (inc <= 100 ? 'متوسط' : 'سيئ');
      st = _worst(st, inc <= 30 ? St.good : (inc <= 100 ? St.warn : St.bad));
      var line = '$what: ارتفع بنق السيرفر ${inc >= 0 ? '+' : ''}${inc.toStringAsFixed(0)} ms ($tag)';
      final rr = d.router.p50;
      if (rr != null && r50 != null) {
        final rinc = rr - r50;
        line += '، وبنق الراوتر ${rinc >= 0 ? '+' : ''}${rinc.toStringAsFixed(0)} ms';
        if (rinc > 25) {
          _wifiLoadBad = true;
          st = _worst(st, St.warn);
        }
      }
      lines.add(line);
      if (d.rssi.isNotEmpty) {
        lines.add('أضعف إشارة أثناء الحمل: ${d.rssi.reduce((a, b) => a < b ? a : b)} dBm');
      }
    }
    if (_wifiLoadBad) {
      lines.add('بنق الراوتر نفسه يرتفع تحت الحمل: الواي فاي أو الراوتر يتشبّع، مو بس الإنترنت.');
    } else if (st != St.good) {
      lines.add('الراوتر يتحمل، والتأخير من خط الإنترنت. العلاج QoS أو تحديد السرعة وهذا غير متاح في هذا الراوتر.');
    }
    _fin('load', st, st == St.good ? 'يتحمل الضغط' : 'يتأثر بالضغط', lines);
  }

  // ---------- 7) نطاقات الراوتر ----------
  Future<void> _tBands() async {
    final ctl = widget.ctl;
    final baseMask = ctl.curMask();
    final baseMode = ctl.curMode();
    final r = rp;
    if (baseMask.isEmpty || ctl.sup.isEmpty || r == null) {
      _fin('bands', St.bad, 'ما قدرت أقرأ نطاقات الراوتر', <String>['ارجع وادخل من جديد.']);
      return;
    }
    final bi = await _pickTarget();
    if (bi < 0) {
      _fin('bands', St.bad, 'ما قدرت أقيس', <String>['الأهداف ما تردّ.']);
      return;
    }
    final target = tp[bi];
    _set(() => step = 'قياس الإعداد الحالي');
    final baseSt = await target.series(40, gapMs: 120, stop: stop);
    final baseR = await r.series(15, gapMs: 100, stop: stop);
    final rp0 = baseR.p50 ?? 0.0;
    final baseScore = _bscore(baseSt, rp0);
    final pr = await probeAll(
      bands: ctl.sup,
      probe: ctl.probe,
      stop: stop,
      log: log,
      step: (s) => _set(() => step = s),
      tick: () {},
    );
    final work = workingBands(pr, max: 5);
    final okN = pr.where((p) => p.res.ok).length;
    final lines = <String>['شغّال $okN من ${pr.length} نطاق تم فحصه (المدعوم ${ctl.sup.length}).'];
    final cands = <_BC>[];
    var touched = pr.isNotEmpty;
    var curMask = '';
    for (var i = 0; i < work.length && !cancel; i++) {
      final b = work[i];
      final c = _BC(maskOne(b), 'تلقائي · B$b');
      _set(() => step = 'قياس ${c.label} (${i + 1}/${work.length})');
      touched = true;
      final applied = await ctl.apply(c.mask, '00');
      if (!applied) {
        lines.add('${c.label}: الراوتر لم يطبّقه');
        continue;
      }
      curMask = c.mask;
      if (!await _waitNet(target)) {
        lines.add('${c.label}: ما رجع الإنترنت');
        continue;
      }
      await Future<void>.delayed(const Duration(seconds: 8));
      final s = await target.series(40, gapMs: 120, stop: stop);
      final rr = await r.series(15, gapMs: 100, stop: stop);
      c.t = s;
      c.score = _bscore(s, rr.p50 ?? rp0);
      cands.add(c);
    }
    if (touched) {
      _set(() => step = 'رجوع للإعداد الحالي');
      final back = await ctl.apply(baseMask, baseMode);
      if (!back) lines.add('تنبيه: ما تأكدت من الرجوع للإعداد الأول. افحص تبويب ROUTER.');
      await _waitNet(target);
    }
    final valid = cands.where((c) => c.score != null).toList()..sort((a, b) => a.score!.compareTo(b.score!));
    lines.add('الحالي: ${baseScore == null ? 'ما قدرت أقيسه' : 'نتيجة ${_f(baseScore)} (${_ps(baseSt)})'}');
    for (final c in valid) {
      lines.add('${c.label}: نتيجة ${_f(c.score)} · ${_ps(c.t!)}');
    }
    var st = St.good;
    var head = 'لا يوجد أفضل من الحالي';
    if (valid.isEmpty) {
      st = St.warn;
      head = 'ما لقيت نطاقًا قابلًا للقياس';
    } else if (baseScore == null) {
      st = St.warn;
      head = 'الأفضل ${valid.first.label}';
      _set(() {
        bestMask = valid.first.mask;
        bestMode = '00';
        bestLabel = valid.first.label;
      });
    } else {
      final top = valid.first;
      final gain = baseScore - top.score!;
      final pct = baseScore > 0 ? gain / baseScore * 100 : 0.0;
      if (gain >= 5 && pct >= 15) {
        st = St.warn;
        head = 'الأفضل ${top.label} (تحسن ${pct.toStringAsFixed(0)}%)';
        _set(() {
          bestMask = top.mask;
          bestMode = '00';
          bestLabel = top.label;
        });
      } else {
        lines.add('إعدادك الحالي كافٍ، ما فيه بديل يتفوق بفارق واضح.');
      }
    }
    _fin('bands', st, head, lines);
  }

  Future<void> _applyBest() async {
    if (bestMask.isEmpty || running || applying) return;
    _set(() {
      applying = true;
      applyMsg = 'جارٍ التطبيق...';
    });
    final ok = await widget.ctl.apply(bestMask, bestMode);
    _set(() {
      applying = false;
      applyMsg = ok ? 'تم تطبيق $bestLabel وتأكّدت القراءة.' : 'ما تأكدت من التطبيق. افحص تبويب ROUTER.';
    });
  }

  // ---------- الخلاصة ----------
  String _diagnose() {
    St g(String id) => res[id]!.st;
    bool ran(String id) => g(id) == St.good || g(id) == St.warn || g(id) == St.bad;
    final ranIds = kTests.where((t) => ran(t.id)).map((t) => t.id).toList();
    if (ranIds.isEmpty) return '';
    final out = <String>[];
    if ((ran('link') && g('link') == St.bad) || (ran('router') && g('router') == St.bad)) {
      out.add('الحلقة الضعيفة: الواي فاي بين جوالك والراوتر (إشارة أو تشويش). عالجه قبل أي شيء.');
    }
    if (ran('chan') && g('chan') == St.bad) {
      out.add('قناة الواي فاي مزدحمة جدًا. غيّرها من إعدادات الراوتر.');
    }
    if (_wifiLoadBad) {
      out.add('الراوتر أو الواي فاي يتشبّع تحت الضغط، فيرتفع البنق لما أحد يحمّل.');
    }
    if (ran('net') && g('net') == St.bad) {
      out.add('الإنترنت نفسه بطيء أو بعيد عن المنطقة. جرّب نطاقًا آخر (فحص النطاقات) أو وقتًا ثانيًا.');
    }
    if (ran('stable') && g('stable') != St.good) {
      out.add('فيه تقطعات أو قفزات بنق أثناء الثبات.');
    }
    if (out.isEmpty) {
      final anyWarn = ranIds.any((i) => g(i) == St.warn);
      out.add(anyWarn
          ? 'ما فيه مشكلة كبيرة، لكن فيه ملاحظات في الفحوصات المعلّمة بالبرتقالي.'
          : 'كل الفحوصات اللي شغّلتها سليمة. لو ببجي ما زال لاق، فالمشكلة غالبًا من سيرفر اللعبة أو مسار الشركة.');
    }
    if (ranIds.length < kTests.length) out.add('فحوصات ما شغّلتها: ما دخلت في هذه الخلاصة.');
    return out.join('\n');
  }

  // ---------- واجهة ----------
  Color _col(St s) {
    switch (s) {
      case St.good:
        return _green;
      case St.warn:
        return Colors.orange;
      case St.bad:
        return Colors.redAccent;
      default:
        return Colors.white24;
    }
  }

  Widget _stIcon(St s) {
    switch (s) {
      case St.running:
        return const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2));
      case St.good:
        return const Icon(Icons.check_circle, color: _green, size: 20);
      case St.warn:
        return const Icon(Icons.warning_amber, color: Colors.orange, size: 20);
      case St.bad:
        return const Icon(Icons.cancel, color: Colors.redAccent, size: 20);
      default:
        return const SizedBox(width: 20, height: 20);
    }
  }

  Widget _tile(TDef t, double w) {
    final r = res[t.id]!;
    final on = sel[t.id] ?? false;
    return SizedBox(
      width: w,
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: _col(r.st), width: r.st == St.idle ? 1 : 2),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: running ? null : () => setState(() => sel[t.id] = !on),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                SizedBox(
                  width: 28,
                  height: 28,
                  child: Checkbox(
                    value: on,
                    visualDensity: VisualDensity.compact,
                    onChanged: running ? null : (v) => setState(() => sel[t.id] = v ?? false),
                  ),
                ),
                const Spacer(),
                _stIcon(r.st),
              ]),
              const SizedBox(height: 4),
              Icon(t.icon, size: 28, color: t.disruptive ? Colors.orangeAccent : Colors.white70),
              const SizedBox(height: 6),
              Text(t.title, style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(t.sub, style: const TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton.tonal(
                  onPressed: running || applying ? null : () => _runList(<String>[t.id]),
                  child: const Text('افحص'),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final w = (MediaQuery.of(context).size.width - 24 - 8) / 2;
    final selected = <String>[for (final t in kTests) if (sel[t.id] ?? false) t.id];
    final shown = kTests.where((t) => res[t.id]!.st != St.idle && res[t.id]!.st != St.running).toList();
    return PopScope(
      canPop: !running && !applying,
      child: Scaffold(
        appBar: AppBar(title: const Text('وضع ببجي (واي فاي)')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          _card('فحص ببجي عبر الواي فاي', [
            const Text(
                'حدّد الفحوصات اللي تبيها وافحص كل واحد لحاله، أو شغّل الكل مرة وحدة. كل فحص يعطيك لون: أخضر سليم، برتقالي ملاحظة، أحمر مشكلة. '
                'ما أقدر أقيس UDP الخاص بببجي مباشرة، فالبنق هنا لسيرفرات قريبة تقريبية.',
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton(
                onPressed: running || applying || selected.isEmpty ? null : () => _runList(selected),
                child: Text('فحص المحدد (${selected.length})'),
              ),
              OutlinedButton(
                onPressed: running || applying
                    ? null
                    : () {
                        setState(() {
                          for (final t in kTests) {
                            sel[t.id] = true;
                          }
                        });
                        _runList(<String>[for (final t in kTests) t.id]);
                      },
                child: const Text('فحص الكل'),
              ),
              if (running)
                OutlinedButton(
                  onPressed: cancel ? null : () => setState(() => cancel = true),
                  child: Text(cancel ? 'جارٍ الإيقاف...' : 'إيقاف'),
                ),
            ]),
          ]),
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 8, children: [for (final t in kTests) _tile(t, w)]),
          if (running || logs.isNotEmpty)
            _card('التقدم', [
              if (running) const LinearProgressIndicator(),
              const SizedBox(height: 6),
              Text(step),
              const SizedBox(height: 6),
              for (final l in logs) Text(l, style: const TextStyle(fontSize: 12, color: Colors.white60)),
            ]),
          if (summary.isNotEmpty)
            _card('الخلاصة', [
              Text(summary),
              if (bestMask.isNotEmpty) ...[
                const SizedBox(height: 10),
                FilledButton(
                  onPressed: running || applying ? null : _applyBest,
                  child: Text('طبّق: $bestLabel'),
                ),
              ],
              if (applyMsg.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(applyMsg, style: const TextStyle(fontWeight: FontWeight.bold)),
              ],
            ]),
          for (final t in shown)
            _card(t.title, [
              Text(res[t.id]!.head, style: TextStyle(fontWeight: FontWeight.bold, color: _col(res[t.id]!.st))),
              const SizedBox(height: 6),
              for (final l in res[t.id]!.lines)
                Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(l, style: const TextStyle(fontSize: 13))),
            ]),
        ]),
      ),
    );
  }
}
