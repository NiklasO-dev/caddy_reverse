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

TEMPLATE="${STACKS_SRC}/caddy/Caddyfile.example"
if [[ ! -f "${TEMPLATE}" ]]; then
  error "Missing ${TEMPLATE}"
fi

info "Installing stacks to ${STACKS_DEST}..."

for stack in uptime-kuma dozzle dockge; do
  install -d "${STACKS_DEST}/${stack}"
  for f in compose.yml .env.example; do
    if [[ -f "${STACKS_SRC}/${stack}/${f}" ]]; then
      cp -f "${STACKS_SRC}/${stack}/${f}" "${STACKS_DEST}/${stack}/${f}"
    fi
  done
done

install -d "${STACKS_DEST}/caddy"
cp -f "${STACKS_SRC}/caddy/compose.yml" "${STACKS_DEST}/caddy/compose.yml"
cp -f "${TEMPLATE}" "${STACKS_DEST}/caddy/Caddyfile.example"

export ACME_EMAIL APPS_DOMAIN CADDY_BASIC_AUTH_USER CADDY_BASIC_AUTH_HASH

envsubst '${ACME_EMAIL} ${APPS_DOMAIN} ${CADDY_BASIC_AUTH_USER} ${CADDY_BASIC_AUTH_HASH}' \
  < "${TEMPLATE}" > "${STACKS_DEST}/caddy/Caddyfile"

chmod 644 "${STACKS_DEST}/caddy/Caddyfile"

if [[ -f "${STACKS_DEST}/dockge/.env.example" && ! -f "${STACKS_DEST}/dockge/.env" ]]; then
  cp "${STACKS_DEST}/dockge/.env.example" "${STACKS_DEST}/dockge/.env"
  info "Created ${STACKS_DEST}/dockge/.env from .env.example"
fi

if command -v docker &>/dev/null; then
  for stack in caddy uptime-kuma dozzle dockge; do
    compose_file="${STACKS_DEST}/${stack}/compose.yml"
    if [[ -f "${compose_file}" ]]; then
      docker compose -f "${compose_file}" config -q
    fi
  done
  info "Compose files validated."
fi

info "Rendered ${STACKS_DEST}/caddy/Caddyfile for *.${APPS_DOMAIN}"
info "Services: kuma.${APPS_DOMAIN}, dozzle.${APPS_DOMAIN}, dockge.${APPS_DOMAIN}"
