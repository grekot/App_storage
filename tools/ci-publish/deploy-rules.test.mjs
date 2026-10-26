import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { collections, compare, normalize } from "./deploy-rules.mjs";

const rules = readFileSync(new URL("../../firebase/firestore.rules", import.meta.url), "utf8");

test("kolekcje z prawdziwych reguł projektu", () => {
  const c = collections(rules);
  for (const name of ["lists", "items", "places", "korona", "waga", "emails", "users", "groups", "library", "invites"]) {
    assert.ok(c.has(name), "brak " + name);
  }
  assert.ok(!c.has("databases"));
});

test("komentarze nie liczą się jako bloki", () => {
  const src = "// match /stare/{id} {\n/* match /inne/{x} */\nmatch /nowe/{id} { allow read: if false; }";
  assert.deepEqual([...collections(src)], ["nowe"]);
});

test("porównanie: końce linii bez znaczenia, dodane i usunięte kolekcje", () => {
  assert.equal(normalize("a\r\nb\r\n"), "a\nb");
  assert.equal(compare("match /a/{x} {}\r\n", "match /a/{x} {}\n").same, true);
  const d = compare("match /a/{x} {} match /b/{x} {}", "match /a/{x} {} match /c/{x} {}");
  assert.equal(d.same, false);
  assert.deepEqual(d.added, ["c"]);
  assert.deepEqual(d.removed, ["b"]);
  // pierwsza publikacja: nic nie znika
  assert.deepEqual(compare("", rules).removed, []);
});
