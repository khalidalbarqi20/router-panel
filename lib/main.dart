import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

const _st = FlutterSecureStorage();

class Resp {
  final String body;
  final HttpHeaders headers;
  Resp(this.body, this.headers);
}

class Huawei {
  final String host;
  final HttpClient _h = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final Map<String, String> _ck = {};
  String _tok = '';
  Huawei(this.host);

  Future<Resp> _req(String m, String p, {String? body}) async {
    final r = await _h.openUrl(m, Uri.parse('http://$host$p'));
    if (_ck.isNotEmpty) {
      r.headers.set('Cookie', _ck.entries.map((e) => '${e.key}=${e.value}').join('; '));
    }
    if (m == 'POST') {
      r.headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      if (_tok.isNotEmpty) r.headers.set('__RequestVerificationToken', _tok);
      r.add(utf8.encode(body ?? ''));
    }
    final s = await r.close();
    for (final c in s.headers[HttpHeaders.setCookieHeader] ?? <String>[]) {
      final kv = c.split(';').first;
      final i = kv.indexOf('=');
      if (i > 0) _ck[kv.substring(0, i).trim()] = kv.substring(i + 1);
    }
    return Resp(await utf8.decodeStream(s), s.headers);
  }

  static String tag(String x, String t) => RegExp('<$t>([^<]*)</$t>').firstMatch(x)?[1] ?? '';
  static Map<String, String> kv(String x) =>
      {for (final m in RegExp(r'<(\w+)>([^<]*)</\1>').allMatches(x)) m[1]!: m[2]!};
  static String? err(String x) => x.contains('<error>') ? tag(x, 'code') : null;

  List<int> _unhex(String s) =>
      [for (var i = 0; i + 1 < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];
  String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

  List<int> _pbkdf2(List<int> pw, List<int> salt, int iter) {
    final h = Hmac(sha256, pw);
    var u = h.convert([...salt, 0, 0, 0, 1]).bytes;
    final t = List<int>.from(u);
    for (var i = 1; i < iter; i++) {
      u = h.convert(u).bytes;
      for (var j = 0; j < 32; j++) {
        t[j] ^= u[j];
      }
    }
    return t;
  }

  String _proof(String cn, String sn, String pw, String saltHex, int iter) {
    final msg = '$cn,$sn,$sn';
    final salted = _pbkdf2(utf8.encode(pw), _unhex(saltHex), iter);
    final ck = Hmac(sha256, utf8.encode('Client Key')).convert(salted).bytes;
    final sk = sha256.convert(ck).bytes;
    final sig = Hmac(sha256, utf8.encode(msg)).convert(sk).bytes;
    return _hex([for (var i = 0; i < 32; i++) ck[i] ^ sig[i]]);
  }

  Future<void> login(String pw) async {
    _ck.clear();
    await _req('GET', '/');
    final t = tag((await _req('GET', '/api/webserver/token')).body, 'token');
    if (t.isEmpty) throw 'الراوتر لم يعطِ توكن الدخول (قد يكون فيرموير مختلف).';
    _tok = t.length > 32 ? t.substring(32) : t;
    final rnd = Random.secure();
    final cn = List.generate(64, (_) => rnd.nextInt(16).toRadixString(16)).join();
    final c = await _req('POST', '/api/user/challenge_login',
        body: '<?xml version="1.0" encoding="UTF-8"?><request><username>admin</username>'
            '<firstnonce>$cn</firstnonce><mode>1</mode></request>');
    final sn = tag(c.body, 'servernonce'), salt = tag(c.body, 'salt');
    final it = int.tryParse(tag(c.body, 'iterations'));
    if (sn.isEmpty || it == null) throw 'رد غير متوقع من الراوتر عند الدخول: ${c.body}';
    _tok = c.headers.value('__requestverificationtoken') ?? _tok;
    final f = await _req('POST', '/api/user/authentication_login',
        body: '<?xml version="1.0" encoding="UTF-8"?><request><clientproof>'
            '${_proof(cn, sn, pw, salt, it)}</clientproof><finalnonce>$sn</finalnonce></request>');
    if (err(f.body) != null) throw 'فشل الدخول (${err(f.body)}): تأكد من كلمة المرور، وقد يكون الدخول مقفولًا مؤقتًا.';
    _tok = f.headers.value('__requestverificationtokenone') ??
        f.headers.value('__requestverificationtoken') ?? _tok;
  }

  void _upd(HttpHeaders h) {
    final t = h.value('__requestverificationtokenone') ?? h.value('__requestverificationtoken');
    if (t != null && t.isNotEmpty) _tok = t;
  }

  Future<String> get(String p) async {
    final r = await _req('GET', '/api/$p');
    _upd(r.headers);
    return r.body;
  }

  Future<String> post(String p, String inner) async {
    final r = await _req('POST', '/api/$p',
        body: '<?xml version="1.0" encoding="UTF-8"?><request>$inner</request>');
    _upd(r.headers);
    return r.body;
  }
}

const ML = {'00': 'تلقائي (4G+5G)', '03': '4G فقط', '08': '5G فقط', '01': '2G فقط', '02': '3G فقط'};
const kBg = Color(0xFF2E2E2E), kHead = Color(0xFF1B1B1B), kBar = Color(0xFF6E6E6E), kGreen = Color(0xFF39D353);

List<int> bandsOf(String hex) {
  final m = int.tryParse(hex, radix: 16) ?? 0;
  return [for (var i = 0; i < 63; i++) if ((m >> i) & 1 == 1) i + 1];
}
String maskOf(Iterable<int> b) => b.fold<int>(0, (a, x) => a | (1 << (x - 1))).toRadixString(16);
String norm(String h) => h.toLowerCase().replaceFirst(RegExp('^0+'), '');
double? num_(String? s) {
  final m = RegExp(r'-?\d+(\.\d+)?').firstMatch(s ?? '');
  return m == null ? null : double.parse(m[0]!);
}
String fmt(double? v) => v == null ? '-' : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());
List<String> bsplit(double b) {
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  var i = 0;
  while (b >= 1024 && i < 4) {
    b /= 1024;
    i++;
  }
  return [b.toStringAsFixed(i < 2 ? 0 : 2), u[i]];
}
Color qc(double f) => f >= .66 ? kGreen : (f >= .33 ? Colors.orange : Colors.redAccent);

class _Ring extends CustomPainter {
  final double f;
  final Color c;
  _Ring(this.f, this.c);
  @override
  void paint(Canvas cv, Size s) {
    final r = Rect.fromLTWH(4, 4, s.width - 8, s.height - 8);
    final p = Paint()..style = PaintingStyle.stroke..strokeWidth = 6..strokeCap = StrokeCap.round;
    cv.drawArc(r, 0, 2 * pi, false, p..color = Colors.white24);
    cv.drawArc(r, -pi / 2, 2 * pi * f, false, p..color = c);
  }
  @override
  bool shouldRepaint(_Ring o) => o.f != f || o.c != c;
}

class Gauge extends StatelessWidget {
  final String label, val, unit;
  final double frac;
  final Color color;
  const Gauge(this.label, this.val, this.unit, this.frac, this.color, {super.key});
  @override
  Widget build(BuildContext c) => SizedBox(
      width: 84,
      height: 84,
      child: CustomPaint(
          painter: _Ring(frac.clamp(0.0, 1.0), color),
          child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(label, style: const TextStyle(fontSize: 10, color: Colors.white70)),
            Text(val, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: Colors.white)),
            Text(unit, style: const TextStyle(fontSize: 10, color: Colors.white70)),
          ]))));
}

class _Spark extends CustomPainter {
  final List<double> d;
  final Color c;
  _Spark(this.d, this.c);
  @override
  void paint(Canvas cv, Size s) {
    if (d.length < 2) return;
    final lo = d.reduce(min), hi = d.reduce(max);
    final rg = (hi - lo) == 0 ? 1.0 : (hi - lo);
    final path = Path();
    for (var i = 0; i < d.length; i++) {
      final x = s.width * i / (d.length - 1), y = s.height * (1 - (d[i] - lo) / rg);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    cv.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 2..color = c);
  }
  @override
  bool shouldRepaint(_Spark o) => true;
}

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'لوحة الراوتر',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            brightness: Brightness.dark,
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(seedColor: kGreen, brightness: Brightness.dark),
            scaffoldBackgroundColor: kBg),
        builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _H();
}

class _H extends State<Home> {
  final host = TextEditingController(text: '192.168.8.1'), pw = TextEditingController();
  Huawei? hw;
  String? _pw;
  Map<String, String> sig = {}, nm = {}, tr = {};
  Map<String, String>? orig;
  List<String> modes = [];
  List<int> sup = [];
  Set<int> sel = {};
  List<double> hR = [], hS = [];
  String nb = '3fffffff', msg = '', report = '', isp = '', model = 'ROUTER';
  bool busy = false, remember = true, _poll = false;
  int tab = 0;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final h = await _st.read(key: 'host');
      final p = await _st.read(key: 'pw');
      if (h != null) host.text = h;
      if (p != null) {
        pw.text = p;
        await doLogin();
      }
    } catch (_) {}
  }

  Future<void> run(Future<void> Function() f) async {
    setState(() {
      busy = true;
      msg = '';
    });
    try {
      await f();
    } catch (e) {
      msg = '$e';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<bool> confirm(String t) async =>
      await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(content: Text(t), actions: [
                TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
                FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('متأكد')),
              ])) ??
      false;

  Future<void> refresh({bool sync = false}) async {
    final s = await hw!.get('device/signal');
    final n = await hw!.get('net/net-mode');
    Map<String, String> t = tr;
    try {
      t = Huawei.kv(await hw!.get('monitoring/traffic-statistics'));
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      sig = Huawei.kv(s);
      nm = Huawei.kv(n);
      tr = t;
      final r = num_(sig['rsrp']), q = num_(sig['sinr']);
      if (r != null) hR.add(r);
      if (q != null) hS.add(q);
      if (hR.length > 120) hR.removeAt(0);
      if (hS.length > 120) hS.removeAt(0);
      if (sync || sel.isEmpty) sel = bandsOf(nm['LTEBand'] ?? '0').toSet();
    });
  }

  Future<void> doLogin() => run(() async {
        final h = Huawei(host.text.trim());
        await h.login(pw.text);
        _pw = pw.text;
        if (remember) {
          await _st.write(key: 'host', value: host.text.trim());
          await _st.write(key: 'pw', value: pw.text);
        } else {
          await _st.delete(key: 'pw');
        }
        pw.clear();
        final l = await h.get('net/net-mode-list');
        modes = RegExp(r'<Access>(\w+)</Access>').allMatches(l).map((m) => m[1]!).toList();
        sup = ({for (final m in RegExp(r'BC(\d+)').allMatches(l)) int.parse(m[1]!)}.toList())..sort();
        nb = RegExp(r'<BandList>.*?<Value>([^<]*)</Value>', dotAll: true).firstMatch(l)?[1] ?? '3fffffff';
        try {
          model = Huawei.tag(await h.get('device/basic_information'), 'devicename');
          isp = Huawei.tag(await h.get('net/current-plmn'), 'FullName');
        } catch (_) {}
        hw = h;
        await refresh(sync: true);
        final o = await _st.read(key: 'orig');
        if (o != null) {
          orig = Map<String, String>.from(jsonDecode(o));
        } else {
          orig = Map.of(nm);
          await _st.write(key: 'orig', value: jsonEncode(orig));
        }
        timer?.cancel();
        timer = Timer.periodic(const Duration(seconds: 3), (_) async {
          if (busy || _poll || hw == null) return;
          _poll = true;
          try {
            await refresh();
          } catch (_) {}
          _poll = false;
        });
      });

  Future<void> logout() async {
    timer?.cancel();
    await _st.delete(key: 'pw');
    setState(() {
      hw = null;
      msg = '';
    });
  }

  Future<void> change(String mask, String mode) => run(() async {
        final r = await hw!.post('net/net-mode',
            '<NetworkMode>$mode</NetworkMode><NetworkBand>$nb</NetworkBand><LTEBand>$mask</LTEBand>');
        final note = Huawei.err(r);
        await Future.delayed(const Duration(seconds: 20));
        for (var i = 0; i < 8; i++) {
          try {
            await hw!.login(_pw!);
            await refresh(sync: true);
            final ok = nm['NetworkMode'] == mode && norm(nm['LTEBand'] ?? '') == mask;
            msg = ok ? 'تم التطبيق وتأكّدت القراءة.' : 'الراوتر لم يطبّق التغيير (رد الراوتر: ${note ?? 'OK'}).';
            return;
          } catch (_) {
            await Future.delayed(const Duration(seconds: 8));
          }
        }
        msg = 'الراوتر لم يرجع بعد. انتظر دقيقة ثم أعد المحاولة.';
      });

  Future<void> pickMode(String m) async {
    if (!['00', '03'].contains(m) && !await confirm('هذا الوضع قد يقطع الإنترنت إذا لم تتوفر الشبكة. متأكد؟')) return;
    await change(norm(nm['LTEBand'] ?? ''), m);
  }

  Future<void> reconnect() async {
    if (!await confirm('إعادة اتصال الشبكة؟ قد ينقطع الإنترنت ثواني.')) return;
    await run(() async {
      final r = await hw!.post('net/reconnect', '<ReconnectAction>1</ReconnectAction>');
      msg = 'رد الراوتر على إعادة الاتصال: ${Huawei.err(r) ?? 'OK'}';
    });
  }

  Future<void> doReport() => run(() async {
        final b = StringBuffer();
        for (final p in ['device/basic_information', 'device/information', 'device/signal',
          'net/net-mode', 'net/net-mode-list', 'monitoring/status', 'wlan/basic-settings']) {
          try {
            b.writeln('## $p\n${await hw!.get(p)}\n');
          } catch (e) {
            b.writeln('## $p خطأ: $e\n');
          }
        }
        report = b.toString().replaceAllMapped(
            RegExp(r'<(\w*(?:imei|imsi|serial|mac|iccid|msisdn|phone|number|ssid)\w*)>[^<]+</',
                caseSensitive: false),
            (m) => '<${m[1]}>***</');
      });

  // ---------- واجهة ----------
  Widget sec(String t) => Container(
      width: double.infinity,
      color: kBar,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      margin: const EdgeInsets.only(top: 14, bottom: 10),
      child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)));

  Widget row(List<Widget> c) => Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: c);

  Widget info(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 14),
      child: Row(children: [
        SizedBox(width: 70, child: Text(k, style: const TextStyle(color: Colors.white54, fontWeight: FontWeight.bold))),
        Expanded(child: Text(v.isEmpty ? '-' : v, textDirection: TextDirection.ltr, textAlign: TextAlign.right)),
      ]));

  Widget sg(String label, String k, String unit, double lo, double hi) {
    final v = num_(sig[k]);
    final f = v == null ? 0.0 : ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
    return Gauge(label, fmt(v), unit, f, qc(f));
  }

  Widget tg(String label, String k, bool rate, Color c) {
    final b = bsplit(num_(tr[k]) ?? 0);
    return Gauge(label, b[0], rate ? '${b[1]}/s' : b[1], 0.0, c);
  }

  String hms(double s) {
    final t = s.toInt();
    return '${(t ~/ 3600).toString().padLeft(2, '0')}:${((t % 3600) ~/ 60).toString().padLeft(2, '0')}';
  }

  List<Widget> cellTab() {
    final has5 = (sig['nrrsrp'] ?? '').isNotEmpty && sig['nrrsrp'] != 'None';
    final band = sig['band'] ?? '';
    final f = (num_(sig['dlfrequency']) ?? 0) / 1000;
    return [
      info('CELL', sig['cell_id'] ?? ''),
      info('ISP', isp),
      info('BAND', band.isEmpty ? '' : 'B$band${f > 0 ? ' - ${f.toStringAsFixed(0)}MHz' : ''}'),
      info('eNBID', sig['enodeb_id'] ?? ''),
      info('WIDTH', 'D:${fmt(num_(sig['dlbandwidth']))} | U:${fmt(num_(sig['ulbandwidth']))}MHz'),
      info('F/TDD', nm['LTEBand'] ?? ''),
      sec('SIGNAL'),
      row([sg('RSSI', 'rssi', 'dBm', -110, -50), sg('RSRQ', 'rsrq', 'dB', -20, -3),
        sg('RSRP', 'rsrp', 'dBm', -125, -70), sg('SINR', 'sinr', 'dB', -5, 30)]),
      if (has5) ...[
        sec('5G NR'),
        row([sg('NR RSRP', 'nrrsrp', 'dBm', -125, -70), sg('NR RSRQ', 'nrrsrq', 'dB', -20, -3),
          sg('NR SINR', 'nrsinr', 'dB', -5, 30)]),
        info('NR FREQ', sig['nrdlfreq'] ?? ''),
      ],
      sec('DOWNLOAD  /  UPLOAD'),
      row([tg('DL/s', 'CurrentDownloadRate', true, kGreen), tg('DL', 'CurrentDownload', false, kGreen),
        tg('UL/s', 'CurrentUploadRate', true, Colors.orange), tg('UL', 'CurrentUpload', false, Colors.orange)]),
      sec('ALL  /  TIME'),
      row([tg('DL', 'TotalDownload', false, kGreen), tg('UL', 'TotalUpload', false, Colors.orange),
        Gauge('CUR', hms(num_(tr['CurrentConnectTime']) ?? 0), 'hh:mm', 0, kGreen),
        Gauge('ALL', fmt(((num_(tr['TotalConnectTime']) ?? 0) / 86400).floorToDouble()), 'days', 0, kGreen)]),
      const SizedBox(height: 20),
    ];
  }

  Widget card(String t, List<Widget> c) => Card(
      margin: const EdgeInsets.all(10),
      child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            ...c
          ])));

  List<Widget> routerTab() => [
        card('الوضع الحالي', [Text(ML[nm['NetworkMode']] ?? nm['NetworkMode'] ?? '-')]),
        if (modes.isNotEmpty)
          card('وضع الشبكة', [
            Wrap(spacing: 8, children: [
              for (final m in modes)
                ChoiceChip(label: Text(ML[m] ?? 'وضع $m'), selected: nm['NetworkMode'] == m,
                    onSelected: busy ? null : (_) => pickMode(m))
            ])
          ]),
        if (sup.isNotEmpty)
          card('نطاقات 4G', [
            Wrap(spacing: 8, children: [
              for (final b in sup)
                FilterChip(label: Text('B$b'), selected: sel.contains(b),
                    onSelected: busy ? null : (v) => setState(() => v ? sel.add(b) : sel.remove(b)))
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              FilledButton(
                  onPressed: busy || sel.isEmpty ? null : () => change(maskOf(sel), nm['NetworkMode'] ?? '00'),
                  child: const Text('تطبيق النطاقات')),
              OutlinedButton(onPressed: busy ? null : () => setState(() => sel = sup.toSet()), child: const Text('كل المدعومة')),
            ]),
          ]),
        card('الرجوع', [
          OutlinedButton(
              onPressed: busy || orig == null
                  ? null
                  : () async {
                      if (await confirm('الرجوع للإعداد الأول (${ML[orig!['NetworkMode']] ?? orig!['NetworkMode']})؟')) {
                        await change(norm(orig!['LTEBand'] ?? ''), orig!['NetworkMode'] ?? '00');
                      }
                    },
              child: const Text('رجوع للإعداد الأول')),
          Text('المحفوظ: الوضع ${orig?['NetworkMode']} والنطاقات ${orig?['LTEBand']}'),
        ]),
        card('تقرير الجهاز', [
          Wrap(spacing: 8, children: [
            OutlinedButton(onPressed: busy ? null : doReport, child: const Text('اقرأ الجهاز')),
            OutlinedButton(
                onPressed: report.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: report)),
                child: const Text('نسخ')),
          ]),
          if (report.isNotEmpty)
            SelectableText(report, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
        ]),
      ];

  List<Widget> chartsTab() => [
        for (final e in [('RSRP', hR, kGreen), ('SINR', hS, Colors.orange)])
          card('${e.$1}  ${e.$2.isEmpty ? '-' : fmt(e.$2.last)}', [
            SizedBox(height: 120, width: double.infinity, child: CustomPaint(painter: _Spark(e.$2, e.$3))),
            const Text('آخر 6 دقائق تقريبًا', style: TextStyle(fontSize: 11, color: Colors.white54)),
          ]),
      ];

  Widget tabBtn(int i, IconData ic, String t, {VoidCallback? onTap}) => Expanded(
      child: InkWell(
          onTap: onTap ?? () => setState(() => tab = i),
          child: Container(
              color: onTap == null && tab == i ? kGreen : const Color(0xFF3A3A3A),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(children: [
                Icon(ic, color: onTap == null && tab == i ? Colors.black : Colors.white70),
                Text(t, style: TextStyle(fontSize: 11, color: onTap == null && tab == i ? Colors.black : Colors.white70)),
              ]))));

  Widget loginView() => ListView(padding: const EdgeInsets.all(14), children: [
        const SizedBox(height: 40),
        const Text('لوحة الراوتر', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: kGreen)),
        const SizedBox(height: 24),
        TextField(controller: host, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'عنوان الراوتر')),
        const SizedBox(height: 10),
        TextField(controller: pw, obscureText: true, textDirection: TextDirection.ltr,
            decoration: const InputDecoration(labelText: 'كلمة مرور admin')),
        CheckboxListTile(
            value: remember,
            onChanged: (v) => setState(() => remember = v ?? true),
            title: const Text('حفظ كلمة المرور على هذا الجهاز (مشفّرة)'),
            controlAffinity: ListTileControlAffinity.leading),
        FilledButton(onPressed: busy ? null : doLogin, child: const Text('دخول')),
        if (busy) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.all(10), child: SelectableText(msg)),
      ]);

  @override
  Widget build(BuildContext c) {
    if (hw == null) return Scaffold(body: SafeArea(child: loginView()));
    final has5 = (sig['nrrsrp'] ?? '').isNotEmpty && sig['nrrsrp'] != 'None';
    return Scaffold(
        body: SafeArea(
            child: Column(children: [
      Container(
          color: kHead,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Text(model.isEmpty ? 'ROUTER' : model, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
            const Spacer(),
            Text(has5 ? '5G' : 'LTE', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: kGreen)),
            IconButton(onPressed: logout, icon: const Icon(Icons.logout), tooltip: 'خروج ونسيان كلمة المرور'),
          ])),
      Container(height: 3, color: kGreen),
      Row(children: [
        tabBtn(0, Icons.cell_tower, 'CELL'),
        tabBtn(1, Icons.router, 'ROUTER'),
        tabBtn(2, Icons.show_chart, 'CHARTS'),
        tabBtn(3, Icons.refresh, 'RECONNECT', onTap: busy ? null : reconnect),
      ]),
      if (busy) const LinearProgressIndicator(),
      Expanded(
          child: ListView(children: [
        ...(tab == 0 ? cellTab() : tab == 1 ? routerTab() : chartsTab()),
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.all(12), child: SelectableText(msg)),
      ])),
    ])));
  }
}
