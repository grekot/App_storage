/// Stałe sklepu.
class StoreConfig {
  const StoreConfig._();

  /// Repozytorium, z którego sklep aktualizuje sam siebie (GitHub Releases).
  static const selfRepo = 'grekot/App_storage';

  /// Nazwa pliku APK sklepu w wydaniu (stała, bez numeru wersji).
  static const selfAsset = 'sklep';

  /// Tagi wydań sklepu: v1.2.0
  static const selfTagPrefix = 'v';

  /// Strona z instrukcją instalacji (GitHub Pages z folderu docs/).
  static const homePage = 'https://grekot.github.io/App_storage/';

  /// Ile ważne jest zaproszenie do grupy.
  static const inviteValidity = Duration(days: 7);

  /// Jak długo pamiętamy odpowiedź GitHuba, zanim zapytamy ponownie
  /// (anonimowo: 60 zapytań na godzinę z jednego adresu IP).
  static const releaseCacheTtl = Duration(minutes: 15);

  /// Administratorzy sklepu: zakładają grupy i zarządzają aplikacjami, osobami i zaproszeniami.
  /// Pozostali tylko widzą swoje grupy i ich aplikacje. Tę samą listę egzekwują reguły
  /// Firestore (firebase/firestore.rules → isAdmin) - aplikacja jedynie ukrywa przyciski.
  static const adminUids = {
    '82qeJdUO8qbzhniNK6bE6xUEovW2', // grzegorz.kotarba@gmail.com
  };

  static bool isAdmin(String uid) => adminUids.contains(uid);

  /// Schemat linków: `grekot-sklep://app/PAKIET`, `grekot-sklep://join/KOD`
  static const linkScheme = 'grekot-sklep';
}
