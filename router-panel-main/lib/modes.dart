import 'package:flutter/material.dart';
import 'download.dart';
import 'game.dart';

/// صفحة المودات: تجمع وضع الألعاب ووضع التنزيل.
class ModesHub extends StatelessWidget {
  final GameCtl ctl;
  const ModesHub({super.key, required this.ctl});

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

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('المودات')),
        body: ListView(padding: const EdgeInsets.all(12), children: [
          _tile(context, Icons.sports_esports, 'وضع الألعاب',
              'أقل بنق وتذبذب وفقد حزم (فورتنايت)', GamePage(ctl: ctl)),
          _tile(context, Icons.download, 'وضع التنزيل',
              'أسرع سرعة تنزيل للبرامج والألعاب، ويطبّق الأفضل تلقائيًا', DownloadPage(ctl: ctl)),
        ]),
      );
}
