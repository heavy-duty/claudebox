# drills/ — release evidence, one file per version

This directory holds the **evidence that a release was proven on real
hardware**. One file per shipped version, named exactly for the version:

```
drills/0.9.0.md
drills/0.9.0-rc1.md
```

The name must match the contents of `VERSION` exactly.
[the pinned ceremony drill-recorded action](https://github.com/heavy-duty/ceremony/tree/0.1.0/actions/drill-recorded)
refuses any tree with a bare `VERSION` that has no such file, or whose file is
blank. A `-dev` tree passes with nothing to assert.

Because each version owns a file, `0.9.0` and `0.9.0-rc1` can never be
confused for one another — they are simply different paths. That used to take
careful whole-version field matching inside one shared file; now it is free.

## This is not `drill/RUNS.md`

Two different artifacts, and the distinction is load-bearing:

| | what it is |
|---|---|
| [`drill/RUNS.md`](../drill/RUNS.md) | the **harness's own history** — every run of `drill/drill.sh`, the traps table, the lore about what broke and why. It is not release-scoped and it is not going anywhere. |
| `drills/<version>.md` | **release evidence** — the record that *this version* was drilled before it shipped. Release-scoped, one file, gated by CI. |

Appending to `drill/RUNS.md` does not satisfy the release gate, and is not
meant to. Keep using it for what it has always been for.

## What a record should contain

- **What ran** — which drill, how many probes, `drill/drill.sh` invocation.
- **On what host** — the machine, the OS, the Incus version. "Real hardware"
  is the claim; name the hardware.
- **The pinned candidate refs** — the exact `BOX_REF` / `RIG_REF` /
  `CAST_REF` under test, and the other repos' commit SHAs. A drill that does
  not say what it drilled proves nothing later.
- **The shared run ID**, so this record reconciles with the sibling repos'.
- **The numbers** — passed, failed, how long it took.
- **What failed**, plainly.

**A failed drill is still a valid record.** The gate wants *evidence*, not
success. A record saying "83/85, criterion (m) regressed, here is the issue"
is a good record. So is a maintainer's written waiver explaining why this
release shipped without a full drill. What the gate refuses is silence — #95,
#114 and #148 all shipped unproven because a skip left no trace.

## Worked example

The version below is a **placeholder that can never be a real release**.
Copy the shape, not the number.

```markdown
# Release drill — 9.9.9

- **Run ID:** `drill-9.9.9-20260721-01` (shared with rig, cast)
- **Host:** bare Debian 13, Ryzen 7 5800X / 64 GB, Incus 6.0.2
- **Date:** 2026-07-21
- **Candidate refs:**
  - box `release/9.9.9` @ `abc1234`
  - rig `release/4.4.4` @ `def5678` (minted with `RIG_REF=release/4.4.4`)
  - cast `release/2.2.2` @ `9abcdef`

## What ran

`bash drill/drill.sh --ref release/9.9.9` — the full end-to-end: install the
stack, mint every template cold, snapshot and restore, uninstall to zero
residue. Then `drill/multiuser.sh` for the two-user grant matrix.

## Result

**84/85 passed, 1 failed.** 41 minutes wall clock.

- Failed: `multiuser.sh` criterion (m) — the raw instance kept a stale route
  after teardown. Filed as #999. Judged not release-blocking: it affects
  teardown residue on a host that is about to be wiped, not the trust
  boundary itself.
- The VM boundary probes (the 85-probe isolation contract) passed clean,
  which is the assertion this repo's drill exists to make.
```
