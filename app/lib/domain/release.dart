import 'versions.dart';

/// Najnowsze wydanie aplikacji - z Firestore (zapisuje CI) albo z GitHub Releases.
class AppRelease {
  const AppRelease({
    required this.tag,
    required this.versionName,
    required this.apkUrl,
    this.versionCode,
    this.packageName,
    this.sha256,
    this.signerSha256,
    this.size = 0,
    this.minSdk,
    this.notes = '',
    this.htmlUrl = '',
    this.publishedAt,
    this.prerelease = false,
    this.iconUrl,
    this.appJsonUrl,
  });

  final String tag;
  final String versionName;
  final int? versionCode;
  final String? packageName;
  final String apkUrl;
  final String? sha256;
  final String? signerSha256;
  final int size;
  final int? minSdk;
  final String notes;
  final String htmlUrl;
  final DateTime? publishedAt;
  final bool prerelease;

  /// Ikona dołączona do wydania (asset icon.png), gdy właściciel nie podał własnej.
  final String? iconUrl;

  /// Link do app.json w wydaniu (metadane: versionCode, sha256, podpis).
  final String? appJsonUrl;

  /// Uzupełnia dane z pliku app.json (format grekot-app-release/1).
  AppRelease withAppJson(Map<String, dynamic> j) {
    String? str(String k) {
      final v = j[k];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    int? integer(String k) {
      final v = j[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v);
      return null;
    }

    final signer = normalizeFingerprint(str('signerSha256') ?? signerSha256);
    return AppRelease(
      tag: tag,
      versionName: str('versionName') ?? versionName,
      versionCode: integer('versionCode') ?? versionCode,
      packageName: str('packageName') ?? packageName,
      apkUrl: apkUrl,
      sha256: str('sha256')?.toLowerCase() ?? sha256,
      signerSha256: signer.isEmpty ? null : signer,
      size: integer('size') ?? size,
      minSdk: integer('minSdk') ?? minSdk,
      notes: notes,
      htmlUrl: htmlUrl,
      publishedAt: DateTime.tryParse(str('publishedAt') ?? '') ?? publishedAt,
      prerelease: prerelease,
      iconUrl: iconUrl,
      appJsonUrl: appJsonUrl,
    );
  }

  Map<String, dynamic> toJson() => {
        'tag': tag,
        'versionName': versionName,
        'versionCode': versionCode,
        'packageName': packageName,
        'apkUrl': apkUrl,
        'sha256': sha256,
        'signerSha256': signerSha256,
        'size': size,
        'minSdk': minSdk,
        'notes': notes,
        'htmlUrl': htmlUrl,
        'publishedAt': publishedAt?.toUtc().toIso8601String(),
        'prerelease': prerelease,
        'iconUrl': iconUrl,
        'appJsonUrl': appJsonUrl,
      };

  /// Z mapy: pamięć podręczna albo pole `latest` dokumentu aplikacji w Firestore.
  /// `publishedAt` może być tekstem ISO albo DateTime (Timestamp zamieniony wcześniej).
  static AppRelease? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final j = raw.map((k, v) => MapEntry(k.toString(), v));
    final apkUrl = j['apkUrl'];
    final tag = j['tag'];
    if (apkUrl is! String || apkUrl.isEmpty || tag is! String) return null;
    final published = j['publishedAt'];
    return AppRelease(
      tag: tag,
      versionName: (j['versionName'] as String?) ?? versionFromTag(tag, ''),
      versionCode: (j['versionCode'] as num?)?.toInt(),
      packageName: j['packageName'] as String?,
      apkUrl: apkUrl,
      sha256: (j['sha256'] as String?)?.toLowerCase(),
      signerSha256: j['signerSha256'] as String?,
      size: (j['size'] as num?)?.toInt() ?? 0,
      minSdk: (j['minSdk'] as num?)?.toInt(),
      notes: (j['notes'] as String?) ?? '',
      htmlUrl: (j['htmlUrl'] as String?) ?? '',
      publishedAt: published is DateTime ? published : DateTime.tryParse('${published ?? ''}'),
      prerelease: j['prerelease'] == true,
      iconUrl: j['iconUrl'] as String?,
      appJsonUrl: j['appJsonUrl'] as String?,
    );
  }
}

/// Wybór wydania z listy `GET /repos/{owner}/{repo}/releases` (najnowsze pierwsze).
/// Bierze pierwsze wydanie, które: nie jest szkicem, pasuje tagiem do [tagPrefix],
/// nie jest pre-release (chyba że [includePrerelease]) i ma plik APK.
/// APK: dokładnie `<assetName>.apk`, a gdy go brak - pierwszy plik .apk.
AppRelease? pickGithubRelease(
  List<dynamic> releases, {
  required String tagPrefix,
  required String assetName,
  bool includePrerelease = false,
}) {
  for (final r in releases) {
    if (r is! Map) continue;
    if (r['draft'] == true) continue;
    final pre = r['prerelease'] == true;
    if (pre && !includePrerelease) continue;
    final tag = (r['tag_name'] ?? '').toString();
    if (!tagMatchesPrefix(tag, tagPrefix)) continue;

    Map? apk, firstApk, appJson, icon;
    final wanted = '${assetName.trim().toLowerCase()}.apk';
    final assets = (r['assets'] as List?) ?? const [];
    for (final a in assets) {
      if (a is! Map) continue;
      final name = (a['name'] ?? '').toString().toLowerCase();
      final url = (a['browser_download_url'] ?? '').toString();
      if (!isTrustedDownloadUrl(url)) continue;
      if (name == wanted) apk = a;
      if (name.endsWith('.apk')) firstApk ??= a;
      if (name == 'app.json') appJson = a;
      if (name == 'icon.png') icon = a;
    }
    apk ??= firstApk;
    if (apk == null) continue;

    final digest = (apk['digest'] ?? '').toString().trim().toLowerCase();
    return AppRelease(
      tag: tag,
      versionName: versionFromTag(tag, tagPrefix),
      apkUrl: apk['browser_download_url'].toString(),
      sha256: RegExp(r'^sha256:[0-9a-f]{64}$').hasMatch(digest) ? digest.substring(7) : null,
      size: (apk['size'] as num?)?.toInt() ?? 0,
      notes: (r['body'] ?? '').toString().trim(),
      htmlUrl: (r['html_url'] ?? '').toString(),
      publishedAt: DateTime.tryParse((r['published_at'] ?? '').toString()),
      prerelease: pre,
      iconUrl: icon?['browser_download_url']?.toString(),
      appJsonUrl: appJson?['browser_download_url']?.toString(),
    );
  }
  return null;
}

/// Pliki pobieramy tylko po HTTPS z GitHuba (strona wydania i jego serwery plików).
bool isTrustedDownloadUrl(String? url) {
  final u = url == null ? null : Uri.tryParse(url);
  if (u == null || u.scheme != 'https') return false;
  final h = u.host.toLowerCase();
  return h == 'github.com' || h.endsWith('.github.com') || h.endsWith('.githubusercontent.com');
}
