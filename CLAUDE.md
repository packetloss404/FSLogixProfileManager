# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**FSLogix Profile Manager (Horizon IC)** is a WinForms-based PowerShell GUI tool for managing FSLogix user profile containers in VMware Horizon Instant Clones environments. It provides a safe way to retire/reset user profiles by renaming containers rather than deleting them.

### Environment Assumptions

- FSLogix containers stored under a UNC path (default: `\\fml-fslogix\FSLogixUserProfiles`)
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

Log files are written to `%TEMP%` with pattern: `FSLogix_Rename_username_YYYYMMDDHHMMSS.log`

## Architecture

### Core Functions

1. **`Get-FSLogixProfiles`** (lines 30-113)
   - Recursively scans the profile root for `*.vhd/*.vhdx` files
   - Extracts usernames from folder names using regex pattern: `^(?<user>.+?)_S-1-5-21-`
   - Aggregates multiple containers per user (Profile, ODFC/Office, multiple SIDs)
   - Returns custom objects with: UserName, ContainerCount, ProfileSizeGB, OfficeSizeGB, TotalSizeGB, LastWriteTime, RootFolder, ContainerFiles array
   - Classification: Files matching `odfc|office` are Office containers, others are Profile containers

2. **`Rename-FSLogixProfileObject`** (lines 118-198)
   - Core rename/retire operation with per-user logging
   - Supports three modes via switches: `-OnlyOdfc`, `-OnlyProfile`, or both unchecked (all containers)
   - Renames containers by appending `-old` before extension (e.g., `Profile_user_SID.vhdx` → `Profile_user_SID-old.vhdx`)
   - WhatIf support: logs `WHATIF: Would rename...` without actual changes
   - Skips files that don't exist or where target already exists
   - Returns log file path

3. **`Apply-Filters`** (lines 203-227)
   - Filters profile list by username substring match
   - Optional age filter: LastWriteTime < (Now - AgeDays)
   - Returns filtered array

4. **`Update-RowHighlight`** (lines 232-259)
   - Highlights DataGridView rows where TotalSizeGB >= threshold
   - Uses MistyRose background color for highlighted rows

### UI Structure

The WinForms UI is built using `System.Windows.Forms` and `System.Drawing`:

- **Row 1** (top): Profile Root textbox, Load Profiles button, version label, GitHub button (top-right corner)
- **Row 2**: User filter, age filter controls, WhatIf checkbox (default: checked), highlight controls
- **DataGridView** (main area): Displays aggregated user profile data with manual row population
- **Bottom row**: Status label, targeting checkboxes (ODFC-only/Profile-only - mutually exclusive), Reset Profile button, Close button

### Key Design Patterns

- **Manual DataGridView population**: Rows added explicitly, with profile objects stored in `Row.Tag` (not data-binding)
- **Mutual exclusivity**: ODFC-only and Profile-only checkboxes use CheckedChanged events to ensure only one can be checked
- **Filtering workflow**: `Apply-Filters` returns filtered subset; `Show-ProfilesInGrid` populates grid with highlighting
- **Safety-first**: WhatIf mode defaults to ON, rename instead of delete, confirmation dialogs, per-user logging

### Global Script Variables

- `$script:AllProfiles`: Holds all loaded profile objects (before filtering)
- `$script:DefaultRowBackColor`: Stores original grid row color for highlight toggling
- `$appVersion`: Version string displayed in title and UI

## Common Development Tasks

### Modifying Username Detection Logic

If the FSLogix folder naming scheme changes, edit the regex patterns in `Get-FSLogixProfiles` (lines 53-62):
- Primary pattern: `'^(?<user>.+?)_S-1-5-21-'`
- Fallback checks both folder name and file basename

### Adding New Grid Columns

Use the `Add-Col` helper function (lines 418-423), then update `Show-ProfilesInGrid` to populate the new column cells.

### Changing Container Classification

ODFC/Office detection uses regex `'odfc|office'` (line 94). Modify this pattern to adjust classification logic.

### Extending Rename Behavior

The rename logic is in `Rename-FSLogixProfileObject`. Current pattern: `"{0}-old{1}" -f $base, $ext` (line 176). Modify to change naming scheme.

## Important Constraints and Behaviors

- **No deletion**: Tool never deletes files, only renames them
- **No open-handle detection**: Tool does not check if containers are in use before renaming
- **Single profile root**: Designed for one UNC path per session (Cloud Cache secondary paths not supported in v0.5.2)
- **PowerShell 5.1+ required**: Uses .NET Framework WinForms assemblies
- **Network access required**: Must have access to the FSLogix UNC share

## Planned Features (v0.6+)

See CHANGELOG.txt lines 118-138 for roadmap:
- SID column or per-folder breakdown
- CSV export functionality
- Per-column sorting in DataGridView
- Multi-root / Cloud Cache support
- Advanced rename preview dialog
- Open-handle detection before rename
- UI theming (light/dark mode)
- Embedded logging panel
- Manual rescan button
