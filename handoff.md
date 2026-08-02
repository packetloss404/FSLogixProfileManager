# Handoff — 2026-08-02

Safe to delete once this work is picked back up.

## State

Working tree is clean and `main` builds/parses. **Shipped behaviour is unchanged
from v0.7.0** — `FSLogixProfileCore.psm1` is new and complete, but neither entry
point imports it yet. Both `.ps1` files are byte-identical to what they were, so
nothing is half-migrated and nothing regressed.

```
FSLogixProfileCore.psm1            NEW  1,752 lines, 35 exported functions
tests/Test-FSLogixProfileCore.ps1  NEW  30 checks, all passing
BACKLOG.md                         REWRITTEN — full audit + phased plan
FSLogixProfileGUI.ps1              untouched (v0.7.0)
FSLogixResetProfile.ps1            untouched (v0.7.0)
```

## What happened this session

A four-specialist review (PowerShell/WinForms, FSLogix domain, Horizon/VDI ops,
UX + docs) went over both scripts. Seven findings are data-loss class. The full
list, with what is fixed and what is not, is in `BACKLOG.md` — that is the
authoritative document, not this file.

Owner approved Phases 0–5 in full, including all four behaviour-breaking changes
(timestamped `-old` suffix, CLI `SupportsShouldProcess`, CLI requires a filter or
`-All`, blank `Max GB` instead of a guessed one).

Phase 0 and the core-logic half of Phases 1/3/4 landed in the module. Everything
still marked `[ ]` in BACKLOG.md is UI wiring, CLI rewrite, or docs.

## Verified vs not

**Verified** — Windows PowerShell 5.1 is reachable from WSL at
`/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe`, so this was
actually run, not just reasoned about:

- All three files parse clean (`[Parser]::ParseFile`).
- `tests/Test-FSLogixProfileCore.ps1` — 30 checks pass. Covers container
  classification, retired-name round-tripping, identity parsing in both
  FlipFlop orders plus `NoProfileContainingFolder`, LDAP escaping, a synthetic
  share (sidecar exclusion, retired/live split, size aggregation, retire plan),
  the single-user-share scalar bug, and the retired-container report.

  ```
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FSLogixProfileCore.ps1
  ```

  It caught a real bug mid-session: `return @(...)` still unrolls a one-element
  array on function *output*. Three functions needed `return , @(...)`. That is
  the same class of bug the review flagged in the original code — worth keeping
  the test green.

**Not verified — no environment for it.** These are written carefully and
reviewed, but have never executed:

- `Get-FSLogixOpenHandle` — needs a real SMB file server and admin rights.
- `Get-FSLogixADStatus` — needs a domain. The `IADsLargeInteger` unwrap for
  `lastLogonTimestamp` is the part most likely to be wrong.
- `Get-FSLogixSettings` — needs an FSLogix host; the remote-registry path needs
  the Remote Registry service, which is off by default on client Windows.
- `Connect-FSLogixHorizon` / `Get-FSLogixHorizonSession` — needs a Connection
  Server. **The REST paths differ between Horizon 8 releases** (`/rest/inventory/v1`
  vs `v2`). Check `https://<cs>/rest/swagger.yaml` on the actual build and pin it
  before trusting the session gate.
- `Get-FSLogixVhdMaxSizeGB` — needs the Hyper-V module.
- The whole Cloud Cache replica path — needs a multi-provider setup.

## Resuming

Run as a `/loop` over the BACKLOG phases, in order — Phase 2, then 3, then the
remaining Phase 1 CLI items, then 4's GUI wiring, then 5. Each phase is a
self-contained commit.

Next concrete step is **task #3, the CLI**, not the GUI: it is the smaller
rewrite, it exercises the module end-to-end, and it is where the worst
remaining live bug is (a bare `.\FSLogixResetProfile.ps1` still retires the
entire share with no filter, no confirmation, no WhatIf and no in-use check).
Get that right and the GUI rewrite has a working reference.

Keep `tests/Test-FSLogixProfileCore.ps1` green as you go, and extend it —
`Rename-FSLogixProfileObject` under `-WhatIf` against the synthetic share is the
obvious next test, and it needs no domain or share.

### Watch out for

- `Rename-FSLogixProfileObject` is `ConfirmImpact='High'`. The CLI should let
  that prompt; **the GUI must pass `-Confirm:$false`** (it has its own
  confirmation, and a console prompt from a WinForms app goes nowhere).
- The module deliberately never guesses. `MaxSizeGB` is `$null` when unknown, and
  `Get-FSLogixOpenHandle` returns `$null` — not an empty array — when it could
  not query. Callers must render "unknown" rather than "fine".
- Nothing in the module touches WinForms, which is what makes the Phase 3
  background-runspace scan possible. Keep it that way. `Set-FSLogixLogHandler`
  is the seam: point it at a `ConcurrentQueue` from the runspace and drain it
  from a UI timer. `PROGRESS`-level lines are meant for a status bar, not the
  log buffer.
- Audit is local-only (`%ProgramData%\FSLogixProfileManager\Audit`) until
  `Set-FSLogixAuditRoot` is called. `-Critical` only aborts when a central root
  was set explicitly — otherwise a homelab with no audit share could not retire
  anything.
