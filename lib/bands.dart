/// أدوات النطاقات بـ BigInt: نطاقات NR توصل إلى 261 فما تكفي int (64 بت).

/// نطاقات 4G/5G من قناع hex (البت i = النطاق i+1).
List<int> bandsOfHex(String hex) {
  final s = hex.trim();
  if (s.isEmpty || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(s)) return <int>[];
  final b = BigInt.parse(s, radix: 16);
  return <int>[
    for (var i = 0; i < b.bitLength; i++)
      if (((b >> i) & BigInt.one) == BigInt.one) i + 1
  ];
}

String maskOfBands(Iterable<int> bands) {
  var b = BigInt.zero;
  for (final x in bands) {
    b |= BigInt.one << (x - 1);
  }
  return b.toRadixString(16);
}

String maskOneBand(int band) => maskOfBands(<int>[band]);

bool _isNrList(String s) => RegExp(r'n\d', caseSensitive: false).hasMatch(s);

/// يقرأ قيمة نطاقات الراوتر بصيغتها الفعلية: قناع hex أو قائمة مثل n78,n41.
Set<int> decodeBands(String v) {
  final s = v.trim();
  if (s.isEmpty) return <int>{};
  if (_isNrList(s)) {
    return <int>{for (final m in RegExp(r'n(\d+)', caseSensitive: false).allMatches(s)) int.parse(m[1]!)};
  }
  return bandsOfHex(s).toSet();
}

/// يكتب النطاقات بنفس صيغة القيمة الحالية في الراوتر ([like]).
String encodeBands(Set<int> bands, String like) {
  if (_isNrList(like) || like.contains(',')) {
    final l = bands.toList()..sort();
    return l.map((b) => 'n$b').join(',');
  }
  var h = maskOfBands(bands);
  if (like.isNotEmpty && RegExp(r'^[0-9a-fA-F]+$').hasMatch(like) && like.length > h.length) {
    h = h.padLeft(like.length, '0');
  }
  return RegExp(r'[A-F]').hasMatch(like) ? h.toUpperCase() : h;
}

bool sameBands(String a, String b) {
  final x = decodeBands(a), y = decodeBands(b);
  return x.length == y.length && x.containsAll(y);
}

/// اسم حقل نطاقات 5G في net/net-mode، يؤخذ من رد الراوتر الفعلي فقط (بدون تخمين).
String? findNrKey(Map<String, String> nm) {
  for (final e in nm.entries) {
    final k = e.key.toLowerCase();
    if (k.contains('nr') && k.contains('band')) return e.key;
  }
  for (final e in nm.entries) {
    final k = e.key.toLowerCase();
    if (k.contains('nr') && (RegExp(r'^[0-9a-fA-F]+$').hasMatch(e.value) || _isNrList(e.value))) return e.key;
  }
  for (final e in nm.entries) {
    final k = e.key.toLowerCase();
    if (RegExp(r'(nsa|sa|5g)').hasMatch(k) && k.contains('band')) return e.key;
  }
  return null;
}

const Set<int> _validNr = <int>{
  1, 2, 3, 5, 7, 8, 12, 13, 14, 18, 20, 25, 26, 28, 29, 30, 34, 38, 39, 40, 41, 48, 50, 51, 53, 65, 66,
  70, 71, 74, 75, 76, 77, 78, 79, 80, 81, 82, 83, 84, 86, 89, 90, 91, 92, 93, 94, 95, 257, 258, 259, 260, 261
};

/// نطاقات 5G المدعومة كما يذكرها الراوتر في net/net-mode-list (N78 أو n78).
List<int> parseNrSupported(String listXml) {
  final s = <int>{
    for (final m in RegExp(r'(?:^|[^a-zA-Z0-9])[nN](\d{1,3})(?!\d)').allMatches(listXml))
      if (_validNr.contains(int.parse(m[1]!))) int.parse(m[1]!)
  };
  return s.toList()..sort();
}

bool hasNrSignal(Map<String, String> s) {
  final v = s['nrrsrp'] ?? '';
  return v.isNotEmpty && v != 'None' && v != '--';
}

/// جدول نطاقات NR: [رقم النطاق، بداية DL، نهاية DL] بالميجاهرتز (3GPP).
const List<List<int>> _nrDlRanges = <List<int>>[
  [1, 2110, 2170], [3, 1805, 1880], [5, 869, 894], [7, 2620, 2690], [8, 925, 960],
  [20, 791, 821], [28, 758, 803], [38, 2570, 2620], [40, 2300, 2400], [41, 2496, 2690],
  [66, 2110, 2200], [71, 617, 652], [77, 3300, 4200], [78, 3300, 3800], [79, 4400, 5000],
];

int? _nrBandOfMhz(double mhz) {
  int? best;
  var w = 1 << 30;
  for (final x in _nrDlRanges) {
    if (mhz >= x[1] && mhz <= x[2] && (x[2] - x[1]) < w) {
      w = x[2] - x[1];
      best = x[0];
    }
  }
  return best;
}

/// يحوّل NR-ARFCN إلى ميجاهرتز (3GPP TS 38.104).
double? _arfcnToMhz(int n) {
  if (n < 0) return null;
  if (n < 600000) return n * 0.005;
  if (n < 2016667) return 3000 + (n - 600000) * 0.015;
  if (n <= 3279165) return 24250.08 + (n - 2016667) * 0.06;
  return null;
}

/// رقم نطاق 5G المتصل من device/signal: أولًا حقل nrband، وإن لم يوجد يُستنتج من nrdlfreq
/// (قد يكون ميجاهرتز أو كيلوهرتز أو رقم NR-ARFCN، فنجرّب كل الاحتمالات ونأخذ أول ما يطابق نطاقًا).
int? nrBandNum(Map<String, String> s) {
  for (final k in <String>['nrband', 'nr_band', 'nrbandname']) {
    final m = RegExp(r'\d+').firstMatch(s[k] ?? '');
    if (m != null) return int.parse(m[0]!);
  }
  for (final k in <String>['nrdlfreq', 'nrdlfrequency', 'nr_dl_freq']) {
    final raw = (s[k] ?? '').trim();
    final m = RegExp(r'\d+(\.\d+)?').firstMatch(raw);
    if (m == null) continue;
    final v = double.parse(m[0]!);
    final t = raw.toLowerCase();
    final cands = <double>[];
    if (t.contains('ghz')) {
      cands.add(v * 1000);
    } else if (t.contains('khz')) {
      cands.add(v / 1000);
    } else if (t.contains('mhz')) {
      cands.add(v);
    } else {
      cands.add(v); // ميجاهرتز
      cands.add(v / 1000); // كيلوهرتز
      final a = _arfcnToMhz(v.toInt());
      if (a != null) cands.add(a); // NR-ARFCN
    }
    for (final c in cands) {
      final b = _nrBandOfMhz(c);
      if (b != null) return b;
    }
  }
  return null;
}

/// ترددات النطاقات بالميجاهرتز (مرجع 3GPP) لعرضها بجانب اسم النطاق.
const Map<int, String> kLteMhz = <int, String>{
  1: '2100', 2: '1900', 3: '1800', 4: '1700', 5: '850', 7: '2600', 8: '900', 12: '700', 13: '700',
  14: '700', 17: '700', 18: '800', 19: '800', 20: '800', 25: '1900', 26: '850', 28: '700', 29: '700',
  32: '1500', 34: '2000', 38: '2600', 39: '1900', 40: '2300', 41: '2500', 42: '3500', 43: '3700',
};

const Map<int, String> kNrMhz = <int, String>{
  1: '2100', 2: '1900', 3: '1800', 5: '850', 7: '2600', 8: '900', 12: '700', 20: '800', 25: '1900',
  28: '700', 38: '2600', 40: '2300', 41: '2500', 66: '2100', 71: '600', 77: '3700', 78: '3500',
  79: '4700', 257: '28000', 258: '26000', 260: '39000', 261: '28000',
};
