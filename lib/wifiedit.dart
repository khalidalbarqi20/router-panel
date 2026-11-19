import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const Color _wGreen = Color(0xFF39D353);

String _tagIn(String x, String t) => RegExp('<$t>([^<]*)</$t>').firstMatch(x)?[1] ?? '';

String? _errIn(String x) =>
    x.contains('<error>') ? (RegExp(r'<code>([^<]*)</code>').firstMatch(x)?[1] ?? '?') : null;

String _unesc(String v) => v
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

String _esc(String v) => v.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// يبدّل قيمة أول وسم بهذا الاسم (الاستبدال حرفي، فما يتأثر بالرموز مثل \$).
String _setTag(String x, String t, String v) {
  final re = RegExp('<$t>[^<]*</$t>');
  if (!re.hasMatch(x)) return x;
  return x.replaceFirstMapped(re, (m) => '<$t>${_esc(v)}</$t>');
}

/// محتوى رد الراوتر بدون غلاف response.
String _inner(String x) => RegExp(r'<response>(.*)</response>', dotAll: true).firstMatch(x)?[1] ?? x;

final RegExp _ssidBlock = RegExp(r'<Ssid>(.*?)</Ssid>', dotAll: true);

List<String> _blocks(String x) => <String>[for (final m in _ssidBlock.allMatches(x)) m[1]!];

String _mapBlock(String x, int pos, String Function(String) f) {
  var i = 0;
  return x.replaceAllMapped(_ssidBlock, (m) {
    final r = i == pos ? '<Ssid>${f(m[1]!)}</Ssid>' : m[0]!;
    i++;
    return r;
  });
}

String _restart(String inner, bool on) {
  if (inner.contains('<WifiRestart>')) return _setTag(inner, 'WifiRestart', on ? '1' : '0');
  return on ? '$inner<WifiRestart>1</WifiRestart>' : inner;
}

String _errText(String c) {
  switch (c) {
    case '100002':
      return 'هذا الأمر غير مدعوم في فيرموير الراوتر';
    case '100003':
      return 'ما عندك صلاحية (انتهت جلسة الدخول، ادخل من جديد)';
    case '100004':
      return 'الراوتر مشغول، أعد المحاولة بعد شوي';
    case '100006':
      return 'الراوتر رفض القيم المرسلة (اسم أو رمز غير مقبول)';
    case '125001':
    case '125002':
    case '125003':
      return 'انتهت جلسة الدخول، أعد الدخول';
    default:
      return 'رفض الراوتر الطلب';
  }
}

class _WNet {
  final int pos;
  String origSsid, origPass;
  final TextEditingController ssid, pass;
  final String auth;
  final bool enabled;
  bool show = false;
  _WNet(this.pos, this.origSsid, this.origPass, this.auth, this.enabled)
      : ssid = TextEditingController(text: origSsid),
        pass = TextEditingController(text: origPass);
  bool get open => auth.toUpperCase() == 'OPEN';
}

/// تعديل شبكات الواي فاي: تغيير اسم الشبكة (SSID) أو رمزها.
class WifiEditPage extends StatefulWidget {
  final Future<String> Function(String) rd;
  final Future<String> Function(String, String) wr;
  final Future<void> Function() relogin;
  const WifiEditPage({super.key, required this.rd, required this.wr, required this.relogin});

  @override
  State<WifiEditPage> createState() => _WifiEditState();
}

class _WifiEditState extends State<WifiEditPage> {
  bool busy = true;
  String msg = '';
  bool multi = false;
  String basicPath = 'wlan/basic-settings', secPath = 'wlan/security-settings';
  String basicXml = '', secXml = '';
  final List<_WNet> nets = <_WNet>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final n in nets) {
      n.ssid.dispose();
      n.pass.dispose();
    }
    super.dispose();
  }

  Future<String> _get(String p) async {
    try {
      final r = await widget.rd(p);
      if (_errIn(r) == '125002' || _errIn(r) == '125003' || _errIn(r) == '100003') {
        await widget.relogin();
        return await widget.rd(p);
      }
      return r;
    } catch (_) {
      await widget.relogin();
      return await widget.rd(p);
    }
  }

  Future<void> _load() async {
    if (mounted) setState(() => busy = true);
    try {
      var mb = '', ms = '';
      try {
        mb = await _get('wlan/multi-basic-settings');
      } catch (_) {}
      final isMulti = _errIn(mb) == null && _blocks(mb).isNotEmpty;
      String bx, sx = '';
      if (isMulti) {
        bx = mb;
        try {
          ms = await _get('wlan/multi-security-settings');
        } catch (_) {}
        sx = _errIn(ms) == null ? ms : '';
        basicPath = 'wlan/multi-basic-settings';
        secPath = 'wlan/multi-security-settings';
      } else {
        bx = await _get('wlan/basic-settings');
        try {
          sx = await _get('wlan/security-settings');
        } catch (_) {}
        basicPath = 'wlan/basic-settings';
        secPath = 'wlan/security-settings';
      }
      final e = _errIn(bx);
      if (e != null) {
        if (mounted) {
          setState(() {
            busy = false;
            msg = 'الراوتر ما أعطى إعدادات الواي فاي (كود $e): ${_errText(e)}.';
          });
        }
        return;
      }
      for (final n in nets) {
        n.ssid.dispose();
        n.pass.dispose();
      }
      nets.clear();
      if (isMulti) {
        final bb = _blocks(bx);
        final sb = _blocks(sx);
        for (var i = 0; i < bb.length; i++) {
          final idx = _tagIn(bb[i], 'Index');
          var sblk = '';
          for (final b in sb) {
            if (idx.isNotEmpty && _tagIn(b, 'Index') == idx) sblk = b;
          }
          if (sblk.isEmpty && i < sb.length) sblk = sb[i];
          nets.add(_WNet(i, _unesc(_tagIn(bb[i], 'WifiSsid')), _unesc(_tagIn(sblk, 'WifiWpapsk')),
              _tagIn(sblk, 'WifiAuthmode'), _tagIn(bb[i], 'WifiEnable') != '0'));
        }
      } else {
        nets.add(_WNet(0, _unesc(_tagIn(bx, 'WifiSsid')), _unesc(_tagIn(sx, 'WifiWpapsk')),
            _tagIn(sx, 'WifiAuthmode'), _tagIn(bx, 'WifiEnable') != '0'));
      }
      multi = isMulti;
      basicXml = bx;
      secXml = sx;
      if (mounted) setState(() => busy = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          msg = 'ما قدرت أقرأ إعدادات الواي فاي: $e';
        });
      }
    }
  }

  Future<bool> _ask(String t) async =>
      await showDialog<bool>(
          context: context,
          builder: (d) => AlertDialog(content: Text(t), actions: [
                TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('إلغاء')),
                FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('متأكد')),
              ])) ??
      false;

  Future<void> _alert(int kind, String title, List<String> lines) async {
    if (mounted) setState(() => msg = '$title\n${lines.join('\n')}');
    if (!mounted) return;
    final color = kind == 0 ? _wGreen : (kind == 1 ? Colors.orangeAccent : Colors.redAccent);
    final icon = kind == 0 ? Icons.check_circle : (kind == 1 ? Icons.warning_amber_rounded : Icons.cancel);
    await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
              title: Row(children: [
                Icon(icon, color: color, size: 30),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 18))),
              ]),
              content: SizedBox(
                  width: double.maxFinite,
                  child: SingleChildScrollView(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (final l in lines) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(l)),
                  ]))),
              actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('حسنًا'))],
            ));
  }

  /// يبني جسم الإرسال للأمان (الرمز) أو الأساسي (الاسم) مع تعديل الشبكة المختارة فقط.
  String _body(bool security, _WNet n, String ssid, String pass, bool restart) {
    final src = security ? secXml : basicXml;
    var inner = _inner(src);
    if (multi) {
      inner = _mapBlock(inner, n.pos, (b) {
        var r = b;
        if (security) {
          r = _setTag(r, 'WifiWpapsk', pass);
        } else {
          r = _setTag(r, 'WifiSsid', ssid);
        }
        return r;
      });
    } else {
      inner = security ? _setTag(inner, 'WifiWpapsk', pass) : _setTag(inner, 'WifiSsid', ssid);
    }
    return _restart(inner, restart);
  }

  Future<String> _send(String path, String body) async {
    try {
      await widget.relogin();
    } catch (_) {}
    try {
      return await widget.wr(path, body);
    } catch (_) {
      await widget.relogin();
      return await widget.wr(path, body);
    }
  }

  Future<void> _save(_WNet n) async {
    final newSsid = n.ssid.text.trim();
    final newPass = n.pass.text;
    final ssidChanged = newSsid != n.origSsid;
    final passChanged = !n.open && newPass != n.origPass;
    if (!ssidChanged && !passChanged) {
      await _alert(1, 'ما فيه تغيير', <String>['ما غيّرت الاسم ولا الرمز.']);
      return;
    }
    if (newSsid.isEmpty || utf8.encode(newSsid).length > 32) {
      await _alert(2, 'اسم الشبكة غير صالح', <String>['الاسم لازم يكون من حرف إلى 32 بايت (الحرف العربي يحسب بايتين).']);
      return;
    }
    if (passChanged && (newPass.length < 8 || newPass.length > 63)) {
      await _alert(2, 'الرمز غير صالح', <String>['رمز الواي فاي (WPA) لازم يكون من 8 إلى 63 حرف.']);
      return;
    }
    final what = <String>[if (ssidChanged) 'الاسم: $newSsid', if (passChanged) 'الرمز: تغيير'].join(' · ');
    if (!await _ask('تغيير الشبكة ($what)\n\n'
        'بعد التطبيق ينقطع الواي فاي عن كل الأجهزة (ومنها جوالك) لحظات، وتحتاج تتصل بالاسم والرمز الجديدين ثم تدخل التطبيق من جديد.\n\nمتأكد؟')) {
      return;
    }
    setState(() {
      busy = true;
      msg = 'جاري التطبيق...';
    });
    // نقرأ الإعدادات الحالية من جديد حتى لا نرسل قيم قديمة لشبكات ثانية.
    try {
      basicXml = await _get(basicPath);
      if (secXml.isNotEmpty) secXml = await _get(secPath);
    } catch (e) {
      if (mounted) setState(() => busy = false);
      await _alert(2, 'ما تم تغيير الشبكة', <String>['ما قدرت أقرأ إعدادات الراوتر الحالية قبل التعديل: $e']);
      return;
    }
    var kind = 0;
    var title = 'تم تغيير الشبكة';
    final lines = <String>[];
    try {
      String? bad;
      if (passChanged) {
        final r = await _send(secPath, _body(true, n, newSsid, newPass, !ssidChanged));
        final e = _errIn(r);
        if (e != null) bad = 'تغيير الرمز: رفض الراوتر (كود $e): ${_errText(e)}.';
      }
      if (bad == null && ssidChanged) {
        final r = await _send(basicPath, _body(false, n, newSsid, newPass, true));
        final e = _errIn(r);
        if (e != null) {
          bad = 'تغيير الاسم: رفض الراوتر (كود $e): ${_errText(e)}.';
          if (passChanged) bad = '$bad\nملاحظة: الرمز انرسل قبلها، فقد يكون تغيّر.';
        }
      }
      if (bad != null) {
        kind = 2;
        title = 'ما تم تغيير الشبكة';
        lines
          ..add(bad)
          ..add('جرّب زر التشخيص (الحشرة) في الأعلى وأرسل لي النتيجة إذا تكرر.');
      } else {
        lines.add('الراوتر قبل الطلب وبيعيد تشغيل الواي فاي.');
        await Future<void>.delayed(const Duration(seconds: 10));
        try {
          await widget.relogin();
          final bx = await _get(basicPath);
          final sx = passChanged ? await _get(secPath) : secXml;
          final bb = multi ? _blocks(bx) : <String>[bx];
          final sb = multi ? _blocks(sx) : <String>[sx];
          final gotSsid = _unesc(_tagIn(n.pos < bb.length ? bb[n.pos] : '', 'WifiSsid'));
          final gotPass = _unesc(_tagIn(n.pos < sb.length ? sb[n.pos] : '', 'WifiWpapsk'));
          final okS = !ssidChanged || gotSsid == newSsid;
          final okP = !passChanged || gotPass.isEmpty || gotPass == newPass;
          if (okS && okP) {
            if (ssidChanged) lines.add('الاسم الجديد انقرأ من الراوتر: $newSsid');
            if (passChanged) lines.add(gotPass.isEmpty ? 'الرمز انرسل (الراوتر ما يعرض الرمز للقراءة فما أقدر أتأكد منه).' : 'الرمز الجديد انقرأ من الراوتر.');
            lines.add('اتصل بالشبكة بالاسم والرمز الجديدين.');
          } else {
            kind = 2;
            title = 'الراوتر ما غيّر القيم';
            lines
              ..add('الراوتر رجّع OK لكن القراءة بعده تدل أن ${!okS ? 'الاسم' : 'الرمز'} ما تغيّر.')
              ..add('السبب المحتمل: الفيرموير يتجاهل هذا الحقل أو يحتاج إعادة تشغيل الراوتر لتطبيقه.')
              ..add('جرّب إعادة تشغيل الراوتر ثم افتح هذي الصفحة وتأكد.');
          }
        } catch (_) {
          kind = 1;
          title = 'انرسل التغيير، وانقطع الاتصال';
          lines
            ..add('ما قدرت أتأكد من النتيجة لأن الواي فاي انقطع (هذا طبيعي أثناء إعادة التشغيل).')
            ..add('اتصل بالاسم والرمز الجديدين، وادخل التطبيق من جديد، وافتح هذي الصفحة للتأكد.');
        }
      }
    } catch (e) {
      kind = 1;
      title = 'تعذّر إكمال العملية';
      lines
        ..add('$e')
        ..add('إذا انقطع الواي فاي فالأغلب أن التغيير انطبق، اتصل بالاسم والرمز الجديدين وتأكد.');
    }
    if (kind == 0) {
      n.origSsid = newSsid;
      n.origPass = newPass;
    }
    if (mounted) setState(() => busy = false);
    await _alert(kind, title, lines);
  }

  String _hide(String x) => x.replaceAllMapped(
      RegExp(r'<(WifiSsid|WifiWpapsk|WifiWepKey\d|WifiMac\w*)>[^<]*</', caseSensitive: false), (m) => '<${m[1]}>***</');

  Future<void> _diag() async {
    final b = StringBuffer();
    for (final p in <String>[basicPath, secPath]) {
      try {
        final x = await _get(p);
        b.writeln('## $p\n${_hide(x).length > 2500 ? _hide(x).substring(0, 2500) : _hide(x)}\n');
      } catch (e) {
        b.writeln('## $p خطأ: $e\n');
      }
    }
    final out = b.toString();
    if (!mounted) return;
    await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
              title: const Text('تشخيص الواي فاي'),
              content: SizedBox(
                  width: double.maxFinite,
                  child: SingleChildScrollView(
                      child: SelectableText(out, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 11)))),
              actions: [
                TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: out)), child: const Text('نسخ')),
                TextButton(onPressed: () => Navigator.pop(d), child: const Text('إغلاق')),
              ],
            ));
  }

  Widget _netCard(_WNet n) {
    final label = multi ? 'الشبكة ${n.pos + 1}' : 'شبكة الواي فاي';
    return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.wifi, color: _wGreen),
                const SizedBox(width: 8),
                Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
                if (!n.enabled)
                  const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text('(غير مفعّلة)', style: TextStyle(color: Colors.orangeAccent, fontSize: 12))),
              ]),
              const SizedBox(height: 10),
              TextField(
                  controller: n.ssid,
                  enabled: !busy,
                  decoration: const InputDecoration(labelText: 'اسم الشبكة (SSID)', border: OutlineInputBorder())),
              const SizedBox(height: 10),
              if (n.open)
                const Text('الشبكة مفتوحة بدون رمز.', style: TextStyle(color: Colors.white54))
              else
                TextField(
                    controller: n.pass,
                    enabled: !busy,
                    obscureText: !n.show,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                        labelText: 'رمز الشبكة',
                        helperText: n.origPass.isEmpty ? 'الراوتر ما يعرض الرمز الحالي. اكتب رمز جديد فقط إذا تبي تغيّره.' : null,
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                            icon: Icon(n.show ? Icons.visibility_off : Icons.visibility),
                            onPressed: () => setState(() => n.show = !n.show)))),
              const SizedBox(height: 12),
              FilledButton.icon(
                  onPressed: busy ? null : () => _save(n),
                  icon: const Icon(Icons.save),
                  label: const Text('حفظ التغيير')),
            ])));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تعديل شبكات الواي فاي'), actions: [
        IconButton(onPressed: busy ? null : _load, icon: const Icon(Icons.refresh), tooltip: 'تحديث'),
        IconButton(onPressed: busy ? null : _diag, icon: const Icon(Icons.bug_report), tooltip: 'تشخيص'),
      ]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (busy) const LinearProgressIndicator(),
        const Card(
            child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                    'تغيير الاسم أو الرمز يقطع الواي فاي عن كل الأجهزة لحظات (ومنها جوالك). بعدها اتصل بالاسم والرمز الجديدين وادخل التطبيق من جديد.',
                    style: TextStyle(color: Colors.orangeAccent, fontSize: 13)))),
        const SizedBox(height: 8),
        for (final n in nets) _netCard(n),
        if (!busy && nets.isEmpty && msg.isEmpty)
          const Padding(padding: EdgeInsets.all(16), child: Text('ما لقيت شبكات واي فاي في الراوتر.', textAlign: TextAlign.center)),
        if (msg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: SelectableText(msg)),
      ]),
    );
  }
}
