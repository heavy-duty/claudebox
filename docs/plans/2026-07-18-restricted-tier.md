# Restricted incus tier — design and measured results (#74)

**Status: implemented and rehearsed.** 54/54 rehearsal criteria green on the
design host (Debian 13 trixie, Incus 6.0.4, nested KVM), in container mode
and VM mode — and green in CI on ubuntu-latest / incus 6.0.0 (whose one
version-drift false FAIL is MU-4 in `drill/RUNS.md`). This doc records the design, what was measured, and why each
decision fell where it did. It supersedes the vetoed #72 design
(`docs/plans/2026-07-17-multiuser-hosts.md` on `feat/restricted-tier-wip`).

## What #74 asked

A restricted (`incus`-group) user can `box new/list/shell/snapshot/rm` their
own boxes, on a network carrying box's **full** isolation contract, seeing no
one else's; the convergence is a documented, idempotent path; the rehearsal
passes criteria (a)–(f); the admin tier is unchanged.

## The three facts that shaped the design

Task-0 (#72) measured one: incus-user confines users to `user-<uid>` projects
(sound), but pins them to a private auto-created bridge `incusbr-<uid>` and
`restricted.networks.access: incusbr-<uid>` — they cannot even see `boxnet`.

This round measured two more:

1. **The private bridge is worse than unhardened.** `incusbr-<uid>` is a
   fully functional NAT bridge — `ipv4.nat=true`, **`ipv6.nat=true`** — with
   no ACL, no `dns.mode=none`, no resolver pin, no port isolation, and IPv6
   egress box's contract explicitly forbids. Any instance placed on it holds
   a door to the host's LAN.
2. **incus-user projects block snapshots** (`Project "user-<uid>" doesn't
   allow for snapshot creation`) — box's entire reuse workflow.

And two open questions from #74, answered from incus-user's own source
(`cmd/incus-user/server.go`, stable-6.0) and then confirmed live:

- **Daemon-level project template?** None exists — the project config is
  hardcoded in `serverSetupUser()`. A per-user admin hook is the only path.
- **Does widening survive a re-sync?** Yes. Setup runs only when the project
  does not exist (and early-outs when the user's certificate is already
  trusted); incus-user never rewrites an existing project. Confirmed live:
  `systemctl restart incus-user.socket` leaves the convergence intact.

## The decision: option 1, tightened

#74 offered (1) converge users onto the shared `boxnet` or (2) harden each
private bridge. Option 2 multiplies every mechanism per user (ACL, resolver
pin, dnsmasq, nft rules, firewall coexistence) and turns the shipped static
profile into N generated ones. Option 1 keeps one hardened network and one
shipped profile — and the existing box↔box mechanisms already make
cross-user isolation free: the nft bridge-family drop and `dns.mode=none`
are host/network-owned, so they bind every instance on `boxnet` no matter
whose project it lives in.

One tightening beyond the issue's sketch: the issue proposed
`restricted.networks.access boxnet,incusbr-<uid>` ("must list both" — true
as long as the default profile still references the private bridge). Listing
both leaves fact 1's unhardened bridge one `--network` flag away, forever.
Instead, `box grant`:

- removes `eth0` from the project's default profile (nothing references the
  private bridge anymore, so the narrowing validates), and
- sets `restricted.networks.access boxnet` — **only**.

After which the hardened network is not the user's default placement but the
only placement their certificate can express. Measured: `incus launch
--network incusbr-<uid>` as the user → `Network not found`; the user cannot
widen their own project (`Error: Certificate is restricted`); they cannot
touch `boxnet`'s config or the ACL (`no permission for project "default"`).

A restricted user CAN edit the `box-net` profile copy in their own project
(they own project profiles — `features.profiles=true`), including stripping
`security.port_isolation` — and CAN attach `boxnet` raw with `--network
boxnet`, no profile at all (the network must be in
`restricted.networks.access` for the profile to work; there is no
allow-via-profile-only lever). That is why the host-owned nft bridge drop is
the second layer: `meta ibrname boxnet obrname boxnet drop` fires on every
port-to-port frame regardless of per-NIC flags. The documented guarantee is
scoped accordingly (see box-design.md): box-minted instances carry per-NIC
port isolation; raw attachments keep every network- and host-owned control,
losing only that redundant L2 layer. Both shapes are measured from inside
the instances (rehearsal criteria g and m).

Two grant-failure contracts, both injected in the rehearsal (criterion n):
a fresh user is backed out of the group with the removal VERIFIED against
the live group database (and any session begun mid-grant is named, with the
loginctl remedy — the one window the database cannot close); a pre-existing
member is never stripped by a failed re-grant, but the failure states out
loud that they retain socket access on part-converged policy, with both
remediations. The default-profile eth0 removal is deliberately NOT restored
on failure: that mutation only reduces capability, and restoring it would
move the failure state away from fail-closed. Every step is check-then-
converge, which is what makes re-run-to-repair deterministic.

## What `box grant <user>` converges (idempotent, re-run to refresh)

1. `usermod -aG incus` (not `incus-admin` — that is the tier)
2. first-touch incus-user as the user (`runuser`/`sudo -u`, stdin pinned) —
   the project is created lazily and cannot be pre-created by an admin
3. remove the default profile's private-bridge `eth0`
4. `restricted.networks.access boxnet`
5. `restricted.snapshots allow`
6. install/refresh the shipped `box-net` profile into the project
7. verify from the user's side of the socket

`box revoke <user>` is the inverse, two strengths: bare = group removal (the
socket closes; boxes keep running; re-grant restores), `--purge` = boxes,
images, project, private bridge, trust-store certificate, incus-user state —
then asserts the absence (the wipe.sh discipline).

## The tier in the CLI

`box_tier()` — UID 0 / `incus-admin` → admin, `incus` alone → restricted,
neither → none — decided from live process credentials (argless `id -nG`),
byte-identical in `bin/box` and `host/setup-host.sh` (diffed by a test).
Tier-aware surface: `new` pre-flights the profile and names the right fix per
tier; `expose` refuses before any daemon call (its plumbing is daemon-global;
without the guard the failure is a lie — a restricted user cannot read
boxnet's redacted config, so box_net_ip would claim their running box has no
address); `setup-host` exits 0 with the honest note; `doctor` runs a
restricted check-set (is the tier granted, does their box resolve/route)
instead of judging host state they cannot see.

Found along the way, fixed for every tier: `box restore` dispatched
`incus restore`, which does not exist in Incus 6 (`incus snapshot restore`).
It had never worked.

## Rehearsal and CI

`drill/multiuser.sh` (root, opt-in via `BOX_MULTIUSER_REHEARSAL=1`) proves
criteria (a)–(f) from #74 plus the measured extensions (g)–(n): the in-box
isolation contract (egress, DNS, box→host, RFC1918, cross-user sibling drop,
name enumeration, IPv6-off), the closed escape hatches, re-sync survival, and
scoped revoke, the raw-attach scoped guarantee (m) and the grant-failure
injections (n). Real users, real grants, real mints, probes from inside;
`--container` for CI, VM mode on real hardware; cleanup deletes everything it
made.

CI gains a `rehearsal` job (ubuntu-latest): install incus, stage the checkout
at `/opt/box` (the #71 layout), `setup-host`, `doctor`, then the rehearsal in
container mode. The tier's semantics are proven on every PR against a live
daemon; the VM trust boundary stays a real-hardware ritual, like the drill.

## Environment

Debian 13 (trixie), Incus 6.0.4, `incus-user.socket` shipped in the incus
package (Debian 13 and Ubuntu 24.04 both), `/dev/kvm` present (VM-mode run),
btrfs pool. Companion work: rig#24 (`box` role), rig#12/#25 (host-class).
