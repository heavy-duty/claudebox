# Versioned installs, and a real uninstall (0.7.0 core)

**Status: implemented and tested.** 154/154 in `test/cli.sh` (which now
*drives* real installer runs, not greps of them), shellcheck clean, and CI's
rehearsal job installs via `install.sh` itself and ends with a zero-residue
uninstall drill on a live Incus. This doc records the design and why each
decision fell where it did.

## What was asked

Two maintainer requests, one PR:

1. **Install should be versioned** — each box version goes to its own folder
   and a tracked default names the one you run, like plenty of CLIs manage
   theirs. Before this, `install.sh` refused to touch an existing install at
   all: changing versions meant uninstalling by hand (`rm -rf` two paths from
   the README) and re-running the installer.
2. **Uninstall is flaky** — there was no uninstall verb at all, only prose;
   `teardown-host.sh` deliberately leaves the install tree; and nothing
   encoded the safe full-removal order (revoke users → teardown-host → remove
   trees/symlinks). Add thorough tests for uninstall, and for grant/revoke
   that they are clean.

## The layout

```
<root>/                       /opt/box (root) or ~/.local/share/box (user);
                              BOX_HOME overrides — both unchanged from #71
  versions/<version>/         one full tree per version, each with its own
                              VERSION + INSTALLED_FROM
  current -> versions/<v>     the tracked default (a relative symlink, so the
                              root can move as a unit)
$BINDIR/box -> <root>/current/bin/box
```

The version key is the tree's own `VERSION` file — the identity of what was
installed, and the name `box versions` lists. `bin/box` needed **no change**
to run from here: line 8 already derives `$root` via `readlink -f`, which
resolves the whole `$BINDIR/box → current → versions/<v>` chain, so
`VERSION`, `templates/`, `host/` and `drill/` all resolve inside the version
tree that is actually running. That same fact is how the new verbs detect
their world: a versioned install always runs from `.../versions/<v>`; a git
checkout does not, and the verbs refuse instead of uninstalling somebody's
working copy.

## Install semantics (#66's stance, kept — at the flip)

#66 established: a stray installer re-run must never clobber a working
install or rebuild the stack under existing boxes. The old enforcement was a
blanket "refuse if anything is installed", which also blocked upgrades. The
versioned layout splits the two concerns:

- **Same version present** → converging no-op ("already installed", exit 0);
  `BOX_REINSTALL=1` replaces that version's tree via two renames (never a
  partial overlay). A converge/reinstall of a non-current version never
  moves the default — switching is `box use`, a deliberate act.
- **Different version** → installs side-by-side, then flips `current` **only
  when no boxes exist**. With boxes present (both tag generations, checked at
  the caller's tier via a shared `existing_boxes()` — byte-identical in
  `install.sh` and `bin/box`, diffed by the tests so the two #66 stances
  cannot drift), the flip is refused loudly, the boxes are *named*, and the
  operator is pointed at the remedy: down/copy-out/rm, then `box use <v>`.
  A daemon that is absent or not answering has no boxes to protect — the
  stance guards boxes, not daemons.
- **Pre-0.7.0 flat tree** → migrated before anything else: `mv` the root
  aside, `mkdir versions/`, `mv` it to `versions/<its-VERSION>`, link
  `current` and `$BINDIR/box`. Two renames inside one parent directory — no
  copy, no window with no install, the operator's tree preserved bit for bit
  (the tests assert the migrated tree's own `INSTALLED_FROM` survives).
- **Wedged symlinks** → healed, never trusted. The old no-op check keyed off
  `$BINDIR/box` *or* `$DEST/bin/box` existing, so a stale symlink (or a
  half-removed tree) faked "already installed" forever. Installed-ness is now
  judged from `versions/<v>` itself; `ln -sfn` converges the links.
- **Tier coexistence** → a root and a per-user install shadow each other by
  PATH order alone; the installer warns when it sees the other tier's tree.
- Host setup is offered on **fresh** hosts only — an upgraded host has made
  that decision (and may have live boxes the stack must not be rebuilt
  under); `box setup-host` re-applies stack changes deliberately.

`BOX_INSTALL_SOURCE=<dir-or-tarball>` bypasses the download (a directory is
tar-copied with `--exclude=.git`). This exists for CI and the drill — the
code under review is what lands — and it is what turned the test suite's
install coverage from greps into real runs.

## The new verbs

Table rows like every other verb (the CMDS table stays the single source of
truth); `uninstall` joins the host-verb flag passthrough so `--all` /
`--purge-host` reach it.

- `box versions` — lists `versions/*`, marking the current default and the
  tree answering the command (they differ when another install shadows yours
  on PATH).
- `box use <version>` — same existing-boxes refusal as the installer's flip
  (shared helper, boxes named), then repoints `current`, converges every PATH
  symlink that resolves into this install root (never one that is somebody
  else's), and **asserts the effective result**: `current` must resolve to
  the asked-for version and `current/bin/box --version` must answer it. A
  flip that "worked" while the operator still runs the old tree is exactly
  the flakiness this verb exists to end.
- `box uninstall [<version>] [--all] [--purge-host]` —
  - one version: refuses the current one; removes the dir; re-checks it.
  - full: the safe order — refuse while boxes exist (naming them) unless
    `--purge-host` runs `teardown-host.sh` first (its own confirmation; a
    note names granted users' surviving projects and `revoke --purge` as the
    clean path); confirm (`--force` / `BOX_YES=1` — installer-family consent,
    deliberately *not* the lifecycle `confirm()`, which must never
    auto-accept from the environment); gather the removal set (root, every
    PATH symlink pointing into it, claudebox crumbs of both name
    generations); remove; then **the absence assert**: every path re-checked
    for file/dir/symlink existence, any survivor → exit 1
    `uninstall INCOMPLETE` naming the leftovers. `rm`'s exit code is not the
    verdict — the re-check is (a half-removed tree is INCOMPLETE, not a
    crash).

## Grant/revoke cleanliness

Reading `revoke-user.sh` against its own absence assert found the gap: the
purge removes `/var/lib/incus/users/<uid>` but never re-checks it — and the
stat was a bare `[ -d ]`, which lies for a non-root admin (`/var/lib/incus`
is not traversable, so the directory reads as absent while it is there).
Both fixed: the check rides `$SUDO test -d`, and the absence block now covers
the state dir. Grepped-and-guarded in `test/cli.sh`; drilled live in CI.

## Tests (the heart of this PR)

`test/cli.sh` stays dependency-free, non-root, daemon-free. New machinery: a
fake `incus` on PATH whose `list` prints `$FAKE_BOXES`, throwaway
`BOX_HOME`/`BOX_BIN` roots, and fabricated second/third sources with
different `VERSION`s. Driven end to end: fresh layout + chain
(`box --version` through both symlinks), no-op/canary, `BOX_REINSTALL`,
side-by-side + no-boxes flip, all three #66 refusals (install flip, `use`,
`uninstall` — boxes named, remedies named), `versions` markers, `use`
flip-and-assert, flat-tree migration (alone, and combined with an upgrade),
dangling- and stale-symlink healing, single-version uninstall (current
refused), full uninstall with planted legacy crumbs and a zero-residue
assert (files *and* symlinks *and* legacy names), the INCOMPLETE scream
(a chmod-pinned survivor), and refusals from a working tree. The existing
DEST/BINDIR-branch tests are kept unchanged (the branch itself is unchanged).

CI's rehearsal job now installs via `install.sh`
(`BOX_INSTALL_SOURCE=$GITHUB_WORKSPACE`), asserts the layout it left, runs
the stack from `/opt/box/current/...`, and appends the uninstall drill:
grant + `revoke --purge` a throwaway user (asserting the incus-user state
dir is gone), `teardown-host` (new `--yes`/`BOX_YES` support), `box
uninstall --all`, then zero residue — networks, profiles, ACLs, nft tables,
systemd units, files, symlinks, both name generations.

## What this is not

- Not #67: boxes still do not migrate across versions — this PR delivers the
  version-agnostic upgrade *path* (side-by-side installs, an explicit flip);
  data migration remains #67.
- Not a release: `VERSION` is untouched (a release PR bumps it).
