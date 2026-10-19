import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wspolne/wspolne.dart' show askForName;

import '../../config.dart';
import '../../domain/models.dart';
import '../../domain/versions.dart';
import '../../services/catalog_controller.dart';
import '../../services/store_repository.dart';
import '../../widgets/app_actions.dart';
import '../../widgets/app_icon.dart';
import '../../widgets/pickers.dart';

/// Grupa: aplikacje, osoby, zaproszenia, wersje u osób, zaufane klucze.
/// Właściciel edytuje wszystko; członek widzi skład grupy i może z niej wyjść.
class GroupScreen extends StatelessWidget {
  const GroupScreen({super.key, required this.controller, required this.groupId});

  final CatalogController controller;
  final String groupId;

  StoreRepository get repo => controller.repo;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<StoreGroup?>(
      stream: repo.watchGroup(groupId),
      builder: (context, snap) {
        final g = snap.data;
        if (g == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: snap.connectionState == ConnectionState.waiting
                  ? const CircularProgressIndicator()
                  : const Text('Grupa nie istnieje albo już do niej nie należysz.'),
            ),
          );
        }
        // Zarządzanie tylko dla administratora-właściciela; pozostali widzą podgląd.
        if (!g.isOwner(repo.uid) || !controller.isAdmin) return _MemberView(controller: controller, group: g);
        return DefaultTabController(
          length: 5,
          child: Scaffold(
            appBar: AppBar(
              title: Text(g.name),
              actions: [
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'rename') {
                      final name = await askForName(context, title: 'Nazwa grupy', initial: g.name);
                      if (name != null) await repo.renameGroup(g.id, name);
                    } else if (v == 'delete') {
                      final ok = await _confirm(context, 'Usunąć grupę „${g.name}”?',
                          'Osoby z grupy przestaną widzieć jej aplikacje. Zainstalowane aplikacje zostają na telefonach.');
                      if (ok && context.mounted) {
                        Navigator.of(context).pop();
                        await repo.deleteGroup(g.id);
                      }
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('Zmień nazwę')),
                    PopupMenuItem(value: 'delete', child: Text('Usuń grupę')),
                  ],
                ),
              ],
              bottom: const TabBar(isScrollable: true, tabs: [
                Tab(text: 'Aplikacje'),
                Tab(text: 'Osoby'),
                Tab(text: 'Zaproszenia'),
                Tab(text: 'Wersje'),
                Tab(text: 'Podpisy'),
              ]),
            ),
            body: TabBarView(children: [
              _AppsTab(controller: controller, group: g),
              _MembersTab(repo: repo, group: g),
              _InvitesTab(repo: repo, group: g),
              _InstallsTab(controller: controller, group: g),
              _SignersTab(controller: controller, group: g),
            ]),
          ),
        );
      },
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String text) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Tak')),
        ],
      ),
    ) ??
    false;

// ---------------------------------------------------------------------- członek

class _MemberView extends StatelessWidget {
  const _MemberView({required this.controller, required this.group});
  final CatalogController controller;
  final StoreGroup group;

  @override
  Widget build(BuildContext context) {
    // Podgląd dla członka: kto prowadzi grupę i jakie aplikacje są w niej udostępnione.
    // Zmiany (aplikacje, osoby, wyjście z grupy) robi administrator.
    return Scaffold(
      appBar: AppBar(title: Text(group.name)),
      body: StreamBuilder<List<StoreApp>>(
        stream: controller.repo.watchApps(group.id),
        builder: (context, snap) {
          final apps = (snap.data ?? const <StoreApp>[]).where((a) => !a.hidden).toList();
          return ListView(children: [
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: Text(group.ownerEmail),
              subtitle: const Text('Administrator grupy'),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('Aplikacje w tej grupie', style: Theme.of(context).textTheme.titleSmall),
            ),
            if (snap.connectionState == ConnectionState.waiting && apps.isEmpty)
              const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()))
            else if (apps.isEmpty)
              const Padding(padding: EdgeInsets.all(16), child: Text('Brak aplikacji.'))
            else
              for (final a in apps)
                ListTile(
                  leading: AppIcon(
                    name: a.name,
                    url: a.iconUrl.isEmpty ? controller.entry(a.packageName)?.iconUrl : a.iconUrl,
                    size: 40,
                  ),
                  title: Text(a.name),
                  subtitle: a.description.isEmpty ? null : Text(a.description, maxLines: 2),
                ),
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Aplikacje i skład grupy ustala administrator sklepu.',
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
          ]);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------- aplikacje

class _AppsTab extends StatelessWidget {
  const _AppsTab({required this.controller, required this.group});
  final CatalogController controller;
  final StoreGroup group;

  /// Wybór aplikacji z biblioteki, które widzi ta grupa.
  Future<void> _pick(BuildContext context, List<StoreApp> current) async {
    final lib = await controller.repo.watchLibrary().first;
    if (!context.mounted) return;
    final chosen = await showPicker(
      context,
      title: 'Aplikacje w „${group.name}”',
      hint: 'Zaznacz aplikacje z biblioteki, które ma widzieć ta grupa.',
      emptyText: 'Biblioteka jest pusta - dodaj aplikację w Zarządzanie → Aplikacje.',
      items: [
        for (final a in lib)
          PickItem(
            id: a.packageName,
            title: a.name,
            subtitle: a.latest?.versionName,
            leading: AppIcon(name: a.name, url: a.iconUrl.isNotEmpty ? a.iconUrl : a.latest?.iconUrl, size: 36),
          ),
      ],
      selected: current.map((a) => a.packageName).toSet(),
    );
    if (chosen == null) return;
    for (final a in lib) {
      final inside = current.any((x) => x.packageName == a.packageName);
      if (chosen.contains(a.packageName) && !inside) await controller.repo.assignApp(group.id, a);
      if (!chosen.contains(a.packageName) && inside) await controller.repo.unassignApp(group.id, a.packageName);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<StoreApp>>(
      stream: controller.repo.watchApps(group.id),
      builder: (context, snap) {
        final apps = snap.data ?? const <StoreApp>[];
        return Scaffold(
          floatingActionButton: FloatingActionButton.extended(
            heroTag: 'apps-${group.id}',
            onPressed: () => _pick(context, apps),
            icon: const Icon(Icons.checklist),
            label: const Text('Wybierz aplikacje'),
          ),
          body: apps.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('Ta grupa nie ma jeszcze aplikacji. Stuknij „Wybierz aplikacje”.',
                      textAlign: TextAlign.center),
                )
              : ListView(padding: const EdgeInsets.only(bottom: 88), children: [
                  for (final a in apps)
                    ListTile(
                      leading: AppIcon(
                          name: a.name, url: a.iconUrl.isEmpty ? controller.entry(a.packageName)?.iconUrl : a.iconUrl),
                      title: Text(a.name + (a.hidden ? ' (ukryta)' : '')),
                      subtitle: Text(a.latest != null ? a.latest!.versionName : a.repo),
                      trailing: IconButton(
                        tooltip: 'Zabierz tej grupie',
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () => controller.repo.unassignApp(group.id, a.packageName),
                      ),
                    ),
                ]),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------- osoby

class _MembersTab extends StatelessWidget {
  const _MembersTab({required this.repo, required this.group});
  final StoreRepository repo;
  final StoreGroup group;

  /// Wybór osób ze wszystkich kont (Zakupy, Powrót, Sklep).
  Future<void> _pick(BuildContext context) async {
    final users = await repo.watchUsers().first;
    if (!context.mounted) return;
    final chosen = await showPicker(
      context,
      title: 'Osoby w „${group.name}”',
      hint: 'Zaznacz osoby, które mają widzieć aplikacje tej grupy.',
      emptyText: 'Brak kont. Osoba musi najpierw zainstalować sklep i założyć konto.',
      items: [for (final u in users) PickItem(id: u.uid, title: u.email, locked: u.uid == group.ownerId)],
      selected: group.members.toSet(),
    );
    if (chosen == null) return;
    for (final u in users) {
      final inside = group.members.contains(u.uid);
      if (u.uid == group.ownerId || chosen.contains(u.uid) == inside) continue;
      await repo.setUserGroups(u, chosen.contains(u.uid) ? {group.id} : {}, [group]);
    }
  }

  Future<void> _addByEmail(BuildContext context) async {
    final email = await askForName(context, title: 'Dodaj osobę po e-mailu', hint: 'adres e-mail konta');
    if (email == null) return;
    final r = await repo.addMemberByEmail(group, email);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(switch (r) {
        AddMemberResult.added => 'Dodano $email',
        AddMemberResult.alreadyMember => '$email już jest w grupie',
        AddMemberResult.notFound => 'Nie ma konta $email. Niech ta osoba zainstaluje sklep i założy konto '
            '(albo wyślij jej kod zaproszenia).',
      }),
      duration: const Duration(seconds: 6),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'members-${group.id}',
        onPressed: () => _pick(context),
        icon: const Icon(Icons.checklist),
        label: const Text('Wybierz osoby'),
      ),
      body: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
        for (final uid in group.members)
          ListTile(
            leading: Icon(uid == group.ownerId ? Icons.admin_panel_settings_outlined : Icons.person_outline),
            title: Text(group.memberEmails[uid] ?? uid),
            subtitle: uid == group.ownerId ? const Text('Administrator') : null,
            trailing: uid == group.ownerId
                ? null
                : IconButton(
                    tooltip: 'Usuń z grupy',
                    icon: const Icon(Icons.person_remove_outlined),
                    onPressed: () async {
                      final ok = await _confirm(
                          context, 'Usunąć ${group.memberEmails[uid] ?? uid}?', 'Aplikacje grupy znikną z jej katalogu.');
                      if (ok) await repo.removeMember(group.id, uid);
                    },
                  ),
          ),
        ListTile(
          leading: const Icon(Icons.alternate_email),
          title: const Text('Dodaj po e-mailu'),
          onTap: () => _addByEmail(context),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------- zaproszenia

class _InvitesTab extends StatelessWidget {
  const _InvitesTab({required this.repo, required this.group});
  final StoreRepository repo;
  final StoreGroup group;

  static String link(String code) => '${StoreConfig.linkScheme}://join/$code';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final inv = await repo.createInvite(group);
          if (!context.mounted) return;
          await showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Kod zaproszenia'),
              content: Column(mainAxisSize: MainAxisSize.min, children: [
                SelectableText(inv.code, style: Theme.of(ctx).textTheme.displaySmall?.copyWith(letterSpacing: 4)),
                const SizedBox(height: 12),
                Text(
                  'Ważny do ${formatDate(inv.expiresAt)}. Osoba instaluje sklep, zakłada konto '
                  'i wpisuje kod w menu „Dołącz kodem zaproszenia”.',
                ),
              ]),
              actions: [
                TextButton(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(
                      text: 'Zaproszenie do sklepu rodzinnego („${group.name}”).\n'
                          '1. Zainstaluj sklep: ${StoreConfig.homePage}\n'
                          '2. Załóż konto i wpisz kod: ${inv.code}',
                    ));
                    Navigator.pop(ctx);
                  },
                  child: const Text('Kopiuj wiadomość'),
                ),
                FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
              ],
            ),
          );
        },
        icon: const Icon(Icons.vpn_key_outlined),
        label: const Text('Nowy kod'),
      ),
      body: StreamBuilder<List<Invite>>(
        stream: repo.watchMyInvites(group.id),
        builder: (context, snap) {
          final list = snap.data ?? const <Invite>[];
          if (list.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'Kod zaproszenia pozwala dołączyć do grupy samodzielnie - bez podawania Ci e-maila. '
                'Kod jest ważny 7 dni i można go użyć wiele razy.',
                textAlign: TextAlign.center,
              ),
            );
          }
          return ListView(padding: const EdgeInsets.only(bottom: 88), children: [
            for (final i in list)
              ListTile(
                leading: Icon(i.isValid ? Icons.vpn_key_outlined : Icons.timer_off_outlined),
                title: Text(i.code, style: const TextStyle(letterSpacing: 2, fontFamily: 'monospace')),
                subtitle: Text(i.isValid ? 'Ważny do ${formatDate(i.expiresAt)}' : 'Wygasł'),
                trailing: IconButton(
                  tooltip: 'Usuń',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => repo.deleteInvite(i.code),
                ),
                onLongPress: () => Clipboard.setData(ClipboardData(text: link(i.code))),
              ),
          ]);
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------- wersje u osób

class _InstallsTab extends StatelessWidget {
  const _InstallsTab({required this.controller, required this.group});
  final CatalogController controller;
  final StoreGroup group;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<InstallReport>>(
      stream: controller.repo.watchInstalls(group.id),
      builder: (context, snap) {
        final reports = snap.data ?? const <InstallReport>[];
        if (reports.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(32),
            child: Text('Tu pojawi się, kto ma zainstalowaną którą wersję (sklep zgłasza to sam).',
                textAlign: TextAlign.center),
          );
        }
        final byPkg = <String, List<InstallReport>>{};
        for (final r in reports) {
          byPkg.putIfAbsent(r.packageName, () => []).add(r);
        }
        return ListView(children: [
          for (final pkg in byPkg.keys.toList()..sort()) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(controller.entry(pkg)?.app.name ?? pkg, style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final r in byPkg[pkg]!..sort((a, b) => a.email.compareTo(b.email)))
              Builder(builder: (context) {
                final latest = controller.entry(pkg)?.release;
                final outdated = latest != null &&
                    (latest.versionCode != null
                        ? latest.versionCode! > r.versionCode
                        : compareVersionNames(latest.versionName, r.versionName) > 0);
                return ListTile(
                  dense: true,
                  leading: Icon(outdated ? Icons.update : Icons.check_circle_outline,
                      color: outdated ? Theme.of(context).colorScheme.error : null),
                  title: Text(r.email),
                  subtitle: Text('${r.versionName}  ·  ${formatDate(r.updatedAt)}'),
                );
              }),
          ],
        ]);
      },
    );
  }
}

// ---------------------------------------------------------------------- zaufane klucze

class _SignersTab extends StatelessWidget {
  const _SignersTab({required this.controller, required this.group});
  final CatalogController controller;
  final StoreGroup group;

  @override
  Widget build(BuildContext context) {
    final repo = controller.repo;
    final self = controller.storeSigner;
    return ListView(padding: const EdgeInsets.all(8), children: [
      const Padding(
        padding: EdgeInsets.all(8),
        child: Text(
          'Sklep instaluje tylko pliki podpisane zaufanym kluczem: kluczem samego sklepu '
          'albo jednym z poniższych. Chroni to przed podmienionym plikiem na GitHubie.',
        ),
      ),
      if (self != null)
        ListTile(
          leading: const Icon(Icons.verified_outlined),
          title: const Text('Klucz tego sklepu'),
          subtitle: Text(self, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          trailing: group.trustedSigners.contains(self)
              ? null
              : TextButton(onPressed: () => repo.addTrustedSigner(group.id, self), child: const Text('Dodaj')),
        ),
      const Divider(),
      for (final s in group.trustedSigners)
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: Text(s, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => repo.removeTrustedSigner(group.id, s),
          ),
        ),
      Padding(
        padding: const EdgeInsets.all(8),
        child: OutlinedButton.icon(
          icon: const Icon(Icons.add),
          label: const Text('Dodaj odcisk SHA-256'),
          onPressed: () async {
            final v = await askForName(context, title: 'Odcisk SHA-256 certyfikatu', hint: 'z apksigner albo app.json');
            final n = normalizeFingerprint(v);
            if (n.length == 64) {
              await repo.addTrustedSigner(group.id, n);
            } else if (v != null && context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Odcisk SHA-256 ma 64 znaki szesnastkowe.')));
            }
          },
        ),
      ),
    ]);
  }
}
