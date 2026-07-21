# box

**Headless, trust-less, throwaway dev VMs.** One command mints a fresh,
network-isolated Incus box from a **template**; the coding-agent templates
hand you a CLI agent on Debian 13 — `claude-box` (Claude Code), `codex-box`
(OpenAI Codex), `grok-box` (xAI Grok) — **box mints, [rig](https://github.com/heavy-duty/rig)
converges**: the template is a thin seed, and the agent tooling lands via a
creds-free `rig bootstrap` role auto-run at mint
([#81](https://github.com/heavy-duty/box/issues/81)). The box is the product
— you log in and work; destroying it loses nothing you didn't push.

**Strictly creds-free.** A box ships with everything installed and **no**
credentials — no agent token, no git PAT, nothing. You authenticate
interactively _inside_ the box. The tool never stores or injects a secret. That
means there's nothing shared or committed, so it's safe for multiple operators
out of the box.

**Templates set what's in the box, never what it can reach.** A template is
image + user + resources + cloud-init; the network and every security flag
live in a shared profile no template can touch, so `blank` is a box with
nobody home — not a box with the safety off.

**The tool knows nothing about your projects.** You just `git clone` inside a
box. A repo can ship an optional [`.box/`](docs/box-recipe.md)
runbook that the box's coding agent reads and acts on — there is no `install`
step and no host-run setup. See [docs/box-design.md](docs/box-design.md) for the
design rationale.

> **0.6.0**: multi-user support.

> **0.5.0**: two new templates (`codex`, `grok`), `box expose` — a
> loopback-only door to a box port, for seeing a dev server — and the host
> lifecycle as first-class verbs: `box setup-host`, `box teardown-host`, and
> `box migrate-host`, which re-homes pre-0.4.0 boxes onto the current stack
> and retires the legacy bridge.
>
> **0.4.0's clean cut stands**: the CLI is `box` (no legacy shim), the
> host stack is `boxnet`/`box-isolate`/`box-firewall` on 10.88.0.0/24, and
> the default template is `blank`. Boxes minted by any earlier version keep
> working under every verb — their legacy tag is honored forever.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/heavy-duty/box/main/install.sh | bash
```

By default that installs the **latest release** — the installer resolves the
release tag off GitHub's `releases/latest` redirect (no API, no token) and
downloads exactly that tree, so two operators running it get the same box.
If the resolution fails it says so and stops — it never silently hands out
`main`. `BOX_REF` picks another channel (a set ref is tried as a tag first,
then as a branch — [#83](https://github.com/heavy-duty/box/issues/83)):

```sh
curl -fsSL .../install.sh | bash                  # the latest release (default)
curl -fsSL .../install.sh | BOX_REF=0.6.0 bash    # pin a release
curl -fsSL .../install.sh | BOX_REF=main bash     # the development tip
```

(A dev tree's `VERSION` carries a `-dev` suffix, so it lands beside your
releases under `versions/`, never on top of one.)

It asks first — **"Install box?"** — then downloads the tree into a
**versioned** install (the way plenty of CLIs manage theirs), links `box` onto
your `PATH`, and on a fresh host asks a second question: **"Set up this
machine as a box host now?"** Say yes and it builds the whole isolation stack
for you (it may ask for `sudo`); say no and you can run `box setup-host`
later. (No `git clone` needed.)

The layout, under the install root (`~/.local/share/box`, or `/opt/box` for a
root install):

```
versions/<version>/          one full tree per installed version
current -> versions/<v>      the tracked default
$BINDIR/box -> current/bin/box    the PATH entry, riding the chain
```

**Re-running is a safe converge.** Installing a version you already have
changes nothing and says so (`BOX_REINSTALL=1` replaces that version's tree);
a stray re-run can never clobber your install or rebuild the stack under your
boxes. Installing a **new** version lands it side by side and flips `current`
only when you have **no boxes** — under existing boxes the flip is refused
(never change versions under a user's boxes,
[#66](https://github.com/heavy-duty/box/issues/66)) and switching stays a
deliberate act: preserve what you care about — `box down <box>`, then
`box export <box>` (one portable file per box, snapshots included —
[#70](https://github.com/heavy-duty/box/issues/70)), then `box rm <box>`
(which deletes the box _and_ its snapshots) — then:

```sh
box versions        # what is installed, which is current, which is running
box use <version>   # flip the default (same refusal while boxes exist)
```

A pre-0.7.0 flat install is migrated into `versions/` automatically on the
next installer run — the tree is moved, not re-downloaded, and your boxes are
untouched. After switching versions (and `box setup-host`, if the stack was
torn down), `box import <file>` brings each exported box back — snapshots,
logins and all. A version-aware upgrade that migrates boxes instead of asking
you to is [#67](https://github.com/heavy-duty/box/issues/67). For unattended
installs (CI, images), `BOX_YES=1` answers every prompt yes,
`BOX_SKIP_SETUP_HOST=1` declines the host-setup step, and
`BOX_INSTALL_SOURCE=<dir-or-tarball>` installs from a local tree instead of
downloading (how CI proves the installer under review, and how the drill can
install an unpushed branch).

### Global vs per-user install

Where box lands depends on **who runs the installer**, because on a shared host
box's tree is _executed by other users_ — so it cannot hide in one user's home:

- **As root → global.** The tree goes to `/opt/box` (world-readable) and the
  `box` symlink to `/usr/local/bin` (already on every login `PATH`). One
  install, every operator on the host runs the same `box`. This is the fleet
  path: [rig](https://github.com/heavy-duty/rig)'s `box` role
  ([rig#24](https://github.com/heavy-duty/rig/issues/24)) installs box once at
  host bootstrap ([#71](https://github.com/heavy-duty/box/issues/71)).
- **As a normal user → per-user.** The tree goes to `~/.local/share/box` and
  the symlink to `~/.local/bin` — the solo path, unchanged. Nobody else needs
  to run your box.

`BOX_HOME` / `BOX_BIN` override the destination on either path. A per-user
install under `/root` would be `0700` and unreadable to everyone else — which
is exactly the bug the root branch fixes. When both tiers are installed, PATH
order decides which `box` wins — the installer warns when it sees the other
tier's tree.

## One-time host setup (Ubuntu 24.04 / Debian 13)

The installer already does this. Run it directly to set up a host you
installed with `BOX_SKIP_SETUP_HOST=1`, or to re-apply the stack by hand:

```sh
box setup-host   # one run is enough
```

Idempotent. Installs Incus and creates the isolation stack: the `boxnet` NAT
bridge (sibling-name resolution off, resolver pinned to public upstreams —
`BOX_DNS` overrides), the `box-isolate` ACL (drops all RFC1918/CGNAT/
link-local egress), the `box-net` profile (port-isolated NICs — boxes can't
reach each other), and firewall rules blocking instance → host. All rules
re-apply at boot via `box-firewall.service` — no post-reboot ritual. If
the host lacks `dnsmasq-base` (Debian cloud images skip Recommends):
`sudo apt-get install -y dnsmasq-base`.

The stack's subnet is `10.88.0.0/24` when free. setup-host **never builds on
a subnet something else already claims** — most tellingly when this machine's
own default gateway sits inside it, which means it is being run *inside a
box*: a nested `boxnet` on the guest's own uplink subnet captures its gateway
address and blackholes the guest's egress in intermittent,
maddening-to-attribute blackouts
([#80](https://github.com/heavy-duty/box/issues/80)). Instead of refusing, a
bare `box setup-host` decides for itself: an existing `boxnet` bridge is
converged on as-is (the bridge is the pin — it is never re-addressed), and a
claimed default triggers an auto-pick of the first free `/24` from
`10.89.0.0/24` through `10.127.0.0/24`, announced loudly — so drills and
rehearsals *inside a box* work with zero flags. `BOX_SUBNET=<a.b.c.0/24>`
pins the subnet explicitly for scripted hosts (the bridge address, the ACL's
gateway carve-out and the firewall all derive from it); a pin is honored or
refused, never silently overridden. `box doctor` recognizes the poisoned
state (a gateway held as a local address, duplicate uplink routes) on the
machine it runs on and inside every box it probes.

A host still carrying the pre-0.4.0 stack: `box migrate-host --all-boxes`
re-homes each legacy box onto `boxnet` (authed state preserved), and
`box migrate-host --retire-legacy` removes the old bridge and profile once no
legacy box remains.

## Multi-user hosts: the restricted tier

One host, several people, and not everyone should hold the daemon. Incus's
socket is all-or-nothing — `incus-admin` group members own every instance on
the machine — so box layers a second tier on
[incus-user](https://linuxcontainers.org/incus/docs/main/projects/):

| tier           | who                              | what they hold                                                    |
| -------------- | -------------------------------- | ----------------------------------------------------------------- |
| **admin**      | root, or the `incus-admin` group | everything: all boxes, the stack, `setup-host`, `expose`, `grant` |
| **restricted** | the `incus` group                | their **own** boxes only, on the same hardened network            |
| none           | everyone else                    | no socket, nothing                                                |

An admin hands the tier out per user, and takes it back:

```sh
box grant dev1              # dev1 can now: box new / list / shell / snapshot / rm — their boxes only
box revoke dev1             # tier removed; their boxes survive (grant again restores).
                            #   a session they already hold keeps the socket until it
                            #   ends — revoke warns and names the loginctl command
box revoke dev1 --purge     # ...or end their sessions and delete everything they had
```

`grant` is an idempotent convergence, not a flag flip, because incus-user's
defaults miss box's contract three ways (measured on Debian 13 / Incus 6.0.4,
see [the plan doc](docs/plans/2026-07-18-restricted-tier.md)): it pins each
user to a private _unhardened_ NAT bridge, it blocks snapshots, and it cannot
see the `box-net` profile. Granting rewires all three: the user's project is
restricted to `boxnet` **and only boxnet** — the hardened network is not their
default placement but the only one their certificate can express — snapshots
and backups are allowed (the clone and `box export` workflows), and the
shipped profile is installed into their project. Re-run
`box grant <user>` after upgrading box to refresh the profile, like
`setup-host` for the stack.

What a restricted user gets is the full contract: same ACL, same DNS
isolation, same pinned resolver, same port isolation, same box↔box drop —
and their boxes cannot reach another user's box, which is the same
box↔box drop doing its one job. What they can't do stays honest: `box
expose` (daemon-global state) says to ask an admin, `box setup-host` and
`box doctor` answer at their tier instead of failing at it.

`drill/multiuser.sh` rehearses all of it live — two users, real grants, real
boxes, probes from inside — and CI runs it on every PR (container mode; the
VM boundary itself is proven on real hardware, like the rest of the drill).

## Quick start

```sh
box new --name work --template claude-box   # a creds-free coding-agent box (~10 min cold)
box shell work                              # enter as the template's user
```

Pick whichever coding-agent template you like — `claude-box`, `codex-box`,
`grok-box` — or `blank` for none. Inside the box, authenticate as needed. The
`claude-box` template looks like this; the others follow the same shape with
their own login step:

```sh
claude                           # then run /login — copy the URL (press c), open it
                                 #   in YOUR browser, paste the code back. No host CLI needed.
gh auth login                    # or drop a PAT in — your git credentials, your call
git clone https://github.com/you/project && cd project
claude                           # if the repo has .box/, the agent reads it and sets up
```

## Templates

No coding agent is special — each is one template among several, and adding
another is just another directory. What ships today:

| Template      | What it becomes                                                    |
| ------------- | ------------------------------------------------------------------ |
| `blank`       | Bare Debian 13 — same isolation, no tooling. The default.          |
| `claude-box`  | Claude Code, creds-free — where this project started               |
| `codex-box`   | OpenAI Codex CLI, creds-free                                       |
| `grok-box`    | xAI Grok CLI, creds-free                                           |
| `staging-box` | Server-class: docker + sshd hardening via rig; VM-only, autostarts |

**Templates are thin seeds; rig does the becoming**
([#81](https://github.com/heavy-duty/box/issues/81)). A template is a
directory under `templates/`: a `box.env` (image, user, resources, boot
demands, tenant role — parsed against a strict allowlist, never sourced) and
a `user-data.yaml` (cloud-init, passed to Incus verbatim except the two rig
pin tokens below). The seed is deliberately small — the tenant user, tmux,
and [rig](https://github.com/heavy-duty/rig) preinstalled, nothing that
joins a tailnet or admits credentials — and after cloud-init settles, box
auto-runs the template's **creds-free** tenant role inside the guest
(`rig bootstrap claude-box` / `codex-box` / `grok-box` / `staging-box`,
[rig#31](https://github.com/heavy-duty/rig/issues/31); the roles carry a
family suffix — `-box` for box tenants, `-server` for fleet machines — and a
template is named for the role it converges,
[rig#76](https://github.com/heavy-duty/rig/issues/76)). The agent CLI,
docker, the server posture and the agent-context file all come from that
role — convergent and idempotent, so the same command re-run later converges
an *existing* box to a newer spec (`box shell <box>` →
`sudo rig bootstrap <role>`). The agent-context file carries the
[#80](https://github.com/heavy-duty/box/issues/80) guard — never run
`box setup-host`, `box teardown-host` or the drill *inside* a box — once,
from rig's roles, instead of copy-pasted per template.

**Anything that joins or admits stays operator-run.** The `staging-box`
tenant's tailnet workload join holds a pre-auth key, so box only prints it as the
next step — `box shell <name>`, then `sudo rig bootstrap workload-server` — and
never sees the key ([#69](https://github.com/heavy-duty/box/issues/69)'s
split, kept).

**The rig pin point** (`RIG_REPO` / `RIG_REF`). The seeds preinstall rig,
which inverts the rig→box install edge
([rig#28](https://github.com/heavy-duty/rig/issues/28): rig installs box on
host-class machines; box guests now install rig). The seed's install line
carries `@RIG_REPO@`/`@RIG_REF@` tokens that box resolves at mint from the
environment:

```sh
box new --name work --template claude-box              # heavy-duty/rig @ main
RIG_REPO=you/rig RIG_REF=my-branch \
  box new --name trial --template claude-box           # a rig branch under review
```

Both directions of that edge track `main` unpinned today — said honestly,
the same way rig documents box's unpinned install
([rig#29](https://github.com/heavy-duty/rig/issues/29)) — until the release
flow lands ([rig#32](https://github.com/heavy-duty/rig/issues/32),
[#83](https://github.com/heavy-duty/box/issues/83)). The pin covers both the
installer fetched and the tree it installs, and the values are
allowlist-validated on the host before they touch the YAML.

```sh
box templates                    # list what this install can mint
box new --name scratch           # the DEFAULT template is blank: bare Debian,
                                 #   same isolation, nobody home — no rig, no role
```

A template **cannot** name a network, a profile, or a `security.*` flag —
there is no key for them. Every box launches with the shared `box-net`
profile (the isolated NIC + root disk), so every template gets the identical
trust boundary. Resources come from the template's `box.env`, overridable at
mint time — inline (`--cpu 2 --memory 3GiB --disk 20GiB`) or via
`BOX_CPU` / `BOX_MEMORY` / `BOX_DISK` environment variables (the scripting
form; flags win). The template's identity (name, user) is stamped onto the instance,
so `shell`, `exec` and `tmux` land in the right user — and a clone still
knows, because `incus copy` carries the metadata.

## Log in once, reuse via snapshots

Because every fresh box is creds-free, re-authenticating each time would be
toil. Snapshot an authenticated box and clone from it instead:

```sh
box snapshot work authed   # checkpoint after you've logged in
box new --name feature --from work/authed   # clone the authed state into a new box
```

`--from` copies the whole box (agent login, git creds, clones and all) while
preserving isolation. You can also `box new --name x --from work` to clone
a box's live state, or roll a box back with `box restore work authed` — which
asks first, since a rollback discards everything since the snapshot (`--force`
skips the prompt, and scripts must pass it: with no terminal to ask on, box
refuses rather than assuming yes).

Forgotten what you called a checkpoint? `box info work` prints the box's
snapshot labels and the `--from` line to clone one.

### `pristine` — the one checkpoint box takes for you

Every fresh mint marks a snapshot called `pristine`
([#104](https://github.com/heavy-duty/box/issues/104)) at the one moment it
is true: **after cloud-init, before `rig bootstrap` converges the tenant
role.** At that instant the guest is pristine Debian plus box's thin seed
(the user, tmux, rig) and nothing else — the state
[heavy-duty/rig#62](https://github.com/heavy-duty/rig/issues/62) calls "back
to pristine Debian". It exists for a few seconds on every mint, so box
captures it rather than asking you to be quick.

```sh
box restore work pristine   # undo the tenant role and everything since
```

That is a complete undo for every tenant role: everything `rig bootstrap
claude|codex|grok|staging` does — docker, node, the agent CLI, the
agent-context file, the role marker — is box-local and file-shaped, so a
filesystem rollback reaches all of it, without paying a ~10-minute re-mint.

Three things it deliberately does not do:

- **It is an undo, not a backup.** Snapshots die with their box: `box rm`
  deletes a box _and_ every snapshot it has. `box export` is the only state
  that outlives the box — see below.
- **It cannot reach off-box state.** A tailnet join, a GitHub runner
  registration, a pushed commit: those are records held somewhere else, and
  no filesystem rollback undoes them (rig#62 covers those separately).
- **A `--from` clone gets no `pristine` of its own.** A clone skips
  cloud-init and rig entirely, so it has no pristine moment to capture, and
  box will not label a source's worked-in state as one. Cloning a _box_
  inherits the source's snapshots (a real `pristine` among them, if the
  source had one); cloning a _snapshot_ starts with none. `box new` says
  which of the two you got.

On a host whose storage pool uses the `dir` driver, a snapshot is a full
multi-GB copy rather than a near-free copy-on-write mark, so the mint
**skips** `pristine` and says so loudly — take it by hand with `box snapshot
<box> pristine` if you want it anyway. btrfs is what `box setup-host`
installs by default precisely so snapshots are cheap. `BOX_SNAPSHOT_PRISTINE=0`
skips the mark on any host.

## Survive the host: `box export` / `box import`

Snapshots live _inside_ a box, and `box rm` deletes the box **and** its
snapshots. `box new --from` clones — but the clone still lives on the same
host, under the same stack. `box export` is the way out
([#70](https://github.com/heavy-duty/box/issues/70)): one portable file that
outlives the box, the host stack, and the machine.

```sh
box down work                        # export wants a settled disk
box export work                      # → work-<UTC stamp>.tar.gz, snapshots included
box rm work                          # nothing is lost anymore
# ...upgrade box / rebuild the host / carry the file to another machine...
box import work-<stamp>.tar.gz       # the box is back — snapshots, logins and all
box import work-<stamp>.tar.gz --name work2   # or under a new name
```

This is what makes the upgrade flow humane
([#66](https://github.com/heavy-duty/box/issues/66)): stop, export, remove
every box, upgrade, re-import. Everything `incus import` restores is the
artifact's truth (disk, config, snapshots); what box re-stamps on import is
_this_ host's truth — the `user.box=1` boundary tag, the `box-net` placement
(re-assigned if the artifact's differs), and a fresh machine identity, the
same move a clone gets, so an imported box can never collide with the box it
was exported from. Import refuses a name any existing instance already holds.
`--instance-only` exports the live state without the snapshots.

**The file is a credential.** A box's disk carries everything inside it —
agent logins, git PATs, SSH keys, shell history. Export scrubs nothing (a
"scrubbed" disk image would be a lie) and shouts instead, every time. Store
and move the file like the secret it is.

## See a dev server: `box expose`

The isolation contract says no inbound path exists — which is one "no" too
many when you're coding in a box and want its dev server in your browser.
`box expose` is the deliberate exception:

```sh
box expose work 3000             # http://127.0.0.1:3000 → work:3000
box expose work 3000 8080        # or pick the host port: 127.0.0.1:8080 → work:3000
box expose work --list           # what doors are open
box expose work --remove 3000    # close one
```

The listen side is **always the host's own loopback** — never the network, no
flag to widen it — so no other machine gains a path to the box. The in-box
server must listen on `0.0.0.0`, not its own loopback (safe inside the
isolation stack: only this door can reach it). A box with a hole says so:
`box info` lists open exposures. Everything else on the box stays dropped —
the door is per-port, punched and removable at runtime.

## Commands

```
box new --name <box> [--template <t>] [--from <src>[/<snap>]] [--cpu <n>] [--memory <size>] [--disk <size>] [--vm|--container]
box templates                # list the templates this install can mint
box list                     # list your boxes
box info <box>               # one box: state, IP, exposures, provenance, snapshots
box shell <box>              # enter as the template's user
box exec <box> -- <cmd...>   # run a command in the box
box tmux <box> [session]     # attach/create a tmux session — survives disconnects
box snapshot <box> [label]   # checkpoint (label defaults to manual-<epoch>)
box restore <box> <snap> [--force]
                             # roll back to a snapshot — destructive, asks first
                             # 'pristine' is auto-marked at mint: back to
                             # pristine Debian + box's seed, before rig ran
box export <box> [<file>] [--instance-only]
                             # one portable file (snapshots incl.) — survives rm & host
box import <file> [--name <box>]
                             # mint a box back from an exported file, re-stamped
box rename <box> <new>       # rename a box (stop it first)
box down <box>               # stop (state kept; `start` resumes)
box start <box>              # start a stopped box
box rm <box> [--force]       # delete the box + its snapshots (asks first)
box expose <box> <port> [<host-port>] | --list | --remove <port>
                             # forward a box port to host loopback — see a dev server
box incus <box> -- <args...> # escape hatch: any incus command, box resolved
box doctor [--fix|--pin-dns] # is this host fit to mint boxes? diagnose from ground truth
box setup-host               # one-time host setup: Incus, the boxnet stack, the firewall
box teardown-host [--purge-incus]   # remove the host stack (both name generations)
box migrate-host --box <n> | --all-boxes | --retire-legacy
                             # move a pre-0.4.0 host onto the box stack
box status                   # deprecated alias for `list`
box help [<command>]         # full help, or one command's page
```

Every command takes `--help`, and options come after the command
(`box list --json`). Exit status: `0` ok, `1` it went wrong, `2` you asked
wrong.

`new` fresh-launches from a template (default: `blank`), or with `--from`
clones an existing box or snapshot. VM mode (`--vm`, the default where
`/dev/kvm` exists) is the trust-less target; container mode (auto-fallback,
`security.nesting=true`) is for hosts without nested virt — weaker isolation,
dev/test only.

## What minted this box: `box info`

A box outlives the release that minted it, the template that shaped it and the
image build it came from — and until
[#103](https://github.com/heavy-duty/box/issues/103) it recorded none of them.
There is no host-side per-box store; the Incus instance config _is_ the
database, so a fact not written at mint time is simply gone. `box new` now
stamps what it knew, and `box info` reads it back:

```
NAME       work
STATE      RUNNING
TYPE       VM
IPV4       10.x.x.x

MINTED     2026-07-19T14:22:07Z by box 0.8.1
TEMPLATE   claude (user claude, role claude)
IMAGE      images:debian/13/cloud @ 8a2f1c9d4e5b…
MODE       vm (asked: auto)
RIG        heavy-duty/rig@main
ORIGIN     mint
```

The image line carries both halves on purpose: the template names an
_unpinned alias on a moving remote_, so what it resolved to at that mint is the
only reproducible fact. `box info --json` carries every key verbatim — they
ride `incus list --format json` in `config`.

**A clone re-stamps.** `incus copy` preserves `user.*` keys, so a clone inherits
its source's template and user for free — but inheriting the mint stamp would
not make it stale, it would make it **false**: the clone was not present at that
mint. `box new --from` therefore re-stamps the four keys that describe _this_
instance's coming into being (`ORIGIN clone of work/authed`, a fresh time, the
box version that cloned it) and leaves the lineage keys alone, because the
clone's disk genuinely did come from that image, template and role. `origin.from`
records one hop: a clone of a clone names its parent, not its grandparent.

**An import records the trip, and rewrites nothing**
([#131](https://github.com/heavy-duty/box/issues/131)). Everything `incus
import` restores is the _artifact's_ truth, so an imported box keeps its mint
stamp verbatim — the mint time, the box version, the image and the origin
belong to the originating host and survive the trip on purpose. What `box
import` adds is the one fact the artifact cannot carry: that the trip happened.

```
MINTED     2026-06-01T10:00:00Z by box 0.7.0
IMPORTED   2026-07-20T09:14:03Z by box 0.8.1 (the mint above predates it)
ORIGIN     clone of work/authed
```

It is **not** `origin=import`, and the difference is the whole point. `origin`
answers how the instance came into _being_ — mint or clone — and overwriting it
would destroy that: the clone above would come back claiming to be an import,
with nothing left saying it was ever a clone and an `origin.from` naming a
lineage no key explains. The import is a _third_ fact, orthogonal to the first
two, so it takes its own keys and leaves every other one alone.

The `IMPORTED` line sits directly under `MINTED` because that adjacency is what
stops the mint time being misread as this host's. Note what it does not claim:
box has no record of _which_ host minted the box, and a box can be exported and
re-imported onto the same host (that is the upgrade flow above), so the line
states only the ordering — the one thing box actually knows.

**A box can make the trip more than once**, and both ends are kept: the first
import is pinned forever, the latest is refreshed on every arrival, and a count
says how many. Last-wins alone would erase the evidence of the earlier trips,
which is the same mistake `origin=import` makes one level up. (The shape
follows [heavy-duty/rig#61](https://github.com/heavy-duty/rig/issues/61)'s
manifest: a birth pair plus a latest pair.)

**Boxes minted before this stamp existed keep working**, under this verb and
every other — they render as a box with blanks and say `MINTED (not recorded)`
rather than erroring. `user.box.schema` names the stamp's _shape_ (an integer,
not the box version) so a box minted by a later release reads back on an older
box as "here is what I understand, and there is more I don't".

## Boxes are just Incus instances

A box is an ordinary Incus instance tagged `user.box=1` (pre-0.4.0 boxes
carry `user.claudebox=1`, honored forever). box wraps the box lifecycle and
the isolation model — not all of Incus. It owns a command
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
[docs/box-design.md](docs/box-design.md) for the rule and why the
command surface is a table.

## Isolation

The contract: **a box reaches the public internet and nothing else.** Not the
host, not your LAN, not another box, not even another box's _name_. What
enforces it, layer by layer:

- **Dedicated NAT bridge** `boxnet`, IPv6 off. Every rule below is
  IPv4-only, so IPv6 would be an uncovered path — off is part of the
  contract, not a default.
- **`box-isolate` ACL** — drops all egress to private space (RFC1918,
  CGNAT, link-local), with a single carve-out to the gateway so DNS works.
- **Sibling isolation, at L2** — two boxes on one bridge are _switched_,
  never routed, so no L3 rule can separate them (learned the hard way; see
  below). `security.port_isolation` on every box NIC plus an nft
  bridge-family drop mean box A cannot exchange frames with box B at all.
- **No name-level reconnaissance** — `dns.mode=none` stops the gateway
  resolving sibling names, and the bridge's resolver is pinned to public
  upstreams (`no-resolv`), so tailnet names and split-DNS zones from a
  host-level VPN don't resolve inside a box either.
- **Host firewall** — instance → host is dropped except DNS/DHCP, including
  the host's public IPs. Entry is `incus exec` over the local socket only —
  **no inbound path exists** — unless you punch one with `box expose`, and
  that door only ever opens onto the host's own loopback (`127.0.0.1`), never
  the network.

The VM is the trust boundary: whatever runs inside — the coding agent, or
anything a template ships — can run arbitrary code and touch nothing you care
about.

### Measured, not claimed

Every clause above is probed live by an end-to-end drill, because the one time
this contract was reasoned about instead of measured, the reasoning was wrong:
box→box traffic was "covered" by an L3 drop that L2-switched frames never
meet — a hole found by probing, not by reading the rules. On a bare host the
drill installs the whole stack, mints every template cold, snapshots and
clones, probes every boundary from inside the boxes, opens and shuts the
`expose` door (and checks the contract survives it), re-homes a faithful
pre-0.4.0 box through `migrate-host`, and removes what it minted —
currently **84 checks, 84 passing**. [drill/RUNS.md](drill/RUNS.md) is the full
history, including every trap that fooled a run into a wrong verdict.

### Run the drill yourself

The drill ships in the repo, not the installed tree — run it from a checkout.
Two versions are in play and both must be current: **the drill script you
run** (a stale checkout judges the past), and **the code under test** — the
drill does not test your working tree; it installs box from GitHub
(default: `heavy-duty/box@main`) and asserts the installed tree is exactly
the ref it asked for before issuing any verdict.

```sh
git clone https://github.com/heavy-duty/box && cd box   # or refresh an existing
git log --oneline -1                                    #   checkout — this commit is
                                                        #   the drill that will judge
bash drill/doctor.sh    # read-only: is this host healthy and the stack live?
bash drill/drill.sh     # FULL end-to-end — mutates the host; use a machine you own
bash drill/wipe.sh      # scorched earth: strip BOTH name generations, images and
                        #   (--purge-storage) the pool, so a run starts from bare
```

To drill something other than latest `main` — a release ref, or a PR branch
on a fork:

```sh
bash drill/drill.sh --ref <branch-or-tag>
bash drill/drill.sh --repo <owner>/<repo> --ref <branch>   # a PR under review
```

The doctor reads ground truth, not config claims — the kernel's `isolated on`
flag per bridge port, the process table, the resolver actually in use — and
diagnoses the host faults that have actually happened: a wedged Incus daemon,
a dnsmasq that silently isn't serving, a VPN resolver that boxes would
inherit.

## Recipes: the `.box/` convention

A repo that wants to be easy to stand up in a box ships an optional `.box/`
folder — a runbook the box's coding agent reads and follows (install deps,
start services, template env, seed data, smoke-test). It is agent-facing
documentation, not a host-executed script. See
[docs/box-recipe.md](docs/box-recipe.md).

## Uninstall

`box uninstall` is the real uninstall, and it runs in the safe order — boxes
first, then the stack, then the tree — and **ends with an absence assert**:
every path it removed is re-checked, and any survivor makes it exit 1 naming
the leftovers instead of reporting a clean uninstall that wasn't (the same
discipline as `box revoke --purge`).

```sh
box uninstall <version>            # one non-current version (side-by-side cleanup)
box uninstall --all --purge-host   # everything: teardown-host (all boxes, the
                                   #   boxnet stack, the firewall), then every
                                   #   version, the symlinks, legacy claudebox crumbs
box uninstall                      # just the install — refuses while boxes exist
                                   #   (and names them); run teardown-host first,
                                   #   or use --purge-host
```

The full-removal order on a multi-user host: `box revoke <user> --purge` each
granted user (it asserts its own zero-residue, including the incus-user state
under `/var/lib/incus/users/`), then `box teardown-host` (add `--purge-incus`
to drop Incus itself, `--yes`/`BOX_YES=1` for automation), then
`box uninstall`. CI drills exactly this sequence and asserts zero residue —
no networks, profiles, nft tables, systemd units, files or symlinks.

## Non-goals

- **No unattended/CI bring-up.** The flow is interactive (log in, clone, ask
  the agent). Reproducible-by-construction provisioning is out of scope.
- **No credential storage or injection by the tool.** Boxes are creds-free;
  snapshots are the reuse mechanism, not a secrets store.
