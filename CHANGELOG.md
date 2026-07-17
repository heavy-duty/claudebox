# Changelog

History before 0.5.0 lives in git and in [drill/RUNS.md](drill/RUNS.md),
which records not just what changed but what each drill run proved.

## Unreleased

### Fixed

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
  hands sequencing back to the drill. Pre-setup tripwires now read *before*
  `install.sh`, since that is what triggers setup now.
- **`install.sh` runs the host setup itself** (#64) — it printed a warning and
  left you a command to run, so the install reported success and `box new`
  failed on a host with no Incus. Since `setup-host` is idempotent, doing this
  on every install is also how an upgraded host picks up stack changes.
  `BOX_SKIP_SETUP_HOST=1` opts out; if setup fails, the install still stands
  and says what to re-run.

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
