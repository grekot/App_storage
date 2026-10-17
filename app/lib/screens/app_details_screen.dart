import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/catalog_controller.dart';
import '../widgets/app_actions.dart';
import '../widgets/app_icon.dart';

/// Karta aplikacji: opis, co nowego, wersje, akcje.
class AppDetailsScreen extends StatelessWidget {
  const AppDetailsScreen({super.key, required this.controller, required this.packageName});

  final CatalogController controller;
  final String packageName;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final e = controller.entry(packageName);
        if (e == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Tej aplikacji nie ma już w katalogu.')),
          );
        }
        final theme = Theme.of(context);
        final r = e.release;
        final inst = e.installed;
        return Scaffold(
          appBar: AppBar(
            actions: [
              if (inst != null)
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'uninstall') controller.uninstall(e);
                  },
                  itemBuilder: (_) => const [PopupMenuItem(value: 'uninstall', child: Text('Odinstaluj'))],
                ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Row(children: [
                Hero(tag: 'icon-$packageName', child: AppIcon(name: e.app.name, url: e.iconUrl, size: 72)),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(e.app.name, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(packageName, style: theme.textTheme.bodySmall),
                  ]),
                ),
              ]),
              const SizedBox(height: 20),
              AppActionButton(controller: controller, entry: e, expanded: true),
              if (e.lastError != null) ...[
                const SizedBox(height: 8),
                Text(e.lastError!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 20),
              _InfoRow(label: 'Najnowsza wersja', value: r == null ? (e.releaseError ?? '-') : r.versionName),
              if (r?.prerelease == true) const _InfoRow(label: 'Kanał', value: 'testowy (pre-release)'),
              _InfoRow(label: 'Zainstalowana', value: inst?.versionName ?? 'nie'),
              if (r != null && r.size > 0) _InfoRow(label: 'Rozmiar', value: formatSize(r.size)),
              if (r?.publishedAt != null) _InfoRow(label: 'Wydana', value: formatDate(r!.publishedAt)),
              if (e.groups.isNotEmpty) _InfoRow(label: 'Udostępnia', value: e.groups.map((g) => g.name).join(', ')),
              if (e.app.description.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('O aplikacji', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(e.app.description),
              ],
              if (r != null && r.notes.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text('Co nowego', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                SelectableText(_plainNotes(r.notes)),
              ],
              const SizedBox(height: 20),
              if (r?.htmlUrl.isNotEmpty == true)
                TextButton.icon(
                  onPressed: () => launchUrl(Uri.parse(r!.htmlUrl), mode: LaunchMode.externalApplication),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Strona wydania na GitHubie'),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Notatki generowane przez GitHub są w Markdown - pokazujemy je jako zwykły tekst.
  static String _plainNotes(String md) => md
      .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
      .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1)!)
      .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m.group(1)!)
      .replaceAll(RegExp(r'^\* ', multiLine: true), '• ')
      .trim();
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 140, child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
          Expanded(child: Text(value)),
        ]),
      );
}
