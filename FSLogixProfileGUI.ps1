<#
FSLogix Profile Manager - Horizon Instant Clones
Version: 0.8.0

Environment:
  Root: \\fml-fslogix\FSLogixUserProfiles (supports multiple paths separated by semicolon)
  Folder pattern: username_S-1-5-21-xxxxxxxx-xxxxxxxx-xxxxxxxx-xxxx

This tool:
  - Finds all *.vhd / *.vhdx under the root(s)
  - Derives username + SID from the folder or filename (both FlipFlop orders + NoProfileContainingFolder)
  - Shows one row per user (aggregated across SIDs) with SID breakdown
  - Detects corrupt profiles, orphaned users (not in AD), and disk space issues
  - Lets you filter, highlight big profiles, and retire containers (with WhatIf by default).
  - Supports multiple profile roots (Cloud Cache), CSV export, column sorting, and theming.

All scan/filter/retire/restore logic lives in FSLogixProfileCore.psm1; this script
is the WinForms host.
#>

param(
    [string]$DefaultProfileRoot = "\\fml-fslogix\FSLogixUserProfiles"
)

$appVersion = "0.8.0"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --------------------------------------------------------------------
#  Logging helper for embedded log panel (defined first; module hooks in below)
# --------------------------------------------------------------------
function Add-LogMessage {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "HH:mm:ss"
    $entry = "[$ts] [$Level] $Message"
    [void]$script:LogMessages.Add($entry)

    while ($script:LogMessages.Count -gt 500) {
        $script:LogMessages.RemoveAt(0)
    }

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
#  Load shared core module and route its log output into this GUI
# --------------------------------------------------------------------
$script:ModulePath = Join-Path $PSScriptRoot 'FSLogixProfileCore.psm1'
Import-Module $script:ModulePath -Force

$script:LogHandler = {
    param($Message, $Level)
    # PROGRESS is for a status bar, not a log buffer.
    if ($Level -eq 'PROGRESS') {
        $lbl = $script:lblStatus
        if ($lbl -and $lbl.IsHandleCreated) {
            try { $lbl.Invoke([Action]{ $script:lblStatus.Text = $Message }) } catch { }
        }
        return
    }
    Add-LogMessage $Message $Level
}
Set-FSLogixLogHandler $script:LogHandler

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
        HealthCorrupt   = [System.Drawing.Color]::LightCoral
        HealthOrphan    = [System.Drawing.Color]::LightGoldenrodYellow
        HealthNearLimit = [System.Drawing.Color]::PeachPuff
        LiveButtonColor = [System.Drawing.Color]::FromArgb(192, 40, 40)
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
        HealthCorrupt   = [System.Drawing.Color]::FromArgb(140, 50, 50)
        HealthOrphan    = [System.Drawing.Color]::FromArgb(120, 100, 30)
        HealthNearLimit = [System.Drawing.Color]::FromArgb(120, 80, 40)
        LiveButtonColor = [System.Drawing.Color]::FromArgb(180, 50, 50)
    }
}

$script:CurrentTheme = "Light"
$script:LogMessages = [System.Collections.ArrayList]::new()

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

    $theme = $script:Themes[$script:CurrentTheme]

    # Priority: Health issues > Size highlight
    if ($ProfileObject.HealthIssues.Count -gt 0) {
        if ($ProfileObject.HealthIssues -contains "CORRUPT" -or $ProfileObject.HealthIssues -contains "BAD_SIGNATURE") {
            $Row.DefaultCellStyle.BackColor = $theme.HealthCorrupt
            return
        }
        if ($ProfileObject.HealthIssues -contains "ORPHAN" -or $ProfileObject.HealthIssues -contains "AD_DISABLED") {
            $Row.DefaultCellStyle.BackColor = $theme.HealthOrphan
            return
        }
        if ($ProfileObject.HealthIssues -contains "NEAR_LIMIT" -or $ProfileObject.HealthIssues -contains "OVER_LIMIT") {
            $Row.DefaultCellStyle.BackColor = $theme.HealthNearLimit
            return
        }
    }

    if (-not $HighlightEnabled) {
        $Row.DefaultCellStyle.BackColor = $DefaultColor
        return
    }

    if ($ProfileObject.TotalSizeGB -ge $ThresholdGB) {
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

    $headers = @()
    foreach ($col in $Grid.Columns) {
        $headers += "`"$($col.HeaderText)`""
    }
    [void]$sb.AppendLine(($headers -join ","))

    foreach ($row in $Grid.Rows) {
        $values = @()
        foreach ($cell in $row.Cells) {
            # 0 / $false / $null are real data; only empty string is "no data".
            $val = if ($null -ne $cell.Value) { $cell.Value.ToString() } else { "" }
            $val = $val -replace "`"", "`"`""
            $values += "`"$val`""
        }
        [void]$sb.AppendLine(($values -join ","))
    }

    [System.IO.File]::WriteAllText($FilePath, $sb.ToString(), [System.Text.Encoding]::UTF8)
    Add-LogMessage "Exported $($Grid.Rows.Count) rows to $FilePath" "INFO"
}

# --------------------------------------------------------------------
#  Proportionate confirmation dialog
# --------------------------------------------------------------------
# Name up to ~5 users + "+N more", show the container count, default to Cancel,
# and require the operator to type the container count when above a threshold.
function Show-ResetConfirmation {
    param(
        $SelectedProfiles,
        [int]$ContainerCount,
        [bool]$WhatIf,
        [ValidateSet('All', 'Office', 'Profile')][string]$Scope = 'All',
        [int]$UserThreshold = 5,
        [int]$ContainerThreshold = 20
    )

    $names = @($SelectedProfiles | ForEach-Object { $_.UserName } | Sort-Object)
    $displayNames = if ($names.Count -le $UserThreshold) {
        $names -join ', '
    } else {
        ($names[0..($UserThreshold - 1)] -join ', ') + " (+$($names.Count - $UserThreshold) more)"
    }

    $modeText = switch ($Scope) {
        'Office'  { 'ODFC/Office containers only' }
        'Profile' { 'Profile containers only' }
        default   { 'ALL containers (Profile + Office)' }
    }

    $large = ($SelectedProfiles.Count -gt $UserThreshold) -or ($ContainerCount -gt $ContainerThreshold)

    if (-not $large) {
        $summary = "Users: $displayNames`n`nContainers: $ContainerCount`nMode: $modeText`nWhatIf: $WhatIf"
        $resp = [System.Windows.Forms.MessageBox]::Show(
            $summary + "`n`nProceed?",
            "Confirm Reset - $(if ($WhatIf) {'SIMULATION'} else {'LIVE'})",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning,
            [System.Windows.Forms.DialogResult]::No
        )
        return ($resp -eq [System.Windows.Forms.DialogResult]::Yes)
    }

    # Above threshold: require typed count.
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Confirm Reset - $(if ($WhatIf) {'SIMULATION'} else {'LIVE'})"
    $form.Size = New-Object System.Drawing.Size(540, 360)
    $form.StartPosition = "CenterParent"
    $form.FormBorderStyle = "FixedDialog"
    $form.MinimizeBox = $false
    $form.MaximizeBox = $false

    $lblSummary = New-Object System.Windows.Forms.Label
    $lblSummary.Text = "Users: $displayNames`n`nContainers: $ContainerCount`nMode: $modeText`nWhatIf: $WhatIf"
    $lblSummary.Location = New-Object System.Drawing.Point(12, 12)
    $lblSummary.Size = New-Object System.Drawing.Size(510, 130)
    $lblSummary.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($lblSummary)

    $lblPrompt = New-Object System.Windows.Forms.Label
    $lblPrompt.Text = "Type the container count ($ContainerCount) to confirm:"
    $lblPrompt.Location = New-Object System.Drawing.Point(12, 155)
    $lblPrompt.AutoSize = $true
    $lblPrompt.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblPrompt)

    $txtCount = New-Object System.Windows.Forms.TextBox
    $txtCount.Location = New-Object System.Drawing.Point(12, 180)
    $txtCount.Size = New-Object System.Drawing.Size(140, 24)
    $txtCount.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $form.Controls.Add($txtCount)

    $lblMatch = New-Object System.Windows.Forms.Label
    $lblMatch.Text = ""
    $lblMatch.Location = New-Object System.Drawing.Point(160, 184)
    $lblMatch.AutoSize = $true
    $form.Controls.Add($lblMatch)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Size = New-Object System.Drawing.Size(100, 30)
    $btnCancel.Location = New-Object System.Drawing.Point(420, 280)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $btnConfirm = New-Object System.Windows.Forms.Button
    $btnConfirm.Text = "Confirm"
    $btnConfirm.Size = New-Object System.Drawing.Size(100, 30)
    $btnConfirm.Location = New-Object System.Drawing.Point(310, 280)
    $btnConfirm.Enabled = $false
    $btnConfirm.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($btnConfirm)

    $txtCount.Add_TextChanged({
        $ok = ($txtCount.Text -match ('^\s*' + $ContainerCount + '\s*$'))
        $btnConfirm.Enabled = $ok
        $lblMatch.Text = if ($ok) { "OK" } elseif ($txtCount.Text.Length -gt 0) { "does not match" } else { "" }
    })

    $form.AcceptButton = $btnConfirm
    $form.CancelButton = $btnCancel

    return ($form.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK)
}

# --------------------------------------------------------------------
#  Rename Preview Dialog
# --------------------------------------------------------------------
function Show-RenamePreviewDialog {
    param(
        $SelectedProfiles,
        [ValidateSet('All', 'Office', 'Profile')][string]$Scope = 'All',
        [bool]$WhatIf,
        [bool]$CheckInUse
    )

    $previewForm = New-Object System.Windows.Forms.Form
    $previewForm.Text = "Rename Preview"
    $previewForm.Size = New-Object System.Drawing.Size(960, 620)
    $previewForm.StartPosition = "CenterParent"
    $previewForm.FormBorderStyle = "Sizable"
    $previewForm.MinimumSize = New-Object System.Drawing.Size(720, 420)

    # --- LIVE / SIMULATION banner ---
    $banner = New-Object System.Windows.Forms.Panel
    $banner.Dock = "Top"
    $banner.Height = 40
    $banner.BackColor = if ($WhatIf) {
        [System.Drawing.Color]::FromArgb(200, 200, 200)
    } else {
        [System.Drawing.Color]::FromArgb(180, 30, 30)
    }
    $previewForm.Controls.Add($banner)

    $lblMode = New-Object System.Windows.Forms.Label
    $lblMode.Text = if ($WhatIf) { "  SIMULATION  -  no changes will be made" } else { "  LIVE  -  containers WILL be renamed" }
    $lblMode.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblMode.ForeColor = if ($WhatIf) { [System.Drawing.Color]::Black } else { [System.Drawing.Color]::White }
    $lblMode.Dock = "Fill"
    $lblMode.TextAlign = "MiddleLeft"
    $banner.Controls.Add($lblMode)

    # --- Subtitle: operator / users / horizon ---
    $horizonStatus = if (Test-FSLogixHorizonConnected) { "connected" } else { "not configured" }
    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = "Operator: $env:USERDOMAIN\$env:USERNAME  |  Users: $($SelectedProfiles.Count)  |  Scope: $Scope  |  CheckInUse: $(if ($CheckInUse) {'on'} else {'off'})  |  Horizon: $horizonStatus"
    $subtitle.Dock = "Top"
    $subtitle.Height = 22
    $subtitle.TextAlign = "MiddleLeft"
    $subtitle.Padding = "6,0,0,0"
    $previewForm.Controls.Add($subtitle)

    # --- Plan list ---
    $listView = New-Object System.Windows.Forms.ListView
    $listView.Dock = "Fill"
    $listView.View = "Details"
    $listView.FullRowSelect = $true
    $listView.GridLines = $true

    [void]$listView.Columns.Add("User", 120)
    [void]$listView.Columns.Add("Class", 60)
    [void]$listView.Columns.Add("Current Path", 340)
    [void]$listView.Columns.Add("New Path", 340)
    [void]$listView.Columns.Add("State", 80)
    [void]$listView.Columns.Add("Note", 200)
    $previewForm.Controls.Add($listView)

    $planTotal = 0
    $inUseCount = 0
    $notReadyCount = 0
    foreach ($profile in $SelectedProfiles) {
        $plan = @(Get-FSLogixRetirePlan -ProfileObject $profile -Scope $Scope -CheckInUse:$CheckInUse)
        foreach ($item in $plan) {
            $listItem = New-Object System.Windows.Forms.ListViewItem($item.UserName)
            [void]$listItem.SubItems.Add($item.Class)
            [void]$listItem.SubItems.Add($item.SourcePath)
            [void]$listItem.SubItems.Add($item.DestPath)
            [void]$listItem.SubItems.Add($item.State)
            [void]$listItem.SubItems.Add($item.Note)
            switch ($item.State) {
                'InUse'        { $listItem.BackColor = [System.Drawing.Color]::LightCoral; $inUseCount++ }
                'AccessDenied' { $listItem.BackColor = [System.Drawing.Color]::LightYellow; $notReadyCount++ }
                'Missing'      { $listItem.BackColor = [System.Drawing.Color]::LightYellow; $notReadyCount++ }
                'Exists'       { $listItem.BackColor = [System.Drawing.Color]::LightYellow; $notReadyCount++ }
            }
            [void]$listView.Items.Add($listItem)
            $planTotal++
        }
    }

    # --- Summary ---
    $summary = New-Object System.Windows.Forms.Label
    $summary.Text = "Plan: $planTotal target(s)  |  In-use: $inUseCount  |  Other not-ready: $notReadyCount"
    $summary.Dock = "Bottom"
    $summary.Height = 24
    $summary.TextAlign = "MiddleLeft"
    $summary.Padding = "6,0,0,0"
    $previewForm.Controls.Add($summary)

    # --- Buttons ---
    $btnPanel = New-Object System.Windows.Forms.Panel
    $btnPanel.Dock = "Bottom"
    $btnPanel.Height = 44
    $previewForm.Controls.Add($btnPanel)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"
    $btnCancel.Size = New-Object System.Drawing.Size(90, 30)
    $btnCancel.Location = New-Object System.Drawing.Point(840, 7)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $btnPanel.Controls.Add($btnCancel)

    $btnProceed = New-Object System.Windows.Forms.Button
    $btnProceed.Text = "Proceed"
    $btnProceed.Size = New-Object System.Drawing.Size(90, 30)
    $btnProceed.Location = New-Object System.Drawing.Point(740, 7)
    $btnProceed.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $btnPanel.Controls.Add($btnProceed)

    # Enter -> Cancel, so a stray Enter never retires anything.
    $previewForm.AcceptButton = $btnCancel
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

    $form.BackColor = $theme.FormBackColor
    $form.ForeColor = $theme.FormForeColor

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

        if ($ctrl.Controls) {
            foreach ($child in $ctrl.Controls) {
                Apply-ToControl $child
            }
        }
    }

    foreach ($ctrl in $form.Controls) {
        Apply-ToControl $ctrl
    }

    if ($script:txtLog) {
        $script:txtLog.BackColor = $theme.LogPanelBackColor
        $script:txtLog.ForeColor = $theme.LogPanelForeColor
    }

    $script:CurrentHighlightColor = $theme.HighlightColor
    $script:DefaultRowBackColor = $theme.GridBackColor

    if ($grid) { Refresh-RowHighlights }

    # Refresh the Reset button's color now that the theme changed.
    Set-ResetButtonAppearance

    Add-LogMessage "Applied theme: $ThemeName" "INFO"
}

# --------------------------------------------------------------------
#  Reset button appearance
# --------------------------------------------------------------------
function Set-ResetButtonAppearance {
    $theme = $script:Themes[$script:CurrentTheme]
    if ($null -eq $theme) { return }
    if ($chkWhatIf.Checked) {
        $btnDelete.BackColor = $theme.ButtonBackColor
        $btnDelete.ForeColor = $theme.ButtonForeColor
        $btnDelete.Text = "Reset Profile"
    } else {
        $btnDelete.BackColor = $theme.LiveButtonColor
        $btnDelete.ForeColor = [System.Drawing.Color]::White
        $btnDelete.Text = "Reset Profile  -  LIVE"
    }
}

# --------------------------------------------------------------------
#  WinForms UI
# --------------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "FSLogix Profile Manager (Horizon IC) - v$appVersion"
$form.Size = New-Object System.Drawing.Size(1200, 800)
$form.StartPosition = "CenterScreen"
$form.AutoScaleMode = 'None'
$form.MinimumSize = New-Object System.Drawing.Size(960, 640)

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

$chkOnlyIssues = New-Object System.Windows.Forms.CheckBox
$chkOnlyIssues.Text = "Issues only"
$chkOnlyIssues.Location = New-Object System.Drawing.Point(480, 53)
$chkOnlyIssues.AutoSize = $true
$form.Controls.Add($chkOnlyIssues)

$chkWhatIf = New-Object System.Windows.Forms.CheckBox
$chkWhatIf.Text = "WhatIf"
$chkWhatIf.Location = New-Object System.Drawing.Point(580, 53)
$chkWhatIf.AutoSize = $true
$chkWhatIf.Checked = $true
$form.Controls.Add($chkWhatIf)

$chkCheckInUse = New-Object System.Windows.Forms.CheckBox
$chkCheckInUse.Text = "Skip in-use"
$chkCheckInUse.Location = New-Object System.Drawing.Point(660, 53)
$chkCheckInUse.AutoSize = $true
$chkCheckInUse.Checked = $true
$form.Controls.Add($chkCheckInUse)

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

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = "Export CSV"
$btnExport.Location = New-Object System.Drawing.Point(950, 50)
$btnExport.Size = New-Object System.Drawing.Size(80, 26)
$form.Controls.Add($btnExport)

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

$script:SortColumn = -1
$script:SortAscending = $true

function Add-Col([string]$header, [int]$width, [string]$sortMode = "Automatic") {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.HeaderText = $header
    $col.Width = $width
    $col.SortMode = [System.Windows.Forms.DataGridViewColumnSortMode]::$sortMode
    [void]$grid.Columns.Add($col)
}

Add-Col "User"         120 "Programmatic"  # col 0
Add-Col "# Cont"        55 "Programmatic"  # col 1
Add-Col "Size (GB)"     75 "Programmatic"  # col 2  (was "Used GB")
Add-Col "Max GB"        60 "Programmatic"  # col 3
Add-Col "Office GB"     70 "Programmatic"  # col 4
Add-Col "Last Write"   120 "Programmatic"  # col 5
Add-Col "Status"       130 "Programmatic"  # col 6
Add-Col "SIDs"         180 "Programmatic"  # col 7
Add-Col "Root Folder"  300 "Programmatic"  # col 8

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
# No MaxLength cap: AppendText no-ops silently at 32,767 chars otherwise.
$script:txtLog.MaxLength = 0
$script:txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$script:txtLog.Dock = "None"
$script:txtLog.Anchor = "Top,Left,Right,Bottom"
$script:txtLog.Size = New-Object System.Drawing.Size(1160, 100)
$splitContainer.Panel2.Controls.Add($script:txtLog)

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

$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Location = New-Object System.Drawing.Point(10, 715)
$script:lblStatus.Size = New-Object System.Drawing.Size(400, 20)
$script:lblStatus.Text = "Ready."
$script:lblStatus.Anchor = "Bottom,Left"
$form.Controls.Add($script:lblStatus)

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

# All profile objects (post-scan)
$script:AllProfiles = @()

# --------------------------------------------------------------------
#  Show profiles in the grid
# --------------------------------------------------------------------
function Show-ProfilesInGrid {
    param(
        [System.Collections.IEnumerable]$Profiles
    )

    # Capture current selection so we can restore it after the repaint.
    $priorUsers = New-Object System.Collections.Generic.HashSet[string]
    foreach ($sel in $grid.SelectedRows) {
        if ($sel.Tag -and $sel.Tag.UserName) { [void]$priorUsers.Add($sel.Tag.UserName) }
    }
    $priorTopRow = $grid.FirstDisplayedScrollingRowIndex

    $grid.Rows.Clear()

    foreach ($p in $Profiles) {
        $idx = $grid.Rows.Add()
        $row = $grid.Rows[$idx]
        $row.Cells[0].Value = $p.UserName
        $row.Cells[1].Value = $p.ContainerCount
        $row.Cells[2].Value = [Math]::Round($p.TotalSizeGB, 2)
        # MaxSizeGB may be $null when neither Get-VHD nor ConfiguredMaxSizeGB was available.
        $row.Cells[3].Value = if ($null -ne $p.MaxSizeGB) { [Math]::Round($p.MaxSizeGB, 1) } else { '' }
        $row.Cells[4].Value = [Math]::Round($p.OfficeSizeGB, 2)
        $row.Cells[5].Value = if ($p.LastWriteTime) { $p.LastWriteTime.ToString("yyyy-MM-dd HH:mm") } else { '' }

        $issues = @($p.HealthIssues)
        $row.Cells[6].Value = if ($issues.Count -eq 0) { "OK" } else { ($issues -join ", ") }
        $row.Cells[6].ToolTipText = "AD Status: $($p.ADStatus)"

        # SIDs - show abbreviated when more than 2; full list in tooltip.
        $sidList = @($p.SIDs)
        if ($sidList.Count -le 2) {
            $row.Cells[7].Value = ($sidList -join "; ")
        } else {
            $row.Cells[7].Value = ($sidList[0..1] -join "; ") + "; ... (+$($sidList.Count - 2) more)"
        }
        $row.Cells[7].ToolTipText = ($sidList -join "`n")

        $row.Cells[8].Value = $p.RootFolder
        $row.Tag = $p

        Update-RowHighlight -Row $row `
                            -ProfileObject $p `
                            -HighlightEnabled $chkHighlight.Checked `
                            -ThresholdGB ([double]$numHighlight.Value) `
                            -DefaultColor $script:DefaultRowBackColor `
                            -HighlightColor $script:CurrentHighlightColor

        if ($priorUsers.Contains($p.UserName)) { $row.Selected = $true }
    }

    # Don't auto-select row 0 - the four-click mass retire relied on this.
    if ($grid.SelectedRows.Count -eq 0 -and $grid.Rows.Count -gt 0) {
        $grid.ClearSelection()
    }

    if ($null -ne $priorTopRow -and $priorTopRow -ge 0 -and $priorTopRow -lt $grid.Rows.Count) {
        $grid.FirstDisplayedScrollingRowIndex = $priorTopRow
    }
}

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

# --------------------------------------------------------------------
#  Column header click for sorting
# --------------------------------------------------------------------
$grid.Add_ColumnHeaderMouseClick({
    param($sender, $e)

    $colIndex = $e.ColumnIndex

    if ($script:SortColumn -eq $colIndex) {
        $script:SortAscending = -not $script:SortAscending
    } else {
        $script:SortColumn = $colIndex
        $script:SortAscending = $true
    }

    $profiles = @()
    foreach ($row in $grid.Rows) {
        if ($row.Tag) { $profiles += $row.Tag }
    }

    $sorted = switch ($colIndex) {
        0 { $profiles | Sort-Object UserName }
        1 { $profiles | Sort-Object ContainerCount }
        2 { $profiles | Sort-Object TotalSizeGB }
        3 { $profiles | Sort-Object { if ($_.MaxSizeGB) { $_.MaxSizeGB } else { -1 } } }
        4 { $profiles | Sort-Object OfficeSizeGB }
        5 { $profiles | Sort-Object LastWriteTime }
        6 { $profiles | Sort-Object { ($_.HealthIssues | Measure-Object).Count } }
        7 { $profiles | Sort-Object { ($_.SIDs | Measure-Object).Count } }
        8 { $profiles | Sort-Object RootFolder }
        default { $profiles }
    }

    if (-not $script:SortAscending) {
        # [array]::Reverse throws on a 0- or 1-row grid.
        $arr = @($sorted)
        if ($arr.Count -gt 1) { [array]::Reverse($arr) }
        $sorted = $arr
    }

    Show-ProfilesInGrid $sorted

    foreach ($col in $grid.Columns) {
        $col.HeaderCell.SortGlyphDirection = "None"
    }
    $grid.Columns[$colIndex].HeaderCell.SortGlyphDirection = if ($script:SortAscending) { "Ascending" } else { "Descending" }

    Add-LogMessage "Sorted by column $($grid.Columns[$colIndex].HeaderText) $(if($script:SortAscending){'ascending'}else{'descending'})" "INFO"
})

# --------------------------------------------------------------------
#  Load profiles
# --------------------------------------------------------------------
function Load-Profiles {
    try {
        $script:lblStatus.Text = "Loading..."
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        Add-LogMessage "Loading profiles..." "INFO"

        Clear-FSLogixADCache

        $roots = $txtRoot.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        $script:AllProfiles = @(Get-FSLogixProfiles -ProfileRoots $roots -CheckOrphans:$chkCheckOrphans.Checked)

        $ageDays = if ($chkAge.Checked) { [int]$numAge.Value } else { 0 }
        $filtered = @(Select-FSLogixProfile -Source $script:AllProfiles -UserFilter @(,$txtFilter.Text) -AgeDays $ageDays -OnlyIssues:$chkOnlyIssues.Checked)

        Show-ProfilesInGrid $filtered

        $issueCount = @($script:AllProfiles | Where-Object { $_.HealthIssues.Count -gt 0 }).Count
        $script:lblStatus.Text = "Loaded $($filtered.Count) user(s) from $($roots.Count) root(s). Issues: $issueCount"
        Add-LogMessage "Loaded $($filtered.Count) user(s), $issueCount with issues" "INFO"
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Error: $($_.Exception.Message)")
        $script:lblStatus.Text = "Error loading profiles."
        Add-LogMessage "Error: $($_.Exception.Message)" "ERROR"
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

$btnLoad.Add_Click({ Load-Profiles })

$btnRescan.Add_Click({
    Add-LogMessage "Manual rescan triggered" "INFO"
    Load-Profiles
})

$btnApplyFilter.Add_Click({
    if (-not $script:AllProfiles -or $script:AllProfiles.Count -eq 0) { return }

    $ageDays = if ($chkAge.Checked) { [int]$numAge.Value } else { 0 }
    $filtered = @(Select-FSLogixProfile -Source $script:AllProfiles -UserFilter @(,$txtFilter.Text) -AgeDays $ageDays -OnlyIssues:$chkOnlyIssues.Checked)

    Show-ProfilesInGrid $filtered
    $script:lblStatus.Text = "Filter: $($filtered.Count) user(s)"
    Add-LogMessage "Filter applied: $($filtered.Count) user(s) match" "INFO"
})

# Enter inside the filter box should apply the filter.
$txtFilter.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $btnApplyFilter.PerformClick()
        $_.Handled = $true
    }
})

$chkAge.Add_CheckedChanged({
    if ($script:AllProfiles -and $script:AllProfiles.Count -gt 0) { $btnApplyFilter.PerformClick() }
})
$chkOnlyIssues.Add_CheckedChanged({
    if ($script:AllProfiles -and $script:AllProfiles.Count -gt 0) { $btnApplyFilter.PerformClick() }
})
$numAge.Add_ValueChanged({
    if ($chkAge.Checked -and $script:AllProfiles -and $script:AllProfiles.Count -gt 0) { $btnApplyFilter.PerformClick() }
})

$chkHighlight.Add_CheckedChanged({ Refresh-RowHighlights })
$numHighlight.Add_ValueChanged({ Refresh-RowHighlights })

# Live/WhatIf changes the Reset button color immediately.
$chkWhatIf.Add_CheckedChanged({ Set-ResetButtonAppearance })

$cmbTheme.Add_SelectedIndexChanged({
    Apply-Theme $cmbTheme.SelectedItem.ToString()
})

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

# --------------------------------------------------------------------
#  Reset Profile (retire / rename) Selected
# --------------------------------------------------------------------
$btnDelete.Add_Click({
    if ($grid.SelectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No users selected. Click one or more rows first.")
        return
    }

    $whatIf       = $chkWhatIf.Checked
    $checkInUse   = $chkCheckInUse.Checked
    $showPreview  = $chkPreview.Checked
    $scope        = if ($chkDeleteOdfc.Checked) { 'Office' }
                    elseif ($chkDeleteProfile.Checked) { 'Profile' }
                    else { 'All' }

    $selectedProfiles = @()
    foreach ($row in $grid.SelectedRows) {
        if ($row.Tag) { $selectedProfiles += $row.Tag }
    }

    # Build the plan up front so the same numbers appear in preview and confirmation.
    $planTotal = 0
    foreach ($p in $selectedProfiles) {
        $plan = @(Get-FSLogixRetirePlan -ProfileObject $p -Scope $scope -CheckInUse:$checkInUse)
        $planTotal += $plan.Count
    }

    # 1. Preview dialog (optional)
    if ($showPreview) {
        $previewResult = Show-RenamePreviewDialog -SelectedProfiles $selectedProfiles -Scope $scope -WhatIf $whatIf -CheckInUse $checkInUse
        if ($previewResult -ne [System.Windows.Forms.DialogResult]::OK) {
            Add-LogMessage "Rename cancelled from preview dialog" "INFO"
            return
        }
    }

    # 2. Proportionate confirmation - always shown
    $confirmed = Show-ResetConfirmation -SelectedProfiles $selectedProfiles -ContainerCount $planTotal -WhatIf $whatIf -Scope $scope
    if (-not $confirmed) {
        Add-LogMessage "Rename cancelled at confirmation" "INFO"
        return
    }

    Add-LogMessage "Starting reset for $($selectedProfiles.Count) user(s), $planTotal container(s), mode=$scope, whatIf=$whatIf" "INFO"

    # Honour the GUI's own confirmation; never let the module's prompt fire.
    $WhatIfPreference = $whatIf
    $results = @()
    try {
        foreach ($obj in $selectedProfiles) {
            $r = Rename-FSLogixProfileObject -ProfileObject $obj -Scope $scope -CheckInUse:$checkInUse -Confirm:$false
            $results += $r
        }
    } finally {
        $WhatIfPreference = $false
    }

    # Aggregate counts and show them in the status bar and a result dialog.
    $totals = [PSCustomObject]@{
        Planned       = 0
        Renamed       = 0
        SkippedInUse  = 0
        SkippedExists = 0
        Missing       = 0
        Failed        = 0
        AbortedCount  = 0
        AbortReasons  = @()
        Logs          = @()
    }
    foreach ($r in $results) {
        $totals.Planned       += $r.Planned
        $totals.Renamed       += $r.Renamed
        $totals.SkippedInUse  += $r.SkippedInUse
        $totals.SkippedExists += $r.SkippedExists
        $totals.Missing       += $r.Missing
        $totals.Failed        += $r.Failed
        if ($r.Aborted) {
            $totals.AbortedCount++
            $totals.AbortReasons += "$($r.UserName): $($r.AbortReason)"
        }
        if ($r.LogPath) { $totals.Logs += $r.LogPath }
    }

    $modeName = if ($whatIf) { "WHATIF" } else { "LIVE" }
    $script:lblStatus.Text = "[$modeName] renamed $($totals.Renamed), in-use $($totals.SkippedInUse), exists $($totals.SkippedExists), missing $($totals.Missing), failed $($totals.Failed) (of $($totals.Planned) planned)"

    $resultText  = "Mode: $modeName`n`n"
    $resultText += "Planned:           $($totals.Planned)`n"
    $resultText += "Renamed:           $($totals.Renamed)`n"
    $resultText += "Skipped (in-use):  $($totals.SkippedInUse)`n"
    $resultText += "Skipped (exists):  $($totals.SkippedExists)`n"
    $resultText += "Missing:           $($totals.Missing)`n"
    $resultText += "Failed:            $($totals.Failed)`n"
    if ($totals.AbortedCount -gt 0) {
        $resultText += "`nAborted ($($totals.AbortedCount)):`n"
        foreach ($r in $totals.AbortReasons) { $resultText += "  $r`n" }
    }
    if ($totals.Logs.Count -gt 0) {
        $resultText += "`nLogs:`n"
        foreach ($l in $totals.Logs) { $resultText += "  $l`n" }
    }
    [System.Windows.Forms.MessageBox]::Show($resultText, "Reset Results - $modeName")

    # Don't pay a second full-share freeze for a WhatIf.
    if (-not $whatIf) {
        Load-Profiles
    } else {
        Add-LogMessage "Skipping rescan after WhatIf run." "INFO"
    }
})

$btnClose.Add_Click({ $form.Close() })

# --------------------------------------------------------------------
#  Apply initial theme and start
# --------------------------------------------------------------------
Apply-Theme "Light"

Add-LogMessage "FSLogix Profile Manager v$appVersion started" "INFO"
Add-LogMessage "Ready. Enter profile root path(s) and click 'Load Profiles'" "INFO"
Add-LogMessage "Enable 'Check AD' to detect orphaned profiles (requires AD connectivity)" "INFO"

[void]$form.ShowDialog()
