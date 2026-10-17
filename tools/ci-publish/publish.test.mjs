import { test } from "node:test";
import assert from "node:assert/strict";
import { buildLatest, buildMessage, topicFor } from "./publish.mjs";

const appJson = {
  schema: "grekot-app-release/1",
  packageName: "pl.grekot.zakupy",
  versionName: "1.3.0",
  versionCode: 42,
  minSdk: 24,
  targetSdk: 36,
  assetName: "zakupy.apk",
  size: 123,
  sha256: "ab".repeat(32),
  signerSha256: "cd".repeat(32),
  abi: "arm64-v8a",
  tag: "zakupy-v1.3.0",
  commit: "abc",
  publishedAt: "2026-10-17T08:00:00Z",
};

test("temat FCM jak w sklepie (Notifications.topicFor)", () => {
  assert.equal(topicFor("pl.grekot.zakupy"), "app_pl_grekot_zakupy");
});

test("pole latest ma klucze AppRelease", () => {
  const l = buildLatest(appJson, { apkUrl: "https://github.com/x/zakupy.apk", releaseUrl: "https://github.com/x" });
  assert.equal(l.versionCode, 42);
  assert.equal(l.apkUrl, "https://github.com/x/zakupy.apk");
  assert.equal(l.signerSha256, "cd".repeat(32));
  assert.equal(l.prerelease, false);
  for (const k of ["tag", "versionName", "packageName", "sha256", "size", "minSdk", "notes", "htmlUrl", "publishedAt"]) {
    assert.ok(k in l, k);
  }
});

test("odrzuca obcy format", () => {
  assert.throws(() => buildLatest({ ...appJson, schema: "x" }, { apkUrl: "" }));
  assert.throws(() => buildLatest({ ...appJson, versionCode: undefined }, { apkUrl: "" }));
});

test("wiadomość FCM", () => {
  const l = buildLatest(appJson, { apkUrl: "u", releaseUrl: "r" });
  const m = buildMessage("Zakupy", l);
  assert.equal(m.topic, "app_pl_grekot_zakupy");
  assert.equal(m.notification.title, "Zakupy 1.3.0");
  assert.equal(m.data.packageName, "pl.grekot.zakupy");
  assert.equal(m.android.notification.channelId, "nowe_wersje");
});
