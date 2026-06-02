# shellcheck shell=bash
# Shared helpers for setup and stack install scripts.

if [[ -z "${REPO_ROOT:-}" ]]; then
  error_repo_root() {
    echo "REPO_ROOT must be set before sourcing lib/common.sh" >&2
    exit 1
  }
  error_repo_root
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
