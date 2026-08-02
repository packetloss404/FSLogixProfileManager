# CLAUDE.md

Guidance for AI coding agents working in this repository.

## Project Overview

**FSLogix Profile Manager (Horizon IC)** is a WinForms PowerShell GUI and a
matching CLI for managing FSLogix user profile containers in VMware Horizon
Instant Clones environments. It retires (renames) containers rather than
deleting them, so a bad reset is reversible from the Retired dialog.

### Environment

- FSLogix containers stored under UNC paths (multiple semicolon-separated
  for Cloud Cache).
- Default: `\\fml-fslogix\FSLogixUserProfiles`.
- Folder naming: `username_S-1-5-21-...` (both FlipFlop orders supported,
  plus `NoProfileContainingFolder`).
- Container files: `*.vhd` and `*.vhdx`.

## Running and Testing

### Launch the GUI

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File .\FSLogixProfileGUI.ps1
```

The `-STA` (Single-Threaded Apartment) flag is required for WinForms.

### Launch the CLI

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\FSLogixResetProfile.ps1 -User vditest1 -WhatIf
```

### Run the tests

```powershell
# Module: 39 checks (pure logic + a synthetic share)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FSLogixProfileCore.ps1

# CLI: 13 smoke tests (safety contract: bare-call refusal, WhatIf, etc.)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FSLogixResetProfile.ps1
```

A bare call (no `-User`, no `-LastUsedDays`, no `-All`) is **refused**. The
default mode is `WhatIf`. Both behaviours are part of the safety contract
the CLI tests pin down.

### WhatIf mode

The tool defaults to WhatIf (simulate) in the GUI. The CLI uses standard
`SupportsShouldProcess`, so `-WhatIf` and `-Confirm` work the way every
other PowerShell advanced function does.

Log files go to `%TEMP%` with pattern
`FSLogix_Rename_<user>_<WHATIF|LIVE>_<stamp>.log`, plus the GUI's
embedded log panel in real time.

## Architecture

```
FSLogixProfileCore.psm1   - the only place scan/filter/retire/restore
                            /purge/Audit/Horizon/AD logic lives.
                            WinForms-free. Importable from a runspace.

FSLogixProfileGUI.ps1     - WinForms host. Imports the module. A thin
                            shell over it. -STA required to run.

FSLogixResetProfile.ps1   - CLI host. Imports the module. A thin
                            shell over it. -STA not required.

tests/                    - smoke tests. No AD / Hyper-V / Horizon
                            / network share required.
```

The module is the source of truth. The two entry points only do
presentation. When you change retire behaviour, change the module.

### `FSLogixProfileCore.psm1` — exported functions

Grouped by responsibility.

**Logging and state**

- `Set-FSLogixLogHandler` / `Write-FSLogixLog` — routes module log output
  to a host-supplied scriptblock. `PROGRESS`-level lines are meant for
  a status bar; the rest go to a log buffer.
- `Set-FSLogixAuditRoot` / `Get-FSLogixAuditRoot` / `Write-FSLogixAudit`
  — monthly append-only CSV; `-Critical` aborts on failed write when a
  central root was set explicitly.

**Container naming**

- `Get-FSLogixContainerClass` — `Profile` / `Office` / `Unknown`
  classification, by positive filename prefix.
- `Test-FSLogixRetiredName` / `Test-FSLogixSupersededName` — detection.
- `New-FSLogixBatchStamp` / `Get-FSLogixRetireTargetName` — produce the
  timestamped `<name>-old-<stamp>.<ext>` form.
- `Resolve-FSLogixIdentity` — SID-first / user-first / `NoProfileContainingFolder`
  / Unresolved, with retirement-suffix stripped first.

**In-use detection**

- `Test-FSLogixFileInUse` — local lock probe (Read, FileShare.None).
- `Get-FSLogixOpenHandle` — `Get-SmbOpenFile` via CimSession; names the
  holder. Returns `$null` (not an empty list) when it could not be
  queried, so "nobody has it open" is distinguishable from "I could
  not find out".
- `Get-FSLogixContainerState` — combined Free / InUse / AccessDenied /
  Missing, preferring the SMB open-file list when available.

**VHD inspection**

- `Test-FSLogixVhdSignature` — VHD/VHDX footer signature check that works
  without Hyper-V. `Valid` / `Invalid` / `Unknown`.
- `Get-FSLogixVhdMaxSizeGB` — `Get-VHD`; returns `$null` when the cmdlet
  is not available (deliberate, never guessed).
- `Get-FSLogixSettings` — reads FSLogix policy from a session host's
  registry (local or remote). Returns `$null` when nothing could be
  read.
- `Get-FSLogixContainerHealth` — `EMPTY` / `BAD_SIGNATURE` / `NEAR_LIMIT`
  / `OVER_LIMIT` / `CORRUPT` flags.

**Active Directory**

- `Initialize-FSLogixADCheck` / `Clear-FSLogixADCache` /
  `Get-FSLogixADStatus` — SID-first bind, `lastLogonTimestamp` (handles
  the `IADsLargeInteger` shape), disabled state.
- `Get-FSLogixLdapEscapedValue` — RFC 4515 escaping for filter values.

**Horizon session gate**

- `Connect-FSLogixHorizon` / `Disconnect-FSLogixHorizon` /
  `Test-FSLogixHorizonConnected` / `Get-FSLogixHorizonSession` /
  `Stop-FSLogixHorizonSession` — REST login, session lookup, logoff.
  Endpoint versions move between Horizon 8 releases; check
  `/rest/swagger.yaml` on the build if the inventory path 404s.

**Discovery**

- `Get-FSLogixProfiles` — scans one or more roots, classifies, resolves
  identity, aggregates by user, returns one record per user with a
  `Containers` array and a separate `RetiredContainers` array.
  Always returns an array (use the leading-comma return idiom).
- `Select-FSLogixProfile` — filter by user / age / AD last logon /
  issues / orphans. Wildcard patterns are escaped before the implicit
  `*...*` wrap, so a `[` in the filter box is safe.

**Retire plan and execution**

- `Get-FSLogixRetirePlan` — what would happen, with the in-use probe.
  Both the preview dialog and the retire itself use this.
- `Rename-FSLogixProfileObject` — rename (or, with `-MoveToRetired`,
  move to `<root>\_retired\<user>\<batch-stamp>\`). Returns
  Renamed / SkippedInUse / SkippedExists / Missing / Failed / Aborted.
- `Restore-FSLogixProfileBatch` — reverses a retire. Displaces any
  live sibling to `*-superseded-<stamp>` rather than overwriting.
  Refuses if the displaced live container is currently mounted.

**Retired-container lifecycle**

- `Get-FSLogixRetiredContainer` — report with `DateSource` (`stamp` /
  `mtime-approx`) and `HasLiveSibling`.
- `Remove-FSLogixRetiredContainer` — gated purge. `-RetentionFloorDays`
  is a hard floor; `-AllowLastCopy` is required to purge a last copy;
  `-IncludeUndated` is required for legacy `-old` files.

### `FSLogixProfileGUI.ps1` — layout

The script does five things:

1. Import the module and route its log handler to `Add-LogMessage`
   (PROGRESS goes to `$lblStatus`; everything else goes to `$txtLog`).
2. Build the theme dictionaries and the form (Dark / Light, with
   `HealthCorrupt` / `HealthOrphan` / `HealthNearLimit` so health
   colours re-theme properly).
3. Build the controls: top row (profile root, Load, Rescan, Check AD,
   version, theme, Horizon, Retired, Set, GitHub); filter row
   (user, Apply, Older than, AD last logon, Issues only, WhatIf,
   Skip in-use, Highlight >); reason row (txtReason, required for
   live runs); split container (DataGridView 10 columns + log
   panel); bottom row (status, Only ODFC, Only Profile, Preview,
   Move to retired, Reset Profile, Close).
4. Wire the buttons. The Reset button has `Set-ResetButtonAppearance`
   for the red LIVE state; the scan button kicks off
   `Start-BackgroundScan`, which runs the module in a runspace and
   drains a `ConcurrentQueue` via a WinForms Timer on the UI thread.
5. Define the dialog functions: `Show-ResetConfirmation` (proportionate,
  typed count above threshold), `Show-RenamePreviewDialog` (LIVE banner,
  plan, Cancel as default), `Show-HorizonConnectDialog`,
  `Show-SettingsDialog`, `Show-RetiredDialog` (Restore + Purge).

### `FSLogixResetProfile.ps1` — parameters

- `-ProfileRoot` (default `\\fml-fslogix\FSLogixUserProfiles`) or
  `-ProfileRoots` (parameter set, required, array).
- `-User` (wildcards, multi-value), `-LastUsedDays`, `-All` (at least
  one is required or the script refuses outright).
- `-Scope` (`All` / `Office` / `Profile`).
- `-CheckInUse` (default on), `-Force`, `-ListOnly`.
- Standard `-WhatIf` / `-Confirm` from `[CmdletBinding(SupportsShouldProcess,
  ConfirmImpact='High')]`.

The script reads `Write-Output` for testable lines (summary, matched
count, no-match message) and `Write-Host` for the colored header. The
tests capture `StdOut`, so anything the tests check must be
`Write-Output`.

## Conventions

- **No deletion in the module.** The only function that deletes is
  `Remove-FSLogixRetiredContainer`, and it has a retention floor plus
  a last-copy guard. Anything else uses `Rename-Item` or `Move-Item`.
- **Never guess.** `MaxSizeGB` is `$null` when unknown. `OpenHandles`
  returns `$null` when it could not be queried. Render "unknown",
  not "fine".
- **Collection returns use the leading-comma idiom.** `return , @($x)`.
  This prevents the scalar-unroll bug on a one-element array. **Callers
  must use a direct call (`$r = func`), not `@(func)`.** `@(func)` gives
  a 1-element wrapper, not the real result. The existing tests use
  method-style access (`(func).Count`), which unrolls the wrapper; the
  CLI and GUI use direct call.
- **No WinForms in the module.** The module is importable from a
  background runspace. The GUI owns all WinForms. Use
  `Set-FSLogixLogHandler` if you need to redirect module output
  somewhere other than the console.
- **Audit log is critical for live operations.** When a central root
  was set explicitly, a failed write aborts the operation. A rename
  that cannot be recorded must not happen.
- **Cloud Cache is all-or-nothing by default.** Pass `-AllOrNothing`
  to `Rename-FSLogixProfileObject` to roll back a half-retired replica
  set; otherwise the surviving copy can resync the dead one back.

## Adding to the module

When you add a new public function:

1. Implement it in `FSLogixProfileCore.psm1`.
2. Add it to `Export-ModuleMember -Function ...` at the bottom of the
   file.
3. Add coverage to `tests/Test-FSLogixProfileCore.ps1`. The test file
   uses a synthetic tree under `$env:TEMP`; no AD / Hyper-V / Horizon
   / network share is required.
4. If the function should be wired into the GUI, add a control and a
   handler. Wire the handler so the GUI's own confirmation is used
   (never let the module's `ShouldProcess` prompt fire — pass
   `-Confirm:$false`).

## Adding a CLI parameter

1. Add it to the `param()` block with the right parameter set.
2. The `SupportShouldProcess` is on; standard `-WhatIf` / `-Confirm`
   are auto-generated. Do not add a custom `-WhatIf` switch.
3. The safety contract is enforced at the top of the script: a bare
   call with no filter is refused. Update the contract if you change
   the meaning of `-User` / `-LastUsedDays` / `-All`.
4. Add a smoke test to `tests/Test-FSLogixResetProfile.ps1` that
   exercises the new path.

## Important Constraints

- **PowerShell 5.1+** for both entry points; the module requires 5.1.
- **STA** for the GUI; not for the CLI.
- **Windows only** (uses `System.Windows.Forms`, `Get-SmbOpenFile`,
  `Get-VHD`, ADSI, etc.).
- **No deletion in the module** (see above).
- **In-use detection is best-effort.** A Cloud Cache session or a
  long-lived `OpenRead` lease can fool the local probe. Treat
  `InUse` as a strong signal, `Free` as a weak one.

## Versioning

- v0.7.0 (predecessor) – health monitoring + AD orphan detection.
- v0.8.0 (current) – shared `FSLogixProfileCore.psm1`, all Phase 0–5
  backlog items landed (see `BACKLOG.md`).
