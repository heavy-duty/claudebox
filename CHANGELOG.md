# Changelog

History before 0.5.0 lives in git and in [drill/RUNS.md](drill/RUNS.md),
which records not just what changed but what each drill run proved.

## Unreleased

### Added

- **`setup-host` auto-picks a free subnet — nested box-in-box with zero
  flags** (#80, completing its fix #1: "refuse … or automatically select a
  non-colliding subnet"). A bare `box setup-host` now decides the subnet
  itself, in four deliberate cases: an explicit `BOX_SUBNET` is honored or
  refused, never silently overridden (scripted hosts keep exact semantics);
  an existing `boxnet` bridge is converged on as-is — the bridge IS the pin —
  turning the old bare-re-run agree-gate refusal into plain convergence
  (unless a foreigner *also* claims the bridge's subnet: that is #80's
  poisoned state, and converging would rebuild on it, so it still refuses and
  names the bridge move); a free `10.88.0.0/24` stays the default; and a
  *claimed* default — the nested case: a drill or rehearsal running inside a
  box, whose own uplink owns 10.88 — scans `10.89.0.0/24` … `10.127.0.0/24`
  in order, takes the first free candidate, announces the pick and the
  claimant loudly, and only refuses when every candidate is claimed. The
  decision happens before any mutation, and everything downstream (the
  bridge, `BOX_GW`, the ACL's gateway carve-out, the firewall, the doctor's
  expectations) derives from it.
- **`setup-host` refuses a claimed subnet, and `BOX_SUBNET` picks another**
  (#80) — run inside a box, `setup-host` used to build a nested `boxnet` on
  the exact subnet and gateway of the guest's own uplink: the guest then held
  its gateway's address as a *local* address, carried duplicate connected
  routes for its uplink subnet, and suffered intermittent, self-recovering
  egress blackouts that looked like flaky internet (measured live: ~24–36 s
  outages, roughly hourly, with the host clean throughout). `setup-host` now
  scans the target subnet **before any mutation** — the default route's
  gateway inside it, or any non-`boxnet` interface holding an address in it —
  and refuses, naming the way out. A prior `boxnet` owning the subnet is the
  legitimate converge path and does not trip it. `BOX_SUBNET=<a.b.c.0/24>`
  (validated, alongside the existing `BOX_DNS`) moves the whole stack: the
  bridge address, the ACL's gateway carve-out (now converged via
  `network acl edit`, so a bridge moved off a colliding subnet no longer
  strands box DNS behind a stale `/32`), the firewall (`box-firewall` reads
  the gateway off the live bridge), and every drill/migrate probe that used
  to hardcode `10.88`.
- **`box doctor` knows the #80 signature** — a default gateway held as a
  LOCAL address, and duplicate connected routes for the uplink subnet, judged
  from `ip route`/`ip addr` on the machine doctor runs on (both tiers, before
  any daemon check — the nested daemon answering could be the impostor) and
  probed *inside* every box it examines. The existing "egress broken but DNS
  fine" split now names itself as #80's fingerprint (the impostor dnsmasq on
  a captured gateway keeps resolving while IP egress dies), and the admin ACL
  section verifies the gateway carve-out matches `boxnet`'s actual gateway.
  The agent-context guard for the templates (suggested fix 4) lands in
  heavy-duty/rig#31's bootstrap roles per the thin-templates split (#81).

- **The `staging` template** (#81, the re-cut of #69's layering) — a
  server-class, creds-free seed: Debian 13, user `ops`, tmux, rig,
  `BOX_REQUIRE_VM=1` (the VM is its trust boundary), `BOX_AUTOSTART=1` (a
  server returns from a host reboot without an operator), and
  `BOX_BOOTSTRAP_ROLE="staging"` — the server posture (docker, sshd
  hardening) converges via `rig bootstrap staging` after mint. The tailnet
  workload join holds a pre-auth key and therefore **stays operator-run**
  (`box shell` → `sudo rig bootstrap workload`), printed as a next step —
  box never sees the key.
- **`BOX_BOOTSTRAP_ROLE` template key + mint-time auto-run** (#81) — a
  template names the **creds-free** rig tenant role box runs inside the guest
  after cloud-init settles (`incus exec … rig bootstrap <role>`); the value
  is a role *name* by allowlist (anything shell-shaped dies at parse time, on
  the host). A failed role leaves the box up and names the re-run — the roles
  are convergent by contract (rig#31). `blank` names no role and auto-runs
  nothing.
- **The rig pin point: `RIG_REPO` / `RIG_REF`** (#81) — the tenant seeds
  preinstall rig, inverting the rig→box install edge (rig#28), and the new
  edge gets the same honest treatment rig#29 gave box's unpinned install:
  `@RIG_REPO@`/`@RIG_REF@` tokens in the seed resolve at mint from the
  environment (default `heavy-duty/rig` @ `main` — unpinned, tracking main,
  until a release flow exists, rig#32/#83). The pin covers both the installer
  fetched and the tree it installs, so a rig branch under review is testable
  end to end; values are allowlist-validated before touching the YAML.
- **Server-posture template keys** (#81, carved from #69) — two optional
  `box.env` allowlist keys. `BOX_REQUIRE_VM=1` refuses both the silent
  container fallback (no `/dev/kvm`, exit 1) and an explicit `--container`
  (exit 2): such a template's trust boundary is the VM. `BOX_AUTOSTART=1`
  stamps `boot.autostart=true` at launch, per-instance like `limits.*`, so
  the box returns from a host reboot without an operator; clones inherit it
  via `incus copy`. Still no key for a network or a `security.*` flag, on
  purpose.
- **Dynamic template test suite** (#81, carved from #69) — `test/cli.sh`
  discovers `templates/*/` instead of hardcoding the list, so a new template
  cannot ship unseen. Per template: `box.env` is driven through the real,
  extracted `load_template` (unknown keys and missing `BOX_IMAGE`/`BOX_USER`
  fail, fixtures proving both dies); `user-data.yaml` exists, declares
  `#cloud-config`, parses as YAML, and installs tmux (#65). Grep guards pin
  the `cmd_new` half: the `REQUIRE_VM` refusal orders after `pick_mode`, and
  `boot.autostart` is stamped only under the `T_AUTOSTART` guard.
- **`box export` / `box import`** (#70) — a box's state that survives the box
  _and_ the host, unblocking #66's humane upgrade flow (down, export, rm,
  upgrade, re-import). `box export <box> [<file>]` wraps `incus export` into
  one portable backup tarball (default `<box>-<UTC stamp>.tar.gz`), snapshots
  included by default (`--instance-only` opts out); the box must be stopped
  first (`box down`) so the artifact is a settled disk, not a moving one. The
  file is **shouted about, not scrubbed** — it carries the box's whole disk
  (agent logins, git credentials, SSH keys), and scrubbing a disk image is a
  promise tarball surgery cannot keep, so box says what is inside instead,
  every time. `box import <file> [--name <box>]` mints the box back and
  re-stamps what is the _current host's_ truth, not the artifact's: the
  `user.box=1` boundary tag (legacy `user.claudebox=1` honored), the
  `box-net` placement (re-assigned if the artifact's differs — the
  migrate-host move), and a fresh machine identity: the NIC's MAC (imports
  restore `volatile.*` verbatim, and a re-import beside its sibling collided
  at start with "MAC address already defined on another NIC" — measured
  live; `incus copy` regenerates it, `incus import` does not) plus
  `reset_identity` (the clone trust boundary: no DHCP collision with the box
  it was exported from).
  Import refuses any name an existing instance holds — the `resolve_box`
  boundary, seen from the other side. Works on both tiers: `box grant` now
  also converges `restricted.backups allow` (incus-user blocks backups by
  default exactly like snapshots, and an export _is_ a backup
  create+download — measured against incus 6.0's `permissions.go`); re-run
  `box grant <user>` after upgrading, as documented. CI's `rehearsal` job now
  proves the round-trip on a live Incus: mint → write a file → snapshot →
  down → export → `rm` → import → the file and the snapshot survived, the
  agent answers, the tag is present, and a colliding re-import is refused.
- **Versioned installs** (#66's stance, made livable) — install.sh now lands
  each version side by side at `<root>/versions/<v>` (its own `VERSION` +
  `INSTALLED_FROM`), with a `current` symlink tracking the default and
  `$BINDIR/box` riding the chain, the way plenty of CLIs manage theirs. New
  verbs: `box versions` (lists installs, marks the current default and the
  running tree), `box use <version>` (flips the default, converges the PATH
  symlinks, and *asserts the effective result* — `current` must resolve to
  the asked-for version and the chain's `box --version` must answer it).
  Re-running the installer with an installed version is a converging no-op
  (`BOX_REINSTALL=1` replaces that version's tree); a **new** version installs
  side-by-side and flips `current` only when no boxes exist — under existing
  boxes the flip is refused loudly, naming the boxes (#66: never change
  versions under a user's boxes; `box use` keeps the same refusal). A
  pre-0.7.0 **flat tree is migrated in place** (two renames, the operator's
  tree preserved bit for bit), so upgrading from 0.6.0 is seamless; a stale
  or dangling `$BINDIR/box` is healed instead of wedging the install; and the
  installer warns when the *other* tier's install (/opt/box vs ~/.local)
  coexists, since PATH order decides which wins.
- **A real uninstall** — `box uninstall [<version>] [--all] [--purge-host]`
  replaces the "rm -rf two paths" prose. One version: refuses the current one
  (`box use` off it first). Everything: runs in the safe order — refuses
  while boxes exist (naming them) unless `--purge-host` runs teardown-host
  first — then removes every version, the `current` and PATH symlinks, and
  the legacy claudebox crumbs (both name generations), and **ends with an
  absence assert**: every removed path is re-checked, and any survivor makes
  it exit 1 as `uninstall INCOMPLETE` naming the leftovers (the
  `revoke --purge` discipline). `teardown-host.sh` gains `--yes`/`BOX_YES=1`
  for automation and now points at `box uninstall` when done.
- **`BOX_INSTALL_SOURCE=<dir-or-tarball>`** — installs from a local tree,
  bypassing the download. CI's rehearsal job now installs via install.sh
  itself (proving the installer under review, not a `cp -r` mimic of it), and
  ends with an **uninstall drill**: grant + `revoke --purge` a throwaway
  user, `teardown-host`, `box uninstall --all`, then assert **zero residue**
  — no networks, profiles, ACLs, nft tables, systemd units, files or
  symlinks.
- **test/cli.sh drives real installs** — still dependency-free, non-root, no
  daemon: `BOX_INSTALL_SOURCE` + throwaway `BOX_HOME`/`BOX_BIN` roots and a
  fake `incus` on PATH (`$FAKE_BOXES`) turn layout, chain, no-op/converge,
  reinstall, side-by-side upgrade, the three #66 refusals (install flip,
  `use`, `uninstall` — boxes named), flat-tree migration, symlink healing,
  single-version and zero-residue uninstalls, and the `INCOMPLETE` scream
  into *driven* tests instead of greps (154 checks).

### Changed

- **Thin templates — box mints, rig converges** (#81, companion rig#31) —
  the tenant content that lived in `claude`/`codex`/`grok`'s cloud-init (the
  agent CLI installs, docker, node, the per-template agent-context heredocs)
  **moves to rig's bootstrap roles**, where it is convergent, idempotent and
  testable end to end instead of parse-only YAML. What remains per template
  is a thin, creds-free seed: the tenant user, tmux (#65), and rig
  preinstalled — nothing that joins a tailnet or admits credentials. The #80
  agent-context guard ("never run `box setup-host` or the drill inside a
  box") now lives once, in rig's roles, not copy-pasted per template. The
  template test sweep grew the contract's teeth: per-template seed asserts
  (user matches, rig pinned via both tokens) and fail-closed **absence
  greps** over effective cloud-init lines — no agent CLI, no docker, no
  tailscale/authkey/ssh, no `write_files` heredocs — so tenant content
  cannot quietly grow back.

### Fixed

- **UFW's gateway carve-out converges with the bridge, and the doctor can
  see it** (the #86 review's blind spot) — `box-firewall` gated its whole
  UFW block behind "a `DENY on boxnet` rule exists", pinning every UFW host
  to the gateway of the *first* run: a bridge remapped off a colliding
  subnet (#80's escape hatch) kept its stale `allow … to <old-gw> port 53`
  and never gained the live gateway's, so box→gateway DNS died at box's own
  deny — while the doctor's carve-out check read only the incus ACL (which
  setup-host converges) and called the host clean. The UFW allows now
  converge off the live bridge address on every run (stale DNS allows
  deleted, the live set ensured — ufw skips existing rules, so a fresh host
  gets the identical rule set and a re-run is a no-op), and `box doctor`
  reads UFW's own table wherever UFW is active, flagging a DNS allow that
  does not match `boxnet`'s gateway (and stale allows left beside a live
  one). The no-UFW nft carve-out never had this failure mode: it is
  interface-scoped, no gateway address to go stale.
- **The boot-time gateway fallback is gone — no rule beats a wrong one** —
  with the bridge not yet addressed when `box-firewall.service` ran,
  `box-firewall` guessed `GW=10.88.0.1`; on a `BOX_SUBNET` host that hit
  that window the UFW carve-out was built for the wrong gateway, a latent
  DNS drop (#86 review). It now fails closed: an unaddressed bridge leaves
  the persisted UFW rules exactly as they are (they survive boots on their
  own, and nothing else in the script needs the gateway) and says so on
  stderr; the next setup-host run or service restart converges them once
  the bridge is addressed.
- **`revoke --purge` re-checks the incus-user state** — the purge removed
  `/var/lib/incus/users/<uid>` without ever asserting its absence, the one
  path its own absence block did not cover; and the stat now rides
  `$SUDO test -d` (`/var/lib/incus` is not traversable by a non-root admin,
  so a bare `[ -d ]` answered "absent" for a directory that was there).
- **A wedged `$BINDIR/box` no longer blocks installing** — the old
  no-op-if-installed check keyed off the symlink's existence OR the tree's,
  so a stale symlink (or a half-removed tree) could fake "already installed"
  forever. Installed-ness is now judged from `versions/<v>` itself; symlinks
  are converged with `ln -sfn`, never trusted as the signal.

## 0.6.0 — 2026-07-18

### Added

- **The restricted tier: multi-user hosts** (#74, redesigning #72) — an admin
  runs `box grant <user>` and that user gets their own boxes on the same
  hardened `boxnet`, seeing nobody else's; `box revoke <user>` takes it back
  (`--purge` deletes their world, and asserts the absence). The tier rides
  incus-user, whose defaults miss box's contract three measured ways (Debian
  13 / Incus 6.0.4): a private _unhardened_ NAT bridge per user, snapshots
  blocked, the `box-net` profile invisible — so grant is an idempotent
  convergence: project narrowed to `boxnet` **and only boxnet** (listing the
  private bridge too, the obvious fix, would keep an unhardened network one
  `--network` flag away), snapshots allowed, the shipped profile installed
  into their project. `box_tier()` (live credentials, argless `id -nG`)
  drives the tier-aware surface: `expose` refuses honestly before any daemon
  call, `setup-host` and `doctor` answer at the caller's tier. Rehearsed
  end-to-end by `drill/multiuser.sh` (criteria a–n: confinement, lifecycle,
  cross-user visibility, name collisions, the in-box isolation contract,
  escape hatches, re-sync survival, revoke incl. the live-session case) —
  54/54 on the design host (container and VM mode), including the raw-attach scoped-guarantee measurement and both grant-failure injections demanded by #75's review.
- **CI runs the multi-user rehearsal on a real Incus** — a second `rehearsal`
  job stands up the full stack on the runner (setup-host, doctor, then
  `multiuser.sh --container`), so every PR proves the tier's semantics
  against a live daemon, not a mock. The VM trust boundary itself remains a
  real-hardware ritual, like the full drill.
- **Global / root install** (#71) — run as root, box installs _once_ to
  `/opt/box` (world-readable) with the `box` symlink on `/usr/local/bin`, so
  every operator on a shared host runs the same tree. Per-user installs are
  unchanged (`$HOME/.local`); `BOX_HOME`/`BOX_BIN` still override. A per-user
  tree under `/root` is `0700` and unreadable to everyone else — the whole fleet
  got `command not found` — so the root branch lands in a system location and
  `chmod -R a+rX`'s it (read for files, +search on dirs), guarded on root. This
  unblocks "rig installs box" (rig#24's `box` role).
- **CI + a test suite** — `.github/workflows/ci.yml` (a `check` job: globstar
  `shellcheck -x` over `bin/* **/*.sh`, then `bash test/cli.sh`) and `test/cli.sh`,
  dependency-free and runnable by a non-root user with no Incus. It exercises the
  `install.sh` DEST/BINDIR branch functionally (both tiers + `BOX_HOME`/`BOX_BIN`
  overrides), the CLI contract, and grep-guards the daemon-gated invariants and
  tmux in every template — the box was the repo with "no tests and no CI".

### Fixed

- **`box restore` never worked against Incus 6** — the command table
  dispatched `incus restore`, a subcommand that does not exist (Incus 6
  spells it `incus snapshot restore`), so every restore died on "unknown
  command". Found by #74's rehearsal exercising the full lifecycle as a
  restricted user; fixed for every tier, and the rehearsal + a grep-guard in
  `test/cli.sh` now hold it.
- **`box tmux` works on every template** (#65) — `box tmux` runs
  `tmux new-session` _inside_ the box, but the templates did not install tmux, so
  it failed with `tmux: command not found`. `tmux` is now in each template's
  cloud-init package list (`blank`/`claude`/`codex`/`grok`).

- **`box setup-host` finishes in one run** (#63). When it had to add you to
  `incus-admin` it stopped there and told you to re-login and re-run — an
  `exit 0` that reported success having built none of the stack: no `boxnet`,
  no ACL, no `box-net` profile, no firewall. It now re-execs itself under
  `sg incus-admin` and completes in that one invocation. The membership check
  was also asking the wrong question: `id -nG "$USER"` reads the group
  database, which lists the group the moment `usermod` returns, so a
  same-session re-run passed the check with credentials that still lacked the
  group and died further down on a bare permission error from `incus`. Argless
  `id -nG` asks the process what it actually holds.

- **`setup-host` works as root, with or without `sudo`** — every privileged
  call was a hardcoded `sudo`, so on a minimal root image (no `sudo` package)
  it died on `sudo: command not found` before doing anything. Privilege is now
  resolved once: nothing at UID 0, `sudo` otherwise, and a clear error if
  neither is possible. This is what made `install.sh`'s root path real rather
  than nominal.
- **`setup-host` grants `incus-admin` to the human, not to root** — under
  `sudo install.sh` it would have added `root` to the group: a no-op (UID 0
  opens the socket regardless) that also left the actual user locked out of
  their own boxes. It now derives the login user from `SUDO_USER`.
- **`box-firewall.service` now reports its state honestly** — the unit is
  `Type=oneshot` and was missing `RemainAfterExit=yes`, so it went
  `inactive (dead)` the instant it succeeded: a host whose isolation was
  perfectly live read as one whose firewall unit had died. drill.sh sends you
  to `systemctl status box-firewall` to diagnose exactly that, and
  setup-host.sh's own comment already asserted the unit "is RemainAfterExit" —
  it was not. Found by running the drill on a real host and mistrusting the
  green: `nft list table bridge box` showed the drop live while the unit read
  dead. `restart` was and remains correct either way.
- **`setup-host`'s apt calls can no longer hang** — a fresh cloud image has
  `apt-daily`/`unattended-upgrades` holding the dpkg lock, and a plain
  `apt-get install` waits on it silently and indefinitely. Now bounded
  (`DPkg::Lock::Timeout=300`) and non-interactive, which matters because
  `install.sh` runs it with nobody watching.

### Changed

- **`drill.sh` proves the new contract instead of masking it** — the drill ran
  `setup-host` itself right after installing, so the stack existed by its own
  hand and a run passed identically whether or not `install.sh` had done a
  thing; a fresh run converged the stack three times, while the messages still
  described the pre-#63 "first pass may only add you to the group" behaviour.
  It now asserts the post-install stack in-group before touching the host, and
  runs `setup-host` exactly once more — after the clean, which deliberately
  unsets `dns.mode` and so has to be converged back. `DRILL_OWNS_SETUP=1`
  hands sequencing back to the drill. Pre-setup tripwires now read _before_
  `install.sh`, since that is what triggers setup now.
- **`install.sh` asks, sets up the host, and no-ops on re-run** (#64) — it now
  prompts _"Install box?"_, then on a fresh host installs the tree and asks a
  second question, _"Set up this machine as a box host now?"_, running the whole
  isolation stack if you say yes (previously it only printed a warning and left
  you a command, so the install reported success and `box new` died on a host
  with no Incus). Prompts read `/dev/tty`, since under `curl | bash` the script
  itself is stdin; `BOX_YES=1` answers yes unattended (required where there is
  no terminal), `BOX_SKIP_SETUP_HOST=1` declines the host-setup step.
- **`install.sh` never overwrites an existing install** — if box is already
  installed it says so and changes nothing, so a stray re-run can no longer
  clobber a working tree or rebuild the host stack under live boxes. Upgrading
  is explicit: uninstall (`rm -rf ~/.local/share/box ~/.local/bin/box`, boxes
  preserved first) and install fresh. This replaces the earlier version-diff
  refusal with a simpler rule that dissolves the same class of errors. The
  version-aware upgrade that migrates boxes instead is #67; a portable
  `box export` so a box survives its own deletion is #70.

## 0.5.0 — 2026-07-15

The release the project was renamed in: the repo is `heavy-duty/box`, matching
the CLI it ships. Everything legacy-facing is honored forever — the
`user.claudebox=1` tag, the `.claudebox/` runbook folder, the old symlink the
installer retires — but nothing current carries the old name.

### Added

- **`codex` and `grok` templates** — OpenAI Codex CLI and xAI Grok CLI boxes,
  creds-free like every template. The template mechanic (image + user +
  resources, never a network or a `security.*` key) now has three tenants
  beside `blank`, and the drill mints all of them cold.
- **`box expose <box> <port> [<host-port>]`** — a deliberate, loopback-only
  door to a port inside a box, for seeing a dev server in your browser. The
  listen side is always the host's `127.0.0.1` (no flag to widen it), the door
  is per-port, `--list`/`--remove` manage it, and `box info` shows open
  exposures — a box with a hole says so.
- **Inline resource overrides on `new`** — `--cpu <n> --memory <size>
--disk <size>` (#57). Resolution most-specific-first: flag > `BOX_CPU` /
  `BOX_MEMORY` / `BOX_DISK` environment (the scripting form) > template
  `box.env` > defaults. Values pass to Incus verbatim; resources are all a
  flag can touch. `--from` refuses them — a clone carries its source's
  resources.
- **Host lifecycle as verbs** — `box setup-host`, `box teardown-host`, and
  `box migrate-host`, which re-homes pre-0.4.0 boxes onto the current stack
  (`--box <n>` / `--all-boxes`, authed state preserved) and retires the legacy
  bridge once empty (`--retire-legacy`).
- **The `.box/` recipe convention** — the agent-facing runbook folder a repo
  can ship, renamed from `.claudebox/` (both spellings read).

### Fixed

- **VM mints no longer hang at GRUB** — Incus defaults VMs to Secure Boot on,
  and a cloud image whose shim the host's OVMF doesn't trust dies with "bad
  shim signature" forever. Boxes now launch with `security.secureboot=false`;
  the VM boundary, not boot attestation, is the box threat model.
- **`box expose` actually delivers packets** — a trilogy of drill-found
  absences: the NAT proxy needs the box's boxnet lease pinned as a static
  `ipv4.address` (Incus resolves `connect=0.0.0.0` against device config, not
  the lease); a loopback-sourced packet needs `route_localnet` plus a
  masquerade on the bridge to leave the host and be answerable; and the box's
  replies need a `ct state established,related` accept ahead of the host
  firewall's input drop, which was eating them statelessly. Boxes still
  cannot initiate toward the host — a box-originated SYN is a NEW flow.
- **Firewall rules now converge on upgrade** — `box-firewall.sh` rebuilds its
  chains every run (add + flush + re-add) instead of skipping when they
  exist, which had pinned every host to the rule set of the release that
  first ran there.
- **Failed mints tell you why** — cloud-init failures print the box's own log
  excerpts and leave the box up to inspect; a mint that never boots names the
  likely cause (corrupt image, Secure Boot, GRUB hang) and ships a sanitized
  console dump; the installer asserts it landed the ref it was asked for.
- **`grok` installs the binary it actually ships** — the installer was read,
  not guessed at, and the CLI lands on the non-interactive PATH (same fix
  class as codex).

### Changed

- **Debrand complete** — env vars, install dir, docs, template descriptions
  and the README all say `box`; the install URL is
  `heavy-duty/box` (GitHub redirects the old one, `BOX_REPO` overrides).
- **The drill grew from 47 to 84 checks** — the expose door opened, exercised
  and shut (with the contract re-probed around it), every template minted
  cold, a faithful pre-0.4.0 box re-homed through `migrate-host`, and the
  inline resource flags asserted (including their precedence over the
  environment).
