import 'package:flutter/material.dart';
import 'package:wspolne/wspolne.dart' show askForName;

import '../../services/catalog_controller.dart';
import 'group_screen.dart';

/// Moje grupy: te, które prowadzę (pełna edycja) i te, do których należę.
class GroupsScreen extends StatelessWidget {
  const GroupsScreen({super.key, required this.controller});

  final CatalogController controller;

  Future<void> _create(BuildContext context) async {
    final name = await askForName(context, title: 'Nowa grupa', hint: 'np. Rodzina');
    if (name == null) return;
    final id = await controller.repo.createGroup(name);
    if (!context.mounted) return;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => GroupScreen(controller: controller, groupId: id)));
  }

  @override
  Widget build(BuildContext context) {
    final uid = controller.repo.uid;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final groups = controller.groups;
        final admin = controller.isAdmin;
        return Scaffold(
          appBar: AppBar(title: Text(admin ? 'Grupy i aplikacje' : 'Moje grupy')),
          // Grupy zakłada tylko administrator (reguły Firestore i tak nie pozwolą innym).
          floatingActionButton: admin
              ? FloatingActionButton.extended(
                  onPressed: () => _create(context),
                  icon: const Icon(Icons.group_add_outlined),
                  label: const Text('Nowa grupa'),
                )
              : null,
          body: groups.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    admin
                        ? 'Grupa to osoby, którym udostępniasz aplikacje (np. „Rodzina”). '
                            'Utwórz grupę, dodaj do niej aplikacje i zaproś osoby.'
                        : 'Nie należysz jeszcze do żadnej grupy. Grupy przydziela administrator sklepu.',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView(children: [
                  for (final g in groups)
                    ListTile(
                      leading: Icon(g.isOwner(uid) ? Icons.admin_panel_settings_outlined : Icons.group_outlined),
                      title: Text(g.name),
                      subtitle: Text(g.isOwner(uid)
                          ? 'Prowadzisz · osób: ${g.members.length}'
                          : 'Prowadzi ${g.ownerEmail}'),
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
