# `staging` template Implementation Plan

> Spec: issue #68. Companion: heavy-duty/rig#22 (`rig bootstrap workload`,
> implemented separately in the rig repo). Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** A server-class `staging` template so staging VMs (registered in the
control plane as servers, reachable tailnet-only) are minted by box instead of
by a hand-rolled `incus launch` in a private infra repo. The template ships
docker + rig preinstalled and nothing else; the operator runs
`box shell` → `sudo rig bootstrap workload` inside, and rig — not box — hardens
sshd, joins the tailnet, and holds the auth key in process memory.

**Why box's isolation stack needs zero changes:** the guest joins the tailnet
*itself*, outbound. The host-side stack (boxnet ACL, port isolation,
box-firewall, loopback-only `expose`) only ever sees allowed outbound UDP.
Isolation becomes the feature: the staging box still cannot reach the LAN, the
host, or a sibling box — it is reachable only over the tailnet, which is
exactly the staging posture.

**Architecture:** one new data-only template directory (`templates/staging/`),
two new keys in the `box.env` allowlist (`BOX_REQUIRE_VM`, `BOX_AUTOSTART`)
honored by `cmd_new` in `bin/box`, and a design-doc section. No new commands,
no new flags, no dependency changes.

## Non-goals

- No changes to boxnet, the `box-isolate` ACL, `box-firewall`, or `expose` —
  the whole point is that none are needed.
- No credential injection — no `TS_AUTHKEY`, no ssh keys, nothing. The
  creds-free contract is untouched; rig owns the join, inside the guest.
- No tailscale and no openssh-server in the template — rig installs both at
  bootstrap time, so box ships neither.
- No control-plane/Coolify awareness (that is cast's job, out of scope).
- No agent tooling in the box: no `~/.claude`, no agent-context file — this
  is a server, not an agent devbox.

## Global constraints

- `templates/staging/` is data-only: a `box.env` (parsed against the
  allowlist, never sourced) and a `user-data.yaml` (passed to Incus verbatim).
  Templates still cannot touch the network or a `security.*` key.
- The two new keys are optional and absent from every other template;
  existing templates mint exactly as before, and the allowlist still rejects
  unknown keys.
- `BOX_REQUIRE_VM` refuses *both* the silent container fallback (no
  `/dev/kvm` → exit 1, it went wrong) and an explicit `--container` (exit 2,
  you asked wrong), per the existing exit-code contract.
- `boot.autostart=true` is stamped only when `BOX_AUTOSTART` is set — absent
  on every other template's boxes. Clones inherit it via `incus copy`, which
  keeps all non-volatile config keys (verified in Incus's
  `InstanceIncludeWhenCopying`; same mechanism the `user.*` stamps already
  rely on — audit B2), so no clone-path code is needed.
- Match the repo's disciplined-bash style; minimal diff; conventional
  commits (`type(scope): subject`).

---

### Task 1: `BOX_REQUIRE_VM` + `BOX_AUTOSTART` in `bin/box`

**Files:** modify `bin/box` only.

- [ ] `load_template()`: initialize `T_REQUIRE_VM=""; T_AUTOSTART=""` and
  accept `BOX_REQUIRE_VM` / `BOX_AUTOSTART` in the key allowlist. Update the
  "image, user and resources, nothing else" phrasing where it enumerates the
  allowlist (the function's header comment, the unknown-key error, and the
  `new`/`templates` help prose) — there is still no key for a network or a
  `security.*` flag, on purpose.
- [ ] `cmd_new` (fresh-mint path): after `m="$(pick_mode)"`, if the template
  set `BOX_REQUIRE_VM` and the effective mode is not `vm`: `usage_error` when
  `--container` was asked for explicitly, `die` (naming `/dev/kvm`) when the
  host fell back. No silent container fallback for a server-class template.
- [ ] `cmd_new` (fresh-mint path): when the template set `BOX_AUTOSTART`,
  append `--config boot.autostart=true` to the launch arguments — the same
  per-instance mechanism as `limits.cpu`. The `--from` clone path needs
  nothing: `incus copy` carries the key (see Global constraints).
- [ ] Commit: `feat(new): BOX_REQUIRE_VM and BOX_AUTOSTART template keys`

### Task 2: the `staging` template

**Files:** create `templates/staging/box.env`,
`templates/staging/user-data.yaml`.

- [ ] `box.env`, following the existing templates' format and header-comment
  voice: `BOX_DESCRIPTION` (server-class staging VM: docker + rig
  preinstalled; converge with `rig bootstrap workload` inside, then register
  in the control plane), `BOX_IMAGE="images:debian/13/cloud"`,
  `BOX_USER="ops"`, `BOX_CPU="4"`, `BOX_MEMORY="8GiB"`, `BOX_DISK="100GiB"`
  (build-sized: the control plane builds on the target),
  `BOX_REQUIRE_VM="1"`, `BOX_AUTOSTART="1"`.
- [ ] `user-data.yaml`, modeled on the claude template but server-minimal:
  user `ops` (NOPASSWD sudo, `lock_passwd: true`), `curl` +
  `ca-certificates`, docker via `get.docker.com` (the mechanism the claude
  template uses), and rig preinstalled via its installer
  (`curl -fsSL …/rig/main/install.sh | bash`, with `HOME=/root` pinned —
  cloud-init's runcmd does not guarantee `HOME`, and rig's installer derives
  its install dir from it: as root it lands in `/root/.local/share/rig` with
  a `/usr/local/bin/rig` symlink, which is what we want since rig runs as
  root). A comment states that tailscale, openssh-server and every credential
  are deliberately absent — rig installs those at bootstrap time. No
  `~/.claude`, no agent-context file.
- [ ] Commit: `feat(templates): staging — server-class VM, docker + rig, creds-free`

### Task 3: design-doc amendment

**Files:** modify `docs/box-design.md`.

- [ ] New section (after Isolation, matching the doc's voice): the isolation
  guarantee is "no inbound *via the host's network position*"; a guest can
  deliberately join an overlay network (tailnet) from inside and invite
  management in over its own outbound tunnel; the `staging` template is the
  sanctioned server-class use of that, layered as box mints / rig converges
  (inside the guest) / cast registers; and the **snapshot-before-join** rule —
  clone from a pre-`rig bootstrap` snapshot, because a post-join clone
  duplicates the source's tailnet identity.
- [ ] Commit: `docs(design): server-class boxes — overlay joins and snapshot-before-join`

---

## Test plan

No Incus in the implementation environment, so runtime minting is **not**
exercised here — the acceptance criteria in #68 (`box new --template staging`
mints a VM on a KVM host, refuses on a non-KVM host, `rig bootstrap workload`
succeeds inside) are exercised on a real host. Static gate, all of which must
pass before merge:

- [ ] `bash -n bin/box` — parses.
- [ ] `shellcheck bin/box` — no new findings against main.
- [ ] Both `templates/staging/*.yaml` / all templates' `user-data.yaml` parse
  as YAML (pyyaml).
- [ ] Grep assertions: `BOX_REQUIRE_VM`/`BOX_AUTOSTART` appear in the
  allowlist; `boot.autostart` is stamped only under the `BOX_AUTOSTART`
  guard; no template other than `staging` sets either key.

---

## Addendum (2026-07-18): rebased onto main; the template test suite

The branch was rebased onto main, which had since gained the restricted tier
(#74), a CI workflow, and `test/cli.sh`. What that changed here:

- **`load_template` conflicts** — main replaced the `[ -n … ] && [ -n … ] ||
  die` required-keys idiom with the spelled-out `if [ -z … ]` form (SC2015)
  and grew the SC2034 directive block; the two new key arms were re-applied
  onto that version, both intact.
- **`cmd_new`** — main added a tier-aware box-net pre-flight at the top of
  the function; the `BOX_REQUIRE_VM` refusal stays in the fresh-mint branch,
  after `pick_mode` (it must read the *effective* mode). Its message holds
  for both tiers: `/dev/kvm` is a host fact, and admin and restricted mints
  go through the same daemon, so the fix is the same — a KVM host, not a
  grant.
- **tmux** — `box tmux` is a contract every template honors (#65, asserted
  by `test/cli.sh`), so the staging package list carries tmux; the operator
  babysits `rig bootstrap workload` through it.
- **The template test suite** (maintainer request): `test/cli.sh`'s template
  coverage is now *dynamic* over `templates/*/` — a new template cannot ship
  unseen. Per template: `box.env` driven through the real, extracted
  `load_template` (unknown keys and missing `BOX_IMAGE`/`BOX_USER` fail);
  `user-data.yaml` exists, declares `#cloud-config`, parses as YAML
  (python3+pyyaml, loudly skipped where absent), installs tmux.
  Staging-specific: both boot demands proven through the parser, docker +
  rig present, and a creds-free grep-refusal (no tailscale/authkey/ssh in
  effective cloud-init lines). Grep guards pin the `cmd_new` half: the
  refusal orders after `pick_mode`; `boot.autostart` is stamped only under
  the `T_AUTOSTART` guard.
