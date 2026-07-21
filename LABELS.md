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
| `state:addressing` | `#D93F0B` | the coding agent to reply, fix, or ask | all bots reviewed and not all approved; or nobody was asked; or a blocker is up | the round-reply is posted and fixes pushed — and any blocker named alongside is cleared |
| `state:needs-human` | `#8250DF` | the human reviewer | the PR **could be merged right now**: no blockers, three formal head-current approvals — and the human review is requested | merged — or changes requested, which cycles back to `state:addressing` |

`bots-reviewing` and `addressing` are deliberately distinct: staleness in the
first means *poke the bots*, staleness in the second means *the agent dropped
the ball*. Collapsing them loses exactly the information a sweep needs.
`bots-reviewing` therefore means strictly *a request is live and an answer is
coming* — a PR nobody was asked to review is the agent's ball, not the bots'.

## The second axis: `blocker:*`

State answers *whose ball is it*. Blockers answer *what is in the way*, and
unlike states they are *facts about the branch* — mutually independent, so a
PR carries as many as apply.

| Label | Color | Means | Clears when |
|---|---|---|---|
| `blocker:conflict` | `#B60205` | GitHub says `CONFLICTING` — the agent owes a **rebase** | it merges cleanly |
| `blocker:ci-red` | `#B60205` | a check failed — the agent owes a **fix**, which a rebase will not provide | checks are green |
| `blocker:unrequested` | `#E99695` | this head has no verdict from somebody — never reviewed, or staled by a push — and **nobody was asked** for one | reviews are requested |
| `blocker:drill-pending` | `#B60205` | a `release` PR whose version has no drill record in [drill/RUNS.md](drill/RUNS.md) — the ceremony is **correct but unevidenced** | the drill is run and recorded (or a waiver is recorded) under `## Release drill — X.Y.Z` |

`blocker:drill-pending` is the one blocker that says the diff is *fine*. The
version is stamped, the changelog is right, CI's other guards are green — what
is missing is the evidence that the release was proven on real hardware, which
[.github/scripts/drill-recorded.sh](.github/scripts/drill-recorded.sh) refuses
to let a release ship without (CONTRIBUTING.md, "Releases"). Naming it
separately from `blocker:ci-red` matters because the two owe different work: a
red check is a fix in the branch, a pending drill is an hour on a real host.

It must be **created by a maintainer account** — the bot account gets a `403`
creating labels, so the labels workflow's bootstrap dispatch cannot mint it.
Until it exists in the repo, `blocked` stands in: it is the closest true thing
(the PR is waiting on something outside itself) and, usefully, the staleness
sweep already skips it, so a release parked overnight on a drill does not
collect a `stale`.

One rule joins the axes: **`state:needs-human` requires zero blockers.** Any
blocker means the work is the agent's, whatever the review round says.

This split exists because the single-label version kept lying. Independent
facts were projected onto one totally-ordered label, so one always had to win
and the losers vanished off the board: a PR that was *both* conflicted and red
could only say one of them, and `needs-rebase` told an agent to rebase when
what it actually owed was a bug fix. Precedence between two blockers is not a
question a set has to answer, which is why every ordering bug this machine has
had — `needs-human` surviving a conflict, `MISSING` swallowing `STALE` — lived
on the axis that had to be totally ordered.

`state:needs-rebase` was the first attempt at this and is **retired**; the
reconciler strips it on sight so no PR is left carrying a label nothing
recomputes.

**`state:needs-human` means one thing: a human could merge this right now.**
The label is the only signal a maintainer scanning the board (or a phone)
actually reads, and one that says "your turn" on an unmergeable PR is worse
than no label at all. So beyond the blockers, one review fact also outranks an
explicit human request:

- **nobody reviewed *this* head** — every approval staled by a push → `state:addressing`,
  because the agent owes a re-request

That case is more dangerous than any blocker: a blocked PR at least shows an X
or a disabled merge button, while a staled-approval PR reads green, mergeable
and "waiting on the human" over code no reviewer has seen.

`UNKNOWN` mergeability is deliberately **not** treated as a conflict. GitHub
reports it for about a minute after every merge while it recomputes, and
flapping every open PR through `blocker:conflict` on each merge would be worse
than the bug this fixes. A failed read of either branch fact degrades to the
same "do not know" value, for the same reason.

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

State labels are machine-owned, with exactly one exception. Every state above
is derivable from GitHub's own facts — the draft flag, requested reviewers,
review states, push timestamps — so the labels workflow
([.github/workflows/labels.yml](.github/workflows/labels.yml)) recomputes the
state and reconciles labels statelessly, on PR events (label changes included)
plus a 15-minute cron. A hand-moved label is a lie waiting to happen; the
workflow asserts the effective state instead.

The exception is `state:needs-human`, which the author sets at handoff
([CONTRIBUTING.md](CONTRIBUTING.md), step 6). That is an optimistic write, not
a transfer of ownership: because `pull_request_target: labeled` wakes the
workflow, the author's own label write fires the sweep that validates it, and
a handoff that had not earned the label is corrected within seconds.

It exists because the wake signal was missing. There is no
`pull_request_review_target` — on fork PRs, which is all of them here,
`pull_request_review` runs read-only and cannot label anything — so the moment
the label becomes true, the third approval landing, fired nothing at all. What
was left was the `*/15` cron, and GitHub deprioritises short intervals hard
enough that the delivered rate is closer to hourly. The label could therefore
lag the round it described by hours, worst on the quietest repo: every sweep
reconciles the whole board, so a busy repo stays fresh by piggybacking on
unrelated PR events, while a quiet one depends on the cron most and receives
it least. `scope:` labels on PRs are applied from the changed
paths by actions/labeler ([.github/labeler.yml](.github/labeler.yml));
[CONTRIBUTING.md](CONTRIBUTING.md) says who sets what.

The same workflow bootstraps the taxonomy: a manual dispatch creates any
missing label idempotently. To create them by hand (needs push access):

```sh
gh label create "state:building"       --color FBCA04 --description "PR is a draft — the coding agent is still building" --force
gh label create "state:bots-reviewing" --color 1D76DB --description "Waiting on the bot reviewers to finish the round" --force
gh label create "state:addressing"     --color D93F0B --description "All bots reviewed — coding agent owes the single reply + fixes" --force
gh label create "blocker:conflict"     --color B60205 --description "Does not merge — the branch conflicts and the agent owes a rebase" --force
gh label create "blocker:ci-red"       --color B60205 --description "A check is failing — the agent owes a fix (not a rebase)" --force
gh label create "blocker:unrequested"  --color E99695 --description "Somebody still owes a verdict and nobody was asked for one" --force
# retired — the reconciler strips it; delete it once no PR carries it
# gh label delete "state:needs-rebase"
gh label create "state:needs-human"    --color 8250DF --description "No blockers, all bots approve — waiting on the human reviewer" --force
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
