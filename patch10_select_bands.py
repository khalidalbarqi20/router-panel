import sys, os

def rd(p):
    return open(p, encoding='utf-8').read()

def wr(p, s):
    open(p, 'w', encoding='utf-8').write(s)

def rep(s, old, new, name):
    if s.count(old) != 1:
        print('NOT FOUND/AMBIGUOUS:', name)
        sys.exit(1)
    return s.replace(old, new, 1)

if not os.path.exists('lib/netinfo.dart'):
    print('شغّل الأمر من مجلد المشروع'); sys.exit(1)
n = rd('lib/netinfo.dart')
if 'final Set<int> sel = <int>{};' in n:
    print('already patched'); sys.exit(0)

n = rep(n, "  final Map<int, int> roles = <int, int>{};\n",
        "  final Map<int, int> roles = <int, int>{};\n  final Set<int> sel = <int>{};\n", 'sel field')

# ---- الاختبار القصير: كل النطاقات أو المحدد فقط ----
n = rep(n, "  Future<void> _quickTest() async {\n    if (running || applying) return;\n    final bands = _bands;\n",
        "  Future<void> _quickTest({bool onlySel = false}) async {\n    if (running || applying) return;\n    final only = onlySel ? (<int>[...sel]..sort()) : null;\n    final bands = only ?? _bands;\n", 'quickTest head')
n = rep(n, "      await _quickRun();\n    } catch (e) {", "      await _quickRun(only: only);\n    } catch (e) {", 'quickTest call')
n = rep(n, "  Future<bool> _quickRun() async {", "  Future<bool> _quickRun({List<int>? only}) async {", 'quickRun sig')
n = rep(n, "      bands: _bands,\n      probe: ctl.probe,", "      bands: only ?? _bands,\n      probe: ctl.probe,", 'quickRun bands')
n = rep(n, "    gQuick = pr;\n    gQuickAt = DateTime.now();\n",
        """    if (only == null) {
      gQuick = pr;
      gQuickAt = DateTime.now();
    } else {
      // دمج نتيجة النطاقات المحددة مع النتائج السابقة بدون مسحها
      gQuick = <BandProbe>[...gQuick.where((p) => !only.contains(p.band)), ...pr];
      gQuickAt ??= DateTime.now();
    }
""", 'quickRun merge')

# ---- الفحص الشامل: كل الشغّالة أو المحدد فقط ----
n = rep(n, "  Future<void> _deepTest() async {\n    if (running || applying) return;\n",
        "  Future<void> _deepTest({bool onlySel = false}) async {\n    if (running || applying) return;\n    final only = onlySel ? (<int>[...sel]..sort()) : null;\n", 'deepTest head')
n = rep(n, "        stale\n            ? 'ما فيه نتيجة",
        "        only != null\n            ? 'يقيس النطاقات المحددة (${only.map((b) => 'B$b').join(' ')}) فقط (بنق وتذبذب وفقد وسرعة تنزيل) ثم المحددة معًا. اللي ما انفحص منها قبل يفحصه أولًا ويتخطى اللي ما يشتغل. والإنترنت ينقطع أثناءه.'\n            : stale\n            ? 'ما فيه نتيجة", 'deepTest text')
n = rep(n, "      await _deepRun(stale);", "      await _deepRun(stale, only: only);", 'deepRun call')
n = rep(n, "  Future<void> _deepRun(bool stale) async {\n    final ctl = widget.ctl;\n    if (stale) {\n      if (!await _quickRun() || cancel) return;\n    } else if (",
        """  Future<void> _deepRun(bool stale, {List<int>? only}) async {
    final ctl = widget.ctl;
    if (only != null) {
      final fresh = gQuickAt != null && DateTime.now().difference(gQuickAt!).inMinutes <= 30;
      final need = <int>[for (final b in only) if (!(fresh && gQuick.any((p) => p.band == b))) b];
      if (need.isNotEmpty) {
        log('يفحص أولًا النطاقات اللي ما انفحصت: ${need.map((b) => 'B$b').join(' ')}');
        if (!await _quickRun(only: need) || cancel) return;
      } else if (!await ensureInternet(ctl, log, stop, () async => mounted && await askRepair(context))) {
        return;
      }
    } else if (stale) {
      if (!await _quickRun() || cancel) return;
    } else if (""", 'deepRun head')
n = rep(n, "    final work = workingBands(gQuick, max: 40);\n",
        """    final allWork = workingBands(gQuick, max: 40);
    final work = only == null ? allWork : <int>[for (final b in allWork) if (only.contains(b)) b];
    if (only != null) {
      final skipped = <int>[for (final b in only) if (!work.contains(b)) b];
      if (skipped.isNotEmpty) log('تخطّيت ${skipped.map((b) => 'B$b').join(' ')}: ما اشتغلت في الاختبار القصير.');
    }
""", 'work')
n = rep(n, "      log('ما فيه نطاق شغّال حسب الاختبار القصير.');", "      log(only == null ? 'ما فيه نطاق شغّال حسب الاختبار القصير.' : 'ما فيه نطاق شغّال بين النطاقات المحددة.');", 'no work msg')
n = rep(n, "cands.add(DRow('كل الشغّالة معًا', _maskOf(work)));", "cands.add(DRow(only == null ? 'كل الشغّالة معًا' : 'المحددة معًا', _maskOf(work)));", 'together label')

# ---- واجهة اختيار النطاقات ----
n = rep(n, "            _quickCard(),\n            _rolesCard(),", "            _quickCard(),\n            _selCard(),\n            _rolesCard(),", 'build')
n = rep(n, "  Widget _deepCard() {\n", """  Widget _selCard() {
    final bands = _bands;
    final okSet = <int>{for (final p in gQuick) if (p.res.ok) p.band};
    final badSet = <int>{for (final p in gQuick) if (!p.res.ok) p.band};
    final off = running || applying;
    final cnt = sel.length;
    return _card('اختبار نطاقات محددة', [
      const Text(
          'اختر نطاق واحد أو أكثر واختبرهم بدون ما تضيّع وقت على النطاقات اللي ما تشتغل. علامة ✓ تعني شغّال و ✗ ما اشتغل حسب آخر اختبار قصير.',
          style: TextStyle(color: Colors.white54, fontSize: 13)),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 4, children: [
        for (final b in bands)
          FilterChip(
            label: Text('B$b'),
            selected: sel.contains(b),
            showCheckmark: false,
            avatar: okSet.contains(b)
                ? const Icon(Icons.check_circle, size: 16, color: _green)
                : (badSet.contains(b) ? const Icon(Icons.cancel, size: 16, color: Colors.redAccent) : null),
            onSelected: off
                ? null
                : (v) => setState(() {
                      if (v) {
                        sel.add(b);
                      } else {
                        sel.remove(b);
                      }
                    }),
          ),
      ]),
      const SizedBox(height: 4),
      Wrap(spacing: 8, children: [
        TextButton(
            onPressed: off
                ? null
                : () => setState(() {
                      sel
                        ..clear()
                        ..addAll(bands);
                    }),
            child: const Text('الكل')),
        TextButton(
            onPressed: off || okSet.isEmpty
                ? null
                : () => setState(() {
                      sel
                        ..clear()
                        ..addAll(okSet.where(bands.contains));
                    }),
            child: const Text('الشغّالة فقط')),
        TextButton(onPressed: off || sel.isEmpty ? null : () => setState(sel.clear), child: const Text('مسح')),
      ]),
      const SizedBox(height: 6),
      FilledButton.tonal(
        onPressed: off || cnt == 0 ? null : () => _quickTest(onlySel: true),
        child: Text('اختبار قصير للمحدد ($cnt)'),
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: off || cnt == 0 ? null : () => _deepTest(onlySel: true),
        child: Text('فحص شامل للمحدد ($cnt)'),
      ),
    ]);
  }

  Widget _deepCard() {
""", 'selCard')
wr('lib/netinfo.dart', n)
print('تم: patch10 (اختيار نطاقات للاختبار القصير والفحص الشامل)')
