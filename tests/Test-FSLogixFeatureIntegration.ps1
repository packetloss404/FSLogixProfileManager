<# Cross-feature native host workflow: saved environment -> scan -> details -> audit search. #>
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with -STA.' }
Add-Type -AssemblyName System.Windows.Forms
$script:Checks = 0
function Check($Name, $Actual, $Expected) {
    if ("$Actual" -ne "$Expected") { throw "$Name : got '$Actual', expected '$Expected'" }
    $script:Checks++; Write-Host "  ok   $Name"
}
function Find-Control($Dialog, [string]$Name) {
    $found = $Dialog.Controls.Find($Name, $true)
    if ($found.Count -ne 1) { throw "Expected one control named $Name." }
    return $found[0]
}
$fixture = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('.feature-integration_' + [guid]::NewGuid().ToString('N'))))
$roots = Join-Path $fixture 'Profiles'
$audit = Join-Path $fixture 'Audit'
$envFile = Join-Path $fixture 'environments.json'
$sid = 'S-1-5-21-1-2-3-1001'; $otherSid = 'S-1-5-21-1-2-3-1002'
$script:DialogQueue = New-Object Collections.Queue
$script:DialogFailure = $null
try {
    foreach ($identity in @($sid, $otherSid)) {
        $directory = Join-Path $roots ('alice_' + $identity)
        [void][IO.Directory]::CreateDirectory($directory)
        $bytes = New-Object byte[] 4096
        [Text.Encoding]::ASCII.GetBytes('vhdxfile').CopyTo($bytes, 0)
        [IO.File]::WriteAllBytes((Join-Path $directory 'Profile_alice.vhdx'), $bytes)
    }
    [void][IO.Directory]::CreateDirectory($audit)
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixProfileGUI.ps1') -DefaultProfileRoot $roots -EnvironmentStorePath $envFile -InitializeOnly
    $form.ShowInTaskbar = $false; $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(-3000,-3000)
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    function Show-FSLogixMessage {
        param($Text, $Caption, $Buttons, $Icon, $DefaultButton)
        if ("$Buttons" -eq 'YesNo') { return [Windows.Forms.DialogResult]::Yes }
        return [Windows.Forms.DialogResult]::OK
    }
    function Show-FSLogixDialog {
        param([Windows.Forms.Form]$Dialog, [Windows.Forms.IWin32Window]$Owner)
        $Dialog.ShowInTaskbar = $false; $Dialog.StartPosition = 'Manual'; $Dialog.Location = New-Object Drawing.Point(-3000,-3000)
        $action = $null
        if ($script:DialogQueue.Count -gt 0 -and $script:DialogQueue.Peek().Kind -eq $Dialog.Name) { $action = $script:DialogQueue.Dequeue().Action }
        $driver = New-Object Windows.Forms.Timer
        $driver.Interval = 40
        $driver.Tag = @{Dialog=$Dialog;Action=$action;Ran=$false;Watch=[Diagnostics.Stopwatch]::StartNew()}
        $driver.Add_Tick({
            param($sender, $eventArgs)
            $state = $sender.Tag
            if ($state.Action -and -not $state.Ran) {
                $state.Ran = $true
                try { & $state.Action $state.Dialog } catch { $script:DialogFailure = $_; $state.Dialog.Close() }
            }
            if ($state.Watch.Elapsed.TotalSeconds -gt 20) { $script:DialogFailure = 'Dialog timeout: ' + $state.Dialog.Text; $state.Dialog.Close() }
        })
        $driver.Start()
        try { if ($Owner) { $result = $Dialog.ShowDialog($Owner) } else { $result = $Dialog.ShowDialog() } }
        finally { $driver.Stop(); $driver.Dispose() }
        if ($script:DialogFailure) { throw $script:DialogFailure }
        return $result
    }

    Set-FSLogixAuditRoot -Path $audit
    $live = Join-Path $roots ('alice_' + $sid + '\Profile_alice.vhdx')
    foreach ($resultName in @('STARTED','OK')) {
        Write-FSLogixAudit -Critical -Record @{Action='RETIRE';Mode='LIVE';Reason='CHG[42] cross-feature';TargetUser='alice';TargetSid=$sid;SourcePath=$live;Result=$resultName}
    }
    Write-FSLogixAudit -Critical -Record @{Action='RETIRE';Mode='LIVE';Reason='Other identity';TargetUser='alice';TargetSid=$otherSid;SourcePath=(Join-Path $roots ('alice_' + $otherSid + '\Profile_alice.vhdx'));Result='OK'}
    $auditFile = (Get-ChildItem -LiteralPath $audit -Filter 'actions_*.csv')[0].FullName
    $auditHash = (Get-FileHash -LiteralPath $auditFile).Hash
    $liveHash = (Get-FileHash -LiteralPath $live).Hash
    Check 'details disabled without selected identity' $btnDetails.Enabled $false
    [void](Save-FSLogixEnvironment -Name 'Integration lab' -Settings (Get-FSLogixEnvironmentUIState) -Path $envFile)
    [void](Update-FSLogixEnvironmentSelector -SelectedName 'Integration lab')
    $chkWhatIf.Checked = $false; $txtReason.Text = 'must clear'
    $script:EnvironmentApplyButton.PerformClick()
    Check 'environment Apply restores WhatIf' $chkWhatIf.Checked $true
    Check 'environment Apply clears reason' $txtReason.Text ''
    Check 'environment Apply does not scan' $grid.Rows.Count 0
    Check 'environment Apply keeps Reset disabled' $btnDelete.Enabled $false
    Check 'environment Apply selects its audit destination' (Get-FSLogixAuditRoot) $audit
    $btnLoad.PerformClick()
    Check 'saved roots load two same-name SID identities' $grid.Rows.Count 2
    $aliceRow = $grid.Rows | Where-Object {$_.Tag.Sid -eq $sid}
    $grid.ClearSelection(); $aliceRow.Selected = $true
    [Windows.Forms.Application]::DoEvents()
    Check 'single selection enables actual Details button' $btnDetails.Enabled $true
    $script:DialogQueue.Enqueue(@{Kind='ProfileDetailsDialog';Action={
        param($dialog)
        Check 'host Details button opens selected SID' $dialog.Tag.Snapshot.Sid $sid
        Check 'details contains exactly selected identity live file' $dialog.Tag.LiveGrid.Rows.Count 1
        Check 'details includes intent and completion' $dialog.Tag.HistoryGrid.Rows.Count 2
        Check 'details does not probe availability on open' $dialog.Tag.Snapshot.AvailabilityStatus 'NotChecked'
        (Find-Control $dialog 'DetailsOpenHistory').PerformClick()
        $dialog.CancelButton.PerformClick()
    }})
    $script:DialogQueue.Enqueue(@{Kind='AuditHistoryDialog';Action={
        param($dialog)
        Check 'details history link carries exact SID' (Find-Control $dialog 'AuditSidFilter').Text $sid
        Check 'linked history excludes same-name other SID' (Find-Control $dialog 'AuditHistoryGrid').Rows.Count 2
        $dialog.CancelButton.PerformClick()
    }})
    $btnDetails.PerformClick()
    $script:DialogQueue.Enqueue(@{Kind='AuditHistoryDialog';Action={
        param($dialog)
        Check 'global history starts with all records' (Find-Control $dialog 'AuditHistoryGrid').Rows.Count 3
        (Find-Control $dialog 'AuditReasonFilter').Text = 'CHG[42]'
        (Find-Control $dialog 'AuditApply').PerformClick()
        Check 'global history literal ticket search' (Find-Control $dialog 'AuditHistoryGrid').Rows.Count 2
        $dialog.CancelButton.PerformClick()
    }})
    $btnAuditHistory.PerformClick()
    $script:DialogQueue.Enqueue(@{Kind='ProfileDetailsDialog';Action={
        param($dialog)
        Check 'double-click opens clicked SID' $dialog.Tag.Snapshot.Sid $otherSid
        $dialog.CancelButton.PerformClick()
    }})
    $otherRow = $grid.Rows | Where-Object {$_.Tag.Sid -eq $otherSid}
    $eventArgs = [Windows.Forms.DataGridViewCellEventArgs]::new(0, $otherRow.Index)
    $method = [Windows.Forms.DataGridView].GetMethod('OnCellDoubleClick', [Reflection.BindingFlags]'Instance,NonPublic')
    [void]$method.Invoke($grid, @($eventArgs))
    Check 'every expected modal action executed' $script:DialogQueue.Count 0
    Check 'details/history preserve profile bytes' (Get-FileHash -LiteralPath $live).Hash $liveHash
    Check 'details/history preserve audit bytes' (Get-FileHash -LiteralPath $auditFile).Hash $auditHash
    Check 'read-only inspection creates no retirement' (Test-Path -LiteralPath (Join-Path $roots '_retired')) $false
    Write-Host "ALL $script:Checks FEATURE INTEGRATION CHECKS PASSED"
} finally {
    if (Get-Variable form -ErrorAction SilentlyContinue) { if ($form -and -not $form.IsDisposed) { $form.Close(); $form.Dispose() } }
    $prefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    if ($fixture.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $fixture) -like '.feature-integration_*') {
        Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction Stop
    }
}
