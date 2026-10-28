<#
Native WinForms workflow tests. Run with Windows PowerShell 5.1 in STA mode:
  powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Test-FSLogixProfileGUI.ps1
Uses actual controls, modal forms, background runspaces and a temporary local
profile tree. Message-box answers are supplied at the presentation seam; AD,
SMB server queries, Horizon, Hyper-V and production shares are not exercised.
#>
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run GUI tests with -STA.' }
$script:Checks = 0
function Check([string]$Name, $Actual, $Expected) {
    if ("$Actual" -ne "$Expected") { throw "$Name : got '$Actual', expected '$Expected'" }
    $script:Checks++
    Write-Host "  ok   $Name"
}
# Keep fixture mutations in the workspace. Some restricted Windows hosts redirect
# TEMP to an AppContainer path that .NET Framework File.Move cannot access.
$testRoot = Join-Path $PSScriptRoot ('.gui-fixture_' + [guid]::NewGuid().ToString('N'))
$testRoot = [IO.Path]::GetFullPath($testRoot)
[void](New-Item -ItemType Directory -Path $testRoot)
$script:Messages = [Collections.ArrayList]::new()
$script:DialogFailure = $null
$script:NextDialogAction = $null

function New-TestContainer([string]$User, [int]$Rid, [string]$Name, [int]$Age = 0) {
    $directory = Join-Path $testRoot ($User + '_S-1-5-21-100-200-300-' + $Rid)
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $path = Join-Path $directory $Name
    $bytes = New-Object byte[] 4096
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('vhdxfile'), $bytes, 8)
    [IO.File]::WriteAllBytes($path, $bytes)
    (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-$Age)
    return $path
}

try {
    $aliceProfile = New-TestContainer 'alice' 1001 'Profile_alice.vhdx' 100
    $aliceOffice = New-TestContainer 'alice' 1001 'ODFC_alice.vhdx' 100
    [void](New-TestContainer 'bob' 1002 'Profile_bob.vhdx')
    [void](New-TestContainer 'bob' 1003 'Profile_bob.vhdx')
    [void](New-TestContainer 'bob' 1004 'Profile_bob.vhdx')
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixProfileGUI.ps1') -DefaultProfileRoot $testRoot -EnvironmentStorePath (Join-Path $testRoot 'environments.json') -InitializeOnly

    # The app still constructs and shows real controls. Keep its window out of
    # the operator's way while PerformClick raises the production event handlers.
    $form.ShowInTaskbar = $false
    $form.StartPosition = 'Manual'
    $form.Location = [Drawing.Point]::new(-3000, -3000)
    $form.Show()
    [Windows.Forms.Application]::DoEvents()
    Set-FSLogixAuditRoot -Path (Join-Path $testRoot 'audit')

    function Show-FSLogixMessage {
        param([string]$Text, [string]$Caption = '', $Buttons = 'OK', $Icon = 'None', $DefaultButton = 'Button1')
        [void]$script:Messages.Add([pscustomobject]@{Text=$Text;Caption=$Caption;Buttons="$Buttons";DefaultButton="$DefaultButton"})
        if ("$Buttons" -eq 'YesNo') { return [Windows.Forms.DialogResult]::Yes }
        return [Windows.Forms.DialogResult]::OK
    }
    function Show-FSLogixDialog {
        param([Windows.Forms.Form]$Dialog, [Windows.Forms.IWin32Window]$Owner)
        $Dialog.ShowInTaskbar = $false
        $Dialog.StartPosition = 'Manual'
        $Dialog.Location = [Drawing.Point]::new(-3000, -3000)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $driver = [Windows.Forms.Timer]::new()
        $driver.Interval = 50
        $driver.Tag = @{Dialog=$Dialog;Action=$script:NextDialogAction;Watch=$watch;Ran=$false}
        $script:NextDialogAction = $null
        $script:DialogFailure = $null
        $driver.Add_Tick({
            param($sender, $eventArgs)
            $state = $sender.Tag
            if ($state.Action -and -not $state.Ran) {
                $state.Ran = $true
                try { & $state.Action $state.Dialog }
                catch { $script:DialogFailure = $_; $state.Dialog.Close() }
            }
            if ($state.Watch.Elapsed.TotalSeconds -gt 20) {
                $script:DialogFailure = 'Native dialog timed out: ' + $state.Dialog.Text
                $state.Dialog.Close()
            }
        })
        $driver.Start()
        try {
            if ($Owner) { $result = $Dialog.ShowDialog($Owner) } else { $result = $Dialog.ShowDialog() }
        } finally { $driver.Stop(); $driver.Dispose() }
        if ($script:DialogFailure) { throw $script:DialogFailure }
        return $result
    }

    $script:NextDialogAction = {
        param($dialog)
        Check 'settings Save button fits inside client area' ($dialog.AcceptButton.Bottom -le $dialog.ClientSize.Height) $true
        ($dialog.Controls | Where-Object {$_ -is [Windows.Forms.TextBox]}).Text = Join-Path $testRoot 'audit'
        $dialog.AcceptButton.PerformClick()
    }
    $btnSettings.PerformClick()
    Check 'settings saves audit root through actual controls' (Get-FSLogixAuditRoot) (Join-Path $testRoot 'audit')
    $script:NextDialogAction = {
        param($dialog)
        $password = $dialog.Controls | Where-Object {$_ -is [Windows.Forms.TextBox] -and $_.UseSystemPasswordChar}
        Check 'Horizon dialog masks password' (@($password).Count) 1
        Check 'Horizon TLS bypass defaults off' ($dialog.Controls | Where-Object {$_ -is [Windows.Forms.CheckBox]}).Checked $false
        Check 'Horizon Connect button fits client area' ($dialog.AcceptButton.Bottom -le $dialog.ClientSize.Height) $true
        $dialog.CancelButton.PerformClick()
    }
    $btnHorizon.PerformClick()
    Check 'cancelling Horizon dialog leaves it disconnected' (Test-FSLogixHorizonConnected) $false

    Check 'WhatIf default' $chkWhatIf.Checked $true
    Check 'in-use check default' $chkCheckInUse.Checked $true
    Check 'move-to-retired default' $chkMoveRetired.Checked $true
    Check 'preview default' $chkPreview.Checked $true
    Check 'unlimited log control' $txtLog.MaxLength 0
    Check 'reset starts disabled before a successful scan' $btnDelete.Enabled $false
    $btnLoad.PerformClick()
    Check 'background scan returns four distinct SID identities' $grid.Rows.Count 4
    Check 'background scan releases pipeline' ($null -eq $script:ScanState.PowerShell) $true
    Check 'load does not implicitly select a user' $grid.SelectedRows.Count 0
    Check 'scan aggregates profile and Office containers' $script:AllProfiles[0].ContainerCount 2
    Check 'scan keeps same-named SID identities separate' (@($script:AllProfiles | Where-Object UserName -eq 'bob').Count) 3

    $headerEvent = [Windows.Forms.DataGridViewCellMouseEventArgs]::new(0,-1,0,0,[Windows.Forms.MouseEventArgs]::new('Left',1,0,0,0))
    $headerMethod = [Windows.Forms.DataGridView].GetMethod('OnColumnHeaderMouseClick',[Reflection.BindingFlags]'Instance,NonPublic')
    [void]$headerMethod.Invoke($grid,@($headerEvent))
    [void]$headerMethod.Invoke($grid,@($headerEvent))
    Check 'header click sorts descending' $grid.Rows[0].Tag.UserName 'bob'
    $txtFilter.Text = 'o'; $btnApplyFilter.PerformClick()
    Check 'substring filter' $grid.Rows.Count 3
    $txtFilter.Text = ''; $btnApplyFilter.PerformClick()
    Check 'filter repaint retains actual descending order' $grid.Rows[0].Tag.UserName 'bob'
    Check 'sort glyph matches descending order' $grid.Columns[0].HeaderCell.SortGlyphDirection 'Descending'
    $txtFilter.Text = '['; $btnApplyFilter.PerformClick()
    Check 'literal bracket filter safely produces no matches' $grid.Rows.Count 0
    $txtFilter.Text = ''; $btnApplyFilter.PerformClick()
    $numAge.Value = 60; $chkAge.Checked = $true
    Check 'disk-age filter' $grid.Rows.Count 1
    Check 'disk-age filter selects old user' $grid.Rows[0].Tag.UserName 'alice'
    $chkAge.Checked = $false
    $script:AllProfiles[0].ADLastLogon = (Get-Date).AddDays(-100)
    $script:AllProfiles[1].ADLastLogon = (Get-Date)
    $numADAge.Value = 60; $chkADAge.Checked = $true
    Check 'AD-age control filters supplied AD timestamps' $grid.Rows.Count 1
    $chkADAge.Checked = $false
    [void]$script:AllProfiles[0].HealthIssues.Add('CORRUPT')
    $chkOnlyIssues.Checked = $true
    Check 'issues-only includes supplied health warning' (@($grid.Rows | Where-Object {$_.Tag.UserName -eq 'alice'}).Count) 1
    $chkOnlyIssues.Checked = $false

    # Exercise truncation/export with a real grid row carrying three SID values.
    # Discovery itself deliberately keeps distinct known SIDs in separate rows.
    $exportProfile = $script:AllProfiles[1].PSObject.Copy()
    $exportProfile.SIDs = @('S-1-5-21-100-200-300-1002','S-1-5-21-100-200-300-1003','S-1-5-21-100-200-300-1004')
    Show-ProfilesInGrid @($exportProfile)
    $grid.Columns[7].DisplayIndex = 0
    $csvPath = Join-Path $testRoot 'export.csv'
    Export-GridToCSV -Grid $grid -FilePath $csvPath
    $exported = Import-Csv -LiteralPath $csvPath
    Check 'CSV follows reordered column headers' ($exported[0].PSObject.Properties.Name[0]) 'SIDs'
    Check 'CSV exports every SID' (($exported | Where-Object User -eq 'bob').SIDs.Split(';').Count) 3
    Check 'CSV excludes truncated display marker' (($exported | Where-Object User -eq 'bob').SIDs -match '\+\d+ more') $false
    $btnApplyFilter.PerformClick()

    $grid.ClearSelection()
    $selectedSid = $grid.Rows[0].Tag.Sid
    $grid.Rows[0].Selected = $true
    $btnApplyFilter.PerformClick()
    Check 'repaint preserves exactly one SID selection among equal names' $grid.SelectedRows.Count 1
    Check 'repaint preserves the selected SID' $grid.SelectedRows[0].Tag.Sid $selectedSid

    $chkWhatIf.Checked = $false
    Check 'live button immediately warns' ($btnDelete.Text -match 'LIVE') $true
    $cmbTheme.SelectedItem = 'Dark'
    Check 'theme control switches real form palette' $form.BackColor.ToArgb() $script:Themes.Dark.FormBackColor.ToArgb()
    Check 'theme keeps live button red' $btnDelete.BackColor.ToArgb() $script:Themes.Dark.LiveButtonColor.ToArgb()
    $alice = $script:AllProfiles | Where-Object UserName -eq 'alice'
    [void]$alice.HealthIssues.Add('CORRUPT')
    Refresh-RowHighlights
    $aliceRow = $grid.Rows | Where-Object {$_.Tag.UserName -eq 'alice'}
    Check 'health color wins over size in dark theme' $aliceRow.DefaultCellStyle.BackColor.ToArgb() $script:Themes.Dark.HealthCorrupt.ToArgb()
    $cmbTheme.SelectedItem = 'Light'
    Check 'health color follows theme changes' $aliceRow.DefaultCellStyle.BackColor.ToArgb() $script:Themes.Light.HealthCorrupt.ToArgb()
    $grid.ClearSelection(); $aliceRow.Selected = $true
    $btnDelete.PerformClick()
    Check 'live run requires reason' $script:Messages[$script:Messages.Count-1].Caption 'Reason required'
    Check 'missing reason leaves profile untouched' (Test-Path -LiteralPath $aliceProfile) $true
    $chkWhatIf.Checked = $true

    $script:NextDialogAction = {
        param($dialog)
        $list = $dialog.Controls | Where-Object {$_ -is [Windows.Forms.ListView]}
        Check 'preview contains each physical container' $list.Items.Count 2
        Check 'preview default action is Cancel' $dialog.AcceptButton.Text 'Cancel'
        Check 'preview shows a real target path' ([string]::IsNullOrWhiteSpace($list.Items[0].SubItems[3].Text)) $false
        $dialog.AcceptButton.PerformClick()
    }
    $previewResult = Show-RenamePreviewDialog -SelectedProfiles @($alice) -WhatIf $true -CheckInUse $true -MoveToRetired $true
    Check 'preview Cancel closes without proceeding' $previewResult 'Cancel'

    $script:NextDialogAction = {
        param($dialog)
        $confirm = $dialog.Controls | Where-Object Text -eq 'Confirm'
        $count = $dialog.Controls | Where-Object {$_ -is [Windows.Forms.TextBox]}
        Check 'large confirmation disabled until count typed' $confirm.Enabled $false
        $count.Text = 'wrong'
        Check 'incorrect typed count cannot confirm' $confirm.Enabled $false
        $count.Text = '21'
        Check 'correct typed count enables confirmation' $confirm.Enabled $true
        $dialog.CancelButton.PerformClick()
    }
    Check 'large confirmation Cancel' (Show-ResetConfirmation -SelectedProfiles @($alice) -ContainerCount 21 -WhatIf $false) $false

    $chkPreview.Checked = $false
    $btnDelete.PerformClick()
    Check 'WhatIf reset preserves source profile' (Test-Path -LiteralPath $aliceProfile) $true
    Check 'WhatIf reset preserves Office source' (Test-Path -LiteralPath $aliceOffice) $true
    Check 'WhatIf creates no retirement directory or manifests' (Test-Path -LiteralPath (Join-Path $testRoot '_retired')) $false
    Check 'WhatIf confirmation reports two planned targets' (($script:Messages | Where-Object Caption -like 'Confirm Reset*' | Select-Object -Last 1).Text -match 'Containers: 2') $true
    Check 'small confirmation defaults to No' (($script:Messages | Where-Object Caption -like 'Confirm Reset*' | Select-Object -Last 1).DefaultButton) 'Button2'
    Check 'WhatIf does not rescan' ($script:LogMessages[$script:LogMessages.Count-1] -match 'Skipping rescan') $true

    $chkDeleteOdfc.Checked = $true
    $chkDeleteProfile.Checked = $true
    Check 'scope toggles are mutually exclusive' $chkDeleteOdfc.Checked $false
    $chkDeleteProfile.Checked = $false
    $txtReason.Text = 'GUI automated local lifecycle'
    $chkWhatIf.Checked = $false
    $btnDelete.PerformClick()
    Check 'live GUI reset moves Profile file' (Test-Path -LiteralPath $aliceProfile) $false
    Check 'live GUI reset moves Office file' (Test-Path -LiteralPath $aliceOffice) $false
    Check 'live reset rescans without nesting arrays' $grid.Rows.Count 4

    $script:NextDialogAction = {
        param($dialog)
        $retiredGrid = $dialog.Controls | Where-Object {$_ -is [Windows.Forms.DataGridView]}
        Check 'retired dialog shows separate container rows' $retiredGrid.Rows.Count 2
        Check 'retired dialog has readable headers' $retiredGrid.Columns[0].HeaderText 'User'
        Check 'retired rows contain actual container objects' $retiredGrid.Rows[0].Tag.UserName 'alice'
        $retiredGrid.ClearSelection()
        foreach ($row in $retiredGrid.Rows) { $row.Selected = $true }
        ($dialog.Controls | Where-Object Text -eq 'Purge...').PerformClick()
        Check 'retired purge respects 90-day floor' $retiredGrid.Rows.Count 2
        $retiredGrid.ClearSelection()
        foreach ($row in $retiredGrid.Rows) { $row.Selected = $true }
        $lockedRetirement = [IO.File]::Open($retiredGrid.Rows[0].Tag.Path, 'Open', 'Read', 'None')
        try {
            ($dialog.Controls | Where-Object Text -eq 'Restore...').PerformClick()
            Check 'locked retirement abort leaves entire batch retired' $retiredGrid.Rows.Count 2
            Check 'restore preflight failure displays an abort reason' ($script:Messages[$script:Messages.Count-1].Text -match 'Aborted: .+') $true
        } finally { $lockedRetirement.Dispose() }
        $retiredGrid.ClearSelection()
        foreach ($row in $retiredGrid.Rows) { $row.Selected = $true }
        ($dialog.Controls | Where-Object Text -eq 'Restore...').PerformClick()
        Check 'retired refresh after restore is empty' $retiredGrid.Rows.Count 0
        $dialog.CancelButton.PerformClick()
    }
    $btnRetired.PerformClick()
    Check 'GUI restore returns Profile to original directory' (Test-Path -LiteralPath $aliceProfile) $true
    Check 'GUI restore returns Office to original directory' (Test-Path -LiteralPath $aliceOffice) $true

    $script:NextDialogAction = {
        param($dialog)
        ($dialog.Controls | Where-Object Text -eq 'Cancel').PerformClick()
    }
    $btnRescan.PerformClick()
    Check 'scan cancellation releases runspace' ($null -eq $script:ScanState.PowerShell) $true
    Check 'scan cancellation re-enables load' $btnLoad.Enabled $true
    Check 'scan cancellation keeps reset disabled' $btnDelete.Enabled $false
    $btnLoad.PerformClick()
    Check 'scan works after cancellation' $grid.Rows.Count 4
    Check 'successful scan re-enables reset' $btnDelete.Enabled $true
    Check 'rescan retains chosen sort order' $grid.Rows[0].Tag.UserName 'bob'

    $missingRoot = Join-Path $testRoot 'missing-provider'
    $txtRoot.Text = $testRoot + ';' + $missingRoot
    Check 'changing provider configuration disables stale reset selection' $btnDelete.Enabled $false
    $btnLoad.PerformClick()
    Check 'missing provider validation preserves previous rows' $grid.Rows.Count 4
    Check 'missing provider validation disables reset' $btnDelete.Enabled $false
    Check 'missing provider is reported to operator' $script:Messages[$script:Messages.Count-1].Caption 'Scan incomplete'
    # Exercise the background strict-scan path too, bypassing prevalidation to
    # model a provider disappearing between validation and enumeration.
    Start-BackgroundScan -Roots @($testRoot,$missingRoot) -CheckOrphans $false
    Check 'incomplete background scan preserves previous rows' $grid.Rows.Count 4
    Check 'incomplete background scan cannot reset partial results' $btnDelete.Enabled $false
    Check 'incomplete background scan visibly logs error' (($script:LogMessages -join "`n") -match '\[ERROR\].*Scan failed:') $true
    $txtRoot.Text = $testRoot
    $btnLoad.PerformClick()
    Check 'complete scan recovers from missing-provider failure' $btnDelete.Enabled $true

    # Real empty and singleton scans pin the collection/runspace boundary cases.
    $emptyRoot = Join-Path $testRoot 'empty'
    [void](New-Item -ItemType Directory -Path $emptyRoot)
    $txtRoot.Text = $emptyRoot
    $btnLoad.PerformClick()
    Check 'empty background scan renders zero rows' $grid.Rows.Count 0
    $txtRoot.Text = Split-Path -Parent $aliceProfile
    $btnLoad.PerformClick()
    Check 'single identity background scan renders one row' $grid.Rows.Count 1
    Check 'single identity scan retains both containers' $grid.Rows[0].Tag.ContainerCount 2
    $txtRoot.Text = $testRoot
    $btnLoad.PerformClick()

    # Pin the native Reset event's integration options without contacting a
    # Horizon server. Earlier checks executed the real module/file lifecycle.
    function Test-FSLogixHorizonConnected { return $true }
    function Rename-FSLogixProfileObject {
        param($ProfileObject, $Scope, [bool]$CheckInUse, $Reason, [bool]$MoveToRetired,
            [switch]$AllOrNothing, [bool]$RequireHorizonCheck, [switch]$WhatIf, [bool]$Confirm)
        $script:CapturedReset = @{AllOrNothing=[bool]$AllOrNothing;RequireHorizonCheck=$RequireHorizonCheck;WhatIf=[bool]$WhatIf;Scope=$Scope}
        return [pscustomobject]@{Planned=1;Renamed=0;SkippedInUse=0;SkippedExists=0;Missing=0;Failed=0;Aborted=$false;LogPath=$null}
    }
    $grid.ClearSelection()
    ($grid.Rows | Where-Object {$_.Tag.UserName -eq 'alice'}).Selected = $true
    $chkWhatIf.Checked = $true
    $chkDeleteOdfc.Checked = $true
    $btnDelete.PerformClick()
    Check 'Reset event enables all-or-nothing safety' $script:CapturedReset.AllOrNothing $true
    Check 'Reset event requires connected Horizon gate' $script:CapturedReset.RequireHorizonCheck $true
    Check 'Reset event passes WhatIf explicitly into module' $script:CapturedReset.WhatIf $true
    Check 'Office scope reaches module through Reset event' $script:CapturedReset.Scope 'Office'
    $btnClearLog.PerformClick()
    Check 'clear log empties actual text control' $txtLog.TextLength 0
    Write-Host "PASS: $script:Checks native GUI checks"
} catch {
    if ($script:LogMessages) { $script:LogMessages | Select-Object -Last 12 | ForEach-Object { Write-Host $_ } }
    if ($script:Messages.Count) { Write-Host $script:Messages[$script:Messages.Count-1].Text }
    throw
} finally {
    if (Get-Variable form -ErrorAction SilentlyContinue) { $form.Close(); $form.Dispose() }
    $fixturePrefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\.gui-fixture_'
    if ($testRoot.StartsWith($fixturePrefix,[StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
