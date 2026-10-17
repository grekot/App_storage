import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../domain/models.dart';
import '../domain/release.dart';
import '../domain/versions.dart';
import 'downloader.dart';
import 'github_releases.dart';
import 'installer.dart';
import 'notifications.dart';
import 'store_repository.dart';

enum TaskPhase { downloading, verifying, installing }

/// Trwające pobieranie / instalacja jednej aplikacji.
class AppTask {
  AppTask(this.phase, {this.progress});
  TaskPhase phase;
  double? progress;
  final cancel = CancelToken();
}

/// Aplikacja w katalogu razem z jej stanem na tym telefonie.
class CatalogEntry {
  CatalogEntry(this.app, this.groups);

  StoreApp app;

  /// Grupy, w których udostępniono tę aplikację
  List<StoreGroup> groups;

  AppRelease? release;
  bool releaseLoaded = false;
  String? releaseError;
  InstalledApp? installed;
  AppTask? task;
  String? lastError;

  String get packageName => app.packageName;
  String? get iconUrl => app.iconUrl.isNotEmpty ? app.iconUrl : release?.iconUrl;

  AppStatus get status => decideStatus(
        installed: installed != null,
        installedName: installed?.versionName,
        installedCode: installed?.versionCode,
        installedSigner: installed?.signerSha256,
        hasRelease: release != null,
        releaseName: release?.versionName,
        releaseCode: release?.versionCode,
        releaseSigner: release?.signerSha256,
      );
}

/// Wynik akcji "Zainstaluj / Aktualizuj".
sealed class ActionOutcome {
  const ActionOutcome();
}

class Installed extends ActionOutcome {
  const Installed();
}

/// Sklep nie ma jeszcze zgody "Instaluj nieznane aplikacje".
class NeedsPermission extends ActionOutcome {
  const NeedsPermission();
}

class Cancelled extends ActionOutcome {
  const Cancelled();
}

class Failed extends ActionOutcome {
  const Failed(this.message, {this.suggestUninstall = false});
  final String message;
  final bool suggestUninstall;
}

/// Serce sklepu: grupy i aplikacje z Firestore + wydania z GitHub/CI +
/// zainstalowane wersje z telefonu + pobieranie i instalacja.
class CatalogController extends ChangeNotifier with WidgetsBindingObserver {
  CatalogController({
    required this.repo,
    Installer? installer,
    GithubReleases? releases,
    ApkDownloader? downloader,
    Notifications? notifications,
  })  : installer = installer ?? Installer(),
        _releases = releases ?? GithubReleases(),
        _downloader = downloader ?? ApkDownloader(),
        notifications = notifications ?? Notifications();

  final StoreRepository repo;
  final Installer installer;
  final GithubReleases _releases;
  final ApkDownloader _downloader;
  final Notifications notifications;

  List<StoreGroup> groups = const [];
  bool groupsLoaded = false;
  String? groupsError;

  final Map<String, List<StoreApp>> _appsByGroup = {};
  final Map<String, StreamSubscription> _appSubs = {};
  StreamSubscription? _groupsSub;

  /// Klucz: packageName
  final Map<String, CatalogEntry> _entries = {};

  /// Sam sklep (samoaktualizacja)
  CatalogEntry? selfEntry;

  /// Odcisk klucza, którym podpisano sklep - domyślnie zaufany
  String? storeSigner;

  bool refreshing = false;

  List<CatalogEntry> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) {
        final o = a.app.order.compareTo(b.app.order);
        return o != 0 ? o : a.app.name.toLowerCase().compareTo(b.app.name.toLowerCase());
      });
    return list;
  }

  CatalogEntry? entry(String packageName) =>
      packageName == selfEntry?.packageName ? selfEntry : _entries[packageName];

  bool get isOwnerOfAnyGroup => groups.any((g) => g.isOwner(repo.uid));

  int get updatesCount => _entries.values.where((e) => e.status == AppStatus.updateAvailable).length;

  // ------------------------------------------------------------------ start / odświeżanie

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    await _loadSelf();
    _groupsSub = repo.watchMyGroups().listen(_onGroups, onError: (Object e) {
      groupsError = '$e';
      groupsLoaded = true;
      notifyListeners();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Powrót z systemowego instalatora / ustawień - odczytaj wersje na nowo.
    if (state == AppLifecycleState.resumed) unawaited(refreshInstalled());
  }

  Future<void> _loadSelf() async {
    try {
      final me = await installer.self();
      storeSigner = me?.signerSha256;
      if (me != null) {
        selfEntry = CatalogEntry(
          StoreApp(
            name: 'Sklep rodzinny',
            packageName: me.packageName,
            repo: StoreConfig.selfRepo,
            tagPrefix: StoreConfig.selfTagPrefix,
            assetName: StoreConfig.selfAsset,
          ),
          const [],
        )..installed = me;
        unawaited(_loadRelease(selfEntry!));
      }
    } catch (e) {
      debugPrint('self: $e');
    }
  }

  void _onGroups(List<StoreGroup> list) {
    groups = list;
    groupsLoaded = true;
    groupsError = null;
    final ids = list.map((g) => g.id).toSet();
    for (final gid in _appSubs.keys.toList()) {
      if (!ids.contains(gid)) {
        _appSubs.remove(gid)?.cancel();
        _appsByGroup.remove(gid);
      }
    }
    for (final g in list) {
      _appSubs[g.id] ??= repo.watchApps(g.id).listen(
            (apps) {
              _appsByGroup[g.id] = apps;
              _rebuild();
            },
            onError: (Object e) => debugPrint('apps ${g.id}: $e'),
          );
    }
    _rebuild();
  }

  /// Scala aplikacje ze wszystkich grup (ta sama aplikacja w dwóch grupach = jeden kafelek).
  void _rebuild() {
    final merged = <String, (StoreApp, List<StoreGroup>)>{};
    for (final g in groups) {
      for (final a in _appsByGroup[g.id] ?? const <StoreApp>[]) {
        if (a.packageName.isEmpty || a.repo.isEmpty) continue;
        if (a.hidden && !g.isOwner(repo.uid)) continue;
        final prev = merged[a.packageName];
        if (prev == null) {
          merged[a.packageName] = (a, [g]);
        } else {
          final keep = prev.$1.order <= a.order ? prev.$1 : a;
          merged[a.packageName] = (
            keep.copyWith(prerelease: prev.$1.prerelease || a.prerelease),
            [...prev.$2, g],
          );
        }
      }
    }
    _entries.removeWhere((pkg, _) => !merged.containsKey(pkg));
    final fresh = <CatalogEntry>[];
    merged.forEach((pkg, v) {
      final existing = _entries[pkg];
      if (existing == null) {
        final e = CatalogEntry(v.$1, v.$2);
        _entries[pkg] = e;
        fresh.add(e);
      } else {
        final sourceChanged = existing.app.repo != v.$1.repo ||
            existing.app.tagPrefix != v.$1.tagPrefix ||
            existing.app.assetName != v.$1.assetName ||
            existing.app.prerelease != v.$1.prerelease ||
            existing.app.latest?.tag != v.$1.latest?.tag;
        existing
          ..app = v.$1
          ..groups = v.$2;
        if (sourceChanged) fresh.add(existing);
      }
    });
    notifyListeners();
    for (final e in fresh) {
      unawaited(_loadRelease(e));
    }
    if (fresh.isNotEmpty) unawaited(refreshInstalled());
    unawaited(notifications.sync([..._entries.keys, if (selfEntry != null) selfEntry!.packageName]));
  }

  Future<void> _loadRelease(CatalogEntry e, {bool force = false}) async {
    final app = e.app;
    try {
      // Etap 2: CI zapisuje najnowsze wydanie w Firestore - wtedy GitHub API nie jest potrzebne.
      if (app.latest != null && !app.prerelease) {
        e.release = app.latest;
      } else {
        e.release = await _releases.latest(
          repo: app.repo,
          tagPrefix: app.tagPrefix,
          assetName: app.assetName,
          includePrerelease: app.prerelease,
          force: force,
        );
      }
      e.releaseError = null;
    } catch (err) {
      e.releaseError = '$err';
    }
    e.releaseLoaded = true;
    notifyListeners();
  }

  Future<void> refresh({bool force = true}) async {
    refreshing = true;
    notifyListeners();
    await Future.wait([
      for (final e in _entries.values) _loadRelease(e, force: force),
      if (selfEntry != null) _loadRelease(selfEntry!, force: force),
      refreshInstalled(),
    ]);
    refreshing = false;
    notifyListeners();
  }

  Future<void> refreshInstalled() async {
    try {
      final map = await installer.installed(_entries.keys);
      for (final e in _entries.values) {
        e.installed = map[e.packageName];
      }
      if (selfEntry != null) selfEntry!.installed = await installer.self() ?? selfEntry!.installed;
      notifyListeners();
      unawaited(_reportInstalls());
    } catch (e) {
      debugPrint('installed: $e');
    }
  }

  /// Etap 3: "kto ma którą wersję" - zapis tylko, gdy wersja się zmieniła.
  Future<void> _reportInstalls() async {
    final prefs = await SharedPreferences.getInstance();
    for (final e in _entries.values) {
      for (final g in e.groups) {
        final key = 'reported|${g.id}|${e.packageName}';
        final code = e.installed?.versionCode ?? -1;
        if (prefs.getInt(key) == code) continue;
        try {
          if (e.installed != null) {
            await repo.reportInstall(g.id, e.installed!);
          } else {
            await repo.clearInstall(g.id, e.packageName);
          }
          await prefs.setInt(key, code);
        } catch (_) {}
      }
    }
  }

  // ------------------------------------------------------------------ akcje

  Future<bool> launch(CatalogEntry e) => installer.launch(e.packageName);

  Future<void> uninstall(CatalogEntry e) => installer.uninstall(e.packageName);

  void cancel(CatalogEntry e) => e.task?.cancel.cancel();

  /// Pobiera, sprawdza i instaluje najnowszą wersję.
  /// [confirmUnknownSigner] - wołane, gdy APK ma nieznany podpis (tylko build deweloperski sklepu).
  Future<ActionOutcome> installOrUpdate(
    CatalogEntry e, {
    Future<bool> Function(String signer)? confirmUnknownSigner,
  }) async {
    final release = e.release;
    if (release == null || e.task != null) return const Cancelled();
    if (!await installer.canInstall()) return const NeedsPermission();

    final task = AppTask(TaskPhase.downloading, progress: 0);
    e
      ..task = task
      ..lastError = null;
    notifyListeners();
    File? file;
    try {
      file = await _downloader.download(
        release.apkUrl,
        fileName: '${e.packageName}.apk',
        expectedSha256: release.sha256,
        cancel: task.cancel,
        onProgress: (p) {
          task.progress = p;
          notifyListeners();
        },
      );

      task
        ..phase = TaskPhase.verifying
        ..progress = null;
      notifyListeners();
      final apk = await installer.apkInfo(file.path);
      if (apk == null) return _fail(e, 'Pobrany plik nie jest poprawnym APK.');
      if (apk.packageName != e.packageName) {
        return _fail(e, 'Plik zawiera inną aplikację (${apk.packageName}) niż oczekiwana (${e.packageName}).');
      }
      final trusted = isSignerTrusted(
        apkSigner: apk.signerSha256,
        storeSigner: storeSigner,
        trustedSigners: e.groups.expand((g) => g.trustedSigners),
        installedSigner: e.installed?.signerSha256,
      );
      if (!trusted) {
        final allow = kDebugMode && confirmUnknownSigner != null && await confirmUnknownSigner(apk.signerSha256 ?? '?');
        if (!allow) {
          return _fail(e, 'Plik jest podpisany nieznanym kluczem - instalacja zablokowana. '
              'Właściciel grupy może dodać ten klucz do zaufanych.');
        }
      }
      if (task.cancel.isCancelled) throw const DownloadCancelled();

      task.phase = TaskPhase.installing;
      notifyListeners();
      final result = await installer.install(file.path);
      if (result.ok) {
        e.task = null;
        await refreshInstalled();
        return const Installed();
      }
      if (result.status == 'aborted') {
        e.task = null;
        notifyListeners();
        return const Cancelled();
      }
      return _fail(e, result.description, suggestUninstall: result.status == 'conflict');
    } on DownloadCancelled {
      e.task = null;
      notifyListeners();
      return const Cancelled();
    } catch (err) {
      return _fail(e, '$err');
    } finally {
      if (file != null && e.packageName != selfEntry?.packageName) {
        try {
          await file.delete();
        } catch (_) {}
      }
    }
  }

  Failed _fail(CatalogEntry e, String message, {bool suggestUninstall = false}) {
    e
      ..task = null
      ..lastError = message;
    notifyListeners();
    return Failed(message, suggestUninstall: suggestUninstall);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _groupsSub?.cancel();
    for (final s in _appSubs.values) {
      s.cancel();
    }
    unawaited(notifications.dispose());
    super.dispose();
  }
}
