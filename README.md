# FSLogix Profile Manager (Horizon IC) – v0.7.0

A WinForms-based PowerShell GUI tool for managing FSLogix user profile containers in VMware Horizon Instant Clones environments. It provides a safe way to retire/reset user profiles by renaming containers rather than deleting them.

Containers are stored under UNC paths like:

```text
\\fml-fslogix\FSLogixUserProfiles
    username_S-1-5-21-XXXXXXXXX-XXXXXXXXX-XXXXXXXXX-XXXXX\*.vhdx
```

Multiple semicolon-separated paths are supported for Cloud Cache setups. Each `username_S-1-5-21-...` folder is treated as a single user profile root, and all `*.vhd` / `*.vhdx` containers beneath it are discovered and aggregated.

---

## Core Features

- Enumerates all `*.vhd` / `*.vhdx` FSLogix containers under one or more root shares.
- Derives usernames and SIDs from folder names with pattern `username_S-1-5-21-...`.
- Aggregates multiple containers (Profile, ODFC/Office, extra SIDs) into a single row per user.
- Displays per-user: Username, Container count, Profile size (GB), Office/ODFC size (GB), Total size (GB), Used GB, Max GB, Last write time, SIDs, Status, Root folder.
- **Column sorting** – click headers to sort; click again to reverse.
- **CSV export** – export the current filtered view to CSV.
- **Filtering:**
  - Filter by username (substring match).
  - Filter by "Last used > X days".
  - Show only profiles with issues (Issues Only filter).
- **Reset Profile modes:**
  - **WhatIf (simulate)** mode (on by default).
  - **Only ODFC (Office) containers** mode.
  - **Only Profile containers** mode.
  - Reset all containers (Profile + Office) when both toggles are off.
- **Rename preview** – modal dialog shows exactly what will happen before any rename.
- **Open-handle detection** – "Skip in-use" checkbox (on by default) detects mounted VHDs before renaming.
- **Health monitoring:**
  - Status column: OK, CORRUPT, ORPHAN, NEAR_LIMIT, EMPTY, RETIRED.
  - Disk space monitoring with Used GB / Max GB columns.
  - Orphan detection via ADSI (no AD module needed).
  - Color-coded rows with legend.
- **Theming** – Light/Dark mode toggle.
- **Embedded log panel** – resizable panel showing real-time activity.
- **Row highlighting** – configurable threshold for Total GB highlighting.
- **Logging** – per-user log files in `%TEMP%` (pattern: `FSLogix_Rename_username_YYYYMMDDHHMMSS.log`).

---

## Rename (Retire) Behavior

- The tool **does not delete** containers.
- Instead, it renames them by appending `-old` before the extension:
  - `Profile_username_SID.vhdx` → `Profile_username_SID-old.vhdx`
  - `ODFC_username_SID.vhd` → `ODFC_username_SID-old.vhd`
- When **WhatIf (simulate)** is enabled, no rename occurs; logs record `WHATIF: Would rename <oldPath> -> <newPath>`.

---

## Requirements

- Windows OS with PowerShell 5.1+.
- .NET Windows Forms assemblies (standard on typical Windows installations).
- Access to your FSLogix profile share (e.g. `\\fml-fslogix\FSLogixUserProfiles`).
- Launch PowerShell in **STA** mode when running the GUI.

---

## Getting Started

1. Copy the scripts to a machine that has network access to your FSLogix share.

2. Open an elevated PowerShell session (optional but recommended for rename/reset operations).

3. Run the GUI in STA mode:

   ```powershell
   powershell.exe -STA -ExecutionPolicy Bypass -File .\FSLogixProfileGUI.ps1
   ```

4. In the GUI:
   - Verify the **Profile Root** path (defaults to `\\fml-fslogix\FSLogixUserProfiles`).
   - Click **Load Profiles**.
   - Use **Filter (user)** and **Last used > X days** as needed.
   - Leave **WhatIf (simulate)** checked during initial testing.

---

## Resetting (Renaming) Profiles Safely

### WhatIf Mode

- When **WhatIf (simulate)** is checked:
  - The tool does not rename any files.
  - Instead, it logs what **would** have been renamed.
  - Check `FSLogix_Rename_*.log` files in `%TEMP%` to review the plan.

### Reset ODFC (Office) only

- Check **Only ODFC (Office) containers** to target only files matching `*odfc*` or `*office*`.

### Reset main Profile only

- Check **Only Profile containers** to target only non-ODFC containers.

### Reset all containers

- Leave both checkboxes unchecked to rename all containers for the selected users.

Always test with WhatIf enabled first.

---

## Row Highlighting

- Turn on **Highlight >** to enable row highlighting.
- Set the **GB** numeric value for the threshold (e.g., `20`).
- Any user whose **Total GB >= threshold** will be highlighted with a distinct background color.
- Uncheck **Highlight >** to disable highlighting entirely.

---

## Known Assumptions / Limitations

- Username detection is tailored to folder names of the form `username_S-1-5-21-...`. Adjust `Get-FSLogixProfiles` for different naming schemes.
- The tool assumes all relevant FSLogix containers are `.vhd` or `.vhdx`.
- Open-handle detection may have false negatives on network shares.

---

## FSLogix Reset Profile CLI (Add-on)

A command-line companion tool (`FSLogixResetProfile.ps1`) for resetting FSLogix profiles without the GUI. Uses the same scanning, filtering, and rename logic as the GUI tool.

### Supports

- `-User` filter (wildcards allowed, multi-value).
- `-LastUsedDays` filter (by last write time).
- `-OnlyOdfc` (Office-only).
- `-OnlyProfile` (Profile-only).
- `-WhatIf` (simulate; no changes, just logs the plan).
- `-ListOnly` (show targets and exit, no rename).
- `-ProfileRoot` to override the default UNC path.

### Usage Examples

```powershell
# Dry run: show what would be reset for one user (profile only)
.\FSLogixResetProfile.ps1 -User vditest1 -OnlyProfile -WhatIf

# Dry run: all users older than 30 days, all containers
.\FSLogixResetProfile.ps1 -LastUsedDays 30 -WhatIf

# Actually reset ODFC only for all vdi* users
.\FSLogixResetProfile.ps1 -User vdi* -OnlyOdfc

# List targets only (no reset), for double-checking
.\FSLogixResetProfile.ps1 -User vdi* -LastUsedDays 60 -ListOnly

# Reset only the profile VHDX for the user bob (WhatIf first)
.\FSLogixResetProfile.ps1 -User bob -OnlyProfile -WhatIf

# Reset only users who haven't logged in 30 days and only their Office container
.\FSLogixResetProfile.ps1 -LastUsedDays 30 -OnlyOdfc
```

### Notes

- Always start with `-WhatIf` or `-ListOnly` to validate which containers will be affected.
- The script does **not delete** any files; it only renames them with `-old` before the extension.
- You can run this from any admin workstation or server that has access to the FSLogix share.

---

## Version

- **FSLogix Profile Manager (Horizon IC) – v0.7.0**

See `CHANGELOG.txt` for full version history.
