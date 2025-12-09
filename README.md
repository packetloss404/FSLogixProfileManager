# FSLogix Profile Manager (Horizon IC) – v0.5.2 (rev2)

This is a WinForms-based PowerShell tool for managing FSLogix user profile containers in a Horizon Instant Clones environment.

It is designed around environments where FSLogix containers are stored under a UNC path like:

```text
\\fml-fslogix\FSLogixUserProfiles
    username_S-1-5-21-XXXXXXXXX-XXXXXXXXX-XXXXXXXXX-XXXXX\*.vhdx
```

Each `username_S-1-5-21-...` folder is treated as a single “user profile root”, and all `*.vhd` / `*.vhdx` containers beneath that root are discovered and aggregated.

---

## v0.5.2 (rev2) Summary

**Granular targeting for “reset profile” operations:**

- Two mutually exclusive checkboxes determine which containers are affected:
  - **Only ODFC (Office) containers**
  - **Only Profile containers**

You now have three clear modes:

1. **ODFC-only**  
   - `Only ODFC (Office) containers` checked  
   - `Only Profile containers` unchecked  
   - ➜ Only containers whose filenames match `odfc` or `office` are renamed.

2. **Profile-only**  
   - `Only Profile containers` checked  
   - `Only ODFC (Office) containers` unchecked  
   - ➜ Only non-ODFC containers (typically the main FSLogix profile VHD/VHDX files) are renamed.

3. **All containers**  
   - Both checkboxes unchecked  
   - ➜ All containers for the selected users are renamed (both Profile and Office).

If both checkboxes are somehow set at the function level, the logic logs a warning and performs no action.

**Reset Profile action:**

- The primary action button is labeled **“Reset Profile”**.
- Clicking it triggers the “retire/rename” flow for the selected users, according to the selected mode and WhatIf setting.

**GitHub / About button:**

- A small button in the **top-right corner** of the window opens your GitHub profile:
  - `https://github.com/packetloss404`
- The button attempts to show a small GitHub icon; if the icon cannot be loaded for any reason, it falls back to a simple **“GH”** text label.
- This provides a quick “About/Source” entry point without cluttering the main UI.

---

## Rename (Retire) Behavior

- The tool **does not delete** containers.
- Instead, it renames them by appending `-old` before the extension, for example:

  - `Profile_username_SID.vhdx` → `Profile_username_SID-old.vhdx`
  - `ODFC_username_SID.vhd` → `ODFC_username_SID-old.vhd`

- Logs are written to `%TEMP%` using the pattern:
  - `FSLogix_Rename_username_YYYYMMDDHHMMSS.log`
- When **WhatIf (simulate)** is enabled:
  - No rename occurs; logs record `WHATIF: Would rename <oldPath> -> <newPath>`.

---

## Core Features

- Enumerates all `*.vhd` / `*.vhdx` FSLogix containers under a root share.
- Derives usernames from folder names with pattern:
  - `username_S-1-5-21-...`
- Aggregates multiple containers (Profile, ODFC/Office, extra SIDs) into a single row per user.
- Displays:
  - Username
  - Container count
  - Profile size (GB)
  - Office/ODFC size (GB)
  - Total size (GB)
  - Last write time
  - Root folder
- Filtering:
  - Filter by username (substring match).
  - Filter by “Last used > X days”.
- “Reset Profile” options:
  - **WhatIf (simulate)** mode (default).
  - **Only ODFC (Office) containers** mode.
  - **Only Profile containers** mode.
  - Reset all containers (Profile + Office) when both toggles are off.
- Logging:
  - Per-user log file in `%TEMP%`, e.g.
    - `FSLogix_Rename_username_YYYYMMDDHHMMSS.log`
- Visual enhancements:
  - Optional row highlighting for profiles where **Total GB >= threshold**.
  - Threshold is configurable (e.g., highlight > 20 GB).
  - Highlighting can be toggled on/off.

---

## Requirements

- Windows OS with PowerShell 5.1+ (or compatible PowerShell with WinForms support).
- .NET Windows Forms assemblies (standard on typical Windows desktop/server installations).
- Access to your FSLogix profile share (e.g. `\\fml-fslogix\FSLogixUserProfiles`).
- Launch PowerShell in **STA** mode when running the GUI.

---

## Getting Started

1. Copy the script to a machine that has network access to your FSLogix share.

2. Open an elevated PowerShell session (optional but recommended for rename/reset operations).

3. Run the script in STA mode:

   ```powershell
   powershell.exe -STA -ExecutionPolicy Bypass -File .\FSLogixProfileGUI-v0.5.2.ps1
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

- When **Only ODFC (Office) containers** is checked:
  - The tool will only target container files whose names match:
    - `*odfc*` or `*office*`

### Reset main Profile only

- When **Only Profile containers** is checked:
  - The tool will only target container files whose names **do not** match:
    - `*odfc*` or `*office*`
  - This typically means only the main FSLogix user profile containers are retired/reset.

### Reset all containers

- When **both** checkboxes are unchecked:
  - All containers belonging to the selected user rows are eligible for renaming (subject to WhatIf).
  - This includes both profile and Office/ODFC containers.

Always test with WhatIf enabled first.

---

## Row Highlighting

- Turn on **Highlight >** to enable row highlighting.
- Set the **GB** numeric value for the threshold (e.g., `20`).
- Any user whose **Total GB >= threshold** will be highlighted with a distinct background color.
- Uncheck **Highlight >** to disable highlighting entirely.

---

## Known Assumptions / Limitations

- Username detection is tailored to folder names of the form:
  - `username_S-1-5-21-...`
- If your FSLogix folder layout uses a different naming scheme, you may need to adjust the `Get-FSLogixProfiles` logic.
- The tool assumes all relevant FSLogix containers are `.vhd` or `.vhdx`.
- This version does not yet:
  - Show per-folder SID keys in the grid.
  - Export grid data to CSV.
  - Check for open file handles/locks.
  - Support multiple FSLogix roots (Cloud Cache secondary paths) in a single run.
  - Provide UI theming or a built-in log viewer panel.

These are planned for the v0.6+ roadmap.

---

## Version

- **FSLogix Profile Manager (Horizon IC) – v0.5.2 (rev2)**

See `CHANGELOG.txt` for full version history and planned roadmap notes.
