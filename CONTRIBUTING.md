# Contributing

This repository is governed by
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony). Agents read
[`.ceremony/AGENTS.md`](.ceremony/AGENTS.md) first, then the role file it
selects. The files under `.ceremony/` are machine-managed and must never be
edited in place.

Only triage mints issues. Everyone else opens or extends a discussion when
they find work outside an existing issue contract. Only humans merge.

## Review panel

The review panel is:

- `claude-bot-andresmgsl`
- `codex-bot-andresmgsl`
- `grok-bot-andresmgsl`
- `kimi-bot-andresmgsl`

Every PR needs a current-head verdict from the whole panel minus its author.
`dan-claude-bot` is triage-only and is never a reviewer. Draft PRs remain
invisible to the panel; when ready, request every eligible reviewer.

## Code and verification

- Bash executables use `set -euo pipefail`; test harnesses use `set -u`
  because they assert failing commands.
- Keep shellcheck clean. Run `bash test/cli.sh` and `bash test/release.sh`;
  CI also runs the Incus multi-user rehearsal.
- Match whole versions: `0.7.0` must never match `0.7.0-rc1`.
- Comments preserve the incident that bought a rule, including its issue
  number.

## Changelog

Every behavior-changing PR adds one concise line under `## Unreleased`,
above the shipped heading below it. Cite the issue or PR. Never replace or
duplicate a shipped heading; the shared armed and monotonic guards enforce
both halves of this rule.

## Releases

The release ceremony, merge and tag doors, version stamps, guard semantics,
and recovery paths are defined by
[heavy-duty/ceremony](https://github.com/heavy-duty/ceremony/blob/0.1.0/README.md).
Box pins the shared machinery and doctrine at `0.1.0`.

Box uses the `file` version backend and has no artifact hook: for this
pure-Bash tree, GitHub’s source tarball for the tag is the package, and
`install.sh` downloads exactly that. `VERSION`, `CHANGELOG.md`, and
`drills/<version>.md` remain box-owned release inputs.

### What a box drill proves

The box drill is the 85-probe VM isolation contract: it exercises the trust
boundary on real hardware. The lighter Incus container rehearsal in CI proves
the tier mechanics but cannot substitute for that boundary measurement. The
record format and operating procedure live in [drills/README.md](drills/README.md).

`drills/<version>.md` and [`drill/RUNS.md`](drill/RUNS.md) are deliberately
different artifacts. The former is per-release evidence read by the release
guard; the latter is the harness’s ongoing run log and lore. Updating one
never satisfies the purpose of the other.

The family drills are independent and may run in any order. Each pins the
same fixed candidate refs: rig’s drill uses the candidate box ref, while
box’s drill mints with the candidate rig ref. Static refs dissolve the
box↔rig runtime recursion; no repository needs to release first.

A known gap remains from box#81: released box templates still default
`RIG_REF` to `main`, so a later mint may consume a rig revision other than
the one drilled. This conversion does not change that behavior or claim the
gap is closed.

## Scope labels

- `scope:cli` — `bin/box`, the command surface
- `scope:installer` — `install.sh`, versioned installs, upgrade/uninstall
- `scope:host` — host setup, teardown, firewall, and isolation stack
- `scope:tiers` — grant/revoke and multi-user boundaries
- `scope:templates` — template and profile seeds
- `scope:drill` — rehearsals, doctor, and run evidence
