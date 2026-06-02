#!/usr/bin/env bash
# Generate Caddy site blocks from stack folders under STACKS_DEST.
#
# Convention: folder name "myapp" -> https://myapp.${APPS_DOMAIN}
# Optional overrides in each stack's caddy.env (SUBDOMAIN, PORT, UPSTREAM, BASIC_AUTH).
#
# Usage:
#   STACKS_DEST=/opt/stacks bash scripts/generate-caddyfile.sh
set -euo pipefail

STACKS_DEST="${STACKS_DEST:-/opt/stacks}"

SKIP_DIRS=(caddy _template)

is_skipped_dir() {
  local name="$1"
  local d
  for d in "${SKIP_DIRS[@]}"; do
    [[ "${name}" == "${d}" ]] && return 0
  done
  [[ "${name}" == .* ]] && return 0
  return 1
}

load_caddy_env() {
  local env_file="$1"
  SUBDOMAIN=""
  PORT=""
  UPSTREAM=""
  BASIC_AUTH="true"
  COMMENT=""
  if [[ -f "${env_file}" ]]; then
    # shellcheck source=/dev/null
    source "${env_file}"
  fi
}

read_compose_hints() {
  local compose_file="$1"
  local detected_upstream="" detected_port=""

  if [[ ! -f "${compose_file}" ]]; then
    return 0
  fi

  detected_upstream="$(grep -E '^[[:space:]]*container_name:' "${compose_file}" 2>/dev/null \
    | head -1 | sed -E 's/^[[:space:]]*container_name:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/' || true)"

  if grep -qE '^[[:space:]]*expose:' "${compose_file}"; then
    detected_port="$(awk '
      /^[[:space:]]*expose:/ { in_expose=1; next }
      in_expose && /^[[:space:]]*-/ {
        gsub(/[^0-9]/, "", $0);
        if ($0 != "") { print $0; exit }
      }
      in_expose && /^[^[:space:]]/ { in_expose=0 }
    ' "${compose_file}" 2>/dev/null || true)"
  fi

  if [[ -z "${detected_port}" ]]; then
    detected_port="$(grep -E '^[[:space:]]*-[[:space:]]*"?[0-9]+' "${compose_file}" 2>/dev/null \
      | head -1 | sed -E 's/^[[:space:]]*-[[:space:]]*"?([0-9]+).*/\1/' || true)"
  fi

  if [[ -z "${UPSTREAM}" && -n "${detected_upstream}" ]]; then
    UPSTREAM="${detected_upstream}"
  fi
  if [[ -z "${PORT}" && -n "${detected_port}" ]]; then
    PORT="${detected_port}"
  fi
}

emit_site_block() {
  local stack_name="$1"
  local subdomain="${SUBDOMAIN:-${stack_name}}"
  local upstream="${UPSTREAM:-${stack_name}}"
  local port="${PORT:-}"
  local basic_auth="${BASIC_AUTH:-true}"

  if [[ -z "${port}" ]]; then
    echo "# ERROR: ${stack_name}: missing PORT (set in caddy.env or expose in compose.yml)" >&2
    return 1
  fi

  if [[ -n "${COMMENT}" ]]; then
    echo "# ${COMMENT}"
  else
    echo "# ${stack_name} -> ${subdomain}.\${APPS_DOMAIN}"
  fi

  echo "${subdomain}.\${APPS_DOMAIN} {"
  if [[ "${basic_auth}" == "true" ]]; then
    cat <<'EOF'
    basicauth {
        ${CADDY_BASIC_AUTH_USER} ${CADDY_BASIC_AUTH_HASH}
    }
EOF
  fi
  echo "    reverse_proxy ${upstream}:${port}"
  echo "}"
  echo ""
}

if [[ ! -d "${STACKS_DEST}" ]]; then
  echo "# No stacks directory: ${STACKS_DEST}" >&2
  exit 1
fi

mapfile -t STACK_DIRS < <(find "${STACKS_DEST}" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
  | sort)

errors=0
for stack_name in "${STACK_DIRS[@]}"; do
  is_skipped_dir "${stack_name}" && continue

  stack_dir="${STACKS_DEST}/${stack_name}"
  compose_file="${stack_dir}/compose.yml"
  [[ -f "${compose_file}" ]] || continue

  load_caddy_env "${stack_dir}/caddy.env"
  SUBDOMAIN="${SUBDOMAIN:-${stack_name}}"
  read_compose_hints "${compose_file}"

  if ! emit_site_block "${stack_name}"; then
    errors=$((errors + 1))
  fi
done

exit "${errors}"
