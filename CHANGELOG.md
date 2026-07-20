# Changelog

History before 0.5.0 lives in git and in [drill/RUNS.md](drill/RUNS.md),
which records not just what changed but what each drill run proved.

## Unreleased

### Changed

- **PR labels split into two axes: `state:*` (whose ball) and `blocker:*`
  (what is in the way)** — `state:needs-rebase` is retired, replaced by
  `blocker:conflict`, `blocker:ci-red` and `blocker:unrequested`. One rule
  joins them: `state:needs-human` requires zero blockers.

  The single-label design forced independent facts through one totally-ordered
  value, and the ordering was where every bug lived. Mergeability, check
  status and the review round move independently — a PR can be conflicted
  *and* red *and* stalled at once — so a total order has to pick a winner and
  silently drop the rest. `state:needs-rebase` was the clearest casualty: it
  fired on both a conflict and a failing check, which need opposite work, and
  told an agent to rebase when what it owed was a bug fix. On this repo's own
  board, #120 was conflicted **and** red and could only say one of them.

  Blockers are a set, so there is no precedence between them to get wrong.
  What is left on the ordered axis is purely about reviews, which is the one
  place an ordering is genuinely meaningful.

  `state:bots-reviewing` also tightens to mean strictly *a request is live and
  an answer is coming*. A ready PR nobody was asked to review read "waiting on
  the reviewers" for the 48 hours it took the stale sweep to notice; it is now
  `state:addressing` + `blocker:unrequested`, because the agent owes the ask.
  Drafts are exempt (the bots ignore drafts by design), as is an explicit
  human request — a maintainer claiming a PR early is deliberate.

  The reconciler strips `state:needs-rebase` on sight, so the retirement heals
  the board rather than stranding a label nothing recomputes. It also never
  *names* a label the repo does not have: `gh issue edit` rejects the whole
  call on one unknown name, so on a repo whose taxonomy predates this change
  an unbootstrapped `blocker:*` would otherwise take the state convergence
  down with it, on exactly the PRs the change exists to fix. Adds are filtered
  against the repo's real label set and the shortfall is logged.
  Fixtures 51 → 66.

- **The tenant templates carry rig's family suffix: `claude` → `claude-box`,
  `codex` → `codex-box`, `grok` → `grok-box`, `staging` → `staging-box`**
  (#123, following heavy-duty/rig#76) — rig is growing a second family of
  roles, and once a `staging` role can mean either a fleet machine or a box
  tenant, the bare name stops naming anything. rig's answer is a suffix on
  the role itself — `-server` for fleet machines, `-box` for box tenants —
  and box's answer is that a template keeps being named for the role it
  converges. Templates are the only surface that spells a rig role out loud
  (`BOX_BOOTSTRAP_ROLE`, auto-run at mint since #81), so a template whose
  directory says one thing and whose role key says another is a trap with a
  15-minute fuse: it mints clean and dies at convergence. `blank` keeps its
  name — it seeds no tenant role, sets no `BOX_BOOTSTRAP_ROLE`, and
  therefore has nothing to agree with. Two namespaces move apart here and
  only one of them moved: the template name and the role are now
  `claude-box`, while the seed USER stays `claude`, because that is the user
  the rig role converges and the one `box shell` lands in. `test/cli.sh`
  pins the pair per tenant rather than each half alone — a future rename
  that moves one and forgets the other mints a box whose role dies looking
  for a user nobody created.

  **This lands after rig's rename, not before, and the ordering is not a
  preference.** The seeds install rig from `RIG_REPO`/`RIG_REF`, which
  default to `heavy-duty/rig@main` and are unpinned until rig#32's releases
  — so a box minted from these templates asks whatever `main` happens to be
  for `rig bootstrap claude-box`. Against a pre-rename rig that role does
  not exist, `cmd_new` refuses to call the box ready, and the operator is
  handed a failed mint for a change neither repo has finished making. Merged
  in the other order the window closes instead of opening: rig's roles are a
  hard cut with no aliases, so the day rig's rename lands, every unmerged
  box seed naming a bare role is the broken one.

  One deliberate asymmetry: the mint-time hints in `cmd_new` match both the
  new and the old spelling of `user.box.template`. That is not an alias for
  the role — nothing here softens the cut, and `rig bootstrap claude` is
  gone. It reads a stamp left on an *instance* at its own mint time, which
  every box minted before today carries forever and every clone carries
  forward; refusing the old spelling would cut nothing over and only drop
  the login hint on boxes that predate the rename, the same reason
  `user.claudebox` is honored everywhere else. `migrate-host.sh` stamps
  re-homed legacy boxes `claude-box`, the name the template has today, so a
  re-homed box looks like a fresh mint rather than a fossil.

  The **machine**-role half of rig's rename reaches box too, in one place:
  the tailnet workload join box prints as a next step for a `staging-box`
  guest is now `sudo rig bootstrap workload-server`. box never runs it — it
  holds a pre-auth key, and that it stays operator-run is the absence
  keeping box creds-free end to end — but box does *print* it, in three
  places that all had to move together (`cmd_new`'s hint, the
  `staging-box` seed's own comment, and the README). A next step an
  operator copy-pastes is as wrong as a role box executes, and it fails
  later and further from the cause.

### Fixed

- **A failed rollup read no longer reads as "nothing is failing"** — when
  `gh pr view` returned nothing, the fallback left the `statusCheckRollup`
  *key* absent, and `checks_state` collapsed that into the same `NONE` as a PR
  that genuinely has no checks. `NONE` blocks nothing, so a transient API
  failure presented as mergeable-by-a-human: the same
  unknown-certified-as-green shape as #136, surviving in the one place that
  fix never looked.

  `checks_state` now distinguishes the two — `UNREADABLE` for an absent key,
  `NONE` for a present-but-empty array — and the sweep leaves an `UNREADABLE`
  PR exactly as it is rather than relabelling on facts it did not read. It is
  deliberately **not** a blocker: blocking on it would flap the entire board
  on one bad API call, and the next tick is fifteen minutes away. Fixtures
  64 → 66.

- **`state:needs-human` no longer appears on PRs a human cannot merge** (#136)
  — `decide_state()` derived state from three inputs (draft flag, requested
  reviewers, submitted reviews) and read *nothing* about mergeability or
  checks. Combined with the `if requested "$HUMAN"` short-circuit at the top of
  its precedence, the label was **sticky**: once the maintainer was requested,
  the PR read `state:needs-human` through conflicts, through red CI, through a
  force-push that staled every approval. Nothing demoted it.

  Observed twice in one afternoon on this repo, in two different shapes. Three
  PRs sat at `state:needs-human` while `CONFLICTING` for hours — the board
  inviting a merge GitHub had already disabled. And #119, after a rebase, read
  `MERGEABLE`, four green checks, `state:needs-human` — with **zero** reviews
  bound to its head. Every visible signal said *merge me* over a tree no
  reviewer had seen, and unlike the conflict case, nothing on the page
  contradicted it.

  The rule the label now keeps is that **`state:needs-human` means a human
  could merge this right now**, so anything making that false outranks the
  request that put it there. A `CONFLICTING` branch or a failing check is the
  agent's to fix: new `state:needs-rebase`. Approvals staled by a push mean
  nobody reviewed this tree: `state:addressing`, because the agent owes a
  re-request. An *unfinished* round still yields to an explicit human request —
  a maintainer pulling a PR to themselves early is deliberate, and `MISSING`
  (nobody has reviewed yet) is a different fact from `STALE` (everyone reviewed
  something else). Precedence is applied to the round as a whole, after every
  verdict is collected: deciding inside the loop let the order of `BOTS` pick
  the answer, so a round that was *both* unfinished and staled returned on the
  `MISSING` before any later bot's `STALE` was read — and came out
  `needs-human` over a head nobody had reviewed, the original bug wearing a
  different hat.

  Whether a check blocks is judged by listing the outcomes that *don't* —
  `SUCCESS`, `NEUTRAL`, `SKIPPED`, and the pending set — rather than the
  outcomes that do. The rollup mixes two closed enums (`CheckRun.conclusion`
  and `StatusContext.state`), and an outcome the list forgets is one the label
  cannot certify as mergeable: `ERROR`, `CANCELLED` and `STALE` all read as
  green under an allow-list of failures. The costs are not symmetric — a false
  failure parks the PR on the agent, who looks; a false success invites a human
  to merge a tree that will not merge. Superseded runs are dropped first, each
  context collapsing to its newest entry: a re-run does not evict the run it
  replaced, so this PR's own tip carried a `CANCELLED` `scope` beside the
  `SUCCESS` `scope` that superseded it, and judging every entry would have
  stranded every re-run PR in `needs-rebase`.

  A run is dated by **when it began**, which took two corrections to get right
  and both restored #136 in the meantime. Dating on completion fails because a
  run still in flight does not omit its completion — `gh` marshals the Go zero
  time as the *string* `"0001-01-01T00:00:00Z"`, which `//` will not fall
  through — so the live re-run sorted to the bottom and the run it superseded
  was judged instead. Taking the *newest* stamp a run carries fails for a
  subtler reason: it resolves to `completedAt` for a finished run and
  `startedAt` for a live one, which are different quantities, so it never
  ordered runs at all. A run cancelled by the concurrency group drains *after*
  its replacement starts — 13 seconds on this PR's own `aa5a6ba` — so the dead
  predecessor routinely out-dated the live run replacing it, and a green
  predecessor in that window read `SUCCESS` with a re-run still in flight.
  Start time has neither failure: a replacement always begins after the run it
  replaces, whatever order they finish in. An entry carrying no usable stamp
  sorts last rather than first, so an undateable in-flight run is never
  discarded in favour of a stale success — every ambiguity resolves toward
  "not settled".

  `UNKNOWN` mergeability is deliberately not treated as unmergeable: GitHub
  reports it for about a minute after every merge while it recomputes, and
  flapping every open PR through `needs-rebase` on each merge would be worse
  than the bug. A failed read of either fact degrades to the same "do not know"
  value for the same reason — an API hiccup must not relabel the board.

  Also adds `merge-next`, because a correct `needs-human` still does not say
  *which* PR to merge first, and order matters when they conflict through
  `CHANGELOG.md`. Queue order is intent, so the reconciler never sets it — it
  only **clears** it the moment the PR stops being mergeable-by-a-human, which
  is precisely the staleness that made `needs-human` untrustworthy. Both live
  shapes, the mixed round, the whole check-outcome enum, and the in-flight
  re-run superseding both a green and a cancelled predecessor — in both
  directions, since a run that *finished* after an earlier in-flight entry
  settles the context, and across the drain window where the predecessor
  completes last — are pinned in `test/labels-reconcile.sh`
  (19 fixtures → 51).

- **CI's shellcheck sweep never lints `.github/scripts/*.sh`** (#116) —
  `globstar` makes `**` descend into subdirectories, but a glob still does
  not *match* a dot-prefixed name, so `**/` never entered `.github/`. The
  three scripts that escaped are the release path: `changelog-armed.sh` (the
  #108/#110 guard that gates every PR, and had never been linted),
  `release-notes.sh` (which produces the published release body), and
  `labels-reconcile.sh` (the label state machine) — while the step's own
  comment promised that "a script in a new subdirectory is linted without
  anyone remembering to edit this list". Latent, not broken: all three pass
  shellcheck as-is, so this lands as a no-op on current code and the fix is
  that a regression in them would now be caught. `dotglob` alongside
  `globstar` closes it, measured rather than assumed — it adds exactly those
  three and nothing else, a checkout's `.git` carrying no `*.sh` (its hooks
  ship as `*.sample`). Paired with a CLASS check in the same shape as the
  `eof_guard_sweep` of #112: the sweep now compares the globbed set against
  `git ls-files '*.sh'` and fails naming any tracked script it does not
  cover, so the gap cannot reopen silently the next time a dot-directory or
  a shopt subtlety hides one. `eof_guard_sweep` itself carried the identical
  blind spot — it rebuilds the same glob — and is widened the same way.

- **A PR can no longer delete a shipped changelog section and stay green**
  (#122) — caught in review of #118, where an entry added under
  `## Unreleased` *replaced* the line `## 0.8.0 — 2026-07-19` instead of
  being inserted above it. The whole shipped 0.8.0 record was absorbed into
  `## Unreleased`, git merged it cleanly — a one-line edit, no conflict, no
  signal — and `changelog-armed.sh` was green on that exact tree, correctly:
  it asks only whether the TOP section agrees with `VERSION`, and
  `## Unreleased` was still on top. The damage would have surfaced at the
  next release, when `release-notes.sh` could no longer find the section it
  extracts by heading, or worse, republished the absorbed prose as new.
  `.github/scripts/changelog-monotonic.sh` asserts the complementary
  invariant on every PR: release headings are **append-only**, so the set of
  `## X.Y.Z` headings on a branch must be a **superset** of the set at its
  merge base. A separate script rather than a clause in `changelog-armed.sh`
  because "a heading disappeared" is a property of a DIFF, not of a tree —
  and because `changelog-armed.sh` is driven against constructed non-git
  fixtures that could not express it. The ceremony's stamp passes by
  construction (it adds `X.Y.Z`, removes none), and no base ref to compare
  against is a loud SKIP locally but a hard failure in CI, which sets
  `CHANGELOG_MONOTONIC_STRICT=1` and checks out with `fetch-depth: 0` so the
  guard can never quietly stop guarding.

  Review of this PR found the guard's first cut incomplete, and the gap is the
  shape the incident *actually* had. Containment catches a **deleted** heading;
  it cannot catch a **duplicated** one, because the duplicate is head-side
  surplus and `comm -23` (base minus head) is blind to extras on the head side
  — with or without `sort -u`, and multiset comparison does not close it for
  the same reason. So the guard now also asserts that version headings are
  **unique on HEAD**, alongside containment rather than instead of it. Nothing
  legitimate repeats one: the ceremony stamps a new version, and `Unreleased`
  fails the version shape. Both trees are pinned in `test/release.sh` — the
  deletion near-miss and the real duplicate — each with `changelog-armed.sh`
  asserted green on it, which is the whole reason this script exists.

- **An upgrade over a pre-0.7.0 flat `/opt/box` no longer skips host setup**
  (#115) — found on the first real host the 0.8.0 drill touched. The
  installer migrates a flat pre-0.7.0 tree into `versions/<v>`, and
  `had_install` was computed *after* that migration — so it observed a
  `versions/` directory the migration had just created, concluded the host
  was already installed, and skipped `host/setup-host.sh`. The result was
  silent and self-concealing: `box --version` reported 0.8.0 while every
  host-side artifact stayed as the old release left it, so the very
  operator who upgraded *for* the #102 `box-firewall` SIGPIPE fix was the
  one who did not receive it, with the version string asserting otherwise.
  `had_install` is now computed **before** the migration block, which is
  the honest question — a tree that needs migrating has by definition never
  been converged by this version's `setup-host`. Hosts already on the
  versioned layout are unaffected: they still read `had_install=1`, for the
  right reason. The consequence is deliberate: an unattended (`BOX_YES=1`)
  upgrade on a flat-tree host now *runs* `setup-host`, which the #66 note
  cautions about — accepted, because `setup-host` converges and is
  idempotent, and shipping a release whose host half is silently missing is
  the worse failure.
- **Host setup runs the version it just installed, not whatever `current`
  points at** (#115) — a second defect in the same block, reachable only
  once the fix above lets `setup-host` run at all. The `#66` guard holds
  the default where it is when the host has existing boxes, so on such a
  host `current` still names the OLD version; running
  `$DEST/current/host/setup-host.sh` would then converge the host with the
  *previous* release's host scripts, reinstating exactly the staleness #115
  is about, in the one case where the operator's live boxes make it
  costly. It now runs the installed version's own tree directly.
- **The pre-0.7.0 migration says what it left behind** (#117) — the
  migration named itself, but not the *lifecycle*: the old tree becomes a
  first-class `box versions` entry the operator never installed, and which
  is indistinguishable from one they deliberately kept as a rollback
  target. The migration line now names both ways out — keep it to roll back
  (`box use <v>`) or reap it (`box uninstall <v>`) — and the closing `done`
  summary re-states it, because the migration line itself scrolls past some
  250 lines before the install ends. Deleting it automatically stays the
  wrong default: it is the only thing to roll back *to*, at exactly the
  moment that matters. No behaviour change.

## 0.8.0 — 2026-07-19

### Added

- **Merging the release PR IS the release — and the release re-arms main
  itself** (#96) — the 0.7.0 ceremony ended in an absence: the release PR
  merged with four approvals and nothing happened, correctly, because
  publishing hung off a separate, manual, silent-when-forgotten tag push —
  a failure shape with no error and no red X. The ship decision already
  lives in the release PR (the one PR whose whole diff is "the version
  leaves `-dev`"), so `release.yml` now fires on pushes to main
  (fork-sourced ceremony PRs get a read-only token on `pull_request`
  events), reading the transition from the push itself: `event.before` to
  the pushed head. A decide step answers four states — release-flow *work*
  merged under the `release` label (`-dev` endstates, the post-release
  window) no-ops green with a NOTICE; the two genuinely ambiguous bare
  states refuse loudly; a true transition then requires a merged,
  `release`-labeled PR behind the commit (read via the API — the label is
  the operator's declared intent) before anything is created. Then, in the
  same job, it tags the merge commit via the API, publishes — and bumps
  main to `X.Y.(Z+1)-dev` itself, direct push with a loud open-a-PR
  fallback, so no follow-up bump PR exists on the paved road. Same-job on
  purpose: a `GITHUB_TOKEN`-created tag triggers no workflows, which is
  also what makes double-publish impossible. The tag-push path stays
  unchanged as the documented manual fallback and backfill (it shipped
  0.7.0 itself). `test/release.sh` grep-pins the gate, every decide
  verdict, the single `on.push` key, and the same-job tag+publish+re-arm
  in the same daemon-free, fail-closed style.

### Fixed

- **The release ceremony re-arms `CHANGELOG.md`, and CI refuses to let
  `main` sit disarmed** (#108) — the ceremony stamps `## Unreleased` into
  `## X.Y.Z — DATE` by hand, and nothing put the heading back, so `main`
  sat with no `## Unreleased` from the release until the next PR that
  happened to re-create one. A PR authored *before* the release wrote its
  entry under `## Unreleased`; with that heading gone, git lands the entry
  under whatever now occupies the position — **the section that just
  shipped** — and it merges **cleanly**. No conflict, no error, no red X:
  the one signal an author would trust is absent exactly when the outcome
  is wrong, and the changelog credits a released version with a change it
  does not contain until a human reads the file. Confirmed in the sibling
  repo (heavy-duty/rig#66); box has not drifted yet, and the reason is
  luck rather than design — 0.6.0's ceremony (`77599ab`) added its heading
  *without* removing `## Unreleased`, so main was never disarmed, while
  0.7.0 did disarm it and left a window that nothing happened to cross.
  Two halves land together. The ceremony step in `CONTRIBUTING.md` is now
  explicitly **two edits**: stamp, then put an empty `## Unreleased` back
  above the section just stamped — it belongs there and not in
  `release.yml`, which only ever touches `VERSION`. And
  `.github/scripts/changelog-armed.sh` enforces it in CI, keyed on
  `VERSION` because the two states are genuinely different: a `-dev` tree
  must carry `## Unreleased` on top, a bare-`VERSION` tree (the ceremony
  PR, and the merge that publishes it) may carry either that or its own
  stamped section. The keying is the whole design and not an
  over-complication — box previously had **no** top-section guard at all,
  and the obvious one, an unconditional `## Unreleased` requirement, is
  false by construction on the ceremony PR's own tree, which is why rig#44
  and heavy-duty/cast#108 both had to revert it. So a forgotten re-arm
  does not block the release; it turns `main` red on the very next push,
  the automatic `-dev` bump the release itself makes. Leaving the bare
  branch's top heading unconstrained is what keeps both ceremony shapes
  legal, and a review round on the sibling fix (heavy-duty/cast#114) found
  the gap that asymmetry leaves: a **half-ceremony** tree — `VERSION`
  bumped, `## Unreleased` still populated on top, and the section for that
  version never stamped — makes the wrong-number test false on its first
  clause, short-circuits, and passes. Nothing then refuses until
  `release.yml` extracts the notes, which is *after* the merge, on `main`,
  with the release already half-shipped. So the bare branch now also
  requires that the section it is about to publish exists and is non-empty,
  and it asserts that by running `release-notes.sh` — the very script
  `release.yml` runs — so the guard and the publisher cannot drift apart
  over what a section is. The message is its own: a missing stamp is not a
  misnumbered one, and an operator sent to correct a version number that is
  already right will not find the real problem. Matches
  heavy-duty/rig#67, so the three repos agree.
- **Ctrl-D at a confirmation prompt aborts out loud, instead of exiting
  in silence** (#111) — `confirm()` and `uninstall_confirm()` both took
  the operator's answer with a bare `read -r reply`. Every answer a
  human can type routes through the `case` below it and ends at a
  `return` or at `die "aborted."` — every answer except EOF. Ctrl-D
  makes `read` return non-zero, `set -euo pipefail` ends the run on that
  line, and the `case` is never reached: box exits 1 having printed
  nothing at all after the question it just asked. It fails closed,
  which is why this is a small fix and not an incident — nothing is
  destroyed, the abort is real. The damage is that the tool goes mute at
  the one moment it had the operator's full attention, and someone who
  Ctrl-Ds out of `box rm work` cannot tell from the output whether the
  box is still there. The cure is one token in each function,
  `read -r reply || die "aborted."`, the same one heavy-duty/rig#43
  applied to rig's credential prompts so the two repos read alike. The
  bug predates everything it touches — `rm` has carried a confirm gate
  for as long as the verb has existed — but #105 took the number of
  verbs reaching that line from one to two, and both are irreversible,
  which is the argument for closing it now rather than the next time
  someone notices. The three answers a human can actually give (`y`,
  `n`, and Ctrl-D) are now driven for real on a pty via util-linux
  `script`: they were structurally untested before, because `[ -t 0 ]`
  sends a terminal-less suite to the refusal branch and every existing
  check stopped there — which is exactly how this survived four
  releases. Review caught that the first pass fixed the bug where it was
  reported and stopped there, while the same defect sat at two more
  destructive gates in this repo: `host/revoke-user.sh:50`, the prompt
  guarding `box revoke --purge` — the one whose own text says "this
  cannot be undone" — and `host/teardown-host.sh:31`, guarding a full
  host teardown. Both run under `set -euo pipefail`, both died mute on
  EOF with their `aborted` line never reached; both now carry the guard
  in their own script's wording. The three `drill/` prompts are
  deliberately left alone — they run under `set -u` only, so EOF falls
  through to the `*)` arm and already aborts out loud — and
  `install.sh:65` was already guarded. What keeps the class closed is a
  repo-wide sweep in `test/cli.sh`: every statement-initial `read` fed
  from stdin, in any file that turns on errexit, must carry a `||`
  guard, with `while read` loops and `<<<` herestrings excluded because
  neither is a prompt. The sweep flags all four sites when their guards
  are removed and nothing else across the tree's fifteen shell files —
  the absence of exactly this check is why the `host/` pair was missed
  in the first place.
- **`box restore` asks before it destroys — and the confirmation prompt is
  now the row's, not rm's** (#105) — `restore` and `rm` both irreversibly
  discard user state, and only one of them asked. The table gave `restore`
  the preconditions `box,arg2`: the instance is ours, a snapshot name is
  present, go. So `box restore work stale-label` silently threw away
  everything done in the box since that snapshot, with no prompt, no
  `--force`, and no way to take it back — a warning in `--help` is not a
  gate. It has been that way since the verb shipped, and it is about to
  become routine rather than rare (heavy-duty/rig#62's pristine snapshot),
  which is the wrong time to still be relying on the operator typing the
  right label. The reason it stayed ungated is worth recording, because it
  is the actual bug: `confirm` was already a precondition token, but the
  dispatch line hardcoded the *words* — `confirm "delete $inst and all its
  snapshots"` — so the one-token fix would have gated restore behind a
  prompt offering to DELETE the box the operator was trying to rescue. A
  gate that names the wrong act is worse than no gate; it is how people
  learn to answer `y` without reading. So the prompt moved into the table
  as a seventh field, each row saying what it is about to do in its own
  words, and `restore` now asks to "roll `<box>` back to snapshot
  `<label>` and discard everything in the box since it was taken" — naming
  the label, because picking the wrong one is the whole risk. `rm`'s
  wording is unchanged and pinned verbatim by a test, since rewording the
  one verb that already worked would be a regression shipped as a
  refactor. A row marked `confirm` with no words is now a hard internal
  error rather than a blank question. `--force` and the no-TTY refusal come
  free — `confirm()` already had both. The one automated caller had to
  consent explicitly: `drill/multiuser.sh` drives restore unattended on real
  Incus and now passes `--force`, which is the rehearsal proving the gate
  rather than working around it — the CI run of this very PR failed there
  first, which is the shape a gate is supposed to have. Coverage went from two
  argument-validation checks that never reached dispatch to the destructive
  path itself, driven against a fake incus: refusing leaves the call log
  empty, `--force` produces exactly one `incus snapshot restore`. Not
  changed, deliberately: `restore` still does not require the box stopped
  (#105 makes that case separately and it deserves its own call), and
  `--help` now says plainly that a rollback of a running box is
  crash-consistent, because these snapshots are stateless.
- **`box-firewall` could hand a UFW host the no-UFW firewall, ~2% of the
  time** (#102) — filed as an intermittent test flake (`test/cli.sh`'s
  fresh-UFW block going four-assertions-red on an unmodified `main`,
  measured here at 5 failing runs in 40), it was not one. The branch that
  decides the host's entire firewall stance read
  `ufw status | grep -q "Status: active"`, and `Status: active` is the FIRST
  line ufw prints: `grep -q` matches it and exits immediately, closing the
  pipe while ufw is still writing the rest of the table, so ufw dies of
  SIGPIPE. `grep` returned 0, but under this script's `set -o pipefail` the
  PIPELINE returns 141 — the `if` reads false and a host with UFW plainly
  active takes the nft-fallback branch, never building the DNS carve-out its
  persisted rules depend on. A pure scheduling race, isolated at ~2% per
  invocation (`PIPESTATUS` = `141 0`; a draining reader flakes 0/2000, a
  reader whose match is on the last line flakes 0/2000). Real ufw is a
  slower, longer writer than the test shim, so production had no reason to
  be safer. `ufw status` is now read ONCE into a variable and matched with
  `[[ ]]` — no reader, no race — and the stale-rule scan reads that same
  snapshot, so the branch decision and the converge loop can no longer
  disagree. **`host/teardown-host.sh` carried the same live defect** and is
  fixed with it: that file does set `pipefail` (line 12), so its UFW
  crumb-removal branch could read a plainly-active UFW as inactive and skip
  silently, leaving stale `boxnet`/`claudenet` rules on a host the operator
  was told is clean — and its numbered-delete loop had the same early-exit
  reader as its condition, so it could end while rules remained. Both now
  read captures. The sibling calls in `drill/wipe.sh` and `drill/doctor.sh`
  are the same shape but set only `set -u`, so the SIGPIPE is discarded
  there and the branch holds — latent, not live, until either gains
  `pipefail`.
- **A missing firewall log now diagnoses itself** (#102) — the four greps
  reading `$WFW/*.log` used to fail together with empty output when the
  driving run took the wrong branch, a signature that looks specific and
  says nothing (#102 was filed reading it as "the log is not written";
  the log existed, the mutations did not, and that distinction *was* the
  diagnosis). `test/cli.sh` now asserts the precondition explicitly before
  the content greps and, on failure, prints the contents of `$WFW`, the log
  itself, and the stderr of the run that should have written it. It also
  keeps `an agreeing UFW host deletes nothing` honest: that check asserts an
  absence, which a run that did nothing at all passes for the wrong reason.
- **`box grant` provisions an `incus-admin` member instead of refusing them**
  (#99) — the refusal read "they already have the admin tier; there is
  nothing tighter to grant", which is true about *permission* and silent
  about *provisioning*: the `incus` group is indeed a strict subset of what
  `incus-admin` opens **at the daemon API**, but the `user-<uid>` project, the
  boxnet narrowing, the snapshot and backup allowances, and the `box-net`
  profile installed into that project are none of them permissions, and an
  `incus-admin` member had none of them — `box_tier()` resolves them to
  `admin`, so they worked in the shared default project next to root and every
  other admin, with no world of their own and no supported way to get one.
  `box grant` now runs the full convergence for them.

  The group step is part of that convergence, not an exception to it: an
  `incus-admin` member is added to `incus` like anyone else. The subset
  argument holds for the API and **fails at the filesystem**, which is where
  it matters here — the two sockets are two files with two owning groups
  (Debian 13 / Incus 6.0.4, measured):

  | socket | group | mode |
  | --- | --- | --- |
  | `/var/lib/incus/unix.socket` | `incus-admin` | 0660 |
  | `/var/lib/incus/unix.socket.user` | `incus` | 0660 |

  `incus-admin` opens the first and not the second, and only the second
  provisions a `user-<uid>` project. Without the membership the provisioning
  touch takes `EACCES`, the swallowing `|| true` hides it, no project appears,
  and the grant dies blaming a perfectly healthy incus-user — the exact
  incus-admin-only user #99 is about, left no better off. So the membership is
  granted, and the grant says out loud why: it is the key to a file, not a new
  privilege (`box_tier()` still reads them as `admin`, both-groups → `admin`).

  The touch itself is **pinned at incus-user's socket**: the incus client picks
  by writability (`client/connection.go` — the daemon socket when writable,
  `unix.socket.user` only otherwise), so for an `incus-admin` member an
  unpinned touch sails past incus-user and provisions nothing. The user-side
  proof that closes the grant names their project for the same reason, since an
  unqualified `profile show` would have answered from the shared default
  project and proved nothing. The socket's existence is probed through `$SUDO`,
  not a bare `[ -e ]` — `/var/lib/incus` is not traversable by a non-root
  admin, so an unprivileged stat reports a present socket as absent, and this
  probe exits on absent (the discipline `box revoke` already documents).

  On success the grant prints the caveat the hard exit was gesturing at, in the
  two forms it actually takes: the restrictions are a **default placement, not
  a confinement** (admin membership still wins at the socket — the default
  project and other users' instances stay one flag away), and until
  `incus-admin` goes their own `box` commands keep landing in the default
  project. Dropping `incus-admin` then lands them in their ready project with
  **no re-grant** — a promise that is only true because they keep `incus`;
  without it that drop would leave them in neither group, `box_tier()` `none`,
  and a converged project they could not open. The failure path follows: the
  membership this run added is rolled back and verified, while the backout
  refuses to call that a lockout — `incus-admin` is untouched and still opens
  every project.

  `box revoke` mirrors it. A bare revoke of a granted `incus-admin` member now
  takes the `incus` membership back and reports **`partial:`** — the socket key
  `box grant` added is gone, their project is kept, and they are explicitly
  **not** locked out. An `incus-admin` member who was never granted is still a
  named **no-op** that makes no privileged call at all. `--purge` unmakes the
  provisioning while refusing to call them "out". Every path names
  `gpasswd -d <user> incus-admin` as the only thing that ends their access.

  Unblocks rig's `users apply` (heavy-duty/rig#49), which had to call `box
  grant` for a user who is both `incus-admin` by hand and role `box` in the
  fleet file. Driven end to end in `test/cli.sh` under logging incus/sudo shims
  — every assertion is made against what the run did, not what the source says
  it would — and, because those shims model neither `INCUS_SOCKET` nor file
  permissions and so cannot reproduce the `EACCES`, measured on real Incus in
  CI by a new `drill/multiuser.sh` criterion (o): an `incus-admin`-only member
  is granted, the membership lands, the project appears, `unix.socket.user`
  opens as them, and dropping `incus-admin` leaves them in their own project
  with no re-grant.


## 0.7.0 — 2026-07-19

### Added

- **The installer defaults to the latest release, and releases publish
  themselves** (#83) — `curl | bash` used to hand out whatever `main` was at
  that second: the 0.6.0 release was a bookmark, not a package, and two
  operators "on 0.6.0" could be running different trees. `install.sh` now
  resolves the latest release tag by following GitHub's `releases/latest`
  redirect (one HEAD request — no API, no token, no rate-limit pain) and
  downloads that tag's tarball; a failed resolution refuses loudly, naming
  `BOX_REF` as the way out — it never hangs and never silently falls back to
  `main`. A set `BOX_REF` is tried as a tag first, then as a branch, so one
  knob yields three channels: default = latest release, `BOX_REF=0.6.0` =
  pinned, `BOX_REF=main` = dev. A new `release.yml` (on a bare `X.Y.Z` tag
  push — the `0.6.0` tag set the no-`v` precedent) asserts the tag names the
  tree's own `VERSION` (a mismatch fails loudly and creates nothing) and
  publishes the GitHub release with that version's `CHANGELOG.md` section as
  the body (`.github/scripts/release-notes.sh` — the curated prose, not the
  generated PR list; no assets, the source tarball for the tag IS the
  package). And `main`'s `VERSION` now carries `-dev` between releases
  (this PR: `0.6.1-dev`): the versioned layout names install trees after
  `VERSION`, so a `main` install without the bump would land in
  `versions/0.6.0` and impersonate the released tree. `test/release.sh`
  drives all of it offline — the extraction against fixtures and the real
  changelog, the resolution and every channel against a shim curl.
- **`setup-host` auto-picks a free subnet — nested box-in-box with zero
  flags** (#80, completing its fix #1: "refuse … or automatically select a
  non-colliding subnet"). A bare `box setup-host` now decides the subnet
  itself, in four deliberate cases: an explicit `BOX_SUBNET` is honored or
  refused, never silently overridden (scripted hosts keep exact semantics);
  an existing `boxnet` bridge is converged on as-is — the bridge IS the pin —
  turning the old bare-re-run agree-gate refusal into plain convergence
  (unless a foreigner *also* claims the bridge's subnet: that is #80's
  poisoned state, and converging would rebuild on it, so it still refuses and
  names the bridge move); a free `10.88.0.0/24` stays the default; and a
  *claimed* default — the nested case: a drill or rehearsal running inside a
  box, whose own uplink owns 10.88 — scans `10.89.0.0/24` … `10.127.0.0/24`
  in order, takes the first free candidate, announces the pick and the
  claimant loudly, and only refuses when every candidate is claimed. The
  decision happens before any mutation, and everything downstream (the
  bridge, `BOX_GW`, the ACL's gateway carve-out, the firewall, the doctor's
  expectations) derives from it.
- **`setup-host` refuses a claimed subnet, and `BOX_SUBNET` picks another**
  (#80) — run inside a box, `setup-host` used to build a nested `boxnet` on
  the exact subnet and gateway of the guest's own uplink: the guest then held
  its gateway's address as a *local* address, carried duplicate connected
  routes for its uplink subnet, and suffered intermittent, self-recovering
  egress blackouts that looked like flaky internet (measured live: ~24–36 s
  outages, roughly hourly, with the host clean throughout). `setup-host` now
  scans the target subnet **before any mutation** — the default route's
  gateway inside it, or any non-`boxnet` interface holding an address in it —
  and refuses, naming the way out. A prior `boxnet` owning the subnet is the
  legitimate converge path and does not trip it. `BOX_SUBNET=<a.b.c.0/24>`
  (validated, alongside the existing `BOX_DNS`) moves the whole stack: the
  bridge address, the ACL's gateway carve-out (now converged via
  `network acl edit`, so a bridge moved off a colliding subnet no longer
  strands box DNS behind a stale `/32`), the firewall (`box-firewall` reads
  the gateway off the live bridge), and every drill/migrate probe that used
  to hardcode `10.88`.
- **`box doctor` knows the #80 signature** — a default gateway held as a
  LOCAL address, and duplicate connected routes for the uplink subnet, judged
  from `ip route`/`ip addr` on the machine doctor runs on (both tiers, before
  any daemon check — the nested daemon answering could be the impostor) and
  probed *inside* every box it examines. The existing "egress broken but DNS
  fine" split now names itself as #80's fingerprint (the impostor dnsmasq on
  a captured gateway keeps resolving while IP egress dies), and the admin ACL
  section verifies the gateway carve-out matches `boxnet`'s actual gateway.
  The agent-context guard for the templates (suggested fix 4) lands in
  heavy-duty/rig#31's bootstrap roles per the thin-templates split (#81).

- **The `staging` template** (#81, the re-cut of #69's layering) — a
  server-class, creds-free seed: Debian 13, user `ops`, tmux, rig,
  `BOX_REQUIRE_VM=1` (the VM is its trust boundary), `BOX_AUTOSTART=1` (a
  server returns from a host reboot without an operator), and
  `BOX_BOOTSTRAP_ROLE="staging"` — the server posture (docker, sshd
  hardening) converges via `rig bootstrap staging` after mint. The tailnet
  workload join holds a pre-auth key and therefore **stays operator-run**
  (`box shell` → `sudo rig bootstrap workload`), printed as a next step —
  box never sees the key.
- **`BOX_BOOTSTRAP_ROLE` template key + mint-time auto-run** (#81) — a
  template names the **creds-free** rig tenant role box runs inside the guest
  after cloud-init settles (`incus exec … rig bootstrap <role>`); the value
  is a role *name* by allowlist (anything shell-shaped dies at parse time, on
  the host). A failed role leaves the box up and names the re-run — the roles
  are convergent by contract (rig#31). `blank` names no role and auto-runs
  nothing.
- **The rig pin point: `RIG_REPO` / `RIG_REF`** (#81) — the tenant seeds
  preinstall rig, inverting the rig→box install edge (rig#28), and the new
  edge gets the same honest treatment rig#29 gave box's unpinned install:
  `@RIG_REPO@`/`@RIG_REF@` tokens in the seed resolve at mint from the
  environment (default `heavy-duty/rig` @ `main` — unpinned, tracking main,
  until a release flow exists, rig#32/#83). The pin covers both the installer
  fetched and the tree it installs, so a rig branch under review is testable
  end to end; values are allowlist-validated before touching the YAML.
- **Server-posture template keys** (#81, carved from #69) — two optional
  `box.env` allowlist keys. `BOX_REQUIRE_VM=1` refuses both the silent
  container fallback (no `/dev/kvm`, exit 1) and an explicit `--container`
  (exit 2): such a template's trust boundary is the VM. `BOX_AUTOSTART=1`
  stamps `boot.autostart=true` at launch, per-instance like `limits.*`, so
  the box returns from a host reboot without an operator; clones inherit it
  via `incus copy`. Still no key for a network or a `security.*` flag, on
  purpose.
- **Dynamic template test suite** (#81, carved from #69) — `test/cli.sh`
  discovers `templates/*/` instead of hardcoding the list, so a new template
  cannot ship unseen. Per template: `box.env` is driven through the real,
  extracted `load_template` (unknown keys and missing `BOX_IMAGE`/`BOX_USER`
  fail, fixtures proving both dies); `user-data.yaml` exists, declares
  `#cloud-config`, parses as YAML, and installs tmux (#65). Grep guards pin
  the `cmd_new` half: the `REQUIRE_VM` refusal orders after `pick_mode`, and
  `boot.autostart` is stamped only under the `T_AUTOSTART` guard.
- **`box export` / `box import`** (#70) — a box's state that survives the box
  _and_ the host, unblocking #66's humane upgrade flow (down, export, rm,
  upgrade, re-import). `box export <box> [<file>]` wraps `incus export` into
  one portable backup tarball (default `<box>-<UTC stamp>.tar.gz`), snapshots
  included by default (`--instance-only` opts out); the box must be stopped
  first (`box down`) so the artifact is a settled disk, not a moving one. The
  file is **shouted about, not scrubbed** — it carries the box's whole disk
  (agent logins, git credentials, SSH keys), and scrubbing a disk image is a
  promise tarball surgery cannot keep, so box says what is inside instead,
  every time. `box import <file> [--name <box>]` mints the box back and
  re-stamps what is the _current host's_ truth, not the artifact's: the
  `user.box=1` boundary tag (legacy `user.claudebox=1` honored), the
  `box-net` placement (re-assigned if the artifact's differs — the
  migrate-host move), and a fresh machine identity: the NIC's MAC (imports
  restore `volatile.*` verbatim, and a re-import beside its sibling collided
  at start with "MAC address already defined on another NIC" — measured
  live; `incus copy` regenerates it, `incus import` does not) plus
  `reset_identity` (the clone trust boundary: no DHCP collision with the box
  it was exported from).
  Import refuses any name an existing instance holds — the `resolve_box`
  boundary, seen from the other side. Works on both tiers: `box grant` now
  also converges `restricted.backups allow` (incus-user blocks backups by
  default exactly like snapshots, and an export _is_ a backup
  create+download — measured against incus 6.0's `permissions.go`); re-run
  `box grant <user>` after upgrading, as documented. CI's `rehearsal` job now
  proves the round-trip on a live Incus: mint → write a file → snapshot →
  down → export → `rm` → import → the file and the snapshot survived, the
  agent answers, the tag is present, and a colliding re-import is refused.
- **Versioned installs** (#66's stance, made livable) — install.sh now lands
  each version side by side at `<root>/versions/<v>` (its own `VERSION` +
  `INSTALLED_FROM`), with a `current` symlink tracking the default and
  `$BINDIR/box` riding the chain, the way plenty of CLIs manage theirs. New
  verbs: `box versions` (lists installs, marks the current default and the
  running tree), `box use <version>` (flips the default, converges the PATH
  symlinks, and *asserts the effective result* — `current` must resolve to
  the asked-for version and the chain's `box --version` must answer it).
  Re-running the installer with an installed version is a converging no-op
  (`BOX_REINSTALL=1` replaces that version's tree); a **new** version installs
  side-by-side and flips `current` only when no boxes exist — under existing
  boxes the flip is refused loudly, naming the boxes (#66: never change
  versions under a user's boxes; `box use` keeps the same refusal). A
  pre-0.7.0 **flat tree is migrated in place** (two renames, the operator's
  tree preserved bit for bit), so upgrading from 0.6.0 is seamless; a stale
  or dangling `$BINDIR/box` is healed instead of wedging the install; and the
  installer warns when the *other* tier's install (/opt/box vs ~/.local)
  coexists, since PATH order decides which wins.
- **A real uninstall** — `box uninstall [<version>] [--all] [--purge-host]`
  replaces the "rm -rf two paths" prose. One version: refuses the current one
  (`box use` off it first). Everything: runs in the safe order — refuses
  while boxes exist (naming them) unless `--purge-host` runs teardown-host
  first — then removes every version, the `current` and PATH symlinks, and
  the legacy claudebox crumbs (both name generations), and **ends with an
  absence assert**: every removed path is re-checked, and any survivor makes
  it exit 1 as `uninstall INCOMPLETE` naming the leftovers (the
  `revoke --purge` discipline). `teardown-host.sh` gains `--yes`/`BOX_YES=1`
  for automation and now points at `box uninstall` when done.
- **`BOX_INSTALL_SOURCE=<dir-or-tarball>`** — installs from a local tree,
  bypassing the download. CI's rehearsal job now installs via install.sh
  itself (proving the installer under review, not a `cp -r` mimic of it), and
  ends with an **uninstall drill**: grant + `revoke --purge` a throwaway
  user, `teardown-host`, `box uninstall --all`, then assert **zero residue**
  — no networks, profiles, ACLs, nft tables, systemd units, files or
  symlinks.
- **test/cli.sh drives real installs** — still dependency-free, non-root, no
  daemon: `BOX_INSTALL_SOURCE` + throwaway `BOX_HOME`/`BOX_BIN` roots and a
  fake `incus` on PATH (`$FAKE_BOXES`) turn layout, chain, no-op/converge,
  reinstall, side-by-side upgrade, the three #66 refusals (install flip,
  `use`, `uninstall` — boxes named), flat-tree migration, symlink healing,
  single-version and zero-residue uninstalls, and the `INCOMPLETE` scream
  into *driven* tests instead of greps (154 checks).

### Changed

- **Thin templates — box mints, rig converges** (#81, companion rig#31) —
  the tenant content that lived in `claude`/`codex`/`grok`'s cloud-init (the
  agent CLI installs, docker, node, the per-template agent-context heredocs)
  **moves to rig's bootstrap roles**, where it is convergent, idempotent and
  testable end to end instead of parse-only YAML. What remains per template
  is a thin, creds-free seed: the tenant user, tmux (#65), and rig
  preinstalled — nothing that joins a tailnet or admits credentials. The #80
  agent-context guard ("never run `box setup-host` or the drill inside a
  box") now lives once, in rig's roles, not copy-pasted per template. The
  template test sweep grew the contract's teeth: per-template seed asserts
  (user matches, rig pinned via both tokens) and fail-closed **absence
  greps** over effective cloud-init lines — no agent CLI, no docker, no
  tailscale/authkey/ssh, no `write_files` heredocs — so tenant content
  cannot quietly grow back.

### Fixed

- **A wedged `incus launch` fails loudly, not forever — the mint's launch
  phase is narrated and time-boxed** (#93) — twice in the 2026-07-19
  release drill (Debian 13, Incus 6.x, /dev/kvm present, images cached),
  the child `incus launch` under `box new` hung with *no server-side
  operation*: `incus operation list` empty, the instance never created, the
  daemon journal quiet — one wedge ran 56 minutes before being killed by
  hand, and an immediate retry of the identical command succeeded in
  minutes, both times. `box new` inherited that as an indefinite silent
  hang, indistinguishable from a cold mint working. It now prints
  `launching instance …` before the call, and the call rides
  `timeout -k 5 $BOX_LAUNCH_TIMEOUT` (seconds, default 600 — generous: the
  coldest measured mint is minutes, never an hour; the same scripting-knob
  shape as `BOX_CPU`/`BOX_MEMORY`), with stdin pinned per the drill's own
  trap list. On the budget firing it probes whether the instance was ever
  registered and tells the two stories apart — the measured #93 wedge (no
  server-side operation; an immediate retry has been observed to succeed)
  vs a slow launch that overran the budget with the instance already
  created — then best-effort deletes either way, so the retry advice is
  clean in both worlds, and points at `box doctor` for the host. The
  `--from` clone path is untouched: `incus copy` of a local instance is a
  different operation and has never been observed to wedge this way.
- **UFW's gateway carve-out converges with the bridge, and the doctor can
  see it** (the #86 review's blind spot) — `box-firewall` gated its whole
  UFW block behind "a `DENY on boxnet` rule exists", pinning every UFW host
  to the gateway of the *first* run: a bridge remapped off a colliding
  subnet (#80's escape hatch) kept its stale `allow … to <old-gw> port 53`
  and never gained the live gateway's, so box→gateway DNS died at box's own
  deny — while the doctor's carve-out check read only the incus ACL (which
  setup-host converges) and called the host clean. The UFW allows now
  converge off the live bridge address on every run (stale DNS allows
  deleted, the live set ensured — ufw skips existing rules, so a fresh host
  gets the identical rule set and a re-run is a no-op), and `box doctor`
  reads UFW's own table wherever UFW is active, flagging a DNS allow that
  does not match `boxnet`'s gateway (and stale allows left beside a live
  one). The no-UFW nft carve-out never had this failure mode: it is
  interface-scoped, no gateway address to go stale.
- **The boot-time gateway fallback is gone — no rule beats a wrong one** —
  with the bridge not yet addressed when `box-firewall.service` ran,
  `box-firewall` guessed `GW=10.88.0.1`; on a `BOX_SUBNET` host that hit
  that window the UFW carve-out was built for the wrong gateway, a latent
  DNS drop (#86 review). It now fails closed: an unaddressed bridge leaves
  the persisted UFW rules exactly as they are (they survive boots on their
  own, and nothing else in the script needs the gateway) and says so on
  stderr; the next setup-host run or service restart converges them once
  the bridge is addressed.
- **`revoke --purge` re-checks the incus-user state** — the purge removed
  `/var/lib/incus/users/<uid>` without ever asserting its absence, the one
  path its own absence block did not cover; and the stat now rides
  `$SUDO test -d` (`/var/lib/incus` is not traversable by a non-root admin,
  so a bare `[ -d ]` answered "absent" for a directory that was there).
- **A wedged `$BINDIR/box` no longer blocks installing** — the old
  no-op-if-installed check keyed off the symlink's existence OR the tree's,
  so a stale symlink (or a half-removed tree) could fake "already installed"
  forever. Installed-ness is now judged from `versions/<v>` itself; symlinks
  are converged with `ln -sfn`, never trusted as the signal.

## 0.6.0 — 2026-07-18

### Added

- **The restricted tier: multi-user hosts** (#74, redesigning #72) — an admin
  runs `box grant <user>` and that user gets their own boxes on the same
  hardened `boxnet`, seeing nobody else's; `box revoke <user>` takes it back
  (`--purge` deletes their world, and asserts the absence). The tier rides
  incus-user, whose defaults miss box's contract three measured ways (Debian
  13 / Incus 6.0.4): a private _unhardened_ NAT bridge per user, snapshots
  blocked, the `box-net` profile invisible — so grant is an idempotent
  convergence: project narrowed to `boxnet` **and only boxnet** (listing the
  private bridge too, the obvious fix, would keep an unhardened network one
  `--network` flag away), snapshots allowed, the shipped profile installed
  into their project. `box_tier()` (live credentials, argless `id -nG`)
  drives the tier-aware surface: `expose` refuses honestly before any daemon
  call, `setup-host` and `doctor` answer at the caller's tier. Rehearsed
  end-to-end by `drill/multiuser.sh` (criteria a–n: confinement, lifecycle,
  cross-user visibility, name collisions, the in-box isolation contract,
  escape hatches, re-sync survival, revoke incl. the live-session case) —
  54/54 on the design host (container and VM mode), including the raw-attach scoped-guarantee measurement and both grant-failure injections demanded by #75's review.
- **CI runs the multi-user rehearsal on a real Incus** — a second `rehearsal`
  job stands up the full stack on the runner (setup-host, doctor, then
  `multiuser.sh --container`), so every PR proves the tier's semantics
  against a live daemon, not a mock. The VM trust boundary itself remains a
  real-hardware ritual, like the full drill.
- **Global / root install** (#71) — run as root, box installs _once_ to
  `/opt/box` (world-readable) with the `box` symlink on `/usr/local/bin`, so
  every operator on a shared host runs the same tree. Per-user installs are
  unchanged (`$HOME/.local`); `BOX_HOME`/`BOX_BIN` still override. A per-user
  tree under `/root` is `0700` and unreadable to everyone else — the whole fleet
  got `command not found` — so the root branch lands in a system location and
  `chmod -R a+rX`'s it (read for files, +search on dirs), guarded on root. This
  unblocks "rig installs box" (rig#24's `box` role).
- **CI + a test suite** — `.github/workflows/ci.yml` (a `check` job: globstar
  `shellcheck -x` over `bin/* **/*.sh`, then `bash test/cli.sh`) and `test/cli.sh`,
  dependency-free and runnable by a non-root user with no Incus. It exercises the
  `install.sh` DEST/BINDIR branch functionally (both tiers + `BOX_HOME`/`BOX_BIN`
  overrides), the CLI contract, and grep-guards the daemon-gated invariants and
  tmux in every template — the box was the repo with "no tests and no CI".

### Fixed

- **`box restore` never worked against Incus 6** — the command table
  dispatched `incus restore`, a subcommand that does not exist (Incus 6
  spells it `incus snapshot restore`), so every restore died on "unknown
  command". Found by #74's rehearsal exercising the full lifecycle as a
  restricted user; fixed for every tier, and the rehearsal + a grep-guard in
  `test/cli.sh` now hold it.
- **`box tmux` works on every template** (#65) — `box tmux` runs
  `tmux new-session` _inside_ the box, but the templates did not install tmux, so
  it failed with `tmux: command not found`. `tmux` is now in each template's
  cloud-init package list (`blank`/`claude`/`codex`/`grok`).

- **`box setup-host` finishes in one run** (#63). When it had to add you to
  `incus-admin` it stopped there and told you to re-login and re-run — an
  `exit 0` that reported success having built none of the stack: no `boxnet`,
  no ACL, no `box-net` profile, no firewall. It now re-execs itself under
  `sg incus-admin` and completes in that one invocation. The membership check
  was also asking the wrong question: `id -nG "$USER"` reads the group
  database, which lists the group the moment `usermod` returns, so a
  same-session re-run passed the check with credentials that still lacked the
  group and died further down on a bare permission error from `incus`. Argless
  `id -nG` asks the process what it actually holds.

- **`setup-host` works as root, with or without `sudo`** — every privileged
  call was a hardcoded `sudo`, so on a minimal root image (no `sudo` package)
  it died on `sudo: command not found` before doing anything. Privilege is now
  resolved once: nothing at UID 0, `sudo` otherwise, and a clear error if
  neither is possible. This is what made `install.sh`'s root path real rather
  than nominal.
- **`setup-host` grants `incus-admin` to the human, not to root** — under
  `sudo install.sh` it would have added `root` to the group: a no-op (UID 0
  opens the socket regardless) that also left the actual user locked out of
  their own boxes. It now derives the login user from `SUDO_USER`.
- **`box-firewall.service` now reports its state honestly** — the unit is
  `Type=oneshot` and was missing `RemainAfterExit=yes`, so it went
  `inactive (dead)` the instant it succeeded: a host whose isolation was
  perfectly live read as one whose firewall unit had died. drill.sh sends you
  to `systemctl status box-firewall` to diagnose exactly that, and
  setup-host.sh's own comment already asserted the unit "is RemainAfterExit" —
  it was not. Found by running the drill on a real host and mistrusting the
  green: `nft list table bridge box` showed the drop live while the unit read
  dead. `restart` was and remains correct either way.
- **`setup-host`'s apt calls can no longer hang** — a fresh cloud image has
  `apt-daily`/`unattended-upgrades` holding the dpkg lock, and a plain
  `apt-get install` waits on it silently and indefinitely. Now bounded
  (`DPkg::Lock::Timeout=300`) and non-interactive, which matters because
  `install.sh` runs it with nobody watching.

### Changed

- **`drill.sh` proves the new contract instead of masking it** — the drill ran
  `setup-host` itself right after installing, so the stack existed by its own
  hand and a run passed identically whether or not `install.sh` had done a
  thing; a fresh run converged the stack three times, while the messages still
  described the pre-#63 "first pass may only add you to the group" behaviour.
  It now asserts the post-install stack in-group before touching the host, and
  runs `setup-host` exactly once more — after the clean, which deliberately
  unsets `dns.mode` and so has to be converged back. `DRILL_OWNS_SETUP=1`
  hands sequencing back to the drill. Pre-setup tripwires now read _before_
  `install.sh`, since that is what triggers setup now.
- **`install.sh` asks, sets up the host, and no-ops on re-run** (#64) — it now
  prompts _"Install box?"_, then on a fresh host installs the tree and asks a
  second question, _"Set up this machine as a box host now?"_, running the whole
  isolation stack if you say yes (previously it only printed a warning and left
  you a command, so the install reported success and `box new` died on a host
  with no Incus). Prompts read `/dev/tty`, since under `curl | bash` the script
  itself is stdin; `BOX_YES=1` answers yes unattended (required where there is
  no terminal), `BOX_SKIP_SETUP_HOST=1` declines the host-setup step.
- **`install.sh` never overwrites an existing install** — if box is already
  installed it says so and changes nothing, so a stray re-run can no longer
  clobber a working tree or rebuild the host stack under live boxes. Upgrading
  is explicit: uninstall (`rm -rf ~/.local/share/box ~/.local/bin/box`, boxes
  preserved first) and install fresh. This replaces the earlier version-diff
  refusal with a simpler rule that dissolves the same class of errors. The
  version-aware upgrade that migrates boxes instead is #67; a portable
  `box export` so a box survives its own deletion is #70.

## 0.5.0 — 2026-07-15

The release the project was renamed in: the repo is `heavy-duty/box`, matching
the CLI it ships. Everything legacy-facing is honored forever — the
`user.claudebox=1` tag, the `.claudebox/` runbook folder, the old symlink the
installer retires — but nothing current carries the old name.

### Added

- **`codex` and `grok` templates** — OpenAI Codex CLI and xAI Grok CLI boxes,
  creds-free like every template. The template mechanic (image + user +
  resources, never a network or a `security.*` key) now has three tenants
  beside `blank`, and the drill mints all of them cold.
- **`box expose <box> <port> [<host-port>]`** — a deliberate, loopback-only
  door to a port inside a box, for seeing a dev server in your browser. The
  listen side is always the host's `127.0.0.1` (no flag to widen it), the door
  is per-port, `--list`/`--remove` manage it, and `box info` shows open
  exposures — a box with a hole says so.
- **Inline resource overrides on `new`** — `--cpu <n> --memory <size>
--disk <size>` (#57). Resolution most-specific-first: flag > `BOX_CPU` /
  `BOX_MEMORY` / `BOX_DISK` environment (the scripting form) > template
  `box.env` > defaults. Values pass to Incus verbatim; resources are all a
  flag can touch. `--from` refuses them — a clone carries its source's
  resources.
- **Host lifecycle as verbs** — `box setup-host`, `box teardown-host`, and
  `box migrate-host`, which re-homes pre-0.4.0 boxes onto the current stack
  (`--box <n>` / `--all-boxes`, authed state preserved) and retires the legacy
  bridge once empty (`--retire-legacy`).
- **The `.box/` recipe convention** — the agent-facing runbook folder a repo
  can ship, renamed from `.claudebox/` (both spellings read).

### Fixed

- **VM mints no longer hang at GRUB** — Incus defaults VMs to Secure Boot on,
  and a cloud image whose shim the host's OVMF doesn't trust dies with "bad
  shim signature" forever. Boxes now launch with `security.secureboot=false`;
  the VM boundary, not boot attestation, is the box threat model.
- **`box expose` actually delivers packets** — a trilogy of drill-found
  absences: the NAT proxy needs the box's boxnet lease pinned as a static
  `ipv4.address` (Incus resolves `connect=0.0.0.0` against device config, not
  the lease); a loopback-sourced packet needs `route_localnet` plus a
  masquerade on the bridge to leave the host and be answerable; and the box's
  replies need a `ct state established,related` accept ahead of the host
  firewall's input drop, which was eating them statelessly. Boxes still
  cannot initiate toward the host — a box-originated SYN is a NEW flow.
- **Firewall rules now converge on upgrade** — `box-firewall.sh` rebuilds its
  chains every run (add + flush + re-add) instead of skipping when they
  exist, which had pinned every host to the rule set of the release that
  first ran there.
- **Failed mints tell you why** — cloud-init failures print the box's own log
  excerpts and leave the box up to inspect; a mint that never boots names the
  likely cause (corrupt image, Secure Boot, GRUB hang) and ships a sanitized
  console dump; the installer asserts it landed the ref it was asked for.
- **`grok` installs the binary it actually ships** — the installer was read,
  not guessed at, and the CLI lands on the non-interactive PATH (same fix
  class as codex).

### Changed

- **Debrand complete** — env vars, install dir, docs, template descriptions
  and the README all say `box`; the install URL is
  `heavy-duty/box` (GitHub redirects the old one, `BOX_REPO` overrides).
- **The drill grew from 47 to 84 checks** — the expose door opened, exercised
  and shut (with the contract re-probed around it), every template minted
  cold, a faithful pre-0.4.0 box re-homed through `migrate-host`, and the
  inline resource flags asserted (including their precedence over the
  environment).
