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
# DRY_RUN=1 narrates every mutation instead of performing it (how this script
# is rehearsed against the live repo). A workflow_dispatch run also bootstraps
# the taxonomy (label create --force), which is how a fresh repo — or a label
# someone deleted — self-heals.

REPO="${REPO:?set REPO to owner/name}"
HUMAN="${HUMAN_REVIEWER:-danmt}"
BOTS=(claude-bot-andresmgsl codex-bot-andresmgsl grok-bot-andresmgsl)
STATES=(state:building state:bots-reviewing state:addressing state:needs-human)
STALE_AFTER=$((48 * 3600))

log() { printf 'labels: %s\n' "$*"; }

run() { # every mutation goes through here — DRY_RUN=1 logs instead of doing
  if [ -n "${DRY_RUN:-}" ]; then log "DRY_RUN: $*"; else "$@"; fi
}

bootstrap_labels() { # dispatch-only: ~20 upserts is too chatty for every cron tick
  while IFS='|' read -r name color desc; do
    [ -n "$name" ] || continue
    run gh label create "$name" -R "$REPO" --color "$color" --description "$desc" --force
  done <<'EOF'
state:building|FBCA04|PR is a draft — the coding agent is still building
state:bots-reviewing|1D76DB|Waiting on the bot reviewers to finish the round
state:addressing|D93F0B|All bots reviewed — coding agent owes the single reply + fixes
state:needs-human|8250DF|All bots approve — waiting on the human reviewer
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

if [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ]; then
  log "workflow_dispatch: bootstrapping the taxonomy"
  bootstrap_labels
fi

now="$(date +%s)"

for n in $(gh pr list -R "$REPO" --state open --limit 100 --json number --jq '.[].number'); do
  pr="$(gh api "repos/$REPO/pulls/$n")"
  draft="$(jq -r '.draft' <<<"$pr")"
  labels="$(jq -r '.labels[].name' <<<"$pr")"
  requested_logins="$(jq -r '.requested_reviewers[].login' <<<"$pr")"
  # PENDING reviews are unsubmitted drafts sitting in someone's browser — not a verdict
  reviews="$(gh api --paginate "repos/$REPO/pulls/$n/reviews" --jq '.[]' \
    | jq -s '[.[] | select(.state != "PENDING")]')"

  latest() { # $1 = login → their latest submitted review state, or empty
    jq -r --arg u "$1" \
      '[.[] | select(.user.login == $u)] | sort_by(.submitted_at) | last | .state // empty' \
      <<<"$reviews"
  }
  requested() { grep -qxF "$1" <<<"$requested_logins"; }
  has_label() { grep -qxF "$1" <<<"$labels"; }

  # ---- who is the ball with? (the LABELS.md state machine) ----
  desired=""
  if [ "$draft" = true ]; then
    desired=state:building
  elif requested "$HUMAN"; then
    # an explicit human request outranks the bot rounds — it is the final
    # gate, and a maintainer pulling a PR to themselves early counts too
    desired=state:needs-human
  else
    for b in "${BOTS[@]}"; do
      # in requested_reviewers = round (re-)requested and unanswered; never
      # reviewed at all = the round hasn't even started for this bot
      if requested "$b" || [ -z "$(latest "$b")" ]; then desired=state:bots-reviewing; fi
    done
    if [ -z "$desired" ]; then
      all_approved=1
      for b in "${BOTS[@]}"; do
        [ "$(latest "$b")" = APPROVED ] || all_approved=0
      done
      if [ "$all_approved" = 1 ]; then
        # the ball is the human's — unless their last word was CHANGES_REQUESTED
        # and nobody has re-requested them since (then the agent owes fixes)
        if ! requested "$HUMAN" && [ "$(latest "$HUMAN")" = CHANGES_REQUESTED ]; then
          desired=state:addressing
        else
          desired=state:needs-human
        fi
      else
        desired=state:addressing
      fi
    fi
  fi

  # encode the runbook's last step: all bots approve → the human is asked, once.
  # The guard (never requested, never reviewed) is what makes this idempotent.
  if [ "$desired" = state:needs-human ] && ! requested "$HUMAN" && [ -z "$(latest "$HUMAN")" ]; then
    run gh api "repos/$REPO/pulls/$n/requested_reviewers" -f "reviewers[]=$HUMAN" --silent
    log "#$n: requested $HUMAN (all bots approve)"
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
    run gh issue edit "$n" -R "$REPO" "${args[@]}" >/dev/null
    log "#$n: state -> $desired${remove:+ (cleared $remove)}"
  fi

  # ---- stale: real activity only, and blocked is legitimately quiet ----
  last_activity="$(
    {
      jq -r '.created_at' <<<"$pr"
      jq -r '.[].submitted_at' <<<"$reviews"
      gh api --paginate "repos/$REPO/issues/$n/comments" --jq '.[].created_at'
      gh api --paginate "repos/$REPO/pulls/$n/comments" --jq '.[].created_at'
      gh api --paginate "repos/$REPO/pulls/$n/commits" --jq '.[].commit.committer.date'
    } | sort | tail -n1
  )"
  age=$((now - $(date -d "$last_activity" +%s)))
  if has_label blocked || [ "$age" -le "$STALE_AFTER" ]; then
    if has_label stale; then
      run gh issue edit "$n" -R "$REPO" --remove-label stale >/dev/null
      log "#$n: unstale"
    fi
  elif ! has_label stale; then
    run gh issue edit "$n" -R "$REPO" --add-label stale >/dev/null
    log "#$n: stale ($((age / 3600))h quiet)"
  fi
done

log "reconciled."
