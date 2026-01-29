# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**FSLogix Profile Manager (Horizon IC)** is a WinForms-based PowerShell GUI tool for managing FSLogix user profile containers in VMware Horizon Instant Clones environments. It provides a safe way to retire/reset user profiles by renaming containers rather than deleting them.

### Environment Assumptions

- FSLogix containers stored under UNC paths (supports multiple semicolon-separated paths for Cloud Cache)
- Default: `\\fml-fslogix\FSLogixUserProfiles`
- Folder naming pattern: `username_S-1-5-21-XXXXXXXXX-XXXXXXXXX-XXXXXXXXX-XXXXX`
- Container files: `*.vhd` and `*.vhdx` files

## Running and Testing

### Launch the Application

```powershell
powershell.exe -STA -ExecutionPolicy Bypass -File .\FSLogixProfileGUI.ps1
```

**Important:** The `-STA` (Single-Threaded Apartment) flag is **required** for WinForms to function properly.

### Testing with WhatIf Mode

The tool defaults to WhatIf mode (simulate) which is **enabled by default**. This logs what would happen without making actual changes. Always test with WhatIf first.

Log files are written to:
- `%TEMP%` with pattern: `FSLogix_Rename_username_YYYYMMDDHHMMSS.log`
- Embedded log panel in the UI (real-time)

## Architecture

### Core Functions

1. **`Get-FSLogixProfiles`** (lines 132-238)
   - Accepts array of profile roots (supports multi-root/Cloud Cache)
   - Recursively scans each root for `*.vhd/*.vhdx` files
   - Extracts usernames AND SIDs from folder names using regex: `^(?<user>.+?)_(?<sid>S-1-5-21-[\d-]+)`
   - Aggregates multiple containers per user across all roots
   - Returns custom objects with: UserName, ContainerCount, ProfileSizeGB, OfficeSizeGB, TotalSizeGB, LastWriteTime, RootFolder, ContainerFiles array, SIDs (HashSet), ProfileRoots (HashSet)
   - Classification: Files matching `odfc|office` are Office containers, others are Profile containers

2. **`Rename-FSLogixProfileObject`** (lines 243-338)
   - Core rename/retire operation with per-user logging
   - Supports modes via switches: `-OnlyOdfc`, `-OnlyProfile`, `-CheckInUse`
   - Open-handle detection: skips in-use files when `-CheckInUse` is true
   - Renames containers by appending `-old` before extension
   - WhatIf support: logs `WHATIF: Would rename...` without actual changes
   - Logs to both file and embedded UI log panel
   - Returns log file path

3. **`Apply-Filters`** (lines 343-367)
   - Filters profile list by username substring match
   - Optional age filter: LastWriteTime < (Now - AgeDays)
   - Returns filtered array

4. **`Update-RowHighlight`** (lines 372-400)
   - Highlights DataGridView rows where TotalSizeGB >= threshold
   - Theme-aware: uses MistyRose for light theme, dark red for dark theme

5. **`Export-GridToCSV`** (lines 405-433)
   - Exports current grid contents to CSV file
   - Proper escaping for CSV format

6. **`Show-RenamePreviewDialog`** (lines 438-544)
   - Modal dialog showing all files to be renamed
   - Columns: User, Current Path, New Path, Status
   - Color-coded status: OK (white), IN USE (red), EXISTS/MISSING (yellow)
   - Returns DialogResult (OK to proceed, Cancel to abort)

7. **`Apply-Theme`** (lines 549-629)
   - Applies Light or Dark theme to all UI controls
   - Recursively updates form, grid, buttons, text boxes, log panel
   - Updates highlight colors per theme

8. **`Test-FileInUse`** (lines 100-115)
   - Attempts exclusive file open to detect if VHD/VHDX is mounted
   - Returns $true if file is locked, $false if available

9. **`Add-LogMessage`** (lines 72-95)
   - Adds timestamped message to embedded log panel
   - Supports log levels: INFO, WARN, ERROR
   - Maintains rolling buffer of 500 messages

### UI Structure

The WinForms UI is built using `System.Windows.Forms` and `System.Drawing`:

- **Row 1** (top): Profile Root textbox (multi-root hint below), Load/Rescan buttons, version label, Theme dropdown, GitHub button
- **Row 2**: User filter, age filter controls, WhatIf checkbox, Skip in-use checkbox, highlight controls, Export CSV button
- **SplitContainer** (main area):
  - **Panel 1**: DataGridView with 8 columns (User, # Cont, Profile GB, Office GB, Total GB, Last Write, SIDs, Root Folder)
  - **Panel 2**: Embedded log panel with Clear button
- **Bottom row**: Status label, ODFC-only/Profile-only checkboxes, Preview checkbox, Reset Profile button, Close button

### Key Design Patterns

- **Manual DataGridView population**: Rows added explicitly, with profile objects stored in `Row.Tag` (not data-binding)
- **Column sorting**: Click headers to sort; uses `ColumnHeaderMouseClick` event with programmatic sorting
- **Mutual exclusivity**: ODFC-only and Profile-only checkboxes use CheckedChanged events
- **Theme system**: Theme definitions in `$script:Themes` hashtable; `Apply-Theme` function recurses through controls
- **Preview workflow**: `Show-RenamePreviewDialog` returns DialogResult before any rename operation
- **Safety-first**: WhatIf ON by default, Skip in-use ON by default, Preview ON by default, rename instead of delete

### Global Script Variables

- `$script:AllProfiles`: Holds all loaded profile objects (before filtering)
- `$script:DefaultRowBackColor`: Current theme's grid background color
- `$script:CurrentHighlightColor`: Current theme's highlight color
- `$script:Themes`: Hashtable of Light/Dark theme definitions
- `$script:CurrentTheme`: "Light" or "Dark"
- `$script:LogMessages`: ArrayList of log entries for embedded panel
- `$script:txtLog`: Reference to log TextBox control
- `$script:SortColumn`: Currently sorted column index (-1 if none)
- `$script:SortAscending`: Sort direction boolean
- `$appVersion`: Version string (0.6.0)

## Common Development Tasks

### Modifying Username Detection Logic

Edit the regex patterns in `Get-FSLogixProfiles` (lines 163-175):
- Primary pattern: `'^(?<user>.+?)_(?<sid>S-1-5-21-[\d-]+)'`
- Captures both username and SID groups
- Fallback checks both folder name and file basename

### Adding New Grid Columns

1. Use `Add-Col` helper function (line 851-857) to add column definition
2. Update `Show-ProfilesInGrid` to populate the new column cells
3. Update column sorting switch statement in `ColumnHeaderMouseClick` handler
4. Update `Export-GridToCSV` if column needs special handling

### Changing Container Classification

ODFC/Office detection uses regex `'odfc|office'` (lines 217, 277, 282, 477-481). Modify this pattern to adjust classification logic.

### Extending Rename Behavior

The rename logic is in `Rename-FSLogixProfileObject`. Current pattern: `"{0}-old{1}" -f $base, $ext` (line 312). Modify to change naming scheme.

### Adding New Themes

Add new theme definition to `$script:Themes` hashtable (lines 31-63). Required properties:
- FormBackColor, FormForeColor
- GridBackColor, GridForeColor, GridHeaderBackColor, GridHeaderForeColor, GridAlternateRowColor
- HighlightColor
- ButtonBackColor, ButtonForeColor
- TextBoxBackColor, TextBoxForeColor
- LogPanelBackColor, LogPanelForeColor

Then add the theme name to `$cmbTheme.Items` (lines 692-693).

## Important Constraints and Behaviors

- **No deletion**: Tool never deletes files, only renames them
- **Open-handle detection**: Enabled by default; uses file lock test (may have false negatives for network shares)
- **Multi-root support**: Semicolon-separated paths; results merged by username
- **PowerShell 5.1+ required**: Uses .NET Framework WinForms assemblies
- **Network access required**: Must have access to the FSLogix UNC share(s)
- **STA mode required**: WinForms requires Single-Threaded Apartment mode

## Version History

- **v0.7.0**: Health monitoring - VHD health checks, disk space monitoring, orphan detection, status column, issues-only filter, color legend
- **v0.6.0**: Major feature release - SID column, CSV export, column sorting, multi-root support, rename preview, open-handle detection, theming, embedded log panel, rescan button
- **v0.5.2**: Profile-only/ODFC-only targeting, GitHub button
- **v0.5.1**: Rename-based retire behavior (replaced delete)
- **v0.5.0**: Initial FSLogix Horizon IC-focused build

---

## FSLogix Reset Profile CLI (Add-on)

A CLI-only companion tool (`FSLogixResetProfile.ps1`) extracted from the GUI utility. Provides the same profile discovery, filtering, and rename logic without requiring WinForms or STA mode.

### Running the CLI

```powershell
# Always start with -WhatIf to preview changes
.\FSLogixResetProfile.ps1 -User <username> -WhatIf

# Or use -ListOnly to see targets without generating logs
.\FSLogixResetProfile.ps1 -User <username> -ListOnly

# Execute actual reset (removes -WhatIf)
.\FSLogixResetProfile.ps1 -User <username>
```

### CLI Architecture

The script (`FSLogixResetProfile.ps1`) mirrors the GUI's core functions:

1. **Profile Discovery (`Get-FSLogixProfiles`)**: Same recursive scan and user aggregation as the GUI. Parses `username_S-1-5-21-...` folder patterns, builds profile objects with container counts, sizes, and file paths.

2. **Filtering (`Apply-Filters`)**: Applies `-User` (wildcard support, multi-value) and `-LastUsedDays` filters.

3. **Rename Operations (`Rename-FSLogixProfileObject`)**: Same rename-to-`-old` logic. Supports `-OnlyOdfc` and `-OnlyProfile` switches. Generates per-user logs in `%TEMP%`.

### CLI Parameters

- `-ProfileRoot` – Override the default UNC path (`\\fml-fslogix\FSLogixUserProfiles`)
- `-User` – Target specific users (supports wildcards and arrays)
- `-LastUsedDays` – Filter to profiles not written to in N days
- `-OnlyOdfc` – Reset only Office/ODFC containers
- `-OnlyProfile` – Reset only Profile containers (excludes ODFC)
- `-WhatIf` – Preview mode, no changes made
- `-ListOnly` – Show targets and exit before rename

### CLI Safety Mechanisms

- Mutual exclusion: Cannot specify both `-OnlyOdfc` and `-OnlyProfile`
- Skips rename if `*-old.vhd(x)` target already exists
- Handles missing container files gracefully with logging
- No deletion: All operations are rename-based

### Testing CLI Changes

1. Test with `-WhatIf` first to validate logic without making changes
2. Use `-ListOnly` to verify filtering and discovery logic
3. Test with a single user (`-User <testuser>`) before broader operations
4. Verify log file generation in `%TEMP%` (pattern: `FSLogix_Rename_<username>_<timestamp>.log`)
5. Test container type filtering with `-OnlyOdfc` and `-OnlyProfile`
6. Test wildcard patterns (`-User vdi*`) and multi-value user filters
