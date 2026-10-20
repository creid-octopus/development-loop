// Unit tests that need no database and no Docker. Run with `npm test` in src/.
// They cover what the app does when the database is missing or wrong, because
// that is the behavior a deployment depends on.

const { test } = require("node:test");
const assert = require("node:assert");

// db.js reads the environment when it loads, so each case loads a fresh copy.
function loadDb(env) {
  for (const k of ["DATABASE_URL", "PGHOST", "PGPORT", "PGUSER", "PGPASSWORD", "PGDATABASE"]) delete process.env[k];
  Object.assign(process.env, env);
  delete require.cache[require.resolve("../db")];
  return require("../db");
}

test("with no configuration the app reports 'not configured' and does not throw", async () => {
  const db = loadDb({});
  assert.strictEqual(db.configured, false);
  assert.deepStrictEqual(await db.status(), { status: "not configured" });
  await assert.rejects(() => db.query("SELECT 1"), { code: "DB_NOT_CONFIGURED" });
});

test("DATABASE_URL is parsed and the password is never reported", async () => {
  const db = loadDb({ DATABASE_URL: "postgres://app:s3cret@db.example:5433/orders" });
  assert.deepStrictEqual(db.target(), { host: "db.example", port: "5433", database: "orders", user: "app" });
  assert.ok(!JSON.stringify(db.target()).includes("s3cret"));
  await db.close();
});

test("PG* variables work when DATABASE_URL is unset", async () => {
  const db = loadDb({ PGHOST: "pg.internal", PGUSER: "svc", PGDATABASE: "tenant_a" });
  assert.deepStrictEqual(db.target(), { host: "pg.internal", port: "5432", database: "tenant_a", user: "svc" });
  await db.close();
});

test("an unreachable database is reported as 'unreachable' with the target, not thrown", async () => {
  // Port 1 refuses connections immediately.
  const db = loadDb({ DATABASE_URL: "postgres://app:x@127.0.0.1:1/none", PGCONNECT_TIMEOUT_MS: "500" });
  const s = await db.status();
  assert.strictEqual(s.status, "unreachable");
  assert.strictEqual(s.host, "127.0.0.1");
  assert.ok(s.error);
  await db.close();
});
