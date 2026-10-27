# Server deployment

This page describes the Linux server path. It deploys the same app as the container path. It uses a package instead of an image.

## How the two paths differ

| | Container path | Server path |
| --- | --- | --- |
| Build workflow | `build-image.yml` | `build-package.yml` |
| Artifact | Image in GHCR | Zip `developmentloop-app` on the Octopus built-in feed |
| Version line | `1.0.<run>` | `1.1.<run>` |
| SBOM | Filesystem scan of the repository | Scan of the folder inside the zip |
| Runtime | In the image | On the server |
| Deploy target | Kubernetes agent | Linux Tentacle with role `app-server` |
| Octopus project | `PT - Raw YAML`, `PT - Kustomize`, `PT - Helm` | `PT - Linux Package` |

Both paths share the database steps. The same roles, migrations, and lock step run on both.

## What the package holds

- `server.js`, `db.js`, `instrumentation.js`, and `package.json`
- Production `node_modules`
- `build.env` with the version, branch, build number, time, and commit
- `developmentloop.env` with `#{...}` tokens that Octopus replaces
- `PostDeploy.sh` that Octopus runs after extraction
- `service.sh` that starts, stops, and checks the app without systemd
- `developmentloop.service` as the systemd unit for a real server

## What the deployment does

1. Notifies Slack.
2. Verifies the database is ready.
3. Runs the Flyway migrations.
4. Locks the Flyway history table against writes by the app login.
5. Checks the Node.js runtime on the target.
6. Extracts the package and replaces the env file values.
7. Runs `PostDeploy.sh`. The script restarts the app and waits for `/health`.
8. Notifies Slack with the app URL.

Steps 5 to 7 live in the process template `linux-deploy-package`. Step 7 lives in the package. The app owns how it restarts. The template stays generic.

## Local app servers

The `local-workloads` stack runs three Linux Tentacles with Node.js. Each registers as its own deployment target in one environment.

| Container | Environment | App on the Mac |
| --- | --- | --- |
| `octopus-app-server-development` | Development | `http://localhost:3101` |
| `octopus-app-server-test` | Test | `http://localhost:3102` |
| `octopus-app-server-production` | Production | `http://localhost:3103` |

The containers have no systemd. `service.sh` stands in. On a real server, install `developmentloop.service` once. `PostDeploy.sh` then restarts the unit.

After a container restart the app is not running. Redeploy the release or run `docker exec <container> bash /opt/developmentloop/current/service.sh start`.

## The runtime is not in the package

The SBOM lists the app dependencies in the zip. The Node.js runtime belongs to the server. A runtime security fix is a host patch. The template parameter `LinuxPackage.MinimumNodeVersion` fails the deployment when a server runs an older version. Raise the value when a runtime fix ships.

## Verify the supply chain

```bash
gh attestation verify developmentloop-app.<version>.zip --repo creid-octopus/development-loop
gh attestation verify developmentloop-app-sbom.<version>.zip --repo creid-octopus/development-loop
```

Download the zips from the Octopus built-in feed first. The command needs GitHub API access. A server without it can use `cosign verify-blob` in a later change.

## Ports and state

- The app listens on port 3000 inside each container.
- The pid file and log live in `/var/lib/developmentloop`. Octopus clears the install folder on every deployment. The state folder survives that.
- The env file holds the database password. `PostDeploy.sh` sets its mode to 600.
