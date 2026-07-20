# box design

`box` is a CLI that mints and manages **trust-less, network-isolated VMs
with a coding agent installed** (`claude-box`, `codex-box`, `grok-box`, or
`blank` for none). It is infrastructure, not a project provisioner.

See issue #3 for the full reframe and rationale. This doc captures the durable
design decisions.

## Principle: separate the tool from the agent

- **The tool** mints isolated boxes with the agent installed but **unauthenticated**.
  It knows nothing about projects, secrets, recipes, or memory.
- **The agent** (Claude Code, Codex, Grok — whichever template, inside the box)
  reads an optional `.box/` runbook in a cloned repo and acts on it. The recipe's
  consumer is the reasoning agent, not host machinery.

## Boxes are strictly creds-free

`box new --name <n>` launches a blank box: everything installed, **no**
git credentials and **no** agent credentials. The operator authenticates
interactively *inside* the box:

- **The coding agent** — e.g. `claude` → `/login` (paste-a-code OAuth: copy the
  URL, open it in your own browser, paste the code back); `codex` and `grok`
  have their own login step. Works because the box is outbound-only; the tool
  never handles a token.
- **Git** — the operator adds their own PAT / `gh auth login` inside the box.

The tool stores and injects **no** credentials, ever. This dissolves the
multi-user problem: nothing shared, nothing committed.

## Snapshots are the reuse mechanism

Re-authing every fresh box would be toil, so authenticated state is reused via
snapshots, not a secrets store:

- `box snapshot <n> [label]` — checkpoint after login + clone.
- `box new --name <n2> --from <src>[/<snapshot>]` — clone an existing box
  or snapshot (authed state and all). Isolation is preserved: the clone keeps
  the `box-net` profile + `boxnet` + ACL.
- `box restore <n> <snapshot>` — roll a box back to a checkpoint.

Log in once → snapshot → spin up authed boxes from it.

Snapshots are in-box state: `box rm` deletes a box *and* its snapshots, and a
clone still lives on the same host. The off-host mechanism is `box export` /
`box import` (#70) — one portable backup tarball, snapshots included by
default, that survives `rm`, a host teardown, an upgrade, a move. The split
of truths is the design: everything `incus import` restores is the artifact's
(disk, config, snapshots); everything box re-stamps on import is the current
host's (the `user.box=1` boundary tag, the `box-net` placement, a fresh
machine identity via the same `reset_identity` a clone gets, and the record
that the trip happened). That last one is #131, and it is deliberately *not*
`origin=import`: `origin` says how the instance came into **being** — mint or
clone — and the import is a third, orthogonal fact. Overwriting `origin` would
make an exported clone come back claiming to be an import, with its
`origin.from` lineage left unreadable, so the import gets its own keys and the
artifact's mint stamp survives the trip untouched. Auth state
rides along deliberately — and because scrubbing a disk image is a promise
tarball surgery cannot keep, export shouts that the file is a credential
instead of pretending to sanitize it.

## Thin templates: box mints, rig converges (#81)

A template is a **thin, creds-free seed** — base image, the tenant user,
tmux, and [rig](https://github.com/heavy-duty/rig) preinstalled — and what
the box *becomes* lives in rig's bootstrap roles (rig#31): box auto-runs the
template's creds-free tenant role after cloud-init (`rig bootstrap claude-box`
/ `codex-box` / `grok-box` / `staging-box` — the roles carry a family suffix,
`-box` for box tenants and `-server` for fleet machines, and the templates are
named for the roles they converge, rig#76), which installs the agent CLI or
server posture. The split is deliberate: cloud-init is a first-boot one-shot —
not convergent, not re-runnable, only parse-and-grep testable — while a rig
role is an idempotent script with effective-state asserts that can also
converge an *existing* box to a newer spec. Anything that joins a tailnet or
holds a key (the staging-box tenant's workload join) stays operator-run
through `box shell`; box prints it as a next step and never sees the key. The
seed's rig install is pinned by `RIG_REPO`/`RIG_REF` at mint (default
`heavy-duty/rig@main`, unpinned — the honest edge until rig#32's releases),
and box's template suite holds the line with fail-closed absence greps: no
agent CLI, no docker, no tailscale, no context-file heredocs in any
template, ever again.

## The box announces itself to the agent

Every coding-agent box gets a global agent-context file
(`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, `~/.grok/AGENTS.md`) telling the
agent it is running in a box (trust-less, ephemeral, creds-free) and to treat a
repo's `.box/` folder as its bootstrap runbook. No "tell it" step, no host
execution. The file is rendered by rig's tenant roles from one shared
template (#81) — including the #80 guard: never run `box setup-host`,
`box teardown-host` or the drill inside a box; a nested box stack claims the
guest's own uplink subnet and silently breaks its networking.

## `.box/` is optional, agent-facing documentation

Not host-executed shell. A repo that wants to be easy to stand up in a sandbox
ships a runbook (prose + optional scripts the agent may run). A repo that does
not, you set up by hand. The tool enforces no contract; there is no `install`.

## What box owns, and what it doesn't

Boxes are ordinary Incus instances, tagged `user.box=1`. That makes every
Incus verb a candidate feature request — `rename`, `info`, `file push`, on
forever — and wrapping them one at a time grows a worse `incus`. The rule:

> **box owns a command when it must enforce an invariant Incus cannot see:**
> the `user.box=1` boundary (never touch an instance we didn't mint), the
> isolation stack (`box-net` profile + `boxnet` + ACL), or the creds-free
> snapshot→clone workflow. Everything else is Incus's job.

The rule cuts both ways, and that's the point:

- `rename` **is** ours — not because it adds logic to `incus rename`, but because
  resolving the name *is* the logic: check the tag, apply `--remote`, and notice
  the box is running (Incus won't rename a running instance) so we can say "stop
  it first" rather than leak an Incus error.
- `incus config set security.nesting=false` is **not** ours. It dismantles the
  trust boundary; wrapping it would imply we bless it.

Two mechanisms keep this honest.

**The command table** (`CMDS` in `bin/box`) is the single source of truth
for what exists, its synopsis, its help line, its preconditions and what runs.
Dispatch and help are both rendered from it, so the help cannot describe a
command that doesn't exist — the failure that produced #8. A thin verb is one
row; a verb that can't be expressed as a row and enforces no invariant of ours
doesn't belong in the tool.

**The escape hatch** — `box incus <box> -- <args...>` — resolves and
tag-checks the box, then hands the rest to Incus verbatim. It means "no" to a
proxy request is not "you can't do that", and it keeps the one rail that matters:
you cannot aim it at an instance box didn't mint. If the command can move
the box off the isolation stack (profile, network, device, `security.*`), it
warns and proceeds — from there the trust boundary is yours to keep.

## Isolation

Dedicated NAT bridge `boxnet` + Incus `box-isolate` ACL dropping all
RFC1918/CGNAT/link-local egress, plus host-firewall rules blocking instance →
host. Entry is `incus exec` over the local socket — no inbound path. The VM is
the trust boundary.

**A box reaches the public internet and nothing else — including no other box.**
That last clause is the one that was assumed and turned out to be false, so it
is spelled out here with the mechanism, and `drill/` tests it on every run.

- **Box → host, LAN, RFC1918, CGNAT, link-local:** the `box-isolate` ACL.
- **Box → box: an nftables *bridge-family* rule** (`host/box-firewall.sh`).
  It cannot be an ACL rule. Two boxes on one bridge share an L2 segment, so
  their frames are *switched* between bridge ports and never traverse the
  netfilter path an L3 ACL lives on — the ACL looked airtight (it drops
  `10.0.0.0/8`, which contains `boxnet`) while box→box was in fact wide open.
  A live probe found box A's SYN arriving at box B. The bridge family's forward
  hook fires exactly on port-to-port frames, which on this bridge means box→box
  and nothing else: gateway traffic and routed egress are delivered locally, not
  forwarded. Dropping every forwarded frame therefore isolates the boxes and
  costs them nothing.
- **Box → box by NAME:** `dns.mode=none`. dnsmasq on the gateway held a record
  for every instance, so a box could enumerate its siblings even where it could
  not reach them. Blocked connections with open reconnaissance is not isolation.
- **IPv6:** off (`ipv6.address=none`), and that is a *contract*, not a default —
  every rule above is IPv4-only, so IPv6 would be an uncovered path.
- **`security.ipv4_filtering`: deliberately NOT used.** It breaks the box's
  networking (in-box Docker cannot pull or run a container). Tested, vetoed.

The rule that keeps this honest: **isolation claims are tested, never reasoned
about.** The box→box hole existed because a plausible code reading said it could
not. See `drill/RUNS.md`.

## Multi-user hosts: access tiers

The daemon socket is binary — `incus-admin` holds everything on the machine —
so a shared host needs a second tier, and Incus ships one: **incus-user**
confines an `incus`-group member to an auto-created project `user-<uid>`,
behind a restricted certificate that cannot name any other project. The tier
is decided once, from the process's live credentials (`box_tier()`: UID 0 or
`incus-admin` → admin; `incus` alone → restricted; neither → none), and every
tier-aware verb reads that one function.

What incus-user does *not* do is honor box's contract — measured on Debian 13
/ Incus 6.0.4 (#74), after the design that assumed it (#72) was vetoed by its
own Task-0 rehearsal:

- it pins each user's project to a private auto-created bridge
  (`incusbr-<uid>`) — a stock NAT bridge with **none** of the hardening: no
  ACL, no `dns.mode=none`, no resolver pin, IPv6 on;
- it blocks snapshots — box's entire reuse workflow;
- the `box-net` profile lives in the default project, invisible to theirs.

So the tier is an **admin-run convergence** (`box grant <user>`), not a
group membership: put them in `incus`, touch incus-user once as them (the
project is created lazily; nothing exists to converge until it does), then
rewire the project — network access narrowed to `boxnet` **and only
`boxnet`**, snapshots allowed, the shipped profile installed. Narrowing is
the load-bearing decision: granting `boxnet,incusbr-<uid>` (the obvious fix)
would leave an unhardened NAT bridge one `--network` flag away from any box
they mint. With the private bridge unreferenced (its `eth0` is removed from
their default profile) and outside `restricted.networks.access`, the hardened
network is not their default placement — it is the only placement their
certificate can express. The grant survives incus-user restarts by that
tool's own design (it configures a project only at creation), and a restricted
certificate cannot widen its own project — both measured, not read.

Cross-USER isolation is the same mechanism as cross-box isolation, on
purpose: their instances share `boxnet` with everyone's, and the bridge-family
drop + port isolation + `dns.mode=none` already make any two boxes strangers.
A restricted user CAN strip `security.port_isolation` from the profile copy
in their own project — or skip the profile entirely and attach `boxnet` raw
(`--network boxnet`); the network must be usable for the profile to work, and
Incus has no allow-via-profile-only lever. So the guarantee is scoped, and
said plainly: **per-NIC port isolation is guaranteed for box-minted
instances; a raw attachment keeps every network-owned control (the ACL,
`dns.mode=none`, the resolver pin) and every host-owned one (the nft bridge
drop) — losing only the redundant per-NIC L2 layer.** Scoped, and measured:
`drill/multiuser.sh` criterion (m) launches exactly that raw instance and
probes egress, RFC1918, both sibling directions and name enumeration from
inside it. Defense in depth, every layer measured (criteria a–n).

`box revoke` is two strengths: bare, it removes the group — their boxes keep
*running* (revoking a person does not kill their workloads), `grant` restores
everything, and because supplementary groups are read at login, revoke warns
when live sessions keep the socket until they end (and names the `loginctl`
command). `--purge` terminates those sessions *first* — a stale-group process
could otherwise touch incus-user after the purge and lazily recreate the
project with stock, unhardened defaults, undoing the grant's whole point —
then deletes their world (boxes, images, project, private bridge, trust-store
certificate) and asserts the absence afterwards. A failed `grant` backs its
own group-add out on exit for the same reason: no half-granted user holding
an un-narrowed socket.

## Non-goals

- Interactive-first: install and setup prompt by default (`BOX_YES=1` and the
  CI rehearsal job are the sanctioned unattended paths).
- No credential storage or injection by the tool.
- No per-user resource quotas on the restricted tier (Incus's
  `limits.*`/`restricted.*` project keys exist when someone needs them).
