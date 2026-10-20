// OpenTelemetry must load before express and http are required.
require("./instrumentation");

const express = require("express");
const fs = require("fs");
const path = require("path");
const { trace, SpanStatusCode } = require("@opentelemetry/api");
const db = require("./db");
const app = express();
const port = process.env.PORT || 3000;

app.use(express.json());

// Marks the active span as failed. The HTTP instrumentation does this for 5xx
// responses it sees. Doing it here as well makes the error rate in the back-end
// match what the app returns, even when a response is sent from middleware.
function markSpanError(message) {
  const span = trace.getActiveSpan();
  if (!span) return;
  span.setStatus({ code: SpanStatusCode.ERROR, message });
}

// Read the .build-env file stamped by the CI "Write build metadata" step into a
// plain object. Returns an empty object locally (file won't exist in dev).
// Keys are: APP_VERSION, APP_BRANCH, APP_BUILD, APP_BUILT_AT, APP_COMMIT_SHA.
function readBuildEnv() {
  const envPath = path.join(__dirname, ".build-env");
  if (!fs.existsSync(envPath)) return {};
  const result = {};
  for (const line of fs.readFileSync(envPath, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq === -1) continue;
    result[trimmed.slice(0, eq).trim()] = trimmed.slice(eq + 1).trim();
  }
  return result;
}

// Build-time values — read from .build-env file (zip/Azure deployment) or from
// ENV vars baked in at image build time (container deployment). Falls through to
// hardcoded local defaults when neither is present.
//
// Precedence: .build-env file > process.env (Docker ENV) > local default
const buildEnv = readBuildEnv();
const buildInfo = {
  version:     buildEnv.APP_VERSION     || process.env.APP_VERSION     || "0.0.0-local",
  environment: process.env.APP_ENV      || "local",
  branch:      buildEnv.APP_BRANCH      || process.env.APP_BRANCH      || "unknown",
  buildNumber: buildEnv.APP_BUILD       || process.env.APP_BUILD       || "local",
  builtAt:     buildEnv.APP_BUILT_AT    || process.env.APP_BUILT_AT    || new Date().toISOString(),
  commitSha:   buildEnv.APP_COMMIT_SHA  || process.env.APP_COMMIT_SHA  || "unknown",
};

// Env → banner colour mapping (makes it obvious what you're looking at)
const envColours = {
  prod:           "#1a7f37",   // green
  "test-feature": "#b45309",   // amber
  test:           "#1d4ed8",   // blue
  staging:        "#7c3aed",   // purple
  local:          "#374151",   // grey
};

function bannerColour(env) {
  for (const [key, colour] of Object.entries(envColours)) {
    if (env.toLowerCase().includes(key)) return colour;
  }
  return "#374151";
}

// ── Failure simulation ────────────────────────────────────────────────────
// Lets a demo trigger real, observable failures on demand.
// Kept off /health so probes never trip them by accident.
//
//   /simulate/errors?rate=0.5   for the next N minutes, return 500 on that
//                               share of requests to / (default 0.5, 5 min)
//   /simulate/latency?ms=1500   for the next N minutes, add delay to /
//   /simulate/reset             clear both
//   /simulate/degraded          /health returns 503 (readiness probe fails)
//   /simulate/crash             process exits (liveness and restart)
//   /simulate/oom               allocate memory until the container is OOMKilled
//
// All accept ?minutes=N where it applies.
const sim = { errorRate: 0, latencyMs: 0, until: 0, degraded: false };

function simActive() {
  if (Date.now() > sim.until) { sim.errorRate = 0; sim.latencyMs = 0; }
  return sim;
}
function minutes(req, fallback = 5) {
  const m = Number(req.query.minutes);
  return (Number.isFinite(m) && m > 0 ? m : fallback) * 60_000;
}

// Applied to the main page only, so the demo signal is clean.
app.use("/", (req, res, next) => {
  if (req.path !== "/") return next();
  const s = simActive();
  const go = () => {
    if (s.errorRate > 0 && Math.random() < s.errorRate) {
      markSpanError("Simulated failure");
      return res.status(500).send("Simulated failure");
    }
    next();
  };
  s.latencyMs > 0 ? setTimeout(go, s.latencyMs) : go();
});

app.get("/simulate/errors", (req, res) => {
  const rate = Number(req.query.rate);
  sim.errorRate = Number.isFinite(rate) && rate >= 0 && rate <= 1 ? rate : 0.5;
  sim.until = Date.now() + minutes(req);
  res.json({ simulating: "errors", rate: sim.errorRate, until: new Date(sim.until) });
});

app.get("/simulate/latency", (req, res) => {
  const ms = Number(req.query.ms);
  sim.latencyMs = Number.isFinite(ms) && ms > 0 ? ms : 1500;
  sim.until = Date.now() + minutes(req);
  res.json({ simulating: "latency", ms: sim.latencyMs, until: new Date(sim.until) });
});

app.get("/simulate/reset", (req, res) => {
  Object.assign(sim, { errorRate: 0, latencyMs: 0, until: 0, degraded: false });
  res.json({ simulating: "nothing" });
});

app.get("/simulate/degraded", (req, res) => {
  sim.degraded = true;
  res.json({ simulating: "degraded", note: "/health now returns 503 until /simulate/reset" });
});

app.get("/simulate/crash", (req, res) => {
  res.json({ simulating: "crash" });
  setTimeout(() => process.exit(1), 100);
});

app.get("/simulate/oom", (req, res) => {
  res.json({ simulating: "oom" });
  const hog = [];
  setInterval(() => hog.push(Buffer.alloc(50 * 1024 * 1024, 1)), 200);
});

app.get("/", (req, res) => {
  const colour = bannerColour(buildInfo.environment);
  res.setHeader("Content-Type", "text/html");
  res.send(`<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>developmentloop · ${buildInfo.environment}</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: system-ui, sans-serif; background: #f9fafb; color: #111827; }

    .banner {
      background: ${colour};
      color: #fff;
      padding: 1.25rem 2rem;
      display: flex;
      align-items: center;
      gap: 1rem;
    }
    .banner h1 { font-size: 1.4rem; font-weight: 700; letter-spacing: -0.5px; }
    .banner .env-badge {
      background: rgba(255,255,255,0.2);
      border-radius: 999px;
      padding: 0.25rem 0.75rem;
      font-size: 0.8rem;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
    }

    .container { max-width: 680px; margin: 2.5rem auto; padding: 0 1.5rem; }

    .card {
      background: #fff;
      border: 1px solid #e5e7eb;
      border-radius: 10px;
      padding: 1.5rem 2rem;
      margin-bottom: 1.25rem;
    }
    .card h2 { font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.08em; color: #6b7280; margin-bottom: 1rem; }

    table { width: 100%; border-collapse: collapse; }
    td { padding: 0.5rem 0; font-size: 0.9rem; vertical-align: top; }
    td:first-child { color: #6b7280; width: 40%; }
    td:last-child  { font-weight: 500; font-family: ui-monospace, monospace; font-size: 0.85rem; word-break: break-all; }

    .version-big {
      font-size: 2.5rem;
      font-weight: 800;
      color: ${colour};
      letter-spacing: -1px;
    }
    .version-sub { color: #6b7280; font-size: 0.85rem; margin-top: 0.25rem; }
  </style>
</head>
<body>
  <div class="banner">
    <h1>developmentloop demo</h1>
    <span class="env-badge">${buildInfo.environment}</span>
  </div>

  <div class="container">
    <div class="card">
      <div class="version-big">v${buildInfo.version}</div>
      <div class="version-sub">build #${buildInfo.buildNumber}</div>
    </div>

    <div class="card">
      <h2>Deployment details</h2>
      <table>
        <tr><td>Environment</td><td>${buildInfo.environment}</td></tr>
        <tr><td>Branch</td><td>${buildInfo.branch}</td></tr>
        <tr><td>Commit</td><td>${buildInfo.commitSha}</td></tr>
        <tr><td>Built at</td><td>${buildInfo.builtAt}</td></tr>
        <tr><td>Build #</td><td>${buildInfo.buildNumber}</td></tr>
      </table>
    </div>
  </div>
</body>
</html>`);
});

// ── Items API ─────────────────────────────────────────────────────────────
// A small table-backed API. It exists so there is a real schema to migrate,
// roll forward, and roll back. The table comes from db/migrations.
function dbError(res, err) {
  markSpanError(err.message);
  if (err.code === "DB_NOT_CONFIGURED") {
    return res.status(503).json({ error: "database not configured" });
  }
  // 42P01: table missing. Flyway has not run, or the app is newer than the schema.
  if (err.code === "42P01" || err.code === "42703") {
    return res.status(500).json({ error: "schema does not match the app", detail: err.message });
  }
  return res.status(500).json({ error: "database error", detail: err.message });
}

app.get("/api/items", async (req, res) => {
  try {
    const { rows } = await db.query("SELECT id, name, created_at FROM items ORDER BY id");
    res.json(rows);
  } catch (err) {
    dbError(res, err);
  }
});

app.post("/api/items", async (req, res) => {
  const name = typeof req.body?.name === "string" ? req.body.name.trim() : "";
  if (!name) return res.status(400).json({ error: "name is required" });
  try {
    const { rows } = await db.query(
      "INSERT INTO items (name) VALUES ($1) RETURNING id, name, created_at",
      [name]
    );
    res.status(201).json(rows[0]);
  } catch (err) {
    dbError(res, err);
  }
});

// Health check endpoint (used by Kubernetes probes and Octopus health checks).
// The database is reported but never fails this endpoint. A database outage
// must not make Kubernetes restart healthy pods. Use /health/db for readiness.
app.get("/health", async (req, res) => {
  const database = await db.status();
  if (sim.degraded) return res.status(503).json({ status: "degraded", ...buildInfo, database });
  res.json({ status: "ok", ...buildInfo, database });
});

// Readiness that includes the database. Returns 503 when a configured
// database is unreachable. An unconfigured database is not a failure.
app.get("/health/db", async (req, res) => {
  const database = await db.status();
  const failed = database.status === "unreachable";
  if (failed) markSpanError("database unreachable");
  res.status(failed ? 503 : 200).json(database);
});

const server = app.listen(port, () => {
  const t = db.target();
  console.log(`developmentloop-demo listening on port ${port} — env: ${buildInfo.environment}`);
  console.log(
    t ? `database: ${t.user}@${t.host}:${t.port}/${t.database}` : "database: not configured (set DATABASE_URL or PGHOST)"
  );
});

module.exports = { app, server };
