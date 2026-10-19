import 'package:flutter/material.dart';
import 'package:wspolne/wspolne.dart' show askForName;

import '../../domain/models.dart';
import '../../services/catalog_controller.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/pickers.dart';
import 'app_edit_screen.dart';
import 'group_screen.dart';

/// Panel administratora: wszystkie aplikacje (biblioteka), grupy i osoby.
/// Przypisania robi się zaznaczaniem - aplikacja do grup, osoba do grup.
class AdminScreen extends StatelessWidget {
  const AdminScreen({super.key, required this.controller});

  final CatalogController controller;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Zarządzanie'),
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.apps), text: 'Aplikacje'),
            Tab(icon: Icon(Icons.groups_outlined), text: 'Grupy'),
            Tab(icon: Icon(Icons.person_outline), text: 'Osoby'),
          ]),
        ),
        body: TabBarView(children: [
          _LibraryTab(controller: controller),
          _GroupsTab(controller: controller),
          _UsersTab(controller: controller),
        ]),
      ),
    );
  }
}

Widget _groupChips(BuildContext context, List<StoreGroup> groups, {String empty = 'bez grupy'}) {
  final theme = Theme.of(context);
  if (groups.isEmpty) {
    return Text(empty, style: TextStyle(color: theme.colorScheme.outline, fontStyle: FontStyle.italic));
  }
  return Wrap(spacing: 6, runSpacing: 4, children: [
    for (final g in groups)
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: theme.colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(g.name, style: TextStyle(fontSize: 12, color: theme.colorScheme.onSecondaryContainer)),
      ),
  ]);
}

// ---------------------------------------------------------------------- aplikacje

class _LibraryTab extends StatelessWidget {
  const _LibraryTab({required this.controller});
  final CatalogController controller;

  void _edit(BuildContext context, [StoreApp? app]) => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => AppEditScreen(controller: controller, app: app),
      ));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'lib',
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: const Text('Dodaj aplikację'),
      ),
      body: StreamBuilder<List<StoreApp>>(
        stream: controller.repo.watchLibrary(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Nie udało się wczytać biblioteki: ${snap.error}'),
            );
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final apps = snap.data!;
          if (apps.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Biblioteka jest pusta. Każde nowe wydanie aplikacji trafia tu samo; '
                'możesz też dodać aplikację ręcznie.',
                textAlign: TextAlign.center,
              ),
            );
          }
          return ListenableBuilder(
            listenable: controller,
            builder: (context, _) => ListView(padding: const EdgeInsets.only(bottom: 88), children: [
              for (final a in apps)
                ListTile(
                  leading: AppIcon(name: a.name, url: a.iconUrl.isNotEmpty ? a.iconUrl : a.latest?.iconUrl),
                  title: Text(a.name + (a.hidden ? ' (ukryta)' : '')),
                  subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(a.latest == null ? a.repo : '${a.latest!.versionName} · ${a.repo}'),
                    const SizedBox(height: 4),
                    _groupChips(context, controller.groupsOfApp(a.packageName), empty: 'nieprzypisana'),
                  ]),
                  isThreeLine: true,
                  trailing: IconButton(
                    tooltip: 'Grupy',
                    icon: const Icon(Icons.group_add_outlined),
                    onPressed: () => _pickGroups(context, a),
                  ),
                  onTap: () => _edit(context, a),
                ),
            ]),
          );
        },
      ),
    );
  }

  Future<void> _pickGroups(BuildContext context, StoreApp app) async {
    final owned = controller.ownedGroups;
    final chosen = await showPicker(
      context,
      title: 'Kto widzi „${app.name}”?',
      hint: 'Zaznacz grupy, którym udostępniasz tę aplikację.',
      emptyText: 'Nie masz jeszcze grup - utwórz je w zakładce Grupy.',
      items: [for (final g in owned) PickItem(id: g.id, title: g.name, subtitle: 'osób: ${g.members.length}')],
      selected: controller.groupsOfApp(app.packageName).map((g) => g.id).toSet(),
    );
    if (chosen == null) return;
    await controller.repo.setAppGroups(app, chosen, owned);
  }
}

// ---------------------------------------------------------------------- grupy

class _GroupsTab extends StatelessWidget {
  const _GroupsTab({required this.controller});
  final CatalogController controller;

  Future<void> _create(BuildContext context) async {
    final name = await askForName(context, title: 'Nowa grupa', hint: 'np. Rodzice');
    if (name == null) return;
    final id = await controller.repo.createGroup(name, trustedSigners: controller.allTrustedSigners);
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupScreen(controller: controller, groupId: id)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final groups = controller.ownedGroups;
        return Scaffold(
          floatingActionButton: FloatingActionButton.extended(
            heroTag: 'grp',
            onPressed: () => _create(context),
            icon: const Icon(Icons.group_add_outlined),
            label: const Text('Nowa grupa'),
          ),
          body: groups.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('Grupa to osoby, którym udostępniasz wybrane aplikacje (np. „Rodzice”).',
                      textAlign: TextAlign.center),
                )
              : ListView(padding: const EdgeInsets.only(bottom: 88), children: [
                  for (final g in groups)
                    ListTile(
                      leading: const Icon(Icons.groups_outlined),
                      title: Text(g.name),
                      subtitle: Text('osób: ${g.members.length} · aplikacji: ${controller.appsInGroup(g.id).length}'
                          '${g.autoAdd ? ' · nowe aplikacje dodają się same' : ''}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => GroupScreen(controller: controller, groupId: g.id)),
                      ),
                    ),
                ]),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------- osoby

class _UsersTab extends StatelessWidget {
  const _UsersTab({required this.controller});
  final CatalogController controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<UserAccount>>(
      stream: controller.repo.watchUsers(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Nie udało się wczytać kont: ${snap.error}\n\n'
                'Sprawdź, czy opublikowane są aktualne reguły Firestore.'),
          );
        }
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final users = snap.data!;
        return ListenableBuilder(
          listenable: controller,
          builder: (context, _) {
            final owned = controller.ownedGroups;
            return ListView(children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('Wszystkie konta (Zakupy, Powrót, Sklep). Stuknij osobę, żeby wybrać jej grupy. '
                    'Kogoś brakuje? Niech zainstaluje sklep i założy konto, albo wyślij mu kod zaproszenia.'),
              ),
              for (final u in users)
                ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(u.email),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: _groupChips(context, owned.where((g) => g.members.contains(u.uid)).toList()),
                  ),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: () => _pickGroups(context, u, owned),
                ),
            ]);
          },
        );
      },
    );
  }

  Future<void> _pickGroups(BuildContext context, UserAccount user, List<StoreGroup> owned) async {
    final chosen = await showPicker(
      context,
      title: user.email,
      hint: 'Zaznacz grupy, do których należy ta osoba. Zobaczy ich aplikacje.',
      emptyText: 'Nie masz jeszcze grup - utwórz je w zakładce Grupy.',
      items: [
        for (final g in owned) PickItem(id: g.id, title: g.name, locked: g.ownerId == user.uid),
      ],
      selected: owned.where((g) => g.members.contains(user.uid)).map((g) => g.id).toSet(),
    );
    if (chosen == null) return;
    await controller.repo.setUserGroups(user, chosen, owned);
  }
}
