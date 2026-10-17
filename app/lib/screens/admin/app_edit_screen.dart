import 'package:flutter/material.dart';

import '../../domain/models.dart';
import '../../domain/release.dart';
import '../../services/github_releases.dart';
import '../../services/store_repository.dart';

/// Dodawanie / edycja aplikacji w grupie.
class AppEditScreen extends StatefulWidget {
  const AppEditScreen({super.key, required this.repo, required this.group, this.app});

  final StoreRepository repo;
  final StoreGroup group;
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

  bool _checking = false;
  bool _saving = false;
  String? _checkResult;
  AppRelease? _found;

  @override
  void dispose() {
    for (final c in [_name, _description, _repo, _tagPrefix, _asset, _package, _icon, _order]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _checkResult = null;
      _found = null;
    });
    try {
      final r = await GithubReleases().latest(
        repo: _repo.text.trim(),
        tagPrefix: _tagPrefix.text.trim().isEmpty ? 'v' : _tagPrefix.text.trim(),
        assetName: _asset.text.trim(),
        includePrerelease: _prerelease,
        force: true,
      );
      if (r == null) {
        _checkResult = 'Nie znaleziono wydania z plikiem APK pasującego do prefiksu tagów.';
      } else {
        _found = r;
        final apkName = Uri.parse(r.apkUrl).pathSegments.last;
        _checkResult = 'Znaleziono ${r.tag}: $apkName'
            '${r.versionCode != null ? ', versionCode ${r.versionCode}' : ''}'
            '${r.packageName != null ? '\nPakiet: ${r.packageName}' : '\nBrak app.json - wpisz nazwę pakietu ręcznie.'}'
            '${r.signerSha256 != null ? '\nPodpis: ${r.signerSha256!.substring(0, 16)}…' : ''}';
        if (_package.text.trim().isEmpty && r.packageName != null) _package.text = r.packageName!;
        if (_asset.text.trim().isEmpty) _asset.text = apkName.replaceFirst(RegExp(r'\.apk$', caseSensitive: false), '');
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
      await widget.repo.saveApp(
        widget.group.id,
        StoreApp(
          id: widget.app?.id ?? '',
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
        ),
      );
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
        title: Text('Usunąć „${app.name}” z grupy?'),
        content: const Text('Zniknie z katalogu członków. Zainstalowane kopie zostaną na telefonach.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Anuluj')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Usuń')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.repo.deleteApp(widget.group.id, app.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    String? required(String? v) => (v ?? '').trim().isEmpty ? 'Wymagane' : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.app == null ? 'Nowa aplikacja' : 'Edycja aplikacji'),
        actions: [
          if (widget.app != null) IconButton(tooltip: 'Usuń', onPressed: _delete, icon: const Icon(Icons.delete_outline)),
        ],
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
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
          Text('Skąd brać wydania', style: Theme.of(context).textTheme.titleSmall),
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
                  helperText: 'bez .apk, np. zakupy',
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
              child: Text(
                _checkResult!,
                style: TextStyle(color: _found == null ? Theme.of(context).colorScheme.error : null),
              ),
            ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _package,
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
            subtitle: const Text('Członkowie tej grupy dostają też wydania oznaczone jako pre-release'),
            value: _prerelease,
            onChanged: (v) => setState(() => _prerelease = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ukryta'),
            subtitle: const Text('Widzisz ją tylko Ty'),
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
