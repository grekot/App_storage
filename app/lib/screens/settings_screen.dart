import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../domain/versions.dart';
import '../services/catalog_controller.dart';
import '../widgets/app_actions.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.controller});

  final CatalogController controller;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _notify;

  CatalogController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.notifications.isEnabled().then((v) {
      if (mounted) setState(() => _notify = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final self = c.selfEntry;
        final selfStatus = self?.status;
        return Scaffold(
          appBar: AppBar(title: const Text('Ustawienia')),
          body: ListView(children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(c.repo.email),
              subtitle: const Text('Konto wspólne z aplikacjami Zakupy i Powrót'),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('Powiadomienia o nowych wersjach'),
              value: _notify ?? true,
              onChanged: _notify == null
                  ? null
                  : (v) async {
                      setState(() => _notify = v);
                      await c.notifications.setEnabled(v, [
                        ...c.entries.map((e) => e.packageName),
                        if (self != null) self.packageName,
                      ]);
                    },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.storefront_outlined),
              title: Text('Sklep ${self?.installed?.versionName ?? ''}'),
              subtitle: Text(switch (selfStatus) {
                AppStatus.updateAvailable => 'Dostępna wersja ${self?.release?.versionName}',
                AppStatus.upToDate || AppStatus.newerInstalled => 'Aktualny',
                _ => self?.releaseError ?? 'Sprawdzam…',
              }),
              trailing: self != null && selfStatus == AppStatus.updateAvailable
                  ? AppActionButton(controller: c, entry: self)
                  : null,
            ),
            if (c.storeSigner != null)
              ListTile(
                leading: const Icon(Icons.fingerprint),
                title: const Text('Klucz podpisu sklepu (SHA-256)'),
                subtitle: Text(c.storeSigner!, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: c.storeSigner!));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Skopiowano')));
                },
              ),
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('Instrukcja i link do instalacji sklepu'),
              subtitle: const Text(StoreConfig.homePage),
              onTap: () => launchUrl(Uri.parse(StoreConfig.homePage), mode: LaunchMode.externalApplication),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Wyloguj'),
              onTap: () async {
                Navigator.of(context).popUntil((r) => r.isFirst);
                await FirebaseAuth.instance.signOut();
              },
            ),
          ]),
        );
      },
    );
  }
}
