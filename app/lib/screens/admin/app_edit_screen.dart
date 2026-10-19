import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/release.dart';
import '../../services/catalog_controller.dart';
import '../../services/github_releases.dart';

/// Aplikacja w bibliotece administratora: dane, źródło wydań i grupy, które ją widzą.
class AppEditScreen extends StatefulWidget {
  const AppEditScreen({super.key, required this.controller, this.app});

  final CatalogController controller;

  /// Wpis z biblioteki; null = nowa aplikacja.
  final StoreApp? app;

  @override
  State<AppEditScreen> createState() => _AppEditScreenState();
}

class _AppEditScreenState extends State<AppEditScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.app?.name);
  late final _description = TextEditingController(text: widget.app?.description);
  late final _repo = TextEditingController(text: widget.app?.repo ?? 'grekot/');
  late final _tagPrefix = TextEditingController(text: widget.app?.tagPrefix ?? 'v');
  late final _asset = TextEditingController(text: widget.app?.assetName);
  late final _package = TextEditingController(text: widget.app?.packageName);
  late final _icon = TextEditingController(text: widget.app?.iconUrl);
  late final _order = TextEditingController(text: '${widget.app?.order ?? 100}');
  late bool _prerelease = widget.app?.prerelease ?? false;
  late bool _hidden = widget.app?.hidden ?? false;
  late final Set<String> _groups = widget.app == null
      ? <String>{}
      : widget.controller.groupsOfApp(widget.app!.packageName).map((g) => g.id).toSet();

  bool _checking = false;
  bool _saving = false;
  String? _checkResult;
  AppRelease? _found;

  CatalogController get c => widget.controller;
  bool get _isNew => widget.app == null;

  @override
  void dispose() {
    for (final t in [_name, _description, _repo, _tagPrefix, _asset, _package, _icon, _order]) {
      t.dispose();
    }
    super.dispose();
  }

  Future<AppRelease?> _fetchRelease() => GithubReleases().latest(
        repo: _repo.text.trim(),
        tagPrefix: _tagPrefix.text.trim().isEmpty ? 'v' : _tagPrefix.text.trim(),
        assetName: _asset.text.trim(),
        includePrerelease: _prerelease,
        force: true,
      );

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _checkResult = null;
      _found = null;
    });
    try {
      final r = await _fetchRelease();
      if (r == null) {
        _checkResult = 'Nie znaleziono wydania z plikiem APK pasującego do prefiksu tagów.';
      } else {
        _found = r;
        final apkName = Uri.parse(r.apkUrl).pathSegments.last;
        _checkResult = 'Znaleziono ${r.tag}: $apkName'
            '${r.versionCode != null ? ', versionCode ${r.versionCode}' : ''}'
            '${r.packageName != null ? '\nPakiet: ${r.packageName}' : '\nBrak app.json - wpisz nazwę pakietu ręcznie.'}';
        if (_package.text.trim().isEmpty && r.packageName != null) _package.text = r.packageName!;
        if (_asset.text.trim().isEmpty) _asset.text = apkName.replaceFirst(RegExp(r'\.apk$', caseSensitive: false), '');
        if (_name.text.trim().isEmpty) _name.text = _repo.text.split('/').last;
      }
    } catch (e) {
      _checkResult = '$e';
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      // Nowa aplikacja (albo zmienione źródło) - pobierz wersję, żeby od razu było co instalować.
      var latest = _found;
      if (latest == null && (_isNew || widget.app?.latest == null)) {
        latest = await _fetchRelease().catchError((_) => null);
      }
      final app = StoreApp(
        id: _package.text.trim(),
        name: _name.text,
        description: _description.text,
        packageName: _package.text,
        repo: _repo.text,
        tagPrefix: _tagPrefix.text,
        assetName: _asset.text,
        iconUrl: _icon.text,
        order: int.tryParse(_order.text.trim()) ?? 100,
        prerelease: _prerelease,
        hidden: _hidden,
        latest: widget.app?.latest,
      );
      final owned = c.ownedGroups;
      await c.repo.saveLibraryApp(app, owned, latest: latest);
      await c.repo.setAppGroups(latest == null ? app : app.copyWith(latest: latest), _groups, owned);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Nie zapisano: $e')));
      }
    }
  }

  Future<void> _delete() async {
    final app = widget.app;
    if (app == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Usunąć „${app.name}”?'),
        content: const Text('Zniknie z biblioteki i ze wszystkich grup. Zainstalowane kopie zostaną na telefonach.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Usuń')),
        ],
      ),
    );
    if (ok != true) return;
    await c.repo.deleteLibraryApp(app.packageName, c.ownedGroups);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    String? required(String? v) => (v ?? '').trim().isEmpty ? 'Wymagane' : null;
    final theme = Theme.of(context);
    final owned = c.ownedGroups;
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'Nowa aplikacja' : widget.app!.name),
        actions: [
          if (!_isNew) IconButton(tooltip: 'Usuń', onPressed: _delete, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('Kto ją widzi', style: theme.textTheme.titleSmall),
          if (owned.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Nie masz jeszcze grup.'))
          else
            for (final g in owned)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _groups.contains(g.id),
                onChanged: (v) => setState(() => v == true ? _groups.add(g.id) : _groups.remove(g.id)),
                title: Text(g.name),
                subtitle: Text('osób: ${g.members.length}'),
              ),
          const Divider(height: 32),
          TextFormField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Nazwa', border: OutlineInputBorder()),
            validator: required,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _description,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Opis (opcjonalnie)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          Text('Skąd brać wydania', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          TextFormField(
            controller: _repo,
            decoration: const InputDecoration(
              labelText: 'Repozytorium GitHub',
              hintText: 'grekot/EscapeRoom',
              border: OutlineInputBorder(),
            ),
            validator: (v) => RegExp(r'^[\w.-]+/[\w.-]+$').hasMatch((v ?? '').trim()) ? null : 'Format: właściciel/repo',
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _tagPrefix,
                decoration: const InputDecoration(
                  labelText: 'Prefiks tagów',
                  helperText: 'v albo np. zakupy-v',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _asset,
                decoration: const InputDecoration(
                  labelText: 'Plik APK',
                  helperText: 'bez .apk (puste = pierwszy)',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _checking ? null : _check,
              icon: _checking
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.travel_explore),
              label: const Text('Sprawdź na GitHubie'),
            ),
          ),
          if (_checkResult != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_checkResult!, style: TextStyle(color: _found == null ? theme.colorScheme.error : null)),
            ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _package,
            enabled: _isNew,
            decoration: const InputDecoration(
              labelText: 'Nazwa pakietu Androida',
              hintText: 'pl.grekot.zakupy',
              border: OutlineInputBorder(),
            ),
            validator: (v) =>
                RegExp(r'^[a-zA-Z]\w*(\.[a-zA-Z]\w*)+$').hasMatch((v ?? '').trim()) ? null : 'np. pl.grekot.zakupy',
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _icon,
            decoration: const InputDecoration(
              labelText: 'Adres ikony (opcjonalnie)',
              helperText: 'Puste = icon.png z wydania albo litera',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _order,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Kolejność (mniejsza = wyżej)', border: OutlineInputBorder()),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Wersje testowe (pre-release)'),
            value: _prerelease,
            onChanged: (v) => setState(() => _prerelease = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ukryta'),
            subtitle: const Text('Nie pokazuj członkom grup (widzisz ją tylko Ty)'),
            value: _hidden,
            onChanged: (v) => setState(() => _hidden = v),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Zapisz'),
          ),
        ]),
      ),
    );
  }
}
