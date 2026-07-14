# claudebox — ships the `box` CLI

**Headless, trust-less, throwaway dev VMs.** One command mints a fresh,
network-isolated Incus box from a **template**; the flagship template is
`claude` — Debian 13 with Claude Code installed, the box this repo is named
for. The box is the product — you log in and work; destroying it loses
nothing you didn't push.

**Strictly creds-free.** A box ships with everything installed and **no**
credentials — no Claude token, no git PAT, nothing. You authenticate
interactively *inside* the box. The tool never stores or injects a secret. That
means there's nothing shared or committed, so it's safe for multiple operators
out of the box.

**Templates set what's in the box, never what it can reach.** A template is
image + user + resources + cloud-init; the network and every security flag
live in a shared profile no template can touch, so `blank` is a box with
nobody home — not a box with the safety off.

**The tool knows nothing about your projects.** You just `git clone` inside a
box. A repo can ship an optional [`.claudebox/`](docs/claudebox-recipe.md)
runbook that Claude Code reads and acts on — there is no `install` step and no
host-run setup. See [docs/claudebox-design.md](docs/claudebox-design.md) for the
design rationale.

> **0.4.0 renamed the CLI** from `claudebox` to `box` — a clean cut, no shim.
> Existing boxes minted by any earlier version keep working under every verb
> (their legacy tag is honored forever); only the old command name retired.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/heavy-duty/claudebox/main/install.sh | bash
```

Installs the tree to `~/.local/share/claudebox` and links `box` onto your
`PATH`. Re-run any time to upgrade — upgrading from a pre-0.4.0 install also
retires the old `claudebox` symlink. (No `git clone` needed.)

## One-time host setup (Ubuntu 24.04 / Debian 13)

```sh
~/.local/share/claudebox/host/setup-host.sh   # run twice if it adds you to incus-admin (re-login between)
```

Idempotent. Installs Incus and creates the isolation stack: the `claudenet` NAT
bridge (sibling-name resolution off, resolver pinned to public upstreams —
`BOX_DNS` overrides), the `claude-isolate` ACL (drops all RFC1918/CGNAT/
link-local egress), the `box-net` profile (port-isolated NICs — boxes can't
reach each other), and firewall rules blocking instance → host. All rules
re-apply at boot via `claudebox-firewall.service` — no post-reboot ritual. If
the host lacks `dnsmasq-base` (Debian cloud images skip Recommends):
`sudo apt-get install -y dnsmasq-base`.

## Quick start

```sh
box new --name work              # mint a fresh, creds-free claude box (~10 min cold)
box shell work                   # enter as the template's user
```

Inside the box, authenticate as needed:

```sh
claude                           # then run /login — copy the URL (press c), open it
                                 #   in YOUR browser, paste the code back. No host CLI needed.
gh auth login                    # or drop a PAT in — your git credentials, your call
git clone https://github.com/you/project && cd project
claude                           # if the repo has .claudebox/, Claude reads it and sets up
```

## Templates

The claude box is one template among several. A template is a directory under
`templates/`: a `box.env` (image, user, resources — parsed against a strict
allowlist, never sourced) and a `user-data.yaml` (cloud-init, passed to Incus
verbatim).

```sh
box templates                            # list what this install can mint
box new --name scratch --template blank  # bare Debian: same isolation, no tooling
```

A template **cannot** name a network, a profile, or a `security.*` flag —
there is no key for them. Every box launches with the shared `box-net`
profile (the isolated NIC + root disk), so every template gets the identical
trust boundary. Resources come from the template's `box.env`;
`BOX_CPU` / `BOX_MEMORY` / `BOX_DISK` environment variables override them at
mint time. The template's identity (name, user) is stamped onto the instance,
so `shell`, `exec` and `tmux` land in the right user — and a clone still
knows, because `incus copy` carries the metadata.

## Log in once, reuse via snapshots

Because every fresh box is creds-free, re-authenticating each time would be
toil. Snapshot an authenticated box and clone from it instead:

```sh
box snapshot work authed   # checkpoint after you've logged in
box new --name feature --from work/authed   # clone the authed state into a new box
```

`--from` copies the whole box (Claude login, git creds, clones and all) while
preserving isolation. You can also `box new --name x --from work` to clone
a box's live state, or roll a box back with `box restore work authed`.

Forgotten what you called a checkpoint? `box info work` prints the box's
snapshot labels and the `--from` line to clone one.

## Commands

```
box new --name <box> [--template <t>] [--from <src>[/<snap>]] [--vm|--container] [--remote r]
box templates                # list the templates this install can mint
box list                     # list your boxes
box info <box>               # one box: state, IP, snapshot labels
box shell <box>              # enter as the template's user
box exec <box> -- <cmd...>   # run a command in the box
box tmux <box> [session]     # attach/create a tmux session — survives disconnects
box snapshot <box> [label]   # checkpoint (label defaults to manual-<epoch>)
box restore <box> <snap>     # roll back to a snapshot
box rename <box> <new>       # rename a box (stop it first)
box down <box>               # stop (state kept; `start` resumes)
box start <box>              # start a stopped box
box rm <box> [--force]       # delete the box + its snapshots (asks first)
box incus <box> -- <args...> # escape hatch: any incus command, box resolved
box doctor [--fix|--pin-dns] # is this host fit to mint boxes? diagnose from ground truth
box status                   # deprecated alias for `list`
box help [<command>]         # full help, or one command's page
```

Every command takes `--help`, and options come after the command
(`box list --json`). Exit status: `0` ok, `1` it went wrong, `2` you asked
wrong.

`new` fresh-launches from a template (default: `claude`), or with `--from`
clones an existing box or snapshot. VM mode (`--vm`, the default where
`/dev/kvm` exists) is the trust-less target; container mode (auto-fallback,
`security.nesting=true`) is for hosts without nested virt — weaker isolation,
dev/test only.

## Boxes are just Incus instances

A box is an ordinary Incus instance tagged `user.box=1` (pre-0.4.0 boxes
carry `user.claudebox=1`, honored forever). box wraps the box lifecycle and the isolation model — not all of Incus. It owns a command
when it must enforce something Incus can't see: that tag (it will not stop,
rename or delete an instance it didn't mint), the isolation stack, or the
creds-free snapshot workflow. For everything else, there's the door:

```sh
box incus work -- config show        # instance name appended
box incus work -- file push x.tar {}/tmp/   # or placed with {}
```

The box is resolved and tag-checked; the rest is passed to `incus` verbatim, and
the command is echoed before it runs. If it can move the box off the isolation
stack (profile, network, device, `security.*`), box warns and proceeds —
the trust boundary is then yours to keep. See
[docs/claudebox-design.md](docs/claudebox-design.md) for the rule and why the
command surface is a table.

## Isolation

The contract: **a box reaches the public internet and nothing else.** Not the
host, not your LAN, not another box, not even another box's *name*. What
enforces it, layer by layer:

- **Dedicated NAT bridge** `claudenet`, IPv6 off. Every rule below is
  IPv4-only, so IPv6 would be an uncovered path — off is part of the
  contract, not a default.
- **`claude-isolate` ACL** — drops all egress to private space (RFC1918,
  CGNAT, link-local), with a single carve-out to the gateway so DNS works.
- **Sibling isolation, at L2** — two boxes on one bridge are *switched*,
  never routed, so no L3 rule can separate them (learned the hard way; see
  below). `security.port_isolation` on every box NIC plus an nft
  bridge-family drop mean box A cannot exchange frames with box B at all.
- **No name-level reconnaissance** — `dns.mode=none` stops the gateway
  resolving sibling names, and the bridge's resolver is pinned to public
  upstreams (`no-resolv`), so tailnet names and split-DNS zones from a
  host-level VPN don't resolve inside a box either.
- **Host firewall** — instance → host is dropped except DNS/DHCP, including
  the host's public IPs. Entry is `incus exec` over the local socket only —
  **no inbound path exists.**

The VM is the trust boundary: whatever runs inside — Claude, or anything a
template ships — can run arbitrary code and touch nothing you care about.

### Measured, not claimed

Every clause above is probed live by an end-to-end drill, because the one time
this contract was reasoned about instead of measured, the reasoning was wrong:
box→box traffic was "covered" by an L3 drop that L2-switched frames never
meet — a hole found by probing, not by reading the rules. On a bare host the
drill installs the whole stack, mints a box cold, snapshots and clones it,
probes every boundary from inside the boxes, and removes what it minted —
currently **47 checks, 47 passing**. [drill/RUNS.md](drill/RUNS.md) is the full
history, including every trap that fooled a run into a wrong verdict.

```sh
bash drill/doctor.sh    # read-only: is this host healthy and the stack live?
bash drill/drill.sh     # FULL end-to-end — mutates the host; use a machine you own
```

The doctor reads ground truth, not config claims — the kernel's `isolated on`
flag per bridge port, the process table, the resolver actually in use — and
diagnoses the host faults that have actually happened: a wedged Incus daemon,
a dnsmasq that silently isn't serving, a VPN resolver that boxes would
inherit.

## Recipes: the `.claudebox/` convention

A repo that wants to be easy to stand up in a box ships an optional `.claudebox/`
folder — a runbook Claude reads and follows (install deps, start services,
template env, seed data, smoke-test). It is agent-facing documentation, not a
host-executed script. See [docs/claudebox-recipe.md](docs/claudebox-recipe.md).

## Uninstall

```sh
~/.local/share/claudebox/host/teardown-host.sh               # boxes, network, ACL, profile, firewall
~/.local/share/claudebox/host/teardown-host.sh --purge-incus # ...and Incus itself
rm -rf ~/.local/share/claudebox ~/.local/bin/box             # the CLI
```

## Non-goals

- **No unattended/CI bring-up.** The flow is interactive (log in, clone, ask
  Claude). Reproducible-by-construction provisioning is out of scope.
- **No credential storage or injection by the tool.** Boxes are creds-free;
  snapshots are the reuse mechanism, not a secrets store.
