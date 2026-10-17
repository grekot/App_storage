/// Porównanie wersji i decyzja, co pokazać na przycisku aplikacji.
/// Czysta logika - testowana bez Fluttera i sieci.
library;

/// Porównuje wersje "1.2.10" i "v1.2.9" numerycznie po segmentach.
/// Wiodące "v" i sufiks po "+", "-" lub spacji są pomijane, brakujące segmenty = 0.
int compareVersionNames(String a, String b) {
  final pa = _parts(a), pb = _parts(b);
  final n = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < n; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

List<int> _parts(String v) {
  final core = v.trim().replaceFirst(RegExp(r'^[vV]'), '').split(RegExp(r'[+\-\s]')).first;
  if (core.isEmpty) return const [];
  return core.split('.').map((s) => int.tryParse(s.trim()) ?? 0).toList();
}

/// Wersja z tagu: "zakupy-v1.2.0" przy prefiksie "zakupy-v" -> "1.2.0", "v1.2.0" -> "1.2.0".
String versionFromTag(String tag, String tagPrefix) {
  var t = tag.trim();
  if (tagPrefix.isNotEmpty && t.startsWith(tagPrefix)) t = t.substring(tagPrefix.length);
  return t.replaceFirst(RegExp(r'^[vV]'), '');
}

/// Czy tag należy do aplikacji o danym prefiksie. Prefiks "v" (zwykłe repo jednej aplikacji)
/// akceptuje "v1.2.0" i "1.2.0"; dłuższy prefiks musi pasować dokładnie i po nim musi być cyfra.
bool tagMatchesPrefix(String tag, String tagPrefix) {
  final t = tag.trim();
  final p = tagPrefix.trim();
  if (p.isEmpty || p == 'v' || p == 'V') return RegExp(r'^[vV]?\d').hasMatch(t);
  if (!t.startsWith(p)) return false;
  return RegExp(r'^[vV]?\d').hasMatch(t.substring(p.length));
}

/// Stan aplikacji w katalogu.
enum AppStatus {
  /// brak wydania i aplikacja nie jest zainstalowana
  unavailable,

  /// jest wydanie, aplikacji nie ma na telefonie
  notInstalled,

  /// zainstalowana starsza wersja
  updateAvailable,

  /// zainstalowana jest najnowsza wersja (albo nie znamy wydania)
  upToDate,

  /// zainstalowana nowsza niż wydanie (np. build deweloperski)
  newerInstalled,

  /// nowsza wersja jest podpisana innym kluczem niż zainstalowana -
  /// Android jej nie zaktualizuje, trzeba odinstalować i zainstalować ponownie
  needsReinstall,
}

/// Decyzja na podstawie zainstalowanej wersji i najnowszego wydania.
/// [installedCode]/[releaseCode] - versionCode (pewniejszy); gdy brak kodu wydania, porównujemy nazwy.
AppStatus decideStatus({
  required bool installed,
  String? installedName,
  int? installedCode,
  String? installedSigner,
  required bool hasRelease,
  String? releaseName,
  int? releaseCode,
  String? releaseSigner,
}) {
  if (!hasRelease) return installed ? AppStatus.upToDate : AppStatus.unavailable;
  if (!installed) return AppStatus.notInstalled;

  int cmp;
  if (releaseCode != null && installedCode != null) {
    cmp = releaseCode.compareTo(installedCode);
  } else {
    cmp = compareVersionNames(releaseName ?? '', installedName ?? '');
  }
  if (cmp < 0) return AppStatus.newerInstalled;
  if (cmp == 0) return AppStatus.upToDate;

  final a = installedSigner?.toLowerCase(), b = releaseSigner?.toLowerCase();
  if (a != null && a.isNotEmpty && b != null && b.isNotEmpty && a != b) return AppStatus.needsReinstall;
  return AppStatus.updateAvailable;
}

/// Czy wolno zainstalować APK o podpisie [apkSigner].
/// Zaufane są: klucz, którym podpisano sam sklep, klucze z listy grupy oraz -
/// dla aktualizacji - klucz już zainstalowanej aplikacji (i tak wymusza go Android).
bool isSignerTrusted({
  required String? apkSigner,
  String? storeSigner,
  Iterable<String> trustedSigners = const [],
  String? installedSigner,
}) {
  final s = _norm(apkSigner);
  if (s.isEmpty) return false;
  if (s == _norm(storeSigner)) return true;
  if (trustedSigners.map(_norm).contains(s)) return true;
  return s == _norm(installedSigner);
}

/// Odcisk SHA-256 w formie małych liter bez dwukropków i spacji.
String normalizeFingerprint(String? v) => _norm(v);

String _norm(String? v) => (v ?? '').replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
