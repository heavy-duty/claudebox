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
STATES=(state:building state:needs-rebase state:bots-reviewing state:addressing state:needs-human)
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

decide_state() { # → the one state:* label this PR should carry
  if [ "$DRAFT" = true ]; then echo state:building; return; fi

  # state:needs-human means ONE thing: a human could merge this right now.
  # Anything that makes that false outranks the request that put it there —
  # otherwise the board invites a merge that cannot or must not happen, and
  # nothing else on the page contradicts it (#136).
  #
  # A conflicted or red branch is the agent's to fix, not the human's to
  # merge. UNKNOWN is deliberately NOT treated as unmergeable: GitHub reports
  # it for a minute after every merge while it recomputes, and flapping every
  # open PR through needs-rebase on each merge would be worse than the bug.
  # An unknown mergeability simply does not trigger this arm; the next sweep
  # sees the settled value.
  # Both default to the "do not know" value: an unset global (older fixture,
  # a failed fetch) must never invent a verdict it did not read.
  case "${MERGEABLE:-UNKNOWN}" in CONFLICTING) echo state:needs-rebase; return ;; esac
  case "${CHECKS:-NONE}" in FAILURE) echo state:needs-rebase; return ;; esac

  local b v verdicts=""
  for b in "${BOTS[@]}"; do
    if requested "$b"; then echo state:bots-reviewing; return; fi
  done
  for b in "${BOTS[@]}"; do
    v="$(bot_verdict "$b")"
    if [ "$v" = MISSING ]; then
      # No verdict at all from this bot. An explicit human request still
      # outranks an unfinished bot round — a maintainer pulling a PR to
      # themselves early is a deliberate act, and the original precedence.
      if requested "$HUMAN"; then echo state:needs-human; return; fi
      echo state:bots-reviewing; return
    fi
    verdicts="$verdicts $v"
  done
  case "$verdicts" in
    # STALE = a verdict for an older head. Unlike MISSING, this outranks the
    # human request: every approval was invalidated by a push, so NOBODY has
    # reviewed this tree. Handing that to the human is the #136 case where
    # everything reads green — mergeable, CI passing, "waiting on the human" —
    # over code no reviewer has seen. The agent owes a re-request.
    *STALE*) echo state:addressing; return ;;
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
state:needs-rebase|B60205|Does not merge — conflicts or failing checks; the agent owes a fix
state:needs-human|8250DF|All bots approve — waiting on the human reviewer
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

  # ---- converge the state:* labels ----
  remove=""
  for s in "${STATES[@]}"; do
    if [ "$s" != "$desired" ] && has_label "$s"; then remove="$remove,$s"; fi
  done
  remove="${remove#,}"
  if ! has_label "$desired" || [ -n "$remove" ]; then
    args=(--add-label "$desired")
    [ -n "$remove" ] && args+=(--remove-label "$remove")
    if run gh issue edit "$n" -R "$REPO" "${args[@]}" >/dev/null; then
      log "#$n: state -> $desired${remove:+ (cleared $remove)}"
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
      CHECKS="$(jq -r '
        (.statusCheckRollup // []) as $c
        | if ($c | length) == 0 then "NONE"
          elif ($c | map(.conclusion // .state // "") | any(. == "FAILURE" or . == "TIMED_OUT" or . == "STARTUP_FAILURE" or . == "ACTION_REQUIRED")) then "FAILURE"
          elif ($c | map(.conclusion // .state // "") | any(. == "" or . == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED")) then "PENDING"
          else "SUCCESS" end' <<<"$GH_VIEW")"
      reconcile_pr "$n"
    ) || log "#$n: reconcile failed — continuing with the remaining PRs"
  done
  log "reconciled."
}

# sourced by test/labels-reconcile.sh for the fixture tests; executed in CI
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
