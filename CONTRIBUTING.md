# Contributing

How change lands in this repo. The short version: PRs are born as drafts,
three reviewer bots take the first rounds, a human takes the last word — and
labels tell you where everything is without opening anything.

## The PR loop

1. **Fork and branch.** Contributors work from forks; upstream branches are
   for maintainers. Title the PR conventionally (`feat:`, `fix:`, `docs:`),
   and include a `CHANGELOG.md` entry under `## Unreleased` when the change
   deserves one.
2. **Open as a draft** while you build. Drafts are invisible to the reviewer
   bots on purpose.
3. **When it's ready**: mark ready-for-review and request all three bots —
   `claude-bot-andresmgsl`, `codex-bot-andresmgsl`, `grok-bot-andresmgsl`.
   They poll roughly every 15 minutes.
4. **Rounds are answered whole.** Wait until all three have reviewed, then
   answer the entire round in a **single reply**, push the fixes, and
   re-request the bots that didn't approve. Prefer verification over
   argument: a test settles what a comment thread can't.
5. **Reviews end in a verdict.** A reviewer — bot or human — either
   **approves** or **requests changes**, never a bare comment. A
   comment-only review is a non-verdict: it doesn't say whether the round
   passed, and the state machine (and anyone scanning the board) has to
   guess. The verdict carries *blockingness only*, the body carries the
   feedback: non-blocking nits ride an **approval** and the author addresses
   them at their discretion; anything blocking — including a question that
   gates the verdict — is **request changes**, saying what unblocks it. The
   reconciler treats a comment-only review as not-approved, so commenting
   without a verdict only stalls the PR. The machine never reads review
   bodies: when a comment-only reviewer's line is really an agreement, that
   judgment belongs to the **author** — escalate by requesting the
   maintainer's review (step 6), and the reconciler flips the label on that
   request, because an explicit request is a fact it can trust.
6. **When the round passes, the author hands the PR to the maintainer** in
   three acts, in this order: post the tagged round summary, request the
   maintainer's review, then set `state:needs-human` yourself — removing the
   state label it replaces. The review request is what *earns* the label,
   provided the PR carries **no `blocker:*` label**. A blocker means the work
   is still yours whatever the round said, so on a conflicted or red PR
   neither the request nor your own label write will stick — the sweep takes
   it straight back off. With three formal head-current approvals the labels
   workflow requests the maintainer automatically; when part of the panel is
   comment-only, reading their agreement is the author's judgment, so the
   author makes the request.

   Writing the label by hand is an **optimistic write, not a transfer of
   ownership**. The machine stays the authority — but because the workflow
   wakes on `labeled`, the author's own write fires the sweep that validates
   it, and a handoff that had not earned the label is corrected seconds later.
   Forgetting the write is not a failure either; it only means the label waits
   for the cron, which is the lag this replaced.
7. **Checks must be green**: `shellcheck` and `bash test/cli.sh` locally
   mirror what CI runs; the multi-user rehearsal runs in CI on a real Incus.

## Changelog entries

Every PR that changes behaviour adds **one line** to `## Unreleased`. One line
is the whole rule — if it wraps more than twice in your editor, cut it down.

- **Say what changed, and stop.** Why it was wrong, how it was found, what it
  cost, what it implies — that belongs in the PR body and the commit message,
  which is where anyone chasing the reasoning already goes. This file answers
  one question: what is different in this version.
- **Any word that can be removed, is removed.**
- **Lead with the surface, not the mechanism.** "`state:needs-human` is set at
  handoff" beats "the labels workflow now also wakes on `labeled`".
- **Cite the issue or PR** — `(#141)` — and let the reader follow it for the
  rest.
- **Mark a breaking change** with a leading `BREAKING:`.
- Group under `### Added` / `### Changed` / `### Fixed` / `### Removed`.
- No bold run-in headings, no sub-paragraphs, no code blocks, no prose essays.

Good:

```markdown
- `state:needs-human` is set at handoff, not by the cron (#141)
- An unreadable check rollup no longer reads as "nothing is failing" (#136)
- BREAKING: `--class human|server` is now `--root-door closed|open` (#77)
```

Not an entry — that is a PR body:

```markdown
- **`state:needs-human` no longer waits on the cron to become true** (#141) —
  the labels workflow now also wakes on `pull_request_target: labeled` and
  `unlabeled`, and the author sets it themselves when handing a PR over. A
  review landing was never a trigger. There is no `pull_request_review_target`,
  and on fork PRs — which is all of them here — ...
```

## Releases

A release is a PR, and merging it ships it
([#96](https://github.com/heavy-duty/box/issues/96), building on
[#83](https://github.com/heavy-duty/box/issues/83)):

1. **The release PR** — `release: X.Y.Z`, labeled `release` — bumps `VERSION`
   from `X.Y.Z-dev` and stamps the `## Unreleased` section with version +
   date (feature PRs land their changelog entry as part of the PR, so the
   section is already written).

   **Stamping is two edits, not one — the second is re-arming.** After
   rewriting `## Unreleased` into `## X.Y.Z — DATE`, put an **empty
   `## Unreleased` back at the top**, immediately above the section you just
   stamped:

   ```markdown
   ## Unreleased

   ## 0.7.1 — 2026-07-19

   ### Fixed
   ...
   ```

   Not cosmetic, and not deferrable to the next PR that happens to need it.
   Between the stamp and the next re-creation of that heading, `main` has no
   `## Unreleased`. A PR authored *before* the release wrote its entry under
   that heading; with the heading gone, git lands the entry under whatever
   now occupies the position — **the section that just shipped** — and it
   merges **cleanly**, no conflict, no signal. The changelog then credits a
   released version with a change it does not contain, and nothing but a
   human reading the file will ever say so
   ([#108](https://github.com/heavy-duty/box/issues/108); confirmed in the
   sibling repo as
   [heavy-duty/rig#66](https://github.com/heavy-duty/rig/issues/66)).

   CI enforces the arming rule with
   [.github/scripts/changelog-armed.sh](.github/scripts/changelog-armed.sh),
   keyed on `VERSION`: a `-dev` tree must carry `## Unreleased` on top; a
   bare-`VERSION` tree (the ceremony PR, and the merge that publishes it) may
   carry either `## Unreleased` or its own stamped section. That is why the
   guard cannot simply demand `## Unreleased` unconditionally — the
   unconditional form is false on the ceremony PR's own tree and makes the
   release unshippable, which is why rig and cast both reverted it. The
   practical consequence: forgetting to re-arm does **not** block the release
   PR, it turns `main` red on the very next push — the automatic `-dev` bump
   the release itself makes. Do it in the ceremony PR and main is never
   disarmed at all.

   **Release headings are append-only.** When you add your entry under
   `## Unreleased`, *insert above* the heading below it — never type over
   that line. Replacing `## 0.8.0 — 2026-07-19` with your own `## Unreleased`
   block deletes a shipped section: its prose is absorbed into `Unreleased`,
   `release-notes.sh` can no longer find the version it extracts by heading,
   and the next release republishes the absorbed prose as if it were new. git
   merges that edit cleanly and `changelog-armed.sh` stays green on it — the
   top section is still the right one — so
   [.github/scripts/changelog-monotonic.sh](.github/scripts/changelog-monotonic.sh)
   asserts the other half on every PR: the set of `## X.Y.Z` headings on your
   branch must be a **superset** of the set at the merge base
   ([#122](https://github.com/heavy-duty/box/issues/122), caught in review of
   [#118](https://github.com/heavy-duty/box/pull/118)). The ceremony's own
   stamp passes it by construction — rewriting `## Unreleased` into
   `## X.Y.Z — DATE` adds a heading and removes none.

   **The drill gates the release, and CI enforces it.** The release PR's
   flow is: draft → ready → bot round → **drill** → `state:needs-human` →
   maintainer merge (which *is* the release). CI proves the tier's semantics
   on every PR; the drill is what proves the VM trust boundary, and it wants
   real hardware and the better part of an hour, so it runs on the release
   PR's branch and nowhere else.

   Record it in [drill/RUNS.md](drill/RUNS.md) under its own heading:

   ```markdown
   ## Release drill — X.Y.Z — DATE
   ```

   ...with the run under it — what it measured, what it found, what it cost.
   [.github/scripts/drill-recorded.sh](.github/scripts/drill-recorded.sh)
   asserts exactly that on every tree with a bare `VERSION`, which is every
   `release` PR and the merge that publishes it; a `-dev` tree passes with
   nothing to assert. It is **no longer a thing a reviewer has to remember**.

   It became CI's job because remembering did not work. The sentence this
   paragraph replaces described a step **no release had ever performed** —
   `drill/RUNS.md` carried no `## Release drill` section at all — and #95,
   #114 and #148 all shipped through the gap as a `VERSION` bump plus a
   `CHANGELOG.md` stamp. The one time it was caught was the one time somebody
   happened to look, which is not a gate.

   **The drill is ONE orchestrated run over the whole stack**, not three
   drills in a queue. box and rig are **mutually recursive**, so there is no
   linear order to put them in: rig sits *below* box as the host-builder
   (`rig bootstrap --host yes` installs box and runs `setup-host`) and
   *above* it as the guest-converger (a `box new` seed's cloud-init curls
   rig's installer and runs `rig bootstrap <tenant>-box`). box's own source
   says as much — the seeds "invert the rig→box install edge (rig#28: rig
   installs box on hosts; now box guests install rig)". The run goes:

   1. `rig bootstrap --host yes` on a bare Debian host — installs box, runs
      `setup-host`
   2. `box new` mints a creds-free seed
   3. the seed converges itself via `rig bootstrap <tenant>-box`
   4. cast on top

   It drills **candidate refs, not released artifacts.** `RIG_REPO` and
   `RIG_REF` are mint-time environment variables (defaults
   `heavy-duty/rig` and `main`, `bin/box`), so a run pins the exact commits
   under test. That dissolves the chicken-and-egg: **no repo has to be
   released before another can be drilled.** And drilling the candidate *is*
   drilling the release — a release PR's diff is `VERSION` plus
   `CHANGELOG.md` and nothing else, so no executable byte differs between
   the tree that was drilled and the tree that ships.

   One run emits **one shared run ID**. Each repo records its own legs under
   its own `## Release drill — X.Y.Z — DATE`, citing that run ID and the
   other two repos' commit SHAs, so the three records reconcile into a single
   run afterwards. The guard reads only this repo's file — it asserts box's
   record exists, never the other two.

   **A known gap, and box is where it belongs.** A *released* box still
   defaults `RIG_REF` to `main`, so what a user mints a week after a drill is
   not the combination that was drilled — the guest converges against
   whatever rig's main has become since. Pinning `RIG_REF` to a released rig
   tag in the templates is the outstanding step from
   [#81](https://github.com/heavy-duty/box/issues/81) (rig#32 step 5), and it
   is what would make a drilled combination reproducible for users. This PR
   does not fix it; box's source already says the two directions "track main
   unpinned today, said honestly ... until a release flow exists".

   A maintainer **waiver** is possible, and it is still written down. The
   guard requires a *record*, not a passing result, so a release that must
   ship without a full drill puts the section under the same heading and says
   plainly that the drill was waived and why. Skipping then costs a
   deliberate, reviewable line in the diff — which is precisely what the
   three silent skips above did not.
2. **The maintainer's merge IS the release.**
   [release.yml](.github/workflows/release.yml) fires on the merged,
   `release`-labeled PR and asserts before creating anything: `VERSION` at
   the merge commit is non-`-dev` **and changed in this PR** (the `-dev`
   interlock — a mislabeled ordinary PR fails loudly and creates nothing),
   the version's `CHANGELOG.md` section extracts non-empty, and no tag or
   release exists for it yet. Then, in the same job, it tags the merge
   commit bare `X.Y.Z` (no `v` prefix, the `0.6.0` precedent) and publishes
   the GitHub release with that section as the body. No assets — the source
   tarball for the tag is the package, and `install.sh` downloads exactly
   that.

   *Manual fallback/backfill*: the tag-push path stays. Tagging the merge
   commit bare `X.Y.Z` by hand and pushing the tag still publishes the same
   way (release.yml asserts the tag names the tree's own `VERSION`) — for
   backfills, or the day the merge path is red.
3. **The release re-arms main itself**: the same workflow run bumps
   `VERSION` to `X.Y.(Z+1)-dev` and pushes the commit straight to main —
   no follow-up PR (it opens one only if branch protection refuses the
   direct push, and says so loudly). Not cosmetic — the versioned layout
   names install trees after `VERSION`, so a `main` install without the
   bump would land in `versions/X.Y.Z` and impersonate the release just
   cut. On the *manual* tag path the bump stays yours: open the one-line
   PR after publishing.

## Labels — who sets what

The full taxonomy lives in [LABELS.md](LABELS.md). What matters day to day is
who sets each kind — most of it is machinery, and hand-moving a
machine-owned label just gets corrected on the next pass:

| Labels | Set by |
|---|---|
| `state:*` | the labels workflow ([.github/workflows/labels.yml](.github/workflows/labels.yml)) — recomputed from GitHub's own facts on PR events (label changes included) and every 15 minutes. Machine-owned, with one exception: the author sets `state:needs-human` at handoff (step 6) and the workflow reconciles it. Otherwise never by hand. Exactly one per PR: *whose ball is it.* |
| `blocker:*` | the same workflow, from the same facts — *what is in the way.* Any number per PR, or none. Never by hand: applying one does not stop a merge, and removing one does not unblock anything. Fix the thing and the next sweep drops the label. |
| `stale` | the same workflow — 48h without commits, comments, or reviews. `blocked` PRs are exempt: they are quiet legitimately. |
| `scope:*` on PRs | actions/labeler, from the changed paths ([.github/labeler.yml](.github/labeler.yml)). Additive — you may add more, the machine won't remove them. |
| `scope:*` on issues | you, when opening or triaging — issues have no paths to derive from. |
| `blocked`, `release` | you — automation never guesses intent. |
| `merge-next` | you or the agent owning the queue. Which PR lands first is a judgement about how they conflict, so the workflow never sets it — it only **clears** it, the moment the PR stops being something a human could merge. |
| `bug` / `enhancement` / `documentation` | you, on issues only — a PR's type already lives in its title. |

## Issues

Give issues the same care as PR titles: say the surface in the title, apply a
`scope:` label and a type label (`bug` / `enhancement` / `documentation`) when
you open one, and `blocked` when it waits on something — that is what keeps
the board navigable as the issue count grows.
