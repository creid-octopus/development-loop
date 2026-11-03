const { test } = require("node:test");
const assert = require("node:assert");
const { branding, DEFAULT_NAME } = require("../branding");

test("untenanted deploys get the default name and the environment colour", () => {
  assert.deepStrictEqual(branding({}, "#1d4ed8"), { name: DEFAULT_NAME, colour: "#1d4ed8", tenanted: false });
  assert.deepStrictEqual(branding({ BRAND_NAME: " ", BRAND_COLOR: "" }, "#1d4ed8"), { name: DEFAULT_NAME, colour: "#1d4ed8", tenanted: false });
});

test("a tenant's name and colour replace the defaults", () => {
  assert.deepStrictEqual(branding({ BRAND_NAME: "Radiant Industries", BRAND_COLOR: "#E11D48" }, "#1d4ed8"),
    { name: "Radiant Industries", colour: "#E11D48", tenanted: true });
});

test("a colour that isn't hex falls back to the environment colour", () => {
  for (const bad of ["red", "#12345", "#123456; background: url(x)", "e11d48"]) {
    assert.strictEqual(branding({ BRAND_COLOR: bad }, "#1d4ed8").colour, "#1d4ed8");
  }
});

test("the name is HTML-escaped", () => {
  assert.strictEqual(branding({ BRAND_NAME: "<b>Cannon & Co's</b>" }, "#000").name, "&lt;b&gt;Cannon &amp; Co&#39;s&lt;/b&gt;");
});
