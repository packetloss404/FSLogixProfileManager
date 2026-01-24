<#
FSLogix Profile Manager - Horizon Instant Clones
Version: 0.7.0

Environment:
  Root: \\fml-fslogix\FSLogixUserProfiles (supports multiple paths separated by semicolon)
  Folder pattern: username_S-1-5-21-xxxxxxxx-xxxxxxxx-xxxxxxxx-xxxx

This tool:
  - Finds all *.vhd / *.vhdx under the root(s)
  - Derives username from the folder name (before "_S-1-5-21-")
  - Shows one row per user (aggregated across SIDs) with SID breakdown
  - Detects corrupt profiles, orphaned users (not in AD), and disk space issues
  - Lets you filter, highlight big profiles, and retire containers (with WhatIf).
  - Supports multiple profile roots (Cloud Cache), CSV export, column sorting, and theming.
#>

param(
    [string]$DefaultProfileRoot = "\\fml-fslogix\FSLogixUserProfiles"
)

$appVersion = "0.7.0"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --------------------------------------------------------------------
#  Theme definitions
# --------------------------------------------------------------------
$script:Themes = @{
    Light = @{
        FormBackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
        FormForeColor = [System.Drawing.Color]::Black
        GridBackColor = [System.Drawing.Color]::White
        GridForeColor = [System.Drawing.Color]::Black
        GridHeaderBackColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
        GridHeaderForeColor = [System.Drawing.Color]::Black
        GridAlternateRowColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
        HighlightColor = [System.Drawing.Color]::MistyRose
        ButtonBackColor = [System.Drawing.Color]::FromArgb(225, 225, 225)
        ButtonForeColor = [System.Drawing.Color]::Black
        TextBoxBackColor = [System.Drawing.Color]::White
        TextBoxForeColor = [System.Drawing.Color]::Black
        LogPanelBackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
        LogPanelForeColor = [System.Drawing.Color]::Black
    }
    Dark = @{
        FormBackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        FormForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
        GridBackColor = [System.Drawing.Color]::FromArgb(37, 37, 38)
        GridForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
        GridHeaderBackColor = [System.Drawing.Color]::FromArgb(62, 62, 66)
        GridHeaderForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
        GridAlternateRowColor = [System.Drawing.Color]::FromArgb(50, 50, 52)
        HighlightColor = [System.Drawing.Color]::FromArgb(100, 60, 60)
        ButtonBackColor = [System.Drawing.Color]::FromArgb(62, 62, 66)
        ButtonForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
        TextBoxBackColor = [System.Drawing.Color]::FromArgb(37, 37, 38)
        TextBoxForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
        LogPanelBackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        LogPanelForeColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
    }
}

$script:CurrentTheme = "Light"
$script:LogMessages = [System.Collections.ArrayList]::new()

# Common VHD size limits (in GB) - FSLogix defaults
$script:CommonSizeLimits = @(30, 50, 100, 120)
$script:SizeWarningThresholdPercent = 90

# --------------------------------------------------------------------
#  Logging helper for embedded log panel
# --------------------------------------------------------------------
function Add-LogMessage {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    [void]$script:LogMessages.Add($entry)

    # Keep only last 500 messages
    while ($script:LogMessages.Count -gt 500) {
        $script:LogMessages.RemoveAt(0)
    }

    # Update log panel if it exists
    if ($script:txtLog -and $script:txtLog.IsHandleCreated) {
        try {
            $script:txtLog.Invoke([Action]{
                $script:txtLog.AppendText("$entry`r`n")
                $script:txtLog.SelectionStart = $script:txtLog.TextLength
                $script:txtLog.ScrollToCaret()
            })
        } catch {
            # Ignore invoke errors during form construction
        }
    }
}

# --------------------------------------------------------------------
#  Open handle detection using file system
# --------------------------------------------------------------------
function Test-FileInUse {
    param([string]$FilePath)

    if (-not (Test-Path $FilePath)) {
        return $false
    }

    try {
        $stream = [System.IO.File]::Open($FilePath, 'Open', 'ReadWrite', 'None')
        $stream.Close()
        $stream.Dispose()
        return $false
    } catch {
        return $true
    }
}

function Get-InUseContainers {
    param($ProfileObject)

    $inUse = @()
    foreach ($file in $ProfileObject.ContainerFiles) {
        if (Test-FileInUse -FilePath $file) {
            $inUse += $file
        }
    }
    return $inUse
}

# --------------------------------------------------------------------
#  AD Orphan Detection
# --------------------------------------------------------------------
function Test-UserExistsInAD {
    param([string]$UserName)

    # Try multiple methods to check if user exists
    try {
        # Method 1: Try ADSI searcher (works without AD module)
        $searcher = [adsisearcher]"(samaccountname=$UserName)"
        $result = $searcher.FindOne()
        return ($null -ne $result)
    } catch {
        # ADSI failed, try AD module if available
        try {
            if (Get-Command Get-ADUser -ErrorAction SilentlyContinue) {
                $user = Get-ADUser -Identity $UserName -ErrorAction SilentlyContinue
                return ($null -ne $user)
            }
        } catch {
            # AD module query failed
        }
    }

    # If we can't query AD, assume user exists (don't mark as orphan)
    return $true
}

$script:ADCheckEnabled = $false
$script:ADCheckCache = @{}

function Initialize-ADCheck {
    # Test if we can query AD
    try {
        $searcher = [adsisearcher]"(samaccountname=Administrator)"
        $result = $searcher.FindOne()
        $script:ADCheckEnabled = $true
        Add-LogMessage "AD connectivity verified - orphan detection enabled" "INFO"
        return $true
    } catch {
        $script:ADCheckEnabled = $false
        Add-LogMessage "AD not available - orphan detection disabled" "WARN"
        return $false
    }
}

function Get-UserADStatus {
    param([string]$UserName)

    if (-not $script:ADCheckEnabled) {
        return "UNKNOWN"
    }

    # Check cache first
    if ($script:ADCheckCache.ContainsKey($UserName)) {
        return $script:ADCheckCache[$UserName]
    }

    # Query AD
    $exists = Test-UserExistsInAD -UserName $UserName
    $status = if ($exists) { "OK" } else { "ORPHAN" }
    $script:ADCheckCache[$UserName] = $status

    return $status
}

# --------------------------------------------------------------------
#  VHD Health Check
# --------------------------------------------------------------------
function Get-VHDHealth {
    param(
        [string]$FilePath,
        [double]$FileSizeGB
    )

    $issues = @()

    # Check for CORRUPT in filename
    $fileName = Split-Path -Leaf $FilePath
    if ($fileName -match 'CORRUPT') {
        $issues += "CORRUPT"
    }

    # Check for -old (already retired)
    if ($fileName -match '-old\.vhdx?$') {
        $issues += "RETIRED"
    }

    # Check if file size is near common limits
    foreach ($limit in $script:CommonSizeLimits) {
        $threshold = $limit * ($script:SizeWarningThresholdPercent / 100)
        if ($FileSizeGB -ge $threshold -and $FileSizeGB -le $limit) {
            $issues += "NEAR_LIMIT"
            break
        }
    }

    # Check if file is very small (might be corrupt/empty)
    if ($FileSizeGB -lt 0.001 -and (Test-Path $FilePath)) {
        $issues += "EMPTY"
    }

    if ($issues.Count -eq 0) {
        return "OK"
    }

    return ($issues -join ",")
}

function Get-VHDMaxSize {
    param([string]$FilePath)

    # Try to get max size using Get-VHD if Hyper-V module is available
    try {
        if (Get-Command Get-VHD -ErrorAction SilentlyContinue) {
            $vhd = Get-VHD -Path $FilePath -ErrorAction SilentlyContinue
            if ($vhd) {
                return [Math]::Round($vhd.Size / 1GB, 2)
            }
        }
    } catch {
        # Get-VHD not available or failed
    }

    # Fallback: guess based on common limits
    $fileSizeGB = (Get-Item $FilePath -ErrorAction SilentlyContinue).Length / 1GB
    foreach ($limit in ($script:CommonSizeLimits | Sort-Object)) {
        if ($fileSizeGB -lt $limit) {
            return $limit
        }
    }

    return 30  # Default FSLogix limit
}

# --------------------------------------------------------------------
#  FSLogix scan + username detection (with SID tracking + health)
# --------------------------------------------------------------------
function Get-FSLogixProfiles {
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$ProfileRoots,
        [bool]$CheckOrphans = $false
    )

    $userTable = @{}
    $debugLimit = 10

    # Initialize AD check if orphan detection requested
    if ($CheckOrphans) {
        Initialize-ADCheck
    }

    foreach ($ProfileRoot in $ProfileRoots) {
        $ProfileRoot = $ProfileRoot.Trim()
        if ([string]::IsNullOrWhiteSpace($ProfileRoot)) { continue }

        if (-not (Test-Path $ProfileRoot)) {
            Add-LogMessage "Profile root not found: $ProfileRoot" "WARN"
            continue
        }

        Add-LogMessage "Scanning: $ProfileRoot" "INFO"

        # All container files
        $vhdFiles = Get-ChildItem -Path $ProfileRoot -Recurse -File -Filter *.vhd* -ErrorAction SilentlyContinue
        Add-LogMessage "Found $($vhdFiles.Count) .vhd/.vhdx files under $ProfileRoot" "INFO"

        foreach ($file in $vhdFiles) {
            # Folder that contains the SID, e.g. vditest1_S-1-5-21-1602...
            $folderLeaf = Split-Path $file.DirectoryName -Leaf
            $userNameGuess = $null
            $sidMatch = $null

            # Pattern: username_S-1-5-21-...
            if ($folderLeaf -match '^(?<user>.+?)_(?<sid>S-1-5-21-[\d-]+)') {
                $userNameGuess = $Matches['user']
                $sidMatch = $Matches['sid']
            }
            elseif ($file.BaseName -match '^(?<user>.+?)_(?<sid>S-1-5-21-[\d-]+)') {
                $userNameGuess = $Matches['user']
                $sidMatch = $Matches['sid']
            }
            else {
                # Fallback: just use the folder name as-is
                $userNameGuess = $folderLeaf
                $sidMatch = "Unknown"
            }

            if ([string]::IsNullOrWhiteSpace($userNameGuess)) {
                continue
            }

            if ($debugLimit -gt 0) {
                Write-Host "DEBUG MAP: $($file.FullName)  =>  User '$userNameGuess', SID '$sidMatch'"
                $debugLimit--
            }

            $fileSizeGB = [Math]::Round($file.Length / 1GB, 3)

            if (-not $userTable.ContainsKey($userNameGuess)) {
                $userTable[$userNameGuess] = [PSCustomObject]@{
                    UserName       = $userNameGuess
                    ContainerCount = 0
                    ProfileSizeGB  = 0.0
                    OfficeSizeGB   = 0.0
                    TotalSizeGB    = 0.0
                    MaxSizeGB      = 0.0
                    LastWriteTime  = $file.LastWriteTime
                    RootFolder     = $file.DirectoryName
                    ContainerFiles = @()
                    SIDs           = [System.Collections.Generic.HashSet[string]]::new()
                    ProfileRoots   = [System.Collections.Generic.HashSet[string]]::new()
                    HealthIssues   = [System.Collections.Generic.HashSet[string]]::new()
                    ADStatus       = "UNKNOWN"
                }
            }

            $entry = $userTable[$userNameGuess]

            $entry.ContainerCount++
            $entry.ContainerFiles += $file.FullName

            # Track SIDs
            if ($sidMatch) {
                [void]$entry.SIDs.Add($sidMatch)
            }

            # Track which roots this user appears in
            [void]$entry.ProfileRoots.Add($ProfileRoot)

            # Check VHD health
            $health = Get-VHDHealth -FilePath $file.FullName -FileSizeGB $fileSizeGB
            if ($health -ne "OK") {
                foreach ($issue in ($health -split ',')) {
                    [void]$entry.HealthIssues.Add($issue)
                }
            }

            # Track max size (use largest container's limit)
            $maxSize = Get-VHDMaxSize -FilePath $file.FullName
            if ($maxSize -gt $entry.MaxSizeGB) {
                $entry.MaxSizeGB = $maxSize
            }

            # Simple classification: Office vs Profile by filename
            if ($file.Name -match 'odfc|office') {
                $entry.OfficeSizeGB += $fileSizeGB
            } else {
                $entry.ProfileSizeGB += $fileSizeGB
            }

            $entry.TotalSizeGB = $entry.ProfileSizeGB + $entry.OfficeSizeGB

            if ($file.LastWriteTime -gt $entry.LastWriteTime) {
                $entry.LastWriteTime = $file.LastWriteTime
            }

            # RootFolder: keep the "highest" folder we see (first one)
            if (-not $entry.RootFolder) {
                $entry.RootFolder = $file.DirectoryName
            }
        }
    }

    # Check AD status for each user if enabled
    if ($CheckOrphans -and $script:ADCheckEnabled) {
        Add-LogMessage "Checking AD status for $($userTable.Count) users..." "INFO"
        $orphanCount = 0
        foreach ($user in $userTable.Keys) {
            $status = Get-UserADStatus -UserName $user
            $userTable[$user].ADStatus = $status
            if ($status -eq "ORPHAN") {
                [void]$userTable[$user].HealthIssues.Add("ORPHAN")
                $orphanCount++
            }
        }
        Add-LogMessage "Found $orphanCount orphaned profiles" "INFO"
    }

    Add-LogMessage "Total unique users found: $($userTable.Count)" "INFO"
    return $userTable.Values | Sort-Object UserName
}

# --------------------------------------------------------------------
#  Retire (rename) profiles with logging (+ Only ODFC / Only Profile)
# --------------------------------------------------------------------
function Rename-FSLogixProfileObject {
    param(
        [Parameter(Mandatory=$true)]
        $ProfileObject,
        [bool]$WhatIf = $true,
        [bool]$OnlyOdfc = $false,
        [bool]$OnlyProfile = $false,
        [bool]$CheckInUse = $true
    )

    $user = $ProfileObject.UserName
    $stamp = Get-Date -Format "yyyyMMddHHmmss"
    $log = Join-Path $env:TEMP ("FSLogix_Rename_{0}_{1}.log" -f $user, $stamp)

    function LogLocal {
        param($msg, $logFile)
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$ts $msg" | Tee-Object -FilePath $logFile -Append | Out-Null
        Add-LogMessage $msg "INFO"
    }

    LogLocal "Starting rename (retire) for '$user'" $log
    LogLocal "Containers (all types): $($ProfileObject.ContainerFiles.Count)" $log
    LogLocal "Mode: WhatIf=$WhatIf, OnlyODFC=$OnlyOdfc, OnlyProfile=$OnlyProfile, CheckInUse=$CheckInUse" $log

    # Decide which files to target
    $files = $ProfileObject.ContainerFiles

    if ($OnlyOdfc -and $OnlyProfile) {
        LogLocal "Both ODFC-only and Profile-only were selected. No action taken." $log
        return $log
    }

    if ($OnlyOdfc) {
        $files = $files | Where-Object { $_ -match 'odfc|office' }
        LogLocal "Filtered to ODFC/Office containers: $($files.Count)" $log
    }

    if ($OnlyProfile) {
        $files = $files | Where-Object { $_ -notmatch 'odfc|office' }
        LogLocal "Filtered to Profile containers (non-ODFC): $($files.Count)" $log
    }

    if (-not $files -or $files.Count -eq 0) {
        LogLocal "No files to rename with current mode. Exiting." $log
        return $log
    }

    $skippedInUse = @()

    foreach ($path in $files) {
        if (-not (Test-Path $path)) {
            LogLocal "Missing file (skip): $path" $log
            continue
        }

        # Check if file is in use
        if ($CheckInUse -and (Test-FileInUse -FilePath $path)) {
            LogLocal "IN USE (skip): $path" $log
            $skippedInUse += $path
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

        if ($WhatIf) {
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

    if ($skippedInUse.Count -gt 0) {
        LogLocal "Skipped $($skippedInUse.Count) in-use files" $log
    }

    LogLocal "Completed rename (retire) for '$user'" $log
    return $log
}

# --------------------------------------------------------------------
#  Filtering helper (returns filtered list)
# --------------------------------------------------------------------
function Apply-Filters {
    param(
        [System.Collections.IEnumerable]$Source,
        [string]$UserFilter,
        [bool]$UseAge,
        [int]$AgeDays,
        [bool]$OnlyIssues = $false
    )

    $filtered = $Source

    if (-not [string]::IsNullOrWhiteSpace($UserFilter)) {
        $filtered = $filtered | Where-Object {
            $_.UserName -like "*$UserFilter*"
        }
    }

    if ($UseAge -and $AgeDays -gt 0) {
        $threshold = (Get-Date).AddDays(-$AgeDays)
        $filtered = $filtered | Where-Object {
            $_.LastWriteTime -lt $threshold
        }
    }

    if ($OnlyIssues) {
        $filtered = $filtered | Where-Object {
            $_.HealthIssues.Count -gt 0
        }
    }

    return @($filtered)
}

# --------------------------------------------------------------------
#  Row highlight helper
# --------------------------------------------------------------------
function Update-RowHighlight {
    param(
        [System.Windows.Forms.DataGridViewRow]$Row,
        $ProfileObject,
        [bool]$HighlightEnabled,
        [double]$ThresholdGB,
        [System.Drawing.Color]$DefaultColor,
        [System.Drawing.Color]$HighlightColor
    )

    if (-not $ProfileObject) {
        $Row.DefaultCellStyle.BackColor = $DefaultColor
        return
    }

    # Priority: Health issues > Size highlight
    if ($ProfileObject.HealthIssues.Count -gt 0) {
        if ($ProfileObject.HealthIssues -contains "CORRUPT") {
            $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightCoral
            return
        }
        if ($ProfileObject.HealthIssues -contains "ORPHAN") {
            $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::LightGoldenrodYellow
            return
        }
        if ($ProfileObject.HealthIssues -contains "NEAR_LIMIT") {
            $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::PeachPuff
            return
        }
    }

    if (-not $HighlightEnabled) {
        $Row.DefaultCellStyle.BackColor = $DefaultColor
        return
    }

    $size = 0.0
    [void][double]::TryParse($ProfileObject.TotalSizeGB.ToString(), [ref]$size)

    if ($size -ge $ThresholdGB) {
        $Row.DefaultCellStyle.BackColor = $HighlightColor
    } else {
        $Row.DefaultCellStyle.BackColor = $DefaultColor
    }
}

# --------------------------------------------------------------------
#  CSV Export helper
# --------------------------------------------------------------------
function Export-GridToCSV {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [string]$FilePath
    )

    $sb = [System.Text.StringBuilder]::new()

    # Headers
    $headers = @()
    foreach ($col in $Grid.Columns) {
        $headers += "`"$($col.HeaderText)`""
    }
    [void]$sb.AppendLine(($headers -join ","))

    # Data rows
    foreach ($row in $Grid.Rows) {
        $values = @()
        foreach ($cell in $row.Cells) {
            $val = if ($cell.Value) { $cell.Value.ToString() } else { "" }
            $val = $val -replace "`"", "`"`""
            $values += "`"$val`""
        }
        [void]$sb.AppendLine(($values -join ","))
    }

    $sb.ToString() | Out-File -FilePath $FilePath -Encoding UTF8
    Add-LogMessage "Exported $($Grid.Rows.Count) rows to $FilePath" "INFO"
}

# --------------------------------------------------------------------
#  Rename Preview Dialog
# --------------------------------------------------------------------
function Show-RenamePreviewDialog {
    param(
        $SelectedProfiles,
        [bool]$OnlyOdfc,
        [bool]$OnlyProfile
    )

    $previewForm = New-Object System.Windows.Forms.Form
    $previewForm.Text = "Rename Preview"
    $previewForm.Size = New-Object System.Drawing.Size(800, 500)
    $previewForm.StartPosition = "CenterParent"
    $previewForm.FormBorderStyle = "Sizable"

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = "The following files will be renamed:"
    $lblInfo.Location = New-Object System.Drawing.Point(10, 10)
    $lblInfo.AutoSize = $true
    $previewForm.Controls.Add($lblInfo)

    $listView = New-Object System.Windows.Forms.ListView
    $listView.Location = New-Object System.Drawing.Point(10, 35)
    $listView.Size = New-Object System.Drawing.Size(760, 380)
    $listView.View = "Details"
    $listView.FullRowSelect = $true
    $listView.GridLines = $true
    $listView.Anchor = "Top,Left,Right,Bottom"

    [void]$listView.Columns.Add("User", 100)
    [void]$listView.Columns.Add("Current Path", 300)
    [void]$listView.Columns.Add("New Path", 300)
    [void]$listView.Columns.Add("Status", 60)

    $previewForm.Controls.Add($listView)

    $inUseCount = 0

    foreach ($profile in $SelectedProfiles) {
        $files = $profile.ContainerFiles

        if ($OnlyOdfc) {
            $files = $files | Where-Object { $_ -match 'odfc|office' }
        }
        if ($OnlyProfile) {
            $files = $files | Where-Object { $_ -notmatch 'odfc|office' }
        }

        foreach ($path in $files) {
            $dir  = Split-Path -Parent $path
            $name = Split-Path -Leaf  $path
            $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
            $ext  = [System.IO.Path]::GetExtension($name)
            $newName = "{0}-old{1}" -f $base, $ext
            $newPath = Join-Path $dir $newName

            $status = "OK"
            if (Test-FileInUse -FilePath $path) {
                $status = "IN USE"
                $inUseCount++
            } elseif (Test-Path $newPath) {
                $status = "EXISTS"
            } elseif (-not (Test-Path $path)) {
                $status = "MISSING"
            }

            $item = New-Object System.Windows.Forms.ListViewItem($profile.UserName)
            [void]$item.SubItems.Add($path)
            [void]$item.SubItems.Add($newPath)
            [void]$item.SubItems.Add($status)

            if ($status -eq "IN USE") {
                $item.BackColor = [System.Drawing.Color]::LightCoral
            } elseif ($status -ne "OK") {
                $item.BackColor = [System.Drawing.Color]::LightYellow
            }

            [void]$listView.Items.Add($item)
        }
    }

    $lblSummary = New-Object System.Windows.Forms.Label
    $lblSummary.Text = "Total files: $($listView.Items.Count), In-use: $inUseCount"
    $lblSummary.Location = New-Object System.Drawing.Point(10, 420)
    $lblSummary.AutoSize = $true
    $lblSummary.Anchor = "Bottom,Left"
    $previewForm.Controls.Add($lblSummary)

    $btnProceed = New-Object System.Windows.Forms.Button
    $btnProceed.Text = "Proceed"
    $btnProceed.Location = New-Object System.Drawing.Point(600, 420)
    $btnProceed.Size = New-Object System.Drawing.Size(80, 28)
    $btnProceed.Anchor = "Bottom,Right"
    $btnProceed.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $previewForm.Controls.Add($btnProceed)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Location = New-Object System.Drawing.Point(690, 420)
    $btnCancel.Size = New-Object System.Drawing.Size(80, 28)
    $btnCancel.Anchor = "Bottom,Right"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $previewForm.Controls.Add($btnCancel)

    $previewForm.AcceptButton = $btnProceed
    $previewForm.CancelButton = $btnCancel

    return $previewForm.ShowDialog()
}

# --------------------------------------------------------------------
#  Apply Theme
# --------------------------------------------------------------------
function Apply-Theme {
    param([string]$ThemeName)

    $theme = $script:Themes[$ThemeName]
    if (-not $theme) { return }

    $script:CurrentTheme = $ThemeName

    # Form
    $form.BackColor = $theme.FormBackColor
    $form.ForeColor = $theme.FormForeColor

    # Apply to all controls recursively
    function Apply-ToControl($ctrl) {
        if ($ctrl -is [System.Windows.Forms.Label]) {
            $ctrl.ForeColor = $theme.FormForeColor
        }
        elseif ($ctrl -is [System.Windows.Forms.Button]) {
            $ctrl.BackColor = $theme.ButtonBackColor
            $ctrl.ForeColor = $theme.ButtonForeColor
            $ctrl.FlatStyle = 'Flat'
            $ctrl.FlatAppearance.BorderColor = $theme.FormForeColor
        }
        elseif ($ctrl -is [System.Windows.Forms.TextBox]) {
            $ctrl.BackColor = $theme.TextBoxBackColor
            $ctrl.ForeColor = $theme.TextBoxForeColor
        }
        elseif ($ctrl -is [System.Windows.Forms.CheckBox]) {
            $ctrl.ForeColor = $theme.FormForeColor
        }
        elseif ($ctrl -is [System.Windows.Forms.NumericUpDown]) {
            $ctrl.BackColor = $theme.TextBoxBackColor
            $ctrl.ForeColor = $theme.TextBoxForeColor
        }
        elseif ($ctrl -is [System.Windows.Forms.ComboBox]) {
            $ctrl.BackColor = $theme.TextBoxBackColor
            $ctrl.ForeColor = $theme.TextBoxForeColor
        }
        elseif ($ctrl -is [System.Windows.Forms.DataGridView]) {
            $ctrl.BackgroundColor = $theme.GridBackColor
            $ctrl.DefaultCellStyle.BackColor = $theme.GridBackColor
            $ctrl.DefaultCellStyle.ForeColor = $theme.GridForeColor
            $ctrl.ColumnHeadersDefaultCellStyle.BackColor = $theme.GridHeaderBackColor
            $ctrl.ColumnHeadersDefaultCellStyle.ForeColor = $theme.GridHeaderForeColor
            $ctrl.AlternatingRowsDefaultCellStyle.BackColor = $theme.GridAlternateRowColor
            $ctrl.EnableHeadersVisualStyles = $false
            $ctrl.GridColor = $theme.FormForeColor
        }
        elseif ($ctrl -is [System.Windows.Forms.SplitContainer]) {
            $ctrl.BackColor = $theme.FormBackColor
        }

        # Recurse into child controls
        if ($ctrl.Controls) {
            foreach ($child in $ctrl.Controls) {
                Apply-ToControl $child
            }
        }
    }

    foreach ($ctrl in $form.Controls) {
        Apply-ToControl $ctrl
    }

    # Update log panel specifically
    if ($script:txtLog) {
        $script:txtLog.BackColor = $theme.LogPanelBackColor
        $script:txtLog.ForeColor = $theme.LogPanelForeColor
    }

    # Store theme highlight color for row highlighting
    $script:CurrentHighlightColor = $theme.HighlightColor
    $script:DefaultRowBackColor = $theme.GridBackColor

    # Refresh row highlights
    if ($grid) {
        Refresh-RowHighlights
    }

    Add-LogMessage "Applied theme: $ThemeName" "INFO"
}

# --------------------------------------------------------------------
#  WinForms UI
# --------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "FSLogix Profile Manager (Horizon IC) - v$appVersion"
$form.Size = New-Object System.Drawing.Size(1200, 800)
$form.StartPosition = "CenterScreen"
$form.AutoScaleMode = 'None'

# --- Row 1: Profile Root + Load button + version label + Theme ---

$lblRoot = New-Object System.Windows.Forms.Label
$lblRoot.Text = "Profile Root(s):"
$lblRoot.Location = New-Object System.Drawing.Point(10, 15)
$lblRoot.AutoSize = $true
$form.Controls.Add($lblRoot)

$txtRoot = New-Object System.Windows.Forms.TextBox
$txtRoot.Location = New-Object System.Drawing.Point(100, 12)
$txtRoot.Size = New-Object System.Drawing.Size(420, 22)
$txtRoot.Text = $DefaultProfileRoot
$form.Controls.Add($txtRoot)

$lblRootHint = New-Object System.Windows.Forms.Label
$lblRootHint.Text = "(semicolon-separated for multiple)"
$lblRootHint.Location = New-Object System.Drawing.Point(100, 36)
$lblRootHint.AutoSize = $true
$lblRootHint.ForeColor = [System.Drawing.Color]::Gray
$lblRootHint.Font = New-Object System.Drawing.Font("Segoe UI", 7)
$form.Controls.Add($lblRootHint)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "Load Profiles"
$btnLoad.Location = New-Object System.Drawing.Point(530, 10)
$btnLoad.Size = New-Object System.Drawing.Size(100, 28)
$form.Controls.Add($btnLoad)

$btnRescan = New-Object System.Windows.Forms.Button
$btnRescan.Text = "Rescan"
$btnRescan.Location = New-Object System.Drawing.Point(635, 10)
$btnRescan.Size = New-Object System.Drawing.Size(60, 28)
$form.Controls.Add($btnRescan)

$chkCheckOrphans = New-Object System.Windows.Forms.CheckBox
$chkCheckOrphans.Text = "Check AD"
$chkCheckOrphans.Location = New-Object System.Drawing.Point(705, 14)
$chkCheckOrphans.AutoSize = $true
$chkCheckOrphans.Checked = $false
$form.Controls.Add($chkCheckOrphans)

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = "v$appVersion"
$lblVersion.Location = New-Object System.Drawing.Point(800, 15)
$lblVersion.AutoSize = $true
$lblVersion.ForeColor = [System.Drawing.Color]::DarkGray
$form.Controls.Add($lblVersion)

# Theme selector
$lblTheme = New-Object System.Windows.Forms.Label
$lblTheme.Text = "Theme:"
$lblTheme.Location = New-Object System.Drawing.Point(860, 15)
$lblTheme.AutoSize = $true
$form.Controls.Add($lblTheme)

$cmbTheme = New-Object System.Windows.Forms.ComboBox
$cmbTheme.Location = New-Object System.Drawing.Point(910, 12)
$cmbTheme.Size = New-Object System.Drawing.Size(70, 22)
$cmbTheme.DropDownStyle = "DropDownList"
[void]$cmbTheme.Items.Add("Light")
[void]$cmbTheme.Items.Add("Dark")
$cmbTheme.SelectedIndex = 0
$form.Controls.Add($cmbTheme)

# --- GitHub Icon Button (Top Right) ---

$GitHubIconBase64 = @"
iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAMAAAAoLQ9TAAAAjVBMVEUAAAD///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////9n8UQeAAAAOHRSTlMAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAADxoaZ2drb3F1e4GHi5GSl5ydnp+go6Wmqa+wsbK0tri5vsHBwoe9JbEAAABLSURBVBgZBcEJEoMgEADRA2Xn7p3d/79HiA36VnHzVvzkhxHIAk2ZaR5uHHJZlFQcg6gkKgq6HgNwGpCUXlorblSdaCjWsUngKCZLXwoRaBAAAAASUVORK5CYII=
"@

$GitHubImage = $null
try {
    $GitHubIconBytes  = [System.Convert]::FromBase64String($GitHubIconBase64)
    $GitHubIconStream = New-Object System.IO.MemoryStream(,$GitHubIconBytes)
    $GitHubImage      = [System.Drawing.Image]::FromStream($GitHubIconStream)
} catch {
    $GitHubImage = $null
}

$btnGithub = New-Object System.Windows.Forms.Button
$btnGithub.Location = New-Object System.Drawing.Point(1120, 10)
$btnGithub.Size     = New-Object System.Drawing.Size(28, 28)
$btnGithub.FlatStyle = 'Flat'
$btnGithub.FlatAppearance.BorderSize = 0
$btnGithub.BackColor = $form.BackColor

if ($GitHubImage -ne $null) {
    $btnGithub.Image = $GitHubImage
} else {
    $btnGithub.Text = "GH"
    $btnGithub.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
}

$btnGithub.Add_Click({
    Start-Process "https://github.com/packetloss404"
})

$form.Controls.Add($btnGithub)

# --- Row 2: Filter / Age / WhatIf / Highlight ---

$lblFilter = New-Object System.Windows.Forms.Label
$lblFilter.Text = "Filter (user):"
$lblFilter.Location = New-Object System.Drawing.Point(10, 55)
$lblFilter.AutoSize = $true
$form.Controls.Add($lblFilter)

$txtFilter = New-Object System.Windows.Forms.TextBox
$txtFilter.Location = New-Object System.Drawing.Point(100, 52)
$txtFilter.Size = New-Object System.Drawing.Size(120, 22)
$form.Controls.Add($txtFilter)

$btnApplyFilter = New-Object System.Windows.Forms.Button
$btnApplyFilter.Text = "Apply"
$btnApplyFilter.Location = New-Object System.Drawing.Point(225, 50)
$btnApplyFilter.Size = New-Object System.Drawing.Size(55, 26)
$form.Controls.Add($btnApplyFilter)

# Last-used filter
$chkAge = New-Object System.Windows.Forms.CheckBox
$chkAge.Text = "Older than"
$chkAge.Location = New-Object System.Drawing.Point(290, 53)
$chkAge.AutoSize = $true
$form.Controls.Add($chkAge)

$numAge = New-Object System.Windows.Forms.NumericUpDown
$numAge.Location = New-Object System.Drawing.Point(375, 52)
$numAge.Minimum = 1
$numAge.Maximum = 3650
$numAge.Value = 30
$numAge.Size = New-Object System.Drawing.Size(50, 22)
$form.Controls.Add($numAge)

$lblDays = New-Object System.Windows.Forms.Label
$lblDays.Text = "days"
$lblDays.Location = New-Object System.Drawing.Point(430, 55)
$lblDays.AutoSize = $true
$form.Controls.Add($lblDays)

# Show only issues
$chkOnlyIssues = New-Object System.Windows.Forms.CheckBox
$chkOnlyIssues.Text = "Issues only"
$chkOnlyIssues.Location = New-Object System.Drawing.Point(480, 53)
$chkOnlyIssues.AutoSize = $true
$form.Controls.Add($chkOnlyIssues)

# WhatIf
$chkWhatIf = New-Object System.Windows.Forms.CheckBox
$chkWhatIf.Text = "WhatIf"
$chkWhatIf.Location = New-Object System.Drawing.Point(580, 53)
$chkWhatIf.AutoSize = $true
$chkWhatIf.Checked = $true
$form.Controls.Add($chkWhatIf)

# Check In Use
$chkCheckInUse = New-Object System.Windows.Forms.CheckBox
$chkCheckInUse.Text = "Skip in-use"
$chkCheckInUse.Location = New-Object System.Drawing.Point(660, 53)
$chkCheckInUse.AutoSize = $true
$chkCheckInUse.Checked = $true
$form.Controls.Add($chkCheckInUse)

# Highlight big profiles
$chkHighlight = New-Object System.Windows.Forms.CheckBox
$chkHighlight.Text = "Highlight >"
$chkHighlight.Location = New-Object System.Drawing.Point(760, 53)
$chkHighlight.AutoSize = $true
$chkHighlight.Checked = $true
$form.Controls.Add($chkHighlight)

$numHighlight = New-Object System.Windows.Forms.NumericUpDown
$numHighlight.Location = New-Object System.Drawing.Point(850, 52)
$numHighlight.Minimum = 1
$numHighlight.Maximum = 10000
$numHighlight.Value = 20
$numHighlight.Size = New-Object System.Drawing.Size(50, 22)
$form.Controls.Add($numHighlight)

$lblHighlightGb = New-Object System.Windows.Forms.Label
$lblHighlightGb.Text = "GB"
$lblHighlightGb.Location = New-Object System.Drawing.Point(905, 55)
$lblHighlightGb.AutoSize = $true
$form.Controls.Add($lblHighlightGb)

# Export button
$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = "Export CSV"
$btnExport.Location = New-Object System.Drawing.Point(950, 50)
$btnExport.Size = New-Object System.Drawing.Size(80, 26)
$form.Controls.Add($btnExport)

# --- Legend ---
$lblLegend = New-Object System.Windows.Forms.Label
$lblLegend.Text = "Legend: "
$lblLegend.Location = New-Object System.Drawing.Point(1040, 55)
$lblLegend.AutoSize = $true
$lblLegend.Font = New-Object System.Drawing.Font("Segoe UI", 7)
$form.Controls.Add($lblLegend)

$lblLegendCorrupt = New-Object System.Windows.Forms.Label
$lblLegendCorrupt.Text = "■ Corrupt"
$lblLegendCorrupt.Location = New-Object System.Drawing.Point(1085, 55)
$lblLegendCorrupt.AutoSize = $true
$lblLegendCorrupt.ForeColor = [System.Drawing.Color]::LightCoral
$lblLegendCorrupt.Font = New-Object System.Drawing.Font("Segoe UI", 7)
$form.Controls.Add($lblLegendCorrupt)

$lblLegendOrphan = New-Object System.Windows.Forms.Label
$lblLegendOrphan.Text = "■ Orphan"
$lblLegendOrphan.Location = New-Object System.Drawing.Point(1130, 55)
$lblLegendOrphan.AutoSize = $true
$lblLegendOrphan.ForeColor = [System.Drawing.Color]::Goldenrod
$lblLegendOrphan.Font = New-Object System.Drawing.Font("Segoe UI", 7)
$form.Controls.Add($lblLegendOrphan)

# --- SplitContainer for Grid + Log Panel ---

$splitContainer = New-Object System.Windows.Forms.SplitContainer
$splitContainer.Location = New-Object System.Drawing.Point(10, 85)
$splitContainer.Size = New-Object System.Drawing.Size(1160, 620)
$splitContainer.Orientation = "Horizontal"
$splitContainer.SplitterDistance = 480
$splitContainer.Panel1MinSize = 200
$splitContainer.Panel2MinSize = 80
$splitContainer.Anchor = "Top,Left,Right,Bottom"
$form.Controls.Add($splitContainer)

# --- DataGrid ---

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(0, 0)
$grid.Dock = "Fill"
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.ReadOnly = $true
$grid.MultiSelect = $true
$grid.SelectionMode = "FullRowSelect"
$grid.AutoGenerateColumns = $false
$grid.AllowUserToOrderColumns = $true
$splitContainer.Panel1.Controls.Add($grid)

$script:DefaultRowBackColor = $grid.DefaultCellStyle.BackColor
$script:CurrentHighlightColor = [System.Drawing.Color]::MistyRose

# Column sorting state
$script:SortColumn = -1
$script:SortAscending = $true

function Add-Col([string]$header, [int]$width, [string]$sortMode = "Automatic") {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.HeaderText = $header
    $col.Width = $width
    $col.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::$sortMode
    [void]$grid.Columns.Add($col)
}

Add-Col "User"          100 "Programmatic"  # col 0
Add-Col "# Cont"         50 "Programmatic"  # col 1
Add-Col "Used GB"        70 "Programmatic"  # col 2
Add-Col "Max GB"         60 "Programmatic"  # col 3
Add-Col "Office GB"      70 "Programmatic"  # col 4
Add-Col "Last Write"    120 "Programmatic"  # col 5
Add-Col "Status"        100 "Programmatic"  # col 6
Add-Col "SIDs"          150 "Programmatic"  # col 7
Add-Col "Root Folder"   300 "Programmatic"  # col 8

# --- Log Panel ---

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "Operation Log:"
$lblLog.Location = New-Object System.Drawing.Point(0, 0)
$lblLog.AutoSize = $true
$splitContainer.Panel2.Controls.Add($lblLog)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Location = New-Object System.Drawing.Point(0, 20)
$script:txtLog.Multiline = $true
$script:txtLog.ScrollBars = "Vertical"
$script:txtLog.ReadOnly = $true
$script:txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$script:txtLog.Dock = "None"
$script:txtLog.Anchor = "Top,Left,Right,Bottom"
$script:txtLog.Size = New-Object System.Drawing.Size(1160, 100)
$splitContainer.Panel2.Controls.Add($script:txtLog)

# Adjust log panel size on split
$splitContainer.Add_SplitterMoved({
    $script:txtLog.Size = New-Object System.Drawing.Size($splitContainer.Panel2.Width, ($splitContainer.Panel2.Height - 25))
})

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Text = "Clear"
$btnClearLog.Location = New-Object System.Drawing.Point(100, 0)
$btnClearLog.Size = New-Object System.Drawing.Size(50, 20)
$splitContainer.Panel2.Controls.Add($btnClearLog)

$btnClearLog.Add_Click({
    $script:txtLog.Clear()
    $script:LogMessages.Clear()
})

# --- Bottom row: status + profile/office-only + Reset/Close ---

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(10, 715)
$lblStatus.Size = New-Object System.Drawing.Size(400, 20)
$lblStatus.Text = "Ready."
$lblStatus.Anchor = "Bottom,Left"
$form.Controls.Add($lblStatus)

$chkDeleteOdfc = New-Object System.Windows.Forms.CheckBox
$chkDeleteOdfc.Text = "Only ODFC"
$chkDeleteOdfc.Location = New-Object System.Drawing.Point(420, 715)
$chkDeleteOdfc.AutoSize = $true
$chkDeleteOdfc.Anchor = "Bottom,Left"
$form.Controls.Add($chkDeleteOdfc)

$chkDeleteProfile = New-Object System.Windows.Forms.CheckBox
$chkDeleteProfile.Text = "Only Profile"
$chkDeleteProfile.Location = New-Object System.Drawing.Point(520, 715)
$chkDeleteProfile.AutoSize = $true
$chkDeleteProfile.Anchor = "Bottom,Left"
$form.Controls.Add($chkDeleteProfile)

# Ensure mutual exclusivity
$chkDeleteOdfc.Add_CheckedChanged({
    if ($chkDeleteOdfc.Checked) { $chkDeleteProfile.Checked = $false }
})

$chkDeleteProfile.Add_CheckedChanged({
    if ($chkDeleteProfile.Checked) { $chkDeleteOdfc.Checked = $false }
})

$chkPreview = New-Object System.Windows.Forms.CheckBox
$chkPreview.Text = "Preview"
$chkPreview.Location = New-Object System.Drawing.Point(620, 715)
$chkPreview.AutoSize = $true
$chkPreview.Checked = $true
$chkPreview.Anchor = "Bottom,Left"
$form.Controls.Add($chkPreview)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = "Reset Profile"
$btnDelete.Location = New-Object System.Drawing.Point(950, 710)
$btnDelete.Size = New-Object System.Drawing.Size(100, 28)
$btnDelete.Anchor = "Bottom,Right"
$form.Controls.Add($btnDelete)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "Close"
$btnClose.Location = New-Object System.Drawing.Point(1060, 710)
$btnClose.Size = New-Object System.Drawing.Size(60, 28)
$btnClose.Anchor = "Bottom,Right"
$form.Controls.Add($btnClose)

# Hold all profile objects
$script:AllProfiles = @()

# Utility: show profiles in the grid (manual rows + highlight)
function Show-ProfilesInGrid {
    param(
        [System.Collections.IEnumerable]$Profiles
    )

    $grid.Rows.Clear()

    foreach ($p in $Profiles) {
        $idx = $grid.Rows.Add()
        $row = $grid.Rows[$idx]
        $row.Cells[0].Value = $p.UserName
        $row.Cells[1].Value = $p.ContainerCount
        $row.Cells[2].Value = [Math]::Round($p.TotalSizeGB, 1)
        $row.Cells[3].Value = $p.MaxSizeGB
        $row.Cells[4].Value = [Math]::Round($p.OfficeSizeGB, 1)
        $row.Cells[5].Value = $p.LastWriteTime.ToString("yyyy-MM-dd HH:mm")

        # Status column
        $issues = @($p.HealthIssues)
        if ($issues.Count -eq 0) {
            $row.Cells[6].Value = "OK"
        } else {
            $row.Cells[6].Value = ($issues -join ", ")
        }
        $row.Cells[6].ToolTipText = "AD Status: $($p.ADStatus)"

        # SID column - show abbreviated SIDs
        $sidList = @($p.SIDs)
        if ($sidList.Count -le 2) {
            $row.Cells[7].Value = ($sidList -join "; ")
        } else {
            $row.Cells[7].Value = "$($sidList[0]); ... (+$($sidList.Count - 1) more)"
        }
        $row.Cells[7].ToolTipText = ($sidList -join "`n")

        $row.Cells[8].Value = $p.RootFolder

        # Store the object on the row for later use
        $row.Tag = $p

        Update-RowHighlight -Row $row `
                            -ProfileObject $p `
                            -HighlightEnabled $chkHighlight.Checked `
                            -ThresholdGB ([double]$numHighlight.Value) `
                            -DefaultColor $script:DefaultRowBackColor `
                            -HighlightColor $script:CurrentHighlightColor
    }
}

# Helper to re-apply highlight to all rows when settings change
function Refresh-RowHighlights {
    foreach ($row in $grid.Rows) {
        $obj = $row.Tag
        if (-not $obj) { continue }

        Update-RowHighlight -Row $row `
                            -ProfileObject $obj `
                            -HighlightEnabled $chkHighlight.Checked `
                            -ThresholdGB ([double]$numHighlight.Value) `
                            -DefaultColor $script:DefaultRowBackColor `
                            -HighlightColor $script:CurrentHighlightColor
    }
}

# Column header click for sorting
$grid.Add_ColumnHeaderMouseClick({
    param($sender, $e)

    $colIndex = $e.ColumnIndex

    # Toggle sort direction if same column
    if ($script:SortColumn -eq $colIndex) {
        $script:SortAscending = -not $script:SortAscending
    } else {
        $script:SortColumn = $colIndex
        $script:SortAscending = $true
    }

    # Get current filtered profiles
    $profiles = @()
    foreach ($row in $grid.Rows) {
        if ($row.Tag) { $profiles += $row.Tag }
    }

    # Sort based on column
    $sorted = switch ($colIndex) {
        0 { $profiles | Sort-Object UserName }
        1 { $profiles | Sort-Object ContainerCount }
        2 { $profiles | Sort-Object TotalSizeGB }
        3 { $profiles | Sort-Object MaxSizeGB }
        4 { $profiles | Sort-Object OfficeSizeGB }
        5 { $profiles | Sort-Object LastWriteTime }
        6 { $profiles | Sort-Object { ($_.HealthIssues | Measure-Object).Count } }
        7 { $profiles | Sort-Object { ($_.SIDs | Measure-Object).Count } }
        8 { $profiles | Sort-Object RootFolder }
        default { $profiles }
    }

    if (-not $script:SortAscending) {
        [array]::Reverse($sorted)
    }

    Show-ProfilesInGrid $sorted

    # Update column header to show sort indicator
    foreach ($col in $grid.Columns) {
        $col.HeaderCell.SortGlyphDirection = "None"
    }
    $grid.Columns[$colIndex].HeaderCell.SortGlyphDirection = if ($script:SortAscending) { "Ascending" } else { "Descending" }

    Add-LogMessage "Sorted by column $($grid.Columns[$colIndex].HeaderText) $(if($script:SortAscending){'ascending'}else{'descending'})" "INFO"
})

# Load profiles function (shared by Load and Rescan)
function Load-Profiles {
    try {
        $lblStatus.Text = "Loading..."
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        Add-LogMessage "Loading profiles..." "INFO"

        # Clear AD cache
        $script:ADCheckCache = @{}

        $roots = $txtRoot.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $script:AllProfiles = Get-FSLogixProfiles -ProfileRoots $roots -CheckOrphans $chkCheckOrphans.Checked

        $filtered = Apply-Filters -Source $script:AllProfiles `
                                  -UserFilter $txtFilter.Text `
                                  -UseAge $chkAge.Checked `
                                  -AgeDays ([int]$numAge.Value) `
                                  -OnlyIssues $chkOnlyIssues.Checked

        Show-ProfilesInGrid $filtered

        # Count issues
        $issueCount = ($script:AllProfiles | Where-Object { $_.HealthIssues.Count -gt 0 }).Count
        $lblStatus.Text = "Loaded $($filtered.Count) user(s) from $($roots.Count) root(s). Issues: $issueCount"
        Add-LogMessage "Loaded $($filtered.Count) user(s), $issueCount with issues" "INFO"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)")
        $lblStatus.Text = "Error loading profiles."
        Add-LogMessage "Error: $($_.Exception.Message)" "ERROR"
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

# Load button
$btnLoad.Add_Click({ Load-Profiles })

# Rescan button (same as load, but logs differently)
$btnRescan.Add_Click({
    Add-LogMessage "Manual rescan triggered" "INFO"
    Load-Profiles
})

# Apply Filter
$btnApplyFilter.Add_Click({
    if (-not $script:AllProfiles -or $script:AllProfiles.Count -eq 0) { return }

    $filtered = Apply-Filters -Source $script:AllProfiles `
                              -UserFilter $txtFilter.Text `
                              -UseAge $chkAge.Checked `
                              -AgeDays ([int]$numAge.Value) `
                              -OnlyIssues $chkOnlyIssues.Checked

    Show-ProfilesInGrid $filtered
    $lblStatus.Text = "Filter: $($filtered.Count) user(s)"
    Add-LogMessage "Filter applied: $($filtered.Count) user(s) match" "INFO"
})

# Re-apply highlights when highlight options change
$chkHighlight.Add_CheckedChanged({ Refresh-RowHighlights })
$numHighlight.Add_ValueChanged({ Refresh-RowHighlights })

# Theme change
$cmbTheme.Add_SelectedIndexChanged({
    Apply-Theme $cmbTheme.SelectedItem.ToString()
})

# Export CSV
$btnExport.Add_Click({
    if ($grid.Rows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No data to export.")
        return
    }

    $saveDialog = New-Object System.Windows.Forms.SaveFileDialog
    $saveDialog.Filter = "CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    $saveDialog.DefaultExt = "csv"
    $saveDialog.FileName = "FSLogix_Export_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    if ($saveDialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Export-GridToCSV -Grid $grid -FilePath $saveDialog.FileName
        [System.Windows.Forms.MessageBox]::Show("Exported to:`n$($saveDialog.FileName)")
    }
})

# Reset Profile (Retire / rename) Selected
$btnDelete.Add_Click({
    if ($grid.SelectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No users selected.")
        return
    }

    $count = $grid.SelectedRows.Count
    $whatIf = $chkWhatIf.Checked
    $onlyOdfc = $chkDeleteOdfc.Checked
    $onlyProfile = $chkDeleteProfile.Checked
    $checkInUse = $chkCheckInUse.Checked
    $showPreview = $chkPreview.Checked

    # Gather selected profiles
    $selectedProfiles = @()
    foreach ($row in $grid.SelectedRows) {
        if ($row.Tag) { $selectedProfiles += $row.Tag }
    }

    # Show preview dialog if enabled
    if ($showPreview) {
        $previewResult = Show-RenamePreviewDialog -SelectedProfiles $selectedProfiles -OnlyOdfc $onlyOdfc -OnlyProfile $onlyProfile
        if ($previewResult -ne [System.Windows.Forms.DialogResult]::OK) {
            Add-LogMessage "Rename cancelled from preview dialog" "INFO"
            return
        }
    } else {
        # Standard confirmation
        $modeText = if ($onlyOdfc) {
            "ODFC/Office containers only"
        } elseif ($onlyProfile) {
            "Profile containers only"
        } else {
            "ALL containers for selected users"
        }

        $resp = [System.Windows.Forms.MessageBox]::Show(
            "Reset profile (retire/rename containers) for $count user(s)?`n`nMode: $modeText`nWhatIf = $whatIf`nSkip in-use = $checkInUse`n`nContainers will be renamed to *-old.vhd(x).",
            "Confirm Reset Profile",
            [System.Windows.Forms.MessageBoxButtons]::YesNo
        )

        if ($resp -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    Add-LogMessage "Starting rename operation for $count user(s)" "INFO"

    $logs = @()

    foreach ($obj in $selectedProfiles) {
        $logFile = Rename-FSLogixProfileObject -ProfileObject $obj -WhatIf:$whatIf -OnlyOdfc:$onlyOdfc -OnlyProfile:$onlyProfile -CheckInUse:$checkInUse
        $logs += $logFile
    }

    [System.Windows.Forms.MessageBox]::Show("Completed. Logs:`n`n$($logs -join "`n")")

    # Reload to reflect renames
    Load-Profiles
})

# Close
$btnClose.Add_Click({ $form.Close() })

# Apply initial theme
Apply-Theme "Light"

# Initial log message
Add-LogMessage "FSLogix Profile Manager v$appVersion started" "INFO"
Add-LogMessage "Ready. Enter profile root path(s) and click 'Load Profiles'" "INFO"
Add-LogMessage "Enable 'Check AD' to detect orphaned profiles (requires AD connectivity)" "INFO"

# Run
[void]$form.ShowDialog()
