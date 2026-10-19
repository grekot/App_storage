import 'package:flutter/material.dart';

import '../domain/versions.dart';
import '../services/catalog_controller.dart';
import '../widgets/app_actions.dart';
import '../widgets/app_icon.dart';
import 'admin/admin_screen.dart';
import 'admin/groups_screen.dart';
import 'app_details_screen.dart';
import 'join_screen.dart';
import 'settings_screen.dart';

/// Ekran główny: aplikacje z moich grup.
class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key, required this.controller});

  final CatalogController controller;

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> with WidgetsBindingObserver {
  bool? _canInstall;

  CatalogController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkPermission();
  }

  Future<void> _checkPermission() async {
    try {
      final ok = await c.installer.canInstall();
      if (mounted) setState(() => _canInstall = ok);
    } catch (_) {}
  }

  void _open(Widget screen) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final entries = c.entries;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Sklep rodzinny'),
            actions: [
              IconButton(
                tooltip: 'Sprawdź nowe wersje',
                onPressed: c.refreshing ? null : () => c.refresh(),
                icon: c.refreshing
                    ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
              ),
              PopupMenuButton<String>(
                onSelected: (v) => switch (v) {
                  'join' => _open(JoinScreen(controller: c)),
                  'admin' => _open(c.isAdmin ? AdminScreen(controller: c) : GroupsScreen(controller: c)),
                  _ => _open(SettingsScreen(controller: c)),
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'join', child: Text('Dołącz kodem zaproszenia')),
                  PopupMenuItem(value: 'admin', child: Text(c.isAdmin ? 'Zarządzanie' : 'Moje grupy')),
                  const PopupMenuItem(value: 'settings', child: Text('Ustawienia')),
                ],
              ),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () => c.refresh(),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                if (_selfUpdate() case final self?) _SelfUpdateBanner(controller: c, entry: self),
                if (_canInstall == false && entries.isNotEmpty)
                  MaterialBanner(
                    leading: const Icon(Icons.security_outlined),
                    content: const Text('Żeby instalować aplikacje, sklep potrzebuje jednorazowej zgody Androida.'),
                    actions: [
                      TextButton(
                        onPressed: () => showInstallPermissionDialog(context, c),
                        child: const Text('Pokaż jak'),
                      ),
                    ],
                  ),
                if (!c.groupsLoaded)
                  const Padding(padding: EdgeInsets.all(48), child: Center(child: CircularProgressIndicator()))
                else if (c.groupsError != null)
                  _Empty(icon: Icons.cloud_off, text: 'Nie udało się wczytać grup.\n${c.groupsError}')
                else if (c.groups.isEmpty)
                  _NoGroup(controller: c, onJoin: () => _open(JoinScreen(controller: c)))
                else if (entries.isEmpty)
                  _Empty(
                    icon: Icons.apps_outlined,
                    text: c.isAdmin
                        ? 'Nie ma jeszcze aplikacji w Twoich grupach. Przypisz je w menu: Zarządzanie.'
                        : 'Nie ma jeszcze aplikacji w Twoich grupach.',
                  )
                else ...[
                  if (c.updatesCount > 0)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Text(
                        c.updatesCount == 1 ? '1 aktualizacja' : 'Aktualizacje: ${c.updatesCount}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                  for (final e in entries) _AppTile(controller: c, entry: e, onTap: () => _openDetails(e)),
                  const SizedBox(height: 24),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  CatalogEntry? _selfUpdate() {
    final s = c.selfEntry;
    if (s == null) return null;
    final st = s.status;
    return st == AppStatus.updateAvailable || s.task != null ? s : null;
  }

  void _openDetails(CatalogEntry e) => _open(AppDetailsScreen(controller: c, packageName: e.packageName));
}

class _AppTile extends StatelessWidget {
  const _AppTile({required this.controller, required this.entry, required this.onTap});

  final CatalogController controller;
  final CatalogEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = entry.release;
    final inst = entry.installed;
    final String subtitle;
    switch (entry.status) {
      case AppStatus.updateAvailable:
      case AppStatus.needsReinstall:
        subtitle = '${inst?.versionName ?? '?'} → ${r?.versionName ?? '?'}';
      case AppStatus.upToDate:
      case AppStatus.newerInstalled:
        subtitle = 'Zainstalowana ${inst?.versionName ?? ''}';
      case AppStatus.notInstalled:
        subtitle = [r?.versionName, formatSize(r?.size ?? 0)].where((s) => s != null && s.isNotEmpty).join(' · ');
      case AppStatus.unavailable:
        subtitle = entry.releaseError ?? (entry.releaseLoaded ? 'Brak opublikowanej wersji' : '');
    }
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Hero(tag: 'icon-${entry.packageName}', child: AppIcon(name: entry.app.name, url: entry.iconUrl)),
      title: Text(entry.app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        entry.lastError ?? subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: entry.lastError != null ? TextStyle(color: theme.colorScheme.error) : null,
      ),
      trailing: AppActionButton(controller: controller, entry: entry),
    );
  }
}

class _SelfUpdateBanner extends StatelessWidget {
  const _SelfUpdateBanner({required this.controller, required this.entry});

  final CatalogController controller;
  final CatalogEntry entry;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      color: Theme.of(context).colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Nowa wersja sklepu: ${entry.release?.versionName ?? ''}',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          AppActionButton(controller: controller, entry: entry, expanded: true),
        ]),
      ),
    );
  }
}

class _NoGroup extends StatelessWidget {
  const _NoGroup({required this.controller, required this.onJoin});

  final CatalogController controller;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(children: [
        Icon(Icons.family_restroom, size: 64, color: theme.colorScheme.primary),
        const SizedBox(height: 16),
        Text('Nie należysz jeszcze do żadnej grupy', style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          'Wpisz kod zaproszenia albo poproś administratora sklepu, żeby dodał Cię po e-mailu:\n'
          '${controller.repo.email}',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(onPressed: onJoin, icon: const Icon(Icons.vpn_key_outlined), label: const Text('Mam kod')),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Column(children: [
          Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(text, textAlign: TextAlign.center),
        ]),
      );
}
