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
- **Grupy** (`groups/{gid}`): właściciel dodaje osoby po e-mailu albo daje im kod zaproszenia
  (ważny 7 dni, wiele użyć). Członek widzi aplikacje grupy i może z niej wyjść.
- **Aplikacje** (`groups/{gid}/apps`): nazwa, repozytorium GitHub, prefiks tagów (`v` albo
  `zakupy-v` w monorepo), nazwa pliku APK. Przycisk „Sprawdź na GitHubie” sam uzupełnia pakiet.
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

6. **Rodzina**: zakładka Zaproszenia → Nowy kod → „Kopiuj wiadomość” i wysłać.

## Testy

| Co | Polecenie |
|---|---|
| Aplikacja (logika wersji, wydań, pobierania) | `cd app && flutter test` |
| Reguły Firestore na emulatorze | `cd firebase/test && npm ci && npm test` |
| Skrypt publikacji z CI | `cd tools/ci-publish && npm ci && npm test` |

Wszystko uruchamia też `.github/workflows/ci.yml` przy każdym pushu.
