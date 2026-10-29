import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'probe.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'game.dart';
import 'modes.dart';
import 'brand.dart';
import 'netinfo.dart';

const _st = FlutterSecureStorage();

class Resp {
  final String body;
  final HttpHeaders headers;
  Resp(this.body, this.headers);
}

class LoginError implements Exception {
  final String code, wait, text;
  LoginError(this.code, this.wait, this.text);
  @override
  String toString() => text;
}

LoginError loginErr(String code, String wait) {
  switch (code) {
    case '108006':
    case '108002':
    case '108001':
      return LoginError(code, wait,
          'كلمة المرور (أو اسم المستخدم) غير صحيحة. لا تخمّن، لأن الراوتر يقفل الدخول بعد محاولات فاشلة. جرّب نفس الكلمة من المتصفح على عنوان الراوتر للتأكد. (الكود $code)');
    case '108007':
      return LoginError(code, wait,
          'الراوتر قفل الدخول مؤقتًا بسبب محاولات فاشلة. انتظر ثم أعد المحاولة${wait.isEmpty ? '' : ' (مدة الانتظار اللي أعطاها الراوتر: $wait)'}. (الكود $code)');
    case '108003':
      return LoginError(code, wait,
          'فيه جلسة دخول ثانية مفتوحة على الراوتر (مثل صفحته في المتصفح). اقفلها وأعد المحاولة. (الكود $code)');
    case '108005':
      return LoginError(code, wait,
          'عدد المستخدمين المسجلين بالراوتر وصل الحد. اقفل جلسة ثانية وأعد المحاولة. (الكود $code)');
    default:
      return LoginError(code, wait, 'رفض الراوتر الدخول (الكود $code).');
  }
}

class Huawei {
  final String host;
  final HttpClient _h = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  final Map<String, String> _ck = {};
  String _tok = '';
  Huawei(this.host) {
    _h.userAgent = 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
  }

  Future<Resp> _req(String m, String p, {String? body}) async {
    for (var i = 0;; i++) {
      try {
        return await _req1(m, p, body: body);
      } on HttpException {
        if (m != 'GET' || i >= 2) rethrow;
      } on SocketException {
        if (m != 'GET' || i >= 2) rethrow;
      }
      await Future.delayed(const Duration(milliseconds: 700));
    }
  }

  Future<Resp> _req1(String m, String p, {String? body}) async {
    final r = await _h.openUrl(m, Uri.parse('http://$host$p'));
    r.persistentConnection = false;
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

  Future<String> probe() async {
    final b = StringBuffer();
    String cut(String x) => x.length > 700 ? x.substring(0, 700) : x;
    String hide(String x) => x.replaceAllMapped(
        RegExp(r'<(\w*(?:imei|imsi|serial|mac|iccid|msisdn|phone|number|ssid)\w*)>[^<]+</', caseSensitive: false),
        (m) => '<${m[1]}>***</');
    for (final path in ['/api/user/state-login', '/api/device/basic_information', '/api/user/hilink_login']) {
      try {
        b.writeln('## GET $path\n${cut(hide((await _req('GET', path)).body))}\n');
      } catch (e) {
        b.writeln('## GET $path خطأ: $e\n');
      }
    }
    try {
      _ck.clear();
      await _req('GET', '/');
      final tk = tag((await _req('GET', '/api/webserver/token')).body, 'token');
      b.writeln('## token طوله: ${tk.length}\n');
      _tok = tk.length > 32 ? tk.substring(32) : tk;
      final rnd = Random.secure();
      final cn = List.generate(64, (_) => rnd.nextInt(16).toRadixString(16)).join();
      final c = await _req('POST', '/api/user/challenge_login',
          body: '<?xml version="1.0" encoding="UTF-8"?><request><username>admin</username>'
              '<firstnonce>$cn</firstnonce><mode>1</mode></request>');
      b.writeln('## POST challenge_login\n${cut(c.body)}\n');
    } catch (e) {
      b.writeln('## token/challenge خطأ: $e\n');
    }
    return b.toString();
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
    final e1 = err(c.body);
    if (e1 != null) throw loginErr(e1, tag(c.body, 'waittime'));
    final sn = tag(c.body, 'servernonce'), salt = tag(c.body, 'salt');
    final it = int.tryParse(tag(c.body, 'iterations'));
    if (sn.isEmpty || it == null) throw 'رد غير متوقع من الراوتر عند الدخول: ${c.body}';
    _tok = c.headers.value('__requestverificationtoken') ?? _tok;
    final f = await _req('POST', '/api/user/authentication_login',
        body: '<?xml version="1.0" encoding="UTF-8"?><request><clientproof>'
            '${_proof(cn, sn, pw, salt, it)}</clientproof><finalnonce>$sn</finalnonce></request>');
    final e2 = err(f.body);
    if (e2 != null) throw loginErr(e2, tag(f.body, 'waittime'));
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
const kIcons = <String, IconData>{
  'router': Icons.router,
  'home': Icons.home,
  'cell': Icons.cell_tower,
  'work': Icons.work,
  'car': Icons.directions_car,
  'store': Icons.store,
  'wifi': Icons.wifi,
  'land': Icons.landscape,
  'apt': Icons.apartment,
  'cottage': Icons.cottage,
};

class Dev {
  String id, name, host, pw, icon;
  Dev(this.id, this.name, this.host, this.pw, this.icon);
  Map<String, String> toJson() => {'id': id, 'name': name, 'host': host, 'pw': pw, 'icon': icon};
  static Dev fromJson(Map j) => Dev('${j['id']}', '${j['name'] ?? ''}', '${j['host'] ?? ''}',
      '${j['pw'] ?? ''}', '${j['icon'] ?? 'router'}');
}

const AN = {'0': 'مدمج (تلقائي)', '1': 'داخلي', '2': 'خارجي'};
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
        builder: (c, w) => Directionality(
            textDirection: TextDirection.rtl,
            child: ColoredBox(
                color: kBg,
                child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: w!)))),
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
  Map<String, String> sig = {}, nm = {}, tr = {}, stx = {};
  Map<String, String>? orig;
  List<String> modes = [];
  List<int> sup = [];
  Set<int> sel = {};
  List<double> hR = [], hS = [];
  String nb = '3fffffff', msg = '', report = '', isp = '', model = 'ROUTER';
  bool busy = false, remember = true, _poll = false, awake = false;
  String ant = '', antType = '';
  int fails = 0, cool = 0;
  Timer? coolT;
  String diag = '';
  bool showPw = false;
  List<Dev> devs = [];
  Dev? cur;
  bool adding = false;
  String coolHost = '', newIcon = 'router';
  final dname = TextEditingController();
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
    coolT?.cancel();
    dname.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final aw = await _st.read(key: 'awake');
      if (aw == '1') {
        awake = true;
        await WakelockPlus.enable();
      }
      final raw = await _st.read(key: 'devices');
      if (raw != null) {
        devs = [for (final j in jsonDecode(raw) as List) Dev.fromJson(j as Map)];
      } else {
        final h = await _st.read(key: 'host');
        final p = await _st.read(key: 'pw');
        if (h != null && p != null) {
          devs = [Dev('${DateTime.now().millisecondsSinceEpoch}', '', h, p, 'router')];
          await saveDevs();
        }
      }
      await _st.delete(key: 'pw');
      await _st.delete(key: 'host');
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> saveDevs() =>
      _st.write(key: 'devices', value: jsonEncode([for (final d in devs) d.toJson()]));

  Future<void> run(Future<void> Function() f) async {
    setState(() {
      busy = true;
      msg = '';
    });
    try {
      await f();
    } catch (e) {
      msg = (e is SocketException || e is HttpException)
          ? 'ما قدرت أتصل بالراوتر. تأكد أنك متصل بواي فاي هذا الراوتر وأن العنوان صحيح. ($e)'
          : '$e';
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
    Map<String, String> sx = stx;
    try {
      sx = Huawei.kv(await hw!.get('monitoring/status'));
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      stx = sx;
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

  Future<void> doLogin({Dev? dev}) => run(() async {
        final hostV = (dev?.host ?? host.text).trim();
        final pwV = dev?.pw ?? pw.text;
        final h = Huawei(hostV);
        try {
          await h.login(pwV);
          fails = 0;
        } on LoginError catch (e) {
          if (e.code == '108007') {
            startCool(hostV);
          } else if (['108006', '108002', '108001'].contains(e.code)) {
            fails++;
          }
          throw LoginError(e.code, e.wait,
              fails > 0 ? '${e.text}\nمحاولات فاشلة متتالية من التطبيق: $fails' : e.text);
        }
        _pw = pwV;
        Dev? d = dev;
        if (d == null) {
          for (final x in devs) {
            if (x.host == hostV) d = x;
          }
          if (d == null && remember) {
            d = Dev('${DateTime.now().millisecondsSinceEpoch}', dname.text.trim(), hostV, pwV, newIcon);
            devs.add(d);
          } else if (d != null && remember) {
            d.pw = pwV;
            if (dname.text.trim().isNotEmpty) d.name = dname.text.trim();
          }
        }
        cur = d;
        pw.clear();
        dname.clear();
        adding = false;
        final l = await h.get('net/net-mode-list');
        modes = RegExp(r'<Access>(\w+)</Access>').allMatches(l).map((m) => m[1]!).toList();
        sup = ({for (final m in RegExp(r'BC(\d+)').allMatches(l)) int.parse(m[1]!)}.toList())..sort();
        nb = RegExp(r'<BandList>.*?<Value>([^<]*)</Value>', dotAll: true).firstMatch(l)?[1] ?? '3fffffff';
        try {
          model = Huawei.tag(await h.get('device/basic_information'), 'devicename');
          isp = Huawei.tag(await h.get('net/current-plmn'), 'FullName');
        } catch (_) {}
        final cd = cur;
        if (cd != null) {
          if (cd.name.isEmpty) cd.name = model.isEmpty ? hostV : model;
          if (devs.contains(cd)) await saveDevs();
        }
        final okey = 'orig_${cd?.id ?? hostV}';
        hw = h;
        await readAntenna();
        await refresh(sync: true);
        final o = await _st.read(key: okey);
        if (o != null) {
          orig = Map<String, String>.from(jsonDecode(o));
        } else {
          orig = Map.of(nm);
          await _st.write(key: okey, value: jsonEncode(orig));
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

  void startCool(String h) {
    coolT?.cancel();
    coolHost = h;
    cool = 120;
    coolT = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        cool--;
        if (cool <= 0) {
          cool = 0;
          t.cancel();
        }
      });
    });
  }

  Future<void> toggleAwake(bool v) async {
    setState(() => awake = v);
    try {
      v ? await WakelockPlus.enable() : await WakelockPlus.disable();
    } catch (_) {}
    await _st.write(key: 'awake', value: v ? '1' : '0');
  }

  Future<void> readAntenna() async {
    try {
      final a = Huawei.tag(await hw!.get('device/antenna_set_type'), 'antennasettype');
      final t = Huawei.tag(await hw!.get('device/antenna_type'), 'antennatype');
      if (mounted) setState(() {
        ant = a;
        antType = t;
      });
    } catch (_) {}
  }

  Future<void> setAntenna(String v) async {
    if (!await confirm('تغيير الانتينا إلى «${AN[v]}»؟ قد ينقطع الاتصال لحظات، وإذا ما فيه انتينا خارجية موصولة قد تضعف الإشارة.')) return;
    await run(() async {
      final r = await hw!.post('device/antenna_set_type', '<antennasettype>$v</antennasettype>');
      final note = Huawei.err(r);
      await Future.delayed(const Duration(seconds: 6));
      for (var i = 0; i < 6; i++) {
        try {
          await readAntenna();
          msg = ant == v
              ? 'تم تغيير الانتينا وتأكّدت القراءة.'
              : 'الراوتر لم يطبّق التغيير (رد الراوتر: ${note ?? 'OK'}، القيمة الحالية: $ant).';
          return;
        } catch (_) {
          await Future.delayed(const Duration(seconds: 5));
        }
      }
      msg = 'ما قدرت أتأكد من النتيجة. انتظر دقيقة وأعد المحاولة.';
    });
  }

  Future<void> logout() async {
    timer?.cancel();
    setState(() {
      hw = null;
      cur = null;
      adding = false;
      msg = '';
      tab = 0;
      sig = {};
      nm = {};
      tr = {};
      hR = [];
      hS = [];
      sel = {};
      modes = [];
      sup = [];
      ant = '';
      antType = '';
      report = '';
      orig = null;
    });
  }

  Future<void> delDev(Dev d) async {
    if (!await confirm('حذف «${d.name.isEmpty ? d.host : d.name}» من القائمة؟ تنحذف كلمة مروره المحفوظة.')) return;
    devs.remove(d);
    await _st.delete(key: 'orig_${d.id}');
    await saveDevs();
    if (mounted) setState(() {});
  }

  Future<void> editDev(Dev d) async {
    final n = TextEditingController(text: d.name);
    final hh = TextEditingController(text: d.host);
    final pp = TextEditingController(text: d.pw);
    var ic = d.icon;
    final ok = await showDialog<bool>(
            context: context,
            builder: (c) => StatefulBuilder(
                builder: (c, set) => AlertDialog(
                        title: const Text('تعديل الجهاز'),
                        content: SingleChildScrollView(
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                          TextField(controller: n, decoration: const InputDecoration(labelText: 'اسم الجهاز')),
                          TextField(controller: hh, textDirection: TextDirection.ltr,
                              decoration: const InputDecoration(labelText: 'عنوان الراوتر')),
                          TextField(controller: pp, obscureText: true, textDirection: TextDirection.ltr,
                              decoration: const InputDecoration(labelText: 'كلمة المرور')),
                          const SizedBox(height: 12),
                          Wrap(spacing: 6, children: [
                            for (final e in kIcons.entries)
                              ChoiceChip(label: Icon(e.value, size: 20), selected: ic == e.key,
                                  onSelected: (_) => set(() => ic = e.key))
                          ]),
                        ])),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
                          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('حفظ')),
                        ]))) ??
        false;
    if (!ok) return;
    d.name = n.text.trim();
    d.host = hh.text.trim();
    d.pw = pp.text;
    d.icon = ic;
    await saveDevs();
    if (mounted) setState(() {});
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
          'net/net-mode', 'net/net-mode-list', 'monitoring/status', 'wlan/basic-settings',
          'device/antenna_type', 'device/antenna_set_type']) {
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

  // ---------- وضع الألعاب ----------
  /// يطبّق النطاق والوضع ويتأكد بالقراءة (بدون واجهة، تستعمله صفحة الألعاب).
  Future<bool> applyQuiet(String mask, String mode) async {
    final body = '<NetworkMode>$mode</NetworkMode><NetworkBand>$nb</NetworkBand><LTEBand>$mask</LTEBand>';
    try {
      await hw!.login(_pw!);
    } catch (_) {}
    try {
      await hw!.post('net/net-mode', body);
    } catch (_) {
      try {
        await hw!.login(_pw!);
        await hw!.post('net/net-mode', body);
      } catch (_) {}
    }
    await Future.delayed(const Duration(seconds: 20));
    for (var i = 0; i < 8; i++) {
      try {
        await hw!.login(_pw!);
        await refresh(sync: true);
        return nm['NetworkMode'] == mode && norm(nm['LTEBand'] ?? '') == mask;
      } catch (_) {
        await Future.delayed(const Duration(seconds: 8));
      }
    }
    return false;
  }
  /// فحص سريع: هل يسجّل الراوتر على هذا النطاق ويتصل بالشبكة؟ (بدون قياسات ثقيلة)
  Future<ProbeRes> probeQuiet(String mask, String mode) async {
    final sw = Stopwatch()..start();
    final want = bandsOf(mask);
    final body = '<NetworkMode>$mode</NetworkMode><NetworkBand>$nb</NetworkBand><LTEBand>$mask</LTEBand>';
    var reached = false;
    try {
      await hw!.login(_pw!);
      reached = true;
    } catch (_) {}
    try {
      await hw!.post('net/net-mode', body);
    } catch (_) {
      try {
        await hw!.login(_pw!);
        await hw!.post('net/net-mode', body);
      } catch (_) {}
    }
    await Future.delayed(const Duration(seconds: 5));
    var good = 0;
    var lastBand = '';
    var everApplied = false;
    while (sw.elapsed < const Duration(seconds: 55) && (everApplied || sw.elapsed < const Duration(seconds: 25))) {
      try {
        final n = Huawei.kv(await hw!.get('net/net-mode'));
        final s = Huawei.kv(await hw!.get('device/signal'));
        reached = true;
        var connected = true;
        var stm = <String, String>{};
        try {
          stm = Huawei.kv(await hw!.get('monitoring/status'));
          connected = stm['ConnectionStatus'] == '901';
        } catch (_) {}
        final b = num_(s['band'])?.toInt();
        final r = num_(s['rsrp']);
        lastBand = b == null ? '' : 'B$b';
        final applied = norm(n['LTEBand'] ?? '') == norm(mask) && n['NetworkMode'] == mode;
        if (applied) everApplied = true;
        if (applied && connected && b != null && want.contains(b)) {
          good++;
          if (good >= 2) {
            return ProbeRes(true, true, 'B$b', r, num_(s['sinr']), sw.elapsed.inSeconds, '',
                cell: s['cell_id'] ?? '',
                pci: s['pci'] ?? '',
                earfcn: s['earfcn'] ?? s['dlearfcn'] ?? s['ltedlfreq'] ?? '',
                ca: isCaMap(stm, s));
          }
        } else {
          good = 0;
        }
      } catch (_) {
        try {
          await hw!.login(_pw!);
        } catch (_) {}
      }
      await Future.delayed(const Duration(seconds: 3));
    }
    final why = !reached ? 'الراوتر ما ردّ' : (!everApplied ? 'الراوتر ما قبل هذا النطاق (غير مدعوم؟)' : (lastBand.isEmpty ? 'ما سجّل على أي نطاق' : 'بقي على $lastBand'));
    return ProbeRes(false, reached, lastBand, null, null, sw.elapsed.inSeconds, why);
  }
  /// حالة الراوتر: الإشارة + الحالة العامة (الحقول المأخوذة من الحالة تبدأ بـ st_).
  Future<Map<String, String>> snapQuiet() async {
    final s = Huawei.kv(await hw!.get('device/signal'));
    var st = <String, String>{};
    try {
      st = Huawei.kv(await hw!.get('monitoring/status'));
    } catch (_) {}
    return <String, String>{...s, for (final e in st.entries) 'st_${e.key}': e.value};
  }

  /// الأجهزة المتصلة (واي فاي + سلك)، بدون تكرار.
  Future<List<Map<String, String>>> hostsQuiet() async {
    final out = <String, Map<String, String>>{};
    List<Map<String, String>> parse(String x) => <Map<String, String>>[
          for (final mm in RegExp(r'<Host>(.*?)</Host>', dotAll: true).allMatches(x)) Huawei.kv(mm[1]!)
        ];
    try {
      for (final h in parse(await hw!.get('wlan/host-list'))) {
        out[h['MacAddress'] ?? h['IpAddress'] ?? '${out.length}'] = <String, String>{...h, '_t': 'wifi'};
      }
    } catch (_) {}
    try {
      for (final h in parse(await hw!.get('lan/HostInfo'))) {
        if ((h['Active'] ?? '1') == '0') continue;
        out.putIfAbsent(h['MacAddress'] ?? h['IpAddress'] ?? '${out.length}',
            () => <String, String>{...h, '_t': (h['InterfaceType'] ?? '').toLowerCase().contains('wi') ? 'wifi' : 'lan'});
      }
    } catch (_) {}
    return out.values.toList();
  }

  GameCtl gameCtl() => GameCtl(
        routerHost: hw!.host,
        sup: List<int>.from(sup),
        modes: List<String>.from(modes),
        curMask: () => norm(nm['LTEBand'] ?? ''),
        curMode: () => nm['NetworkMode'] ?? '00',
        apply: applyQuiet,
        probe: probeQuiet,
        keepAwake: awake,
        snap: snapQuiet,
        hosts: hostsQuiet,
        scanList: (<int>{...sup, ...kSaudiBands}.toList()..sort()),
      );

  Future<void> openGame() async {
    if (busy || hw == null) return;
    setState(() => busy = true);
    try {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (c) => ModesHub(ctl: gameCtl())));
    } finally {
      if (mounted) setState(() => busy = false);
    }
    try {
      await refresh(sync: true);
    } catch (_) {}
  }

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
        card('الشاشة', [
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: awake,
              onChanged: toggleAwake,
              title: const Text('إبقاء الشاشة شغّالة'),
              subtitle: const Text('أثناء فتح التطبيق فقط')),
        ]),
        if (ant.isNotEmpty)
          card('الانتينا', [
            Text('الحالية: ${AN[ant] ?? 'قيمة $ant'}${antType.isEmpty ? '' : '  (المستخدمة فعليًا: $antType)'}'),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final e in AN.entries)
                ChoiceChip(label: Text(e.value), selected: ant == e.key,
                    onSelected: busy ? null : (_) => setAntenna(e.key))
            ]),
          ]),
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

  Widget devicesView() => ListView(padding: const EdgeInsets.all(14), children: [
        const SizedBox(height: 30),
        const Text('لوحة الراوتر', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: kGreen)),
        const SizedBox(height: 6),
        const Text('اختر الجهاز للدخول', textAlign: TextAlign.center, style: TextStyle(color: Colors.white54)),
        const SizedBox(height: 18),
        for (final d in devs)
          Card(
              child: ListTile(
                  leading: CircleAvatar(backgroundColor: kGreen, child: Icon(kIcons[d.icon] ?? Icons.router, color: Colors.black)),
                  title: Text(d.name.isEmpty ? d.host : d.name),
                  subtitle: Text(cool > 0 && coolHost == d.host
                      ? 'مقفول مؤقتًا: ${cool ~/ 60}:${(cool % 60).toString().padLeft(2, '0')}'
                      : d.host),
                  onTap: busy || (cool > 0 && coolHost == d.host) ? null : () => doLogin(dev: d),
                  trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'e') {
                          editDev(d);
                        } else {
                          delDev(d);
                        }
                      },
                      itemBuilder: (c) => const [
                            PopupMenuItem(value: 'e', child: Text('تعديل')),
                            PopupMenuItem(value: 'd', child: Text('حذف')),
                          ]))),
        const SizedBox(height: 8),
        OutlinedButton.icon(
            onPressed: busy ? null : () => setState(() => adding = true),
            icon: const Icon(Icons.add),
            label: const Text('إضافة جهاز')),
        if (busy) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.all(10), child: SelectableText(msg)),
      ]);

  Widget loginView() => ListView(padding: const EdgeInsets.all(14), children: [
        if (devs.isNotEmpty)
          Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                  onPressed: busy ? null : () => setState(() => adding = false),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('رجوع للأجهزة'))),
        const SizedBox(height: 40),
        const Text('لوحة الراوتر', textAlign: TextAlign.center, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: kGreen)),
        const SizedBox(height: 24),
        TextField(controller: host, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'عنوان الراوتر')),
        const SizedBox(height: 10),
        TextField(controller: dname, decoration: const InputDecoration(labelText: 'اسم الجهاز (اختياري)')),
        const SizedBox(height: 10),
        TextField(controller: pw, obscureText: !showPw, textDirection: TextDirection.ltr,
            decoration: InputDecoration(
                labelText: 'كلمة مرور admin',
                suffixIcon: IconButton(
                    icon: Icon(showPw ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => showPw = !showPw)))),
        CheckboxListTile(
            value: remember,
            onChanged: (v) => setState(() => remember = v ?? true),
            title: const Text('حفظ الجهاز وكلمة مروره (مشفّرة)'),
            controlAffinity: ListTileControlAffinity.leading),
        Wrap(spacing: 6, children: [
          for (final e in kIcons.entries)
            ChoiceChip(label: Icon(e.value, size: 20), selected: newIcon == e.key,
                onSelected: (_) => setState(() => newIcon = e.key))
        ]),
        const SizedBox(height: 10),
        FilledButton(
            onPressed: busy || (cool > 0 && coolHost == host.text.trim()) ? null : () => doLogin(),
            child: Text(cool > 0 && coolHost == host.text.trim()
                ? 'انتظر ${cool ~/ 60}:${(cool % 60).toString().padLeft(2, '0')}'
                : 'دخول')),
        if (busy) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.all(10), child: SelectableText(msg)),
        const SizedBox(height: 10),
        OutlinedButton(
            onPressed: busy
                ? null
                : () => run(() async {
                      diag = await Huawei(host.text.trim()).probe();
                    }),
            child: const Text('فحص الراوتر (بدون كلمة مرور)')),
        if (diag.isNotEmpty) ...[
          OutlinedButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: diag)),
              child: const Text('نسخ نتيجة الفحص')),
          SelectableText(diag, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
        ],
      ]);

  @override
  Widget build(BuildContext c) {
    if (hw == null) return Scaffold(body: SafeArea(child: (devs.isEmpty || adding) ? loginView() : devicesView()));
    final has5 = (sig['nrrsrp'] ?? '').isNotEmpty && sig['nrrsrp'] != 'None';
    return Scaffold(
        body: SafeArea(
            child: Column(children: [
      Container(
          color: kHead,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            (cur?.icon == null || cur?.icon == 'router')
                ? const KifiBadge(size: 30)
                : Icon(kIcons[cur?.icon] ?? Icons.router, color: kGreen),
            const SizedBox(width: 8),
            Flexible(
                child: Text((cur != null && cur!.name.isNotEmpty) ? cur!.name : (model.isEmpty ? 'ROUTER' : model),
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
            const Spacer(),
            Text(has5 ? '5G' : 'LTE', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: kGreen)),
            IconButton(onPressed: logout, icon: const Icon(Icons.logout), tooltip: 'رجوع لقائمة الأجهزة'),
          ])),
      Container(height: 3, color: kGreen),
      Row(children: [
        tabBtn(0, Icons.cell_tower, 'CELL'),
        tabBtn(1, Icons.router, 'ROUTER'),
        tabBtn(2, Icons.show_chart, 'CHARTS'),
        tabBtn(3, Icons.refresh, 'RECONNECT', onTap: busy ? null : reconnect),
        tabBtn(4, Icons.tune, 'MODES', onTap: openGame),
      ]),
      if (busy) const LinearProgressIndicator(),
      Expanded(
          child: ListView(children: [
        ...(tab == 0 ? <Widget>[SignalHero(sig: sig, st: stx), ...cellTab()] : tab == 1 ? routerTab() : chartsTab()),
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.all(12), child: SelectableText(msg)),
      ])),
    ])));
  }
}
