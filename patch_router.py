import sys
p = 'lib/main.dart'
s = open(p, encoding='utf-8').read()
if 'wakelock_plus' in s:
    print('main.dart already patched')
    sys.exit(0)

def rep(old, new):
    global s
    if s.count(old) < 1:
        print('NOT FOUND:', old[:60]); sys.exit(1)
    s = s.replace(old, new, 1)

rep("import 'package:flutter_secure_storage/flutter_secure_storage.dart';",
"import 'package:flutter_secure_storage/flutter_secure_storage.dart';\nimport 'package:wakelock_plus/wakelock_plus.dart';")

rep("const kBg =", "const AN = {'0': 'مدمج (تلقائي)', '1': 'داخلي', '2': 'خارجي'};\nconst kBg =")

rep("bool busy = false, remember = true, _poll = false;",
"bool busy = false, remember = true, _poll = false, awake = false;\n  String ant = '', antType = '';")

rep("""      final h = await _st.read(key: 'host');
      final p = await _st.read(key: 'pw');
      if (h != null) host.text = h;""",
"""      final h = await _st.read(key: 'host');
      final p = await _st.read(key: 'pw');
      final aw = await _st.read(key: 'awake');
      if (aw == '1') {
        awake = true;
        await WakelockPlus.enable();
        if (mounted) setState(() {});
      }
      if (h != null) host.text = h;""")

rep("""  Future<void> logout() async {""",
"""  Future<void> toggleAwake(bool v) async {
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

  Future<void> logout() async {""")

rep("""        hw = h;
        await refresh(sync: true);""",
"""        hw = h;
        await readAntenna();
        await refresh(sync: true);""")

rep("'net/net-mode', 'net/net-mode-list', 'monitoring/status', 'wlan/basic-settings']",
"'net/net-mode', 'net/net-mode-list', 'monitoring/status', 'wlan/basic-settings',\n          'device/antenna_type', 'device/antenna_set_type']")

rep("""  List<Widget> routerTab() => [
        card('الوضع الحالي',""",
"""  List<Widget> routerTab() => [
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
        card('الوضع الحالي',""")

open(p, 'w', encoding='utf-8').write(s)

q = 'pubspec.yaml'
t = open(q, encoding='utf-8').read()
if 'wakelock_plus' not in t:
    t = t.replace("  flutter_secure_storage: ^9.2.2\n", "  flutter_secure_storage: ^9.2.2\n  wakelock_plus: ^1.2.8\n")
    open(q, 'w', encoding='utf-8').write(t)
print('OK patched')
