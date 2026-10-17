import 'package:flutter/material.dart';

import '../domain/versions.dart';
import '../services/catalog_controller.dart';

/// Przycisk akcji aplikacji: Zainstaluj / Aktualizuj / Otwórz / postęp pobierania.
class AppActionButton extends StatelessWidget {
  const AppActionButton({super.key, required this.controller, required this.entry, this.expanded = false});

  final CatalogController controller;
  final CatalogEntry entry;

  /// Pełna szerokość (karta aplikacji) zamiast kompaktowego przycisku na liście.
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final task = entry.task;
    if (task != null) return _TaskIndicator(controller: controller, entry: entry, task: task, expanded: expanded);

    final (label, primary, onPressed) = switch (entry.status) {
      AppStatus.notInstalled => ('Zainstaluj', true, () => runInstall(context, controller, entry)),
      AppStatus.updateAvailable => ('Aktualizuj', true, () => runInstall(context, controller, entry)),
      AppStatus.needsReinstall => ('Zainstaluj ponownie', true, () => _reinstall(context, controller, entry)),
      AppStatus.upToDate || AppStatus.newerInstalled => ('Otwórz', false, () => controller.launch(entry)),
      AppStatus.unavailable => (
          entry.releaseLoaded ? 'Brak wydania' : 'Sprawdzam…',
          false,
          null,
        ),
    };
    final child = Text(label);
    final button = primary
        ? FilledButton(onPressed: onPressed, child: child)
        : OutlinedButton(onPressed: onPressed, child: child);
    return expanded ? SizedBox(width: double.infinity, child: button) : button;
  }
}

class _TaskIndicator extends StatelessWidget {
  const _TaskIndicator({required this.controller, required this.entry, required this.task, required this.expanded});

  final CatalogController controller;
  final CatalogEntry entry;
  final AppTask task;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final label = switch (task.phase) {
      TaskPhase.downloading => task.progress == null ? 'Pobieranie…' : 'Pobieranie ${(task.progress! * 100).round()}%',
      TaskPhase.verifying => 'Sprawdzanie…',
      TaskPhase.installing => 'Instalowanie…',
    };
    final bar = LinearProgressIndicator(value: task.phase == TaskPhase.downloading ? task.progress : null);
    final cancel = task.phase == TaskPhase.downloading
        ? IconButton(
            tooltip: 'Anuluj',
            icon: const Icon(Icons.close),
            onPressed: () => controller.cancel(entry),
          )
        : null;
    if (!expanded) {
      return SizedBox(
        width: 120,
        child: Row(children: [
          Expanded(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(label, style: Theme.of(context).textTheme.labelSmall, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              bar,
            ]),
          ),
          ?cancel,
        ]),
      );
    }
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(label),
          const SizedBox(height: 6),
          bar,
        ]),
      ),
      ?cancel,
    ]);
  }
}

/// Instalacja / aktualizacja z obsługą wszystkich wyników (zgoda, błędy, podpis).
Future<void> runInstall(BuildContext context, CatalogController controller, CatalogEntry entry) async {
  final messenger = ScaffoldMessenger.of(context);
  final outcome = await controller.installOrUpdate(
    entry,
    confirmUnknownSigner: (signer) => _confirmUnknownSigner(context, signer),
  );
  if (!context.mounted) return;
  switch (outcome) {
    case Installed():
      messenger.showSnackBar(SnackBar(content: Text('Zainstalowano: ${entry.app.name}')));
    case NeedsPermission():
      await showInstallPermissionDialog(context, controller);
    case Cancelled():
      break;
    case Failed(:final message, :final suggestUninstall):
      if (suggestUninstall) {
        await _reinstall(context, controller, entry, reason: message);
      } else {
        messenger.showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 6)));
      }
  }
}

/// Wyjaśnienie zgody "Instaluj nieznane aplikacje" i przejście do ustawień.
Future<void> showInstallPermissionDialog(BuildContext context, CatalogController controller) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.security_outlined),
      title: const Text('Potrzebna jednorazowa zgoda'),
      content: const Text(
        'Android pozwala instalować aplikacje spoza Google Play tylko programom, którym na to zezwolisz.\n\n'
        'Za chwilę otworzą się ustawienia: włącz „Zezwalaj z tego źródła” dla Sklepu rodzinnego, '
        'wróć strzałką i stuknij przycisk instalacji jeszcze raz.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nie teraz')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Otwórz ustawienia')),
      ],
    ),
  );
  if (go == true) await controller.installer.openInstallSettings();
}

Future<void> _reinstall(BuildContext context, CatalogController controller, CatalogEntry entry, {String? reason}) async {
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.swap_horiz),
      title: const Text('Potrzebna ponowna instalacja'),
      content: Text(
        '${reason ?? 'Nowa wersja jest podpisana innym kluczem niż zainstalowana.'}\n\n'
        'Odinstaluj aplikację „${entry.app.name}”, a potem zainstaluj ją tutaj ponownie. '
        'Dane zapisane w chmurze (listy, miejsca) wrócą po zalogowaniu; '
        'dane trzymane tylko w telefonie zostaną usunięte - jeśli są ważne, najpierw je wyeksportuj.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Odinstaluj')),
      ],
    ),
  );
  if (go == true) await controller.uninstall(entry);
}

Future<bool> _confirmUnknownSigner(BuildContext context, String signer) async {
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.warning_amber_outlined),
      title: const Text('Nieznany podpis'),
      content: Text(
        'Wersja deweloperska sklepu: plik jest podpisany kluczem spoza listy zaufanych.\n\n'
        'SHA-256: $signer\n\nZainstalować mimo to?',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nie')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Instaluj')),
      ],
    ),
  );
  return ok ?? false;
}

/// "12,3 MB"
String formatSize(int bytes) {
  if (bytes <= 0) return '';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} kB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';
}

/// "17.10.2026"
String formatDate(DateTime? d) {
  if (d == null) return '';
  final l = d.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.day)}.${two(l.month)}.${l.year}';
}
