# orthanc-mirror-ops

Mirrors the [Orthanc](https://orthanc.uclouvain.be/) Mercurial repositories to
`github.com/birotekno`, with full converted history, synced daily.

> **Unofficial mirror.** Upstream lives at <https://orthanc.uclouvain.be/hg/> and is
> maintained by UCLouvain and the Orthanc community. These mirrors are operated by
> birotekno for our own SIMRS work. Do not report Orthanc bugs here — take them to
> [the official channels](https://orthanc.uclouvain.be/book/users/support.html).

## Why

Orthanc develops in Mercurial on a single self-hosted server. There is no official git
mirror of the core (`orthanc-server/orthanc` on GitHub does not exist — that org holds
only newer git-native side projects). This gives us a git-native copy that our tooling
can consume and that survives upstream outages.

## What it mirrors

23 repos — every repo on the hg server except the two marked `[Discontinued]`
(`orthanc-client`, and `orthanc-postgresql`, whose live successor is `orthanc-databases`).
The list is `repos.txt`, which is the single source of truth for both the local bootstrap
and the CI matrix.

## Ref layout

Each mirror repo has:

| Ref | Owner | Meaning |
|---|---|---|
| `refs/heads/upstream` | **machine** | hg `default` tip. Force-pushed every sync. |
| `refs/heads/branches/<name>` | **machine** | Every hg named branch, verbatim. Force-pushed. |
| `refs/tags/*` | **machine** | hg tags, where a repo has any. |
| `refs/cinnabar/metadata` | **machine** | cinnabar's hg↔git map. A speed cache (see below). |
| `refs/heads/main` | **us** | Our branch. **CI never writes it.** Default branch. |

> Orthanc ships releases as hg **named branches** (`OrthancGdcm-1.8`, …), *not* tags.
> Several repos have zero tags. Mirroring only `default` would silently drop every
> release line — hence `branches/*`.

## Fork-later workflow

Nothing is forked today: `main` starts identical to `upstream`. When we need a SIMRS
patch, commit it to `main`, and pick up upstream changes with:

```bash
git fetch origin
git merge origin/upstream      # or: git rebase origin/upstream
```

Because CI only ever force-pushes `upstream`, `branches/*`, and the metadata ref, **no
sync can clobber our work**. This is verified, not assumed — see Testing below.

## Usage

```bash
# One-time local import (serial, slow — run on a workstation, not CI)
./scripts/bootstrap.sh              # all of repos.txt
./scripts/bootstrap.sh orthanc-gdcm # one repo

# Sync an existing mirror (what CI runs)
./scripts/sync.sh orthanc-gdcm
```

Env: `MIRROR_ORG` (default `birotekno`), `HG_BASE`, `WORK_DIR`,
`ORTHANC_MIRROR_TOKEN` (CI; locally the `gh` credential helper is used instead).

## CI

`.github/workflows/sync.yml` — daily at 03:17 UTC (≈10:17 WIB), plus `workflow_dispatch`
with an optional repo list. Matrix over `repos.txt`, `fail-fast: false` so one bad repo
doesn't mask the other 22, `max-parallel: 4`.

Requires secret **`ORTHANC_MIRROR_TOKEN`**: a fine-grained PAT scoped to `birotekno` with
*Contents: read & write* and *Administration: read & write* (repo creation).

## Two things that will bite you

**1. Pin git-cinnabar.** Cinnabar's hg→git conversion is *deterministic* — the same hg
changeset yields the same git SHA on any machine, with or without metadata. That is why
metadata loss is harmless here (unlike `hg-fast-export`, whose marks file is load-bearing:
lose it and every commit hash rewrites). But determinism holds **per cinnabar version**.
A version bump can change the mapping and rewrite history unattended. `CINNABAR_VERSION`
is pinned in the workflow and asserted at runtime. Upgrade deliberately: bump, run one
repo, compare SHAs, then roll out.

**2. Be a polite guest.** `orthanc.uclouvain.be` is one university's server. The bootstrap
is deliberately serial and CI is capped at 4 parallel jobs, once a day. Don't raise it.

## Testing

Verified end-to-end against live upstream on 2026-07-16 (`orthanc-gdcm`, 117 commits):

- **Fidelity** — `git cinnabar git2hg` on the converted tip returns `3b96baa5caa6`,
  identical to `hg identify` against the live server.
- **Determinism** — a clone with no metadata seeded produced byte-identical SHAs across
  all 10 branches.
- **Stateless CI path** — work dir deleted, metadata restored from GitHub alone: reports
  `[up to date]`, same SHAs.
- **Idempotency** — second run with no upstream change pushes nothing.
- **The fork-later guarantee** — a real commit pushed to `main`, then a sync run: `main`
  survived untouched.

## Licensing

Orthanc core is GPLv3; several plugins are AGPLv3. Mirroring is squarely within license.
Obligations attach on *distribution of modified binaries* — relevant when we fork and
ship, not for mirroring. Leave `COPYING` and license headers alone.
