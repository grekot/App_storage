# Sklep rodzinny – prywatna dystrybucja moich aplikacji Android

## Cel

Aplikacja na Androida w stylu Google Play, w której wybrane osoby (rodzina) widzą katalog
moich aplikacji, instalują je jednym stuknięciem i dostają aktualizacje. Ja publikuję nową
wersję tak jak dziś (`git tag vX.Y.Z`), a reszta dzieje się sama.

## Stan realizacji (2026-10-17)

Kod wszystkich etapów jest gotowy i przetestowany lokalnie. **Nic nie jest jeszcze wypchnięte
na GitHub ani opublikowane w Firebase.** Kroki ręczne: [README.md](README.md), sekcja
„Uruchomienie od zera”.

| Etap | Stan | Gdzie |
|---|---|---|
| 0 – wspólny workflow, jeden klucz podpisu | gotowe lokalnie; buildy release GPS RTK i Zakupów podpisane wspólnym kluczem | `.github/workflows/flutter-android-release.yml`; gałęzie `sklep-ci` w EscapeRoom i GPS_RTK; nowe repo T_rex_3 (`main`) |
| 1 – MVP sklepu | gotowe; `flutter analyze` czysto, testy jednostkowe przechodzą, APK debug i release się budują | `app/` |
| 2 – wersje z CI, podpis, zaproszenia | gotowe; reguły przetestowane na emulatorze | `tools/ci-publish/`, `firebase/` |
| 3 – powiadomienia, „kto ma którą wersję”, kanał beta | gotowe | `app/lib/services/notifications.dart`, zakładka „Wersje” |
| 4 – „W Sklepie” w aplikacjach | gotowe w EscapeRoom i GPS RTK | gałęzie `sklep-ci` |

Odstępstwa od planu poniżej:
- CI zapisuje tylko pole `latest` dokumentu aplikacji. Podkolekcja historii `releases/` okazała się zbędna.
- Nie użyto `setRequestUpdateOwnership`. Blokowałoby to ręczne `adb install` przy rozwoju aplikacji.
- Katalog wybiera wydanie z listy `releases` (z filtrem prefiksu tagu), a nie z `releases/latest`.
  Działa to także w monorepo T_rex_3.
- Firestore ma jeden zestaw reguł. Jedynym źródłem jest teraz `firebase/firestore.rules`
  (Zakupy + Powrót + Sklep).
- Ikona aplikacji w katalogu pochodzi z `icon.png`, którą CI wyciąga z APK.
  Ręczny adres ikony jest opcjonalny.
- Zakupy i Powrót nie mają przycisku „W Sklepie”. Nie miały własnej samoaktualizacji.

## Co już mam (stan na 2026-10-17, przegląd `C:\TMP\My_GIT`)

| Obszar | Jak jest teraz | Gdzie |
|---|---|---|
| Framework | Flutter 3.41 / Dart 3.11; aplikacje Android (+ Windows w EscapeRoom) | EscapeRoom, GPS_RTK/app, T_rex_3/{lista-zakupow,powrot}/phone |
| Backend | **Firebase, projekt `zakupy-8ec54`** (plan Spark): Auth e-mail/hasło, Firestore (europe-central2), AI Logic | T_rex_3/lista-zakupow/firebase/KONFIGURACJA.md |
| Konta i grupy | pakiet **`wspolne`**: `AccountRepository` (znajomi, książka adresowa `emails/{e-mail} → uid`, udostępnianie przez `members[]` + `memberEmails{}`), ekrany logowania / znajomych / udostępniania; reguły z `validMembersChange()` | T_rex_3/wspolne, T_rex_3/lista-zakupow/firebase/firestore.rules |
| Publikacja | **GitHub Releases**: tag `v*` → GitHub Actions buduje APK → `softprops/action-gh-release` (notatki generowane automatycznie) | EscapeRoom/.github/workflows/release.yml, GPS_RTK/.github/workflows/release-apk.yml |
| Aktualizacja w apce | `GET api.github.com/repos/{owner}/{repo}/releases/latest` (publiczne repo, bez tokena) → porównanie wersji → pobranie `.apk` do cache → `FileProvider` + `ACTION_VIEW` (`REQUEST_INSTALL_PACKAGES`). GPS RTK dodatkowo: weryfikacja SHA-256 z pola `digest`, limity czasu i rozmiaru, anulowanie | GPS_RTK/app/lib/services/update_service.dart, EscapeRoom/lib/core/update/app_update.dart, EscapeRoom/.../MainActivity.kt |
| Podpisywanie | **niespójne**: EscapeRoom – własny keystore (sekrety `KEYSTORE_*`, lokalnie `android/key.properties`); GPS RTK – CI publikuje APK **debug**; Zakupy/Powrót – klucz debug, build lokalny (`build_apk.cmd`, `--split-per-abi`) | build.gradle.kts w każdej apce |
| Repozytoria | EscapeRoom i GPS_RTK: publiczne na `github.com/grekot`. **T_rex_3 (Zakupy, Powrót) nie ma repozytorium z remote** | – |
| Identyfikatory | `pl.escaperoom.escape_room`, `pl.gpsrtk.gps_rtk_app`, `pl.grekot.zakupy`, `pl.grekot.powrot` | – |

Wniosek: 80 % klocków już istnieje. Sklep to w zasadzie **katalog w Firestore + istniejący
mechanizm GitHub Releases + istniejący `wspolne`**, zebrane w jednej apce.

## Decyzje architektoniczne

1. **Flutter**, nie Kotlin – reużycie `wspolne` (logowanie, znajomi, model `members`) i wzorca
   `MethodChannel` z EscapeRoom na część natywną (instalator, odczyt wersji innych pakietów).
2. **Ten sam projekt Firebase `zakupy-8ec54`** – rodzina ma już konta z Zakupów/Powrotu; te same
   konta logują się do sklepu, działa książka adresowa `emails`.
3. **Pliki APK zostają w GitHub Releases** (darmowo, bez limitu transferu, 2 GB/plik). Katalog
   (kto co widzi) jest prywatny w Firestore; same pliki są publiczne „dla znających link”.
   Dla rodziny wystarczy. Ścieżki na później, gdyby APK miały być naprawdę prywatne:
   - repo prywatne + fine-grained PAT (tylko „Contents: read”, tylko wybrane repo) trzymany w
     Firestore w dokumencie czytelnym wyłącznie dla członków grupy; sklep pobiera assety przez
     API (`Accept: application/octet-stream`). Token ma datę ważności – trzeba odnawiać.
   - Firebase Storage z regułami na Auth – dziś wymaga planu Blaze (karta; w darmowych limitach
     realnie 0 zł).
4. **Jeden wspólny klucz podpisu release** dla wszystkich aplikacji (ten z EscapeRoom). Android
   nie zaktualizuje apki podpisanej innym kluczem – bez tego sklep nie zadziała. Koszt:
   Zakupy, Powrót i GPS RTK (dziś klucz debug) trzeba na każdym telefonie **raz odinstalować
   i zainstalować ze sklepu** (dane Zakupów/Powrotu są w Firestore, nic nie ginie; GPS RTK –
   punkty w pamięci telefonu, wyeksportować wcześniej).
5. **Stałe nazwy assetów** w release (`escape_room.apk`, nie `escape_room-1.2.0.apk`) → stały
   link `github.com/{owner}/{repo}/releases/latest/download/escape_room.apk`. Przydatne do QR
   i do bootstrapu samego sklepu.
6. **Metadane release w pliku `app.json`** dołączanym do każdego wydania przez CI:
   `packageName, versionName, versionCode, minSdk, sha256, size, abi`. Sklep nie musi zgadywać
   `versionCode` z tagu; a od etapu 2 CI wpisuje to samo do Firestore.

## Architektura

```
 JA                         GITHUB                              FIREBASE (zakupy-8ec54)         TELEFON CZŁONKA RODZINY
 git tag v1.3.0 ──► Actions (wspólny workflow):          groups/{gid}: members[]           Sklep (Flutter)
                     build + podpis wspólnym kluczem      groups/{gid}/apps/{appId}:        ├ logowanie (wspolne)
                     ──► Release: app.apk + app.json      nazwa, opis, pkg, repo, ikona     ├ katalog ◄── Firestore (realtime)
                     ──► (etap 2) zapis wersji            (etap 2) …/apps/{id}/releases/*   ├ „Aktualizuj 1.2 → 1.3" ◄── GitHub API / Firestore
                         do Firestore (service account)   (etap 3) FCM topic „apps"         ├ pobierz ──► SHA-256 ──► podpis ──► instalator
                     ──► (etap 3) push FCM                                                  └ self-update tym samym torem
```

### Dane w Firestore (rozszerzenie istniejących reguł)

```
groups/{groupId}                      name, ownerId, members[], memberEmails{uid: e-mail}, createdAt
groups/{groupId}/apps/{appId}         name, description, packageName, repo ("grekot/EscapeRoom"),
                                      assetName ("escape_room.apk"), iconUrl, order, hidden
groups/{groupId}/apps/{appId}/releases/{versionName}   (etap 2, pisze CI) versionCode, apkUrl, sha256,
                                      size, notes, publishedAt, minSdk, prerelease
invites/{code}                        (etap 2) groupId, createdBy, expiresAt, usesLeft
users/{uid}/installs/{packageName}    (etap 3) versionName, versionCode, installedAt, device
emails/{e-mail}                       już jest (książka adresowa)
```

Reguły: `groups` – dokładnie wzorzec `lists`/`places` (`validMembersChange`); `apps` i
`releases` – odczyt `isMember(groupId)`, zapis tylko `ownerId` grupy (CI pisze przez Admin SDK,
który omija reguły). Jedna grupa „Rodzina” na start; model pozwala później na „Dzieci” czy
„Testerzy” (pre-release widoczne tylko tam).

### Aplikacja sklepu – ekrany

| Ekran | Co robi |
|---|---|
| Logowanie | `LoginScreen` z `wspolne` (konto wspólne z Zakupami/Powrotem) |
| Katalog | kafelki: ikona, nazwa, stan **Zainstaluj / Aktualizuj (1.2 → 1.3) / Otwórz**; pociągnij-odśwież |
| Szczegóły | opis, changelog (notatki release), rozmiar, data, lista wersji; przycisk akcji z paskiem postępu |
| Pierwsze uruchomienie | kreator: zgoda „Instaluj nieznane aplikacje” dla sklepu (jednorazowo, systemowe ustawienia) |
| Panel właściciela (tylko `ownerId`) | dodaj/edytuj aplikację (nazwa, repo, package, ikona), członkowie (dodaj po e-mailu – jak znajomi), grupy |
| Ustawienia | sprawdzanie w tle, powiadomienia, „Sprawdź aktualizację sklepu” |

### Część natywna (Kotlin, `MethodChannel pl.grekot.sklep/installer`)

- `installedVersion(pkg)` → `versionName`/`versionCode` lub `null`. Wymaga widoczności pakietów:
  w manifeście `<queries><intent><action MAIN/><category LAUNCHER/></intent></queries>` (widzi
  wszystkie apki z ikoną, bez wpisywania pakietów na sztywno); poza Google Play dopuszczalne też
  `QUERY_ALL_PACKAGES`.
- `installApk(path)` → `PackageInstaller` (sesja + `PendingIntent` ze statusem; postęp i wynik
  wracają do Fluttera) zamiast `ACTION_VIEW`. Android 14+: `setRequestUpdateOwnership(true)` –
  sklep staje się „właścicielem aktualizacji”.
- `apkSignerSha256(path)` → odcisk certyfikatu podpisu pobranego APK; sklep instaluje tylko,
  gdy zgadza się z moim kluczem (obrona przed podmienionym plikiem lepsza niż sam SHA-256).
- `canInstallUnknownApps()` / `openInstallSettings()`, `launch(pkg)`.
- Do sprawdzenia w etapie 2: Android 12+ z uprawnieniem `UPDATE_PACKAGES_WITHOUT_USER_ACTION`
  pozwala aktualizować **bez dialogu systemowego** apki, które sklep sam zainstalował i które
  nie dodają nowych uprawnień. Pierwsza instalacja zawsze z potwierdzeniem.

### Dystrybucja samego sklepu (bootstrap)

Jedyna rzecz instalowana ręcznie. Strona (GitHub Pages w repo sklepu) z kodem QR do stałego
linku `…/releases/latest/download/sklep.apk` i trzema krokami: pobierz → zezwól → zaloguj.
Potem sklep aktualizuje się sam (`UpdateService` z GPS RTK praktycznie 1:1).

## Etapy

### Etap 0 – fundamenty publikacji (bez sklepu; 1–2 wieczory)

1. **Wspólny workflow** `release.yml` (`workflow_call` w repo `grekot/.github` albo kopiowany):
   wejścia `app_dir`, `asset_name`; sekrety `KEYSTORE_*`; kroki: analyze + test → build release
   z `--build-name=<tag>` `--build-number=<run_number>` → `app.json` + SHA-256 → Release ze
   stałą nazwą assetu. Wzorzec: EscapeRoom (podpis) + GPS_RTK (bramka jakości).
2. Przepiąć **EscapeRoom** (zmiana nazwy assetu) i **GPS RTK** (release zamiast debug, podpis).
3. **Zakupy i Powrót** na GitHub. Dwie opcje: repo per aplikacja (jak dotąd) albo źródła
   prywatne + wydania publikowane do osobnego publicznego repo `grekot/wydania`
   (`action-gh-release` ma wejście `repository`; release nie wymaga źródeł). Dodać podpis
   wspólnym kluczem.
4. `wspolne` dostępne spoza T_rex_3: osobne repo albo zależność `git:` z `path:` – sklep
   nie może używać `path: ../../T_rex_3/wspolne`.

### Etap 1 – MVP sklepu (tydzień wieczorami)

1. Projekt Flutter `app/` (package `pl.grekot.sklep`), rejestracja w Firebase `zakupy-8ec54`.
2. Logowanie z `wspolne`; `groups` + `apps` w Firestore, reguły; panel właściciela
   (dodaj aplikację, dodaj członka po e-mailu).
3. Katalog realtime; wersje **na żywo z GitHub API** (`parseRelease` z GPS RTK): 1 zapytanie na
   aplikację przy odświeżeniu, cache 15 min (limit 60/h na IP bez tokena).
4. Pobieranie (postęp, SHA-256, limity – kod z GPS RTK) → kanał natywny → instalator;
   odczyt zainstalowanych wersji; stan kafelka.
5. Self-update sklepu; strona bootstrap z QR; instrukcja dla rodziny w `docs/`.
6. Testy jednostkowe logiki bez sieci (porównanie wersji, parsowanie release, plan stanu kafelków).

### Etap 2 – automatyzacja i bezpieczeństwo

1. CI po wydaniu zapisuje `releases/{version}` do Firestore (service account JSON w sekretach,
   `firebase-admin` w kroku Node albo REST). Sklep przestaje pytać GitHub o wersje – ma je
   realtime, z changelogiem i `versionCode`; GitHub służy tylko do pobierania.
2. Weryfikacja certyfikatu podpisu APK przed instalacją.
3. Zaproszenia kodem/QR (`invites/{code}`): nowa osoba zakłada konto, wpisuje kod → sama dopisuje
   się do grupy (reguła sprawdza ważność kodu). Bez tego właściciel musi wiedzieć, że ktoś już
   założył konto.
4. Aktualizacje bez dialogu (`UPDATE_PACKAGES_WITHOUT_USER_ACTION`) – zweryfikować na urządzeniu.

### Etap 3 – powiadomienia i podgląd

1. **FCM** (darmowe, bez Cloud Functions): krok CI wysyła wiadomość do tematu `apps` przez
   FCM HTTP v1 tym samym service accountem → telefony dostają „Nowa wersja Zakupów 1.4”.
   Alternatywa bez serwera: `workmanager` + lokalne powiadomienie co kilka godzin.
2. `users/{uid}/installs` – ekran właściciela „kto ma którą wersję”.
3. Kanał beta: `prerelease` w GitHub → widoczny tylko dla grupy „Testerzy”.

### Etap 4 – porządki

- W aplikacjach: „Sprawdź aktualizacje” → „Otwórz w Sklepie” (intent do sklepu z `package`);
  wspólny kod aktualizacji do pakietu obok `wspolne`.
- Windows: sklep raczej nie; wydania Windows (EscapeRoom) zostają linkiem na stronie release.

## Struktura repo

```
App_storage/              (nazwa robocza; docelowo np. Sklep)
  PROJEKT.md              ten dokument
  app/                    Flutter: lib/{auth,catalog,install,admin,update}, android/…/MainActivity.kt
  firebase/firestore.rules  reguły groups/apps/releases/invites (łączone z regułami Zakupów)
  ci/release.yml          wspólny workflow dla wszystkich aplikacji + skrypt zapisu do Firestore
  docs/                   strona bootstrap (QR), instrukcja dla rodziny
  .github/workflows/      wydania samego sklepu (ten sam workflow)
```

## Alternatywa bez pisania kodu (dla uczciwości)

**Obtainium** (open source) śledzi GitHub Releases wskazanych repozytoriów i instaluje
aktualizacje – robi dokładnie to, co etap 1, bez katalogu i bez logowania. Każdy członek rodziny
musi jednak sam dodać każdą aplikację (jest import/eksport listy). Drugi klasyk: prywatne repo
**F-Droid** (`fdroidserver` + GitHub Pages) i klient F-Droid. Własny sklep wygrywa tym, że:
jedno konto wspólne z Zakupami/Powrotem, katalog kontroluję ja, rodzina nic nie konfiguruje,
powiadomienia push.

## Ryzyka i uwagi

- **Zmiana klucza podpisu** = jednorazowa reinstalacja apek z kluczem debug (patrz Decyzje, pkt 4).
- **Limit GitHub API** 60 zapytań/h na adres IP (etap 1); znika w etapie 2.
- **Publiczne APK** – każdy ze znalezionym linkiem pobierze plik; w aplikacjach nie ma sekretów
  (Firebase chronią reguły), więc akceptowalne. Ścieżki na prywatność opisane w Decyzjach, pkt 3.
- **Dialog systemowy** przy każdej instalacji jest normą poza Google Play; ominięcie przy
  aktualizacjach – tylko w warunkach z etapu 2, pkt 4.
- **`versionCode`** musi rosnąć: `github.run_number` jest monotoniczny w obrębie repo; przy
  przenosinach Zakupów do nowego repo numer startuje od 1 – ustawić offset wyższy niż dotychczasowy.
- **`wspolne`** poza T_rex_3 – inaczej sklep nie zbuduje się w CI (etap 0, pkt 4).

## Otwarte decyzje

1. Nazwa i `applicationId` sklepu (propozycja: `pl.grekot.sklep`).
2. APK publiczne w GitHub Releases (rekomendacja na start) czy od razu prywatne.
3. Zakupy/Powrót: repo per aplikacja czy wspólne repo wydań `grekot/wydania`.
4. Start od etapu 0 (fundamenty) czy równolegle etap 0 i szkielet etapu 1.
