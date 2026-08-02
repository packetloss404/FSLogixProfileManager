# Backlog

Roughly ordered. Phase 0 and the Phase 1 core logic have landed in
`FSLogixProfileCore.psm1`; nothing imports it yet, so the shipped behaviour of
`FSLogixProfileGUI.ps1` and `FSLogixResetProfile.ps1` is still v0.7.0.

---

## Where this came from

A four-specialist review on 2026-08-02 (PowerShell/WinForms, FSLogix domain,
Horizon/VDI ops, UX + docs) went over both scripts. It superseded the two
low-priority items previously tracked here, both of which are now folded into
Phase 0 and Phase 3 below.

The headline: the safety story the README tells — "rename, never delete",
"WhatIf by default", "skip in-use" — does not survive contact with a real
environment. Seven findings are data-loss class.

Owner decision (2026-08-02): do all of it, Phases 0–5, including all four
behaviour-breaking changes. Execution runs as a `/loop` over the phases below.

---

## Phase 0 — shared module  ✅ landed, not yet wired up

`FSLogixProfileCore.psm1` now holds the scan / classify / filter / retire /
restore / purge core, with no WinForms dependency (so it is safe to import into
a background runspace).

This had to come first: findings 1–7 below each need fixing in two diverged
copies otherwise. Skipping it is exactly how the CLI ended up with no in-use
check at all.

`tests/Test-FSLogixProfileCore.ps1` covers the pure logic and a synthetic share
— 30 checks, no AD / Hyper-V / Horizon / network needed.

---

## Phase 1 — data-loss class

- [x] **Retired containers are re-scanned and re-renamed; a second reset skips
      the live container.** `-Filter *.vhd*` matched `*-old.vhdx`, which landed
      in `ContainerFiles`, which is what the rename loop targets. Second reset:
      the live container's `-old` target already exists → skipped; the *backup*
      renames to `-old-old`. Log said "Renamed", dialog said "Completed", user
      logged back into the same broken profile. Retired containers are now held
      in a separate `RetiredContainers` set and are never retire targets.
- [x] **`*.vhd*` is a prefix match, so Cloud Cache sidecars were treated as
      containers and renamed.** `.vhdx.meta`, `.vhdx.metadata`, `.vhdx.lock` were
      counted, flagged `EMPTY`, and renamed to `<name>.vhdx-old.meta`. Now
      post-filtered on real extension, with a count of what was ignored.
- [x] **Timestamped retire suffix** — `-old-yyyyMMdd-HHmmss`. Fixes the collision
      chain, groups a batch, and gives a retirement date (`Rename-Item` preserves
      `LastWriteTime`, so there was previously no way to know when anything was
      retired). *Breaking: legacy plain `-old` files still read fine but are
      treated as date-unknown by the purge path.*
- [x] **Only the `username_SID` folder order was parsed — FSLogix's default is
      SID-first.** With `FlipFlopProfileDirectoryName` unset, nothing matched,
      identity fell through to the folder leaf, and the AD check then flagged
      *every* profile in the estate `ORPHAN`. "Issues only" → Ctrl+A → Reset.
      Both orders now parse, plus `NoProfileContainingFolder` via the filename.
- [x] **Unparseable layouts collapsed many users into one row.** The fallback
      keyed on the folder *leaf*, so a flat share became a single row whose
      `ContainerFiles` spanned the estate. Unresolved rows now key on their
      directory, carry `UNPARSED_NAME`, and are refused by the retire path
      unless `-Force`.
- [x] **`-OnlyProfile` / `-OnlyOdfc` were inverted on dedicated Office shares.**
      Discovery classified on the filename but the retire and preview paths
      matched `odfc|office` against the *full path* — under `\\fs\...\ODFC\`
      everything matched. `O365_*.vhdx` was also misclassified as a profile
      container, so `-OnlyProfile` destroyed the user's Outlook container, and
      `officeadmin`'s profile container was treated as Office. Classification is
      now a positive prefix match on the filename, computed once at discovery and
      stored per container; `Unknown` is excluded from both scoped modes.
- [x] **Orphan detection used sAMAccountName, not the SID already parsed.**
      Folder names are a snapshot from container-creation time, so any renamed or
      trusted-domain user was flagged ORPHAN and offered for bulk retirement
      while actively in use. Now binds `LDAP://<SID=...>` first, falls back to an
      escaped sAMAccountName filter, and returns last-logon and disabled state.
- [x] **A share with exactly one user broke both tools.** `return @(...)` still
      unrolls to a scalar on function *output* — the GUI errored, the CLI printed
      "No profiles matched" and exited 0. All collection returns now use `, @()`.
      Regression-tested.
- [ ] **CLI: replace the hand-rolled `-WhatIf` with `SupportsShouldProcess`.**
      Done in the module; the CLI entry point still needs rewriting. The custom
      switch ignores `$WhatIfPreference` and blocks ever adding `CmdletBinding`
      (duplicate parameter name). *Breaking: `-Confirm` and `$WhatIfPreference`
      start working; explicit `-WhatIf` is unaffected.*
- [ ] **CLI: require `-User` / `-LastUsedDays` or an explicit `-All`.** Today a
      bare `.\FSLogixResetProfile.ps1` retires every profile on the share: no
      filter, WhatIf off, no confirmation, and no in-use check anywhere in the
      file. It is the schedulable tool and it is strictly more dangerous than the
      GUI. *Breaking: any scheduled task relying on the bare form.*
- [ ] **CLI: in-use checking on by default.**

## Phase 2 — make the guards real

- [ ] **Preview dialog must show whether the run is live.** It is never passed
      `$whatIf`, its label reads "The following files will be renamed:" either
      way, and — because preview and the confirmation box are an if/else — the
      default-ON preview path is the *only* path that never displays the WhatIf
      flag. Red `LIVE` / grey `SIMULATION` banner, plus operator, user count and
      Horizon check status.
- [ ] **Stop the four-click mass retire.** `FullRowSelect` auto-selects row 0
      after every load, so the `SelectedRows.Count -eq 0` guard is effectively
      dead; the confirmation MessageBox sets no `MessageBoxDefaultButton` so
      **Yes** is focused, and `$btnProceed` is the preview's `AcceptButton`.
      Load → uncheck WhatIf → uncheck Preview → Reset → Enter retires whatever is
      selected; Ctrl+A first and that is everyone.
- [ ] **Proportionate confirmation** — name up to ~5 users plus "+N more", show
      the container count, default to No, and require typing the count above a
      threshold.
- [ ] **Report what actually happened.** `Rename-FSLogixProfileObject` returned
      only a log path and the UI showed "Completed." unconditionally, so a run
      where every rename failed Access Denied was indistinguishable from a clean
      one. The module now returns renamed/skipped/failed/aborted counts — wire
      them into the status bar and the result dialog.
- [ ] **Colour the Reset button when WhatIf is off.** It survives rescan and
      theme changes correctly, but once unchecked there is no visual cue for the
      rest of the session.
- [ ] **Do not rescan after a WhatIf run** — currently unconditional, so every
      dry run costs a second full-share freeze.

## Phase 3 — performance and correctness

- [ ] **Move the scan into a runspace with progress and a Cancel button.** It is
      fully synchronous on the UI thread today: the window ghosts to "Not
      Responding", nothing can be cancelled, no control is disabled, and queued
      clicks dispatch into a freshly repopulated grid the instant it returns.
      The module emits `PROGRESS`-level lines for exactly this.
- [x] **Stop the per-file `Get-VHD` storm.** It was called per container, each
      time re-running `Get-Command Get-VHD` plus a redundant `Get-Item` for a
      `.Length` the caller already had. Now probed once, opt-in via
      `-ReadVhdMetadata`.
- [x] **Blank `Max GB` instead of guessing.** The fallback returned "first of
      30/50/100/120 GB larger than the file", so Max GB exceeded the file size by
      construction and showed 30 for a 130 GB container. `NEAR_LIMIT` now fires
      only against a real ceiling (Get-VHD, or `SizeInMBs` from the registry).
      *Breaking: the column is blank on a workstation without Hyper-V until
      `-ConfiguredMaxSizeGB` is supplied.*
- [x] **Real corruption signal.** `CORRUPT` was a filename match for the string
      "corrupt" — FSLogix never does that; it hands out a temp profile and leaves
      the file where it is. Added a VHD/VHDX footer signature check that works
      without Hyper-V and tolerates a mounted file. (Filename match retained for
      containers an admin marked by hand.)
- [x] **`Test-FileInUse` false positives.** Opened `ReadWrite`/share-`None` and
      treated every exception as in-use, so a read-only operator saw 100% IN USE
      and — with skip-in-use on by default — a reset that did nothing and
      reported success. Now opens for Read, and distinguishes
      Free/InUse/AccessDenied/Missing.
- [x] **`Get-SmbOpenFile` in-use detection.** Authoritative where the lock probe
      guesses, and it names the holding user and client machine. Falls back
      cleanly, and returns `$null` rather than an empty list when it could not be
      queried, so "nobody has it open" is distinguishable from "I don't know".
- [ ] **Log panel silently dies at ~32 KB.** `MaxLength` is never set on
      `$txtLog`, so the multiline default of 32,767 chars applies (~350 lines) and
      `AppendText` no-ops after that. The 500-entry cap trims the backing
      ArrayList, not the control. One line: `$txtLog.MaxLength = 0`.
- [ ] **Theme the health colours.** `LightCoral` / `LightGoldenrodYellow` /
      `PeachPuff` are hardcoded and never themed; against the Dark theme's
      `(220,220,220)` foreground that is ~1.3:1 contrast on exactly the rows that
      matter.
- [ ] **DPI and resize.** `AutoScaleMode='None'` with hardcoded pixel layout
      breaks at 125%+; no `MinimumSize`, so shrinking the window marches the
      buttons over the checkboxes.
- [ ] **Sorting**: `[array]::Reverse` throws on a 0- or 1-row grid (swallowed in
      a WinForms handler); the sort glyph goes stale after filter/rescan;
      Status and SIDs sort by *count*, not by displayed text.
- [ ] **Selection is destroyed on every repaint** — capture and restore it.
- [ ] **Filters do not reapply**: `chkOnlyIssues`, `chkAge` and `numAge` have no
      handlers, and Enter in the filter box does nothing (no `AcceptButton`).
- [ ] **CSV export**: drops `0` values (falsy check), ignores user column
      reordering, and exports the truncated `"...(+N more)"` SID cell.
- [ ] Preview form is never disposed; `Get-InUseContainers` is dead code;
      `$profile` shadows the automatic variable; `Test-Path` without
      `-LiteralPath` throughout; unescaped `-like` means a `[` in the filter box
      silently kills the Apply button.
- [ ] **Rename the "Used GB" column.** It holds on-disk file size, not
      volume-internal used space. `Size (GB)`, with a tooltip.

## Phase 4 — operational features

- [x] **Audit trail** — monthly append-only CSV, one row per file action,
      recording actor, host, mode, reason, target user + SID, source, dest, size,
      result and holder. A failed write aborts the operation when a central root
      was configured explicitly. Logs previously went to `%TEMP%` on the
      operator's own workstation, recorded no operator and no ticket, and a
      WhatIf log was indistinguishable from a live one.
- [x] **Restore** — batch-scoped, signature-checked, session-gated. Displaces any
      existing live container to `-superseded-<stamp>` rather than overwriting, so
      the restore is itself reversible. Zero deletions.
- [x] **Retired-container report and purge** — age, reclaimable size, and a
      `HasLiveSibling` column. Purge has a hard retention floor (default 90 days),
      refuses a last remaining copy without `-AllowLastCopy`, and refuses legacy
      undated `-old` files without `-IncludeUndated`.
- [x] **Optional Horizon session gate** — REST login against the Connection
      Server, session lookup, and logoff (never disconnect: a disconnected session
      keeps the Instant Clone alive and the container mounted). Retire can require
      it; when not configured, callers must say so rather than implying it passed.
- [x] **Read FSLogix policy from the registry** — `VHDLocations`, `CCDLocations`,
      `SizeInMBs`, `FlipFlopProfileDirectoryName`, `NoProfileContainingFolder`,
      `VHDNamePattern`. Configures the tool from the environment instead of
      assuming a layout.
- [x] **Cloud Cache is no longer treated as independent shares.** Replicas were
      double-counted in every size column and retired file-by-file with no
      all-or-nothing semantics — leaving a half-retired set that Cloud Cache
      resyncs back (silently undoing the reset) or diverges. `-CloudCacheMode`
      de-duplicates for reporting; `-AllOrNothing` pre-flights every replica and
      rolls back on mid-flight failure.
- [ ] **Wire all of the above into the GUI**: reason/ticket box (required for live
      runs), Horizon connect dialog, retired-containers dialog with Restore and
      Purge, audit-root setting.
- [ ] **AD last-logon column.** `LastWriteTime` is a poor "unused" signal — an SMB
      lease means an actively mounted container can show a stale timestamp, which
      is precisely what the age filter selects for bulk retirement.
      `lastLogonTimestamp` is already retrieved; surface it and allow filtering
      on it.
- [ ] **Move retired containers out of the user's own ACL scope.** Renaming in
      place leaves the "safe backup" in a directory the end user controls and
      still counts against their FSRM quota. `\\...\_retired\<user>\<stamp>\`,
      operators-only.

## Phase 5 — docs and hygiene

- [ ] **CLAUDE.md**: every line number is stale by 130–200 lines; it says
      `$appVersion` is 0.6.0 (it is 0.7.0) and contradicts its own version
      history; it describes an 8-column grid with "Profile GB" and "Total GB",
      neither of which exists (the grid has 9 columns); nine real functions — the
      entire v0.7.0 health/AD subsystem — are undocumented.
- [ ] **README**: the highlighting section is factually wrong (health colours are
      checked *before* the highlight-disabled early return); control labels do not
      match the UI; it points at a `CHANGELOG.txt` that does not exist; and "the
      same scanning, filtering, and rename logic as the GUI" is untrue of the CLI.
      Rewrite the safety claims so nobody reads open-handle detection as a
      guarantee.
- [x] `.gitignore`.
- [ ] `LICENSE`.
- [ ] Fold CHANGELOG's "Maybe someday" list into this file — a backlog living in
      the changelog.
- [ ] CHANGELOG has no entry for `5d0d08b` (absorbing the CLI) or `21ba003`
      (DEBUG MAP removal), and no `## Unreleased` section.

---

## Not doing

- Container compaction / shrink (`Optimize-VHD`, `Invoke-FslShrinkDisk`). The
  most-requested feature for a tool that already measures size, but it is a
  different risk class from rename-and-restore and deserves its own decision.
- Read-only mount of a retired container to pull a user's files back out.
  Natural follow-on to Restore; not scoped here.
- JEA endpoint for access control. The proportionate answer for a
  small-enterprise deployment (it solves audit and access control together), but
  it is deployment work, not repo work. Until then the share ACL is the control
  and the UI gate would only be convenience — say so in the README.
- Per-folder ACL validation against the owning SID. Catches the most common
  real-world FSLogix support case; worth doing, but after the above.
