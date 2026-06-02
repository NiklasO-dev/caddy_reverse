#!/usr/bin/env bash
# Copy stack templates to STACKS_DEST and render Caddyfile from setup.env.
#
# Usage (on the VPS, as root or deploy with sudo, after editing setup.env):
#   sudo bash scripts/install-stacks.sh
#
# After git pull, re-run to refresh compose files and re-render the Caddyfile:
#   cd /opt/caddy_reverse && git pull && sudo bash scripts/install-stacks.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACKS_SRC="${REPO_ROOT}/stacks"
STACKS_DEST="${STACKS_DEST:-/opt/stacks}"

# shellcheck source=lib/common.sh
source "${REPO_ROOT}/lib/common.sh"
# shellcheck source=lib/setup-env.sh
source "${REPO_ROOT}/lib/setup-env.sh"

load_setup_env
validate_setup_env_common
ensure_caddy_basic_auth_hash

if [[ ! -d "${STACKS_SRC}" ]]; then
  error "Missing stacks directory: ${STACKS_SRC}"
fi

GLOBAL_TEMPLATE="${STACKS_SRC}/caddy/Caddyfile.example"
if [[ ! -f "${GLOBAL_TEMPLATE}" ]]; then
  error "Missing ${GLOBAL_TEMPLATE}"
fi

GENERATE_SCRIPT="${REPO_ROOT}/scripts/generate-caddyfile.sh"
chmod +x "${GENERATE_SCRIPT}"

info "Installing stacks to ${STACKS_DEST}..."

# Copy bundled stacks from git. Manual stacks on the server (not in git) are kept;
# Caddy generation scans every folder under STACKS_DEST that has compose.yml.
for stack_dir in "${STACKS_SRC}"/*/; do
  [[ -d "${stack_dir}" ]] || continue
  stack="$(basename "${stack_dir}")"
  [[ "${stack}" == "caddy" ]] && continue

  install -d "${STACKS_DEST}/${stack}"
  for f in compose.yml caddy.env .env.example caddy.env.example; do
    if [[ -f "${STACKS_SRC}/${stack}/${f}" ]]; then
      cp -f "${STACKS_SRC}/${stack}/${f}" "${STACKS_DEST}/${stack}/${f}"
    fi
  done
done

install -d "${STACKS_DEST}/caddy"
cp -f "${STACKS_SRC}/caddy/compose.yml" "${STACKS_DEST}/caddy/compose.yml"
cp -f "${GLOBAL_TEMPLATE}" "${STACKS_DEST}/caddy/Caddyfile.example"

export ACME_EMAIL APPS_DOMAIN CADDY_BASIC_AUTH_USER CADDY_BASIC_AUTH_HASH

info "Generating Caddy site blocks from ${STACKS_DEST}..."
SITES_FILE="$(mktemp)"
if ! STACKS_DEST="${STACKS_DEST}" bash "${GENERATE_SCRIPT}" > "${SITES_FILE}"; then
  rm -f "${SITES_FILE}"
  error "Caddy generation failed — fix caddy.env / compose.yml in stack folders"
fi

mapfile -t HOSTNAMES < <(grep -oE '^[a-zA-Z0-9][a-zA-Z0-9-]*\.\$\{APPS_DOMAIN\}' "${SITES_FILE}" \
  | sed -E 's/\.\\$\{APPS_DOMAIN\}//' || true)

{
  envsubst '${ACME_EMAIL} ${APPS_DOMAIN} ${CADDY_BASIC_AUTH_USER} ${CADDY_BASIC_AUTH_HASH}' \
    < "${GLOBAL_TEMPLATE}"
  envsubst '${ACME_EMAIL} ${APPS_DOMAIN} ${CADDY_BASIC_AUTH_USER} ${CADDY_BASIC_AUTH_HASH}' \
    < "${SITES_FILE}"
} > "${STACKS_DEST}/caddy/Caddyfile"
rm -f "${SITES_FILE}"

chmod 644 "${STACKS_DEST}/caddy/Caddyfile"

if [[ -f "${STACKS_DEST}/dockge/.env.example" && ! -f "${STACKS_DEST}/dockge/.env" ]]; then
  cp "${STACKS_DEST}/dockge/.env.example" "${STACKS_DEST}/dockge/.env"
  info "Created ${STACKS_DEST}/dockge/.env from .env.example"
fi

if command -v docker &>/dev/null; then
  while IFS= read -r -d '' compose_file; do
    docker compose -f "${compose_file}" config -q
  done < <(find "${STACKS_DEST}" -mindepth 2 -maxdepth 2 -name compose.yml -print0)
  info "Compose files validated."
fi

info "Rendered ${STACKS_DEST}/caddy/Caddyfile for *.${APPS_DOMAIN}"
if [[ ${#HOSTNAMES[@]} -gt 0 ]]; then
  info "Services: $(printf '%s.%s, ' "${HOSTNAMES[@]}" "${APPS_DOMAIN}" | sed 's/, $//')"
fi
