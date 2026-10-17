// Przepisuje konfigurację Firebase z google-services.json do aplikacji sklepu.
// Użycie (w folderze App_storage):  node tools/configure.mjs
// Wzorowane na T_rex_3/lista-zakupow/tools/configure.mjs.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SOURCE = join(ROOT, "app", "android", "app", "google-services.json");
const TARGET = join(ROOT, "app", "lib", "firebase_options.dart");
const PACKAGE = "pl.grekot.sklep";

if (!existsSync(SOURCE)) {
  console.error("Brak pliku " + SOURCE);
  console.error("Pobierz go z konsoli Firebase (Ustawienia projektu → Twoje aplikacje → Android " + PACKAGE + ").");
  process.exit(1);
}

const gs = JSON.parse(readFileSync(SOURCE, "utf8"));
const client = gs.client.find((c) => c.client_info.android_client_info.package_name === PACKAGE);
if (!client) {
  const have = gs.client.map((c) => c.client_info.android_client_info.package_name).join(", ");
  console.error("W google-services.json nie ma aplikacji " + PACKAGE + " (są: " + have + ").");
  console.error("Dodaj aplikację Android " + PACKAGE + " w tym samym projekcie i pobierz plik ponownie.");
  process.exit(1);
}

const dart = `// WYGENEROWANE przez tools/configure.mjs z google-services.json - nie edytuj ręcznie.
import 'package:firebase_core/firebase_core.dart';

const bool firebaseConfigured = true;

const FirebaseOptions firebaseOptions = FirebaseOptions(
  apiKey: '${client.api_key[0].current_key}',
  appId: '${client.client_info.mobilesdk_app_id}',
  messagingSenderId: '${gs.project_info.project_number}',
  projectId: '${gs.project_info.project_id}',
  storageBucket: '${gs.project_info.storage_bucket || ""}',
);
`;
writeFileSync(TARGET, dart);
console.log("Zapisano " + TARGET + " (projekt " + gs.project_info.project_id + ")");
console.log("Dla CI (sekret FIREBASE_OPTIONS_SKLEP_B64):");
console.log("  base64 -w0 app/lib/firebase_options.dart");
