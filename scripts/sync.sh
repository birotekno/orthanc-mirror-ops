#!/usr/bin/env bash
#
# sync.sh <repo> -- mirror one Orthanc hg repo into github.com/$ORG/<repo>.
#
# Idempotent and safe to run from either a laptop or CI: the only difference is
# whether local state already exists. Run twice with no upstream change and the
# second run pushes nothing.
#
# Ref layout it maintains (ALL force-pushed; all machine-owned):
#   refs/heads/upstream          <- hg 'default' branch tip  (our tracking branch)
#   refs/heads/branches/<name>   <- every hg named branch, verbatim (release lines)
#   refs/tags/*                  <- hg tags, where they exist
#   refs/cinnabar/metadata       <- cinnabar's hg<->git map, a SPEED CACHE only
#
# It NEVER touches refs/heads/main. That is the whole basis of "fork later":
# our patches live on main, so no sync can clobber them.
#
# On cinnabar metadata: conversion is deterministic, so a lost/absent metadata
# ref costs time (full re-convert), never correctness. Verified 2026-07-16 --
# a no-metadata convert reproduced byte-identical SHAs. This is NOT true of
# hg-fast-export, and is why we chose cinnabar.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

REPO="${1:-}"
[ -n "$REPO" ] || die "usage: sync.sh <repo-name>"
require_tools

WORK="$WORK_DIR/$REPO"
mkdir -p "$WORK"

if [ ! -d "$WORK/.git" ]; then
  log "$REPO: initialising work tree at $WORK"
  git init -q "$WORK"
fi

cd "$WORK"

# Remotes are re-set every run so a rotated token or moved URL just works.
git remote remove origin 2>/dev/null || true
git remote add origin "$(origin_url "$REPO")"
git remote remove hg 2>/dev/null || true
git remote add hg "hg::$(hg_url "$REPO")"

# Seed the metadata cache. Non-fatal: absent metadata (first run, cache miss,
# brand-new repo) just means cinnabar converts from scratch.
if git fetch -q origin 'refs/cinnabar/metadata:refs/cinnabar/metadata' 2>/dev/null; then
  log "$REPO: metadata cache restored ($(git rev-parse --short refs/cinnabar/metadata))"
else
  log "$REPO: no metadata cache -- full conversion (slower, same result)"
fi

# orthanc.uclouvain.be is a single university-hosted server and it does time out
# under concurrent load -- observed 2026-07-16, 4/23 CI jobs failed to even open
# a TCP connection (~135s) while the rest succeeded. Transient upstream flakiness
# must not fail a daily mirror, so retry with backoff before giving up.
log "$REPO: fetching from mercurial"
fetch_ok=0
for attempt in 1 2 3; do
  if git fetch -q hg; then fetch_ok=1; break; fi
  if [ "$attempt" -lt 3 ]; then
    backoff=$(( attempt * 60 ))
    log "$REPO: hg fetch failed (attempt $attempt/3) -- upstream may be busy; retrying in ${backoff}s"
    # A failed fetch can leave cinnabar's remote refs half-written; clear them
    # so the retry starts from the restored metadata rather than a partial state.
    git remote prune hg >/dev/null 2>&1 || true
    sleep "$backoff"
  fi
done
[ "$fetch_ok" -eq 1 ] || die "$REPO: hg fetch failed after 3 attempts (upstream unreachable?)"

# Map cinnabar's remote refs to the layout we publish.
DEFAULT_REF="refs/remotes/hg/branches/default/tip"
git rev-parse --verify -q "$DEFAULT_REF" >/dev/null \
  || die "$REPO: no 'default' branch found on hg -- upstream layout changed?"

REFSPECS=( "+$DEFAULT_REF:refs/heads/upstream" )

# Orthanc ships releases as hg NAMED BRANCHES, not tags (e.g. OrthancGdcm-1.8).
# Mirroring only 'default' would silently drop every release line.
while read -r ref; do
  name="${ref#refs/remotes/hg/branches/}"
  name="${name%/tip}"
  [ "$name" = "default" ] && continue
  REFSPECS+=( "+$ref:refs/heads/branches/$name" )
done < <(git for-each-ref --format='%(refname)' 'refs/remotes/hg/branches/')

# Tags, where a repo has them.
if [ -n "$(git for-each-ref 'refs/tags/')" ]; then
  REFSPECS+=( "+refs/tags/*:refs/tags/*" )
fi

REFSPECS+=( "+refs/cinnabar/metadata:refs/cinnabar/metadata" )

log "$REPO: pushing ${#REFSPECS[@]} refspecs to $ORG/$REPO"

# Push status must be captured on its own: piping straight into grep would let
# grep's exit code mask a failed push, and under `pipefail` a fully-filtered
# (i.e. perfectly clean) run would exit 1 and look like a failure.
#
# 'badFilemode' warnings are expected and benign -- cinnabar's metadata trees
# carry file modes git considers odd. Filtered so they don't drown real errors.
push_rc=0
git push --porcelain origin "${REFSPECS[@]}" >"$WORK/.push.log" 2>&1 || push_rc=$?

# Scrub the token before anything reaches a log.
sed -e 's|x-access-token:[^@]*@|x-access-token:***@|g' "$WORK/.push.log" \
  | grep -vE 'badFilemode|^remote: warning' >&2 || true

[ "$push_rc" -eq 0 ] || die "$REPO: push failed (rc=$push_rc)"

log "$REPO: done ($(git rev-parse --short "$DEFAULT_REF") = hg $(git cinnabar git2hg "$DEFAULT_REF" | cut -c1-12))"
