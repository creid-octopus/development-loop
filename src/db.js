// Postgres access. Everything about where the database lives comes from the
// environment. Nothing in this file knows about Docker, Kubernetes, or a vendor.
//
// Two ways to configure the connection. The first one wins.
//   DATABASE_URL                       postgres://user:password@host:5432/dbname
//   PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE   the standard libpq variables
//
// With neither set the app still starts. The item endpoints return 503 and
// /health reports "not configured". That keeps the app runnable on its own.
//
// The app never creates or changes tables. Flyway does that before the app
// deploys (see db/migrations and scripts/migrate.sh).

const { Pool } = require("pg");

const configured = Boolean(process.env.DATABASE_URL || process.env.PGHOST);

let pool = null;
if (configured) {
  pool = new Pool({
    // pg reads PG* variables on its own. connectionString overrides them.
    connectionString: process.env.DATABASE_URL || undefined,
    max: Number(process.env.PGPOOL_MAX || 5),
    // Fail fast. A request should not hang for 30 seconds on a dead database.
    connectionTimeoutMillis: Number(process.env.PGCONNECT_TIMEOUT_MS || 3000),
    idleTimeoutMillis: 30_000,
  });
  // A broken idle connection must not crash the process.
  pool.on("error", (err) => console.error("postgres pool error:", err.message));
}

// Where we are connecting, for logs and /health. Never includes the password.
function target() {
  if (!configured) return null;
  try {
    if (process.env.DATABASE_URL) {
      const u = new URL(process.env.DATABASE_URL);
      return { host: u.hostname, port: u.port || "5432", database: u.pathname.slice(1), user: decodeURIComponent(u.username) };
    }
  } catch {
    return { host: "invalid DATABASE_URL" };
  }
  return {
    host: process.env.PGHOST,
    port: process.env.PGPORT || "5432",
    database: process.env.PGDATABASE || process.env.PGUSER || "postgres",
    user: process.env.PGUSER || "unknown",
  };
}

// Reports the database state. Never throws.
//   status:        "not configured" | "ok" | "unreachable"
//   schemaVersion: latest successful Flyway migration, or null before the first
async function status() {
  if (!configured) return { status: "not configured" };
  try {
    const started = Date.now();
    await pool.query("SELECT 1");
    const latencyMs = Date.now() - started;
    let schemaVersion = null;
    try {
      const r = await pool.query(
        "SELECT version FROM flyway_schema_history WHERE success AND version IS NOT NULL ORDER BY installed_rank DESC LIMIT 1"
      );
      schemaVersion = r.rows[0]?.version ?? null;
    } catch (err) {
      // 42P01 = table does not exist. Flyway has not run yet.
      if (err.code !== "42P01") throw err;
    }
    return { status: "ok", latencyMs, schemaVersion, ...target() };
  } catch (err) {
    return { status: "unreachable", error: err.message, ...target() };
  }
}

// Async so callers always get a rejected promise, never a synchronous throw.
async function query(text, params) {
  if (!pool) {
    const err = new Error("database not configured");
    err.code = "DB_NOT_CONFIGURED";
    throw err;
  }
  return pool.query(text, params);
}

async function close() {
  if (pool) await pool.end();
}

module.exports = { configured, query, status, close, target };
