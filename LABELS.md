# Labels

How this repo uses GitHub labels. The taxonomy is shared across the
heavy-duty repos (box, rig, cast) — only the `scope:` set differs per repo,
because it names this repo's actual surfaces.

## State — who is the ball with? (PRs, exactly one)

Every open PR carries exactly one `state:` label, and it answers the only
question a board scan actually asks: *who is this PR waiting on?* The states
mirror the review loop this repo runs — PRs open as drafts, three reviewer
bots pick up ready PRs with reviews requested, each round is answered in a
single reply, and a human takes the final review.

| Label | Color | Waiting on | Enters when | Leaves when |
|---|---|---|---|---|
| `state:building` | `#FBCA04` | the coding agent, still building | PR opened as draft | marked ready + bot reviews requested |
| `state:bots-reviewing` | `#1D76DB` | the reviewer bots to finish the round | ready with reviews requested, or fixes pushed and reviews re-requested | all three bots have reviewed the round |
| `state:addressing` | `#D93F0B` | the coding agent to reply and push fixes | all bots reviewed the round, not all approved | the single round-reply is posted and fixes pushed |
| `state:needs-human` | `#8250DF` | the human reviewer | all three bots approve | merged — or changes requested, which cycles back to `state:addressing` |

`bots-reviewing` and `addressing` are deliberately distinct: staleness in the
first means *poke the bots*, staleness in the second means *the agent dropped
the ball*. Collapsing them loses exactly the information a sweep needs.

## Cross-cutting (PRs and issues)

| Label | Color | Meaning |
|---|---|---|
| `stale` | `#B60205` | No activity for 48h. Sweep-managed, never hand-applied. `state:building` + `stale` is precisely a forgotten draft. |
| `blocked` | `#6A737D` | Waiting on another PR or issue to land first. Quiet *legitimately* — the staleness sweep skips it. |
| `release` | `#0E8A16` | Release flow, versioning, and packaging work. |

## Scope — which surface? (PRs and issues, any number)

All scopes share one calm color, `#C5DEF5` — scopes locate, states alert.

| Label | Covers |
|---|---|
| `scope:cli` | `bin/box` — the command surface itself |
| `scope:installer` | `install.sh`, the versioned install layout, upgrade/uninstall |
| `scope:host` | `host/` — setup-host, teardown, the firewall and isolation stack |
| `scope:tiers` | the restricted tier — grant/revoke, multi-user semantics |
| `scope:templates` | `templates/` — the box seeds |
| `scope:drill` | `drill/` — the rehearsals, doctor, RUNS.md |

## Issue types

`bug`, `enhancement`, `documentation` — issues only. PRs carry their type in
the conventional title (`feat:`, `fix:`, `docs:`), so typing a PR with a label
would just say the same thing twice, drifting apart eventually.

## Maintenance

State labels are written by automation, never by hand. Every state above is
derivable from GitHub's own facts — the draft flag, requested reviewers,
review states, push timestamps — so a scheduled workflow recomputes the state
and reconciles labels statelessly. A hand-moved label is a lie waiting to
happen; the workflow asserts the effective state instead. Until that workflow
lands, treat `state:` labels as advisory.

The same workflow bootstraps the taxonomy: it creates any missing label
idempotently. To create them by hand (needs push access):

```sh
gh label create "state:building"       --color FBCA04 --description "PR is a draft — the coding agent is still building" --force
gh label create "state:bots-reviewing" --color 1D76DB --description "Waiting on the bot reviewers to finish the round" --force
gh label create "state:addressing"     --color D93F0B --description "All bots reviewed — coding agent owes the single reply + fixes" --force
gh label create "state:needs-human"    --color 8250DF --description "All bots approve — waiting on the human reviewer" --force
gh label create "stale"                --color B60205 --description "No activity for 48h — needs a poke (sweep-managed)" --force
gh label create "blocked"              --color 6A737D --description "Waiting on another PR or issue to land first" --force
gh label create "release"              --color 0E8A16 --description "Release flow and version/packaging work" --force
gh label create "scope:cli"            --color C5DEF5 --description "bin/box — the command surface" --force
gh label create "scope:installer"      --color C5DEF5 --description "install.sh, versioned installs, upgrade/uninstall" --force
gh label create "scope:host"           --color C5DEF5 --description "host/ — setup, teardown, firewall, isolation stack" --force
gh label create "scope:tiers"          --color C5DEF5 --description "restricted tier — grant/revoke, multi-user" --force
gh label create "scope:templates"      --color C5DEF5 --description "templates/ — the box seeds" --force
gh label create "scope:drill"          --color C5DEF5 --description "drill/ — rehearsals, doctor, RUNS.md" --force
gh label delete duplicate --yes; gh label delete invalid --yes; gh label delete question --yes
gh label delete wontfix --yes; gh label delete "help wanted" --yes; gh label delete "good first issue" --yes
```
