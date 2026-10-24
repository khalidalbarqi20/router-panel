import sys
p = 'lib/main.dart'
s = open(p, encoding='utf-8').read()
if 'class LoginError' in s:
    print('already patched'); sys.exit(0)

def rep(old, new):
    global s
    if s.count(old) != 1:
        print('NOT FOUND/AMBIGUOUS:', old[:70]); sys.exit(1)
    s = s.replace(old, new, 1)

rep("class Huawei {", """class LoginError implements Exception {
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

class Huawei {""")

rep("    final sn = tag(c.body, 'servernonce'), salt = tag(c.body, 'salt');",
"""    final e1 = err(c.body);
    if (e1 != null) throw loginErr(e1, tag(c.body, 'waittime'));
    final sn = tag(c.body, 'servernonce'), salt = tag(c.body, 'salt');""")

rep("    if (err(f.body) != null) throw 'فشل الدخول (${err(f.body)}): تأكد من كلمة المرور، وقد يكون الدخول مقفولًا مؤقتًا.';",
"""    final e2 = err(f.body);
    if (e2 != null) throw loginErr(e2, tag(f.body, 'waittime'));""")

rep("  String ant = '', antType = '';", "  String ant = '', antType = '';\n  int fails = 0, cool = 0;\n  Timer? coolT;")

rep("    timer?.cancel();\n    super.dispose();", "    timer?.cancel();\n    coolT?.cancel();\n    super.dispose();")

rep("        await doLogin();\n", "        await doLogin(auto: true);\n")

rep("""Future<void> doLogin() => run(() async {
        final h = Huawei(host.text.trim());
        await h.login(pw.text);""",
"""Future<void> doLogin({bool auto = false}) => run(() async {
        final h = Huawei(host.text.trim());
        try {
          await h.login(pw.text);
          fails = 0;
        } on LoginError catch (e) {
          if (e.code == '108007') {
            startCool();
          } else if (['108006', '108002', '108001'].contains(e.code)) {
            fails++;
            if (auto) {
              await _st.delete(key: 'pw');
              pw.clear();
            }
          }
          throw LoginError(e.code, e.wait,
              fails > 0 ? '${e.text}\\nمحاولات فاشلة متتالية من التطبيق: $fails' : e.text);
        }""")

rep("  Future<void> toggleAwake(bool v) async {", """  void startCool() {
    coolT?.cancel();
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

  Future<void> toggleAwake(bool v) async {""")

rep("        FilledButton(onPressed: busy ? null : doLogin, child: const Text('دخول')),",
"""        FilledButton(
            onPressed: busy || cool > 0 ? null : () => doLogin(),
            child: Text(cool > 0 ? 'انتظر ${cool ~/ 60}:${(cool % 60).toString().padLeft(2, '0')}' : 'دخول')),""")

open(p, 'w', encoding='utf-8').write(s)
print('OK patched 2')
