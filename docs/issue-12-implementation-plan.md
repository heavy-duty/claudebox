# Implementation plan — the #12 split: audit, isolation hardening, box + templates

Plan of record for the work proposed in
[#12](https://github.com/heavy-duty/claudebox/issues/12), which is split into
three issues, strictly ordered:
[#15 audit](https://github.com/heavy-duty/claudebox/issues/15) →
[#16 isolation hardening](https://github.com/heavy-duty/claudebox/issues/16) →
[#17 box + templates](https://github.com/heavy-duty/claudebox/issues/17).
Pinned to `main` @ `0982a2d` (post-PR-#13). The issues are the *what and why*;
this is the *in what order, touching which lines, proven how*. Nothing lands
from this document — each stage below ships through its issue's own PR (the
audit ships no code at all, only findings).

## Sequencing

| Stage | Issue | Ships | Why this position |
| --- | --- | --- | --- |
| **0. Audit** | #15 | nothing — a verification log on the issue | The isolation analysis is a code reading; the boundary has never been probed live, and four Incus behaviors decide *which* code below is right. Verify before writing, not after. |
| **1. Isolation hardening** | #16 | explicit sibling drop, L2 filtering, `dns.mode=none`, IPv6-off as contract, `tests/isolation.sh` | Independently valuable on the *current* tool; no naming churn. Its test then stands guard over stage 2 — the rename cannot silently regress isolation that a test asserts. |
| **2. `box` + templates** | #17 | template dirs + parser, metadata stamping, user lookup, tag/name renames, profile split, installer, docs | The churny half. Lands against a repo whose isolation is already explicit and tested. |

The command-table refactor
([PR #13](https://github.com/heavy-duty/claudebox/pull/13), merged)
tag-gates every verb through `resolve_box()` (`bin/claudebox:349-355`) — which
is exactly the seam where stage 2's dual-tag matching lives: one function
instead of per-verb edits. It also added the `incus` escape hatch, which
answers "how do I run something as root in a templated box" without a flag.

## Stage 0 — audit (#15): verify the boundary and the four load-bearing behaviors

#15 carries the full probe tables: section A walks every edge of the stated
contract (egress, host, LAN, sibling, DNS enumeration, inbound, IPv6), section
B pins the mechanisms the later stages lean on. The four decisive B-checks:

1. **Bridge ACL catches intra-bridge traffic** — the premise of Part 2's
   analysis. Two scratch instances on `claudenet`; ping A→B. Expected: blocked
   (by the accidental `10.0.0.0/8` drop). If it is NOT blocked, Part 2's
   diagnosis is wrong and stage 1 gets redesigned before any code.
2. **`@internal` as ACL destination on a *bridge* network** —
   `incus network acl rule add claude-isolate egress action=drop destination=@internal`.
   Accepted and effective → stage 1 uses `@internal` (renumber-proof by
   construction). Rejected or inert → fall back to deriving the subnet in
   `setup-host.sh` (masking the gateway CIDR that
   `incus network get claudenet ipv4.address` returns — it is `10.87.0.1/24`,
   host bits included, not `10.87.0.0/24`).
3. **`incus copy` preserves `user.*` config keys** — clone a scratch instance
   carrying `user.box.user=claude`; `incus config get` on the clone. The whole
   `--from` reuse story rests on this.
4. **`dns.mode=none` semantics** — set it on a scratch bridge; confirm
   instance names stop resolving while upstream resolution through the
   gateway dnsmasq still works. (Also confirms the test's `getent` lines can
   go green.)

Each answer is a comment on #15. Cost: under an hour with Incus at hand.

## Stage 1 — isolation hardening (#16, one PR)

### Changes

**`host/setup-host.sh`**
- Add the explicit sibling drop to the `claude-isolate` ACL, *after* the
  gateway carve-out (rule order is load-bearing, as the existing comment
  says): `destination=@internal` per the audit's B1, else the derived-subnet
  form. Either way, one comment stating the intent: *boxes must not reach
  boxes; this rule is that statement, independent of the RFC1918 drops.*
- `incus network set claudenet dns.mode=none`.
- A comment on `ipv6.address=none` promoting it from choice to contract:
  every ACL rule below is IPv4-only; IPv6-on with no rules is an open door.
- All three idempotent, consistent with the script's re-run discipline
  (the ACL block currently only runs on create — the new rules follow the
  same guard, plus a one-shot `rule add` guarded by `acl show | grep`).

**`profiles/claude-dev.yaml`**
- `security.mac_filtering: "true"` and `security.ipv4_filtering: "true"` on
  `eth0`, with the caveat comment from the issue (box pinned to its own
  address; in-box Docker unaffected; extra-MAC workloads foreclosed).
- Existing boxes pick this up on profile re-apply (`setup-host.sh` already
  does `incus profile edit claude-dev <` on every run) — but a *running*
  instance may need a restart for NIC filtering to attach. The PR states
  this; the test proves it for fresh boxes.

**`tests/isolation.sh`** (new — first test in the repo)
- Exactly the issue's test block: mint `a` and `b`, extract B's `eth0`
  address (exact-name match, eth0-selected — a Docker-running box reports
  several quoted IPv4s across CSV lines, so naive `--columns 4` pasting
  self-destructs), then assert: ping A→B fails; `getent hosts b` and
  `getent hosts b.incus` fail; `curl https://example.com` passes;
  `incus network get claudenet ipv6.address` is `none`.
- Plain bash, `set -euo pipefail`, prints PASS/FAIL per line, exits nonzero
  on any MUST-fail that passed. Runs on a host with claudebox set up; not
  CI-wired (there is no CI and no Incus in CI — a `## running` header says
  how to run it by hand).
- Cleans up its two boxes on exit (`trap`), `--force`.

**`docs/claudebox-design.md`**
- The isolation section gains the sentence that was always missing: sibling
  boxes are mutually unreachable *by design*, DNS does not enumerate them,
  IPv6-off and L2 filtering are part of the contract, and `tests/isolation.sh`
  is the proof.

### Acceptance (#16's list)

- Isolation unchanged and now explicit: host, LAN, sibling, DNS enumeration
  all blocked — `tests/isolation.sh` green on a live host, output pasted
  into the PR.
- No CLI behavior change whatsoever (`claudebox --version` to `rm` — this PR
  touches no line of `bin/claudebox`).

## Stage 2 — `box` with templates (#17, one PR, after maintainer answers)

### Blocking inputs (#17's open questions — maintainer calls)

| Question | Recommendation | Default if unanswered |
| --- | --- | --- |
| Compat or clean cut for the *CLI name* | clean cut at next minor; keep dual-**tag** matching regardless (non-negotiable — old boxes/snapshots must not fall out of `list`/`shell`/`--from`) | clean cut |
| Default template | `claude` — muscle memory survives | `claude` |
| Repo/binary naming | keep repo `heavy-duty/claudebox`, binary `box`, installer keeps `CLAUDEBOX_*` env vars as documented aliases for one release | keep repo name |

### Changes, in commit order

1. **`templates/`** — `claude/` (today's `cloud-init/user-data.yaml` moved
   verbatim + `box.env` with `BOX_DESCRIPTION/IMAGE/USER/CPU/MEMORY/DISK`)
   and `blank/` (minimal user-create cloud-init + its `box.env`).
   `cloud-init/` directory retires in the same commit.
2. **Manifest parser** — `read_template()`: strict `KEY="value"` reader
   (grep + case allowlist, ~15 lines, zero-dep). **Not `source`** — a
   template must not execute host bash, and an unknown key (`BOX_NETWORK=`)
   is a hard error, which is the enforcement of "a template cannot express
   a different network". Mint-time warning if `user-data.yaml` does not
   mention `BOX_USER` (grep, advisory only — the two declare the same fact
   twice and cannot be mechanically unified while cloud-init stays verbatim).
3. **Launch path** (today's launch block, `bin/claudebox:423-426` and the
   surrounding `cmd_new`) — resolve template
   (`--template`, default per decision), stamp
   `user.box=1 user.box.template=<t> user.box.user=<BOX_USER>`, apply
   resources as `--config limits.cpu/limits.memory` + VM `--device
   root,size=`, profile becomes `box-net`.
4. **User lookup** — `box_user()` reading `user.box.user` off the instance
   (empty-string-safe: `incus config get` exits 0 with empty output on unset
   keys), legacy branch: `user.claudebox=1` → `claude`, final fallback
   `root`. `shell`/`exec` (today's `:522-523`) use it.
5. **Dual-tag matching** — `resolve_box()` (`:349-355`) and the `list`
   filters (`:441,485`) accept `user.box=1` *or* `user.claudebox=1`.
   `list` merges both sets.
6. **Profile split** — `profiles/box-net.yaml`: NIC (+ the new stage-1
   security flags) and root-disk device — the placement contract, nothing
   else. Resources leave for the templates. `claude-dev` is left in place
   for existing boxes (Incus refuses to delete an in-use profile);
   `setup-host.sh` stops managing it and prints a note when it still exists.
7. **`box templates`** — list `templates/*/box.env` names + descriptions;
   discovery via the existing `$root` resolution (`bin/claudebox:8` already
   `readlink -f`s through the install symlink, so `templates/` ships exactly
   like `cloud-init/` does today).
8. **Renames** — binary `bin/box`, network `boxnet`, ACL `box-isolate`,
   profile `box-net`, nft table `inet box`, `/usr/local/sbin/box-firewall`
   + unit, `~/.local/share/box`; `install.sh` (tarball check at `:41`,
   symlink at `:53`, env vars per decision). Host setup migrates: detects
   the old-name network/ACL and renames or recreates idempotently —
   **existing boxes keep working through it** (they sit on the bridge by
   device reference; the test from stage 1, renamed with everything else,
   re-proves isolation after the rename).
9. **Docs** — design doc, README, recipe: tool is `box`, Claude is a
   template, `.claudebox/` repo-runbook convention **unchanged in v1**
   (consuming repos depend on it), `~/.claude/CLAUDE.md` text updated in the
   claude template only.

### Acceptance (stage 2 slice — the issue's list, verbatim, plus)

- Every unchecked box in #17's acceptance section, run live and pasted
  into the PR.
- A `box.env` with an unknown key is rejected with a message naming the key.
- A pre-rename box (tagged `user.claudebox=1`): appears in `box list`,
  `box shell` lands in `claude`, `box new --from old/authed` clones and the
  clone shells into `claude`.
- `tests/isolation.sh` (post-rename names) green.

## Risks

- **The audit's A3 fails to block** — sibling traffic NOT blocked today.
  Then #16's analysis gets corrected first (it is a worse bug than
  documented) and stage 1 becomes the fix rather than the formalization.
  The plan's shape survives; the urgency changes.
- **`@internal` unsupported on bridge networks** — planned for: the derived
  subnet fallback is specified above, one function in `setup-host.sh`.
- **Running-instance NIC filtering** — `security.*_filtering` may need an
  instance restart to take effect on existing boxes; stated in the stage-1
  PR rather than automated (restarting user boxes unasked is not this
  tool's style).

## Out of scope, deliberately

- Named opt-in networks (#16's forward-looking section) — the design
  here avoids foreclosing it (drop rule is intent-stated, profile is the
  single placement contract) and builds none of it.
- CI for the isolation test — no Incus in CI today; the test is a runbook
  script with PASS/FAIL discipline.
- Renaming the `.claudebox/` repo-runbook convention — consuming repos
  depend on it; explicitly frozen in v1.
