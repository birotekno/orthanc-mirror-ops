#!/usr/bin/env bash
# Shared config and helpers. Sourced by sync.sh and bootstrap.sh.

set -euo pipefail

ORG="${MIRROR_ORG:-birotekno}"
HG_BASE="${HG_BASE:-https://orthanc.uclouvain.be/hg}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$REPO_ROOT/.work}"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Read repos.txt, stripping comments and blanks.
read_repos() {
  grep -vE '^\s*(#|$)' "$REPO_ROOT/repos.txt"
}

# Build the origin URL. Uses the PAT when present (CI), otherwise plain https
# and lets the local git credential helper / gh auth handle it.
#
# NEVER echo the result -- it embeds the token.
origin_url() {
  local repo="$1"
  if [ -n "${ORTHANC_MIRROR_TOKEN:-}" ]; then
    printf 'https://x-access-token:%s@github.com/%s/%s.git' \
      "$ORTHANC_MIRROR_TOKEN" "$ORG" "$repo"
  else
    printf 'https://github.com/%s/%s.git' "$ORG" "$repo"
  fi
}

hg_url() { printf '%s/%s/' "$HG_BASE" "$1"; }

require_tools() {
  command -v git >/dev/null || die "git not found"
  command -v hg  >/dev/null || die "hg not found"
  git cinnabar --version >/dev/null 2>&1 || die "git-cinnabar not found"
}
