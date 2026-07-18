# Backlog

## Portfolio audit backlog — 2026-07-17
_Findings from a 2026-07-17 code audit, preserved for later._

### Later / deferred
- **[low/L]** GUI and CLI duplicate the scan/filter/rename logic across two standalone .ps1 files (no shared module)
  - Fix: Extract shared core (Get-FSLogixProfiles, Rename-FSLogixProfileObject, Apply-Filters, Get-VHDHealth/Get-VHDMaxSize, Test-FileInUse) into a new FSLogixProfileCore.psm1 and Import-Module it from both FSLogixProfileGUI.ps1 and FSLogixResetProfile.ps1. Real design work: reconcile the two slightly-diverged copies and re-test both entry points.
- **[low/S]** 'Used GB' column (col 2) is populated from TotalSizeGB, which is on-disk VHD file size (ProfileSizeGB+OfficeSizeGB), not volume-internal used space — loose vs the separate 'Max GB' column
  - Fix: In FSLogixProfileGUI.ps1:1097 rename header 'Used GB' to 'Size (GB)' (or 'On-disk GB') to match what Cells[2]=TotalSizeGB (line 1210) actually holds — the dynamic-VHD file size. Optionally add a column tooltip noting it's on-disk allocation, not internal used bytes.
