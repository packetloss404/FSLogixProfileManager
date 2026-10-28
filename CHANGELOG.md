# FSLogix Profile Manager – Changelog

## Unreleased

### 0.9.0 features

- Saved named environments with explicit Save/update/delete, last-selected startup
  restore, audit/default semantics, Horizon reconnect hints, filters, theme and
  grid layout. Schema validation, atomic concurrent writes and the 4 MB limit
  protect saved files. Applying clears stale state and restores simulation safety;
  no credentials, tokens, TLS bypass, tickets or live choices are captured.
- User details from a toolbar button or row double-click: live files/replicas,
  retired files, scan-labelled AD/health metadata, associated audit events and
  explicit Horizon status. Availability refresh is opt-in and read-only; unknown
  replica metadata stays unknown. Same-name known SIDs remain separate.
- Searchable audit history across monthly CSVs with literal user/ticket/operator,
  exact SID/action and inclusive UTC date filters, sortable results, full records,
  Dark theme and visible source errors. History files are never rewritten.
- Restore, displacement and rollback audit rows now retain each file's identity
  across multi-user batches. Host logging return values are suppressed so they
  cannot contaminate returned profile arrays. Strict retired reports surface
  missing roots and enumeration errors to the details view.
- Added persistence/API, native GUI and cross-feature tests. Portable artifacts
  include required Private/ and UI/ sources and receive a relocated STA smoke
  launch before upload. No deployment was requested or performed.
- Documented workflows and limits in docs/FEATURES.md and docs/VERIFICATION.md.
- Verified 647 assertions across 12 Windows PowerShell 5.1 suites, plus the
  relocated portable app and clear missing-dependency startup failures.

### 0.8.0 development verification (previous snapshot)

October 2026 verification and correctness fixes (development version 0.8.0).

- Added Windows PowerShell 5.1 CI on push/PR, an isolated timeout-bounded test
  runner, real native WinForms tests, CLI subprocess tests, filesystem lifecycle
  tests, and explicitly stubbed service-adapter tests. CI packages a portable
  script artifact only after passing; no deployment is configured or performed.
- Local verification passes 339 checks across core (41), lifecycle (83), native
  GUI (87), CLI (81), and adapter (47) suites. External systems remain unverified.
- Fixed nested-array return handling in scan, health, plan, preview and retired
  paths. Empty and single-user results now behave correctly in both hosts.
- Fixed CLI wildcard matching and real WhatIf planning/logs. Live runs now require
  -Reason, support -AuditRoot, and default to MoveToRetired and AllOrNothing.
  Missing/failed/aborted actions return nonzero. Bare calls are refused before
  root access; unavailable roots and blank filters are rejected.
- Retirement now expands every recorded physical Cloud Cache replica, checks the
  batch before changes, and attempts rollback after failures. Audit intent is
  written before mutation; required audit failure aborts or triggers rollback.
- Managed retirements keep .restore.json original-path metadata. Restore validates
  those relative paths, preflights the selection, preserves replacement live files,
  and attempts batch rollback after failures. Older managed retirements without
  metadata require manual recovery. Superseded containers stay out of live scans.
- Purge revalidates current file type, retired suffix, date, original live sibling,
  and last-copy state rather than trusting report fields. The configurable
  retention floor cannot be lowered below 90 days.
- Fixed GUI CSV display order, sort persistence, selection identity, retired dialog
  headers and batch restore, mutually exclusive scope controls, and scan-cancel
  cleanup. Preview and confirmation retain safe defaults. Connected GUI retirement
  requires the Horizon session gate and uses per-identity all-or-nothing handling.
- Horizon requests restore certificate-validation callbacks after success/failure;
  lab bypass follows the chosen connection. Failed or tokenless reconnects clear
  stale connection state; logoff IDs are URI-escaped.
- Required Horizon checks reject malformed/null inventories and recognize bare,
  domain-qualified and UPN usernames. SMB probes keep server results separate
  and reject mixed-server public requests. GUI/CLI discovery fails closed on
  missing roots and partial enumeration; stale GUI results cannot enable Reset.
- Rewrote README, backlog, agent guidance and handoff to distinguish implemented
  behavior from verified behavior. Removed claims of multi-SID username merging,
  automatic ACL/quota protection, automatic policy/metadata reads, and completed
  production integration validation. See docs/VERIFICATION.md for remaining lab
  checks for AD, SMB, Hyper-V, Horizon and Cloud Cache.

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
