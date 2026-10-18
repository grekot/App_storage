// Krok CI po opublikowaniu wydania (etap 2 i 3 sklepu rodzinnego):
//  1. zapisuje najnowsze wydanie w polu `latest` każdej aplikacji o tym pakiecie
//     (groups/*/apps/* z packageName == pakiet z app.json) - sklep nie musi pytać GitHub API,
//  2. wysyła powiadomienie FCM na temat app_<pakiet> (subskrybują go telefony z tą aplikacją w katalogu).
//
// Wejście (zmienne środowiskowe):
//   FIREBASE_SERVICE_ACCOUNT  JSON konta usługi (sekret repozytorium); brak = krok pomijany
//   APP_JSON                  ścieżka do app.json (format grekot-app-release/1)
//   APK_URL                   link do APK w wydaniu
//   RELEASE_URL               strona wydania
//   RELEASE_NOTES_FILE        (opcjonalnie) plik z notatkami wydania
//   ICON_URL                  (opcjonalnie) link do icon.png w wydaniu
//   PRERELEASE                "true" = wersja testowa: bez zapisu `latest`, bez powiadomienia
//   APP_NAME                  (opcjonalnie) nazwa do powiadomienia, gdy pakietu nie ma w żadnej grupie
//   GITHUB_REPOSITORY         repozytorium wydania (ustawia GitHub Actions) - do automatycznego dodania
//
// Automatyczne dodawanie: grupy z polem autoAdd == true, w których tej aplikacji jeszcze nie ma,
// dostają ją od razu z nazwą z APK (app.json → appName). Sam sklep nie trafia do katalogu.
//   DRY_RUN                   "true" = tylko wypisz, co by zrobił
import { readFileSync, existsSync } from "node:fs";

export function topicFor(packageName) {
  return "app_" + packageName.replaceAll(".", "_");
}

/** Pole `latest` dokumentu aplikacji - te same klucze co AppRelease.toJson() w sklepie. */
export function buildLatest(appJson, { apkUrl, releaseUrl, notes = "", iconUrl = null }) {
  if (appJson.schema !== "grekot-app-release/1") throw new Error("Nieznany format app.json: " + appJson.schema);
  for (const k of ["packageName", "versionName", "versionCode", "tag"]) {
    if (appJson[k] === undefined || appJson[k] === "") throw new Error("Brak pola " + k + " w app.json");
  }
  return {
    tag: appJson.tag,
    versionName: appJson.versionName,
    versionCode: appJson.versionCode,
    packageName: appJson.packageName,
    apkUrl,
    sha256: appJson.sha256 ?? null,
    signerSha256: appJson.signerSha256 ?? null,
    size: appJson.size ?? 0,
    minSdk: appJson.minSdk ?? null,
    notes: notes.slice(0, 4000),
    htmlUrl: releaseUrl ?? "",
    publishedAt: appJson.publishedAt ?? new Date().toISOString(),
    prerelease: false,
    iconUrl,
    appJsonUrl: null,
  };
}

export const SELF_PACKAGE = "pl.grekot.sklep";

/** Nowy wpis katalogu dla aplikacji wydanej pierwszy raz (pola jak StoreApp.toEditableJson w sklepie). */
export function buildCatalogEntry(appJson, repo, fallbackName = "") {
  const tag = appJson.tag, ver = appJson.versionName;
  const prefix = tag.endsWith(ver) && tag.length > ver.length ? tag.slice(0, tag.length - ver.length) : "v";
  return {
    name: (appJson.appName || fallbackName || appJson.packageName).slice(0, 60),
    description: "",
    packageName: appJson.packageName,
    repo,
    tagPrefix: prefix,
    assetName: String(appJson.assetName ?? "").replace(/\.apk$/i, ""),
    iconUrl: "",
    order: 100,
    prerelease: false,
    hidden: false,
  };
}

/** Wiadomość FCM HTTP v1 (firebase-admin messaging().send). */
export function buildMessage(appName, latest) {
  return {
    topic: topicFor(latest.packageName),
    notification: {
      title: `${appName} ${latest.versionName}`,
      body: "Nowa wersja w Sklepie rodzinnym - stuknij, aby zaktualizować.",
    },
    data: { packageName: latest.packageName, versionName: latest.versionName, tag: latest.tag },
    android: { priority: "normal", notification: { channelId: "nowe_wersje", tag: latest.packageName } },
  };
}

async function main() {
  const env = process.env;
  if (!env.FIREBASE_SERVICE_ACCOUNT) {
    console.log("::notice::Brak sekretu FIREBASE_SERVICE_ACCOUNT - pomijam zapis do Firestore i powiadomienie.");
    return;
  }
  if (env.PRERELEASE === "true") {
    console.log("Wersja testowa (pre-release) - sklep pobierze ją z GitHuba, bez powiadomienia.");
    return;
  }
  const appJson = JSON.parse(readFileSync(env.APP_JSON, "utf8"));
  const notes =
    env.RELEASE_NOTES_FILE && existsSync(env.RELEASE_NOTES_FILE) ? readFileSync(env.RELEASE_NOTES_FILE, "utf8") : "";
  const latest = buildLatest(appJson, {
    apkUrl: env.APK_URL,
    releaseUrl: env.RELEASE_URL,
    notes,
    iconUrl: env.ICON_URL || null,
  });

  const { initializeApp, cert } = await import("firebase-admin/app");
  const { getFirestore, Timestamp } = await import("firebase-admin/firestore");
  const { getMessaging } = await import("firebase-admin/messaging");
  const sa = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT);
  initializeApp({ credential: cert(sa), projectId: sa.project_id });
  const db = getFirestore();

  // Kilka grup w praktyce - przechodzimy wszystkie (bez indeksu collectionGroup).
  const groups = await db.collection("groups").get();
  let appName = env.APP_NAME || latest.packageName;
  let updated = 0;
  for (const g of groups.docs) {
    const apps = await g.ref.collection("apps").where("packageName", "==", latest.packageName).get();
    for (const a of apps.docs) {
      appName = a.get("name") || appName;
      const prev = a.get("latest");
      if (prev && typeof prev.versionCode === "number" && prev.versionCode > latest.versionCode) {
        console.log(`Pomijam ${g.id}/${a.id}: ma nowszą wersję (${prev.versionCode}).`);
        continue;
      }
      const data = { ...latest, publishedAt: Timestamp.fromDate(new Date(latest.publishedAt)) };
      if (env.DRY_RUN === "true") console.log("DRY_RUN zapis", g.id, a.id, data);
      else await a.ref.update({ latest: data });
      updated++;
    }
  }
  console.log(`Zapisano wersję ${latest.versionName} (${latest.versionCode}) w ${updated} wpisach katalogu.`);

  // Pierwsze wydanie nowej aplikacji: dopisz ją do grup z włączonym autoAdd.
  if (latest.packageName !== SELF_PACKAGE && env.GITHUB_REPOSITORY) {
    for (const g of groups.docs.filter((d) => d.get("autoAdd") === true)) {
      const has = await g.ref.collection("apps").where("packageName", "==", latest.packageName).limit(1).get();
      if (!has.empty) continue;
      const entry = buildCatalogEntry(appJson, env.GITHUB_REPOSITORY, env.APP_NAME);
      appName = entry.name;
      const data = {
        ...entry,
        latest: { ...latest, publishedAt: Timestamp.fromDate(new Date(latest.publishedAt)) },
        createdAt: Timestamp.now(),
        updatedAt: Timestamp.now(),
      };
      if (env.DRY_RUN === "true") console.log("DRY_RUN nowa aplikacja", g.id, data);
      else await g.ref.collection("apps").add(data);
      console.log(`Dodano „${entry.name}” do grupy „${g.get("name")}” (automatycznie).`);
    }
  }

  const message = buildMessage(appName, latest);
  if (env.DRY_RUN === "true") {
    console.log("DRY_RUN powiadomienie", JSON.stringify(message));
  } else {
    const id = await getMessaging().send(message);
    console.log("Wysłano powiadomienie na temat", message.topic, id);
  }
}

if (import.meta.url === `file://${process.argv[1]}` || process.argv[1]?.endsWith("publish.mjs")) {
  main().catch((e) => {
    // Wydanie już jest na GitHubie - błąd tego kroku nie może go "cofnąć"; sklep i tak znajdzie wersję przez API.
    console.log("::warning::Zapis do Firestore / powiadomienie nie powiodło się: " + (e?.message ?? e));
  });
}
