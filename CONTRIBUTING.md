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

   This PR is where the release ritual hangs:
   the full drill on real hardware, recorded in
   [drill/RUNS.md](drill/RUNS.md) — CI proves the tier's semantics on every
   PR, a release still proves the boundary.
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
