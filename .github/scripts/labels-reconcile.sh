#!/usr/bin/env bash
set -euo pipefail

# labels-reconcile.sh — the automation LABELS.md promises: state labels are
# written by machinery, never by hand. Every run derives each open PR's
# state:* from GitHub's own facts (draft flag, requested reviewers, submitted
# reviews) and converges the labels to it, so a killed run or a hand-moved
# label heals on the next pass. Stale is judged from real activity — commits,
# comments, reviews — never from label churn, or the sweep would un-stale its
# own mark every tick.
#
# The verdict contract (CONTRIBUTING.md): reviews end in approve or
# request-changes. Some live bots are comment-only and post agreement as a
# COMMENTED review — a non-verdict this machine refuses to guess about (body
# parsing is a heuristic, and a wrong guess promotes an unapproved PR). The
# judgment call belongs to the PR AUTHOR, who reads the round and escalates
# by requesting the human's review — an explicit request is a fact, and it is
# the one this machine trusts (see decide_state's top precedence). The
# machine auto-requests the human only in the no-judgment-needed case: three
# formal head-current approvals. Any approval that counts must be bound to
# the CURRENT head SHA: GitHub keeps approvals alive across pushes, and a
# stale approval must never promote unreviewed code to the human.
#
# DRY_RUN=1 narrates every mutation instead of performing it (how this script
# is rehearsed against the live repo). A workflow_dispatch run also bootstraps
# the taxonomy (label create --force) — that heal is dispatch-only; the cron
# sweep tolerates a missing label rather than recreating it.
#
# The state machine below is pure (globals in, state out) and covered by
# fixture tests in test/labels-reconcile.sh.

HUMAN="${HUMAN_REVIEWER:-danmt}"
BOTS=(claude-bot-andresmgsl codex-bot-andresmgsl grok-bot-andresmgsl)
STATES=(state:building state:bots-reviewing state:addressing state:needs-human)
BLOCKERS=(blocker:conflict blocker:ci-red blocker:unrequested)
# Labels this machine used to own and no longer does. Cleared on sight so a
# retirement heals the board instead of stranding a label nothing recomputes.
RETIRED=(state:needs-rebase)
STALE_AFTER=$((48 * 3600))

log() { printf 'labels: %s\n' "$*"; }

run() { # every mutation goes through here — DRY_RUN=1 logs instead of doing
  if [ -n "${DRY_RUN:-}" ]; then log "DRY_RUN: $*"; else "$@"; fi
}

# ---------------------------------------------------------------------------
# The state machine. Pure functions over four globals, set per PR:
#   DRAFT        true|false
#   HEAD_SHA     the PR's current head commit
#   REQUESTED    newline-separated logins with a review currently requested
#   REVIEWS_JSON JSON array of submitted (non-PENDING) reviews
#   MERGEABLE    MERGEABLE | CONFLICTING | UNKNOWN  (GitHub's own verdict)
#   CHECKS       SUCCESS | FAILURE | PENDING | NONE (the check rollup)
# ---------------------------------------------------------------------------

requested() { grep -qxF "$1" <<<"$REQUESTED"; }

checks_state() { # rollup JSON on stdin → SUCCESS | FAILURE | PENDING | NONE
  # The rollup mixes two node types with two different closed enums: CheckRun
  # carries `conclusion` (CheckConclusionState), StatusContext carries `state`
  # (StatusState). Rather than list the outcomes that block — the version that
  # shipped in this PR's first round listed four, and ERROR, CANCELLED and
  # STALE fell through its `else` into SUCCESS — this lists the outcomes that
  # DON'T, and treats everything else as blocking.
  #
  # That direction is the point. An outcome we do not recognise is one we
  # cannot certify as mergeable, and certifying the unrecognised as green is
  # the exact shape of #136. The cost of being wrong is symmetric in form and
  # not in consequence: a false FAILURE parks the PR on the agent, who looks;
  # a false SUCCESS invites a human to merge a tree that will not merge.
  jq -r '
    # NEUTRAL and SKIPPED satisfy branch protection — a skipped required check
    # is not a failed one, and path-filtered jobs skip constantly here.
    ["SUCCESS", "NEUTRAL", "SKIPPED"] as $passing
    # "" covers a StatusContext still reported with no state at all.
    | ["", "PENDING", "IN_PROGRESS", "QUEUED", "WAITING", "REQUESTED", "EXPECTED"] as $waiting

    # A re-run does not evict the run it superseded — the rollup keeps both.
    # This PR proved it: its own tip carried a CANCELLED `scope` (15:19:39)
    # beside the SUCCESS `scope` (15:19:45) that replaced it, same workflow.
    # Once CANCELLED blocks, judging every entry would strand this very PR in
    # needs-rebase forever, so collapse each context to its newest entry first.
    # Key on workflow + name because a bare job name is only unique within its
    # workflow.
    #
    # Dating a run is the subtle part, and getting it wrong restores the bug.
    # A run still in flight has no completion, but `gh` does not omit the
    # field: its Go struct marshals the zero time as "0001-01-01T00:00:00Z",
    # which is a string, so `//` will not fall through it. Ordering on
    # completion therefore sorted the LIVE re-run to the bottom and let `last`
    # pick the very run it superseded — reporting the old SUCCESS while a
    # replacement was still running, which is #136 again.
    #
    # So: date a run by when it BEGAN, discarding both spellings of absent
    # (null, and the zero sentinel) and falling back only if it never recorded
    # a beginning. NOT by the newest stamp of any kind: `max` compares the
    # completion of a finished run against the start of a live one, which are
    # different quantities and not an ordering on runs. A run cancelled by the
    # concurrency group does not stop the instant its replacement starts — the
    # runner has to wind down — so predecessor.completedAt > successor.startedAt
    # is the ordinary case, and `max` dated the dead predecessor newer than the
    # live run that replaced it, narrowing both failures above without closing
    # them. The list is already in preference order, so `first` IS that rule.
    #
    # An entry that carries no usable timestamp at all sorts LAST rather than
    # first — something we cannot date is most likely the thing just created,
    # and treating it as newest keeps an undateable in-flight run from being
    # discarded in favour of a stale success. Every ambiguity resolves toward
    # "not settled".
    | [ (.statusCheckRollup // [])[]
        | { ctx: [.workflowName // "", .name // .context // ""],
            at:  ([.startedAt, .createdAt, .completedAt]
                  | map(select(type == "string" and . != ""
                               and (startswith("0001-01-01") | not)))
                  | first // ""),
            outcome: ((.conclusion // .state // "") | ascii_upcase) } ]
    | group_by(.ctx)
    | map(sort_by([(.at == ""), .at]) | last | .outcome) as $latest

    | if   ($latest | length) == 0                            then "NONE"
      elif (($latest - $passing - $waiting) | length) > 0     then "FAILURE"
      elif (($latest - $passing) | length) > 0                then "PENDING"
      else "SUCCESS" end'
}

bot_verdict() { # $1 = login → MISSING | BLOCK | APPROVE | STALE | FEEDBACK
  local review state commit
  review="$(jq -c --arg u "$1" \
    '[.[] | select(.user.login == $u)] | sort_by(.submitted_at) | last // empty' \
    <<<"$REVIEWS_JSON")"
  if [ -z "$review" ]; then echo MISSING; return; fi
  state="$(jq -r '.state' <<<"$review")"
  commit="$(jq -r '.commit_id' <<<"$review")"
  case "$state" in
    CHANGES_REQUESTED)
      # blocks at ANY head — GitHub's own semantic: only a newer review
      # from the same reviewer clears it
      echo BLOCK ;;
    APPROVED)
      if [ "$commit" = "$HEAD_SHA" ]; then echo APPROVE; else echo STALE; fi ;;
    *)
      # COMMENTED and anything else: a non-verdict. The machine does not
      # read bodies — if the comment is really an agreement, the AUTHOR
      # says so by requesting the human's review.
      echo FEEDBACK ;;
  esac
}

human_request_needed() { # 0 when needs-human requires a FRESH human request
  # already requested → the handoff is live; head-current human approval →
  # nothing left to ask. Anything else (never reviewed, an old comment, an
  # approval of an older head) stalls the handoff unless we request —
  # guarding on "has the human ever reviewed" wedged exactly that way.
  if requested "$HUMAN"; then return 1; fi
  if [ "$(bot_verdict "$HUMAN")" = APPROVE ]; then return 1; fi
  return 0
}

blockers() { # → the blocker:* labels this PR should carry, one per line
  # The second axis. These are FACTS ABOUT THE BRANCH, and they are mutually
  # independent — a PR can be conflicted and red and unasked at once — so they
  # are a set, not an ordering. That is the whole point of splitting them out
  # of state:*: every precedence bug this machine has had (needs-human
  # surviving a conflict, MISSING swallowing STALE) came from projecting
  # independent facts onto one totally-ordered label. A set has no precedence
  # to get wrong.
  #
  # UNKNOWN mergeability is deliberately NOT a conflict: GitHub reports it for
  # about a minute after every merge while it recomputes, and flapping every
  # open PR on each merge would be worse than the bug. Same for a failed read
  # of either fact — both default to the "do not know" value, which blocks
  # nothing. An unset global (an older fixture, a failed fetch) must never
  # invent a verdict it did not read.
  case "${MERGEABLE:-UNKNOWN}" in CONFLICTING) echo blocker:conflict ;; esac
  case "${CHECKS:-NONE}" in FAILURE) echo blocker:ci-red ;; esac

  # Nobody is on the hook for a verdict somebody still owes. Distinct from
  # bots-reviewing, which says a request is live and an answer is coming:
  # here the round is stalled because no one was ever asked, and the board
  # said "waiting on the bots" for the 48h it took `stale` to notice.
  # A draft is exempt (the bots ignore drafts by design), and so is an
  # explicit human request — a maintainer claiming a PR early is deliberate,
  # not a dropped ball.
  if [ "$DRAFT" != true ] && ! requested "$HUMAN"; then
    local b any_missing=false any_requested=false
    for b in "${BOTS[@]}"; do
      requested "$b" && any_requested=true
      [ "$(bot_verdict "$b")" = MISSING ] && any_missing=true
    done
    if [ "$any_missing" = true ] && [ "$any_requested" = false ]; then
      echo blocker:unrequested
    fi
  fi
}

decide_state() { # → the one state:* label this PR should carry
  if [ "$DRAFT" = true ]; then echo state:building; return; fi

  local s
  s="$(round_state)"

  # The one rule joining the two axes: state:needs-human means a human could
  # merge this RIGHT NOW, so it requires a clear branch. Any blocker at all
  # means the work is the agent's — whatever the review round says — and the
  # blocker label says which work it is. Nothing else in this function reads
  # the branch, which is what keeps the ordering below purely about reviews.
  if [ "$s" = state:needs-human ] && [ -n "$(blockers)" ]; then
    echo state:addressing; return
  fi
  echo "$s"
}

round_state() { # → the state the REVIEW ROUND alone implies; knows no branch facts
  local b verdicts=""
  for b in "${BOTS[@]}"; do
    if requested "$b"; then echo state:bots-reviewing; return; fi
  done
  # Collect the WHOLE round before applying any precedence. Deciding inside
  # the loop let BOTS order pick the winner: a MISSING returned immediately,
  # so a STALE belonging to a later bot was never even read, and the mixed
  # round (one approval staled by a push, another bot yet to review) came out
  # needs-human — the #136 headline shape, with zero reviews bound to the head.
  for b in "${BOTS[@]}"; do
    verdicts="$verdicts $(bot_verdict "$b")"
  done
  case "$verdicts" in
    # STALE = a verdict for an older head. Unlike MISSING, this outranks the
    # human request: every approval it covers was invalidated by a push, so
    # NOBODY has reviewed this tree. Handing that to the human is the #136 case
    # where everything reads green — mergeable, CI passing, "waiting on the
    # human" — over code no reviewer has seen. The agent owes a re-request.
    # Checked before MISSING because "unfinished" must not swallow "and also
    # stale": a round that is both is a push that outran the re-requests, not
    # a maintainer deliberately claiming the PR early.
    *STALE*) echo state:addressing; return ;;
  esac
  case "$verdicts" in
    # No verdict at all from some bot, and nothing staled. An explicit human
    # request still outranks an unfinished round — a maintainer pulling a PR
    # to themselves early is a deliberate act, and the original precedence.
    #
    # Otherwise it is the AGENT's ball, not the bots'. The loop above already
    # returned for every live bot request, so reaching here with a MISSING
    # means somebody owes a verdict and nobody was asked for one — the round
    # is not running. Calling that bots-reviewing was the lie that let a
    # forgotten PR read "waiting on the reviewers" for the 48h it took the
    # stale sweep to notice. blocker:unrequested says why.
    *MISSING*)
      if requested "$HUMAN"; then echo state:needs-human; return; fi
      echo state:addressing; return ;;
  esac
  # an explicit human request outranks the remaining bot outcomes — it is the
  # final gate, and a maintainer pulling a PR to themselves early counts too
  if requested "$HUMAN"; then echo state:needs-human; return; fi
  case "$verdicts" in
    # FEEDBACK = a comment with no verdict → the agent owes the round-reply.
    *BLOCK* | *FEEDBACK*) echo state:addressing; return ;;
  esac
  # the bots all approve — but if the human's standing word is
  # changes-requested (and nobody re-requested them yet), the agent owes
  # fixes, not the human a nag
  if [ "$(bot_verdict "$HUMAN")" = BLOCK ]; then
    echo state:addressing
  else
    echo state:needs-human
  fi
}

# ---------------------------------------------------------------------------
# The sweep: fetch facts, decide, converge. One PR's failure never aborts the
# others — each PR reconciles in a subshell and a failure just logs.
# ---------------------------------------------------------------------------

bootstrap_labels() { # dispatch-only: ~20 upserts is too chatty for every cron tick
  while IFS='|' read -r name color desc; do
    [ -n "$name" ] || continue
    run gh label create "$name" -R "$REPO" --color "$color" --description "$desc" --force
  done <<'EOF'
state:building|FBCA04|PR is a draft — the coding agent is still building
state:bots-reviewing|1D76DB|Waiting on the bot reviewers to finish the round
state:addressing|D93F0B|All bots reviewed — coding agent owes the single reply + fixes
state:needs-human|8250DF|No blockers, all bots approve — waiting on the human reviewer
blocker:conflict|B60205|Does not merge — the branch conflicts and the agent owes a rebase
blocker:ci-red|B60205|A check is failing — the agent owes a fix (not a rebase)
blocker:unrequested|E99695|Somebody still owes a verdict and nobody was asked for one
merge-next|0E8A16|Head of the merge queue — merge this one next (set by hand/agent, cleared here)
stale|B60205|No activity for 48h — needs a poke (sweep-managed)
blocked|6A737D|Waiting on another PR or issue to land first
release|0E8A16|Release flow and version/packaging work
scope:cli|C5DEF5|bin/box — the command surface
scope:installer|C5DEF5|install.sh, versioned installs, upgrade/uninstall
scope:host|C5DEF5|host/ — setup, teardown, firewall, isolation stack
scope:tiers|C5DEF5|restricted tier — grant/revoke, multi-user
scope:templates|C5DEF5|templates/ — the box seeds
scope:drill|C5DEF5|drill/ — rehearsals, doctor, RUNS.md
EOF
}

has_label() { grep -qxF "$1" <<<"$LABELS"; }

reconcile_pr() { # $1 = PR number; relies on the globals set from its fetch
  local n="$1" desired remove s args last_activity age

  desired="$(decide_state)"

  # encode the runbook's last step for the no-judgment case: three formal
  # head-current approvals → the human is asked, once. The guard asks whether
  # a FRESH human review is needed for THIS head — never "has the human ever
  # reviewed", which wedged the handoff after any earlier human comment.
  # Idempotent (a live request suppresses it); race-free via the shared
  # concurrency group in labels.yml. With a comment-only bot on the panel
  # this path stays cold and the AUTHOR requests the human.
  if [ "$desired" = state:needs-human ] && human_request_needed; then
    run gh api "repos/$REPO/pulls/$n/requested_reviewers" -f "reviewers[]=$HUMAN" --silent
    log "#$n: requested $HUMAN (round passed)"
  fi

  # ---- converge both axes ----
  # state:* is exclusive (everything but $desired comes off); blocker:* is a
  # set (each one on or off on its own); RETIRED always comes off. One edit
  # call for all of it, so a PR never flickers through a half-applied board.
  local want_blockers add=""
  want_blockers="$(blockers)"

  remove=""
  for s in "${STATES[@]}"; do
    if [ "$s" != "$desired" ] && has_label "$s"; then remove="$remove,$s"; fi
  done
  for s in "${RETIRED[@]}"; do
    if has_label "$s"; then remove="$remove,$s"; fi
  done
  for s in "${BLOCKERS[@]}"; do
    if grep -qxF "$s" <<<"$want_blockers"; then
      has_label "$s" || add="$add,$s"
    else
      has_label "$s" && remove="$remove,$s"
    fi
  done
  add="${add#,}"
  remove="${remove#,}"
  if ! has_label "$desired" || [ -n "$remove" ] || [ -n "$add" ]; then
    args=(--add-label "$desired${add:+,$add}")
    [ -n "$remove" ] && args+=(--remove-label "$remove")
    if run gh issue edit "$n" -R "$REPO" "${args[@]}" >/dev/null; then
      log "#$n: state -> $desired${add:+ +$add}${remove:+ (cleared $remove)}"
    else
      # a deleted label must not wedge the sweep — dispatch heals the taxonomy
      log "#$n: WARNING: label edit failed (missing label? run the workflow manually to bootstrap)"
    fi
  fi

  # ---- merge-next: cleared, never set ----------------------------------
  # Queue order is INTENT — which PR should land first is a judgement about
  # conflicts and dependencies that GitHub knows nothing about, so the
  # reconciler must not guess it (LABELS.md's rule for `blocked`/`release`).
  # What it CAN do is stop the label going stale the way needs-human did:
  # the moment the PR is no longer the thing a human should merge next, the
  # claim is removed. Setting it stays with whoever owns the queue.
  if has_label merge-next && [ "$desired" != state:needs-human ]; then
    run gh issue edit "$n" -R "$REPO" --remove-label merge-next >/dev/null
    log "#$n: cleared merge-next (state is $desired, not mergeable-by-a-human)"
  fi

  # ---- stale: real activity only, and blocked is legitimately quiet ----
  last_activity="$(
    {
      jq -r '.created_at' <<<"$PR_JSON"
      jq -r '.[].submitted_at' <<<"$REVIEWS_JSON"
      gh api --paginate "repos/$REPO/issues/$n/comments" --jq '.[].created_at'
      gh api --paginate "repos/$REPO/pulls/$n/comments" --jq '.[].created_at'
      gh api --paginate "repos/$REPO/pulls/$n/commits" --jq '.[].commit.committer.date'
    } | sort | tail -n1
  )"
  age=$((NOW - $(date -d "$last_activity" +%s)))
  if has_label blocked || [ "$age" -le "$STALE_AFTER" ]; then
    if has_label stale; then
      run gh issue edit "$n" -R "$REPO" --remove-label stale >/dev/null
      log "#$n: unstale"
    fi
  elif ! has_label stale; then
    run gh issue edit "$n" -R "$REPO" --add-label stale >/dev/null
    log "#$n: stale ($((age / 3600))h quiet)"
  fi
}

main() {
  REPO="${REPO:?set REPO to owner/name}"
  NOW="$(date +%s)"

  if [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ]; then
    log "workflow_dispatch: bootstrapping the taxonomy"
    bootstrap_labels
  fi

  local n
  for n in $(gh pr list -R "$REPO" --state open --limit 100 --json number --jq '.[].number'); do
    (
      PR_JSON="$(gh api "repos/$REPO/pulls/$n")"
      DRAFT="$(jq -r '.draft' <<<"$PR_JSON")"
      HEAD_SHA="$(jq -r '.head.sha' <<<"$PR_JSON")"
      LABELS="$(jq -r '.labels[].name' <<<"$PR_JSON")"
      REQUESTED="$(jq -r '.requested_reviewers[].login' <<<"$PR_JSON")"
      # PENDING reviews are unsubmitted drafts in someone's browser — not a verdict
      REVIEWS_JSON="$(gh api --paginate "repos/$REPO/pulls/$n/reviews" --jq '.[]' \
        | jq -s '[.[] | select(.state != "PENDING")]')"
      # mergeability + the check rollup, the two facts the state machine was
      # blind to (#136). `gh pr view` rather than the REST PR object: the API's
      # `mergeable` is a tri-state boolean that GitHub computes lazily, while
      # this returns the same MERGEABLE/CONFLICTING/UNKNOWN string the UI shows.
      # Failure to read them is NOT fatal and NOT treated as broken — an API
      # hiccup must never flap every PR into needs-rebase, so both degrade to
      # the "do not know" value that triggers nothing.
      GH_VIEW="$(gh pr view "$n" -R "$REPO" --json mergeable,statusCheckRollup 2>/dev/null || echo '{}')"
      MERGEABLE="$(jq -r '.mergeable // "UNKNOWN"' <<<"$GH_VIEW")"
      CHECKS="$(checks_state <<<"$GH_VIEW")"
      reconcile_pr "$n"
    ) || log "#$n: reconcile failed — continuing with the remaining PRs"
  done
  log "reconciled."
}

# sourced by test/labels-reconcile.sh for the fixture tests; executed in CI
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
