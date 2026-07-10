# claudebox design

`claudebox` is a CLI that mints and manages **trust-less, network-isolated VMs
with Claude Code installed**. It is infrastructure, not a project provisioner.

See issue #3 for the full reframe and rationale. This doc captures the durable
design decisions.

## Principle: separate the tool from the agent

- **The tool** mints isolated boxes with Claude installed but **unauthenticated**.
  It knows nothing about projects, secrets, recipes, or memory.
- **The agent** (Claude Code, inside the box) reads an optional `.claudebox/`
  runbook in a cloned repo and acts on it. The recipe's consumer is the
  reasoning agent, not host machinery.

## Boxes are strictly creds-free

`claudebox new --name <n>` launches a blank box: everything installed, **no**
git credentials and **no** Claude credentials. The operator authenticates
interactively *inside* the box:

- **Claude** — `claude` → `/login` (paste-a-code OAuth: copy the URL, open it in
  your own browser, paste the code back). Works because the box is outbound-only;
  the tool never handles a token.
- **Git** — the operator adds their own PAT / `gh auth login` inside the box.

The tool stores and injects **no** credentials, ever. This dissolves the
multi-user problem: nothing shared, nothing committed.

## Snapshots are the reuse mechanism

Re-authing every fresh box would be toil, so authenticated state is reused via
snapshots, not a secrets store:

- `claudebox snapshot <n> [label]` — checkpoint after login + clone.
- `claudebox new --name <n2> --from <src>[/<snapshot>]` — clone an existing box
  or snapshot (authed state and all). Isolation is preserved: the clone keeps
  the `claude-dev` profile + `claudenet` + ACL.
- `claudebox restore <n> <snapshot>` — roll a box back to a checkpoint.

Log in once → snapshot → spin up authed boxes from it.

## The box announces itself to the agent

cloud-init installs a global `~/.claude/CLAUDE.md` in every box telling Claude it
is running in a claudebox (trust-less, ephemeral, creds-free) and to treat a
repo's `.claudebox/` folder as its bootstrap runbook. No "tell it" step, no host
execution.

## `.claudebox/` is optional, agent-facing documentation

Not host-executed shell. A repo that wants to be easy to stand up in a sandbox
ships a runbook (prose + optional scripts the agent may run). A repo that does
not, you set up by hand. The tool enforces no contract; there is no `install`.

## Isolation (unchanged)

Dedicated NAT bridge `claudenet` + Incus `claude-isolate` ACL dropping all
RFC1918/CGNAT/link-local egress, plus host-firewall rules blocking instance →
host. The instance reaches the internet and nothing else. Entry is `incus exec`
over the local socket — no inbound path. The VM is the trust boundary.

## Non-goals

- No unattended/CI bring-up — the flow is interactive.
- No credential storage or injection by the tool.
