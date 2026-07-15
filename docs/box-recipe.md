# The `.box/` convention

`box` mints trust-less, creds-free, isolated VMs with Claude Code already
installed (`box new/shell/snapshot/restore/exec/down/start/rm/status`). The
tool knows **nothing** about your project. There is no `install` step and no
host-run setup script.

A project makes itself easy to stand up inside a box by shipping an optional
`.box/` folder. This folder is **agent-facing documentation** — read and
acted on by Claude Code (the reasoning agent) running inside the box. It is not
shell that the host executes.

> The folder was named `.claudebox/` before the 0.5.0 rename. Repos that still
> ship `.claudebox/` keep working — the agent is told to read either — but new
> projects should use `.box/`.

## What it is / what it is not

- **Optional.** No `.box/` is a perfectly valid state.
- **Agent-facing.** You are writing instructions to a reasoning agent, not a
  machine. Prose is fine; the agent adapts.
- **Not a host contract.** The host never parses, sources, or runs anything in
  here. There is no enforced schema and no required filenames.
- Old model: a host-executed `.devbox/setup.sh`. New model: a runbook the agent
  reads and decides how to act on.

## How it's consumed

Every box ships a global `~/.claude/CLAUDE.md` telling Claude it is inside a
box and to treat a repo's `.box/` folder as its bootstrap runbook.
So the whole flow is:

```
box new           # get a box
box shell         # get in
git clone <repo> && cd <repo>
claude                  # Claude reads .box/ and brings the project up
```

The operator can also just say: *"set this project up per .box"*.

## Suggested contents (all optional)

Author everything here for a reasoning agent.

- **`.box/SETUP.md`** — the prose runbook. Prerequisites, how to install
  deps, how to start services, how to template the env, how to seed data, and
  how to smoke-test. Written as instructions to Claude.
- **Helper scripts** (e.g. `.box/dev-up.sh`) that the runbook tells Claude
  to run. Claude decides to run them; the host never does.
- **`.box/env.template`** — example env the runbook explains how to fill.
  Staging values the operator pastes in. **Never commit real secrets.**
- **`.box/compose.yml`** — optional services the runbook starts.

## Worked example

A minimal `.box/SETUP.md` for a Node + Postgres app:

```markdown
# Setup

This is a Node service backed by Postgres.

1. Install deps: `npm ci`
2. Start Postgres: `docker compose -f .box/compose.yml up -d`
3. Create the env file: copy `.box/env.template` to `.env` and ask the
   operator to fill in `DATABASE_URL` and `API_KEY` (staging values).
4. Run migrations: `npm run migrate`
5. Start the app: `npm run dev`
6. Smoke-test: `curl -sf localhost:3000/health` should return `{"ok":true}`.
```

That's it — Claude reads it top to bottom and adapts if reality differs.

## Guidance

- **Keep it declarative and resilient.** State intent and steps; let the agent
  adapt when the repo has drifted. Don't hard-code brittle assumptions.
- **Never put real credentials in `.box/`.** Templates and staging
  placeholders only. The operator pastes real values at runtime.
- **No `.box/` is fine.** The operator can stand the project up by hand,
  or let Claude infer the steps from the repo's `README` / `CLAUDE.md`.
