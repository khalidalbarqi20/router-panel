import sys, os

def rd(p):
    return open(p, encoding='utf-8').read()

def rep(s, old, new, name):
    if s.count(old) != 1:
        print('NOT FOUND/AMBIGUOUS:', name)
        sys.exit(1)
    return s.replace(old, new, 1)

if 'band_roles' in rd('lib/netinfo.dart'):
    print('already patched'); sys.exit(0)

# ---------------- netinfo.dart: أساسي وثانوي ----------------
n = rd('lib/netinfo.dart')
n = rep(n, "import 'dart:math';\n", "import 'dart:convert';\nimport 'dart:math';\n", 'imp convert')
n = rep(n, "import 'package:flutter/material.dart';\n",
        "import 'package:flutter/material.dart';\nimport 'package:flutter_secure_storage/flutter_secure_storage.dart';\n", 'imp storage')
n = rep(n, "const Color _green = Color(0xFF39D353);\n",
        "const Color _green = Color(0xFF39D353);\nconst FlutterSecureStorage _store = FlutterSecureStorage();\n", 'store const')
n = rep(n, "  String bestPingLabel = '', bestPingMask = '', bestSpeedLabel = '', bestSpeedMask = '';\n",
        "  String bestPingLabel = '', bestPingMask = '', bestSpeedLabel = '', bestSpeedMask = '';\n  final Map<int, int> roles = <int, int>{};\n  String roleMsg = '';\n", 'fields')
n = rep(n, "    super.initState();\n    _refresh();\n", "    super.initState();\n    _refresh();\n    _loadRoles();\n", 'init')
n = rep(n, "  // ---------- واجهة ----------\n", r'''  // ---------- أساسي وثانوي ----------
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
''', 'roles methods')
n = rep(n, "            _quickCard(),\n            _deepCard(),\n", "            _quickCard(),\n            _rolesCard(),\n            _deepCard(),\n", 'build')
open('lib/netinfo.dart', 'w', encoding='utf-8').write(n)

# ---------------- pubg.dart: فحوصات الواي فاي للجوال فقط ----------------
p = rd('lib/pubg.dart')
p = rep(p, "      try {\n        switch (t.id) {\n", """      if (!Platform.isAndroid && (t.id == 'link' || t.id == 'chan')) {
        _fin(t.id, St.warn, 'متاح على الجوال فقط', <String>['قياس إشارة الواي فاي والقنوات يحتاج أندرويد.']);
        continue;
      }
      try {
        switch (t.id) {
""", 'pubg platform')
open('lib/pubg.dart', 'w', encoding='utf-8').write(p)

# ---------------- main.dart: عرض مناسب لشاشة الكمبيوتر ----------------
m = rd('lib/main.dart')
m = rep(m, "builder: (c, w) => Directionality(textDirection: TextDirection.rtl, child: w!),",
        "builder: (c, w) => Directionality(\n            textDirection: TextDirection.rtl,\n            child: ColoredBox(\n                color: kBg,\n                child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 640), child: w!)))),", 'builder')
open('lib/main.dart', 'w', encoding='utf-8').write(m)

# ---------------- workflow ويندوز (منفصل عن الأندرويد) ----------------
os.makedirs('.github/workflows', exist_ok=True)
open('.github/workflows/build-windows.yml', 'w', encoding='utf-8').write('''name: build-windows
on: workflow_dispatch
jobs:
  win:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - name: Create Windows project and apply sources
        shell: bash
        run: |
          flutter create --platforms=windows --project-name router_panel app_win
          cp -f pubspec.yaml app_win/pubspec.yaml
          rm -f app_win/lib/main.dart
          cp -r lib/. app_win/lib/
      - name: Build
        working-directory: app_win
        shell: bash
        run: |
          flutter pub get
          flutter build windows --release
      - name: Zip
        shell: pwsh
        run: Compress-Archive -Path app_win/build/windows/x64/runner/Release/* -DestinationPath router-panel-windows.zip
      - uses: actions/upload-artifact@v4
        with:
          name: router-panel-windows
          path: router-panel-windows.zip
''')
print('patched OK')
