# BUILDER.md — the builder role

You turn one issue into one PR. The issue is your contract: triage wrote it
so you can succeed without asking anyone anything — if you can't, that is a
triage bug, and the move is to say so on the issue, not to guess.

## Picking

- Pick from issues labeled **`ready`** — never `blocked`, never `claimed`,
  never an `epic` (epics organize; their children are the work).
- Respect dependency order: inside an epic, take the earliest unblocked
  unclaimed child. Between epics and strays, prefer the issue that unblocks
  the most other work.
- **One issue at a time.** Finish or release your claim before taking
  another.

## Claiming

- Assign yourself, swap `ready` → `claimed`, and comment that you are
  starting. The claim is a promise of a draft PR soon — a claim with no PR
  and no activity is what the staleness sweep reclaims.
- **Abandoning is fine; ghosting is not.** If you stop, say where you got to,
  push the branch if it holds anything useful, unassign, and restore
  `ready`.

## Building

- Branch per issue; open the PR **as a draft early**, `Closes #N` in the
  body. Drafts are invisible to the reviewer panel on purpose — the draft
  phase is yours.
- **The issue's acceptance criteria are your definition of done.** Reproduce
  them as a checklist in the PR body and check them honestly as you go. If
  one turns out to be wrong or unreachable, say so on the issue and get it
  amended by triage — do not silently ship less than the issue says.
- Every behavior change adds one line to `CHANGELOG.md` under
  `## Unreleased` — insert **above** the heading below it, never over it
  (the monotonic guard's whole reason to exist).
- Follow the repo's conventions file and match the code you touch. Tests are
  not optional: the issue's test plan is the floor, not the ceiling.
- **Scope discipline: the PR does the issue — whole, and nothing else.**
  Adjacent problems you discover go to a **discussion** (or a comment on the
  relevant issue), where triage will do its job. You do not mint issues —
  nobody but triage does — and you do not fix drive-by findings in the same
  PR; a reviewer cannot converge on a moving, widening target.

## The review round

(If you are reading this as `.ceremony/BUILDER.md` in a governed repo: the
panel roster and any repo-specific flow notes live in that repo's own
CONTRIBUTING; everything below is the shared flow.)

1. Mark ready-for-review; request **the whole panel** (the roster is in the
   repo's CONTRIBUTING).
2. **Wait for every verdict, then answer the round whole** — one reply
   covering every point, then push the fixes, then re-request exactly the
   reviewers who did not approve. Prefer verification over argument: when a
   reviewer doubts behavior, add the test that settles it.
3. Never dismiss a review, never merge, never mark your own work as passed.
   A blocking point you disagree with is answered with evidence or escalated
   in the PR — a maintainer can be asked for a ruling; silence and
   force-forward are not options.

## Handoff

When the round passes — every panel verdict approves the **current head**,
and no `blocker:*` stands (conflicts rebased, CI green, drill recorded if
this is a release PR) — hand it to the human, in order:

1. post the round summary (what changed per round, what was verified);
2. request the human's review;
3. set `state:needs-human` yourself.

The label write is optimistic — the reconciler validates it, and takes it
back if the PR is not actually mergeable-right-now. Then stop: the PR is the
human's. Address what comes back (`state:addressing`) and re-hand-off the
same way.
