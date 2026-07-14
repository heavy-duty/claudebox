# claudebox

A CLI to run **headless, trust-less Claude Code in throwaway VMs**. One command
mints a fresh, network-isolated Incus box with Claude Code installed. The box is
the product — you log in and work; destroying it loses nothing you didn't push.

**Strictly creds-free.** A box ships with everything installed and **no**
credentials — no Claude token, no git PAT, nothing. You authenticate
interactively *inside* the box. The tool never stores or injects a secret. That
means there's nothing shared or committed, so it's safe for multiple operators
out of the box.

**The tool knows nothing about your projects.** You just `git clone` inside a
box. A repo can ship an optional [`.claudebox/`](docs/claudebox-recipe.md)
runbook that Claude Code reads and acts on — there is no `install` step and no
host-run setup. See [docs/claudebox-design.md](docs/claudebox-design.md) for the
design rationale.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/heavy-duty/claudebox/main/install.sh | bash
```

Installs the tree to `~/.local/share/claudebox` and links `claudebox` onto your
`PATH`. Re-run any time to upgrade. (No `git clone` needed.)

## One-time host setup (Ubuntu 24.04 / Debian 13)

```sh
~/.local/share/claudebox/host/setup-host.sh   # run twice if it adds you to incus-admin (re-login between)
```

Idempotent. Installs Incus and creates the isolation stack: the `claudenet` NAT
bridge (sibling-name resolution off, resolver pinned to public upstreams —
`BOX_DNS` overrides), the `claude-isolate` ACL (drops all RFC1918/CGNAT/
link-local egress), the `claude-dev` profile (port-isolated NICs — boxes can't
reach each other), and firewall rules blocking instance → host. All rules
re-apply at boot via `claudebox-firewall.service` — no post-reboot ritual. If
the host lacks `dnsmasq-base` (Debian cloud images skip Recommends):
`sudo apt-get install -y dnsmasq-base`.

## Quick start

```sh
claudebox new --name work        # mint a fresh, creds-free box (~10 min cold)
claudebox shell work             # enter as the claude user
```

Inside the box, authenticate as needed:

```sh
claude                           # then run /login — copy the URL (press c), open it
                                 #   in YOUR browser, paste the code back. No host CLI needed.
gh auth login                    # or drop a PAT in — your git credentials, your call
git clone https://github.com/you/project && cd project
claude                           # if the repo has .claudebox/, Claude reads it and sets up
```

## Log in once, reuse via snapshots

Because every fresh box is creds-free, re-authenticating each time would be
toil. Snapshot an authenticated box and clone from it instead:

```sh
claudebox snapshot work authed   # checkpoint after you've logged in
claudebox new --name feature --from work/authed   # clone the authed state into a new box
```

`--from` copies the whole box (Claude login, git creds, clones and all) while
preserving isolation. You can also `claudebox new --name x --from work` to clone
a box's live state, or roll a box back with `claudebox restore work authed`.

Forgotten what you called a checkpoint? `claudebox info work` prints the box's
snapshot labels and the `--from` line to clone one.

## Commands

```
claudebox new --name <box> [--from <src>[/<snap>]] [--vm|--container] [--remote r]
claudebox list                     # list your boxes
claudebox info <box>               # one box: state, IP, snapshot labels
claudebox shell <box>              # enter as the claude user
claudebox exec <box> -- <cmd...>   # run a command in the box
claudebox snapshot <box> [label]   # checkpoint (label defaults to manual-<epoch>)
claudebox restore <box> <snap>     # roll back to a snapshot
claudebox rename <box> <new>       # rename a box (stop it first)
claudebox down <box>               # stop (state kept; `start` resumes)
claudebox start <box>              # start a stopped box
claudebox rm <box> [--force]       # delete the box + its snapshots (asks first)
claudebox incus <box> -- <args...> # escape hatch: any incus command, box resolved
claudebox status                   # deprecated alias for `list`
claudebox help [<command>]         # full help, or one command's page
```

Every command takes `--help`, and options come after the command
(`claudebox list --json`). Exit status: `0` ok, `1` it went wrong, `2` you asked
wrong.

`new` fresh-launches from cloud-init, or with `--from` clones an existing box or
snapshot. VM mode (`--vm`, the default where `/dev/kvm` exists) is the trust-less
target; container mode (auto-fallback, `security.nesting=true`) is for hosts
without nested virt — weaker isolation, dev/test only.

## Boxes are just Incus instances

A box is an ordinary Incus instance tagged `user.claudebox=1`. claudebox wraps
the box lifecycle and the isolation model — not all of Incus. It owns a command
when it must enforce something Incus can't see: that tag (it will not stop,
rename or delete an instance it didn't mint), the isolation stack, or the
creds-free snapshot workflow. For everything else, there's the door:

```sh
claudebox incus work -- config show        # instance name appended
claudebox incus work -- file push x.tar {}/tmp/   # or placed with {}
```

The box is resolved and tag-checked; the rest is passed to `incus` verbatim, and
the command is echoed before it runs. If it can move the box off the isolation
stack (profile, network, device, `security.*`), claudebox warns and proceeds —
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

The VM is the trust boundary: Claude can run arbitrary code inside and touch
nothing you care about.

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
rm -rf ~/.local/share/claudebox ~/.local/bin/claudebox       # the CLI
```

## Non-goals

- **No unattended/CI bring-up.** The flow is interactive (log in, clone, ask
  Claude). Reproducible-by-construction provisioning is out of scope.
- **No credential storage or injection by the tool.** Boxes are creds-free;
  snapshots are the reuse mechanism, not a secrets store.
