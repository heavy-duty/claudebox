# box export / import — a box's state that survives the box and the host (#70)

**Status: implemented.** Asked for by @danmt on #66, as the prerequisite for
the upgrade flow the installer wants to enforce: _stop, export, remove every
box before you upgrade — then re-import_. This doc records the design
decisions, the facts they rest on, and what holds them.

## The gap #70 named

Nothing a box held could outlive a host teardown:

- `box snapshot` is an **in-box** checkpoint, and `box rm` deletes the box
  and every snapshot it has — a snapshot cannot outlive its box.
- `box new --from` clones to an independent box, but the clone still lives
  **on the same host**, under the same stack. It is not an artifact you can
  carry off the machine or keep across a teardown.

So #66's refusal-to-upgrade-over-live-boxes could only say "copy things out
by hand" — honest, but lossy. `box export` upgrades that instruction to
"export, keep the file, re-import after".

## The shape

`incus export` / `incus import` are the primitives: a backup tarball of an
instance and (by default) its snapshots, and instance creation from that
tarball. box wraps them where it must enforce what incus cannot see.

- **`box export <box> [<file>]`** — the box must be tagged `user.box=1` (the
  boundary, as everywhere) and **stopped**. Default filename
  `<box>-<UTC stamp>.tar.gz` (sortable, collision-free, and it answers the
  question you will ask the file later: _when is this state from?_).
  Snapshots ride along by default; `--instance-only` opts out, passed to
  incus verbatim. Refuses to overwrite an existing file without `--force`.
- **`box import <file> [--name <box>]`** — reads the artifact's own instance
  name from `backup/index.yaml` up front, refuses any name an existing
  instance already holds (box or not — `resolve_box`'s boundary from the
  other side), pre-flights the stack (`require_stack`, factored out of
  `cmd_new` now that it has two callers), imports, then re-stamps, starts,
  and hands over.

## The three decisions, and why they fell where they did

**1. Require `box down` first — no live export, no snapshot-then-export.**
Incus _can_ back up a running instance, but a live root disk is a moving
target, and this artifact's entire job is to be trusted later, on a host
that no longer has the box to compare against. The refusal reuses
`require_stopped` with an honest reason parameter: rename is stopped because
_incus_ insists; export is stopped because _we_ decided — the message should
not claim otherwise.

**2. Snapshots included by default.** box's reuse workflow (log in once,
snapshot, clone forever) lives in snapshots; an artifact that quietly
dropped the authed checkpoint would defeat the verb's purpose. The opt-out
is explicit and named for what it does (`--instance-only`).

**3. Credentials: shout, don't scrub.** A box's disk carries agent logins,
git PATs, SSH keys, shell history, deleted-but-unwiped blocks. "Scrubbing" a
disk-image tarball is a promise no tarball surgery can keep, and handing
someone a file labeled sanitized that is not would be worse than the risk it
hides. So export prints a loud, unconditional stderr warning: the file _is_
a credential; store and move it as one. Import repeats the point — auth
state came back by design, the same trust boundary as cloning an authed
snapshot.

## Import re-stamps the host's truth, not the artifact's

The split is the design. Everything `incus import` restores is the
artifact's truth: disk, config, devices, snapshots. Everything box then
re-stamps is the current host's:

- **The boundary tag.** `user.*` keys ride inside the artifact, so a box
  export brings `user.box.template` / `user.box.user` back on its own, and a
  legacy `user.claudebox=1` stays honored as it is everywhere else. An
  instance carrying neither tag is stamped `user.box=1` — importing is
  minting, and a minted box is ours to manage.
- **The placement.** The artifact carries its profile list, but the
  isolation contract is _this_ host's `box-net` profile. A box export
  already says `box-net`; anything else is re-assigned (`incus profile
  assign` — the same move `migrate-host` makes re-homing a legacy box). An
  artifact naming a profile the host lacks fails inside `incus import` with
  incus's own error naming it. A fresh host without the stack at all is
  refused before the import, tier-aware (`require_stack`: admins are sent to
  `setup-host`, restricted users to `box grant`).
- **The identity — host side and guest side.** The artifact's `volatile.*`
  config comes back verbatim, _including the NIC's MAC_: importing an
  artifact twice, or beside the box it was exported from, collided at start
  with `MAC address already defined on another NIC` (measured live on Incus
  6.0.4 — `incus copy` regenerates the MAC on clone; `incus import` does
  not). So import unsets every volatile hwaddr before the start and lets
  incus mint fresh ones. Then, in-guest: the artifact's machine-id rides in
  its disk, and `reset_identity` runs before handover, exactly like a clone
  — machine-id → DHCP client-id → lease, the collision that function's
  comment documents. Verified live: two imports of one artifact running side
  by side with distinct MACs, distinct machine-ids, both holding the
  pre-export file and snapshot.

## The restricted tier: measured, then converged

`incus export` rides the backup API (an export _is_ "create a backup,
download it, delete it"), and a restricted project blocks it by default:
`restricted.backups=block` the moment `restricted=true` — read from incus
6.0's `internal/server/project/permissions.go` (the default table, and
`AllowBackupCreation` enforcing it). Import needs no key of its own:
restoring a backup file is plain instance creation.

So the honest answer was not an `expose`-style refusal — the limitation is a
project key, not daemon-global state — but the same convergence grant
already performs for snapshots: `box grant` now also sets
`restricted.backups allow`. Re-run `box grant <user>` after upgrading, as
the grant contract already says.

## What holds it

- **`test/cli.sh`** (dependency-free, no incus): driven usage errors
  (missing box/file/name-value, unknown box, missing file, a non-artifact
  file refused by the pure tar+awk parse), and grep/line-order guards for
  every daemon-gated invariant — `require_stopped` before `incus export`,
  snapshots-by-default, the credential shout, `user.box=1` re-stamping, the
  collision guard before `incus import`, `require_stack` in both `cmd_new`
  and `cmd_import`, `reset_identity` after the start, and grant's
  `restricted.backups allow`. All fail-closed: a deleted guard cannot ship
  green.
- **CI's `rehearsal` job**, on the runner's live Incus (container mode — the
  round-trip is backup mechanics, identical across instance types; the VM
  boundary stays a real-hardware ritual): mint → write a file → snapshot →
  down → export → `rm` → import under a new name → assert the tag, the
  agent, the file, the snapshot survived, and that a colliding re-import is
  refused.

## Related

- #66 — the installer refusal this makes humane (its message is reconciled
  when both land).
- #67 — the version-aware upgrade that would migrate instead of asking.
