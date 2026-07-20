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
| `state:needs-rebase` | `#B60205` | the coding agent to rebase or fix | the branch does not merge — GitHub says `CONFLICTING`, or a check has failed | it merges cleanly and checks are green again |
| `state:needs-human` | `#8250DF` | the human reviewer | the PR **could be merged right now**: mergeable, checks not failing, three formal head-current approvals — and the human review is requested | merged — or changes requested, which cycles back to `state:addressing` |

`bots-reviewing` and `addressing` are deliberately distinct: staleness in the
first means *poke the bots*, staleness in the second means *the agent dropped
the ball*. Collapsing them loses exactly the information a sweep needs.

**`state:needs-human` means one thing: a human could merge this right now.**
Anything that makes that false outranks the review request that put it there,
because the label is the only signal a maintainer scanning the board (or a
phone) actually reads — and a label that says "your turn" on an unmergeable PR
is worse than no label at all. Two things therefore take precedence over an
explicit human request:

- **it does not merge** — `CONFLICTING`, or a failing check → `state:needs-rebase`
- **nobody reviewed *this* head** — every approval staled by a push → `state:addressing`,
  because the agent owes a re-request

The second is the more dangerous of the two: with a conflict, GitHub at least
disables the merge button, while a staled-approval PR reads green, mergeable
and "waiting on the human" over code no reviewer has seen.

`UNKNOWN` mergeability is deliberately **not** treated as unmergeable. GitHub
reports it for about a minute after every merge while it recomputes, and
flapping every open PR through `needs-rebase` on each merge would be worse than
the bug this precedence fixes.

An *unfinished* round still yields to an explicit human request — a maintainer
pulling a PR to themselves early is a deliberate act. `MISSING` (nobody has
reviewed yet) and `STALE` (everyone reviewed something else) are different
facts and are treated differently.

## Cross-cutting (PRs and issues)

| Label | Color | Meaning |
|---|---|---|
| `stale` | `#B60205` | No activity for 48h. Sweep-managed, never hand-applied. `state:building` + `stale` is precisely a forgotten draft. |
| `blocked` | `#6A737D` | Waiting on another PR or issue to land first. Quiet *legitimately* — the staleness sweep skips it. |
| `release` | `#0E8A16` | Release flow, versioning, and packaging work. |
| `merge-next` | `#0E8A16` | Head of the merge queue — **merge this one next**. Queue order is *intent* (which PR lands first, given how they conflict), so the reconciler never sets it: you or the agent maintaining the queue do. The reconciler only **clears** it, the moment the PR stops being something a human could merge — so it cannot go stale the way `state:needs-human` did. |

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
review states, push timestamps — so the labels workflow
([.github/workflows/labels.yml](.github/workflows/labels.yml)) recomputes the
state and reconciles labels statelessly, on a 15-minute cron plus PR events.
A hand-moved label is a lie waiting to happen; the workflow asserts the
effective state instead. `scope:` labels on PRs are applied from the changed
paths by actions/labeler ([.github/labeler.yml](.github/labeler.yml));
[CONTRIBUTING.md](CONTRIBUTING.md) says who sets what.

The same workflow bootstraps the taxonomy: a manual dispatch creates any
missing label idempotently. To create them by hand (needs push access):

```sh
gh label create "state:building"       --color FBCA04 --description "PR is a draft — the coding agent is still building" --force
gh label create "state:bots-reviewing" --color 1D76DB --description "Waiting on the bot reviewers to finish the round" --force
gh label create "state:addressing"     --color D93F0B --description "All bots reviewed — coding agent owes the single reply + fixes" --force
gh label create "state:needs-rebase"   --color B60205 --description "Does not merge — conflicts or failing checks; the agent owes a fix" --force
gh label create "state:needs-human"    --color 8250DF --description "All bots approve — waiting on the human reviewer" --force
gh label create "merge-next"           --color 0E8A16 --description "Head of the merge queue — merge this one next (set by hand/agent, cleared here)" --force
gh label create "stale"                --color B60205 --description "No activity for 48h — needs a poke (sweep-managed)" --force
gh label create "blocked"              --color 6A737D --description "Waiting on another PR or issue to land first" --force
gh label create "release"              --color 0E8A16 --description "Release flow and version/packaging work" --force
gh label create "scope:cli"            --color C5DEF5 --description "bin/box — the command surface" --force
gh label create "scope:installer"      --color C5DEF5 --description "install.sh, versioned installs, upgrade/uninstall" --force
gh label create "scope:host"           --color C5DEF5 --description "host/ — setup, teardown, firewall, isolation stack" --force
gh label create "scope:tiers"          --color C5DEF5 --description "restricted tier — grant/revoke, multi-user" --force
gh label create "scope:templates"      --color C5DEF5 --description "templates/ — the box seeds" --force
gh label create "scope:drill"          --color C5DEF5 --description "drill/ — rehearsals, doctor, RUNS.md" --force
# delete is not an upsert: a label that is already gone exits non-zero. Swallow
# that, so this block converges on re-run instead of erroring after first success.
for L in duplicate invalid question wontfix "help wanted" "good first issue"; do
  gh label delete "$L" --yes 2>/dev/null || true
done
```
