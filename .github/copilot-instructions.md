# Copilot Instructions

See [AGENTS.md](../AGENTS.md) for full project documentation, conventions, and the checklist for adding new services.

## Key Rules

- All shell scripts must be **Bash 3.2 compatible** (macOS default). No associative arrays, no namerefs, no Bash 4+ features.
- Use `"key:value"` indexed arrays parsed with `${entry%%:*}` and `${entry##*:}`.
- Adding a new service requires changes in **5 files**: `setup-madie.sh`, `.env.example`, `madie.sh` (4 locations), and `docker-compose.yml`.
- Docker Compose uses YAML anchors (`*java-base`, `*java-common-env`, `*mongo-spring-env`, `*node-service`) — merge them with `<<:` instead of duplicating config.
- `serviceConfig.json` is served by `madie-root:9000`, not `support-data`.
- `support-data` serves the `madie/` subdirectory as its root.
- Port variable naming: `<SERVICE_NAME>_PORT` or `MADIE_<NAME>_PORT`, consistent across `.env.example`, `madie.sh`, and `docker-compose.yml`.
