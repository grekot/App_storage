// Czysta logika polecenia `sklep` (bez sieci) - testowana w lib.test.mjs.

/** Wartość JS -> wartość Firestore REST. */
export function toValue(v) {
  if (v === null || v === undefined) return { nullValue: null };
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  if (typeof v === "boolean") return { booleanValue: v };
  if (typeof v === "number") return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  if (typeof v === "string") return { stringValue: v };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(toValue) } };
  if (typeof v === "object") return { mapValue: { fields: toFields(v) } };
  throw new Error("Nieobsługiwany typ: " + typeof v);
}

export function toFields(obj) {
  const out = {};
  for (const [k, v] of Object.entries(obj)) if (v !== undefined) out[k] = toValue(v);
  return out;
}

/** Wartość Firestore REST -> JS (znaczniki czasu jako Date). */
export function fromValue(v) {
  if (!v || "nullValue" in v) return null;
  if ("booleanValue" in v) return v.booleanValue;
  if ("integerValue" in v) return Number(v.integerValue);
  if ("doubleValue" in v) return v.doubleValue;
  if ("stringValue" in v) return v.stringValue;
  if ("timestampValue" in v) return new Date(v.timestampValue);
  if ("arrayValue" in v) return (v.arrayValue.values ?? []).map(fromValue);
  if ("mapValue" in v) return fromFields(v.mapValue.fields ?? {});
  return null;
}

export function fromFields(fields) {
  const out = {};
  for (const [k, v] of Object.entries(fields ?? {})) out[k] = fromValue(v);
  return out;
}

/** Dokument REST -> { id, path, ...pola } */
export function fromDoc(doc) {
  const path = doc.name.split("/documents/")[1];
  return { id: path.split("/").pop(), path, ...fromFields(doc.fields) };
}

/** Prefiks tagu: "zakupy-v1.0.1" -> "zakupy-v", "v1.2.0" -> "v", "1.2.0" -> "v". */
export function tagPrefixOf(tag) {
  const m = /^(.*?)(\d+(?:\.\d+)*.*)$/.exec(tag.trim());
  if (!m) return null;
  return m[1] === "" ? "v" : m[1];
}

/** Czy tag należy do prefiksu (tak samo jak w aplikacji sklepu: tagMatchesPrefix). */
export function tagMatchesPrefix(tag, prefix) {
  const t = tag.trim();
  if (!prefix || prefix === "v" || prefix === "V") return /^[vV]?\d/.test(t);
  return t.startsWith(prefix) && /^[vV]?\d/.test(t.slice(prefix.length));
}

const isApk = (a) => /\.apk$/i.test(a.name ?? "");

/** Prefiksy aplikacji w repozytorium (monorepo ma kilka), od najnowszego wydania. */
export function prefixesIn(releases) {
  const seen = [];
  for (const r of releases) {
    if (r.draft || !(r.assets ?? []).some(isApk)) continue;
    const p = tagPrefixOf(r.tag_name ?? "");
    if (p && !seen.includes(p)) seen.push(p);
  }
  return seen;
}

/** Najnowsze wydanie z APK dla prefiksu (bez pre-release, chyba że withPre). */
export function pickRelease(releases, prefix, withPre = false) {
  return (
    releases.find(
      (r) => !r.draft && (withPre || !r.prerelease) && tagMatchesPrefix(r.tag_name ?? "", prefix) && (r.assets ?? []).some(isApk),
    ) ?? null
  );
}

/** Nazwa repozytorium z linku albo skrótu: "https://github.com/grekot/X(.git)" -> "grekot/X", "X" -> "grekot/X". */
export function normalizeRepo(input, owner = "grekot") {
  let s = input.trim().replace(/\.git$/, "").replace(/\/+$/, "");
  const m = /github\.com[/:]([^/]+\/[^/]+)/.exec(s);
  if (m) s = m[1];
  if (!s.includes("/")) s = `${owner}/${s}`;
  if (!/^[\w.-]+\/[\w.-]+$/.test(s)) throw new Error("Niepoprawne repozytorium: " + input);
  return s;
}

/** Dopasowanie aplikacji po pakiecie albo fragmencie nazwy (bez wielkości liter i polskich znaków). */
export function findApps(apps, query) {
  const norm = (s) =>
    (s ?? "")
      .toLowerCase()
      .normalize("NFD")
      .replace(/[̀-ͯ]/g, "")
      .replace(/ł/g, "l");
  const q = norm(query);
  const exact = apps.filter((a) => norm(a.packageName) === q || norm(a.name) === q);
  if (exact.length) return exact;
  return apps.filter((a) => norm(a.packageName).includes(q) || norm(a.name).includes(q));
}

/** "--nazwa X --beta tak pozycja" -> { _: ["pozycja"], nazwa: "X", beta: "tak" } */
export function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const [k, v] = a.slice(2).split("=", 2);
      if (v !== undefined) out[k] = v;
      else if (i + 1 < argv.length && !argv[i + 1].startsWith("--")) out[k] = argv[++i];
      else out[k] = "tak";
    } else out._.push(a);
  }
  return out;
}

export function yes(v) {
  if (v === undefined) return undefined;
  return ["tak", "t", "yes", "y", "true", "1", "on"].includes(String(v).toLowerCase());
}
