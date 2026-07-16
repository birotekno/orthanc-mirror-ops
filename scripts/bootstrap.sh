#!/usr/bin/env bash
#
# bootstrap.sh [repo ...] -- one-time local import.
#
# Creates the GitHub repo (if absent), runs the same sync.sh engine CI uses,
# then seeds `main` from `upstream` and makes it the default branch.
#
# Run this on a workstation, not in CI: the first conversion of `orthanc` is
# 20+ years of changesets. After this, CI only ever handles small deltas.
#
# Deliberately SERIAL. orthanc.uclouvain.be is one university's server and we
# are an uninvited guest on it; do not parallelise this.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_tools
command -v gh >/dev/null || die "gh CLI not found (needed to create repos)"

REPOS=( "$@" )
[ ${#REPOS[@]} -gt 0 ] || mapfile -t REPOS < <(read_repos)

log "bootstrapping ${#REPOS[@]} repo(s) into $ORG"

failed=()
for repo in "${REPOS[@]}"; do
  log "=== $repo ==="

  if gh repo view "$ORG/$repo" >/dev/null 2>&1; then
    log "$repo: GitHub repo exists"
  else
    log "$repo: creating $ORG/$repo"
    desc="Mirror of ${HG_BASE}/${repo} -- unofficial birotekno mirror, synced daily"
    gh repo create "$ORG/$repo" --public --description "$desc" \
      || { failed+=( "$repo (create)" ); continue; }
  fi

  "$(dirname "${BASH_SOURCE[0]}")/sync.sh" "$repo" \
    || { failed+=( "$repo (sync)" ); continue; }

  # Seed main from upstream, once. If main already exists we leave it strictly
  # alone -- by then it may carry our patches.
  if git ls-remote --exit-code --heads "$(origin_url "$repo")" main >/dev/null 2>&1; then
    log "$repo: main already exists, leaving untouched"
  else
    log "$repo: seeding main from upstream"
    git -C "$WORK_DIR/$repo" push origin \
      "refs/remotes/hg/branches/default/tip:refs/heads/main" 2>/dev/null \
      || { failed+=( "$repo (main)" ); continue; }
    gh repo edit "$ORG/$repo" --default-branch main >/dev/null 2>&1 || true
  fi
done

if [ ${#failed[@]} -gt 0 ]; then
  log "FAILED: ${failed[*]}"
  exit 1
fi
log "bootstrap complete: ${#REPOS[@]} repo(s)"
