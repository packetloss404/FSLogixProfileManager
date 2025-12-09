<#
FSLogix Profile Manager - Horizon Instant Clones
Version: 0.5.2

Environment:
  Root: \\fml-fslogix\FSLogixUserProfiles
  Folder pattern: username_S-1-5-21-xxxxxxxx-xxxxxxxx-xxxxxxxx-xxxx

This tool:
  - Finds all *.vhd / *.vhdx under the root
  - Derives username from the folder name (before "_S-1-5-21-")
  - Shows one row per user (aggregated across SIDs)
  - Lets you filter, highlight big profiles, and retire containers (with WhatIf).
  - Has options to target ONLY ODFC/Office containers or ONLY Profile containers.
  - Instead of deleting containers, this version RENAMES them with "-old" before the extension.
#>

param(
    [string]$DefaultProfileRoot = "\\fml-fslogix\FSLogixUserProfiles"
)

$appVersion = "0.5.2"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --------------------------------------------------------------------
#  FSLogix scan + username detection
# --------------------------------------------------------------------
function Get-FSLogixProfiles {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ProfileRoot
    )

    if (-not (Test-Path $ProfileRoot)) {
        throw "Profile root not found: $ProfileRoot"
    }

    # All container files
    $vhdFiles = Get-ChildItem -Path $ProfileRoot -Recurse -File -Filter *.vhd* -ErrorAction SilentlyContinue
    Write-Host "DEBUG: Found $($vhdFiles.Count) .vhd/.vhdx files under $ProfileRoot"

    $userTable = @{}
    $debugLimit = 10

    foreach ($file in $vhdFiles) {
        # Folder that contains the SID, e.g. vditest1_S-1-5-21-1602...
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
            # Fallback: just use the folder name as-is
            $userNameGuess = $folderLeaf
        }

        if ([string]::IsNullOrWhiteSpace($userNameGuess)) {
            continue
        }

        if ($debugLimit -gt 0) {
            Write-Host "DEBUG MAP: $($file.FullName)  =>  User '$userNameGuess'"
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

        # Simple classification: Office vs Profile by filename
        if ($file.Name -match 'odfc|office') {
            $entry.OfficeSizeGB += $sizeGB
        } else {
            $entry.ProfileSizeGB += $sizeGB
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
        [bool]$OnlyProfile = $false
    )

    $user = $ProfileObject.UserName
    $stamp = Get-Date -Format "yyyyMMddHHmmss"
    $log = Join-Path $env:TEMP ("FSLogix_Rename_{0}_{1}.log" -f $user, $stamp)

    function LogLocal {
        param($msg, $logFile)
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$ts $msg" | Tee-Object -FilePath $logFile -Append | Out-Null
    }

    LogLocal "Starting rename (retire) for '$user'" $log
    LogLocal "Containers (all types): $($ProfileObject.ContainerFiles.Count)" $log
    LogLocal "Mode: WhatIf=$WhatIf, OnlyODFC=$OnlyOdfc, OnlyProfile=$OnlyProfile" $log

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
        [int]$AgeDays
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
        [System.Drawing.Color]$DefaultColor
    )

    if (-not $ProfileObject) {
        $Row.DefaultCellStyle.BackColor = $DefaultColor
        return
    }

    if (-not $HighlightEnabled) {
        $Row.DefaultCellStyle.BackColor = $DefaultColor
        return
    }

    $size = 0.0
    [void][double]::TryParse($ProfileObject.TotalSizeGB.ToString(), [ref]$size)

    if ($size -ge $ThresholdGB) {
        $Row.DefaultCellStyle.BackColor = [System.Drawing.Color]::MistyRose
    } else {
        $Row.DefaultCellStyle.BackColor = $DefaultColor
    }
}

# --------------------------------------------------------------------
#  WinForms UI
# --------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "FSLogix Profile Manager (Horizon IC) - v$appVersion"
$form.Size = New-Object System.Drawing.Size(1000,700)
$form.StartPosition = "CenterScreen"
$form.AutoScaleMode = 'None'

# --- Row 1: Profile Root + Load button + version label ---

$lblRoot = New-Object System.Windows.Forms.Label
$lblRoot.Text = "Profile Root:"
$lblRoot.Location = New-Object System.Drawing.Point(10,15)
$lblRoot.AutoSize = $true
$form.Controls.Add($lblRoot)

$txtRoot = New-Object System.Windows.Forms.TextBox
$txtRoot.Location = New-Object System.Drawing.Point(100,12)
$txtRoot.Size = New-Object System.Drawing.Size(480,22)
$txtRoot.Text = $DefaultProfileRoot
$form.Controls.Add($txtRoot)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "Load Profiles"
$btnLoad.Location = New-Object System.Drawing.Point(590,10)
$btnLoad.Size = New-Object System.Drawing.Size(120,28)
$form.Controls.Add($btnLoad)

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = "v$appVersion"
$lblVersion.Location = New-Object System.Drawing.Point(730,15)
$lblVersion.AutoSize = $true
$lblVersion.ForeColor = [System.Drawing.Color]::DarkGray
$form.Controls.Add($lblVersion)

# --- GitHub Icon Button (Top Right) ---

# Base64-encoded GitHub logo PNG (16x16)
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
$btnGithub.Location = New-Object System.Drawing.Point(920, 10)
$btnGithub.Size     = New-Object System.Drawing.Size(28,28)
$btnGithub.FlatStyle = 'Flat'
$btnGithub.FlatAppearance.BorderSize = 0
$btnGithub.BackColor = $form.BackColor

if ($GitHubImage -ne $null) {
    $btnGithub.Image = $GitHubImage
} else {
    $btnGithub.Text = "GH"
    $btnGithub.Font = New-Object System.Drawing.Font("Segoe UI",8,[System.Drawing.FontStyle]::Bold)
}

$btnGithub.Add_Click({
    Start-Process "https://github.com/packetloss404"
})

$form.Controls.Add($btnGithub)

# --- Row 2: Filter / Age / WhatIf / Highlight ---

$lblFilter = New-Object System.Windows.Forms.Label
$lblFilter.Text = "Filter (user):"
$lblFilter.Location = New-Object System.Drawing.Point(10,50)
$lblFilter.AutoSize = $true
$form.Controls.Add($lblFilter)

$txtFilter = New-Object System.Windows.Forms.TextBox
$txtFilter.Location = New-Object System.Drawing.Point(100,47)
$txtFilter.Size = New-Object System.Drawing.Size(180,22)
$form.Controls.Add($txtFilter)

$btnApplyFilter = New-Object System.Windows.Forms.Button
$btnApplyFilter.Text = "Apply Filter"
$btnApplyFilter.Location = New-Object System.Drawing.Point(290,45)
$btnApplyFilter.Size = New-Object System.Drawing.Size(100,26)
$form.Controls.Add($btnApplyFilter)

# Last-used filter
$chkAge = New-Object System.Windows.Forms.CheckBox
$chkAge.Text = "Last used >"
$chkAge.Location = New-Object System.Drawing.Point(410,48)
$chkAge.AutoSize = $true
$form.Controls.Add($chkAge)

$numAge = New-Object System.Windows.Forms.NumericUpDown
$numAge.Location = New-Object System.Drawing.Point(510,47)
$numAge.Minimum = 1
$numAge.Maximum = 3650
$numAge.Value = 30
$numAge.Size = New-Object System.Drawing.Size(60,22)
$form.Controls.Add($numAge)

$lblDays = New-Object System.Windows.Forms.Label
$lblDays.Text = "days"
$lblDays.Location = New-Object System.Drawing.Point(575,50)
$lblDays.AutoSize = $true
$form.Controls.Add($lblDays)

# WhatIf
$chkWhatIf = New-Object System.Windows.Forms.CheckBox
$chkWhatIf.Text = "WhatIf (simulate)"
$chkWhatIf.Location = New-Object System.Drawing.Point(640,48)
$chkWhatIf.AutoSize = $true
$chkWhatIf.Checked = $true
$form.Controls.Add($chkWhatIf)

# Highlight big profiles
$chkHighlight = New-Object System.Windows.Forms.CheckBox
$chkHighlight.Text = "Highlight >"
$chkHighlight.Location = New-Object System.Drawing.Point(720,48)
$chkHighlight.AutoSize = $true
$chkHighlight.Checked = $true
$form.Controls.Add($chkHighlight)

$numHighlight = New-Object System.Windows.Forms.NumericUpDown
$numHighlight.Location = New-Object System.Drawing.Point(820,47)
$numHighlight.Minimum = 1
$numHighlight.Maximum = 10000
$numHighlight.Value = 20
$numHighlight.Size = New-Object System.Drawing.Size(60,22)
$form.Controls.Add($numHighlight)

$lblHighlightGb = New-Object System.Windows.Forms.Label
$lblHighlightGb.Text = "GB"
$lblHighlightGb.Location = New-Object System.Drawing.Point(885,50)
$lblHighlightGb.AutoSize = $true
$form.Controls.Add($lblHighlightGb)

# --- DataGrid ---

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(10,80)
$grid.Size = New-Object System.Drawing.Size(960,520)
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.ReadOnly = $true
$grid.MultiSelect = $true
$grid.SelectionMode = "FullRowSelect"
$grid.AutoGenerateColumns = $false
$form.Controls.Add($grid)

$script:DefaultRowBackColor = $grid.DefaultCellStyle.BackColor

function Add-Col([string]$header, [int]$width) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.HeaderText = $header
    $col.Width = $width
    [void]$grid.Columns.Add($col)
}

Add-Col "User"          150  # col 0
Add-Col "# Cont"         70  # col 1
Add-Col "Profile GB"     90  # col 2
Add-Col "Office GB"      90  # col 3
Add-Col "Total GB"       90  # col 4
Add-Col "Last Write"    150  # col 5
Add-Col "Root Folder"   260  # col 6

# --- Bottom row: status + profile/office-only + Reset/Close ---

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(10,615)
$lblStatus.Size = New-Object System.Drawing.Size(360,20)
$lblStatus.Text = "Ready."
$form.Controls.Add($lblStatus)

$chkDeleteOdfc = New-Object System.Windows.Forms.CheckBox
$chkDeleteOdfc.Text = "Only ODFC (Office) containers"
$chkDeleteOdfc.Location = New-Object System.Drawing.Point(380,615)
$chkDeleteOdfc.AutoSize = $true
$form.Controls.Add($chkDeleteOdfc)

$chkDeleteProfile = New-Object System.Windows.Forms.CheckBox
$chkDeleteProfile.Text = "Only Profile containers"
$chkDeleteProfile.Location = New-Object System.Drawing.Point(620,615)
$chkDeleteProfile.AutoSize = $true
$form.Controls.Add($chkDeleteProfile)

# Ensure mutual exclusivity
$chkDeleteOdfc.Add_CheckedChanged({
    if ($chkDeleteOdfc.Checked) { $chkDeleteProfile.Checked = $false }
})

$chkDeleteProfile.Add_CheckedChanged({
    if ($chkDeleteProfile.Checked) { $chkDeleteOdfc.Checked = $false }
})

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Text = "Reset Profile"
$btnDelete.Location = New-Object System.Drawing.Point(800,610)
$btnDelete.Size = New-Object System.Drawing.Size(100,28)
$form.Controls.Add($btnDelete)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = "Close"
$btnClose.Location = New-Object System.Drawing.Point(910,610)
$btnClose.Size = New-Object System.Drawing.Size(60,28)
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
        $row.Cells[2].Value = $p.ProfileSizeGB
        $row.Cells[3].Value = $p.OfficeSizeGB
        $row.Cells[4].Value = $p.TotalSizeGB
        $row.Cells[5].Value = $p.LastWriteTime
        $row.Cells[6].Value = $p.RootFolder

        # Store the object on the row for later use
        $row.Tag = $p

        Update-RowHighlight -Row $row `
                            -ProfileObject $p `
                            -HighlightEnabled $chkHighlight.Checked `
                            -ThresholdGB ([double]$numHighlight.Value) `
                            -DefaultColor $script:DefaultRowBackColor
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
                            -DefaultColor $script:DefaultRowBackColor
    }
}

# Load button
$btnLoad.Add_Click({
    try {
        $lblStatus.Text = "Loading..."
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        $root = $txtRoot.Text.Trim()
        $script:AllProfiles = Get-FSLogixProfiles -ProfileRoot $root

        $filtered = Apply-Filters -Source $script:AllProfiles `
                                  -UserFilter $txtFilter.Text `
                                  -UseAge $chkAge.Checked `
                                  -AgeDays ([int]$numAge.Value)

        Show-ProfilesInGrid $filtered
        $lblStatus.Text = "Loaded $($filtered.Count) user(s)"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)")
        $lblStatus.Text = "Error loading profiles."
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# Apply Filter
$btnApplyFilter.Add_Click({
    if (-not $script:AllProfiles -or $script:AllProfiles.Count -eq 0) { return }

    $filtered = Apply-Filters -Source $script:AllProfiles `
                              -UserFilter $txtFilter.Text `
                              -UseAge $chkAge.Checked `
                              -AgeDays ([int]$numAge.Value)

    Show-ProfilesInGrid $filtered
    $lblStatus.Text = "Filter: $($filtered.Count) user(s)"
})

# Re-apply highlights when highlight options change
$chkHighlight.Add_CheckedChanged({ Refresh-RowHighlights })
$numHighlight.Add_ValueChanged({ Refresh-RowHighlights })

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

    $modeText = if ($onlyOdfc) {
        "ODFC/Office containers only"
    } elseif ($onlyProfile) {
        "Profile containers only"
    } else {
        "ALL containers for selected users"
    }

    $resp = [System.Windows.Forms.MessageBox]::Show(
        "Reset profile (retire/rename containers) for $count user(s)?`n`nMode: $modeText`nWhatIf = $whatIf`n`nContainers will be renamed to *-old.vhd(x).",
        "Confirm Reset Profile",
        [System.Windows.Forms.MessageBoxButtons]::YesNo
    )

    if ($resp -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $logs = @()

    foreach ($row in $grid.SelectedRows) {
        $obj = $row.Tag
        if (-not $obj) { continue }

        $logFile = Rename-FSLogixProfileObject -ProfileObject $obj -WhatIf:$whatIf -OnlyOdfc:$onlyOdfc -OnlyProfile:$onlyProfile
        $logs += $logFile
    }

    [System.Windows.Forms.MessageBox]::Show("Completed. Logs:`n`n$($logs -join "`n")")

    # Reload to reflect renames
    $btnLoad.PerformClick()
})

# Close
$btnClose.Add_Click({ $form.Close() })

# Run
[void]$form.ShowDialog()
