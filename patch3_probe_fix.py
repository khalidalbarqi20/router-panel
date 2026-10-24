import sys
p = 'lib/main.dart'
s = open(p, encoding='utf-8').read()
if 'Future<String> probe()' in s:
    print('already patched'); sys.exit(0)

def rep(old, new):
    global s
    if s.count(old) != 1:
        print('NOT FOUND/AMBIGUOUS:', old[:70]); sys.exit(1)
    s = s.replace(old, new, 1)

# 1) اتصال أثبت: بدون keep-alive + إعادة محاولة للقراءة
rep("  Future<Resp> _req(String m, String p, {String? body}) async {",
"""  Future<Resp> _req(String m, String p, {String? body}) async {
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

  Future<Resp> _req1(String m, String p, {String? body}) async {""")

rep("    final r = await _h.openUrl(m, Uri.parse('http://$host$p'));",
"""    final r = await _h.openUrl(m, Uri.parse('http://$host$p'));
    r.persistentConnection = false;""")

rep("  Huawei(this.host);", """  Huawei(this.host) {
    _h.userAgent = 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
  }""")

# 2) فحص الراوتر بدون كلمة مرور
rep("  static String tag(String x, String t) =>", """  Future<String> probe() async {
    final b = StringBuffer();
    String cut(String x) => x.length > 700 ? x.substring(0, 700) : x;
    String hide(String x) => x.replaceAllMapped(
        RegExp(r'<(\\w*(?:imei|imsi|serial|mac|iccid|msisdn|phone|number|ssid)\\w*)>[^<]+</', caseSensitive: false),
        (m) => '<${m[1]}>***</');
    for (final path in ['/api/user/state-login', '/api/device/basic_information', '/api/user/hilink_login']) {
      try {
        b.writeln('## GET $path\\n${cut(hide((await _req('GET', path)).body))}\\n');
      } catch (e) {
        b.writeln('## GET $path خطأ: $e\\n');
      }
    }
    try {
      _ck.clear();
      await _req('GET', '/');
      final tk = tag((await _req('GET', '/api/webserver/token')).body, 'token');
      b.writeln('## token طوله: ${tk.length}\\n');
      _tok = tk.length > 32 ? tk.substring(32) : tk;
      final rnd = Random.secure();
      final cn = List.generate(64, (_) => rnd.nextInt(16).toRadixString(16)).join();
      final c = await _req('POST', '/api/user/challenge_login',
          body: '<?xml version="1.0" encoding="UTF-8"?><request><username>admin</username>'
              '<firstnonce>$cn</firstnonce><mode>1</mode></request>');
      b.writeln('## POST challenge_login\\n${cut(c.body)}\\n');
    } catch (e) {
      b.writeln('## token/challenge خطأ: $e\\n');
    }
    return b.toString();
  }

  static String tag(String x, String t) =>""")

# 3) كلمة المرور المرئية + زر الفحص
rep("  int fails = 0, cool = 0;\n  Timer? coolT;", "  int fails = 0, cool = 0;\n  Timer? coolT;\n  String diag = '';\n  bool showPw = false;")

rep("""        TextField(controller: pw, obscureText: true, textDirection: TextDirection.ltr,
            decoration: const InputDecoration(labelText: 'كلمة مرور admin')),""",
"""        TextField(controller: pw, obscureText: !showPw, textDirection: TextDirection.ltr,
            decoration: InputDecoration(
                labelText: 'كلمة مرور admin',
                suffixIcon: IconButton(
                    icon: Icon(showPw ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => showPw = !showPw)))),""")

rep("        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.all(10), child: SelectableText(msg)),",
"""        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.all(10), child: SelectableText(msg)),
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
        ],""")

open(p, 'w', encoding='utf-8').write(s)
print('OK patched 3')
