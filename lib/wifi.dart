import 'package:flutter/services.dart';

const MethodChannel _ch = MethodChannel('router_panel/wifi');

int _i(Object? v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);

/// رقم القناة من التردد بالميجاهرتز.
int channelOf(int f) {
  if (f == 2484) return 14;
  if (f >= 2412 && f < 2484) return (f - 2407) ~/ 5;
  if (f >= 5955) return (f - 5950) ~/ 5;
  if (f >= 4900) return (f - 5000) ~/ 5;
  return 0;
}

String bandNameOf(int f) => f >= 5925 ? '6GHz' : (f >= 4900 ? '5GHz' : (f > 0 ? '2.4GHz' : '-'));

/// حالة اتصال الجوال بالواي فاي الآن.
class WifiLink {
  final int rssi, speed, freq, rx, tx, std;
  final String ssid, bssid;
  WifiLink(this.rssi, this.speed, this.freq, this.rx, this.tx, this.std, this.ssid, this.bssid);
  int get channel => channelOf(freq);
  String get bandName => bandNameOf(freq);
  String get stdName {
    switch (std) {
      case 1:
        return 'قديم (a/b/g)';
      case 4:
        return 'Wi-Fi 4';
      case 5:
        return 'Wi-Fi 5';
      case 6:
        return 'Wi-Fi 6';
      case 8:
        return 'Wi-Fi 7';
      default:
        return '';
    }
  }
}

/// شبكة مجاورة من نتيجة المسح.
class Ap {
  final String ssid, bssid;
  final int level, freq, width;
  Ap(this.ssid, this.bssid, this.level, this.freq, this.width);
  int get channel => channelOf(freq);
}

/// يطلب إذن الموقع (يلزمه مسح الشبكات). [ask] false = يتحقق فقط بدون طلب.
Future<bool> wifiPerm({bool ask = true}) async {
  try {
    return (await _ch.invokeMethod<bool>('perm', <String, dynamic>{'ask': ask})) ?? false;
  } catch (_) {
    return false;
  }
}

Future<WifiLink?> wifiLink() async {
  try {
    final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('info');
    if (m == null) return null;
    return WifiLink(_i(m['rssi']), _i(m['speed']), _i(m['freq']), _i(m['rx']), _i(m['tx']),
        _i(m['std']), '${m['ssid'] ?? ''}', '${m['bssid'] ?? ''}');
  } catch (_) {
    return null;
  }
}

/// يمسح الشبكات المجاورة (أندرويد يحدّ عدد المسحات، فقد ترجع نتائج قديمة قليلًا).
Future<List<Ap>> wifiScan() async {
  try {
    await _ch.invokeMethod<bool>('startScan');
  } catch (_) {}
  await Future<void>.delayed(const Duration(seconds: 4));
  try {
    final l = await _ch.invokeMethod<List<dynamic>>('results');
    if (l == null) return <Ap>[];
    final out = <Ap>[];
    for (final e in l) {
      final m = e as Map<dynamic, dynamic>;
      out.add(Ap('${m['ssid'] ?? ''}', '${m['bssid'] ?? ''}', _i(m['level']), _i(m['freq']), _i(m['width'])));
    }
    return out;
  } catch (_) {
    return <Ap>[];
  }
}
