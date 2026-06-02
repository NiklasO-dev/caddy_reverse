# shellcheck shell=bash
# Load and validate setup.env from the repo root.

load_setup_env() {
  SETUP_ENV_FILE="${SETUP_ENV_FILE:-${REPO_ROOT}/setup.env}"
  SETUP_ENV_EXAMPLE="${REPO_ROOT}/setup.env.example"

  if [[ ! -f "${SETUP_ENV_FILE}" ]]; then
    echo "Missing ${SETUP_ENV_FILE}" >&2
    echo "Create it from the example:" >&2
    echo "  cp setup.env.example setup.env" >&2
    echo "  nano setup.env   # as root, before: bash setup_v2.sh" >&2
    exit 1
  fi

  # shellcheck disable=SC1090
  set -a
  source "${SETUP_ENV_FILE}"
  set +a
}

validate_setup_env_common() {
  local missing=()
  for var in APPS_DOMAIN ACME_EMAIL CADDY_BASIC_AUTH_USER; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Set these in setup.env: ${missing[*]}"
  fi

  if [[ "${APPS_DOMAIN}" == *"example.com"* && "${ALLOW_EXAMPLE_DOMAIN:-}" != "1" ]]; then
    warn "APPS_DOMAIN still looks like the example (${APPS_DOMAIN})."
    warn "Point wildcard DNS *.${APPS_DOMAIN} at your VPS before starting Caddy."
  fi
}

validate_setup_env_v2() {
  validate_setup_env_common

  local missing=()
  for var in NEW_USER SSH_PORT TIMEZONE SSH_PUBLIC_KEYS; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("${var}")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    error "setup_v2.sh requires in setup.env: ${missing[*]}"
  fi

  if [[ "${SSH_PUBLIC_KEYS}" == *"AAAA..."* ]]; then
    error "Replace the placeholder SSH public key in setup.env (SSH_PUBLIC_KEYS)."
  fi
}

caddy_hash_placeholder() {
  local hash="${CADDY_BASIC_AUTH_HASH:-}"
  hash="${hash#\'}"; hash="${hash%\'}"
  [[ -z "${hash}" ]] \
    || [[ "${hash}" == *"REPLACE"* ]] \
    || [[ "${hash}" == *"YOUR_"* ]]
}

ensure_caddy_basic_auth_hash() {
  if ! caddy_hash_placeholder; then
    return 0
  fi

  if ! command -v docker &>/dev/null; then
    error "Set CADDY_BASIC_AUTH_HASH in setup.env, or install Docker first."
    error "Generate a hash: docker run --rm caddy caddy hash-password"
  fi

  if [[ ! -t 0 ]]; then
    error "CADDY_BASIC_AUTH_HASH is empty and no TTY — set it in setup.env before running non-interactively."
  fi

  echo ""
  read -rsp "Caddy basic auth password (used for Kuma, Dozzle, Dockge): " _caddy_pass
  echo ""
  if [[ -z "${_caddy_pass}" ]]; then
    error "Empty password — set CADDY_BASIC_AUTH_HASH in setup.env or enter a password."
  fi

  CADDY_BASIC_AUTH_HASH="$(
    docker run --rm -i caddy caddy hash-password --plaintext "${_caddy_pass}"
  )"
  export CADDY_BASIC_AUTH_HASH

  warn "Add this line to setup.env on the server so git pull / reinstall does not prompt again:"
  echo "CADDY_BASIC_AUTH_HASH='${CADDY_BASIC_AUTH_HASH}'"
}
