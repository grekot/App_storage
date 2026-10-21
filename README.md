# Sklep rodzinny

Prywatny „Google Play” dla moich aplikacji na Androida. Członkowie grupy instalują sklep raz,
a potem instalują i aktualizują przez niego wszystkie udostępnione im aplikacje.
Plan i decyzje: [PROJEKT.md](PROJEKT.md).

```
 git tag ──► GitHub Actions (wspólny workflow) ──► GitHub Release: <app>.apk + app.json + icon.png
                         │                                      ▲
                         └─► Firestore: latest + FCM push        │ pobranie APK
                                      │                          │
                     Sklep (Flutter) ◄┘ katalog grupy ──► SHA-256 ──► podpis ──► PackageInstaller
```

| Folder | Co to jest |
|---|---|
| [`app/`](app/) | aplikacja sklepu (Flutter, `pl.grekot.sklep`) |
| [`firebase/`](firebase/) | reguły Firestore całego projektu, [konfiguracja](firebase/KONFIGURACJA.md), testy reguł na emulatorze |
| [`.github/workflows/flutter-android-release.yml`](.github/workflows/flutter-android-release.yml) | wspólny workflow wydań dla wszystkich aplikacji |
| [`tools/ci-publish/`](tools/ci-publish/) | krok CI: zapis wersji do Firestore + powiadomienie FCM |
| [`tools/configure.mjs`](tools/configure.mjs) | `google-services.json` → `app/lib/firebase_options.dart` |
| [`docs/`](docs/) | strona startowa z kodem QR (GitHub Pages), [kroki ręczne etapu 0](docs/ETAP0-kroki-reczne.md) |

## Jak działa sklep

- **Konto**: logowanie z pakietu `wspolne` (T_rex_3). To samo konto co w Zakupach i Powrocie.
- **Administrator**: tylko on zakłada grupy i zarządza aplikacjami, osobami, zaproszeniami
  i zaufanymi kluczami. Lista administratorów jest w regułach (`firebase/firestore.rules` → `isAdmin`)
  i w aplikacji (`app/lib/config.dart` → `adminUids`). Zmiana listy wymaga obu miejsc i publikacji reguł.
- **Grupy** (`groups/{gid}`): administrator dodaje osoby po e-mailu albo daje im kod zaproszenia
  (ważny 7 dni, wiele użyć). Członek tylko widzi swoje grupy i ich aplikacje, nie może też sam
  z grupy wyjść (usuwa go administrator).
- **Biblioteka** (`library/{pakiet}`, widzi tylko administrator): wszystkie aplikacje z nazwą,
  repozytorium GitHub, prefiksem tagów (`v` albo `zakupy-v` w monorepo) i plikiem APK.
  Każde wydanie przez wspólny workflow trafia tu samo.
- **Przypisania**: grupa widzi tylko aplikacje, które administrator jej przypisał (kopie wpisów
  w `groups/{gid}/apps`). W aplikacji: menu → Zarządzanie → Aplikacje / Grupy / Osoby (zaznaczanie).
- **Wersje**: z pola `latest` zapisanego przez CI, a gdy go nie ma, z GitHub API
  (pamięć 15 minut i zapytania warunkowe, żeby nie przekroczyć 60 zapytań na godzinę).
- **Instalacja**: pobranie tylko z GitHuba po HTTPS, kontrola SHA-256, kontrola pakietu i
  **podpisu** (zaufany jest klucz samego sklepu i klucze z listy grupy), potem `PackageInstaller`.
  Na Androidzie 12+ aktualizacje aplikacji zainstalowanych przez sklep mogą przejść bez okna systemowego.
- **Inny podpis** niż zainstalowana wersja: sklep od razu proponuje odinstalowanie i ponowną instalację.
- **Samoaktualizacja**: sklep sprawdza własne wydania (`grekot/App_storage`, `sklep.apk`).
- **Powiadomienia**: temat FCM `app_<pakiet>` dla każdej aplikacji z katalogu.
- **Kto ma którą wersję**: sklep zgłasza zainstalowane wersje, właściciel widzi je w zakładce „Wersje”.
- **Linki**: `grekot-sklep://app/<pakiet>` otwiera kartę aplikacji (przycisk „W Sklepie”
  w EscapeRoom i GPS RTK), `grekot-sklep://join/<kod>` dołącza do grupy.

## Zarządzanie z komputera: polecenie `sklep`

W folderze `App_storage` (Windows: `sklep.cmd`, wszędzie: `node tools/sklep-cli/sklep.mjs`):

```bash
sklep login
```

Logowanie jest jednorazowe, kontem z Zakupów. Sesja leży w `%APPDATA%\sklep-rodzinny\sesja.json`,
hasło nie jest zapisywane. Polecenie działa przez te same reguły Firestore co telefon.

| Polecenie | Co robi |
|---|---|
| `sklep status` | grupy, ich osoby i aplikacje, nieprzypisane aplikacje |
| `sklep aplikacje` | cała biblioteka i grupy każdej aplikacji |
| `sklep dodaj grekot/EscapeRoom` | dodaje aplikację do biblioteki; pakiet, nazwę i plik odczytuje z wydania |
| `sklep przypisz zakupy --grupa Domowa,Rodzice` | udostępnia aplikację grupom (`odepnij` zabiera) |
| `sklep nowa-grupa Rodzice --osoby zona@example.com` | nowa grupa z osobami |
| `sklep uzytkownicy` | wszystkie konta i ich grupy |
| `sklep dodaj-osobe ania@example.com --grupa Domowa` | dodaje osobę do grup (`usun-osobe` usuwa) |
| `sklep ustaw zakupy --opis "…" --kolejnosc 1` | zmiana nazwy, opisu, kolejności, ikony, bety, ukrycia |
| `sklep zaproszenie --grupa Domowa` | kod zaproszenia i gotowa wiadomość |
| `sklep wersje` | kto ma którą wersję |
| `sklep pomoc` | wszystkie polecenia |

**Nowe aplikacje nie trafiają same do grup.** Wydanie dopisuje je tylko do biblioteki, a do grup
przypisuje je administrator. Wyjątek: grupa z włączonym `autoAdd` (`sklep auto tak --grupa X`).

## Budowanie

Wymagania jak w innych projektach: Flutter 3.41, JDK 17, Android SDK.

```bash
cd app && flutter pub get && flutter analyze && flutter test
```

```bash
cd app && flutter build apk --release
```

Pakiet `wspolne` w `pubspec.yaml` pochodzi z `github.com/grekot/T_rex_3` (folder `wspolne`).
Lokalnie nadpisuje go ścieżką `app/pubspec_overrides.yaml` (poza gitem):

```yaml
dependency_overrides:
  wspolne:
    path: ../../T_rex_3/wspolne
```

Podpis release: `app/android/key.properties` (poza gitem, kopia z EscapeRoom, wspólny keystore).
Na Windows przy błędzie Gradle „Unable to establish loopback connection” ustaw `TEMP`/`TMP`
na `C:\TMP\jtmp`.

## Uruchomienie od zera (kolejność)

1. **Firebase**: [firebase/KONFIGURACJA.md](firebase/KONFIGURACJA.md). Rejestracja `pl.grekot.sklep`,
   `node tools/configure.mjs`, publikacja reguł, konto usługi dla CI.
2. **GitHub**: [docs/ETAP0-kroki-reczne.md](docs/ETAP0-kroki-reczne.md). Repozytoria App_storage
   i T_rex_3 jako **publiczne** (sklep pobiera APK bez tokena, a CI sklepu pobiera `wspolne` z T_rex_3),
   sekrety, scalenie gałęzi `sklep-ci`, pierwsze tagi.
   W App_storage dodatkowo sekrety `FIREBASE_OPTIONS_SKLEP_B64` i `FIREBASE_SERVICE_ACCOUNT`,
   a `FIREBASE_SERVICE_ACCOUNT` także w EscapeRoom, GPS_RTK i T_rex_3.
3. **GitHub Pages** dla App_storage: Settings → Pages → Branch `main`, folder `/docs`.
   Strona: <https://grekot.github.io/App_storage/>.
4. **Pierwsze wydanie sklepu**: `git tag v0.1.0 && git push origin v0.1.0`.
5. **W sklepie** (jako właściciel): menu → Grupy i aplikacje → Nowa grupa „Rodzina” →
   zakładka Podpisy → „Dodaj” przy kluczu tego sklepu → Aplikacje → dodaj:

   | Nazwa | Repozytorium | Prefiks tagów | Plik APK | Pakiet |
   |---|---|---|---|---|
   | Pokój Zagadek AI | `grekot/EscapeRoom` | `v` | `escape_room` | `pl.escaperoom.escape_room` |
   | GPS RTK | `grekot/GPS_RTK` | `v` | `gps_rtk` | `pl.gpsrtk.gps_rtk_app` |
   | Zakupy | `grekot/T_rex_3` | `zakupy-v` | `zakupy` | `pl.grekot.zakupy` |
   | Powrót | `grekot/T_rex_3` | `powrot-v` | `powrot` | `pl.grekot.powrot` |
   | Na szczycie | `grekot/T_rex_3` | `naszczycie-v` | `naszczycie` | `pl.grekot.naszczycie` |

6. **Rodzina**: zakładka Zaproszenia → Nowy kod → „Kopiuj wiadomość” i wysłać.

## Testy

| Co | Polecenie |
|---|---|
| Aplikacja (logika wersji, wydań, pobierania) | `cd app && flutter test` |
| Reguły Firestore na emulatorze | `cd firebase/test && npm ci && npm test` |
| Skrypt publikacji z CI | `cd tools/ci-publish && npm ci && npm test` |

Wszystko uruchamia też `.github/workflows/ci.yml` przy każdym pushu.
