#!/usr/bin/env node
// Zarządzanie Sklepem rodzinnym z komputera.
// Loguje się Twoim kontem (tym samym co w Zakupach) i działa przez te same reguły Firestore
// co aplikacja na telefonie - nie potrzebuje klucza konta usługi.
//
// Użycie (w folderze App_storage):  sklep pomoc
import { mkdirSync, readFileSync, writeFileSync, existsSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createInterface } from "node:readline";
import { randomInt } from "node:crypto";
import { buildLatest } from "../ci-publish/publish.mjs";
import {
  findApps,
  fromDoc,
  normalizeRepo,
  parseArgs,
  pickRelease,
  prefixesIn,
  toFields,
  toValue,
  yes,
} from "./lib.mjs";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const SESSION = join(process.env.APPDATA || join(homedir(), ".config"), "sklep-rodzinny", "sesja.json");
const SELF_PACKAGE = "pl.grekot.sklep";

// ------------------------------------------------------------------ konfiguracja i logowanie

function firebaseConfig() {
  const p = join(ROOT, "app", "lib", "firebase_options.dart");
  if (!existsSync(p)) throw new Error("Brak app/lib/firebase_options.dart - uruchom: node tools/configure.mjs");
  const src = readFileSync(p, "utf8");
  const get = (k) => new RegExp(`${k}: '([^']*)'`).exec(src)?.[1];
  const apiKey = get("apiKey"), projectId = get("projectId");
  if (!apiKey || !projectId) throw new Error("firebase_options.dart to zaślepka - uruchom: node tools/configure.mjs");
  return { apiKey, projectId };
}

const CFG = (() => {
  try {
    return firebaseConfig();
  } catch (e) {
    return { error: e.message };
  }
})();
const DOCS = () => `https://firestore.googleapis.com/v1/projects/${CFG.projectId}/databases/(default)/documents`;

function ask(question, { hidden = false } = {}) {
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    if (hidden) {
      rl._writeToOutput = (s) => {
        if (s.includes(question)) rl.output.write(s);
        else if (s.includes("\n") || s.includes("\r")) rl.output.write("\n");
        else rl.output.write("*");
      };
    }
    rl.question(question, (a) => {
      rl.close();
      resolve(a.trim());
    });
  });
}

async function login() {
  const email = await ask("E-mail (konto z Zakupów / Sklepu): ");
  const password = await ask("Hasło: ", { hidden: true });
  const r = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${CFG.apiKey}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email, password, returnSecureToken: true }),
  });
  const j = await r.json();
  if (j.error) throw new Error("Logowanie nieudane: " + j.error.message);
  mkdirSync(dirname(SESSION), { recursive: true });
  writeFileSync(SESSION, JSON.stringify({ email: j.email, uid: j.localId, refreshToken: j.refreshToken }, null, 2));
  console.log(`Zalogowano jako ${j.email}. Sesja zapisana w ${SESSION} (hasło nie jest zapisywane).`);
}

let auth = null;
async function session() {
  if (auth) return auth;
  if (!existsSync(SESSION)) throw new Error("Nie jesteś zalogowany. Uruchom: sklep login");
  const s = JSON.parse(readFileSync(SESSION, "utf8"));
  const r = await fetch(`https://securetoken.googleapis.com/v1/token?key=${CFG.apiKey}`, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: s.refreshToken }),
  });
  const j = await r.json();
  if (j.error) throw new Error("Sesja wygasła (" + j.error.message + "). Uruchom: sklep login");
  if (j.refresh_token && j.refresh_token !== s.refreshToken) {
    writeFileSync(SESSION, JSON.stringify({ ...s, refreshToken: j.refresh_token }, null, 2));
  }
  auth = { uid: j.user_id, email: s.email, idToken: j.id_token };
  return auth;
}

// ------------------------------------------------------------------ Firestore REST

async function fs(method, path, body) {
  const { idToken } = await session();
  const url = path.startsWith("http") ? path : `${DOCS()}${path}`;
  const r = await fetch(url, {
    method,
    headers: { authorization: `Bearer ${idToken}`, "content-type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  const j = text ? JSON.parse(text) : {};
  if (!r.ok) {
    const msg = j.error?.status === "PERMISSION_DENIED" ? "brak uprawnień (reguły Firestore)" : j.error?.message ?? r.status;
    throw new Error(`Firestore ${method} ${path}: ${msg}`);
  }
  return j;
}

const getDoc = async (path) => fromDoc(await fs("GET", `/${path}`));
const listDocs = async (path) => ((await fs("GET", `/${path}?pageSize=300`)).documents ?? []).map(fromDoc);
const createDoc = async (coll, data, id) =>
  fromDoc(await fs("POST", `/${coll}${id ? `?documentId=${encodeURIComponent(id)}` : ""}`, { fields: toFields(data) }));
const deleteDoc = (path) => fs("DELETE", `/${path}`);

/** Zapis wybranych pól (+ opcjonalne transformacje: dopisanie/usunięcie z tablicy, czas serwera). */
async function update(path, data = {}, { remove = [], arrayUnion = {}, arrayRemove = {}, mustExist = true } = {}) {
  const fieldPaths = [...Object.keys(data).map(quotePath), ...remove.map(quotePath)];
  const transforms = [
    ...Object.entries(arrayUnion).map(([f, vals]) => ({ fieldPath: f, appendMissingElements: { values: vals.map(toValue) } })),
    ...Object.entries(arrayRemove).map(([f, vals]) => ({ fieldPath: f, removeAllFromArray: { values: vals.map(toValue) } })),
    { fieldPath: "updatedAt", setToServerValue: "REQUEST_TIME" },
  ];
  const name = `projects/${CFG.projectId}/databases/(default)/documents/${path}`;
  await fs("POST", `${DOCS()}:commit`, {
    writes: [
      {
        update: { name, fields: nested(data) },
        updateMask: { fieldPaths },
        updateTransforms: transforms,
        ...(mustExist ? { currentDocument: { exists: true } } : {}),
      },
    ],
  });
}

// "memberEmails.abc" w masce, a w polach zagnieżdżona mapa
const quotePath = (p) => p.split(".").map((s) => (/^[A-Za-z_][A-Za-z0-9_]*$/.test(s) ? s : `\`${s}\``)).join(".");
function nested(data) {
  const out = {};
  for (const [k, v] of Object.entries(data)) {
    const parts = k.split(".");
    let cur = out;
    parts.slice(0, -1).forEach((p) => (cur = cur[p] ??= {}));
    cur[parts.at(-1)] = v;
  }
  return toFields(out);
}

async function myGroups() {
  const { uid } = await session();
  const res = await fs("POST", `${DOCS()}:runQuery`, {
    structuredQuery: {
      from: [{ collectionId: "groups" }],
      where: { fieldFilter: { field: { fieldPath: "members" }, op: "ARRAY_CONTAINS", value: { stringValue: uid } } },
    },
  });
  return res.filter((x) => x.document).map((x) => fromDoc(x.document));
}

/** Grupa z --grupa albo jedyna prowadzona przeze mnie. */
async function ownedGroup(args) {
  const { uid } = await session();
  const owned = (await myGroups()).filter((g) => g.ownerId === uid);
  if (!owned.length) throw new Error("Nie prowadzisz żadnej grupy. Utwórz ją: sklep nowa-grupa Rodzina");
  if (args.grupa) {
    const q = args.grupa.toLowerCase();
    const g = owned.find((x) => x.name.toLowerCase() === q) ?? owned.find((x) => x.name.toLowerCase().includes(q));
    if (!g) throw new Error(`Nie ma grupy „${args.grupa}”. Twoje grupy: ${owned.map((x) => x.name).join(", ")}`);
    return g;
  }
  if (owned.length > 1) throw new Error(`Masz kilka grup - dodaj --grupa NAZWA (${owned.map((x) => x.name).join(", ")})`);
  return owned[0];
}

async function appIn(group, query) {
  const apps = await listDocs(`groups/${group.id}/apps`);
  const hit = findApps(apps, query);
  if (!hit.length) throw new Error(`W grupie „${group.name}” nie ma aplikacji „${query}”.`);
  if (hit.length > 1) throw new Error(`„${query}” pasuje do kilku: ${hit.map((a) => a.name).join(", ")} - doprecyzuj.`);
  return hit[0];
}

// ------------------------------------------------------------------ GitHub

async function gh(path) {
  const r = await fetch(`https://api.github.com${path}`, {
    headers: { accept: "application/vnd.github+json", "user-agent": "sklep-cli" },
  });
  if (r.status === 404) throw new Error(`GitHub: nie ma ${path} (repozytorium prywatne albo literówka?)`);
  if (r.status === 403 || r.status === 429) throw new Error("GitHub chwilowo ogranicza zapytania (60/h z tego adresu). Spróbuj za kilkanaście minut.");
  if (!r.ok) throw new Error(`GitHub ${path}: HTTP ${r.status}`);
  return r.json();
}

/** Wszystko o aplikacji z najnowszego wydania: pakiet, nazwa, plik, prefiks, latest. */
async function detect(repo, { prefix, withPre = false } = {}) {
  const releases = await gh(`/repos/${repo}/releases?per_page=30`);
  const prefixes = prefixesIn(releases);
  if (!prefixes.length) throw new Error(`${repo}: brak wydań z plikiem APK. Najpierw wydaj aplikację (tag).`);
  if (!prefix) {
    if (prefixes.length > 1) {
      throw new Error(`${repo} zawiera kilka aplikacji - dodaj --prefiks (${prefixes.join(", ")})`);
    }
    prefix = prefixes[0];
  }
  const rel = pickRelease(releases, prefix, withPre);
  if (!rel) throw new Error(`${repo}: brak wydania z prefiksem „${prefix}” (są: ${prefixes.join(", ")})`);
  const jsonAsset = rel.assets.find((a) => a.name === "app.json");
  if (!jsonAsset) {
    throw new Error(`${repo} ${rel.tag_name}: wydanie bez app.json (sprzed wspólnego workflow). Wydaj nową wersję.`);
  }
  const appJson = await (await fetch(jsonAsset.browser_download_url)).json();
  const apk = rel.assets.find((a) => a.name === appJson.assetName) ?? rel.assets.find((a) => /\.apk$/i.test(a.name));
  const icon = rel.assets.find((a) => a.name === "icon.png");
  const latest = buildLatest(appJson, {
    apkUrl: apk.browser_download_url,
    releaseUrl: rel.html_url,
    notes: rel.body ?? "",
    iconUrl: icon?.browser_download_url ?? null,
  });
  latest.publishedAt = new Date(latest.publishedAt);
  latest.prerelease = !!rel.prerelease;
  return {
    prefix,
    appJson,
    latest,
    name: appJson.appName || repo.split("/")[1],
    assetName: (appJson.assetName ?? apk.name).replace(/\.apk$/i, ""),
  };
}

// ------------------------------------------------------------------ polecenia

const commands = {
  async login() {
    if (CFG.error) throw new Error(CFG.error);
    await login();
  },

  async wyloguj() {
    if (existsSync(SESSION)) rmSync(SESSION);
    console.log("Wylogowano (sesja usunięta).");
  },

  async status() {
    const { uid, email } = await session();
    const groups = await myGroups();
    console.log(`Konto: ${email}`);
    if (!groups.length) return console.log("Nie należysz do żadnej grupy. Utwórz: sklep nowa-grupa Rodzina");
    for (const g of groups) {
      const own = g.ownerId === uid;
      console.log(`\n■ ${g.name}  (${own ? "prowadzisz" : "prowadzi " + (g.memberEmails?.[g.ownerId] ?? "?")}, ` +
        `osób: ${g.members.length}${g.autoAdd ? ", nowe aplikacje dodają się same" : ""})`);
      const apps = (await listDocs(`groups/${g.id}/apps`)).sort((a, b) => (a.order ?? 100) - (b.order ?? 100) || a.name.localeCompare(b.name));
      if (!apps.length) console.log("   (brak aplikacji - dodaj: sklep dodaj grekot/NazwaRepo)");
      for (const a of apps) {
        const v = a.latest ? `${a.latest.versionName} (${a.latest.versionCode})` : "wersja z GitHuba";
        console.log(`   • ${a.name.padEnd(22)} ${v.padEnd(16)} ${a.repo} ${a.tagPrefix}*${a.hidden ? "  [ukryta]" : ""}${a.prerelease ? "  [beta]" : ""}`);
      }
    }
  },

  async "nowa-grupa"(args) {
    const name = args._.join(" ").trim();
    if (!name) throw new Error("Podaj nazwę: sklep nowa-grupa Rodzina");
    const { uid, email } = await session();
    const g = await createDoc("groups", {
      name, ownerId: uid, members: [uid], memberEmails: { [uid]: email.toLowerCase() },
      trustedSigners: [], autoAdd: true, createdAt: new Date(),
    });
    console.log(`Utworzono grupę „${name}”. Nowe aplikacje będą się do niej dodawać same przy wydaniu.`);
    return g;
  },

  async dodaj(args) {
    if (!args._[0]) throw new Error("Podaj repozytorium: sklep dodaj grekot/EscapeRoom [--prefiks zakupy-v]");
    const repo = normalizeRepo(args._[0]);
    const group = await ownedGroup(args);
    const d = await detect(repo, { prefix: args.prefiks, withPre: yes(args.beta) });
    if (d.appJson.packageName === SELF_PACKAGE) throw new Error("To jest sam sklep - nie dodaje się go do katalogu.");
    const apps = await listDocs(`groups/${group.id}/apps`);
    const existing = apps.find((a) => a.packageName === d.appJson.packageName);
    const data = {
      name: args.nazwa ?? existing?.name ?? d.name,
      description: args.opis ?? existing?.description ?? "",
      packageName: d.appJson.packageName,
      repo,
      tagPrefix: d.prefix,
      assetName: d.assetName,
      iconUrl: args.ikona ?? existing?.iconUrl ?? "",
      order: args.kolejnosc !== undefined ? Number(args.kolejnosc) : existing?.order ?? 100,
      prerelease: yes(args.beta) ?? existing?.prerelease ?? false,
      hidden: yes(args.ukryta) ?? existing?.hidden ?? false,
      latest: d.latest,
    };
    if (existing) {
      await update(existing.path, data);
      console.log(`Zaktualizowano „${data.name}” w grupie „${group.name}”: ${d.latest.versionName} (${d.latest.versionCode}).`);
    } else {
      await createDoc(`groups/${group.id}/apps`, { ...data, createdAt: new Date() });
      console.log(`Dodano „${data.name}” (${data.packageName}) do grupy „${group.name}”: wersja ${d.latest.versionName}.`);
    }
  },

  async usun(args) {
    const group = await ownedGroup(args);
    const app = await appIn(group, args._.join(" "));
    await deleteDoc(app.path);
    console.log(`Usunięto „${app.name}” z grupy „${group.name}” (zainstalowane kopie zostają na telefonach).`);
  },

  async ustaw(args) {
    const group = await ownedGroup(args);
    const app = await appIn(group, args._.join(" "));
    const data = {};
    if (args.nazwa !== undefined) data.name = args.nazwa;
    if (args.opis !== undefined) data.description = args.opis;
    if (args.kolejnosc !== undefined) data.order = Number(args.kolejnosc);
    if (args.ikona !== undefined) data.iconUrl = args.ikona;
    if (args.beta !== undefined) data.prerelease = yes(args.beta);
    if (args.ukryta !== undefined) data.hidden = yes(args.ukryta);
    if (!Object.keys(data).length) throw new Error("Co zmienić? --nazwa, --opis, --kolejnosc, --ikona, --beta tak/nie, --ukryta tak/nie");
    await update(app.path, data);
    console.log(`Zmieniono „${app.name}”: ${Object.keys(data).join(", ")}.`);
  },

  async osoby(args) {
    const group = await ownedGroup(args);
    console.log(`Grupa „${group.name}”:`);
    for (const uid of group.members) {
      console.log(`   • ${group.memberEmails?.[uid] ?? uid}${uid === group.ownerId ? "  (właściciel)" : ""}`);
    }
  },

  async "dodaj-osobe"(args) {
    const email = (args._[0] ?? "").trim().toLowerCase();
    if (!email.includes("@")) throw new Error("Podaj e-mail: sklep dodaj-osobe ania@example.com");
    const group = await ownedGroup(args);
    let entry;
    try {
      entry = await getDoc(`emails/${encodeURIComponent(email)}`);
    } catch {
      throw new Error(`${email} nie ma jeszcze konta. Niech zainstaluje sklep i je założy - albo wyślij kod: sklep zaproszenie`);
    }
    if (group.members.includes(entry.uid)) return console.log(`${email} już jest w grupie „${group.name}”.`);
    await update(`groups/${group.id}`, { [`memberEmails.${entry.uid}`]: email }, { arrayUnion: { members: [entry.uid] } });
    console.log(`Dodano ${email} do grupy „${group.name}”.`);
  },

  async "usun-osobe"(args) {
    const q = (args._[0] ?? "").trim().toLowerCase();
    const group = await ownedGroup(args);
    const uid = Object.entries(group.memberEmails ?? {}).find(([, e]) => e === q)?.[0];
    if (!uid) throw new Error(`W grupie nie ma ${q}.`);
    if (uid === group.ownerId) throw new Error("Nie można usunąć właściciela.");
    await update(`groups/${group.id}`, {}, { remove: [`memberEmails.${uid}`], arrayRemove: { members: [uid] } });
    console.log(`Usunięto ${q} z grupy „${group.name}”.`);
  },

  async zaproszenie(args) {
    const group = await ownedGroup(args);
    const { uid } = await session();
    const days = Number(args.dni ?? 7);
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    const code = Array.from({ length: 8 }, () => alphabet[randomInt(alphabet.length)]).join("");
    const expiresAt = new Date(Date.now() + days * 86400000);
    await createDoc("invites", { groupId: group.id, groupName: group.name, createdBy: uid, expiresAt, createdAt: new Date() }, code);
    console.log(`Kod: ${code}  (ważny do ${expiresAt.toLocaleDateString("pl-PL")})\n`);
    console.log("Wiadomość do wysłania:\n");
    console.log(`Zaproszenie do sklepu rodzinnego („${group.name}”).
1. Zainstaluj sklep: https://grekot.github.io/App_storage/
2. Zaloguj się (konto z Zakupów) albo załóż konto.
3. Menu → „Dołącz kodem zaproszenia” → ${code}`);
  },

  async wersje(args) {
    const group = await ownedGroup(args);
    const apps = await listDocs(`groups/${group.id}/apps`);
    const reports = await listDocs(`groups/${group.id}/installs`);
    if (!reports.length) return console.log("Nikt jeszcze nie zgłosił instalacji (sklep robi to sam po instalacji).");
    for (const a of apps) {
      const rs = reports.filter((r) => r.packageName === a.packageName);
      if (!rs.length) continue;
      console.log(`\n${a.name} (najnowsza ${a.latest?.versionName ?? "?"})`);
      for (const r of rs) {
        const old = a.latest?.versionCode && r.versionCode < a.latest.versionCode;
        console.log(`   ${old ? "⚠" : "✓"} ${r.email.padEnd(32)} ${r.versionName}`);
      }
    }
  },

  async auto(args) {
    const group = await ownedGroup(args);
    const on = yes(args._[0] ?? "tak");
    await update(`groups/${group.id}`, { autoAdd: on });
    console.log(on
      ? `Nowe aplikacje będą się same dodawać do „${group.name}” przy pierwszym wydaniu.`
      : `Automatyczne dodawanie do „${group.name}” wyłączone.`);
  },

  async zaufaj(args) {
    const group = await ownedGroup(args);
    const sha = (args._[0] ?? "").replace(/[^0-9a-fA-F]/g, "").toLowerCase();
    if (sha.length !== 64) throw new Error("Podaj odcisk SHA-256 (64 znaki szesnastkowe).");
    await update(`groups/${group.id}`, {}, { arrayUnion: { trustedSigners: [sha] } });
    console.log(`Dodano zaufany klucz do „${group.name}”.`);
  },

  async pomoc() {
    console.log(`Sklep rodzinny - zarządzanie z komputera

  sklep login                         zaloguj się (raz; konto z Zakupów)
  sklep status                        grupy, aplikacje i ich wersje
  sklep dodaj <repo> [opcje]          dodaj albo odśwież aplikację - reszta wykrywa się sama
        --prefiks zakupy-v              (tylko gdy repozytorium ma kilka aplikacji)
        --nazwa "…" --opis "…" --kolejnosc 10 --beta tak --ukryta tak
  sklep ustaw <aplikacja> [opcje]     zmień nazwę, opis, kolejność, ikonę, betę, ukrycie
  sklep usun <aplikacja>              usuń z katalogu grupy
  sklep osoby                         kto jest w grupie
  sklep dodaj-osobe <e-mail>          dodaj osobę, która ma już konto
  sklep usun-osobe <e-mail>
  sklep zaproszenie [--dni 7]         kod zaproszenia + gotowa wiadomość
  sklep wersje                        kto ma którą wersję
  sklep nowa-grupa <nazwa>            nowa grupa (np. Testerzy)
  sklep auto tak|nie                  nowe aplikacje dodają się same przy wydaniu
  sklep zaufaj <sha256>               dodatkowy zaufany klucz podpisu
  sklep wyloguj

Kilka grup? Dodaj --grupa NAZWA. <aplikacja> = fragment nazwy albo pakiet.`);
  },
};
commands.help = commands.pomoc;
commands["usuń"] = commands.usun;

const args = parseArgs(process.argv.slice(2));
const cmd = args._.shift() ?? "status";
const fn = commands[cmd];
if (!fn) {
  console.error(`Nieznane polecenie „${cmd}”.\n`);
  await commands.pomoc();
  process.exit(2);
}
try {
  if (CFG.error && cmd !== "pomoc" && cmd !== "help") throw new Error(CFG.error);
  await fn(args);
} catch (e) {
  console.error("Błąd: " + e.message);
  process.exit(1);
}
