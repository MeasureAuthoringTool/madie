#!/usr/bin/env bash
#
# setup-madie.sh
#
# Clones (or updates) all repositories needed to run the MADiE project locally.
# Usage:
#   ./setup-madie.sh              # Clone or update ALL repo groups
#   ./setup-madie.sh frontends    # Clone or update only frontend repos
#   ./setup-madie.sh services     # Clone or update only microservice repos
#   ./setup-madie.sh libs         # Clone or update only shared library repos
#   ./setup-madie.sh --https         # Use HTTPS URLs instead of SSH
#   GIT_PROTOCOL=https ./setup-madie.sh   # Alternative: env var
#
# On first run, repos are cloned into categorized subdirectories.
# On subsequent runs, each repo is updated with the latest from its default branch.

set -eo pipefail

ORG="MeasureAuthoringTool"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Repo lists as "repo:branch" pairs (Bash 3 compatible) ───────────────────

FRONTEND_DIR="$BASE_DIR/frontends"
FRONTENDS=(
  "madie-root:develop"
  "madie-layout:develop"
  "madie-auth:develop"
  "madie-measure:develop"
  "madie-cql-library:develop"
  "madie-util:develop"
  "madie-admin:develop"
)

SERVICES_DIR="$BASE_DIR/services"
SERVICES=(
  "measure-service:develop"
  "madie-fhir-service:develop"
  "terminology-service:develop"
  "cql-library-service:develop"
  "madie-qdm-service:develop"
  "madie-fhir-elm-translator:develop"
  "madie-qdm-elm-translation:develop"
  "madie-user-service:develop"
  "virus-scan-service:develop"
  "qrda-export-service:develop"
  "excel-export:develop"
)

STANDALONE_DIR="$BASE_DIR/standalone"
STANDALONE=(
  "support-data:main"
  # "madie-public:develop"  # Uncomment when repo is created
)

LIBS_DIR="$BASE_DIR/libs"
LIBS=(
  "madie-models:main"
  "madie-design-system:main"
  "madie-java-models:develop"
  "madie-rest-commons:develop"
  "madie-translator-commons:develop"
  "packaging-utility:develop"
  "madie-editor:develop"
)

# ─── Colors & helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}   $*"; }

# ─── Clone protocol (SSH by default; use --https flag or GIT_PROTOCOL=https) ──

USE_HTTPS=false
for arg in "$@"; do
  case "$arg" in
    --https) USE_HTTPS=true ;;
  esac
done
if [ "${GIT_PROTOCOL:-}" = "https" ]; then
  USE_HTTPS=true
fi

get_clone_url() {
  local repo="$1"
  if $USE_HTTPS; then
    echo "https://github.com/${ORG}/${repo}.git"
  else
    echo "git@github.com:${ORG}/${repo}.git"
  fi
}

# ─── Core logic ──────────────────────────────────────────────────────────────

clone_or_update() {
  local repo="$1"
  local branch="$2"
  local target_dir="$3"
  local repo_path="$target_dir/$repo"
  local clone_url
  clone_url="$(get_clone_url "$repo")"

  if [ -d "$repo_path/.git" ]; then
    info "Updating ${BOLD}$repo${NC} (branch: $branch)"
    (
      cd "$repo_path"
      # Fetch latest from origin
      git fetch origin --prune --quiet

      # Check if there are uncommitted changes
      if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
        warn "$repo has local changes — stashing before update"
        git stash push -m "setup-madie auto-stash $(date +%Y%m%d-%H%M%S)" --quiet
      fi

      # Checkout the target branch and pull
      current_branch="$(git symbolic-ref --short HEAD 2>/dev/null || echo '')"
      if [ "$current_branch" != "$branch" ]; then
        git checkout "$branch" --quiet 2>/dev/null || {
          warn "$repo: branch '$branch' not found locally, fetching..."
          git checkout -b "$branch" "origin/$branch" --quiet
        }
      fi

      git pull origin "$branch" --quiet
    ) && success "$repo is up to date" \
      || error "Failed to update $repo"
  else
    info "Cloning ${BOLD}$repo${NC} (branch: $branch)"
    git clone --branch "$branch" "$clone_url" "$repo_path" --quiet \
      && success "$repo cloned" \
      || error "Failed to clone $repo"
  fi
}

process_group() {
  local group_name="$1"
  local target_dir="$2"
  shift 2

  echo ""
  echo -e "${BOLD}━━━ ${group_name} ━━━${NC}"
  mkdir -p "$target_dir"

  # Remaining args are "repo:branch" pairs
  for entry in "$@"; do
    local repo="${entry%%:*}"
    local branch="${entry##*:}"
    clone_or_update "$repo" "$branch" "$target_dir"
  done
}

# ─── Main ─────────────────────────────────────────────────────────────────────

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════╗"
echo "║        MADiE Project Setup Script        ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Clones or updates all MADiE repos       ║"
echo "║  into: $BASE_DIR"
echo "╚══════════════════════════════════════════╝"
echo -e "${NC}"

# Ensure data directory exists for Docker volume mounts
mkdir -p "$BASE_DIR/data"

filter="all"
for arg in "$@"; do
  case "$arg" in
    --https) ;; # already handled above
    *) filter="$arg" ;;
  esac
done

do_frontends=false
do_services=false
do_standalone=false
do_libs=false

case "$filter" in
  all)
    do_frontends=true
    do_services=true
    do_standalone=true
    do_libs=true
    ;;
  frontends|frontend|fe)
    do_frontends=true
    ;;
  services|service|be|backend)
    do_services=true
    ;;
  standalone)
    do_standalone=true
    ;;
  libs|lib|libraries)
    do_libs=true
    ;;
  *)
    error "Unknown group: $filter"
    echo "Usage: $0 [all|frontends|services|standalone|libs] [--https]"
    exit 1
    ;;
esac

if $do_frontends; then
  process_group "Single-SPA Frontends" "$FRONTEND_DIR" "${FRONTENDS[@]}"
fi

if $do_services; then
  process_group "Backend Microservices" "$SERVICES_DIR" "${SERVICES[@]}"
fi

if $do_standalone; then
  process_group "Standalone Apps" "$STANDALONE_DIR" "${STANDALONE[@]}"
fi

if $do_libs; then
  process_group "Shared Libraries" "$LIBS_DIR" "${LIBS[@]}"
fi

echo ""
echo -e "${GREEN}${BOLD}✔ Done!${NC}"
echo ""
echo -e "  Data:       $BASE_DIR/data (Docker volume mounts)"

# Summary
if $do_frontends; then
  echo -e "  Frontends:  $FRONTEND_DIR (${#FRONTENDS[@]} repos)"
fi
if $do_services; then
  echo -e "  Services:   $SERVICES_DIR (${#SERVICES[@]} repos)"
fi
if $do_standalone; then
  echo -e "  Standalone: $STANDALONE_DIR (${#STANDALONE[@]} repos)"
fi
if $do_libs; then
  echo -e "  Libraries:  $LIBS_DIR (${#LIBS[@]} repos)"
fi
echo ""
