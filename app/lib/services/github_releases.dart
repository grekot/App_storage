import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config.dart';
import '../domain/release.dart';

class ReleaseException implements Exception {
  const ReleaseException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Najnowsze wydania z GitHub Releases (publiczne repozytoria, bez tokena).
///
/// Oszczędza limit 60 zapytań/h: odpowiedź pamięta przez [StoreConfig.releaseCacheTtl],
/// a potem pyta warunkowo (If-None-Match) - odpowiedź 304 nie zużywa limitu.
/// Po znalezieniu wydania dociąga jego app.json (pobranie pliku nie liczy się do limitu API).
class GithubReleases {
  GithubReleases({http.Client? client, Future<SharedPreferences> Function()? prefs})
      : _client = client ?? http.Client(),
        _prefs = prefs ?? SharedPreferences.getInstance;

  final http.Client _client;
  final Future<SharedPreferences> Function() _prefs;

  static const _headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'grekot-sklep',
  };

  Future<AppRelease?> latest({
    required String repo,
    required String tagPrefix,
    required String assetName,
    bool includePrerelease = false,
    bool force = false,
  }) async {
    final key = 'gh2|$repo|$tagPrefix|$assetName|$includePrerelease';
    final prefs = await _prefs();
    final cached = _readCache(prefs, key);
    if (!force && cached != null && DateTime.now().difference(cached.fetchedAt) < StoreConfig.releaseCacheTtl) {
      return cached.release;
    }

    final uri = Uri.parse('https://api.github.com/repos/${repo.trim()}/releases?per_page=30');
    final headers = {..._headers, if (cached?.etag != null) 'If-None-Match': cached!.etag!};
    final http.Response r;
    try {
      r = await _client.get(uri, headers: headers).timeout(const Duration(seconds: 20));
    } on SocketException {
      if (cached != null) return cached.release;
      throw const ReleaseException('Brak połączenia z GitHub.');
    } on HttpException catch (e) {
      if (cached != null) return cached.release;
      throw ReleaseException('Błąd sieci: ${e.message}');
    }

    if (r.statusCode == 304 && cached != null) {
      await _writeCache(prefs, key, cached.release, cached.etag);
      return cached.release;
    }
    if (r.statusCode == 404) {
      throw ReleaseException('Nie ma repozytorium $repo (albo jest prywatne).');
    }
    if (r.statusCode == 403 || r.statusCode == 429) {
      if (cached != null) return cached.release;
      throw const ReleaseException('GitHub chwilowo ogranicza zapytania. Spróbuj za kilkanaście minut.');
    }
    if (r.statusCode != 200) {
      if (cached != null) return cached.release;
      throw ReleaseException('GitHub odpowiedział kodem ${r.statusCode}.');
    }

    final list = jsonDecode(utf8.decode(r.bodyBytes));
    if (list is! List) throw const ReleaseException('Niepoprawna odpowiedź GitHub.');
    var release = pickGithubRelease(
      list,
      tagPrefix: tagPrefix,
      assetName: assetName,
      includePrerelease: includePrerelease,
    );
    if (release?.appJsonUrl != null) {
      // Ten sam tag co w pamięci - app.json już mamy.
      if (cached?.release?.tag == release!.tag && cached?.release?.versionCode != null) {
        release = cached!.release;
      } else {
        release = await _withAppJson(release);
      }
    }
    await _writeCache(prefs, key, release, r.headers['etag']);
    return release;
  }

  Future<AppRelease> _withAppJson(AppRelease release) async {
    try {
      final r = await _client
          .get(Uri.parse(release.appJsonUrl!), headers: {'User-Agent': 'grekot-sklep'})
          .timeout(const Duration(seconds: 20));
      if (r.statusCode != 200) return release;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      return j is Map<String, dynamic> ? release.withAppJson(j) : release;
    } catch (_) {
      return release; // bez app.json też da się zainstalować (wersja z tagu)
    }
  }

  _Cached? _readCache(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return _Cached(
        AppRelease.fromJson(j['release']),
        DateTime.tryParse(j['fetchedAt'] as String? ?? '') ?? DateTime(2000),
        j['etag'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(SharedPreferences prefs, String key, AppRelease? release, String? etag) =>
      prefs.setString(
        key,
        jsonEncode({
          'release': release?.toJson(),
          'fetchedAt': DateTime.now().toIso8601String(),
          'etag': etag,
        }),
      );
}

class _Cached {
  _Cached(this.release, this.fetchedAt, this.etag);
  final AppRelease? release;
  final DateTime fetchedAt;
  final String? etag;
}
