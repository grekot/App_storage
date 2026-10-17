import 'dart:async';

import 'package:flutter/services.dart';

import '../domain/models.dart';

/// Wynik instalacji z PackageInstallera.
class InstallResult {
  const InstallResult(this.status, [this.message]);

  /// success | aborted | conflict | incompatible | storage | blocked | invalid | failure
  final String status;
  final String? message;

  bool get ok => status == 'success';

  /// Zrozumiały opis dla użytkownika.
  String get description => switch (status) {
        'success' => 'Zainstalowano.',
        'aborted' => 'Instalacja anulowana.',
        'conflict' => 'Zainstalowana wersja ma inny podpis albo jest nowsza. '
            'Odinstaluj ją i zainstaluj ponownie ze sklepu.',
        'incompatible' => 'Ta wersja nie pasuje do tego telefonu (za stary Android albo procesor).',
        'storage' => 'Za mało miejsca na telefonie.',
        'blocked' => 'Instalację zablokował system albo zasady urządzenia.',
        'invalid' => 'Pobrany plik jest uszkodzony.',
        _ => 'Instalacja nie powiodła się${message == null ? '' : ': $message'}.',
      };
}

/// Kanał do natywnej części (MainActivity.kt).
class Installer {
  Installer() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'link' && call.arguments is String) _links.add(call.arguments as String);
    });
  }

  static const _channel = MethodChannel('pl.grekot.sklep/installer');
  final _links = StreamController<String>.broadcast();

  /// Linki grekot-sklep://… otwarte, gdy sklep już działa.
  Stream<String> get links => _links.stream;

  /// Link, z którym uruchomiono sklep (jednorazowo).
  Future<String?> takeLink() async => _channel.invokeMethod<String>('takeLink');

  Future<Map<String, InstalledApp>> installed(Iterable<String> packages) async {
    final list = packages.where((p) => p.isNotEmpty).toSet().toList();
    if (list.isEmpty) return const {};
    final raw = await _channel.invokeMethod<Map>('installed', {'packages': list}) ?? const {};
    final out = <String, InstalledApp>{};
    raw.forEach((k, v) {
      final a = InstalledApp.fromMap(v);
      if (a != null) out[k.toString()] = a;
    });
    return out;
  }

  /// Sam sklep: wersja i odcisk klucza, którym jest podpisany.
  Future<InstalledApp?> self() async => InstalledApp.fromMap(await _channel.invokeMethod('self'));

  /// Pakiet, wersja i podpis pobranego pliku APK.
  Future<InstalledApp?> apkInfo(String path) async =>
      InstalledApp.fromMap(await _channel.invokeMethod('apkInfo', {'path': path}));

  Future<bool> canInstall() async => await _channel.invokeMethod<bool>('canInstall') ?? false;

  Future<void> openInstallSettings() => _channel.invokeMethod('openInstallSettings');

  Future<InstallResult> install(String path) async {
    final r = await _channel.invokeMethod<Map>('install', {'path': path});
    return InstallResult((r?['status'] ?? 'failure').toString(), r?['message']?.toString());
  }

  Future<bool> launch(String packageName) async =>
      await _channel.invokeMethod<bool>('launch', {'package': packageName}) ?? false;

  Future<void> uninstall(String packageName) => _channel.invokeMethod('uninstall', {'package': packageName});
}
