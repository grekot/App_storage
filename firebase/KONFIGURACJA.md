# Konfiguracja Firebase dla sklepu (jednorazowo, ok. 15 minut)

Sklep korzysta z **tego samego projektu Firebase co Zakupy i Powrót** (`zakupy-8ec54`).
Dzięki temu rodzina loguje się tym samym kontem, a właściciel dodaje osoby po e-mailu
z istniejącej książki adresowej. Wszystko robisz w przeglądarce w
<https://console.firebase.google.com/project/zakupy-8ec54>. Plan Spark (darmowy) wystarcza.

## 1. Aplikacja Android sklepu

1. Koło zębate obok „Przegląd projektu” → **Ustawienia projektu**.
2. W sekcji **Twoje aplikacje** → **Dodaj aplikację** → ikona **Android**.
3. Nazwa pakietu: **`pl.grekot.sklep`**. Pseudonim: `Sklep`. SHA-1 nie jest potrzebny.
4. **Pobierz `google-services.json`** i zapisz go jako
   `C:\TMP\My_GIT\App_storage\app\android\app\google-services.json`
   (plik zawiera teraz wszystkie aplikacje projektu - to normalne).
5. Pozostałe kroki kreatora pomiń.
6. W folderze `App_storage`:

   ```bash
   node tools/configure.mjs
   ```

   Skrypt zapisze `app/lib/firebase_options.dart` (poza gitem).

## 2. Reguły Firestore

Firestore ma **jeden zestaw reguł** dla całej bazy. Plik [`firestore.rules`](firestore.rules)
zawiera reguły Zakupów i Powrotu bez zmian oraz nowe bloki sklepu.

1. **Firestore Database → Reguły**.
2. Usuń całą zawartość, wklej zawartość `firebase/firestore.rules` → **Opublikuj**.

Od tej chwili to jest jedyne źródło reguł projektu. Plik
`T_rex_3/lista-zakupow/firebase/firestore.rules` warto zastąpić odnośnikiem do tego pliku,
żeby przy następnej zmianie Zakupów nie opublikować starej wersji bez sklepu.

Testy reguł na emulatorze (Node.js + Java 17, w Windows z krótką ścieżką TEMP):

```bash
cd firebase/test && npm ci && TEMP='C:\TMP\jtmp' TMP='C:\TMP\jtmp' npm test
```

## 3. Powiadomienia (Cloud Messaging)

Nowe projekty mają włączone **Firebase Cloud Messaging API (V1)**. Sprawdź:
**Ustawienia projektu → Cloud Messaging** → „Firebase Cloud Messaging API (V1)”: *Włączone*.
Starego interfejsu „Legacy” nie trzeba.

## 4. Konto usługi dla CI (zapis wersji + powiadomienia)

Krok wydania w GitHub Actions zapisuje nową wersję w Firestore i wysyła powiadomienie.
Potrzebuje do tego klucza konta usługi.

1. **Ustawienia projektu → Konta usługi → Firebase Admin SDK → Wygeneruj nowy klucz prywatny**.
2. Pobrany plik JSON **nie trafia do żadnego repozytorium**. Jego całą zawartość wklejasz jako sekret
   **`FIREBASE_SERVICE_ACCOUNT`** w każdym repozytorium, które publikuje aplikacje do sklepu
   (App_storage, EscapeRoom, GPS_RTK, T_rex_3), albo raz jako sekret organizacji/konta, jeśli używasz.
3. Po wklejeniu usuń plik z dysku.

Klucz daje pełny dostęp do projektu (omija reguły), więc trzymaj go tylko w sekretach GitHub.
Bez tego sekretu wydania nadal działają: sklep znajdzie nową wersję przez GitHub API,
tylko bez powiadomienia push.

## 5. Sekret konfiguracji aplikacji dla CI

`firebase_options.dart` jest poza gitem, więc CI dostaje go z sekretu:

```bash
base64 -w0 app/lib/firebase_options.dart
```

Wynik wklej jako sekret **`FIREBASE_OPTIONS_SKLEP_B64`** w repozytorium App_storage.
