---
name: release
description: >-
  Write ASUS ZenBook Linux Tools release docs for the version on the current
  branch by reviewing all changes (committed, staged, and unstaged vs the merge
  base). Use when the user asks for a release, release notes, changelog, GitHub
  release description, or to document the current version from the branch name.
---

# Release Docs

Produce release documentation for the **current branch version**, covering
**all** changes for that release. Do **not** tag, push, or `gh release create`
unless the user explicitly asks.

## Agent mandate (mandatory)

1. **Version from the current branch only** — parse `git branch --show-current`.
   Write that semver into **`VERSION`** (single source of truth, no `v` prefix).
   Sync `pyproject.toml` `tool.poetry.version`. Do **not** invent a version from
   tags or prior docs.
2. **Look at ALL changes** — every file and theme that lands in this release,
   not a subset. Include commits since the merge base **and** uncommitted /
   staged work still on the tree.
3. Write **both** release files under `docs/releases/`.
4. Reset `PPA_UPLOAD_REVISION` to `"1"` in `.github/workflows/ppa-release.yml`
   when `VERSION` itself bumps (keep a higher revision only when re-uploading
   the same `VERSION`).
5. Add a **new top** `debian/changelog` entry `asus-zenbook-linux-tools (${version})
   resolute` summarizing the release (historical older entries stay).
6. Update agent indexes (`AGENTS.md` current-version line, architecture skill
   tree, this skill) in the **same** change set.
7. **Amend the release-branch tip** so the **commit title and description** match
   the release (not a bare `vX.Y.Z` subject with an empty body). Prefer
   `git commit --amend` when the tip is the release commit; rewrite both the
   subject and the body from the release themes. Still **do not** amend, commit,
   or force-push unless the user explicitly asks in this turn — skill
   invocation alone is **not** authorization.

## Version from branch

```bash
branch="$(git branch --show-current)"
# Accept: feature/v1.0.1 | release/v1.0.1 | v1.0.1 | 1.0.1
version="$(printf '%s' "$branch" | sed -E 's#.*/##; s/^v//')"
# Canonical forms:
#   VER=1.0.1   (VERSION file + poetry)
#   TAG=v1.0.1  (docs, GitHub tag, install URLs)
```

Abort if `$version` is not `N.N.N` (semver digits). Do **not** fall back to
debian / tags / poetry.

Previous tag for compare links: latest `v*` tag older than this release
(usually `v` + prior patch), e.g. `v1.0.0` → `v1.0.1`.

## Bump project version (mandatory — single source of truth)

**Canonical version file:** repo-root [`VERSION`](../../../VERSION) (one line, e.g. `1.0.1`).

After resolving `$version` from the branch:

1. Write `$version` into **`VERSION`** (overwrite; first line only; no `v` prefix).
2. Set `pyproject.toml` `[tool.poetry] version` to the same string (`scripts/run-lints.sh`
   fails if they diverge).
3. Point human install URLs at tag `v$version` (`README.md` checksum one-liner,
   `docs/INSTRUCTIONS.md` `TAG=`, release notes). Do **not** put
   `NONINTERACTIVE_CHOICE` in those human snippets.
4. Bump TUI fallback pins in `bin/asus_install_selection_tui.py`
   (`or "vX.Y.Z"`) so a missing `ASUS_DISPLAY_VERSION` is not a stale older tag.
5. Reset `PPA_UPLOAD_REVISION` to `1` on a new `VERSION`.
6. Add a **new top** `debian/changelog` native entry for `$version`.

Historical `docs/releases/v1.0.0.md` and older changelog entries are archives —
leave them.

## Gather ALL changes (do not skip)

```bash
base="$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master)"
git log --oneline "$base"..HEAD
git diff --stat "$base"...HEAD
git diff --name-status "$base"...HEAD
git status --porcelain=v1
git diff --stat HEAD
git diff --cached --stat
```

**Completeness rules:**

* Cover **product** changes (installer, daemons, DE shortcuts, i18n).
* Cover **CI / Docker / scripts / workflows / PPA**.
* Cover **tests**, **docs**, **agent skills**, **packaging** when present.
* Group by theme; do not paste raw file lists as the release narrative.
* **Spell out ALL desktop families** when the release touches multi-DE support:
  GNOME, KDE Plasma, XFCE, LXQt, Cinnamon, MATE.
* Name the nine always-on distro lanes when the matrix or install path changes:
  Ubuntu 26.04, Debian trixie, Fedora 44, Rocky 10, openSUSE Tumbleweed,
  Arch latest, openSUSE Leap 16.0, AlmaLinux 10, Manjaro base.

## Output files

| File | Purpose |
| --- | --- |
| `docs/releases/vX.Y.Z.md` | Full release page (install + changelog) |
| `docs/releases/vX.Y.Z_github_description.md` | GitHub Release body (title line = H1) |

Mirror the tone of the latest prior files in `docs/releases/`. GitHub H1:

```markdown
# ASUS ZenBook Linux Tools vX.Y.Z - <Short Theme Title>
```

End the GitHub description with:

```markdown
**Full Changelog**: [vPREV...vX.Y.Z](https://github.com/ventura8/asus-zenbook-linux-tools/compare/vPREV...vX.Y.Z)
```

## Commit / amend (opt-in)

Prepare the release files **without** rewriting HEAD until the user asks.
Skill invocation alone is **not** authorization to commit or amend.

When the user asks to finish / amend the release commit:

1. Stage release docs, `debian/changelog`, version pins, and this skill update.
2. **`git commit --amend`** the release-branch tip (same change set) and **replace
   both the title and the description** so they summarize the release themes —
   not a lone `vX.Y.Z` subject with an empty body.
3. Title pattern (1 line, imperative / theme-focused), e.g.
   `v1.0.1: dynamic install progress and empty selection`.
4. Description: short bullets aligned with `docs/releases/vX.Y.Z.md` (progress,
   empty/`none`, DE i18n, PO lint, packaging/tests) — why and what shipped.

**Amend only when all are true:**

1. User explicitly confirmed amend (or “do it” / finish the release commit) in
   this turn.
2. `HEAD` is the release-branch tip and was created by this agent in this
   conversation, **or** the user explicitly requested amend of that commit.
3. The branch has **no upstream**, or the user also confirmed
   `--force-with-lease` after a warning.
4. Never `--no-verify`. Never force-push `main`/`master`.

If the user declines, leave HEAD unchanged and report that they must
commit/amend separately before tag / `gh release create`.

## Checklist

```text
Release progress:
- [ ] Version parsed from current branch only
- [ ] VERSION + pyproject.toml set to that version
- [ ] PPA_UPLOAD_REVISION reset to 1 (new VERSION) or left as re-upload bump
- [ ] debian/changelog top entry added
- [ ] Human install URLs / INSTRUCTIONS TAG updated
- [ ] ALL diffs vs merge-base + working tree reviewed
- [ ] docs/releases/vX.Y.Z.md written
- [ ] docs/releases/vX.Y.Z_github_description.md written
- [ ] AGENTS.md / architecture skill tree updated
- [ ] Commit title + description amended to match release themes (after user ask)
```
