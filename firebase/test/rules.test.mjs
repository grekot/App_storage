// Testy reguł Firestore na emulatorze: npm test (w folderze firebase/test).
import { after, before, beforeEach, describe, test } from "node:test";
import { readFileSync } from "node:fs";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  Timestamp,
  arrayRemove,
  arrayUnion,
  collection,
  deleteDoc,
  deleteField,
  doc,
  getDoc,
  getDocs,
  query,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
} from "firebase/firestore";

// Administrator = uid wpisany w regułach (isAdmin).
const OWNER = { uid: "82qeJdUO8qbzhniNK6bE6xUEovW2", email: "owner@x.pl" };
const MEMBER = { uid: "member", email: "member@x.pl" };
const NEW = { uid: "newbie", email: "newbie@x.pl" };
const OUTSIDER = { uid: "outsider", email: "outsider@x.pl" };

let env;
const db = (u) => env.authenticatedContext(u.uid, { email: u.email }).firestore();

const inDays = (d) => Timestamp.fromMillis(Date.now() + d * 86400000);

before(async () => {
  const [host, port] = (process.env.FIRESTORE_EMULATOR_HOST || "127.0.0.1:8181").split(":");
  env = await initializeTestEnvironment({
    projectId: "demo-sklep",
    firestore: { rules: readFileSync(new URL("../firestore.rules", import.meta.url), "utf8"), host, port: +port },
  });
});

after(async () => env?.cleanup());

beforeEach(async () => {
  await env.clearFirestore();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const f = ctx.firestore();
    await setDoc(doc(f, "groups/g1"), {
      name: "Rodzina",
      ownerId: OWNER.uid,
      members: [OWNER.uid, MEMBER.uid],
      memberEmails: { [OWNER.uid]: OWNER.email, [MEMBER.uid]: MEMBER.email },
      trustedSigners: [],
    });
    await setDoc(doc(f, "groups/g2"), {
      name: "Inna",
      ownerId: OUTSIDER.uid,
      members: [OUTSIDER.uid],
      memberEmails: { [OUTSIDER.uid]: OUTSIDER.email },
    });
    await setDoc(doc(f, "groups/g1/apps/a1"), {
      name: "Zakupy",
      packageName: "pl.grekot.zakupy",
      repo: "grekot/T_rex_3",
      tagPrefix: "zakupy-v",
    });
    await setDoc(doc(f, "invites/GOODCODE"), {
      groupId: "g1", groupName: "Rodzina", createdBy: OWNER.uid, expiresAt: inDays(7),
    });
    await setDoc(doc(f, "invites/OLDCODE1"), {
      groupId: "g1", groupName: "Rodzina", createdBy: OWNER.uid, expiresAt: inDays(-1),
    });
    await setDoc(doc(f, "invites/OTHERG22"), {
      groupId: "g2", groupName: "Inna", createdBy: OUTSIDER.uid, expiresAt: inDays(7),
    });
  });
});

const join = (u, gid, code) =>
  updateDoc(doc(db(u), `groups/${gid}`), {
    members: arrayUnion(u.uid),
    [`memberEmails.${u.uid}`]: u.email,
    lastInvite: code,
    updatedAt: serverTimestamp(),
  });

describe("grupy", () => {
  test("członek czyta, obcy nie", async () => {
    await assertSucceeds(getDoc(doc(db(MEMBER), "groups/g1")));
    await assertFails(getDoc(doc(db(OUTSIDER), "groups/g1")));
  });

  test("zapytanie o moje grupy", async () => {
    const snap = await assertSucceeds(
      getDocs(query(collection(db(MEMBER), "groups"), where("members", "array-contains", MEMBER.uid))),
    );
    if (snap.size !== 1) throw new Error("oczekiwano 1 grupy, jest " + snap.size);
  });

  test("grupy zakłada tylko administrator, jako właściciel i jedyny członek", async () => {
    const adm = { name: "Nowa", memberEmails: { [OWNER.uid]: OWNER.email } };
    await assertSucceeds(setDoc(doc(db(OWNER), "groups/n1"), { ...adm, ownerId: OWNER.uid, members: [OWNER.uid] }));
    await assertFails(
      setDoc(doc(db(OWNER), "groups/n2"), { ...adm, ownerId: OWNER.uid, members: [OWNER.uid, MEMBER.uid] }),
    );
    const base = { name: "Moja", memberEmails: { [NEW.uid]: NEW.email } };
    await assertFails(setDoc(doc(db(NEW), "groups/n3"), { ...base, ownerId: NEW.uid, members: [NEW.uid] }));
    await assertFails(setDoc(doc(db(NEW), "groups/n4"), { ...base, ownerId: OWNER.uid, members: [NEW.uid] }));
  });

  test("nie-administrator nie zarządza nawet grupą, której jest właścicielem", async () => {
    // g2 należy do OUTSIDER (np. grupa sprzed zmiany reguł)
    await assertFails(updateDoc(doc(db(OUTSIDER), "groups/g2"), { name: "Zmieniona" }));
    await assertFails(
      setDoc(doc(db(OUTSIDER), "groups/g2/apps/x"), { name: "X", packageName: "pl.x.y", repo: "a/b" }),
    );
    await assertFails(
      setDoc(doc(db(OUTSIDER), "invites/ZZZZZZZZ"), {
        groupId: "g2", groupName: "Inna", createdBy: OUTSIDER.uid, expiresAt: inDays(7),
      }),
    );
    await assertFails(deleteDoc(doc(db(OUTSIDER), "groups/g2")));
    await assertSucceeds(getDoc(doc(db(OUTSIDER), "groups/g2")));
  });

  test("właściciel dodaje i usuwa osoby, członek nie", async () => {
    await assertSucceeds(
      updateDoc(doc(db(OWNER), "groups/g1"), { members: arrayUnion(NEW.uid), [`memberEmails.${NEW.uid}`]: NEW.email }),
    );
    await assertFails(
      updateDoc(doc(db(MEMBER), "groups/g1"), { members: arrayUnion(OUTSIDER.uid) }),
    );
    await assertSucceeds(
      updateDoc(doc(db(OWNER), "groups/g1"), { members: arrayRemove(NEW.uid), [`memberEmails.${NEW.uid}`]: deleteField() }),
    );
  });

  test("właściciel nie może zniknąć z grupy ani oddać jej przez pole ownerId", async () => {
    await assertFails(updateDoc(doc(db(OWNER), "groups/g1"), { members: arrayRemove(OWNER.uid) }));
    await assertFails(updateDoc(doc(db(OWNER), "groups/g1"), { ownerId: MEMBER.uid }));
  });

  test("członek nie zmienia grupy i nie wychodzi sam (usuwa go administrator)", async () => {
    await assertFails(updateDoc(doc(db(MEMBER), "groups/g1"), { name: "Moja" }));
    await assertFails(
      updateDoc(doc(db(MEMBER), "groups/g1"), {
        members: arrayRemove(MEMBER.uid), [`memberEmails.${MEMBER.uid}`]: deleteField(), updatedAt: serverTimestamp(),
      }),
    );
    await assertSucceeds(
      updateDoc(doc(db(OWNER), "groups/g1"), {
        members: arrayRemove(MEMBER.uid), [`memberEmails.${MEMBER.uid}`]: deleteField(), updatedAt: serverTimestamp(),
      }),
    );
  });

  test("członek nie zmienia zaufanych kluczy", async () => {
    await assertFails(updateDoc(doc(db(MEMBER), "groups/g1"), { trustedSigners: ["ab"] }));
    await assertSucceeds(updateDoc(doc(db(OWNER), "groups/g1"), { trustedSigners: arrayUnion("ab") }));
  });
});

describe("zaproszenia", () => {
  test("dołączenie ważnym kodem", async () => {
    await assertSucceeds(join(NEW, "g1", "GOODCODE"));
    await assertSucceeds(getDoc(doc(db(NEW), "groups/g1")));
  });

  test("wygasły kod, kod innej grupy, brak kodu", async () => {
    await assertFails(join(NEW, "g1", "OLDCODE1"));
    await assertFails(join(NEW, "g1", "OTHERG22"));
    await assertFails(join(NEW, "g1", "NIEMATAK"));
  });

  test("przy dołączeniu nie można zmienić nazwy ani wpisać cudzego e-maila", async () => {
    await assertFails(
      updateDoc(doc(db(NEW), "groups/g1"), {
        members: arrayUnion(NEW.uid), [`memberEmails.${NEW.uid}`]: NEW.email, lastInvite: "GOODCODE", name: "X",
      }),
    );
    await assertFails(
      updateDoc(doc(db(NEW), "groups/g1"), {
        members: arrayUnion(NEW.uid), [`memberEmails.${NEW.uid}`]: "ktos@x.pl", lastInvite: "GOODCODE",
      }),
    );
    await assertFails(
      updateDoc(doc(db(NEW), "groups/g1"), {
        members: arrayUnion(NEW.uid, OUTSIDER.uid), [`memberEmails.${NEW.uid}`]: NEW.email, lastInvite: "GOODCODE",
      }),
    );
  });

  test("tworzy tylko właściciel grupy, ważność do 31 dni", async () => {
    const inv = (u, gid, d) => ({ groupId: gid, groupName: "x", createdBy: u.uid, expiresAt: inDays(d) });
    await assertSucceeds(setDoc(doc(db(OWNER), "invites/ABCDEFGH"), inv(OWNER, "g1", 7)));
    await assertFails(setDoc(doc(db(MEMBER), "invites/ABCDEFGJ"), inv(MEMBER, "g1", 7)));
    await assertFails(setDoc(doc(db(OWNER), "invites/ABCDEFGK"), inv(OWNER, "g1", 60)));
    await assertFails(setDoc(doc(db(OWNER), "invites/ABC"), inv(OWNER, "g1", 7)));
  });

  test("odczyt pojedynczego kodu tak, przeglądanie cudzych nie", async () => {
    await assertSucceeds(getDoc(doc(db(NEW), "invites/GOODCODE")));
    await assertFails(getDocs(collection(db(NEW), "invites")));
    await assertSucceeds(getDocs(query(collection(db(OWNER), "invites"), where("createdBy", "==", OWNER.uid))));
  });

  test("usuwa twórca", async () => {
    await assertFails(deleteDoc(doc(db(MEMBER), "invites/GOODCODE")));
    await assertSucceeds(deleteDoc(doc(db(OWNER), "invites/GOODCODE")));
  });
});

describe("aplikacje", () => {
  const app = { name: "Powrót", packageName: "pl.grekot.powrot", repo: "grekot/T_rex_3" };

  test("członek czyta, obcy nie", async () => {
    await assertSucceeds(getDocs(collection(db(MEMBER), "groups/g1/apps")));
    await assertFails(getDocs(collection(db(OUTSIDER), "groups/g1/apps")));
  });

  test("zapisuje tylko właściciel, z poprawnymi polami", async () => {
    await assertSucceeds(setDoc(doc(db(OWNER), "groups/g1/apps/a2"), app));
    await assertFails(setDoc(doc(db(MEMBER), "groups/g1/apps/a3"), app));
    await assertFails(setDoc(doc(db(OWNER), "groups/g1/apps/a4"), { ...app, repo: "https://evil" }));
    await assertFails(setDoc(doc(db(OWNER), "groups/g1/apps/a5"), { ...app, packageName: "zly pakiet" }));
    await assertFails(deleteDoc(doc(db(MEMBER), "groups/g1/apps/a1")));
    await assertSucceeds(deleteDoc(doc(db(OWNER), "groups/g1/apps/a1")));
  });
});

describe("kto ma którą wersję", () => {
  const rep = (u) => ({ uid: u.uid, email: u.email, packageName: "pl.grekot.zakupy", versionName: "1.0.0", versionCode: 3 });

  test("członek zapisuje swój wpis, nie cudzy", async () => {
    await assertSucceeds(setDoc(doc(db(MEMBER), `groups/g1/installs/${MEMBER.uid}_pl.grekot.zakupy`), rep(MEMBER)));
    await assertFails(setDoc(doc(db(MEMBER), `groups/g1/installs/${OWNER.uid}_pl.grekot.zakupy`), rep(OWNER)));
    await assertFails(setDoc(doc(db(OUTSIDER), `groups/g1/installs/${OUTSIDER.uid}_pl.grekot.zakupy`), rep(OUTSIDER)));
  });

  test("właściciel widzi wszystkie, członek tylko swoje", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `groups/g1/installs/${OWNER.uid}_pl.grekot.zakupy`), rep(OWNER));
    });
    await assertSucceeds(getDocs(collection(db(OWNER), "groups/g1/installs")));
    await assertFails(getDocs(collection(db(MEMBER), "groups/g1/installs")));
    await assertFails(getDoc(doc(db(MEMBER), `groups/g1/installs/${OWNER.uid}_pl.grekot.zakupy`)));
  });
});

describe("biblioteka i lista kont (tylko administrator)", () => {
  const lib = { name: "Zakupy", packageName: "pl.grekot.zakupy", repo: "grekot/T_rex_3", tagPrefix: "zakupy-v" };

  test("biblioteka: administrator czyta i zapisuje, inni nie", async () => {
    await assertSucceeds(setDoc(doc(db(OWNER), "library/pl.grekot.zakupy"), lib));
    await assertSucceeds(getDocs(collection(db(OWNER), "library")));
    await assertFails(getDocs(collection(db(MEMBER), "library")));
    await assertFails(getDoc(doc(db(MEMBER), "library/pl.grekot.zakupy")));
    await assertFails(setDoc(doc(db(MEMBER), "library/pl.x.y"), { ...lib, packageName: "pl.x.y" }));
    await assertFails(setDoc(doc(db(OWNER), "library/inna.nazwa"), lib)); // id = pakiet
    await assertSucceeds(deleteDoc(doc(db(OWNER), "library/pl.grekot.zakupy")));
  });

  test("lista kont: administrator tak, inni tylko pojedynczy wpis", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), `emails/${MEMBER.email}`), { uid: MEMBER.uid, email: MEMBER.email });
    });
    await assertSucceeds(getDocs(collection(db(OWNER), "emails")));
    await assertFails(getDocs(collection(db(MEMBER), "emails")));
    await assertSucceeds(getDoc(doc(db(NEW), `emails/${MEMBER.email}`)));
  });
});

describe("Zakupy i Powrót bez zmian", () => {
  test("własna lista i książka adresowa", async () => {
    await assertSucceeds(
      setDoc(doc(db(MEMBER), "lists/l1"), {
        name: "Biedronka", ownerId: MEMBER.uid, members: [MEMBER.uid], memberEmails: { [MEMBER.uid]: MEMBER.email },
      }),
    );
    await assertFails(getDoc(doc(db(OUTSIDER), "lists/l1")));
    await assertSucceeds(setDoc(doc(db(MEMBER), `emails/${MEMBER.email}`), { uid: MEMBER.uid, email: MEMBER.email }));
    await assertFails(setDoc(doc(db(MEMBER), `emails/${OUTSIDER.email}`), { uid: MEMBER.uid, email: OUTSIDER.email }));
  });
});
