import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class Resp {
  final String body;
  final HttpHeaders headers;
  Resp(this.body, this.headers);
}

/// عميل Huawei: دخول SCRAM ثم قراءة/كتابة /api/...
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

  static String tag(String x, String t) =>
      RegExp('<$t>([^<]*)</$t>').firstMatch(x)?[1] ?? '';
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
List<int> bandsOf(String hex) {
  final m = int.tryParse(hex, radix: 16) ?? 0;
  return [for (var i = 0; i < 63; i++) if ((m >> i) & 1 == 1) i + 1];
}
String maskOf(Iterable<int> b) => b.fold<int>(0, (a, x) => a | (1 << (x - 1))).toRadixString(16);
String norm(String h) => h.toLowerCase().replaceFirst(RegExp('^0+'), '');

void main() => runApp(const App());

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'لوحة الراوتر',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xFF0B5D6B), useMaterial3: true),
        darkTheme: ThemeData(
            colorSchemeSeed: const Color(0xFF0B5D6B), brightness: Brightness.dark, useMaterial3: true),
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
  Map<String, String> sig = {}, nm = {};
  Map<String, String>? orig;
  List<String> modes = [];
  List<int> sup = [];
  Set<int> sel = {};
  String nb = '3fffffff', msg = '', report = '';
  bool busy = false;
  Timer? timer;

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
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
    if (!mounted) return;
    setState(() {
      sig = Huawei.kv(s);
      nm = Huawei.kv(n);
      if (sync || sel.isEmpty) sel = bandsOf(nm['LTEBand'] ?? '0').toSet();
    });
  }

  Future<void> doLogin() => run(() async {
        final h = Huawei(host.text.trim());
        await h.login(pw.text);
        _pw = pw.text;
        pw.clear();
        final l = await h.get('net/net-mode-list');
        modes = RegExp(r'<Access>(\w+)</Access>').allMatches(l).map((m) => m[1]!).toList();
        sup = ({for (final m in RegExp(r'BC(\d+)').allMatches(l)) int.parse(m[1]!)}.toList())..sort();
        nb = RegExp(r'<BandList>.*?<Value>([^<]*)</Value>', dotAll: true).firstMatch(l)?[1] ?? '3fffffff';
        hw = h;
        await refresh(sync: true);
        orig ??= Map.of(nm);
        timer?.cancel();
        timer = Timer.periodic(const Duration(seconds: 15), (_) => refresh().catchError((_) {}));
      });

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

  Widget card(String t, List<Widget> c) => Card(
      child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...c
          ])));

  List<Widget> login() => [
        card('الدخول', [
          TextField(controller: host, textDirection: TextDirection.ltr, decoration: const InputDecoration(labelText: 'عنوان الراوتر')),
          const SizedBox(height: 8),
          TextField(controller: pw, obscureText: true, textDirection: TextDirection.ltr,
              decoration: const InputDecoration(labelText: 'كلمة مرور admin (لا تُحفظ)')),
          const SizedBox(height: 12),
          FilledButton(onPressed: busy ? null : doLogin, child: const Text('دخول')),
        ])
      ];

  List<Widget> dash() {
    final has5 = (sig['nrrsrp'] ?? '').isNotEmpty && sig['nrrsrp'] != 'None';
    return [
      card('الإشارة', [
        Text('4G: B${sig['band'] ?? '-'} · RSRP ${sig['rsrp'] ?? '-'} · SINR ${sig['sinr'] ?? '-'}'),
        Text(has5 ? '5G: ${sig['nrdlfreq'] ?? ''} · RSRP ${sig['nrrsrp']} · SINR ${sig['nrsinr'] ?? '-'}' : '5G: غير متصل'),
        Text('الوضع: ${ML[nm['NetworkMode']] ?? nm['NetworkMode'] ?? '-'}'),
      ]),
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
        Text('الإعداد الأول محفوظ في الذاكرة فقط: الوضع ${orig?['NetworkMode']} والنطاقات ${orig?['LTEBand']}'),
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
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('لوحة الراوتر')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          if (busy) const LinearProgressIndicator(),
          ...(hw == null ? login() : dash()),
          if (msg.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: SelectableText(msg)),
        ]),
      );
}
