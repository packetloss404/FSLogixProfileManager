# FSLogix Profile Manager – Changelog

## Unreleased

Groundwork for v0.8.0. The GUI and CLI now import `FSLogixProfileCore.psm1`; the
duplicated local copies of scan/filter/retire/in-use/AD/health logic are gone.

**Wired into the GUI (`FSLogixProfileGUI.ps1`):**

- LIVE / SIMULATION banner on the preview dialog, with operator, user count,
  scope, in-use check and Horizon status.
- Cancel is now the AcceptButton on the preview; auto-select of row 0 after
  a load is cleared so the empty-selection guard is no longer dead.
- Proportionate confirmation: lists up to 5 users + "+N more", shows the
  container count, defaults to No, and above a threshold requires the
  operator to type the container count.
- Result counts (renamed / in-use / exists / missing / failed / aborted)
  come from the module's structured return and render into the status bar
  and a result dialog.
- The Reset button is red and reads "Reset Profile - LIVE" whenever
  WhatIf is off; restored when WhatIf comes back on. Survives rescan and
  theme changes.
- WhatIf runs no longer trigger a second full-share freeze.
- The scan runs in a background runspace with a Cancel button, draining
  progress through a ConcurrentQueue via a WinForms Timer on the UI
  thread. The UI no longer ghosts during a large share scan.
- Reason / Ticket text box, required for any live run (WhatIf is still
  allowed without one). The reason is written to the audit log on every
  renamed row.
- AD Last Logon column surfaces `lastLogonTimestamp`, with a parallel
  "AD last logon > N days" filter plumbed through `Select-FSLogixProfile
  -ADLastLogonDays`. The on-disk age filter still works the same way.
- Horizon connect dialog (server / user / domain / password / optional
  skip-cert for labs). Connection state surfaces in the preview banner.
- Settings dialog for the audit root, with a "use default" jump back to
  `%ProgramData%` for homelabs. An explicitly-set central path means a
  failed audit write aborts the operation.
- Retired-containers dialog with batch Restore and gated Purge. Last-copy
  rows are tinted; the dialog auto-adds `-AllowLastCopy` and/or
  `-IncludeUndated` only when the selection actually needs them.
- "Move to retired" checkbox (default on): retired files land under
  `<root>\_retired\<user>\<batch-stamp>\` instead of in the user's
  writable directory. They stop counting against the user's FSRM quota
  and fall outside the user's ACL scope.
- Sort glyph persists across filter/rescan; Status and SIDs sort by the
  displayed text, not by item count; the "Used GB" column is renamed
  to "Size (GB)"; the log panel no longer dies at ~32 KB
  (`MaxLength = 0`); the preview form is disposed; CSV exports the full
  SID list and respects the user's column reorder.

**Wired into the CLI (`FSLogixResetProfile.ps1`):**

- `[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]` replaces
  the hand-rolled `-WhatIf`. `-WhatIf` and `-Confirm` work the way
  every other PS advanced function does.
- A bare call with no filter is refused outright. `-User`, `-LastUsedDays`
  or an explicit `-All` is required.
- In-use checking defaults to `$true`. `-CheckInUse:$false` opts out.
- `-OnlyOdfc` and `-OnlyProfile` collapse into `-Scope` (All / Office /
  Profile).
- `-Force` passes through to the module's retire (allow unresolved
  identities).
- Multi-root via `-ProfileRoots` as a parameter set, or `-ProfileRoot`
  that splits on `;`.

**Module (`FSLogixProfileCore.psm1`):**

- `Rename-FSLogixProfileObject` and `Get-FSLogixRetirePlan` now accept a
  `-MoveToRetired` switch that retires into `<root>\_retired\<user>\<stamp>\`.

**Tests:**

- `tests/Test-FSLogixProfileCore.ps1` — 39 checks. Added coverage for
  `Rename-FSLogixProfileObject` under `-WhatIf` and under `-MoveToRetired`.
- `tests/Test-FSLogixResetProfile.ps1` (new) — 13 CLI smoke tests for the
  safety contract: bare-call refusal, `-All` opt-in, `-LastUsedDays`,
  `-User`, `WhatIf` routing through `SupportsShouldProcess`, unknown
  user, help text.

**New: `.gitignore`** — keeps `FSLogix_Rename_*.log` and exported CSVs out
of the repo.

Also: absorbed `FSLogixResetProfile.ps1` into this repo (`5d0d08b`) and
removed leftover DEBUG MAP scaffolding from both scripts (`21ba003`) —
neither was recorded here at the time.

## v0.7.0

Health monitoring update. The tool now catches problems before they bite you.

**VHD health checks** – Scans for corrupt profiles (files with "CORRUPT" in the name), empty/broken containers, and already-retired files. Shows up in the new Status column.

**Disk space monitoring** – Grid now shows "Used GB" vs "Max GB" columns. Profiles approaching their size limit (90%+) get flagged as NEAR_LIMIT and highlighted orange.

**Orphan detection** – Enable "Check AD" before loading to find profiles for users that no longer exist in Active Directory. Uses ADSI queries so no AD module needed. Results cached per session.

**Status column** – New column shows health status: OK, CORRUPT, ORPHAN, NEAR_LIMIT, EMPTY, RETIRED. Color-coded rows make problems obvious.

**Issues only filter** – New checkbox to show only profiles with problems. Useful for cleanup sessions.

**Legend** – Added a color legend in the toolbar so you know what the highlights mean.

Window a bit wider (1200px) to fit everything.

---

## v0.6.0

Big update. Finally got around to the features I've been putting off.

**Multi-root support** – You can now specify multiple profile paths separated by semicolons. Handy for Cloud Cache setups where you've got profiles spread across servers. Results get merged by username.

**SID column** – Grid now shows which SIDs are associated with each user. Hover for the full list if there's more than a couple.

**CSV export** – Export button dumps the current filtered view to CSV.

**Column sorting** – Click headers to sort. Click again to reverse.

**Rename preview** – Before any rename operation, you get a dialog showing exactly what's about to happen. Shows which files are in-use or already have a `-old` version.

**Open-handle detection** – New "Skip in-use" checkbox (on by default). Tries to detect if a VHD is mounted before renaming. Not bulletproof on network shares but better than nothing.

**Theming** – Light/dark mode toggle. The dark theme is easier on the eyes for late-night cleanups.

**Log panel** – Resizable panel at the bottom shows what's happening in real-time. Beats digging through %TEMP% for log files.

**Rescan button** – Refresh the profile list without restarting the tool.

Window is bigger now (1100x800) to fit everything.

---

## v0.5.2 (rev2)  – GitHub/About button & UI polish

- Added a **GitHub/About button** in the top-right corner of the main window:
  - Clicking the button opens: `https://github.com/packetloss404`.
  - The button attempts to render a small embedded GitHub icon.
  - If the icon cannot be loaded (e.g., GDI+/image decode issues), it falls back to a small text label **“GH”** instead of throwing an error.

- Kept the bottom-row alignment and wording from v0.5.2:
  - Bottom controls (status label, ODFC/Profile checkboxes, Reset/Close buttons) arranged on a single horizontal row.
  - Main action button text: **“Reset Profile”**.
  - Confirmation dialog clearly indicates that containers will be renamed to `*-old.vhd(x)`.

---

## v0.5.2  (Profile-only & ODFC-only targeting, “Reset Profile” UI)

- Added a new **“Only Profile containers”** checkbox, alongside:
  - **“Only ODFC (Office) containers”**

- The tool now supports three clear retirement/reset modes:
  1. **ODFC-only**:
     - `Only ODFC (Office) containers` checked.
     - `Only Profile containers` unchecked.
     - Only containers whose filenames match `odfc` or `office` are renamed.
  2. **Profile-only**:
     - `Only Profile containers` checked.
     - `Only ODFC (Office) containers` unchecked.
     - Only non-ODFC containers (typical user profile VHD/VHDX) are renamed.
  3. **All containers**:
     - Both checkboxes unchecked.
     - All containers for the selected users are renamed.

- Ensured the two checkboxes are **mutually exclusive**:
  - Checking one automatically unchecks the other.
  - If both are true at the function level, no action is taken and a warning is logged.

- UI alignment and labeling:
  - Bottom-row controls (status label, ODFC/Profile checkboxes, Reset/Close buttons) are aligned in a single horizontal row for a cleaner look.
  - Main action button text changed from “Retire (rename) selected” to **“Reset Profile”**.
  - Confirmation dialog updated to match the new wording and still clearly indicate that containers will be renamed to `*-old.vhd(x)`.

- Under the hood:
  - `Rename-FSLogixProfileObject` now accepts `-OnlyOdfc` and `-OnlyProfile` switches.
  - Filters the profile’s `ContainerFiles` collection based on these flags.
  - Logs the final container list that will be processed (or skipped).

---

## v0.5.1  (Rename-based “retire” behavior)

- Changed cleanup semantics from **delete** to **rename**:
  - Instead of deleting FSLogix containers, the tool now **renames** them by appending `-old` before the extension.
  - Examples:
    - `Profile_username_SID.vhdx` → `Profile_username_SID-old.vhdx`
    - `ODFC_username_SID.vhd` → `ODFC_username_SID-old.vhd`
  - This provides a safer rollback path and avoids immediate data loss.

- Updated per-user operation:
  - New core function `Rename-FSLogixProfileObject` replaces the delete function.
  - Logs are now written as `FSLogix_Rename_username_YYYYMMDDHHMMSS.log`.

- Updated UI labels:
  - Bottom action button text changed to “Retire (rename) selected”.
  - Checkbox text for Office-only mode changed to “Only ODFC (Office) containers”.
  - Confirmation dialog explicitly states files will be renamed to `*-old.vhd(x)`.

- WhatIf behavior:
  - When **WhatIf (simulate)** is enabled, the tool logs what would be renamed without making changes.
  - Log entries use messages like:
    - `WHATIF: Would rename <oldPath> -> <newPath>`.

---

## v0.5  (FSLogix Horizon IC-focused build)

- Added **versioning**:
  - Script-level `$appVersion` variable set to `0.5`.
  - Version string displayed in the window title.
  - Version label displayed on the top row.

- Stabilized discovery logic for environments using folder naming:
  - `username_S-1-5-21-XXXXXXXXX-XXXXXXXXX-XXXXXXXXX-XXXXX`
- Enumerates all `*.vhd` / `*.vhdx` containers under the profile root and groups them by username.
- Shows per-user aggregates:
  - Container count
  - Profile size (GB)
  - Office/ODFC size (GB)
  - Total size (GB)
  - Last write time
  - Root folder

- Added **Delete only ODFC** mode (now evolved to Office-only rename/reset mode).
- Maintained **WhatIf (simulate)** mode:
  - On by default.
  - Log files record what would be done instead of actually performing actions when enabled.

- Implemented **row highlighting**:
  - **Highlight > X GB** controls:
    - Checkbox to enable/disable highlighting.
    - Numeric threshold in GB.
  - Rows where `TotalSizeGB >= threshold` are highlighted (MistyRose background).

- Manual DataGridView population:
  - Grid is populated row-by-row using stored profile objects in `Row.Tag`.
  - Avoids data-binding quirks and ensures reliable display even with complex objects.

- UI layout refinements:
  - Controls placed on two clean top rows:
    - Row 1: Profile Root, Load Profiles, version label.
    - Row 2: Filter, Last used > X days, WhatIf (simulate), Highlight > X GB.
  - NumericUpDown controls positioned to avoid clipping by the form edge.
  - Bottom row: Status, container targeting toggles, main action button, Close.

---

## Maybe someday

(These belong in `BACKLOG.md` now — moved to the "Not doing" section
there. Kept here only as a pointer.)

---

# FSLogix Reset Profile CLI – Changelog

## v1

- Created the first **CLI-only** version of the FSLogix profile reset tool, extracted from the GUI-based Horizon IC utility.
- Implemented scanning of an FSLogix profile root (default: `\\fml-fslogix\FSLogixUserProfiles`) for `*.vhd` / `*.vhdx` containers.
- Implemented username detection based on folder naming pattern:
  - `username_S-1-5-21-XXXXXXXXX-XXXXXXXXX-XXXXXXXXX-XXXXX`
- Aggregated multiple containers per user into a single profile object:
  - Tracks container count, Profile size (GB), Office/ODFC size (GB), total size (GB), last write time, root folder, and container file paths.
- Added support for flexible targeting and filtering:
  - `-User` parameter (supports wildcards and multiple values).
  - `-LastUsedDays` parameter to filter by last write time (e.g., only profiles not touched in 30+ days).
  - `-OnlyOdfc` switch to restrict operations to Office/ODFC containers (filenames matching `odfc` or `office`).
  - `-OnlyProfile` switch to restrict operations to non-ODFC containers (main profile disks).
  - `-ListOnly` switch to list matched profiles without performing any rename operations.
- Implemented safe **rename-based** reset behavior:
  - All operations rename container files from `Name.vhd(x)` to `Name-old.vhd(x)` rather than deleting them.
  - Ensures a rollback path and avoids immediate data loss.
- Added per-user logging:
  - Each operation writes to `%TEMP%` using the pattern:
    - `FSLogix_Rename_<username>_<YYYYMMDDHHMMSS>.log`
  - Logs include:
    - Selected mode (WhatIf, OnlyODFC, OnlyProfile).
    - Number of containers discovered and filtered.
    - Per-file actions (WHATIF messages or actual rename results).
- Added `-WhatIf` support:
  - When present, no files are renamed.
  - Logs record `WHATIF: Would rename <oldPath> -> <newPath>` entries for review.
- Implemented safety checks:
  - Prevents use of `-OnlyOdfc` and `-OnlyProfile` at the same time (exits with an error).
  - Skips rename if the `*-old.vhd(x)` target file already exists.
  - Handles missing original files gracefully (logging and continue).
- Added console output summary:
  - Shows matched user profiles (username, container count, total size, last write time) before performing any changes.
  - Echoes current settings: ProfileRoot, User filter, LastUsedDays, OnlyOdfc, OnlyProfile, WhatIf, and ListOnly.
