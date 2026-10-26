// Publikuje firebase/firestore.rules w projekcie Firebase (zakupy-8ec54) kontem usługi z CI.
// Uruchamiany w ci.yml po testach reguł na emulatorze, tylko przy pushu na main.
//
// Zmienne:
//   FIREBASE_SERVICE_ACCOUNT  JSON konta usługi (sekret repozytorium); brak = krok pomijany
//   RULES_FILE                ścieżka do reguł (domyślnie ../../firebase/firestore.rules)
//   ALLOW_REMOVED=true        zgoda na usunięcie bloków `match /kolekcja`, które są w opublikowanych
//                             regułach, a nie ma ich w pliku (np. dopisanych ręcznie w konsoli)
//   DRY_RUN=true              tylko porównanie, bez publikacji
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const DEFAULT_RULES = fileURLToPath(new URL("../../firebase/firestore.rules", import.meta.url));

export function normalize(source) {
  return String(source).replace(/\r\n/g, "\n").trim();
}

// Nazwy kolekcji z bloków `match /nazwa/{...}` (na każdym poziomie), bez komentarzy
export function collections(source) {
  const code = normalize(source)
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/\/\/.*$/gm, "");
  const out = new Set();
  for (const m of code.matchAll(/match\s+\/([A-Za-z0-9_-]+)\//g)) {
    if (m[1] !== "databases") out.add(m[1]);
  }
  return out;
}

// Co się zmieni: { same, added: [...], removed: [...] }
export function compare(published, next) {
  const a = collections(published);
  const b = collections(next);
  return {
    same: normalize(published) === normalize(next),
    added: [...b].filter((x) => !a.has(x)).sort(),
    removed: [...a].filter((x) => !b.has(x)).sort(),
  };
}

async function main() {
  const env = process.env;
  if (!env.FIREBASE_SERVICE_ACCOUNT) {
    console.log("::notice::Brak sekretu FIREBASE_SERVICE_ACCOUNT - reguły nie zostały opublikowane.");
    return;
  }
  const source = readFileSync(env.RULES_FILE || DEFAULT_RULES, "utf8");

  const { initializeApp, cert } = await import("firebase-admin/app");
  const { getSecurityRules } = await import("firebase-admin/security-rules");
  const sa = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
  initializeApp({ credential: cert(sa), projectId: sa.project_id });
  const rules = getSecurityRules();

  let published = "";
  try {
    const current = await rules.getFirestoreRuleset();
    published = current.source.map((f) => f.content).join("\n");
  } catch (e) {
    // Brak opublikowanych reguł (nowy projekt) - publikujemy od zera
    if (e?.code !== "security-rules/not-found") throw e;
  }

  const diff = compare(published, source);
  if (diff.same) {
    console.log("Reguły w projekcie " + sa.project_id + " są już aktualne - nic do zrobienia.");
    return;
  }
  if (diff.added.length) console.log("Nowe kolekcje w regułach: " + diff.added.join(", "));
  if (diff.removed.length) {
    const msg = "Z reguł znikają kolekcje: " + diff.removed.join(", ");
    if (env.ALLOW_REMOVED !== "true") {
      console.log("::error::" + msg + ". Jeśli to zamierzone, uruchom ręcznie z ALLOW_REMOVED=true.");
      process.exitCode = 1;
      return;
    }
    console.log("::warning::" + msg + " (ALLOW_REMOVED=true).");
  }
  if (env.DRY_RUN === "true") {
    console.log("DRY_RUN: reguły różnią się od opublikowanych - nie publikuję.");
    return;
  }
  const released = await rules.releaseFirestoreRulesetFromSource(source);
  console.log("Opublikowano reguły Firestore w " + sa.project_id + ": " + released.name);
}

if (process.argv[1]?.endsWith("deploy-rules.mjs")) {
  main().catch((e) => {
    console.log("::error::Publikacja reguł nie powiodła się: " + (e?.message ?? e));
    process.exitCode = 1;
  });
}
