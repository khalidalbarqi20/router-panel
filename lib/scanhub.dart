import 'package:flutter/material.dart';
import 'download.dart';
import 'game.dart';
import 'kisignals.dart';
import 'netinfo.dart';
import 'nrtest.dart';
import 'pubg.dart';

/// صفحة فحص الشبكة والنطاقات: كل أدوات فحص الترددات والشبكة في مكان واحد.
/// (تعديل النطاقات وقفلها في صفحة «النطاقات» فقط.)
class ScanHub extends StatelessWidget {
  final GameCtl ctl;
  final Future<String> Function(String) rd;
  final Future<String> Function(String, String) wr;
  final Future<void> Function() relogin;
  const ScanHub({super.key, required this.ctl, required this.rd, required this.wr, required this.relogin});

  Widget _tile(BuildContext context, IconData icon, String title, String sub, Widget page) => Card(
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: ListTile(
          leading: Icon(icon, size: 30),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(sub),
          trailing: const Icon(Icons.chevron_left),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (c) => page)),
        ),
      );

  Widget _head(String t) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4, right: 4),
      child: Text(t, style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF39D353))));

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('فحص الشبكة والنطاقات')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          _head('فحص الترددات والشبكة'),
          _tile(context, Icons.cell_tower, 'الشبكة والنطاقات',
              'الأبراج، تجميع النطاقات +، الأجهزة المتصلة، اختبار قصير وفحص شامل', NetInfoPage(ctl: ctl)),
          _tile(context, Icons.compare_arrows, 'إشارات الترددات',
              'قارن SINR وRSRP وRSRQ لكل تردد، وقياس نطاقات 4G واحدًا واحدًا',
              KiSignals(rd: rd, wr: wr, relogin: relogin)),
          _tile(context, Icons.hub, 'اختبار نطاقات 5G',
              'يجرّب كل نطاق 5G لحاله ويقيس إشارته ثم يرجّع إعدادك', NrTestPage(ctl: ctl)),
          _tile(context, Icons.wifi_find, 'فحص الواي فاي والقنوات',
              'فحص الواي فاي والقنوات والبنق، كل فحص لحاله أو الكل', PubgPage(ctl: ctl)),
          _head('أوضاع التحسين (تفحص النطاقات وتطبّق الأفضل)'),
          _tile(context, Icons.sports_esports, 'وضع الألعاب', 'أقل بنق وتذبذب وفقد حزم (فورتنايت)', GamePage(ctl: ctl)),
          _tile(context, Icons.download, 'وضع التنزيل',
              'أسرع سرعة تنزيل للبرامج والألعاب، ويطبّق الأفضل تلقائيًا', DownloadPage(ctl: ctl)),
        ]),
      );
}
