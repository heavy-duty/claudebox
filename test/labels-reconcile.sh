#!/usr/bin/env bash
set -euo pipefail

# Fixture tests for the labels-reconcile state machine: a comment is a
# non-verdict whatever its body says (the AUTHOR escalates by requesting the
# human), a stale approval does not promote unreviewed code, and an explicit
# human request outranks everything.
# Dependency-free beyond jq; no network, no daemon — pure decide_state.

cd "$(dirname "$0")/.."
# shellcheck source=.github/scripts/labels-reconcile.sh
. .github/scripts/labels-reconcile.sh

# The DRAFT/HEAD_SHA/REQUESTED/REVIEWS_JSON assignments below are the state
# machine's inputs, consumed inside the sourced decide_state — not unused.
# shellcheck disable=SC2034
BOT1="${BOTS[0]}" BOT2="${BOTS[1]}" BOT3="${BOTS[2]}"
pass=0 fail=0

expect() { # $1 = description, $2 = want, $3 = got
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s — want %s, got %s\n' "$1" "$2" "$3"
  fi
}

rev() { # $1=login $2=state $3=commit $4=body $5=submitted_at → one review object
  jq -n --arg u "$1" --arg s "$2" --arg c "$3" --arg b "$4" --arg t "$5" \
    '{user: {login: $u}, state: $s, commit_id: $c, body: $b, submitted_at: $t}'
}

reviews() { jq -s '.' <<<"$*"; } # collect review objects into an array

# -- drafts are building, whoever is requested --------------------------------
DRAFT=true HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON='[]'
expect "draft PR is building" state:building "$(decide_state)"

# -- fresh ready PR with bots requested ---------------------------------------
DRAFT=false REQUESTED="$BOT1
$BOT2
$BOT3" REVIEWS_JSON='[]'
expect "requested bots mean bots-reviewing" state:bots-reviewing "$(decide_state)"

# -- a bot that never reviewed keeps the round open ---------------------------
#    With a live request that is the bots' ball; with NO request outstanding it
#    is the agent's, because nothing is coming until somebody asks.
REQUESTED="$BOT3" REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)")"
expect "a missing bot WITH a live request is bots-reviewing" state:bots-reviewing "$(decide_state)"
REQUESTED=""
expect "...but with nobody asked it is the agent's ball" state:addressing "$(decide_state)"
expect "...and the blocker names the stall" blocker:unrequested "$(blockers)"

# -- a comment is a non-verdict, agreement body or not: the author escalates --
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" COMMENTED head1 "✅ **Reviewed — I agree with everything.**" t1)" \
  "$(rev "$BOT2" APPROVED  head1 "" t2)" \
  "$(rev "$BOT3" APPROVED  head1 "" t3)")"
expect "comment-only agreement still parks on the author" state:addressing "$(decide_state)"
# ...and the author's escalation — requesting the human — flips it
REQUESTED="$HUMAN"
expect "author escalation flips to needs-human" state:needs-human "$(decide_state)"
REQUESTED=""

# -- three formal approvals need no author judgment ---------------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "three formal approvals reach needs-human" state:needs-human "$(decide_state)"

# -- a comment WITHOUT a verdict parks the PR on the agent --------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" COMMENTED head1 "🔧 Reviewed — I agree with most; feedback below." t1)" \
  "$(rev "$BOT2" APPROVED  head1 "" t2)" \
  "$(rev "$BOT3" APPROVED  head1 "" t3)")"
expect "comment without verdict is addressing" state:addressing "$(decide_state)"

# -- changes requested blocks, at any head ------------------------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" CHANGES_REQUESTED old1 "blockers below" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "changes-requested blocks even from an old head" state:addressing "$(decide_state)"

# -- a stale approval must not promote unreviewed code ------------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED old1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "stale approval is addressing (agent owes re-request)" state:addressing "$(decide_state)"

# -- a re-requested bot reopens the round even with an old approval on file ---
REQUESTED="$BOT1"
expect "re-requested bot means bots-reviewing" state:bots-reviewing "$(decide_state)"
REQUESTED=""

# -- only the LATEST review per bot counts ------------------------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" CHANGES_REQUESTED head1 "blockers" t1)" \
  "$(rev "$BOT1" APPROVED head1 "" t2)" \
  "$(rev "$BOT2" APPROVED head1 "" t3)" \
  "$(rev "$BOT3" APPROVED head1 "" t4)")"
expect "later approval supersedes earlier block" state:needs-human "$(decide_state)"

# -- an explicit human request outranks the bot rounds ------------------------
REQUESTED="$HUMAN" REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" COMMENTED head1 "feedback, no verdict" t1)")"
expect "human requested outranks bots" state:needs-human "$(decide_state)"
REQUESTED=""

# -- human CHANGES_REQUESTED puts the ball back on the agent ------------------
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)" \
  "$(rev "$HUMAN" CHANGES_REQUESTED head1 "not yet" t4)")"
expect "human block with bots approving is addressing" state:addressing "$(decide_state)"
# ...and re-requesting the human hands it back to them
REQUESTED="$HUMAN"
expect "re-requested human is needs-human again" state:needs-human "$(decide_state)"
REQUESTED=""

# -- an old human comment must not wedge the handoff (codex, #85 round 3) -----
REVIEWS_JSON="$(reviews \
  "$(rev "$HUMAN" COMMENTED old1 "early thoughts" t0)" \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "old human comment + three approvals is needs-human" state:needs-human "$(decide_state)"
expect "old human comment still needs a fresh request" needed "$(human_request_needed && echo needed || echo not-needed)"
# ...a stale human APPROVAL likewise needs a re-request for the new head
REVIEWS_JSON="$(reviews \
  "$(rev "$HUMAN" APPROVED old1 "" t0)" \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "stale human approval needs a fresh request" needed "$(human_request_needed && echo needed || echo not-needed)"
# ...a HEAD-CURRENT human approval needs nothing more
REVIEWS_JSON="$(reviews \
  "$(rev "$HUMAN" APPROVED head1 "" t0)" \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"
expect "head-current human approval needs no request" not-needed "$(human_request_needed && echo needed || echo not-needed)"
# ...and a live request suppresses re-requesting
REQUESTED="$HUMAN"
expect "live human request suppresses re-request" not-needed "$(human_request_needed && echo needed || echo not-needed)"
REQUESTED=""

# ---------------------------------------------------------------------------
# #136: state:needs-human must mean "a human could merge this RIGHT NOW".
# Both cases below were observed live in this repo on 2026-07-20, and both
# showed state:needs-human while being unmergeable in different ways.
# ---------------------------------------------------------------------------
ALL_APPROVE="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)" \
  "$(rev "$BOT3" APPROVED head1 "" t3)")"

# -- flavour 1: not mergeable. The merge button is disabled, yet the board
#    said "your turn" on #119/#120/#127 for hours. The branch fact now rides
#    the blocker axis; the state says whose ball it is, which is the agent's.
DRAFT=false HEAD_SHA=head1 REQUESTED="" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=CONFLICTING CHECKS=SUCCESS
expect "a CONFLICTING PR is the agent's, not the human's" state:addressing "$(decide_state)"
expect "...and says WHY on the blocker axis" blocker:conflict "$(blockers)"
REQUESTED="$HUMAN"
expect "...even with the human explicitly requested" state:addressing "$(decide_state)"

# -- red CI is the same claim, but NOT the same work: a rebase does not fix a
#    failing test. Collapsing both into one needs-rebase label told the agent
#    to do the wrong thing, which is why the axis split exists.
REQUESTED="" MERGEABLE=MERGEABLE CHECKS=FAILURE
expect "a red PR is the agent's" state:addressing "$(decide_state)"
expect "...and is distinguishable from a conflict" blocker:ci-red "$(blockers)"
REQUESTED="$HUMAN"
expect "...and a human request does not override red CI" state:addressing "$(decide_state)"

# -- both at once. The single-axis design could not say this at all: one label
#    had to win, and the loser silently vanished off the board.
REQUESTED="" MERGEABLE=CONFLICTING CHECKS=FAILURE
expect "a conflicted AND red PR reports both blockers" "blocker:conflict
blocker:ci-red" "$(blockers)"
expect "...and is still just the agent's ball" state:addressing "$(decide_state)"

# -- UNKNOWN is NOT unmergeable. GitHub reports it for ~a minute after every
#    merge while it recomputes; treating it as broken would flap every open PR
#    on each merge — worse than the bug being fixed.
REQUESTED="" MERGEABLE=UNKNOWN CHECKS=PENDING
expect "UNKNOWN mergeability blocks nothing" state:needs-human "$(decide_state)"
expect "...and raises no blocker" "" "$(blockers)"

# -- blocker:unrequested — the stalled round. Nobody owes an answer because
#    nobody was ever asked, yet the board read "waiting on the bots" until
#    `stale` noticed 48h later.
MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED="" REVIEWS_JSON='[]'
expect "ready, nobody asked, nothing reviewed raises unrequested" blocker:unrequested "$(blockers)"
# ...the partial case is equally stalled: one verdict in, nobody asked for the rest
REVIEWS_JSON="$(reviews "$(rev "$BOT1" APPROVED head1 "" t1)")"
expect "one bot in, none requested is still unrequested" blocker:unrequested "$(blockers)"
# ...but a live request means an answer IS coming
REQUESTED="$BOT2"
expect "a live bot request is not a stalled round" "" "$(blockers)"
# ...and a draft is exempt: the bots ignore drafts by design
DRAFT=true REQUESTED="" REVIEWS_JSON='[]'
expect "a draft with nobody asked is not stalled" "" "$(blockers)"
# ...as is an explicit human request — claiming a PR early is deliberate
DRAFT=false REQUESTED="$HUMAN"
expect "an early human claim is not a stalled round" "" "$(blockers)"
REQUESTED="" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE CHECKS=SUCCESS

# -- flavour 2 (the dangerous one): mergeable, green, human requested, and
#    NOBODY has reviewed this head. Observed on #119 after a rebase: every
#    signal read "merge me" and nothing on the page contradicted it.
MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED="$HUMAN"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED oldhead "" t1)" \
  "$(rev "$BOT2" APPROVED oldhead "" t2)" \
  "$(rev "$BOT3" APPROVED oldhead "" t3)")"
expect "stale approvals outrank the human request (nobody reviewed this tree)" state:addressing "$(decide_state)"

# -- ...and a round that is BOTH unfinished and staled is still the agent's.
#    Deciding inside the bot loop made this depend on BOTS order: the MISSING
#    returned before any later bot's STALE was read, so the mixed round came
#    out needs-human with nothing bound to the head. Pinned at both ends of
#    the array, because the whole failure was one of ordering.
MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED="$HUMAN"
REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED oldhead "" t1)" \
  "$(rev "$BOT2" APPROVED oldhead "" t2)")"
expect "stale approvals + a bot yet to review is addressing, not needs-human" \
  state:addressing "$(decide_state)"
REVIEWS_JSON="$(reviews "$(rev "$BOT3" APPROVED oldhead "" t3)")"
expect "...and the same when the stale verdict is the LAST bot in BOTS" \
  state:addressing "$(decide_state)"

# -- but an UNFINISHED round still yields to an explicit human request: a
#    maintainer pulling a PR to themselves early is deliberate, and was the
#    original precedence. MISSING differs from STALE — nobody has reviewed
#    YET, versus everyone reviewed something else.
REVIEWS_JSON="$(reviews "$(rev "$BOT1" APPROVED head1 "" t1)")"
expect "an unfinished round still yields to an explicit human request" state:needs-human "$(decide_state)"
REQUESTED=""
expect "...and without that request the agent owes the ask" state:addressing "$(decide_state)"

# ---------------------------------------------------------------------------
# checks_state: the rollup classifier. It lived inline in main() for the first
# round of this PR, which is why nothing here caught it calling ERROR,
# CANCELLED and STALE green. Extracted so the enum can be pinned down.
# ---------------------------------------------------------------------------
rollup() { jq -n --argjson c "$1" '{statusCheckRollup: $c}'; }
run_() { jq -n --arg n "$1" --arg o "$2" --arg t "${3:-2026-07-20T15:00:00Z}" \
  '{__typename:"CheckRun", workflowName:"ci", name:$n, conclusion:$o, completedAt:$t}'; }
ctx_() { jq -n --arg n "$1" --arg s "$2" --arg t "${3:-2026-07-20T15:00:00Z}" \
  '{__typename:"StatusContext", context:$n, state:$s, createdAt:$t}'; }

expect "no checks at all is NONE" NONE "$(rollup '[]' | checks_state)"
# A failed fetch leaves no rollup KEY; a PR with no checks leaves an empty
# ARRAY. Collapsing the two let an API hiccup read as "nothing is failing" —
# the same unknown-certified-as-green shape as #136, in the one place that
# fix did not look. The caller skips an UNREADABLE PR rather than relabelling.
expect "a failed read is UNREADABLE, not NONE" UNREADABLE "$(echo '{}' | checks_state)"
expect "...and a real empty rollup is still NONE" NONE \
  "$(echo '{"mergeable":"MERGEABLE","statusCheckRollup":[]}' | checks_state)"
expect "all green is SUCCESS" SUCCESS \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b SUCCESS)]" | checks_state)"
expect "a queued run is PENDING" PENDING \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b QUEUED)]" | checks_state)"
expect "a plain failure is FAILURE" FAILURE \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b FAILURE)]" | checks_state)"

# -- the round-1 gap: outcomes that are neither success nor pending, and that
#    leave a required check unsatisfied. All three reached the old `else`.
expect "a commit status ERROR blocks" FAILURE \
  "$(rollup "[$(run_ a SUCCESS),$(ctx_ lint ERROR)]" | checks_state)"
expect "a CANCELLED run blocks" FAILURE \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b CANCELLED)]" | checks_state)"
expect "a STALE run blocks" FAILURE \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b STALE)]" | checks_state)"
expect "an outcome the enum does not know blocks, it does not pass" FAILURE \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b SOME_FUTURE_STATE)]" | checks_state)"

# -- NEUTRAL and SKIPPED satisfy branch protection; path-filtered jobs skip
#    constantly, and calling that red would park every PR on the agent.
expect "NEUTRAL and SKIPPED are not failures" SUCCESS \
  "$(rollup "[$(run_ a SUCCESS),$(run_ b NEUTRAL),$(run_ c SKIPPED)]" | checks_state)"

# -- latest-wins. The rollup keeps superseded runs, so this PR's own tip
#    carried a CANCELLED `scope` beside the SUCCESS `scope` that replaced it.
#    Without collapsing, making CANCELLED block would strand it forever.
expect "a re-run supersedes the cancelled original" SUCCESS \
  "$(rollup "[$(run_ scope CANCELLED 2026-07-20T15:19:39Z),\
              $(run_ scope SUCCESS   2026-07-20T15:19:45Z)]" | checks_state)"
expect "...and the reverse order is not a re-run passing, it is one failing" FAILURE \
  "$(rollup "[$(run_ scope SUCCESS   2026-07-20T15:19:39Z),\
              $(run_ scope CANCELLED 2026-07-20T15:19:45Z)]" | checks_state)"
# same job name in a different workflow is a different context, not a re-run
expect "same name in another workflow does not supersede" FAILURE \
  "$(rollup "[$(jq -n '{__typename:"CheckRun",workflowName:"labels",name:"scope",conclusion:"FAILURE",completedAt:"2026-07-20T15:00:00Z"}'),\
              $(run_ scope SUCCESS 2026-07-20T15:19:45Z)]" | checks_state)"

# -- a run still IN FLIGHT. `run_()` cannot express this: it always carries a
#    real completedAt, which is exactly why the supersede rule shipped dating
#    runs by completion and nothing caught it. Both spellings of "no
#    completion" are pinned, because `gh` emits the zero sentinel (a string,
#    which `//` does not fall through) while the API emits null.
inflight_() { jq -n --arg n "$1" --arg t "$2" --arg c "${3:-0001-01-01T00:00:00Z}" \
  '{__typename:"CheckRun", workflowName:"ci", name:$n, status:"IN_PROGRESS",
    conclusion:"", startedAt:$t, completedAt:(if $c == "null" then null else $c end)}'; }

expect "a re-run in flight beats the success it superseded (zero sentinel)" PENDING \
  "$(rollup "[$(run_ build SUCCESS 2026-07-20T15:00:00Z),\
              $(inflight_ build 2026-07-20T15:10:00Z)]" | checks_state)"
expect "...and the same when the absent completion is null" PENDING \
  "$(rollup "[$(run_ build SUCCESS 2026-07-20T15:00:00Z),\
              $(inflight_ build 2026-07-20T15:10:00Z null)]" | checks_state)"
expect "a replacement in flight for a CANCELLED run is pending, not failed" PENDING \
  "$(rollup "[$(run_ build CANCELLED 2026-07-20T15:00:00Z),\
              $(inflight_ build 2026-07-20T15:10:00Z)]" | checks_state)"
# an entry carrying no usable timestamp is treated as newest, not oldest —
# ambiguity resolves toward "not settled" rather than toward a stale success.
# Guarded by the sort tiebreak rather than the dating expression: reverting
# only `at:` leaves this passing, so the two changes are separately pinned.
expect "an undateable in-flight run is not discarded for a stale success" PENDING \
  "$(rollup "[$(run_ build SUCCESS 2026-07-20T15:00:00Z),\
              $(jq -n '{__typename:"CheckRun",workflowName:"ci",name:"build",conclusion:"",startedAt:null,completedAt:null}')]" \
     | checks_state)"
# ...and the reverse direction, which stops "in flight sorts last" being
# widened into "in flight always wins": a run that FINISHED after an earlier
# in-flight entry is the newer word, and the context is settled.
expect "a finished re-run supersedes an earlier in-flight run" SUCCESS \
  "$(rollup "[$(inflight_ build 2026-07-20T15:19:00Z),\
              $(run_ build SUCCESS 2026-07-20T15:19:45Z)]" | checks_state)"

# -- the wind-down window. A predecessor cancelled by the concurrency group
#    does not stop the instant its replacement starts, so its completion
#    routinely lands AFTER the successor's start — on box's aa5a6ba the
#    replacement started 15:19:38 and the run it cancelled finished 15:19:51.
#    Dating by "newest stamp of any kind" compares the dead run's completion
#    against the live run's start, which is not an ordering on runs, and the
#    predecessor wins. Every fixture above spaces completion before start, so
#    none of them can see it. run_() cannot express the overlap either — it
#    carries no startedAt — hence the explicit payloads.
overlap_() { jq -n --arg n "$1" --arg o "$2" --arg s "$3" --arg c "$4" \
  '{__typename:"CheckRun", workflowName:"ci", name:$n, conclusion:$o,
    startedAt:$s, completedAt:$c}'; }
expect "a predecessor finishing after its replacement started is still older (CANCELLED)" PENDING \
  "$(rollup "[$(overlap_ scope CANCELLED 2026-07-20T15:19:00Z 2026-07-20T15:19:51Z),\
              $(inflight_ scope 2026-07-20T15:19:38Z)]" | checks_state)"
expect "...and the same when it finished green — mid-flight is not mergeable" PENDING \
  "$(rollup "[$(overlap_ build SUCCESS 2026-07-20T15:19:00Z 2026-07-20T15:19:51Z),\
              $(inflight_ build 2026-07-20T15:19:38Z)]" | checks_state)"

# -- the classifier feeds the state machine: a cancelled required check must
#    take the PR off the human's plate, which is the whole point of #136.
DRAFT=false HEAD_SHA=head1 REQUESTED="$HUMAN" REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE
CHECKS="$(rollup "[$(run_ a SUCCESS),$(run_ b CANCELLED)]" | checks_state)"
expect "a cancelled check reaches decide_state as the agent's ball" state:addressing "$(decide_state)"
expect "...via blocker:ci-red, not a conflict" blocker:ci-red "$(blockers)"

# -- the happy path survives all of the above.
REVIEWS_JSON="$ALL_APPROVE" MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED=""
expect "mergeable + green + three head-current approvals is needs-human" state:needs-human "$(decide_state)"
# -- and a draft outranks everything, including a conflict.
DRAFT=true MERGEABLE=CONFLICTING
expect "a draft is building even when conflicted" state:building "$(decide_state)"
DRAFT=false MERGEABLE=MERGEABLE CHECKS=SUCCESS REQUESTED="" REVIEWS_JSON='[]'

printf 'labels-reconcile tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
