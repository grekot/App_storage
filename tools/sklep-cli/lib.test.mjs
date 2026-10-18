import { test } from "node:test";
import assert from "node:assert/strict";
import {
  findApps,
  fromDoc,
  fromValue,
  normalizeRepo,
  parseArgs,
  pickRelease,
  prefixesIn,
  tagMatchesPrefix,
  tagPrefixOf,
  toValue,
  yes,
} from "./lib.mjs";

test("Firestore: wartości w obie strony", () => {
  const obj = { a: 1, b: 1.5, c: "x", d: true, e: null, f: [1, "y"], g: { h: 2 }, t: new Date("2026-10-18T10:00:00Z") };
  const back = fromValue(toValue(obj));
  assert.deepEqual(back, obj);
  assert.deepEqual(toValue(42), { integerValue: "42" });
});

test("Firestore: dokument", () => {
  const d = fromDoc({
    name: "projects/p/databases/(default)/documents/groups/g1/apps/a1",
    fields: { name: { stringValue: "Zakupy" } },
  });
  assert.equal(d.id, "a1");
  assert.equal(d.path, "groups/g1/apps/a1");
  assert.equal(d.name, "Zakupy");
});

test("prefiksy tagów", () => {
  assert.equal(tagPrefixOf("zakupy-v1.0.1"), "zakupy-v");
  assert.equal(tagPrefixOf("v1.2.0"), "v");
  assert.equal(tagPrefixOf("1.2.0"), "v");
  assert.ok(tagMatchesPrefix("v1.0.0", "v"));
  assert.ok(!tagMatchesPrefix("zakupy-v1.0.0", "v"));
  assert.ok(tagMatchesPrefix("zakupy-v1.0.0", "zakupy-v"));
});

const rel = (tag, opts = {}) => ({
  tag_name: tag,
  draft: false,
  prerelease: false,
  assets: [{ name: "x.apk" }],
  ...opts,
});

test("monorepo: lista prefiksów i wybór wydania", () => {
  const list = [
    rel("powrot-v1.0.2"),
    rel("zakupy-v1.0.3", { prerelease: true }),
    rel("zakupy-v1.0.1"),
    rel("v0.1.0", { assets: [] }),
  ];
  assert.deepEqual(prefixesIn(list), ["powrot-v", "zakupy-v"]);
  assert.equal(pickRelease(list, "zakupy-v").tag_name, "zakupy-v1.0.1");
  assert.equal(pickRelease(list, "zakupy-v", true).tag_name, "zakupy-v1.0.3");
  assert.equal(pickRelease(list, "v"), null);
});

test("repozytorium z linku i skrótu", () => {
  assert.equal(normalizeRepo("EscapeRoom"), "grekot/EscapeRoom");
  assert.equal(normalizeRepo("https://github.com/grekot/GPS_RTK.git"), "grekot/GPS_RTK");
  assert.equal(normalizeRepo("grekot/T_rex_3/"), "grekot/T_rex_3");
  assert.throws(() => normalizeRepo("zly adres"));
});

test("wyszukiwanie aplikacji bez polskich znaków", () => {
  const apps = [
    { name: "Pokój Zagadek AI", packageName: "pl.escaperoom.escape_room" },
    { name: "Powrót", packageName: "pl.grekot.powrot" },
    { name: "Zakupy", packageName: "pl.grekot.zakupy" },
  ];
  assert.equal(findApps(apps, "pokoj")[0].name, "Pokój Zagadek AI");
  assert.equal(findApps(apps, "pl.grekot.zakupy").length, 1);
  assert.equal(findApps(apps, "powrot")[0].name, "Powrót");
  assert.equal(findApps(apps, "po").length, 2);
});

test("argumenty", () => {
  assert.deepEqual(parseArgs(["grekot/X", "--nazwa", "Ala ma", "--beta", "--kolejnosc=5"]), {
    _: ["grekot/X"],
    nazwa: "Ala ma",
    beta: "tak",
    kolejnosc: "5",
  });
  assert.equal(yes("tak"), true);
  assert.equal(yes("nie"), false);
  assert.equal(yes(undefined), undefined);
});
