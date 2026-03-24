#!/usr/bin/env bash
#
# madie.sh — MADiE local development CLI
#
# Usage:
#   ./madie.sh start <mode> [group] [-f]  Start services
#   ./madie.sh stop  [group]              Stop running services
#   ./madie.sh status                     Show status of all tracked processes
#   ./madie.sh logs  <name|--all>         Tail logs for one or all services
#
# Start modes: dev, dist, docker
# Groups:      all (default), frontends, services, standalone
#
# Prerequisites:
#   - Copy .env.example to .env and configure
#   - Run ./setup-madie.sh first to clone all repos
#   - Node.js, npm, Java 17+, Maven, Ruby (for qrda-export-service)

set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$BASE_DIR/.madie.pids"
LOGS_DIR="$BASE_DIR/logs"
ENV_FILE="$BASE_DIR/.env"
FOLLOW_LOGS=false

# ─── Colors & helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}   $*"; }

# ─── Load .env ────────────────────────────────────────────────────────────────
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
else
  warn ".env file not found — using defaults from .env.example"
  if [ -f "$BASE_DIR/.env.example" ]; then
    set -a
    source "$BASE_DIR/.env.example"
    set +a
  else
    error "No .env or .env.example found. Run: cp .env.example .env"
    exit 1
  fi
fi

# ─── Inter-service environment variables (native mode uses localhost) ─────────

export_service_urls() {
  local host="localhost"

  # Inter-service URLs
  export QDM_ELM_TRANSLATOR_SERVICE_URL="http://${host}:${MADIE_QDM_ELM_TRANSLATION_PORT:-8084}/api/qdm"
  export FHIR_ELM_TRANSLATOR_SERVICE_URL="http://${host}:${MADIE_FHIR_ELM_TRANSLATOR_PORT:-8083}/api/fhir"
  export FHIR_SERVICES_URL="http://${host}:${MADIE_FHIR_SERVICE_PORT:-8085}/api"
  export VIRUS_SCAN_SERVICE_URL="http://${host}:${VIRUS_SCAN_SERVICE_PORT:-5000}"
  export TERMINOLOGY_SERVICE_URL="http://${host}:${TERMINOLOGY_SERVICE_PORT:-8081}/api"
  export SERVICE_CONFIG_JSON_URL="http://${host}:${MADIE_ROOT_PORT:-9000}/env-config/serviceConfig.json"
  export QDM_SERVICE_URL="http://${host}:${MADIE_QDM_SERVICE_PORT:-8086}/api"
  export CQL_LIBRARY_SERVICE_URL="http://${host}:${CQL_LIBRARY_SERVICE_PORT:-8082}/api"
  export QRDA_SERVICE_URL="http://${host}:${QRDA_EXPORT_SERVICE_PORT:-8089}/api"
  export CODE_SYSTEM_ENTRY_URL="http://${host}:${SUPPORT_DATA_PORT:-8660}/code-system-entry.json"

  # CQL Template URLs (served by support-data)
  export CQL_TEMPLATE_QICORE411_URL="http://${host}:${SUPPORT_DATA_PORT:-8660}/QICore411_CQLTemplate.txt"
  export CQL_TEMPLATE_QICORE600_URL="http://${host}:${SUPPORT_DATA_PORT:-8660}/QICore600_CQLTemplate.txt"
  export CQL_TEMPLATE_QDM56_URL="http://${host}:${SUPPORT_DATA_PORT:-8660}/QDM56_CQLTemplate.txt"

  # Feature flags
  export FORCE_VIRUS_SCAN="${FORCE_VIRUS_SCAN:-true}"

  # VSAC
  export VSAC_API_KEY="${VSAC_API_KEY:-your-vsac-api-key}"

  # HARP (user-service)
  export HARP_CLIENT_ID="${HARP_CLIENT_ID:-your-harp-client-id}"
  export HARP_LOCAL_OVERRIDE_ID="${HARP_LOCAL_OVERRIDE_ID:-}"
  export HARP_SECRET="${HARP_SECRET:-your-harp-secret}"

  # MongoDB (for services that use individual MONGO_* vars)
  export MONGO_DBUSER="${MONGO_INITDB_ROOT_USERNAME:-root}"
  export MONGO_DBPASS="${MONGO_INITDB_ROOT_PASSWORD:-E5press0}"
  export MONGO_HOST="localhost:${MONGO_PORT:-27017}"
  export MONGO_DATABASE="${MONGO_DB_NAME:-madie}"
  export MONGO_OPTIONS="${MONGO_OPTIONS:-?authSource=admin&maxPoolSize=50&connectTimeoutMS=2000&serverSelectionTimeoutMS=2000}"

  # Spring Data MongoDB URI (native/localhost)
  export SPRING_DATA_MONGODB_URI="mongodb://${MONGO_INITDB_ROOT_USERNAME:-root}:${MONGO_INITDB_ROOT_PASSWORD:-E5press0}@localhost:${MONGO_PORT:-27017}/${MONGO_DB_NAME:-madie}?authSource=admin"

  # Okta (for excel-export and other Node services)
  export ISSUER="${OKTA_ISSUER:-https://your-org.okta.com/oauth2/default}"
  export CLIENT_ID="${OKTA_CLIENT_ID:-your-client-id}"
}

# ─── Process management ──────────────────────────────────────────────────────

# ─── Process tree helper ──────────────────────────────────────────────────────
# Kill a process and all its descendants (children, grandchildren, etc.)
kill_tree() {
  local pid=$1
  local sig="${2:-TERM}"

  # Find child processes
  local children
  children=$(ps -ax -o pid=,ppid= | awk -v ppid="$pid" '$2 == ppid {print $1}')

  for child in $children; do
    kill_tree "$child" "$sig"
  done

  kill -"$sig" "$pid" 2>/dev/null || true
}

start_process() {
  local name="$1"
  local dir="$2"
  local cmd="$3"
  local port="$4"
  local group="$5"

  if [ ! -d "$dir" ]; then
    warn "Directory not found for $name: $dir — skipping (run setup-madie.sh first)"
    return
  fi

  # Auto-install node_modules if a package.json exists but node_modules is missing
  if [ -f "$dir/package.json" ] && [ ! -d "$dir/node_modules" ]; then
    info "Installing dependencies for $name (node_modules not found)..."
    if (cd "$dir" && npm install --no-audit --no-fund --loglevel=error); then
      success "Dependencies installed for $name"
    else
      error "npm install failed for $name — skipping"
      return
    fi
  fi

  mkdir -p "$LOGS_DIR"
  local logfile="$LOGS_DIR/${name}.log"

  # Check if already running
  if grep -q " ${name} " "$PID_FILE" 2>/dev/null; then
    local existing_pid
    existing_pid=$(grep " ${name} " "$PID_FILE" | awk '{print $1}')
    if kill -0 "$existing_pid" 2>/dev/null; then
      warn "$name is already running (PID: $existing_pid) — skipping"
      return
    fi
    # Stale entry, remove it
    sed -i.bak "/ ${name} /d" "$PID_FILE" 2>/dev/null || true
  fi

  echo -e "${DIM}$(date '+%Y-%m-%d %H:%M:%S') — Starting $name${NC}" > "$logfile"
  nohup bash -c "cd '$dir' && exec $cmd" >> "$logfile" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true

  echo "$pid $name $port $group" >> "$PID_FILE"
  success "Started ${BOLD}$name${NC}  →  port ${BOLD}$port${NC}  (PID: $pid, log: logs/${name}.log)"
}

stop_processes() {
  local filter_group="${1:-all}"

  if [ ! -f "$PID_FILE" ]; then
    warn "No running processes found (no PID file)"
    return
  fi

  local tmpfile
  tmpfile=$(mktemp)

  while read -r pid name port group; do
    [ -z "$pid" ] && continue
    if [ "$filter_group" != "all" ] && [ "$group" != "$filter_group" ]; then
      echo "$pid $name $port $group" >> "$tmpfile"
      continue
    fi

    local killed=false

    # Try killing the tracked PID and its entire process tree
    if kill -0 "$pid" 2>/dev/null; then
      kill_tree "$pid" TERM
      sleep 0.5
      if kill -0 "$pid" 2>/dev/null; then
        kill_tree "$pid" 9
        sleep 0.3
      fi
      killed=true
    fi

    # Fallback: also kill anything still listening on the port
    if [ -n "$port" ]; then
      local port_pids
      port_pids=$(lsof -ti :"$port" 2>/dev/null || true)
      if [ -n "$port_pids" ]; then
        for ppid in $port_pids; do
          kill_tree "$ppid" TERM 2>/dev/null
        done
        sleep 0.3
        # Force kill any survivors
        port_pids=$(lsof -ti :"$port" 2>/dev/null || true)
        if [ -n "$port_pids" ]; then
          for ppid in $port_pids; do
            kill_tree "$ppid" 9 2>/dev/null
          done
        fi
        killed=true
      fi
    fi

    if [ "$killed" = true ]; then
      success "Stopped $name (port $port)"
    else
      info "$name was not running"
    fi
  done < "$PID_FILE"

  if [ -s "$tmpfile" ]; then
    mv "$tmpfile" "$PID_FILE"
  else
    rm -f "$PID_FILE" "$tmpfile"
  fi
}

# Kill processes by scanning all known MADiE ports via lsof
kill_by_ports() {
  # All known port:name pairs
  local ports=(
    "${MADIE_ROOT_PORT:-9000}:madie-root"
    "${MADIE_LAYOUT_PORT:-8500}:madie-layout"
    "${MADIE_AUTH_PORT:-8502}:madie-auth"
    "${MADIE_EDITOR_PORT:-8501}:madie-editor"
    "${MADIE_MEASURE_PORT:-8505}:madie-measure"
    "${MADIE_CQL_LIBRARY_PORT:-8507}:madie-cql-library"
    "${MADIE_UTIL_PORT:-8508}:madie-util"
    "${MEASURE_SERVICE_PORT:-8080}:measure-service"
    "${TERMINOLOGY_SERVICE_PORT:-8081}:terminology-service"
    "${CQL_LIBRARY_SERVICE_PORT:-8082}:cql-library-service"
    "${MADIE_FHIR_ELM_TRANSLATOR_PORT:-8083}:madie-fhir-elm-translator"
    "${MADIE_QDM_ELM_TRANSLATION_PORT:-8084}:madie-qdm-elm-translation"
    "${MADIE_FHIR_SERVICE_PORT:-8085}:madie-fhir-service"
    "${MADIE_QDM_SERVICE_PORT:-8086}:madie-qdm-service"
    "${MADIE_USER_SERVICE_PORT:-8088}:madie-user-service"
    "${QRDA_EXPORT_SERVICE_PORT:-8089}:qrda-export-service"
    "${VIRUS_SCAN_SERVICE_PORT:-5000}:virus-scan-service"
    "${EXCEL_EXPORT_PORT:-3000}:excel-export"
    "${SUPPORT_DATA_PORT:-8660}:support-data"
  )

  local killed=0
  local skipped=0

  for entry in "${ports[@]}"; do
    local port="${entry%%:*}"
    local name="${entry##*:}"

    # Find PIDs listening on this port
    local pids
    pids=$(lsof -ti :"$port" 2>/dev/null || true)

    if [ -z "$pids" ]; then
      continue
    fi

    skipped_this=false
    for pid in $pids; do
      if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        sleep 0.3
        if kill -0 "$pid" 2>/dev/null; then
          kill -9 "$pid" 2>/dev/null || true
        fi
        success "Killed process on port $port ($name, PID: $pid)"
        killed=$((killed + 1))
      fi
    done
  done

  # Clean up stale PID file since we killed by port
  rm -f "$PID_FILE"

  if [ "$killed" -eq 0 ]; then
    info "No MADiE processes found on any known ports"
  else
    success "Killed $killed process(es). PID file cleaned up."
  fi
}

show_status() {
  if [ ! -f "$PID_FILE" ]; then
    info "No MADiE processes tracked"
    return
  fi

  printf "\n${BOLD}%-8s %-30s %-8s %-12s %-8s${NC}\n" "PID" "SERVICE" "PORT" "GROUP" "STATUS"
  printf "%-8s %-30s %-8s %-12s %-8s\n" "───" "───────" "────" "─────" "──────"

  while read -r pid name port group; do
    [ -z "$pid" ] && continue
    if kill -0 "$pid" 2>/dev/null; then
      status="${GREEN}running${NC}"
    else
      status="${RED}stopped${NC}"
    fi
    printf "%-8s %-30s %-8s %-12s ${status}\n" "$pid" "$name" "$port" "$group"
  done < "$PID_FILE"
  echo ""
}

tail_log() {
  local name="$1"
  local logfile="$LOGS_DIR/${name}.log"
  if [ ! -f "$logfile" ]; then
    error "No log file found for $name"
    exit 1
  fi
  tail -f "$logfile"
}

# Color palette for multiplexed log output
LOG_COLORS=( '31' '32' '33' '34' '35' '36' '91' '92' '93' '94' '95' '96' )

tail_all_logs() {
  local filter_group="${1:-all}"
  local log_files=()
  local names=()

  if [ ! -f "$PID_FILE" ]; then
    error "No running processes found (no PID file)"
    exit 1
  fi

  while read -r pid name port group; do
    [ -z "$pid" ] && continue
    if [ "$filter_group" != "all" ] && [ "$group" != "$filter_group" ]; then
      continue
    fi
    local logfile="$LOGS_DIR/${name}.log"
    if [ -f "$logfile" ]; then
      log_files+=("$logfile")
      names+=("$name")
    fi
  done < "$PID_FILE"

  if [ ${#log_files[@]} -eq 0 ]; then
    error "No log files found for group: $filter_group"
    exit 1
  fi

  info "Tailing ${#log_files[@]} log(s) — press Ctrl+C to stop\n"

  # Print the color legend
  for i in "${!names[@]}"; do
    local ci=$(( i % ${#LOG_COLORS[@]} ))
    printf "  \033[${LOG_COLORS[$ci]}m●\033[0m %s\n" "${names[$i]}"
  done
  echo ""

  # Build a tail command that prefixes each line with a colored service name
  # Using awk to add prefixes: tail -f file1 file2 ... prints ==> filename <== headers
  tail -f "${log_files[@]}" | awk -v nc="${#names[@]}" '
    BEGIN {
      split("'"$(IFS=,; echo "${log_files[*]}")"'", files, ",")
      split("'"$(IFS=,; echo "${names[*]}")"'", labels, ",")
      split("31,32,33,34,35,36,91,92,93,94,95,96", colors, ",")
      nc = split("'"$(IFS=,; echo "${names[*]}")"'", labels, ",")
      for (i = 1; i <= nc; i++) {
        # Map filename to label + color
        fname = files[i]
        file_label[fname] = labels[i]
        file_color[fname] = colors[((i - 1) % 12) + 1]
      }
      current = ""
    }
    /^==> .* <==$/ {
      # Extract filename from tail header
      gsub(/^==> /, ""); gsub(/ <==$/, "")
      current = $0
      next
    }
    {
      label = file_label[current]
      color = file_color[current]
      if (label == "") { label = "???"; color = "37" }
      # Right-pad label to 28 chars for alignment
      pad = 28 - length(label)
      if (pad < 1) pad = 1
      printf "\033[%sm%-28s\033[0m │ %s\n", color, label, $0
    }
  '
}

# ─── Startup routines ────────────────────────────────────────────────────────

start_frontends_dev() {
  echo ""
  echo -e "${BOLD}━━━ Single-SPA Frontends (dev) ━━━${NC}"
  start_process "madie-root"        "$BASE_DIR/frontends/madie-root"        "npm start"  "${MADIE_ROOT_PORT:-9000}"        "frontends"
  start_process "madie-layout"      "$BASE_DIR/frontends/madie-layout"      "npm start"  "${MADIE_LAYOUT_PORT:-8500}"      "frontends"
  start_process "madie-auth"        "$BASE_DIR/frontends/madie-auth"        "npm start"  "${MADIE_AUTH_PORT:-8502}"        "frontends"
  start_process "madie-editor"      "$BASE_DIR/frontends/madie-editor"      "npm start"  "${MADIE_EDITOR_PORT:-8501}"      "frontends"
  start_process "madie-measure"     "$BASE_DIR/frontends/madie-measure"     "npm start"  "${MADIE_MEASURE_PORT:-8505}"     "frontends"
  start_process "madie-cql-library" "$BASE_DIR/frontends/madie-cql-library" "npm start"  "${MADIE_CQL_LIBRARY_PORT:-8507}" "frontends"
  start_process "madie-util"        "$BASE_DIR/frontends/madie-util"        "npm start"  "${MADIE_UTIL_PORT:-8508}"        "frontends"
}

start_frontends_dist() {
  echo ""
  echo -e "${BOLD}━━━ Single-SPA Frontends (dist) ━━━${NC}"
  local cmd_tpl="npx http-server dist/ -p"
  start_process "madie-root"        "$BASE_DIR/frontends/madie-root"        "${cmd_tpl} ${MADIE_ROOT_PORT:-9000} -c-1"        "${MADIE_ROOT_PORT:-9000}"        "frontends"
  start_process "madie-layout"      "$BASE_DIR/frontends/madie-layout"      "${cmd_tpl} ${MADIE_LAYOUT_PORT:-8500} -c-1"      "${MADIE_LAYOUT_PORT:-8500}"      "frontends"
  start_process "madie-auth"        "$BASE_DIR/frontends/madie-auth"        "${cmd_tpl} ${MADIE_AUTH_PORT:-8502} -c-1"        "${MADIE_AUTH_PORT:-8502}"        "frontends"
  start_process "madie-editor"      "$BASE_DIR/frontends/madie-editor"      "${cmd_tpl} ${MADIE_EDITOR_PORT:-8501} -c-1"      "${MADIE_EDITOR_PORT:-8501}"      "frontends"
  start_process "madie-measure"     "$BASE_DIR/frontends/madie-measure"     "${cmd_tpl} ${MADIE_MEASURE_PORT:-8505} -c-1"     "${MADIE_MEASURE_PORT:-8505}"     "frontends"
  start_process "madie-cql-library" "$BASE_DIR/frontends/madie-cql-library" "${cmd_tpl} ${MADIE_CQL_LIBRARY_PORT:-8507} -c-1" "${MADIE_CQL_LIBRARY_PORT:-8507}" "frontends"
  start_process "madie-util"        "$BASE_DIR/frontends/madie-util"        "${cmd_tpl} ${MADIE_UTIL_PORT:-8508} -c-1"        "${MADIE_UTIL_PORT:-8508}"        "frontends"
}

start_services_dev() {
  echo ""
  echo -e "${BOLD}━━━ Backend Microservices (dev) ━━━${NC}"

  export_service_urls

  # Java / Maven services
  local mvn_cmd="mvn spring-boot:run"
  start_process "measure-service"           "$BASE_DIR/services/measure-service"           "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${MEASURE_SERVICE_PORT:-8080}"            "${MEASURE_SERVICE_PORT:-8080}"            "services"
  start_process "madie-fhir-service"        "$BASE_DIR/services/madie-fhir-service"        "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${MADIE_FHIR_SERVICE_PORT:-8085}"         "${MADIE_FHIR_SERVICE_PORT:-8085}"         "services"
  start_process "terminology-service"       "$BASE_DIR/services/terminology-service"       "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${TERMINOLOGY_SERVICE_PORT:-8081}"        "${TERMINOLOGY_SERVICE_PORT:-8081}"        "services"
  start_process "cql-library-service"       "$BASE_DIR/services/cql-library-service"       "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${CQL_LIBRARY_SERVICE_PORT:-8082}"        "${CQL_LIBRARY_SERVICE_PORT:-8082}"        "services"
  start_process "madie-qdm-service"         "$BASE_DIR/services/madie-qdm-service"         "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${MADIE_QDM_SERVICE_PORT:-8086}"          "${MADIE_QDM_SERVICE_PORT:-8086}"          "services"
  start_process "madie-user-service"        "$BASE_DIR/services/madie-user-service"        "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${MADIE_USER_SERVICE_PORT:-8088}"         "${MADIE_USER_SERVICE_PORT:-8088}"         "services"
  start_process "madie-fhir-elm-translator" "$BASE_DIR/services/madie-fhir-elm-translator" "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${MADIE_FHIR_ELM_TRANSLATOR_PORT:-8083}" "${MADIE_FHIR_ELM_TRANSLATOR_PORT:-8083}" "services"
  start_process "madie-qdm-elm-translation" "$BASE_DIR/services/madie-qdm-elm-translation" "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${MADIE_QDM_ELM_TRANSLATION_PORT:-8084}" "${MADIE_QDM_ELM_TRANSLATION_PORT:-8084}" "services"

  # Node services
  start_process "virus-scan-service" "$BASE_DIR/services/virus-scan-service" "npm run dev"  "${VIRUS_SCAN_SERVICE_PORT:-5000}" "services"
  start_process "excel-export"       "$BASE_DIR/services/excel-export"       "npm run dev"  "${EXCEL_EXPORT_PORT:-3000}"       "services"

  # Ruby service (uses Nginx/Passenger in Docker; native mode uses rackup)
  start_process "qrda-export-service" "$BASE_DIR/services/qrda-export-service" "bundle exec rackup -p ${QRDA_EXPORT_SERVICE_PORT:-8089}" "${QRDA_EXPORT_SERVICE_PORT:-8089}" "services"
}

start_services_dist() {
  # For Java services, dist mode still uses Maven (same as dev)
  # For Node/Ruby services, use production start
  echo ""
  echo -e "${BOLD}━━━ Backend Microservices (dist) ━━━${NC}"

  export_service_urls

  local mvn_cmd="mvn spring-boot:run"
  start_process "measure-service"           "$BASE_DIR/services/measure-service"           "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${MEASURE_SERVICE_PORT:-8080}"            "${MEASURE_SERVICE_PORT:-8080}"            "services"
  start_process "madie-fhir-service"        "$BASE_DIR/services/madie-fhir-service"        "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${MADIE_FHIR_SERVICE_PORT:-8085}"         "${MADIE_FHIR_SERVICE_PORT:-8085}"         "services"
  start_process "terminology-service"       "$BASE_DIR/services/terminology-service"       "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${TERMINOLOGY_SERVICE_PORT:-8081}"        "${TERMINOLOGY_SERVICE_PORT:-8081}"        "services"
  start_process "cql-library-service"       "$BASE_DIR/services/cql-library-service"       "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${CQL_LIBRARY_SERVICE_PORT:-8082}"        "${CQL_LIBRARY_SERVICE_PORT:-8082}"        "services"
  start_process "madie-qdm-service"         "$BASE_DIR/services/madie-qdm-service"         "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${MADIE_QDM_SERVICE_PORT:-8086}"          "${MADIE_QDM_SERVICE_PORT:-8086}"          "services"
  start_process "madie-user-service"        "$BASE_DIR/services/madie-user-service"        "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${MADIE_USER_SERVICE_PORT:-8088}"         "${MADIE_USER_SERVICE_PORT:-8088}"         "services"
  start_process "madie-fhir-elm-translator" "$BASE_DIR/services/madie-fhir-elm-translator" "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${MADIE_FHIR_ELM_TRANSLATOR_PORT:-8083}" "${MADIE_FHIR_ELM_TRANSLATOR_PORT:-8083}" "services"
  start_process "madie-qdm-elm-translation" "$BASE_DIR/services/madie-qdm-elm-translation" "${mvn_cmd} -Dspring-boot.run.arguments=--server.port=${MADIE_QDM_ELM_TRANSLATION_PORT:-8084}" "${MADIE_QDM_ELM_TRANSLATION_PORT:-8084}" "services"

  start_process "virus-scan-service"  "$BASE_DIR/services/virus-scan-service"  "npm start"  "${VIRUS_SCAN_SERVICE_PORT:-5000}" "services"
  start_process "excel-export"        "$BASE_DIR/services/excel-export"        "npm start"  "${EXCEL_EXPORT_PORT:-3000}"       "services"
  start_process "qrda-export-service" "$BASE_DIR/services/qrda-export-service" "bundle exec rackup -p ${QRDA_EXPORT_SERVICE_PORT:-8089} -E production" "${QRDA_EXPORT_SERVICE_PORT:-8089}" "services"
}

start_standalone() {
  echo ""
  echo -e "${BOLD}━━━ Standalone ━━━${NC}"
  start_process "support-data" "$BASE_DIR/standalone/support-data" "npx http-server ./madie -p ${SUPPORT_DATA_PORT:-8660} -c-1 --cors" "${SUPPORT_DATA_PORT:-8660}" "standalone"
}

# ─── Docker mode ──────────────────────────────────────────────────────────────

docker_mode() {
  local action="${1:-up}"
  local compose_file="$BASE_DIR/docker-compose.yml"

  if [ ! -f "$compose_file" ]; then
    error "docker-compose.yml not found in $BASE_DIR"
    exit 1
  fi

  case "$action" in
    up)
      info "Starting MADiE via docker-compose (dev mode with volume mounts)..."
      docker compose -f "$compose_file" --env-file "$ENV_FILE" up -d --build
      success "Docker stack is up. Use 'docker compose logs -f' to follow logs."
      ;;
    down)
      info "Stopping MADiE docker-compose stack..."
      docker compose -f "$compose_file" down
      success "Docker stack stopped."
      ;;
    *)
      error "Unknown docker action: $action"
      echo "Usage: $0 docker [up|down]"
      exit 1
      ;;
  esac
}

# ─── Usage ────────────────────────────────────────────────────────────────────

usage() {
  echo -e "${BOLD}MADiE CLI${NC}"
  echo ""
  echo "Usage: $0 <command> [options]"
  echo ""
  echo "Commands:"
  echo "  start dev    [group] [-f]  Start in dev mode (hot-reload via webpack / spring-boot)"
  echo "  start dist   [group] [-f]  Start from pre-built artifacts"
  echo "  start docker [up|down]     Manage the docker-compose stack"
  echo "  stop   [group]             Stop running MADiE processes"
  echo "  kill                       Kill all processes on known MADiE ports"
  echo "  status                     Show status of all tracked processes"
  echo "  logs   <name>              Tail the log for a specific service"
  echo "  logs   --all [group]       Tail all logs with color-coded service prefixes"
  echo "  help   [topic]             Show detailed help (topics: start, stop, kill, logs, docker)"
  echo ""
  echo "Options:"
  echo "  -f, --follow      After starting, tail aggregated logs"
  echo ""
  echo "Groups: all (default), frontends, services, standalone"
  echo ""
  echo "Run '$0 help' for detailed examples."
}

help_cmd() {
  local topic="${1:-}"

  case "$topic" in
    start)
      echo -e "${BOLD}Starting MADiE${NC}"
      echo ""
      echo "Start all services in dev mode (webpack hot-reload, spring-boot:run):"
      echo "  $0 start dev"
      echo ""
      echo "Start and follow aggregated logs in the terminal:"
      echo "  $0 start dev -f"
      echo ""
      echo "Start only frontends or only backend services:"
      echo "  $0 start dev frontends"
      echo "  $0 start dev services"
      echo ""
      echo "Start from pre-built artifacts (dist/build folders):"
      echo "  $0 start dist"
      echo "  $0 start dist frontends"
      echo ""
      echo "Start the full Docker Compose stack:"
      echo "  $0 start docker up"
      echo ""
      echo "Tear down the Docker stack:"
      echo "  $0 start docker down"
      ;;

    stop)
      echo -e "${BOLD}Stopping MADiE${NC}"
      echo ""
      echo "Stop all running MADiE processes:"
      echo "  $0 stop"
      echo ""
      echo "Stop only a specific group:"
      echo "  $0 stop frontends     # Stop frontend processes"
      echo "  $0 stop services      # Stop backend service processes"
      echo "  $0 stop standalone    # Stop standalone processes (support-data, etc.)"
      echo ""
      echo "If PIDs are out of sync, use 'kill' instead (see: $0 help kill)"
      echo ""
      echo "Typical workflow — start, work, then stop:"
      echo "  $0 start dev          # Begin your session"
      echo "  # ... do your work ..."
      echo "  $0 stop               # End your session"
      ;;

    kill)
      echo -e "${BOLD}Kill by Port${NC}"
      echo ""
      echo "Force-kill all processes listening on known MADiE ports."
      echo "Use this when PID tracking has gotten out of sync (e.g. after a crash)."
      echo ""
      echo "  $0 kill               # Scans all configured ports and kills any listeners"
      echo ""
      echo "This uses lsof to find processes by port, so it works even if the"
      echo "PID file (.madie.pids) is stale or missing. The PID file is cleaned"
      echo "up automatically after a kill."
      echo ""
      echo "Ports scanned: 9000, 8500-8508, 8080-8089, 8660, 5000, 3000"
      ;;

    logs)
      echo -e "${BOLD}Viewing Logs${NC}"
      echo ""
      echo "Tail logs for a single service:"
      echo "  $0 logs madie-root"
      echo "  $0 logs madie-measure-service"
      echo ""
      echo "Tail all logs with color-coded prefixes:"
      echo "  $0 logs --all"
      echo ""
      echo "Tail logs for a specific group:"
      echo "  $0 logs --all frontends"
      echo "  $0 logs --all services"
      echo ""
      echo "Start and follow logs in one command:"
      echo "  $0 start dev -f"
      ;;

    docker)
      echo -e "${BOLD}Docker Mode${NC}"
      echo ""
      echo "Bring up the full stack via Docker Compose:"
      echo "  $0 start docker up"
      echo ""
      echo "Tear down containers and networks:"
      echo "  $0 start docker down"
      echo ""
      echo "Tip: Volume mounts enable hot-reload without restarts."
      echo "     Edit .env to configure ports, credentials, and feature flags."
      ;;

    "")
      echo -e "${BOLD}MADiE CLI — Quick Reference${NC}"
      echo ""
      echo -e "${GREEN}Getting started:${NC}"
      echo "  $0 start dev              # Start everything in dev mode"
      echo "  $0 start dev -f           # Start and follow aggregated logs"
      echo ""
      echo -e "${GREEN}Starting specific groups:${NC}"
      echo "  $0 start dev frontends    # Only frontend apps (webpack)"
      echo "  $0 start dev services     # Only backend services (spring-boot)"
      echo "  $0 start dev frontends -f # Start frontends + follow their logs"
      echo ""
      echo -e "${GREEN}Using pre-built artifacts:${NC}"
      echo "  $0 start dist             # Serve from build/dist folders"
      echo "  $0 start dist services    # Only services from built JARs"
      echo ""
      echo -e "${GREEN}Docker:${NC}"
      echo "  $0 start docker up        # Full stack via docker-compose"
      echo "  $0 start docker down      # Tear it all down"
      echo ""
      echo -e "${GREEN}Stopping:${NC}"
      echo "  $0 stop                   # Stop all running processes"
      echo "  $0 stop frontends         # Stop only frontends"
      echo "  $0 stop services          # Stop only services"
      echo "  $0 kill                   # Kill everything by port (when PIDs are stale)"
      echo ""
      echo -e "${GREEN}Monitoring:${NC}"
      echo "  $0 status                 # Show running processes and PIDs"
      echo "  $0 logs madie-root        # Tail a single service log"
      echo "  $0 logs --all             # Tail all logs (color-coded)"
      echo "  $0 logs --all services    # Tail only service logs"
      echo ""
      echo "For detailed help on a topic: $0 help <start|stop|kill|logs|docker>"
      ;;

    *)
      error "Unknown help topic: $topic"
      echo "Available topics: start, stop, kill, logs, docker"
      echo "Or run '$0 help' with no topic for a full quick reference."
      exit 1
      ;;
  esac
}

# ─── Main ─────────────────────────────────────────────────────────────────────

if [ $# -lt 1 ]; then
  usage
  exit 0
fi

command="$1"
shift

case "$command" in
  start)
    if [ $# -lt 1 ]; then
      error "Specify a start mode: dev, dist, or docker"
      echo "Usage: $0 start <dev|dist|docker> [group] [-f]"
      exit 1
    fi

    mode="$1"
    shift
    group="all"

    # Parse remaining args: [group] [-f|--follow]
    for arg in "$@"; do
      case "$arg" in
        -f|--follow) FOLLOW_LOGS=true ;;
        *)           group="$arg" ;;
      esac
    done

    case "$mode" in
      dev)
        echo -e "\n${BOLD}Starting MADiE in DEV mode...${NC}\n"
        case "$group" in
          all)
            start_frontends_dev
            start_services_dev
            start_standalone
            ;;
          frontends|frontend|fe)  start_frontends_dev ;;
          services|service|be)    start_services_dev ;;
          standalone)             start_standalone ;;
          *) error "Unknown group: $group"; exit 1 ;;
        esac
        if [ "$FOLLOW_LOGS" = true ]; then
          echo ""
          tail_all_logs "$group"
        fi
        ;;

      dist)
        echo -e "\n${BOLD}Starting MADiE in DIST mode...${NC}\n"
        case "$group" in
          all)
            start_frontends_dist
            start_services_dist
            start_standalone
            ;;
          frontends|frontend|fe)  start_frontends_dist ;;
          services|service|be)    start_services_dist ;;
          standalone)             start_standalone ;;
          *) error "Unknown group: $group"; exit 1 ;;
        esac
        if [ "$FOLLOW_LOGS" = true ]; then
          echo ""
          tail_all_logs "$group"
        fi
        ;;

      docker)
        docker_mode "$group"
        ;;

      *)
        error "Unknown start mode: $mode"
        echo "Usage: $0 start <dev|dist|docker> [group] [-f]"
        exit 1
        ;;
    esac
    ;;

  stop)
    group="${1:-all}"
    echo -e "\n${BOLD}Stopping MADiE processes...${NC}\n"
    stop_processes "$group"
    ;;

  kill)
    echo -e "\n${BOLD}Killing all processes on MADiE ports...${NC}\n"
    kill_by_ports
    ;;

  status)
    show_status
    ;;

  logs)
    target="${1:-}"
    if [ "$target" = "--all" ] || [ "$target" = "-a" ]; then
      log_group="${2:-all}"
      tail_all_logs "$log_group"
    elif [ -z "$target" ]; then
      error "Specify a service name or use --all, e.g.:"
      echo "  $0 logs madie-root    # Single service"
      echo "  $0 logs --all         # All services"
      exit 1
    else
      tail_log "$target"
    fi
    ;;

  -h|--help|help)
    help_cmd "${1:-}"
    ;;

  *)
    error "Unknown command: $command"
    usage
    exit 1
    ;;
esac

echo ""
