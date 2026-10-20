# Etap 0 – kroki ręczne (GitHub)

Lokalnie wszystko jest gotowe i zbudowane (stan 2026-10-17). Niczego nie wypchnięto, nie
utworzono repozytoriów, sekretów ani tagów. Ten plik opisuje, co trzeba zrobić ręcznie
w przeglądarce / terminalu, żeby wydania zaczęły trafiać do sklepu.

| Repo | Gałąź lokalna | Co się zmieniło |
|---|---|---|
| `App_storage` | (repo prowadzi sesja sklepu) | `.github/workflows/flutter-android-release.yml` – wspólny workflow (`workflow_call`) |
| `EscapeRoom` | `sklep-ci` | `release.yml`: job android → wspólny workflow (`escape_room.apk` + `app.json`), zip Windows dołączany po nim |
| `GPS_RTK` | `sklep-ci` | podpis release z `key.properties`; `release-apk.yml`: build kontrolny na main, tag `v*` → wspólny workflow (`gps_rtk.apk`) |
| `T_rex_3` | `main` (nowe repo) | `git init`, `.gitignore`, podpis w Zakupach i Powrocie, `release-zakupy.yml`, `release-powrot.yml` |

Odcisk SHA-256 certyfikatu wspólnego klucza (publiczny, ma się zgadzać z `signerSha256`
w każdym `app.json`):

```
79d9af0dcfd2a5727fe9281fea579feae4391f9ebfad424149ef4b9b4549c14f
79:D9:AF:0D:CF:D2:A5:72:7F:E9:28:1F:EA:57:9F:EA:E4:39:1F:9E:BF:AD:42:41:49:EF:4B:9B:45:49:C1:4F
(certyfikat: CN=Pokoj Zagadek AI, OU=EscapeRoom, O=grekot, C=PL)
```

## 1. Repozytorium App_storage na GitHub (najpierw!)

Wszystkie aplikacje wołają `grekot/App_storage/.github/workflows/flutter-android-release.yml@main`,
więc ten plik musi być na `main` w GitHub **zanim** powstanie pierwszy tag w innym repo.

1. Na github.com → **New repository** → nazwa `App_storage`, właściciel `grekot`.
   - **Publiczne** (zalecane – w workflow nie ma sekretów), albo
   - prywatne, ale wtedy: *App_storage → Settings → Actions → General → Access* →
     **„Accessible from repositories owned by the user 'grekot'”**. Bez tego wywołania
     z innych repo kończą się błędem „workflow was not found”.
2. Wypchnij `main` z katalogu `C:\TMP\My_GIT\App_storage` (repo prowadzi sesja sklepu – upewnij
   się, że plik workflow jest w commicie):

   ```bash
   git -C /c/TMP/My_GIT/App_storage remote add origin https://github.com/grekot/App_storage.git
   ```

   ```bash
   git -C /c/TMP/My_GIT/App_storage push -u origin main
   ```

## 2. Sekrety (Settings → Secrets and variables → Actions → New repository secret)

Wartości haseł są w `C:\TMP\My_GIT\EscapeRoom\android\key.properties` (nie commitować, nie
wklejać nigdzie poza polem sekretu):

| Sekret | Skąd |
|---|---|
| `KEYSTORE_BASE64` | plik `C:\Users\grzegorz.kotarba\.escape_room\upload-keystore.jks` w base64 (polecenie niżej) |
| `KEYSTORE_PASSWORD` | `storePassword` z key.properties |
| `KEY_ALIAS` | `keyAlias` z key.properties (`upload`) |
| `KEY_PASSWORD` | `keyPassword` z key.properties |

Base64 keystore'a do schowka (PowerShell):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\Users\grzegorz.kotarba\.escape_room\upload-keystore.jks")) | Set-Clipboard
```

Base64 `firebase_options.dart` Zakupów do schowka (PowerShell):

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\TMP\My_GIT\T_rex_3\lista-zakupow\phone\lib\firebase_options.dart")) | Set-Clipboard
```

(Git Bash: `base64 -w0 <plik> | clip`.) Nie używaj `certutil -encode` – dodaje nagłówki.

Gdzie co ustawić:

| Repo | Sekrety |
|---|---|
| `grekot/EscapeRoom` | 4 × `KEYSTORE_*`/`KEY_*` – **prawdopodobnie już są** (używał ich stary release.yml); sprawdź listę |
| `grekot/GPS_RTK` | 4 × `KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD` |
| `grekot/T_rex_3` | 4 × jak wyżej + `FIREBASE_OPTIONS_ZAKUPY_B64` (base64 pliku `lista-zakupow/phone/lib/firebase_options.dart`) |
| `grekot/T_rex_3` (później) | `FIREBASE_OPTIONS_POWROT_B64` – gdy Powrót dostanie prawdziwą konfigurację (`node tools/configure.mjs`); dziś jego plik to zaślepka |
| `grekot/T_rex_3` (Korona) | `FIREBASE_OPTIONS_KORONA_B64` – base64 `korona/phone/lib/firebase_options.dart` (po dodaniu `pl.grekot.korona` w Firebase i `node tools/configure.mjs` w `korona/phone`) |
| `grekot/App_storage` | 4 × `KEYSTORE_*`/`KEY_*` + `FIREBASE_OPTIONS_SKLEP_B64` (base64 `app/lib/firebase_options.dart` sklepu) |
| wszystkie cztery | `FIREBASE_SERVICE_ACCOUNT` – JSON konta usługi Firebase: zapis nowej wersji w katalogu sklepu i powiadomienie push (opis: `firebase/KONFIGURACJA.md`, pkt 4). Bez niego wydania działają, tylko bez powiadomień |

Bez `KEYSTORE_BASE64` workflow i tak zbuduje APK, ale podpisany kluczem debug runnera
(ostrzeżenie w logu) – takiego wydania sklep nie przyjmie. Bez sekretu Firebase APK powstaje
z zaślepką `firebaseConfigured = false` (ostrzeżenie) – aplikacja pokaże „nieskonfigurowane”.

## 3. Repozytorium T_rex_3 na GitHub

Releases muszą być publiczne (sklep pobiera APK bez tokena), więc repo **publiczne**.
Konfiguracja Firebase (`firebase_options.dart`, `google-services.json`, `firebase-config.js`)
jest w `.gitignore` i nie trafiła do commita; w CI odtwarza ją sekret.

1. github.com → New repository → `T_rex_3`, **bez** README/.gitignore (repo lokalne już ma commit).
2. Wypchnij:

   ```bash
   git -C /c/TMP/My_GIT/T_rex_3 remote add origin https://github.com/grekot/T_rex_3.git
   ```

   ```bash
   git -C /c/TMP/My_GIT/T_rex_3 push -u origin main
   ```

## 4. Kolejność pushy

1. `App_storage` → `main` (pkt 1).
2. Sekrety we wszystkich trzech repo (pkt 2).
3. **EscapeRoom**: scal `sklep-ci` do `main` i wypchnij (push na main uruchamia tylko `ci.yml`):

   ```bash
   git -C /c/TMP/My_GIT/EscapeRoom checkout main
   ```

   ```bash
   git -C /c/TMP/My_GIT/EscapeRoom merge --ff-only sklep-ci
   ```

   ```bash
   git -C /c/TMP/My_GIT/EscapeRoom push origin main
   ```

4. **GPS_RTK**: tak samo (`sklep-ci` zawiera też niewypchnięty wcześniej commit „Niwelacja…”).
   Push na main uruchomi build kontrolny – powinien przejść jak dotąd.
5. **T_rex_3**: `push -u origin main` (pkt 3). Push na main nie uruchamia żadnego workflow.

## 5. Pierwsze tagi

| Repo | Tag | Uwagi |
|---|---|---|
| EscapeRoom | `v1.0.1` (ostatni: `v1.0.0`) | albo ręcznie: Actions → Release → Run workflow → wersja |
| GPS_RTK | `v1.0.17` (ostatni: `v1.0.16`) | |
| T_rex_3 | `zakupy-v1.0.1` | wersja = tag bez `zakupy-v` |
| T_rex_3 | `powrot-v1.0.1` | najlepiej dopiero po skonfigurowaniu Firebase w Powrocie |
| T_rex_3 | `korona-v1.0.0` | po sekrecie `FIREBASE_OPTIONS_KORONA_B64` i publikacji reguł z blokiem `korona` |

```bash
git -C /c/TMP/My_GIT/GPS_RTK tag v1.0.17
```

```bash
git -C /c/TMP/My_GIT/GPS_RTK push origin v1.0.17
```

Po każdym wydaniu sprawdź na stronie release: są dokładnie `<nazwa>.apk` i `app.json`,
a `signerSha256` w `app.json` = odcisk z początku tego pliku. Jeśli jest inny – brakuje
sekretów (log joba „Podpis release” pokazuje ostrzeżenie).

### versionCode

- `versionCode = github.run_number + version_code_offset`. Nazwy plików workflow
  (`release.yml`, `release-apk.yml`) zostały bez zmian, żeby licznik nie wrócił do 1.
- Zakupy i Powrót budują się z `--split-per-abi` (arm64) – Flutter dodaje wtedy 2000
  (`versionCode = 2000 + run_number + 10`). Dotychczasowe lokalne buildy miały 2001,
  więc pierwsze wydanie z CI (≥ 2011) jest wyższe. Nie przełączaj później tych aplikacji na
  APK uniwersalny (versionCode spadłby do ~11 i aktualizacja byłaby niemożliwa).
- `app.json` zawiera prawdziwy versionCode odczytany z APK.

### Monorepo T_rex_3 a `releases/latest`

W `grekot/T_rex_3` są wydania dwóch aplikacji. `releases/latest` wskazuje to, które powstało
ostatnio, więc link `releases/latest/download/zakupy.apk` przestanie działać po wydaniu
Powrotu (i odwrotnie). Sklep dla tego repo musi szukać na liście release'ów najnowszego
wydania z assetem `zakupy.apk` / tagiem `zakupy-v*`.

## 6. Jednorazowa reinstalacja (zmiana klucza podpisu)

Android nie zaktualizuje aplikacji podpisanej innym kluczem („Aplikacja nie została
zainstalowana – konflikt pakietu”). Na każdym telefonie **raz**:

| Aplikacja | Czym była podpisana | Co zrobić |
|---|---|---|
| GPS RTK | do `v1.0.9` losowy klucz debug runnera, od `v1.0.10` stały, commitowany klucz debug | **najpierw kopia zapasowa punktów** (eksport w aplikacji), odinstaluj, zainstaluj `gps_rtk.apk` z nowego wydania, przywróć kopię |
| Zakupy | lokalny klucz debug | odinstaluj, zainstaluj `zakupy.apk` (dane są w Firestore – zaloguj się ponownie) |
| Powrót | lokalny klucz debug | jak Zakupy |
| EscapeRoom | wspólny klucz, jeśli sekrety były ustawione przy `v1.0.0` | zwykle nic; jeśli aktualizacja się nie uda – odinstaluj i zainstaluj ponownie |

Sprawdzenie, czym podpisany jest APK (lokalnie, build-tools z Android SDK):

```bash
"$ANDROID_HOME/build-tools/36.0.0/apksigner.bat" verify --print-certs plik.apk
```

Od tej chwili kolejne wersje aktualizują się w miejscu – i przez wbudowane „Sprawdź
aktualizacje”, i przez sklep.

## Lokalne buildy release

W `GPS_RTK/app/android/`, `T_rex_3/lista-zakupow/phone/android/` i
`T_rex_3/powrot/phone/android/` leży lokalny `key.properties` (kopia z EscapeRoom, wskazuje
wspólny keystore; gitignorowany). Dzięki temu `flutter build apk --release` na tej maszynie
podpisuje wspólnym kluczem. Na Windows przy błędzie Gradle „Unable to establish loopback
connection” ustaw `TEMP`/`TMP` na `C:\TMP\jtmp` (opis w `EscapeRoom/README.md`).
