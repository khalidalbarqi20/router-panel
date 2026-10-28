import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// إحصاءات سلسلة قياسات: القيم الناجحة بالترتيب الزمني + عدد المرسَل.
class PingStats {
  final int sent;
  final List<double> ok;
  PingStats(this.sent, this.ok);

  int get lost => sent - ok.length;
  double get lossPct => sent == 0 ? 0.0 : 100.0 * lost / sent;
  double? get p50 => _pct(0.5);
  double? get p95 => _pct(0.95);

  /// التذبذب: متوسط الفرق المطلق بين قياسين متتاليين.
  double get jitter {
    if (ok.length < 2) return 0.0;
    double s = 0.0;
    for (var i = 1; i < ok.length; i++) {
      s += (ok[i] - ok[i - 1]).abs();
    }
    return s / (ok.length - 1);
  }

  double? _pct(double q) {
    if (ok.isEmpty) return null;
    final s = List<double>.from(ok)..sort();
    final i = ((s.length - 1) * q).round();
    return s[i];
  }
}

/// تشغيل أمر ping الموجود في أندرويد، ومعه بديل TCP إذا لم يتوفر.
class PingEngine {
  static String bin = 'ping';
  static List<String> tail = <String>['-c', '1'];
  static bool tcpOnly = true;

  static Future<void> detect(String ip) async {
    tcpOnly = true;
    final bins = <String>['ping', '/system/bin/ping'];
    final variants = <List<String>>[
      <String>['-c', '1', '-W', '2'],
      <String>['-c', '1'],
    ];
    for (final b in bins) {
      for (final v in variants) {
        final r = await _run(b, v, ip);
        if (r != null) {
          bin = b;
          tail = v;
          tcpOnly = false;
          return;
        }
      }
    }
  }

  static Future<double?> _run(String b, List<String> v, String ip) async {
    try {
      final p = await Process.start(b, <String>[...v, ip]);
      final out = p.stdout.transform(systemEncoding.decoder).join();
      p.stderr.drain<void>();
      await p.exitCode.timeout(const Duration(seconds: 5), onTimeout: () {
        p.kill();
        return -9;
      });
      final text = await out.timeout(const Duration(seconds: 2), onTimeout: () => '');
      final m = RegExp(r'time[=<]\s*([0-9]+(?:\.[0-9]+)?)').firstMatch(text);
      if (m == null) return null;
      return double.parse(m[1]!);
    } catch (_) {
      return null;
    }
  }

  static Future<double?> sample(String ip) => _run(bin, tail, ip);
}

class Pinger {
  final String host;
  final int tcpPort;
  InternetAddress? addr;
  Pinger(this.host, {this.tcpPort = 443});

  Future<bool> resolve() async {
    try {
      final l = await InternetAddress.lookup(host).timeout(const Duration(seconds: 6));
      InternetAddress? pick;
      for (final a in l) {
        if (a.type == InternetAddressType.IPv4) {
          pick = a;
          break;
        }
      }
      if (pick == null && l.isNotEmpty) pick = l.first;
      addr = pick;
      return pick != null;
    } catch (_) {
      return false;
    }
  }

  Future<double?> once() async {
    final a = addr;
    if (a == null) return null;
    if (!PingEngine.tcpOnly) return PingEngine.sample(a.address);
    return _tcp(a);
  }

  Future<double?> _tcp(InternetAddress a) async {
    final sw = Stopwatch()..start();
    try {
      final s = await Socket.connect(a, tcpPort, timeout: const Duration(seconds: 2));
      sw.stop();
      s.destroy();
      return sw.elapsedMicroseconds / 1000.0;
    } on SocketException catch (e) {
      sw.stop();
      // ECONNREFUSED = وصل رد الرفض من الطرف الثاني، فالزمن صالح كقياس.
      if (e.osError?.errorCode == 111) return sw.elapsedMicroseconds / 1000.0;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<PingStats> series(int n, {int gapMs = 150, bool Function()? stop}) async {
    final ok = <double>[];
    var sent = 0;
    for (var i = 0; i < n; i++) {
      if (stop != null && stop()) break;
      sent++;
      final v = await once();
      if (v != null) ok.add(v);
      await Future<void>.delayed(Duration(milliseconds: gapMs));
    }
    return PingStats(sent, ok);
  }
}

/// تحميل (تنزيل) لمدة محددة لإحداث ضغط على الخط. يرجع عدد البايتات المستلمة.
Future<int> loadDown(Duration d, bool Function() stop) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  final end = DateTime.now().add(d);
  var bytes = 0;
  try {
    while (DateTime.now().isBefore(end) && !stop()) {
      final req = await c.getUrl(Uri.parse('https://speed.cloudflare.com/__down?bytes=25000000'));
      final res = await req.close();
      await for (final chunk in res) {
        bytes += chunk.length;
        if (!DateTime.now().isBefore(end) || stop()) break;
      }
    }
  } catch (_) {
  } finally {
    c.close(force: true);
  }
  return bytes;
}

/// رفع لمدة محددة. يرجع عدد البايتات المرسلة.
Future<int> loadUp(Duration d, bool Function() stop) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  final end = DateTime.now().add(d);
  var bytes = 0;
  try {
    final req = await c.postUrl(Uri.parse('https://speed.cloudflare.com/__up'));
    req.headers.contentType = ContentType.binary;
    req.done.then<void>((_) {}, onError: (Object _) {});
    final buf = Uint8List(65536);
    while (DateTime.now().isBefore(end) && !stop()) {
      req.add(buf);
      await req.flush();
      bytes += buf.length;
    }
    c.close(force: true);
  } catch (_) {
    c.close(force: true);
  }
  return bytes;
}

/// مصادر ملفات اختبار التنزيل (يُجرَّب الأول ثم البدائل حتى يشتغل واحد).
class DownSrc {
  final String name, url;
  const DownSrc(this.name, this.url);
}

const List<DownSrc> kDownSrcs = <DownSrc>[
  DownSrc('Cloudflare', 'https://speed.cloudflare.com/__down?bytes=25000000'),
  DownSrc('CacheFly', 'https://cachefly.cachefly.net/100mb.test'),
  DownSrc('OVH', 'https://proof.ovh.net/files/100Mb.dat'),
  DownSrc('ThinkBroadband', 'http://ipv4.download.thinkbroadband.com/100MB.zip'),
];

/// الرابط المعتمد بعد اختيار المصدر.
String gDownUrl = 'https://speed.cloudflare.com/__down?bytes=25000000';

/// يجرّب رابطًا لمدة ثوانٍ قليلة: يرجع OK إذا نزل بيانات كافية، وإلا سبب الفشل.
Future<String> tryDownUrl(String url, bool Function() stop) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
  var bytes = 0;
  try {
    final req = await c.getUrl(Uri.parse(url)).timeout(const Duration(seconds: 8));
    final res = await req.close().timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) return 'HTTP ${res.statusCode}';
    final sw = Stopwatch()..start();
    await for (final chunk in res) {
      bytes += chunk.length;
      if (sw.elapsedMilliseconds > 3500 || stop()) break;
    }
    return bytes >= 150000 ? 'OK' : 'بيانات قليلة ($bytes بايت)';
  } catch (e) {
    return 'خطأ: ${e.runtimeType}';
  } finally {
    c.close(force: true);
  }
}

/// يختار أول مصدر يشتغل ويحفظه في gDownUrl. يرجع اسمه، أو نصًا فارغًا إن فشلت كلها.
Future<String> pickDownSource(void Function(String) log, bool Function() stop) async {
  for (final s in kDownSrcs) {
    if (stop()) break;
    final r = await tryDownUrl(s.url, stop);
    if (r == 'OK') {
      gDownUrl = s.url;
      log('مصدر التنزيل: ${s.name}');
      return s.name;
    }
    log('${s.name}: $r');
  }
  return '';
}

/// نتيجة قياس سرعة التنزيل: السرعة بالميجابت/ث وإجمالي البايتات وسبب الفشل إن وُجد.
class Tput {
  final double mbps;
  final int bytes;
  final String note;
  Tput(this.mbps, this.bytes, [this.note = '']);
}

/// يقيس سرعة التنزيل بعدة اتصالات متوازية، ويتجاهل أول [warm] ثانية (بداية بطيئة).
Future<Tput> measureDown(bool Function() stop, {int conns = 4, int secs = 8, int warm = 2}) async {
  final sw = Stopwatch()..start();
  final end = Duration(seconds: secs);
  final warmD = Duration(seconds: warm);
  var total = 0;
  var atWarm = -1;
  var warmMs = 0.0;
  var note = '';

  Future<void> worker() async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 6);
    try {
      while (sw.elapsed < end && !stop()) {
        final req = await c.getUrl(Uri.parse(gDownUrl));
        final res = await req.close();
        if (res.statusCode != 200) {
          if (note.isEmpty) note = 'HTTP ${res.statusCode}';
          break;
        }
        await for (final chunk in res) {
          total += chunk.length;
          if (atWarm < 0 && sw.elapsed >= warmD) {
            atWarm = total;
            warmMs = sw.elapsedMicroseconds / 1000.0;
          }
          if (sw.elapsed >= end || stop()) break;
        }
      }
    } catch (e) {
      if (note.isEmpty) note = 'خطأ: ${e.runtimeType}';
    } finally {
      c.close(force: true);
    }
  }

  await Future.wait(<Future<void>>[for (var i = 0; i < conns; i++) worker()]);
  sw.stop();
  final totalMs = sw.elapsedMicroseconds / 1000.0;
  var mbps = 0.0;
  if (atWarm >= 0 && totalMs > warmMs + 500) {
    mbps = (total - atWarm) * 8 / ((totalMs - warmMs) * 1000.0);
  } else if (total > 0 && totalMs > 0) {
    mbps = total * 8 / (totalMs * 1000.0);
  }
  return Tput(mbps, total, note);
}
