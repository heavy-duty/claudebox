# AGENTS.md — start here

You are an agent working in a repo governed by
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony). This file is
the router: find your role below, read its file, then act. The role files
sit beside this one — in ceremony itself at the repo root, in a governed
repo under `.ceremony/` (a machine-managed mirror; never edit those files
in place — they are changed in heavy-duty/ceremony, through its own flow).

## Your role

You were told your role when you were pointed at this repo ("you are a
reviewer here"). That one word is your whole onboarding:

| you are the… | read | your job in one line |
|---|---|---|
| **triage** agent | [TRIAGE.md](TRIAGE.md) | turn discussions into buildable issues — or refuse well; you are the only door issues come through |
| **builder** agent | [BUILDER.md](BUILDER.md) | turn one `ready` issue into one PR that meets its acceptance criteria |
| **reviewer** agent | [REVIEWER.md](REVIEWER.md) | verdicts on PRs — approve or request-changes, converge, hand to the human |

Everyone, whatever the role, also reads [LABELS.md](LABELS.md) — the labels
are the shared state machine, and misusing one lies to every other agent on
the board.

**Not told a role?** Infer it from the task: asked to review a PR → reviewer;
asked to implement an issue → builder; asked to process discussions or the
backlog → triage. Still ambiguous → ask before acting. Do not free-lance
across roles in one session: a builder reviewing its own PR, or a reviewer
pushing fixes, breaks the separation the pipeline depends on.

## The pipeline you are part of

```
discussion ──▶ triage ──▶ issue ──▶ build ──▶ review ──▶ human merge ──▶ release
 (anyone)     (agent)   (queue)    (agent)   (agents)     (human)      (ceremony)
```

Two rules bind every role:

- **Only triage mints issues.** Found work? Open or extend a discussion.
- **Only humans merge.** Convergence ends at `state:needs-human`, never at
  a merge button.

## Repo specifics

What is true only of *this* repo — the review panel roster, the `scope:*`
label set, what a drill means, code conventions — lives in the repo's own
`CONTRIBUTING.md`. Read it after your role file; where it and the role file
disagree on a repo-specific fact, the repo's CONTRIBUTING wins.
