# AGENTS.md — MADiE Dev Environment Orchestration

This repository orchestrates ~25 repos across the MADiE (Measure Authoring Development Integrated Environment) project. It contains shell scripts, Docker Compose configuration, and environment templates — no application source code lives here directly.

## Repository Layout

```
madie.sh              # Main CLI — start, stop, kill, status, logs, help
setup-madie.sh        # Clone/update all MADiE repos
docker-compose.yml    # Full Docker stack (20 containers)
.env.example          # Environment variable template → copy to .env
data/init-mongo.js    # MongoDB initialization (users, permissions, seeding initial organizations)
frontends/            # 7 single-spa micro-frontend repos (cloned here)
services/             # 11 backend microservice repos (cloned here)
standalone/           # Static file server repos (cloned here)
libs/                 # Shared library repos (cloned here, not run)
logs/                 # Runtime log files (gitignored)
```

The subdirectories (`frontends/`, `services/`, `standalone/`, `libs/`) contain cloned git repos — each is its own project. This orchestration repo only tracks the top-level scripts and config via a whitelist-based `.gitignore`.

---

## Planning Documents

All implementation plans must be stored in the root `plans/` directory. Do not place plans in
individual service repositories or external session directories. Use a descriptive kebab-case
filename, such as `plans/proposed-structured-include-parsing-refactor.md`.

The `plans/` directory is intentionally gitignored; plans are local project artifacts unless a user
explicitly requests that a plan be committed.

---

## CLI Reference — madie.sh

All runtime operations go through `./madie.sh`:

```bash
# Start services
./madie.sh start dev                # Dev mode — webpack + spring-boot:run (hot reload)
./madie.sh start dev frontends      # Only frontends
./madie.sh start dev services       # Only backend services
./madie.sh start dev -f             # Start + follow aggregated logs
./madie.sh start dist               # Serve from pre-built artifacts
./madie.sh start docker up          # Full Docker Compose stack
./madie.sh start docker down        # Tear down Docker stack

# Stop services
./madie.sh stop                     # Graceful stop (PID-based + port fallback)
./madie.sh stop frontends           # Stop only a group
./madie.sh kill                     # Force-kill by port (when PIDs are stale)

# Monitor
./madie.sh status                   # Show PID/port/status table
./madie.sh logs madie-root          # Tail single service log
./madie.sh logs --all               # Tail all logs, color-coded
./madie.sh logs --all services      # Tail only a group

# Help
./madie.sh help                     # Quick reference with examples
./madie.sh help start               # Detailed help per topic
```

**Groups:** `all` (default), `frontends` (aliases: `frontend`, `fe`), `services` (aliases: `service`, `be`), `standalone`

---

## Docker Compose

```bash
# Via the CLI (preferred — loads .env correctly):
./madie.sh start docker up
./madie.sh start docker down

# Direct docker compose commands:
docker compose up -d --build                           # Start all
docker compose up -d --build <service>                 # Rebuild one service
docker compose down -v                                 # Tear down + remove volumes
docker compose logs -f <service>                       # Follow one service
docker compose rm -sf <svc> && docker compose up -d --build --renew-anon-volumes <svc>  # Clean rebuild
```

The compose file uses YAML anchors for DRY config:
- `x-java-base` / `&java-base` — Maven 3 + Eclipse Temurin 17 base
- `x-java-common-env` / `&java-common-env` — Okta, Maven opts, Spring DevTools
- `x-mongo-spring-env` / `&mongo-spring-env` — MongoDB URI
- `x-node-service` / `&node-service` — Node 20 Alpine base with polling enabled

Services merge these via `<<: [*java-common-env, *mongo-spring-env]` then add service-specific vars.

---

## Bash Compatibility — CRITICAL

Scripts must work on **macOS Bash 3.2**. This means:

- **NO** `declare -A` (associative arrays) — use indexed arrays with `"key:value"` strings
- **NO** `local -n` (namerefs)
- **NO** `${var@P}` or other Bash 4+ parameter transforms
- Parse pairs via `${entry%%:*}` (before colon) and `${entry##*:}` (after colon)
- `set -eo pipefail` (not `-u` in setup-madie.sh — causes unbound var errors on Bash 3)
- `madie.sh` uses `set -euo pipefail` but all variables have `${VAR:-default}` guards

---

## Adding a New Service

When a new repo is added to the MADiE project, update these files:

### 1. setup-madie.sh — Add to repo array

Add an entry to the appropriate array (`FRONTENDS`, `SERVICES`, `STANDALONE`, or `LIBS`):

```bash
SERVICES=(
  ...
  "new-service:develop"    # format: "repo-name:default-branch"
)
```

### 2. .env.example — Add port variable

Follow the naming convention `<SERVICE_NAME>_PORT`:

```
NEW_SERVICE_PORT=8090
```

### 3. madie.sh — Four locations

**a) `export_service_urls()`** — Add inter-service URL if other services call it:
```bash
export NEW_SERVICE_URL="http://${host}:${NEW_SERVICE_PORT:-8090}/api"
```

**b) `start_services_dev()`** — Add start_process call:
```bash
start_process "new-service" "$BASE_DIR/services/new-service" \
  "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${NEW_SERVICE_PORT:-8090}" \
  "${NEW_SERVICE_PORT:-8090}" "services"
```

**c) `start_services_dist()`** — Same pattern as dev (or adjusted command).

**d) `kill_by_ports()`** — Add to the ports array:
```bash
"${NEW_SERVICE_PORT:-8090}:new-service"
```

### 4. docker-compose.yml — Add service definition

Use the appropriate anchor. Example for a Java service:

```yaml
new-service:
  <<: *java-base
  container_name: madie-new-service
  ports:
    - "${NEW_SERVICE_PORT:-8090}:${NEW_SERVICE_PORT:-8090}"
  volumes:
    - ./services/new-service:/app
    - maven-repo:/root/.m2
    - ~/.m2/settings.xml:/root/.m2/settings.xml:ro
  depends_on:
    mongodb:
      condition: service_healthy
  environment:
    <<: [*java-common-env, *mongo-spring-env]
  command: mvn spring-boot:run -Dspring-boot.run.arguments=--server.port=${NEW_SERVICE_PORT:-8090}
```

For Node services, use `<<: *node-service` and add an anonymous `node_modules` volume.

### 5. .gitignore — No change needed

The whitelist-based `.gitignore` ignores everything by default, so new cloned repos are automatically excluded.

---

## Environment Variable Flow

Variables cascade through three layers with consistent defaults:

```
.env (user config, gitignored)
  ↓ fallback
.env.example (committed defaults)
  ↓ fallback
inline defaults in scripts: ${VAR:-default}
```

Port variable naming:
- Frontends: `MADIE_<NAME>_PORT` (e.g., `MADIE_ROOT_PORT=9000`)
- Java services: `<SERVICE>_PORT` or `MADIE_<SERVICE>_PORT`
- Node/Ruby: `<SERVICE>_PORT` (e.g., `VIRUS_SCAN_SERVICE_PORT=5000`)

The same variable is referenced in `.env.example`, `madie.sh`, and `docker-compose.yml`.

---

## Port Allocations

| Range | Usage |
|-------|-------|
| 9000 | madie-root (main entry point + serviceConfig.json) |
| 8500–8508 | Frontend micro-frontends |
| 8080–8089 | Java microservices |
| 8660 | support-data (static files) |
| 5000 | virus-scan-service |
| 3000 | excel-export |
| 27017 | MongoDB |

---

## Key Implementation Details

**Process management:** `madie.sh` tracks PIDs in `.madie.pids` (format: `PID NAME PORT GROUP`). The `stop` command kills the process tree (recursive child kill via `kill_tree()`), then falls back to `lsof`-based port scanning. The `kill` command skips PIDs entirely and goes straight to port-based termination.

**npm auto-install:** `start_process()` checks for `package.json` without `node_modules` and runs `npm install` automatically before starting Node projects.

**Docker Maven auth:** Each Java container mounts `~/.m2/settings.xml:ro` for GitHub Packages access. The `maven-repo` named volume persists the `.m2` cache across rebuilds.

**serviceConfig.json:** Served by `madie-root` on port 9000, not `support-data`. Services that need it (`measure-service`, `madie-fhir-service`) depend on `madie-root`'s healthcheck.

**support-data:** Serves the `madie/` subdirectory as root, so URLs are `http://localhost:8660/code-system-entry.json` (not `/madie/code-system-entry.json`).

**Logging helpers:** Use `info()`, `success()`, `warn()`, `error()` for consistent colored output. Log files go to `logs/<service-name>.log`.

---

## What NOT to Modify

- **Cloned repos** (`frontends/`, `services/`, `libs/`, `standalone/`) — these are separate git repos. Make changes in their own repositories.
- **`.env`** — gitignored, contains user secrets. Edit `.env.example` for new defaults.
- **`data/`** — only `init-mongo.js` is tracked. Everything else is Docker volume data.
- **`temp/`** — reference files, not part of the project.
