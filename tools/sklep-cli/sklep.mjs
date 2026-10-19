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
    console.log(`Konto: ${email}${isAdminUid(uid) ? "  (administrator)" : ""}`);
    if (!groups.length) console.log("Nie należysz do żadnej grupy.");
    for (const g of groups) {
      const own = g.ownerId === uid;
      console.log(`\n■ ${g.name}  (${own ? "prowadzisz" : "prowadzi " + (g.memberEmails?.[g.ownerId] ?? "?")}, ` +
        `osób: ${g.members.length}${g.autoAdd ? ", nowe aplikacje dodają się same" : ""})`);
      if (own) console.log(`   osoby: ${g.members.map((u) => g.memberEmails?.[u] ?? u).join(", ")}`);
      const apps = sortApps(await listDocs(`groups/${g.id}/apps`));
      if (!apps.length) console.log("   (brak aplikacji - przypisz: sklep przypisz <aplikacja> --grupa " + g.name + ")");
      for (const a of apps) console.log(`   • ${appLine(a)}`);
    }
    if (isAdminUid(uid)) {
      const lib = await listDocs("library").catch(() => []);
      const assigned = new Set();
      for (const g of groups) (await listDocs(`groups/${g.id}/apps`)).forEach((a) => assigned.add(a.packageName));
      const free = lib.filter((a) => !assigned.has(a.packageName));
      console.log(`\nBiblioteka: ${lib.length} aplikacji` + (free.length ? `, nieprzypisane: ${free.map((a) => a.name).join(", ")}` : ""));
    }
  },

  // ---------------------------------------------------------------- biblioteka aplikacji

  async aplikacje() {
    const lib = sortApps(await listDocs("library"));
    if (!lib.length) return console.log("Biblioteka jest pusta. Dodaj: sklep dodaj grekot/NazwaRepo (albo jednorazowo: sklep migruj)");
    const owned = await ownedGroups();
    const groupsOf = await assignmentMap(owned);
    console.log("Biblioteka aplikacji (widzisz ją tylko Ty):\n");
    for (const a of lib) {
      const gs = groupsOf.get(a.packageName) ?? [];
      console.log(`• ${appLine(a)}\n    grupy: ${gs.length ? gs.map((g) => g.name).join(", ") : "— (nieprzypisana)"}`);
    }
  },

  async dodaj(args) {
    if (!args._[0]) throw new Error("Podaj repozytorium: sklep dodaj grekot/EscapeRoom [--prefiks zakupy-v] [--grupa Domowa,Rodzice]");
    const repo = normalizeRepo(args._[0]);
    await requireAdmin();
    const d = await detect(repo, { prefix: args.prefiks, withPre: yes(args.beta) });
    const pkg = d.appJson.packageName;
    if (pkg === SELF_PACKAGE) throw new Error("To jest sam sklep - nie dodaje się go do katalogu.");
    const existing = await getDoc(`library/${pkg}`).catch(() => null);
    const data = {
      name: args.nazwa ?? existing?.name ?? d.name,
      description: args.opis ?? existing?.description ?? "",
      packageName: pkg,
      repo,
      tagPrefix: d.prefix,
      assetName: d.assetName,
      iconUrl: args.ikona ?? existing?.iconUrl ?? "",
      order: args.kolejnosc !== undefined ? Number(args.kolejnosc) : existing?.order ?? 100,
      prerelease: yes(args.beta) ?? existing?.prerelease ?? false,
      hidden: yes(args.ukryta) ?? existing?.hidden ?? false,
      latest: d.latest,
    };
    await update(`library/${pkg}`, existing ? data : { ...data, createdAt: new Date() }, { mustExist: false });
    console.log(`${existing ? "Odświeżono" : "Dodano do biblioteki"} „${data.name}” (${pkg}): wersja ${d.latest.versionName}.`);
    await syncCopies(data);
    if (args.grupa) await commands.przypisz({ _: [pkg], grupa: args.grupa });
    else if (!existing) console.log(`Przypisz ją do grup: sklep przypisz "${data.name}" --grupa Domowa`);
  },

  async przypisz(args) {
    const app = await libApp(args._.join(" "));
    const groups = await groupsByNames(args.grupa, "przypisz <aplikacja> --grupa Domowa,Rodzice");
    for (const g of groups) {
      const copies = (await listDocs(`groups/${g.id}/apps`)).filter((a) => a.packageName === app.packageName);
      if (copies.length) {
        console.log(`„${app.name}” już jest w grupie „${g.name}”.`);
        continue;
      }
      await update(`groups/${g.id}/apps/${app.packageName}`, { ...copyFields(app), createdAt: new Date() }, { mustExist: false });
      console.log(`Przypisano „${app.name}” do grupy „${g.name}”.`);
    }
  },

  async odepnij(args) {
    const app = await libApp(args._.join(" "));
    const groups = await groupsByNames(args.grupa, "odepnij <aplikacja> --grupa Domowa");
    for (const g of groups) {
      const copies = (await listDocs(`groups/${g.id}/apps`)).filter((a) => a.packageName === app.packageName);
      for (const c of copies) await deleteDoc(c.path);
      console.log(copies.length ? `Odpięto „${app.name}” od grupy „${g.name}”.` : `„${app.name}” nie było w grupie „${g.name}”.`);
    }
  },

  async ustaw(args) {
    const app = await libApp(args._.join(" "));
    const data = {};
    if (args.nazwa !== undefined) data.name = args.nazwa;
    if (args.opis !== undefined) data.description = args.opis;
    if (args.kolejnosc !== undefined) data.order = Number(args.kolejnosc);
    if (args.ikona !== undefined) data.iconUrl = args.ikona;
    if (args.beta !== undefined) data.prerelease = yes(args.beta);
    if (args.ukryta !== undefined) data.hidden = yes(args.ukryta);
    if (!Object.keys(data).length) throw new Error("Co zmienić? --nazwa, --opis, --kolejnosc, --ikona, --beta tak/nie, --ukryta tak/nie");
    await update(`library/${app.packageName}`, data);
    const n = await syncCopies({ ...app, ...data });
    console.log(`Zmieniono „${app.name}”: ${Object.keys(data).join(", ")} (biblioteka + ${n} grup).`);
  },

  async usun(args) {
    const app = await libApp(args._.join(" "));
    if (!yes(args.na_pewno)) {
      throw new Error(`To usunie „${app.name}” z biblioteki i ze WSZYSTKICH grup. Dodaj --na_pewno tak ` +
        `(albo tylko z jednej grupy: sklep odepnij "${app.name}" --grupa NAZWA).`);
    }
    for (const g of await ownedGroups()) {
      for (const c of (await listDocs(`groups/${g.id}/apps`)).filter((a) => a.packageName === app.packageName)) await deleteDoc(c.path);
    }
    await deleteDoc(`library/${app.packageName}`);
    console.log(`Usunięto „${app.name}” z biblioteki i wszystkich grup (zainstalowane kopie zostają na telefonach).`);
  },

  async migruj() {
    await requireAdmin();
    const lib = new Map((await listDocs("library")).map((a) => [a.packageName, a]));
    let added = 0;
    for (const g of await ownedGroups()) {
      for (const a of await listDocs(`groups/${g.id}/apps`)) {
        if (lib.has(a.packageName) || a.packageName === SELF_PACKAGE) continue;
        const data = { ...copyFields(a), createdAt: new Date() };
        await update(`library/${a.packageName}`, data, { mustExist: false });
        lib.set(a.packageName, data);
        added++;
        console.log(`Biblioteka ← „${a.name}” (z grupy „${g.name}”)`);
      }
    }
    console.log(added ? `Przeniesiono do biblioteki: ${added}. Przypisania do grup bez zmian.` : "Biblioteka jest już kompletna.");
  },

  // ---------------------------------------------------------------- grupy

  async "nowa-grupa"(args) {
    const name = args._.join(" ").trim();
    if (!name) throw new Error('Podaj nazwę: sklep nowa-grupa Rodzice [--osoby "zona@example.com"]');
    await requireAdmin();
    const { uid, email } = await session();
    await createDoc("groups", {
      name, ownerId: uid, members: [uid], memberEmails: { [uid]: email.toLowerCase() },
      trustedSigners: await sharedTrustedSigners(), autoAdd: false, createdAt: new Date(),
    });
    console.log(`Utworzono grupę „${name}” (jesteś w niej Ty). Aplikacje przypisz: sklep przypisz <aplikacja> --grupa "${name}"`);
    if (args.osoby) {
      for (const e of args.osoby.split(",")) await commands["dodaj-osobe"]({ _: [e.trim()], grupa: name });
    }
  },

  async "usun-grupe"(args) {
    const [g] = await groupsByNames(args._.join(" "), "usun-grupe NAZWA --na_pewno tak");
    if (!yes(args.na_pewno)) throw new Error(`To usunie grupę „${g.name}”. Dodaj --na_pewno tak`);
    for (const sub of ["apps", "installs"]) for (const d of await listDocs(`groups/${g.id}/${sub}`)) await deleteDoc(d.path);
    await deleteDoc(`groups/${g.id}`);
    console.log(`Usunięto grupę „${g.name}”. Aplikacje zostają w bibliotece i na telefonach.`);
  },

  async auto(args) {
    const groups = await groupsByNames(args.grupa, "auto tak|nie --grupa NAZWA");
    const on = yes(args._[0] ?? "tak");
    for (const group of groups) {
      await update(`groups/${group.id}`, { autoAdd: on });
      console.log(on
        ? `Nowe aplikacje będą się same dodawać do „${group.name}” przy pierwszym wydaniu.`
        : `Automatyczne dodawanie do „${group.name}” wyłączone.`);
    }
  },

  async zaufaj(args) {
    const sha = (args._[0] ?? "").replace(/[^0-9a-fA-F]/g, "").toLowerCase();
    if (sha.length !== 64) throw new Error("Podaj odcisk SHA-256 (64 znaki szesnastkowe).");
    const groups = args.grupa ? await groupsByNames(args.grupa) : await ownedGroups();
    for (const g of groups) await update(`groups/${g.id}`, {}, { arrayUnion: { trustedSigners: [sha] } });
    console.log(`Dodano zaufany klucz do: ${groups.map((g) => g.name).join(", ")}.`);
  },

  // ---------------------------------------------------------------- osoby

  async uzytkownicy() {
    await requireAdmin();
    const users = (await listDocs("emails")).sort((a, b) => a.email.localeCompare(b.email));
    const groups = await ownedGroups();
    console.log("Konta (wszyscy, którzy zalogowali się w Zakupach, Powrocie albo Sklepie):\n");
    for (const u of users) {
      const gs = groups.filter((g) => g.members.includes(u.uid)).map((g) => g.name);
      console.log(`• ${u.email.padEnd(34)} ${gs.length ? gs.join(", ") : "— (bez grupy)"}`);
    }
    console.log(`\nPrzypisz: sklep dodaj-osobe <e-mail> --grupa Domowa,Rodzice`);
  },

  async osoby(args) {
    const groups = args.grupa ? await groupsByNames(args.grupa) : await ownedGroups();
    for (const group of groups) {
      console.log(`Grupa „${group.name}”:`);
      for (const uid of group.members) {
        console.log(`   • ${group.memberEmails?.[uid] ?? uid}${uid === group.ownerId ? "  (administrator)" : ""}`);
      }
    }
  },

  async "dodaj-osobe"(args) {
    const email = (args._[0] ?? "").trim().toLowerCase();
    if (!email.includes("@")) throw new Error("Podaj e-mail: sklep dodaj-osobe ania@example.com --grupa Domowa,Rodzice");
    const groups = await groupsByNames(args.grupa, "dodaj-osobe <e-mail> --grupa Domowa,Rodzice");
    let entry;
    try {
      entry = await getDoc(`emails/${encodeURIComponent(email)}`);
    } catch {
      throw new Error(`${email} nie ma jeszcze konta. Niech zainstaluje sklep i je założy - albo wyślij kod: sklep zaproszenie --grupa ...`);
    }
    for (const group of groups) {
      if (group.members.includes(entry.uid)) {
        console.log(`${email} już jest w grupie „${group.name}”.`);
        continue;
      }
      await update(`groups/${group.id}`, { [`memberEmails.${entry.uid}`]: email }, { arrayUnion: { members: [entry.uid] } });
      console.log(`Dodano ${email} do grupy „${group.name}”.`);
    }
  },

  async "usun-osobe"(args) {
    const q = (args._[0] ?? "").trim().toLowerCase();
    const groups = await groupsByNames(args.grupa, "usun-osobe <e-mail> --grupa Domowa");
    for (const group of groups) {
      const uid = Object.entries(group.memberEmails ?? {}).find(([, e]) => e === q)?.[0];
      if (!uid) {
        console.log(`W grupie „${group.name}” nie ma ${q}.`);
        continue;
      }
      if (uid === group.ownerId) throw new Error("Nie można usunąć administratora z jego grupy.");
      await update(`groups/${group.id}`, {}, { remove: [`memberEmails.${uid}`], arrayRemove: { members: [uid] } });
      console.log(`Usunięto ${q} z grupy „${group.name}”.`);
    }
  },

  async zaproszenie(args) {
    const [group] = await groupsByNames(args.grupa ?? (await ownedGroups()).map((g) => g.name).join(","), "zaproszenie --grupa NAZWA", { single: true });
    const { uid } = await session();
    const days = Number(args.dni ?? 7);
    const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    const code = Array.from({ length: 8 }, () => alphabet[randomInt(alphabet.length)]).join("");
    const expiresAt = new Date(Date.now() + days * 86400000);
    await createDoc("invites", { groupId: group.id, groupName: group.name, createdBy: uid, expiresAt, createdAt: new Date() }, code);
    console.log(`Kod do grupy „${group.name}”: ${code}  (ważny do ${expiresAt.toLocaleDateString("pl-PL")})\n`);
    console.log("Wiadomość do wysłania:\n");
    console.log(`Zaproszenie do sklepu rodzinnego („${group.name}”).
1. Zainstaluj sklep: https://grekot.github.io/App_storage/
2. Zaloguj się (konto z Zakupów) albo załóż konto.
3. Menu → „Dołącz kodem zaproszenia” → ${code}`);
  },

  async wersje(args) {
    const groups = args.grupa ? await groupsByNames(args.grupa) : await ownedGroups();
    for (const group of groups) {
      const apps = await listDocs(`groups/${group.id}/apps`);
      const reports = await listDocs(`groups/${group.id}/installs`);
      console.log(`\n■ ${group.name}`);
      if (!reports.length) {
        console.log("   nikt jeszcze nie zgłosił instalacji");
        continue;
      }
      for (const a of apps) {
        const rs = reports.filter((r) => r.packageName === a.packageName);
        if (!rs.length) continue;
        console.log(`   ${a.name} (najnowsza ${a.latest?.versionName ?? "?"})`);
        for (const r of rs) {
          const old = a.latest?.versionCode && r.versionCode < a.latest.versionCode;
          console.log(`      ${old ? "⚠" : "✓"} ${r.email.padEnd(32)} ${r.versionName}`);
        }
      }
    }
  },

  async pomoc() {
    console.log(`Sklep rodzinny - zarządzanie z komputera (administrator)

  sklep login                              zaloguj się (raz; konto z Zakupów)
  sklep status                             grupy, ich osoby i aplikacje

 Aplikacje (biblioteka - widzisz ją tylko Ty)
  sklep aplikacje                          wszystkie aplikacje i ich grupy
  sklep dodaj <repo> [--grupa A,B]         dodaj/odśwież w bibliotece (reszta wykrywa się sama)
        --prefiks zakupy-v                   (tylko gdy repozytorium ma kilka aplikacji)
        --nazwa "…" --opis "…" --kolejnosc 10 --beta tak --ukryta tak
  sklep przypisz <aplikacja> --grupa A,B   udostępnij aplikację grupom
  sklep odepnij <aplikacja> --grupa A      zabierz aplikację grupie
  sklep ustaw <aplikacja> [opcje]          nazwa, opis, kolejność, ikona, beta, ukrycie (wszędzie)
  sklep usun <aplikacja> --na_pewno tak    usuń z biblioteki i wszystkich grup
  sklep migruj                             jednorazowo: aplikacje z grup → biblioteka

 Grupy i osoby
  sklep nowa-grupa <nazwa> [--osoby a@x.pl,b@x.pl]
  sklep usun-grupe <nazwa> --na_pewno tak
  sklep uzytkownicy                        wszystkie konta i ich grupy
  sklep dodaj-osobe <e-mail> --grupa A,B   dodaj osobę (musi mieć konto) do grup
  sklep usun-osobe <e-mail> --grupa A
  sklep osoby [--grupa A]                  kto jest w grupach
  sklep zaproszenie --grupa A [--dni 7]    kod zaproszenia + gotowa wiadomość
  sklep wersje [--grupa A]                 kto ma którą wersję
  sklep auto tak|nie --grupa A             nowe wydania dodają się do grupy same (domyślnie nie)
  sklep zaufaj <sha256> [--grupa A]        dodatkowy zaufany klucz podpisu
  sklep wyloguj

<aplikacja> = fragment nazwy albo pakiet, np. zakupy. Nazwy z spacjami w cudzysłowie.`);
  },
};

// ------------------------------------------------------------------ pomocnicze (administrator)

const ADMINS = ["82qeJdUO8qbzhniNK6bE6xUEovW2"]; // jak isAdmin w firebase/firestore.rules
const isAdminUid = (uid) => ADMINS.includes(uid);

async function requireAdmin() {
  const { uid } = await session();
  if (!isAdminUid(uid)) throw new Error("To polecenie jest tylko dla administratora sklepu.");
}

async function ownedGroups() {
  const { uid } = await session();
  return (await myGroups()).filter((g) => g.ownerId === uid);
}

/** "Domowa,Rodzice" -> grupy administratora (dopasowanie bez wielkości liter, też fragmentem). */
async function groupsByNames(names, usage = "", { single = false } = {}) {
  const owned = await ownedGroups();
  if (!owned.length) throw new Error("Nie prowadzisz żadnej grupy. Utwórz: sklep nowa-grupa Rodzice");
  if (!names) {
    if (owned.length === 1) return owned;
    throw new Error(`Podaj --grupa (${owned.map((g) => g.name).join(", ")})${usage ? ". Np.: sklep " + usage : ""}`);
  }
  const out = [];
  for (const n of String(names).split(",").map((s) => s.trim().toLowerCase()).filter(Boolean)) {
    const g = owned.find((x) => x.name.toLowerCase() === n) ?? owned.find((x) => x.name.toLowerCase().includes(n));
    if (!g) throw new Error(`Nie ma grupy „${n}”. Twoje grupy: ${owned.map((x) => x.name).join(", ")}`);
    if (!out.includes(g)) out.push(g);
  }
  if (single && out.length > 1) throw new Error(`Wybierz jedną grupę --grupa (${owned.map((g) => g.name).join(", ")})`);
  return out;
}

async function libApp(query) {
  await requireAdmin();
  if (!query.trim()) throw new Error("Podaj aplikację (fragment nazwy albo pakiet).");
  const lib = await listDocs("library");
  const hit = findApps(lib, query);
  if (!hit.length) throw new Error(`W bibliotece nie ma „${query}”. Lista: sklep aplikacje`);
  if (hit.length > 1) throw new Error(`„${query}” pasuje do kilku: ${hit.map((a) => a.name).join(", ")} - doprecyzuj.`);
  return hit[0];
}

/** Pola kopiowane z biblioteki do grup. */
function copyFields(a) {
  const out = {};
  for (const k of ["name", "description", "packageName", "repo", "tagPrefix", "assetName", "iconUrl", "order", "prerelease", "hidden", "latest"]) {
    if (a[k] !== undefined && a[k] !== null) out[k] = a[k];
  }
  return out;
}

/** Zmiany wpisu biblioteki trafiają do jego kopii we wszystkich grupach administratora. */
async function syncCopies(app) {
  let n = 0;
  for (const g of await ownedGroups()) {
    for (const c of (await listDocs(`groups/${g.id}/apps`)).filter((a) => a.packageName === app.packageName)) {
      await update(c.path, copyFields(app));
      n++;
    }
  }
  return n;
}

async function assignmentMap(groups) {
  const map = new Map();
  for (const g of groups) {
    for (const a of await listDocs(`groups/${g.id}/apps`)) map.set(a.packageName, [...(map.get(a.packageName) ?? []), g]);
  }
  return map;
}

/** Zaufane klucze z istniejących grup - nowa grupa dostaje te same. */
async function sharedTrustedSigners() {
  const all = new Set();
  for (const g of await ownedGroups()) (g.trustedSigners ?? []).forEach((s) => all.add(s));
  return [...all];
}

const sortApps = (apps) => apps.sort((a, b) => (a.order ?? 100) - (b.order ?? 100) || a.name.localeCompare(b.name));

function appLine(a) {
  const v = a.latest ? `${a.latest.versionName} (${a.latest.versionCode})` : "wersja z GitHuba";
  return `${a.name.padEnd(22)} ${v.padEnd(16)} ${a.repo} ${a.tagPrefix}*${a.hidden ? "  [ukryta]" : ""}${a.prerelease ? "  [beta]" : ""}`;
}


commands.help = commands.pomoc;
commands["usuń"] = commands.usun;
commands["użytkownicy"] = commands.uzytkownicy;
commands.uzytkownik = commands.uzytkownicy;

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
