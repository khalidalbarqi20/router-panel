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

/// رقم نطاق 5G المتصل من device/signal (nrband).
int? nrBandNum(Map<String, String> s) {
  for (final k in <String>['nrband', 'nr_band', 'nrbandname']) {
    final m = RegExp(r'\d+').firstMatch(s[k] ?? '');
    if (m != null) return int.parse(m[0]!);
  }
  return null;
}
