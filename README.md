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
bridge, the `claude-isolate` ACL (drops all RFC1918/CGNAT/link-local egress),
the `claude-dev` profile, and firewall rules blocking instance → host. All rules
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
claudebox down <box>               # stop (state kept; `start` resumes)
claudebox start <box>              # start a stopped box
claudebox rm <box> [--force]       # delete the box + its snapshots (asks first)
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

## Isolation

Dedicated NAT bridge `claudenet` + Incus `claude-isolate` ACL dropping all
private-range egress, plus host-firewall rules that block instance → host
(including the host's public IPs). The box reaches the public internet and
nothing else. Entry is `incus exec` over the local socket only — **no inbound
path exists.** The VM is the trust boundary: Claude can run arbitrary code inside
and touch nothing you care about.

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
