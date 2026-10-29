import 'package:flutter/material.dart';
import 'probe.dart';

const Color _kg = Color(0xFF39D353);

/// شعار KiFi: مستطيل أخضر مستدير بداخله الاسم.
class KifiBadge extends StatelessWidget {
  final double size;
  const KifiBadge({super.key, this.size = 32});

  @override
  Widget build(BuildContext context) => Container(
        width: size * 1.6,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: _kg, borderRadius: BorderRadius.circular(size * 0.28)),
        child: Text('KiFi',
            style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: size * 0.5, letterSpacing: 0.4)),
      );
}

/// عرض كبير مثل واجهة الراوتر: أعمدة الإشارة + نوع الشبكة (4G+) + الأبراج الحالية.
class SignalHero extends StatelessWidget {
  final Map<String, String> sig, st;
  const SignalHero({super.key, required this.sig, required this.st});

  static String _g(Map<String, String> m, List<String> ks) {
    for (final k in ks) {
      final v = m[k];
      if (v != null && v.isNotEmpty && v != '--') return v;
    }
    return '';
  }

  int _bars() {
    final i = int.tryParse(st['SignalIcon'] ?? '');
    if (i != null && i >= 0 && i <= 5) return i;
    final r = double.tryParse((sig['rsrp'] ?? '').replaceAll(RegExp(r'[^0-9.\-]'), ''));
    if (r == null) return 0;
    if (r >= -85) return 5;
    if (r >= -95) return 4;
    if (r >= -105) return 3;
    if (r >= -115) return 2;
    return 1;
  }

  String _type() {
    final nr = sig['nrrsrp'] ?? '';
    if (nr.isNotEmpty && nr != 'None') return '5G';
    switch (st['CurrentNetworkTypeEx'] ?? '') {
      case '1011':
        return '4G+';
      case '101':
        return '4G';
      case '46':
      case '45':
        return '3G+';
      case '41':
        return '3G';
      default:
        return _g(sig, <String>['band']).isEmpty ? '-' : '4G';
    }
  }

  int _nei() {
    final v = _g(sig, <String>['nei_cellid', 'neighbor_cellid']);
    if (v.isEmpty) return 0;
    return v.split(RegExp(r'[,;\s]+')).where((x) => x.isNotEmpty && x != '0' && x != '-').length;
  }

  @override
  Widget build(BuildContext context) {
    final bars = _bars();
    final ca = isCaMap(st, sig);
    final cell = _g(sig, <String>['cell_id']);
    final id = int.tryParse(cell);
    final band = _g(sig, <String>['band']);
    final nei = _nei();
    final connected = (st['ConnectionStatus'] ?? '901') == '901';
    final towerLine = !connected
        ? 'غير متصل بأي برج'
        : 'متصل بـ 1 برج${nei > 0 ? ' · $nei خلية مجاورة ظاهرة' : ''}';
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          Column(mainAxisSize: MainAxisSize.min, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (var i = 0; i < 5; i++)
                Container(
                  width: 12,
                  height: 16.0 + i * 11,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: i < bars ? _kg : Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
            ]),
            const SizedBox(height: 8),
            Text(_type(), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w300)),
          ]),
          const SizedBox(width: 20),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('الأبراج الحالية', style: TextStyle(color: Colors.white60, fontSize: 12)),
              Text(towerLine, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              if (band.isNotEmpty) Text('النطاق B$band${ca ? '  +  تجميع نطاقات' : ''}', style: const TextStyle(fontSize: 13)),
              if (cell.isNotEmpty)
                Text(
                  id != null && id > 255 ? 'برج ${id >> 8} · خلية ${id & 255}' : 'خلية $cell',
                  style: const TextStyle(fontSize: 13, color: Colors.white70),
                ),
            ]),
          ),
        ]),
      ),
    );
  }
}
