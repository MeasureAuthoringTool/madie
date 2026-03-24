# MADiE Local Development Environment

**Measure Authoring Development Integrated Environment** — Scripts and configuration for running the full MADiE stack locally.

This project provides orchestration tooling to clone, configure, and run all ~25 MADiE repositories as a unified local development environment.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Project Structure](#project-structure)
- [Setup — Cloning Repositories](#setup--cloning-repositories)
- [Configuration](#configuration)
- [Running MADiE](#running-madie)
  - [Dev Mode (Hot Reload)](#dev-mode-hot-reload)
  - [Dist Mode (Pre-built Artifacts)](#dist-mode-pre-built-artifacts)
  - [Docker Mode](#docker-mode)
- [Stopping MADiE](#stopping-madie)
- [Monitoring & Logs](#monitoring--logs)
- [Port Reference](#port-reference)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| **Git** | Any recent | SSH access to the `MeasureAuthoringTool` GitHub org |
| **Node.js** | 18+ (20 recommended) | With npm; used by frontends, virus-scan, excel-export |
| **Java** | 17+ | Eclipse Temurin or equivalent |
| **Maven** | 3.8+ | `~/.m2/settings.xml` must include GitHub Packages credentials (see [Maven Auth](#maven-authentication)) |
| **Ruby** | 3.x + Bundler | Only needed for `qrda-export-service` in native mode |
| **Docker Desktop** | 4.x+ | Only needed for Docker mode; allocate ≥128 GB disk |
| **Bash** | 3.2+ | macOS default Bash is supported |

### Maven Authentication

Several Java services depend on `madie-java-models` hosted on GitHub Packages. Your `~/.m2/settings.xml` must include a server entry:

```xml
<settings>
  <servers>
    <server>
      <id>github</id>
      <username>YOUR_GITHUB_USERNAME</username>
      <password>YOUR_GITHUB_PAT</password>
    </server>
  </servers>
</settings>
```

Generate a [Personal Access Token](https://github.com/settings/tokens) with `read:packages` scope.

> **Docker mode** automatically mounts your `~/.m2/settings.xml` into Java containers, so the same credentials work in both native and Docker modes.

---

## Quick Start

```bash
# 1. Clone this orchestration repo
git clone git@github.com:MeasureAuthoringTool/madie.git
cd madie

# 2. Configure environment
cp .env.example .env
# Edit .env with your Okta, HARP, and VSAC credentials

# 3. Clone all MADiE repositories
./setup-madie.sh

# 4. Start everything in dev mode
./madie.sh start dev

# 5. (Optional) Follow aggregated logs
./madie.sh start dev -f
```

MADiE will be available at **http://localhost:9000** once all services are running.

---

## Project Structure

```
madie/
├── madie.sh              # CLI for starting, stopping, and managing services
├── setup-madie.sh        # Clone/update all MADiE repositories
├── docker-compose.yml    # Full Docker Compose stack (20 services)
├── .env.example          # Environment variable template
├── .env                  # Your local configuration (git-ignored)
├── data/
│   └── init-mongo.js     # MongoDB initialization script
├── frontends/            # Single-SPA micro-frontends (7 repos)
│   ├── madie-root/
│   ├── madie-layout/
│   ├── madie-auth/
│   ├── madie-editor/
│   ├── madie-measure/
│   ├── madie-cql-library/
│   └── madie-util/
├── services/             # Backend microservices (11 repos)
│   ├── measure-service/
│   ├── madie-fhir-service/
│   ├── terminology-service/
│   ├── cql-library-service/
│   ├── madie-qdm-service/
│   ├── madie-user-service/
│   ├── madie-fhir-elm-translator/
│   ├── madie-qdm-elm-translation/
│   ├── virus-scan-service/
│   ├── excel-export/
│   └── qrda-export-service/
├── standalone/           # Standalone utilities
│   └── support-data/     # Static JSON/CQL template files
├── libs/                 # Shared libraries (not run directly)
│   ├── madie-models/
│   ├── madie-design-system/
│   ├── madie-java-models/
│   ├── madie-rest-commons/
│   └── madie-translator-commons/
├── logs/                 # Service log files (git-ignored)
└── temp/                 # Temporary/reference files (git-ignored)
```

---

## Setup — Cloning Repositories

The `setup-madie.sh` script clones all repositories on first run, or updates them to the latest from their default branch on subsequent runs.

```bash
# Clone/update everything
./setup-madie.sh

# Clone/update only a specific group
./setup-madie.sh frontends
./setup-madie.sh services
./setup-madie.sh standalone
./setup-madie.sh libs
```

**Group aliases:** `frontend` / `fe`, `service` / `be` / `backend`, `lib` / `libraries`

### What it does

| Scenario | Behavior |
|----------|----------|
| **First run** | Clones each repo via SSH into its category folder |
| **Subsequent runs** | Fetches latest, auto-stashes local changes, checks out and pulls the default branch (`develop` for most, `main` for models/design-system) |

> Repos are cloned using SSH URLs (`git@github.com:MeasureAuthoringTool/...`). Ensure your SSH key is configured for the MeasureAuthoringTool organization.

---

## Configuration

Copy the example environment file and edit it with your credentials:

```bash
cp .env.example .env
```

### Required Configuration

These must be set for the backend services to function:

| Variable | Description |
|----------|-------------|
| `OKTA_ISSUER` | Your Okta OAuth2 issuer URL |
| `OKTA_CLIENT_ID` | Your Okta client ID |
| `VSAC_API_KEY` | VSAC API key for terminology operations |
| `HARP_CLIENT_ID` | HARP client ID (used by user-service) |
| `HARP_SECRET` | HARP client secret |

### Optional Configuration

Defaults are provided for all of these:

| Variable | Default | Description |
|----------|---------|-------------|
| `MONGO_PORT` | `27017` | MongoDB port |
| `MONGO_INITDB_ROOT_USERNAME` | `root` | MongoDB root username |
| `MONGO_INITDB_ROOT_PASSWORD` | `E5press0` | MongoDB root password |
| `MONGO_DB_NAME` | `madie` | MongoDB database name |
| `FORCE_VIRUS_SCAN` | `true` | Enable/disable virus scanning |
| `MAVEN_OPTS` | `-Xmx512m` | JVM options for Maven |

All service ports can be overridden (see [Port Reference](#port-reference)).

---

## Running MADiE

### Dev Mode (Hot Reload)

Starts frontends with webpack dev server and backend services with `mvn spring-boot:run`. Code changes are picked up automatically.

```bash
# Start everything
./madie.sh start dev

# Start everything and follow aggregated logs
./madie.sh start dev -f

# Start only frontends
./madie.sh start dev frontends

# Start only backend services
./madie.sh start dev services

# Start only standalone (support-data)
./madie.sh start dev standalone
```

> **Auto-install:** If a Node.js project is missing its `node_modules` directory, `npm install` runs automatically before starting.

### Dist Mode (Pre-built Artifacts)

Serves frontends from their `dist/` build output and runs backend services in production mode.

```bash
# Start everything from pre-built artifacts
./madie.sh start dist

# Start only services
./madie.sh start dist services
```

> You must build each project first (e.g., `npm run build` for frontends, `mvn package` for Java services).

### Docker Mode

Runs the entire stack in Docker containers. Source code is volume-mounted for hot-reload without image rebuilds.

```bash
# Bring up the full stack
./madie.sh start docker up

# Tear down containers and networks
./madie.sh start docker down
```

**What Docker mode provides:**
- MongoDB 6.0 with automatic initialization
- All 7 frontends (Node 20 Alpine)
- All 8 Java services (Maven 3 + Eclipse Temurin 17)
- 2 Node services (virus-scan, excel-export)
- 1 Ruby service (qrda-export, built from Dockerfile)
- 1 standalone static file server (support-data)
- Shared Maven cache volume (persists across rebuilds)
- FHIR profile cache volume
- Your `~/.m2/settings.xml` mounted read-only for GitHub Packages auth

**Rebuild a specific service:**

```bash
docker compose up -d --build <service-name>
```

**Fresh rebuild with clean dependencies:**

```bash
docker compose down -v                    # Remove all volumes
docker compose up -d --build              # Rebuild everything
```

---

## Stopping MADiE

### Graceful Stop (PID-based)

```bash
# Stop all services
./madie.sh stop

# Stop only a specific group
./madie.sh stop frontends
./madie.sh stop services
./madie.sh stop standalone
```

### Force Kill (Port-based)

If PIDs get out of sync (e.g., after a crash), use `kill` to find and terminate processes by their configured ports:

```bash
./madie.sh kill
```

This scans all known MADiE ports using `lsof`, kills any listeners, and cleans up the PID file.

---

## Monitoring & Logs

### Check Status

```bash
./madie.sh status
```

Displays a table of all tracked processes with their PID, port, group, and running status.

### View Logs

```bash
# Tail a single service log
./madie.sh logs madie-root
./madie.sh logs measure-service

# Tail all logs with color-coded service prefixes
./madie.sh logs --all

# Tail only logs for a specific group
./madie.sh logs --all frontends
./madie.sh logs --all services
```

### Follow Logs at Startup

Add `-f` to any start command to automatically tail aggregated logs after startup:

```bash
./madie.sh start dev -f
./madie.sh start dev frontends -f
```

### Docker Logs

```bash
docker compose logs -f                    # All services
docker compose logs -f measure-service    # Single service
```

---

## Port Reference

### Frontends

| Service | Port | Description |
|---------|------|-------------|
| madie-root | 9000 | Root single-spa config + serviceConfig.json |
| madie-layout | 8500 | Shell/layout micro-frontend |
| madie-editor | 8501 | CQL editor micro-frontend |
| madie-auth | 8502 | Authentication micro-frontend |
| madie-measure | 8505 | Measure management micro-frontend |
| madie-cql-library | 8507 | CQL library micro-frontend |
| madie-util | 8508 | Shared utilities micro-frontend |

### Java Services

| Service | Port | Description |
|---------|------|-------------|
| measure-service | 8080 | Core measure CRUD and orchestration |
| terminology-service | 8081 | VSAC terminology operations |
| cql-library-service | 8082 | CQL library management |
| madie-fhir-elm-translator | 8083 | FHIR CQL→ELM translation |
| madie-qdm-elm-translation | 8084 | QDM CQL→ELM translation |
| madie-fhir-service | 8085 | FHIR validation and operations |
| madie-qdm-service | 8086 | QDM measure operations |
| madie-user-service | 8088 | User management and HARP integration |

### Node / Ruby Services

| Service | Port | Description |
|---------|------|-------------|
| excel-export | 3000 | Measure export to Excel |
| virus-scan-service | 5000 | File virus scanning |
| qrda-export-service | 8089 | QRDA export (Ruby/Nginx) |

### Standalone / Infrastructure

| Service | Port | Description |
|---------|------|-------------|
| support-data | 8660 | Static CQL templates and config JSON |
| mongodb | 27017 | MongoDB 6.0 database |

---

## Troubleshooting

### `declare -A: invalid option`

You're running macOS default Bash 3.2. The scripts are written to be compatible — ensure you're using the latest versions of `setup-madie.sh` and `madie.sh` from this repo.

### `No space left on device` (Docker)

Docker's virtual disk is full. Clean up and increase the limit:

```bash
docker system prune -a --volumes
```

Also increase disk allocation: **Docker Desktop → Settings → Resources → Disk image size → 128 GB+**

### `pull access denied` for a service image

A service is trying to pull a non-existent remote image. All MADiE services should build locally. Check that the service in `docker-compose.yml` uses `build:` without an `image:` directive.

### Maven `Unauthorized` / can't pull `madie-java-models`

Your `~/.m2/settings.xml` is missing GitHub Packages credentials. See [Maven Authentication](#maven-authentication).

### `Connection refused` to `serviceConfig.json`

The `madie-root` frontend hasn't finished starting. In Docker mode, services that need `serviceConfig.json` depend on `madie-root`'s healthcheck. In native mode, ensure frontends are started before or alongside services.

### Stale node_modules in Docker

If a frontend has dependency errors after updating:

```bash
docker compose rm -sf <service-name>
docker compose up -d --build --renew-anon-volumes <service-name>
```

### Processes still running after `stop`

Use `kill` to force-terminate by port:

```bash
./madie.sh kill
```

### MongoDB connection refused

Ensure MongoDB is running. In native mode, you need a local MongoDB instance on port 27017. In Docker mode, it starts automatically via `docker compose`.

---

## CLI Reference

```
./madie.sh <command> [options]

Commands:
  start dev    [group] [-f]   Start in dev mode (hot-reload)
  start dist   [group] [-f]   Start from pre-built artifacts
  start docker [up|down]      Manage the Docker Compose stack
  stop   [group]              Stop running processes (PID-based)
  kill                        Kill all processes on MADiE ports
  status                      Show running processes
  logs   <name>               Tail a single service log
  logs   --all [group]        Tail all logs (color-coded)
  help   [topic]              Detailed help (start|stop|kill|logs|docker)

Groups: all (default), frontends, services, standalone
```

For detailed help on any command:

```bash
./madie.sh help           # Full quick reference
./madie.sh help start     # Start examples
./madie.sh help stop      # Stop examples
./madie.sh help kill      # Kill examples
./madie.sh help logs      # Log viewing examples
./madie.sh help docker    # Docker mode examples
```
