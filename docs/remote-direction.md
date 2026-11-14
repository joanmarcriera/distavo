# Distavo remotes: which way code flows, and what to merge (9 Nov 2026)

Task: https://familia.riera.co.uk/tasks/1925. Facts checked 2026-11-09 12:10 UTC with `git ls-remote --heads`
on each remote and the Forgejo API (`GET /api/v1/repos/marc/<repo>`). Re-check before acting; this is a snapshot.

## The three remotes

| Remote (local name) | URL | Role | Who writes |
|---|---|---|---|
| `origin` | `git@github.com:joanmarcriera/distavo.git` | **Primary.** `main`, release tags, GitHub Actions (CI and release workflows are `workflow_dispatch`, plus tags for CI on `ci/tag-ci`). | Marc only. Drive lanes never push here. |
| `forgejo` | `git@git.riera.co.uk:marc/distavo.git` | **Read-only pull mirror of GitHub** (API: `mirror: true`, `original_url` = the GitHub repo, interval 8 h, last sync 2026-11-09 06:30Z). A push is refused ("Mirror Repository ... is read-only"). | Nobody. It follows `origin`. |
| `forgejo-work` | `git@git.riera.co.uk:marc/distavo-work.git` | **Private work repo** for drive/agent branches (API: `mirror: false`, `private: true`, no push mirrors). | Drive lanes push `feat/drive-*` branches here (grant G2). |

So code flows: lanes → `forgejo-work` (branches) → Marc merges into local `main` → `git push origin main` (GitHub)
→ the `forgejo` mirror pulls it within 8 h (or on "Synchronise now" in the Forgejo UI).

The old ci.yml comment "GitHub is a push mirror only" was the cause of the confusion in #1925; ci.yml, version-bump.yml
and `docs/release-automation.md` were corrected on 25 Oct. This page is the one-page map.

## Branch inventory

`main`: `origin/main` = `forgejo/main` = `e6d36b6` (merge of PR #16, `cloud/codex-fixes-2026-10-31`).
A local `main` that is behind must be fast-forwarded first (`git merge --ff-only origin/main`).

**On `forgejo-work` (23 branches):** every one is an ancestor of `feat/drive-distavo-o-2026-11-09` (`a3199c1`),
and every one forks from `16003f8` (the main before PR #16). None is merged into `main`.
`feat/drive-distavo-p-2026-11-09` (this lane) sits on top of `o`. Merging the newest branch of the chain
merges all of them; the older branches are history, not separate merges:
`2026-11-07`, `advice-template`, `advice-review-2026-11-07`, `codex-2026-11-07`, `codex-review-2026-11-07`,
`corrections-2026-11-07`, `corrections-review-2026-11-07`, `channel-speakers`, `integ-2026-11-07`, `b`…`n`, `o`.
`git merge-tree --write-tree e6d36b6 a3199c1` exits 0: `o` merges into today's `main` without conflicts.

**On `origin` (and mirrored to `forgejo`), not merged into `main`:**

| Branch | Commits | Merges onto `o` | Note |
|---|---|---|---|
| `ci/gitleaks-gate` | 2 (secret-scan gate, actions pinned) | clean | #1846. Decide push-trigger vs dispatch-only first. |
| `ci/tag-ci-2026-10-26` | 1 (CI on `v*` tags) | clean | #4086 |
| `cloud/trust-rows-1-3-2026-11-02` | 2 (keep complete `.wav.part`; colliding sanitised bases) | clean | Review by eye: overlaps the pipeline/state work in the drive chain. |
| `claude/review-2026-11-09` | 3 (script error handling, docs, crash-risk review) | clean | Pushed to GitHub today by another session. |
| `feature/2955-direct-power-features` | 8 (CLI, loopback MCP, Import from URL) | **conflicts** in `Config.swift`, `StatusMenu.swift` | Parked since 5 Oct (#2955). Not in this merge round. |

Already merged (nothing to do): `cloud/codex-fixes-2026-10-31`, `fix/1.19.0-ci-compile`, `release/1.19`.

## Merge checklist for Marc (in order)

Do this in a clean checkout (the main checkout `~/Development/Project/distavo` is on `feat/drive-distavo-d-2026-11-08`
with an untracked `.archify/`; that is fine for `git switch` as long as `git status` shows nothing else).

- [ ] 1. Run the by-eye checks listed in `docs/drive-review-2026-11-09.md` (signed build) and take its decisions A–C.
- [ ] 2. Update and fast-forward main:
  `cd ~/Development/Project/distavo && git fetch origin && git fetch forgejo-work && git switch main && git merge --ff-only origin/main`
- [ ] 3. Merge the drive chain (p contains o, n … j and every older drive branch):
  `git merge --no-ff forgejo-work/feat/drive-distavo-p-2026-11-09`
  (if you do not want p's commits, merge `forgejo-work/feat/drive-distavo-o-2026-11-09` instead).
- [ ] 4. Test before pushing:
  `cd apple/DistavoCore && swift test; cd ../DistavoEmbedded && swift test; cd ../..`
- [ ] 5. Push main to the primary: `git push origin main`
- [ ] 6. Optional, each its own decision, each followed by `swift test` and a push:
  `git merge --no-ff origin/ci/tag-ci-2026-10-26`,
  `git merge --no-ff origin/cloud/trust-rows-1-3-2026-11-02`,
  `git merge --no-ff origin/claude/review-2026-11-09`,
  `git merge --no-ff origin/ci/gitleaks-gate`. Leave `feature/2955-direct-power-features` (conflicts).
- [ ] 7. Let the mirror catch up, then confirm: `git ls-remote forgejo refs/heads/main` equals `git rev-parse main`
  (or press "Synchronise now" at https://git.riera.co.uk/marc/distavo/settings).
- [ ] 8. Optional tidy after the merge: the `feat/drive-*` branches on `forgejo-work` can stay as history; deleting
  them is yours to decide (`git push forgejo-work --delete <branch>`).
