# FSLogix Profile Manager (Horizon IC) – v0.8.0

A WinForms PowerShell GUI and a matching CLI for managing FSLogix user profile
containers in VMware Horizon Instant Clones environments. Retires (renames)
containers rather than deleting them, so a bad reset is reversible from the
Retired dialog.

Containers are stored under UNC paths like:

```text
\\fml-fslogix\FSLogixUserProfiles
    username_S-1-5-21-XXXXXXXXX-XXXXXXXXX-XXXXXXXXX-XXXXX\*.vhdx
```

Multiple semicolon-separated paths are supported for Cloud Cache setups. Each
`username_S-1-5-21-...` folder is treated as a single user profile root, and
all `*.vhd` / `*.vhdx` containers beneath it are discovered and aggregated.

> **v0.8.0 changes**: the GUI and CLI now share a single core module
> (`FSLogixProfileCore.psm1`). The two diverged copies of scan/filter/retire
> logic are gone, and the new features (audit, batch restore, retired
> report, Horizon gate, AD last-logon, move-to-retired) are wired in.

---

## Core Features

- Enumerates all `*.vhd` / `*.vhdx` FSLogix containers under one or more root
  shares.
- Derives usernames and SIDs from folder names for both FlipFlop orders
  (`username_SID` and `SID_username`) and from the filename under the
  `NoProfileContainingFolder` layout.
- Aggregates multiple containers (Profile, ODFC/Office, extra SIDs) into one
  row per user.
- Grid columns: User, # Cont, Size (GB), Max GB, Office GB, Last Write,
  Status, SIDs, AD Last Logon, Root Folder.
- **Column sorting** – click headers; sort glyph persists across
  filter/rescan. Status and SIDs sort by displayed text, not count.
- **CSV export** – full SIDs, respects column reorder, drops the truncated
  `(... +N more)` cell.
- **Filtering:**
  - Filter by username (substring; brackets escape).
  - Filter by "Last used > X days" (on-disk mtime).
  - Filter by "AD last logon > X days" (`lastLogonTimestamp`).
  - Issues-only filter.
- **Reset Profile modes:**
  - **WhatIf (simulate)** – default for the GUI; required for any
    non-WhatIf CLI run via `-WhatIf` or by typing a count.
  - **Only ODFC (Office)** / **Only Profile** checkboxes map to `-Scope
    Office` / `-Scope Profile` in the module.
  - Reset all containers (Profile + Office) when both toggles are off.
  - **Move to retired** (default on): retired files land under
    `<root>\_retired\<user>\<batch-stamp>\` so they stop counting against
    the user's FSRM quota and fall outside the user's ACL scope. Turn off
    to fall back to the legacy in-place rename.
- **Rename preview** – LIVE / SIMULATION banner at the top with operator,
  user count, scope, in-use check status, and Horizon connection state.
  The default action on the preview is Cancel, not Proceed.
- **Reason / Ticket** – required text box for any live run. The reason
  is written to the audit log on every renamed row.
- **In-use detection** – "Skip in-use" is on by default. The tool tries
  `Get-SmbOpenFile` first (names the holder); falls back to a local lock
  probe.
  > Open-handle detection is best-effort. A `ReadWrite` mount on a
  > different file server, a Cloud Cache session, or a long-lived
  > `OpenRead` lease can all show a container as "free" when it isn't.
  > The InUse result is a strong signal; the Free result is a weak one.
- **Health monitoring:**
  - Status column: OK, CORRUPT, BAD_SIGNATURE, ORPHAN, AD_DISABLED,
    NEAR_LIMIT, OVER_LIMIT, EMPTY, HAS_RETIRED, UNPARSED_NAME.
  - Row colouring: corrupt/orphan/near-limit use theme-aware colours
    (dark variants for the Dark theme, not the original hard-coded
    `LightCoral`).
  - Disk space monitoring with Size (GB) / Max GB columns. Max GB is
    blank unless Get-VHD or the registry's `SizeInMBs` is available.
  - Orphan detection via ADSI (no AD module needed). Binds by SID first,
    falls back to an escaped `sAMAccountName` filter.
- **Theming** – Light / Dark mode toggle. Health colours re-theme.
- **Embedded log panel** – resizable; `MaxLength = 0` so it no longer
  silently dies at ~32 KB.
- **Row highlighting** – configurable threshold for Size (GB). Health
  issues win over the size highlight, so a CORRUPT row stays coral even
  under a low threshold.
- **Logging** – per-user log files in `%TEMP%` (pattern:
  `FSLogix_Rename_<user>_<WHATIF|LIVE>_<stamp>.log`).
- **Audit trail** – monthly append-only CSV under the configured root
  (default `%ProgramData%\FSLogixProfileManager\Audit`). If a central
  root was set explicitly via Settings, a failed write aborts the
  operation.
- **Retired dialog** – lists every retired container under the configured
  roots, with an age filter, batch Restore and gated Purge (90-day
  retention floor, refuses a last copy without `-AllowLastCopy`, refuses
  legacy undated `-old` without `-IncludeUndated`).
- **Background scan** – runs in a runspace; the UI shows a marquee
  progress form with a Cancel button. No more "Not Responding".

---

## Requirements

- Windows OS with PowerShell 5.1+.
- .NET Windows Forms assemblies (standard on Windows).
- Access to your FSLogix profile share (e.g.
  `\\fml-fslogix\FSLogixUserProfiles`).
- Launch PowerShell in **STA** mode for the GUI.

---

## Getting Started

1. Copy the scripts to a machine with network access to your FSLogix share.
2. Open an elevated PowerShell session (recommended for rename/reset
   operations).
3. Run the GUI in STA mode:

   ```powershell
   powershell.exe -STA -ExecutionPolicy Bypass -File .\FSLogixProfileGUI.ps1
   ```

4. In the GUI:
   - Verify the **Profile Root** path (defaults to
     `\\fml-fslogix\FSLogixUserProfiles`).
   - Click **Load Profiles**.
   - Use **Filter (user)**, **Older than** and **AD last logon** as
     needed.
   - **WhatIf** is on by default. Type a **Reason / Ticket** before
     unchecking it.
   - Use the **Horizon...** button to connect to a Connection Server
     (optional).
   - Use the **Retired...** button to inspect and restore/purge retired
     containers.
   - Use the **Set...** button to point the audit trail at a central
     share.

---

## Resetting (Renaming) Profiles Safely

### WhatIf Mode

- When **WhatIf** is checked, no files are renamed. The run is logged
  with `[WHATIF] Summary` and no audit row is written.
- Read the per-user log in `%TEMP%` to review the plan.

### Reset ODFC (Office) only

- Check **Only ODFC** to target only the Office container for the
  selected users.

### Reset main Profile only

- Check **Only Profile** to target only the non-ODFC container.

### Reset all containers

- Leave both checkboxes unchecked to rename every container for the
  selected users.

### Live run contract

- A **Reason / Ticket** is required.
- The Reset button reads **Reset Profile - LIVE** in red whenever
  WhatIf is off.
- The preview dialog is non-modal only at the source: the **Proceed**
  button on the preview is not the default, and the confirmation that
  follows it requires the operator to type the container count when the
  selection is large.
- A second full-share freeze never happens after a WhatIf run.
- An audit row is written for every action. A failed write aborts the
  operation when a central audit root was set.

---

## Row Highlighting

- **Highlight >** uses the Size (GB) column. Any user whose Size (GB)
  is at or above the threshold is highlighted with the theme's
  highlight colour.
- **Health wins over size.** A row with `CORRUPT`, `BAD_SIGNATURE`,
  `ORPHAN`, `AD_DISABLED`, `NEAR_LIMIT` or `OVER_LIMIT` is coloured by
  the health tier before the size threshold is checked, and stays that
  colour even when the size highlight is disabled.

---

## FSLogix Reset Profile CLI

The CLI (`FSLogixResetProfile.ps1`) is a thin shell over the same module
the GUI uses. It does not have its own copies of scan/filter/retire
logic.

### Safety contract

- A bare call with no filter is **refused outright**. Specify
  `-User`, `-LastUsedDays`, or an explicit `-All`.
- A live run uses `SupportsShouldProcess`; a `-WhatIf` run is the
  default for any path that ends in a rename.
- In-use checking is on by default. Pass `-CheckInUse:$false` to
  disable (and accept the risk).
- `-Force` allows retiring a row whose identity could not be parsed
  out of the share layout.

### Usage Examples

```powershell
# Dry run for one user.
.\FSLogixResetProfile.ps1 -User vditest1 -WhatIf

# Live: every user whose profile hasn't been touched in 60 days.
.\FSLogixResetProfile.ps1 -LastUsedDays 60

# Multi-root: scan both providers as independent shares.
.\FSLogixResetProfile.ps1 -ProfileRoots '\\fs1\Profiles','\\fs2\Profiles' -User vdi* -WhatIf

# Live: Office containers only for vdi* users, opt out of in-use check.
.\FSLogixResetProfile.ps1 -User 'vdi*' -Scope Office -CheckInUse:$false

# List targets only (no reset), for double-checking.
.\FSLogixResetProfile.ps1 -User vdi* -LastUsedDays 60 -ListOnly
```

### Breaking changes vs the v1 CLI

- The custom `-WhatIf` switch is gone; use the standard one.
- `-OnlyOdfc` and `-OnlyProfile` are gone; use `-Scope Office` /
  `-Scope Profile`.
- A bare call with no filter now exits with an error.

---

## Known Assumptions / Limitations

- Username detection works for folder names of the forms
  `username_SID` and `SID_username`, plus the
  `NoProfileContainingFolder` layout. Adjust the regexes in
  `FSLogixProfileCore.psm1` for other naming schemes.
- The tool assumes relevant FSLogix containers are `.vhd` or `.vhdx`.
- Open-handle detection can have false negatives on network shares.
- AD queries can fail on a host that is not domain-joined; orphan
  detection is then disabled (rows render as `UNKNOWN`).

---

## Version

- **FSLogix Profile Manager (Horizon IC) – v0.8.0**

See `CHANGELOG.md` for the full history. The audit backlog lives in
`BACKLOG.md`.
