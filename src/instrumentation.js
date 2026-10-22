// OpenTelemetry setup. Loaded first by server.js so instrumentation patches
// http and express before they are required.
//
// Everything vendor-specific lives in OTEL_* environment variables, not code.
// The app only knows "send OTLP somewhere". Locally that is an OpenTelemetry
// Collector that feeds Prometheus, Tempo, and Grafana. In Kubernetes it is still
// the Datadog Agent on the node until the Collector is deployed there. Moving
// from one to the other is a change to OTEL_EXPORTER_OTLP_ENDPOINT, not code.
//
// Key env vars (set in docker-compose.yml or the Kubernetes manifest):
//   OTEL_SERVICE_NAME              service name shown in the back-end
//   OTEL_EXPORTER_OTLP_ENDPOINT    e.g. http://$(HOST_IP):4318
//   OTEL_EXPORTER_OTLP_PROTOCOL    http/protobuf
//   OTEL_TRACES_EXPORTER           otlp
//   OTEL_METRICS_EXPORTER          otlp
//   OTEL_SDK_DISABLED              "true" turns all of this off (local runs)

if (process.env.OTEL_SDK_DISABLED === "true") {
  module.exports = {};
  return;
}

const { NodeSDK } = require("@opentelemetry/sdk-node");
const { resourceFromAttributes } = require("@opentelemetry/resources");
const { HttpInstrumentation } = require("@opentelemetry/instrumentation-http");
const { ExpressInstrumentation } = require("@opentelemetry/instrumentation-express");

// Version is baked into the image at build time (APP_VERSION).
// Environment comes from the ConfigMap (APP_ENV).
// These become the "version" and "env" labels in Grafana and Datadog.
const environment = (process.env.APP_ENV || "local").toLowerCase();
const resource = resourceFromAttributes({
  "service.version": process.env.APP_VERSION || "0.0.0-local",
  "deployment.environment.name": environment,
  "deployment.environment": environment, // older semconv name, still read by Datadog
  "vcs.ref.head.revision": process.env.APP_COMMIT_SHA || "unknown",
});

const sdk = new NodeSDK({
  resource,
  instrumentations: [
    new HttpInstrumentation({
      // Keep probe traffic out of traces. Probes still hit the server, they
      // just don't add noise to error rate and latency.
      ignoreIncomingRequestHook: (req) =>
        (req.headers["user-agent"] || "").startsWith("kube-probe"),
    }),
    new ExpressInstrumentation(),
  ],
});

sdk.start();

// Flush on shutdown so the last spans reach the agent.
for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    sdk.shutdown().finally(() => process.exit(0));
  });
}

module.exports = { sdk };
