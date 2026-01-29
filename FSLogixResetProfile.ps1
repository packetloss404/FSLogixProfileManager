<#
.SYNOPSIS
    Command-line FSLogix profile reset tool (rename-based).

.DESCRIPTION
    Scans an FSLogix profile root (UNC share), groups containers by username,
    and optionally "resets" profiles by RENAMING containers to add "-old"
    before the extension.

    It supports:
      - Targeting specific users (with wildcards).
      - Filtering by last-used (LastWriteTime in days).
      - Targeting ONLY ODFC/Office containers, ONLY Profile containers, or ALL.
      - WhatIf simulation mode (no changes, just logs).

.NOTES
    Version: v1 (CLI-only)

    Default profile root:
      \\fml-fslogix\FSLogixUserProfiles

    Folder naming pattern expected (like Horizon IC lab):
      username_S-1-5-21-XXXXXXXXX-XXXXXXXXX-XXXXXXXXX-XXXXX

    Logs are written per user to %TEMP%:
      FSLogix_Rename_<username>_<YYYYMMDDHHMMSS>.log
#>

param(
    # FSLogix profile root (UNC)
    [string]$ProfileRoot = "\\fml-fslogix\FSLogixUserProfiles",

    # Target user(s). Supports wildcards. If omitted, all users are considered.
    [string[]]$User,

    # Filter: only profiles whose last write is older than this many days.
    [int]$LastUsedDays = 0,

    # If set, only Office/ODFC containers (filename contains 'odfc' or 'office') are processed.
    [switch]$OnlyOdfc,

    # If set, only non-ODFC (profile) containers are processed.
    [switch]$OnlyProfile,

    # If set, no changes are made; actions are logged as "WHATIF".
    [switch]$WhatIf,

    # If set, show which profiles WOULD be targeted, then exit (no rename).
    [switch]$ListOnly
)

# --------------------------------------------------------------------------------------------------
# Validation
# --------------------------------------------------------------------------------------------------

Write-Host "FSLogixResetProfile.ps1 - Command-line reset tool (v1)" -ForegroundColor Cyan
Write-Host "ProfileRoot : $ProfileRoot"
Write-Host "User filter : $($User -join ', ')" 
Write-Host "LastUsedDays: $LastUsedDays"
Write-Host "OnlyOdfc    : $($OnlyOdfc.IsPresent)"
Write-Host "OnlyProfile : $($OnlyProfile.IsPresent)"
Write-Host "WhatIf      : $($WhatIf.IsPresent)"
Write-Host "ListOnly    : $($ListOnly.IsPresent)"
Write-Host ""

if ($OnlyOdfc -and $OnlyProfile) {
    Write-Error "You cannot specify both -OnlyOdfc and -OnlyProfile. Choose one or neither."
    exit 1
}

if (-not (Test-Path $ProfileRoot)) {
    Write-Error "Profile root not found: $ProfileRoot"
    exit 1
}

# --------------------------------------------------------------------------------------------------
#  FSLogix scan + username detection
# --------------------------------------------------------------------------------------------------
function Get-FSLogixProfiles {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Root
    )

    Write-Host "Scanning for *.vhd* under $Root ..." -ForegroundColor Yellow

    $vhdFiles = Get-ChildItem -Path $Root -Recurse -File -Filter *.vhd* -ErrorAction SilentlyContinue
    Write-Host "Found $($vhdFiles.Count) container file(s)." -ForegroundColor Green

    $userTable = @{}
    $debugLimit = 10

    foreach ($file in $vhdFiles) {
        $folderLeaf = Split-Path $file.DirectoryName -Leaf
        $userNameGuess = $null

        # Pattern: username_S-1-5-21-...
        if ($folderLeaf -match '^(?<user>.+?)_S-1-5-21-') {
            $userNameGuess = $Matches['user']
        }
        elseif ($file.BaseName -match '^(?<user>.+?)_S-1-5-21-') {
            $userNameGuess = $Matches['user']
        }
        else {
            # Fallback: just use the folder name
            $userNameGuess = $folderLeaf
        }

        if ([string]::IsNullOrWhiteSpace($userNameGuess)) { continue }

        if ($debugLimit -gt 0) {
            Write-Host ("DEBUG MAP: {0} => '{1}'" -f $file.FullName, $userNameGuess) -ForegroundColor DarkGray
            $debugLimit--
        }

        if (-not $userTable.ContainsKey($userNameGuess)) {
            $userTable[$userNameGuess] = [PSCustomObject]@{
                UserName       = $userNameGuess
                ContainerCount = 0
                ProfileSizeGB  = 0.0
                OfficeSizeGB   = 0.0
                TotalSizeGB    = 0.0
                LastWriteTime  = $file.LastWriteTime
                RootFolder     = $file.DirectoryName
                ContainerFiles = @()
            }
        }

        $entry = $userTable[$userNameGuess]

        $entry.ContainerCount++
        $entry.ContainerFiles += $file.FullName

        $sizeGB = [Math]::Round($file.Length / 1GB, 3)

        if ($file.Name -match 'odfc|office') {
            $entry.OfficeSizeGB += $sizeGB
        } else {
            $entry.ProfileSizeGB += $sizeGB
        }

        $entry.TotalSizeGB = $entry.ProfileSizeGB + $entry.OfficeSizeGB

        if ($file.LastWriteTime -gt $entry.LastWriteTime) {
            $entry.LastWriteTime = $file.LastWriteTime
        }

        if (-not $entry.RootFolder) {
            $entry.RootFolder = $file.DirectoryName
        }
    }

    return $userTable.Values | Sort-Object UserName
}

# --------------------------------------------------------------------------------------------------
#  Filtering helper
# --------------------------------------------------------------------------------------------------
function Apply-Filters {
    param(
        [System.Collections.IEnumerable]$Source,
        [string[]]$UserFilter,
        [int]$LastUsedDays
    )

    $filtered = $Source

    if ($UserFilter -and $UserFilter.Count -gt 0) {
        $patterns = $UserFilter
        $filtered = $filtered | Where-Object {
            $name = $_.UserName
            foreach ($p in $patterns) {
                if ($name -like $p) { return $true }
            }
            return $false
        }
    }

    if ($LastUsedDays -gt 0) {
        $threshold = (Get-Date).AddDays(-$LastUsedDays)
        $filtered = $filtered | Where-Object {
            $_.LastWriteTime -lt $threshold
        }
    }

    return @($filtered)
}

# --------------------------------------------------------------------------------------------------
#  Retire (rename) profiles with logging (+ Only ODFC / Only Profile)
# --------------------------------------------------------------------------------------------------
function Rename-FSLogixProfileObject {
    param(
        [Parameter(Mandatory=$true)]
        $ProfileObject,
        [bool]$WhatIfMode = $true,
        [bool]$OnlyOdfcMode = $false,
        [bool]$OnlyProfileMode = $false
    )

    $user  = $ProfileObject.UserName
    $stamp = Get-Date -Format "yyyyMMddHHmmss"
    $log   = Join-Path $env:TEMP ("FSLogix_Rename_{0}_{1}.log" -f $user, $stamp)

    function LogLocal {
        param($msg, $logFile)
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$ts $msg" | Tee-Object -FilePath $logFile -Append | Out-Null
    }

    LogLocal "Starting rename (retire) for '$user'" $log
    LogLocal "Containers (all types): $($ProfileObject.ContainerFiles.Count)" $log
    LogLocal "Mode: WhatIf=$WhatIfMode, OnlyODFC=$OnlyOdfcMode, OnlyProfile=$OnlyProfileMode" $log

    $files = $ProfileObject.ContainerFiles

    if ($OnlyOdfcMode -and $OnlyProfileMode) {
        LogLocal "Both ODFC-only and Profile-only were selected. No action taken." $log
        return $log
    }

    if ($OnlyOdfcMode) {
        $files = $files | Where-Object { $_ -match 'odfc|office' }
        LogLocal "Filtered to ODFC/Office containers: $($files.Count)" $log
    }

    if ($OnlyProfileMode) {
        $files = $files | Where-Object { $_ -notmatch 'odfc|office' }
        LogLocal "Filtered to Profile containers (non-ODFC): $($files.Count)" $log
    }

    if (-not $files -or $files.Count -eq 0) {
        LogLocal "No files to rename with current mode. Exiting." $log
        return $log
    }

    foreach ($path in $files) {
        if (-not (Test-Path $path)) {
            LogLocal "Missing file (skip): $path" $log
            continue
        }

        $dir  = Split-Path -Parent $path
        $name = Split-Path -Leaf  $path

        $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
        $ext  = [System.IO.Path]::GetExtension($name)

        $newName = "{0}-old{1}" -f $base, $ext
        $newPath = Join-Path $dir $newName

        if (Test-Path $newPath) {
            LogLocal "Target already exists (skip): $newPath" $log
            continue
        }

        if ($WhatIfMode) {
            LogLocal "WHATIF: Would rename $path -> $newPath" $log
        } else {
            try {
                Rename-Item -LiteralPath $path -NewName $newName -ErrorAction Stop
                LogLocal ("Renamed {0} -> {1}" -f $path, $newPath) $log
            } catch {
                LogLocal ("ERROR renaming {0}: {1}" -f $path, $_.Exception.Message) $log
            }
        }
    }

    LogLocal "Completed rename (retire) for '$user'" $log
    return $log
}

# --------------------------------------------------------------------------------------------------
#  Main
# --------------------------------------------------------------------------------------------------

$allProfiles = Get-FSLogixProfiles -Root $ProfileRoot
if (-not $allProfiles -or $allProfiles.Count -eq 0) {
    Write-Warning "No FSLogix profiles discovered under $ProfileRoot."
    exit 0
}

$targets = Apply-Filters -Source $allProfiles -UserFilter $User -LastUsedDays $LastUsedDays

if ($targets.Count -eq 0) {
    Write-Warning "No profiles matched the specified filters."
    exit 0
}

Write-Host ""
Write-Host "Matched $($targets.Count) user profile(s) with current filters:" -ForegroundColor Yellow
$targets | Select-Object UserName, ContainerCount, TotalSizeGB, LastWriteTime |
    Format-Table -AutoSize

if ($ListOnly) {
    Write-Host ""
    Write-Host "ListOnly mode: no reset performed." -ForegroundColor Cyan
    exit 0
}

$modeText = if ($OnlyOdfc) {
    "ODFC/Office containers only"
} elseif ($OnlyProfile) {
    "Profile containers only"
} else {
    "ALL containers (Profile + Office)"
}

Write-Host ""
Write-Host "Reset mode : $modeText" -ForegroundColor Yellow
Write-Host "WhatIf     : $($WhatIf.IsPresent)" -ForegroundColor Yellow
Write-Host ""

$logs = @()

foreach ($p in $targets) {
    Write-Host ("Processing user: {0}" -f $p.UserName) -ForegroundColor Cyan
    $logFile = Rename-FSLogixProfileObject `
        -ProfileObject $p `
        -WhatIfMode:$WhatIf.IsPresent `
        -OnlyOdfcMode:$OnlyOdfc.IsPresent `
        -OnlyProfileMode:$OnlyProfile.IsPresent

    if ($logFile) {
        $logs += $logFile
    }
}

Write-Host ""
Write-Host "Done. Log files:" -ForegroundColor Green
$logs | ForEach-Object { Write-Host "  $_" }
Write-Host ""
Write-Host "Tip: review logs first when running with -WhatIf. Remove -WhatIf to actually reset." -ForegroundColor DarkCyan
