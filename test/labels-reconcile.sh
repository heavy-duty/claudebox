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
REQUESTED="" REVIEWS_JSON="$(reviews \
  "$(rev "$BOT1" APPROVED head1 "" t1)" \
  "$(rev "$BOT2" APPROVED head1 "" t2)")"
expect "missing bot review means bots-reviewing" state:bots-reviewing "$(decide_state)"

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

printf 'labels-reconcile tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
