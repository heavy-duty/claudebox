# Changelog

History before 0.5.0 lives in git and in [drill/RUNS.md](drill/RUNS.md),
which records not just what changed but what each drill run proved.

## Unreleased

### Changed

- Release and repository governance now use the shared ceremony pinned at `0.1.0` (heavy-duty/ceremony#14)

### Added

- `kimi-box` template — the Moonshot Kimi CLI agent seed (#158; rig#109's tenant)

## 0.9.0 — 2026-07-21

### Added

- `box import` stamps the trip, leaving the artifact's own mint stamp intact
  (#131)
- A minted box records how it was minted, and `box info` reads it back (#103)
- A clone re-stamps its own provenance instead of inheriting its source's
  (#103)
- `box info` grew a provenance block, blank on boxes that predate the stamp
  (#103)
- Every fresh mint marks a `pristine` snapshot, before rig converges anything
  (#104, heavy-duty/rig#62)
- A mint that converges a tenant role marks a `bootstrapped` snapshot (#130)
- CI refuses a release PR with no drill record at `drills/<version>.md`

### Changed

- `state:needs-human` is set at handoff, not by the cron (#141)
- PR labels split into two axes: `state:*` (whose ball) and `blocker:*` (what
  is in the way); `state:needs-rebase` is retired
- BREAKING: the tenant templates carry rig's family suffix — `claude` →
  `claude-box`, `codex` → `codex-box`, `grok` → `grok-box`, `staging` →
  `staging-box` (#123, heavy-duty/rig#76)
- Changelog entries are one line each, and the whole file now follows the rule
  (#147)

### Fixed

- `test/release.sh` is green on the release ceremony's own tree
- `changelog-monotonic.sh` no longer lets a duplicate heading through when it
  cannot see the base (#143)
- An unreadable check rollup no longer reads as "nothing is failing"
- `state:needs-human` no longer appears on PRs a human cannot merge (#136)
- CI's shellcheck sweep now lints `.github/scripts/*.sh` (#116)
- A PR can no longer delete or duplicate a shipped changelog section and stay
  green (#122)
- An upgrade over a pre-0.7.0 flat `/opt/box` no longer skips host setup (#115)
- Host setup runs the version it just installed, not whatever `current` points
  at (#115)
- The pre-0.7.0 migration says what it left behind, and how to keep or reap it
  (#117)
- `teardown-host.sh` refuses a terminal-less run instead of aborting mute
  (#113)
- `drill/wipe.sh` no longer carries #102's SIGPIPE shape, and the pin sweeps
  the class (#107)
- The racing-reader sweep guards the class, not one spelling, and names
  `incus config trust list` as a second writer (#124)

## 0.8.0 — 2026-07-19

### Added

- Merging the release PR is the release, and the release re-arms main itself
  (#96)

### Fixed

- The release ceremony re-arms `CHANGELOG.md`, and CI refuses to let main sit
  disarmed (#108, heavy-duty/rig#67)
- Ctrl-D at a confirmation prompt aborts out loud instead of exiting in
  silence (#111)
- `box restore` asks before it destroys, in the row's own words rather than
  `rm`'s (#105)
- `box-firewall` could hand a UFW host the no-UFW firewall, ~2% of the time
  (#102)
- A missing firewall log now diagnoses itself (#102)
- `box grant` provisions an `incus-admin` member instead of refusing them
  (#99)

## 0.7.0 — 2026-07-19

### Added

- The installer defaults to the latest release, and releases publish
  themselves (#83)
- `setup-host` auto-picks a free subnet — nested box-in-box with zero flags
  (#80)
- `setup-host` refuses a claimed subnet, and `BOX_SUBNET` picks another (#80)
- `box doctor` knows the #80 signature: a gateway held as a local address, and
  duplicate connected routes for the uplink subnet
- The `staging` template — a server-class, creds-free seed (#81)
- The `BOX_BOOTSTRAP_ROLE` template key, auto-run at mint (#81)
- The rig pin point: `RIG_REPO` / `RIG_REF` (#81)
- Server-posture template keys `BOX_REQUIRE_VM` and `BOX_AUTOSTART` (#81)
- The template test suite discovers `templates/*/` instead of hardcoding the
  list (#81)
- `box export` / `box import` — a box's state that survives the box and the
  host (#70)
- Versioned installs at `<root>/versions/<v>`, with `box versions` and
  `box use` (#66)
- A real uninstall: `box uninstall [<version>] [--all] [--purge-host]`, ending
  in an absence assert
- `BOX_INSTALL_SOURCE=<dir-or-tarball>` installs from a local tree, and CI's
  rehearsal drills the uninstall to zero residue
- `test/cli.sh` drives real installs against throwaway roots and a fake incus
  (154 checks)

### Changed

- Thin templates — box mints a creds-free seed, rig's bootstrap roles converge
  the tenant content (#81, heavy-duty/rig#31)

### Fixed

- A wedged `incus launch` fails loudly, not forever: the launch phase is
  narrated and time-boxed (#93)
- UFW's gateway carve-out converges with the bridge, and the doctor can see it
  (#86)
- The boot-time gateway fallback is gone — an unaddressed bridge leaves the
  persisted UFW rules alone (#86)
- `revoke --purge` re-checks the incus-user state, and stats it through
  `$SUDO`
- A wedged `$BINDIR/box` no longer blocks installing

## 0.6.0 — 2026-07-18

### Added

- The restricted tier: `box grant` / `box revoke` give a user their own boxes
  on the shared hardened `boxnet` (#74)
- CI runs the multi-user rehearsal on a real Incus
- Global / root install — one world-readable tree at `/opt/box` (#71)
- CI and a test suite: `.github/workflows/ci.yml` and `test/cli.sh`

### Fixed

- `box restore` never worked against Incus 6 — it dispatched `incus restore`,
  which does not exist
- `box tmux` works on every template — tmux is in each template's package list
  (#65)
- `box setup-host` finishes in one run, re-execing itself under
  `sg incus-admin` (#63)
- `setup-host` works as root, with or without `sudo`
- `setup-host` grants `incus-admin` to the human, not to root
- `box-firewall.service` reports its state honestly, via `RemainAfterExit=yes`
- `setup-host`'s apt calls can no longer hang on the dpkg lock

### Changed

- `drill.sh` asserts the post-install stack instead of building it itself
- `install.sh` asks, sets up the host, and no-ops on re-run (#64)
- `install.sh` never overwrites an existing install

## 0.5.0 — 2026-07-15

The release the project was renamed in: the repo is `heavy-duty/box`, matching
the CLI it ships. Everything legacy-facing is honored forever — the
`user.claudebox=1` tag, the `.claudebox/` runbook folder, the old symlink the
installer retires — but nothing current carries the old name.

### Added

- `codex` and `grok` templates
- `box expose <box> <port> [<host-port>]` — a loopback-only door to a port
  inside a box
- Inline resource overrides on `new`: `--cpu`, `--memory`, `--disk` (#57)
- Host lifecycle as verbs: `box setup-host`, `box teardown-host`,
  `box migrate-host`
- The `.box/` recipe convention, renamed from `.claudebox/` (both spellings
  read)

### Fixed

- VM mints no longer hang at GRUB — boxes launch with
  `security.secureboot=false`
- `box expose` actually delivers packets
- Firewall rules converge on upgrade instead of pinning a host to the release
  that first ran there
- Failed mints tell you why
- `grok` installs the binary it actually ships

### Changed

- Debrand complete — env vars, install dir, docs, template descriptions and
  the README all say `box`; the install URL is `heavy-duty/box`
- The drill grew from 47 to 84 checks
