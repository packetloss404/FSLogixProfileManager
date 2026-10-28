<# Real WinForms details dialog tests; local files and message-loop control interaction. #>
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with -STA.' }
$script:checks = 0
function Check($Name, $Actual, $Expected) {
    if ("$Actual" -ne "$Expected") { throw "$Name : got '$Actual', expected '$Expected'" }
    $script:checks++; Write-Host "  ok   $Name"
}
$fixture = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('.details-ui_' + [guid]::NewGuid().ToString('N'))))
$script:NextDialogAction = $null; $script:DialogFailure = $null
try {
    $root = Join-Path $fixture 'profiles'; $audit = Join-Path $fixture 'audit'
    $userDirectory = Join-Path $root 'alice_S-1-5-21-5-6-7-1001'
    [void][IO.Directory]::CreateDirectory($userDirectory); [void][IO.Directory]::CreateDirectory($audit)
    $live = Join-Path $userDirectory 'Profile_alice.vhdx'
    $office = Join-Path $userDirectory 'ODFC_alice.vhdx'
    $retired = Join-Path $userDirectory 'Profile_alice-old-20200101-000000.vhdx'
    $bytes = New-Object byte[] 4096; [Text.Encoding]::ASCII.GetBytes('vhdxfile').CopyTo($bytes,0)
    foreach ($path in @($live,$office,$retired)) { [IO.File]::WriteAllBytes($path,$bytes) }
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixProfileGUI.ps1') -DefaultProfileRoot $root -EnvironmentStorePath (Join-Path $fixture 'environments.json') -InitializeOnly
    $form.ShowInTaskbar = $false; $form.StartPosition = 'Manual'; $form.Location = [Drawing.Point]::new(-3000,-3000)
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    Set-FSLogixAuditRoot $audit
    Write-FSLogixAudit -Record @{Action='RETIRE';Mode='LIVE';Reason="CHG555`r`nLong reason with quoted `"values`"";TargetUser='alice';TargetSid='S-1-5-21-5-6-7-1001';SourcePath=$live;DestPath=$retired;Result='OK'}
    function Show-FSLogixMessage { param($Text,$Caption,$Buttons,$Icon,$DefaultButton) return [Windows.Forms.DialogResult]::No }
    function Show-FSLogixDialog {
        param([Windows.Forms.Form]$Dialog, [Windows.Forms.IWin32Window]$Owner)
        $Dialog.ShowInTaskbar = $false; $Dialog.StartPosition = 'Manual'; $Dialog.Location = [Drawing.Point]::new(-3000,-3000)
        $timer = [Windows.Forms.Timer]::new(); $timer.Interval = 40
        $timer.Tag = @{Dialog=$Dialog;Action=$script:NextDialogAction;Ran=$false;Watch=[Diagnostics.Stopwatch]::StartNew()}
        $script:NextDialogAction = $null; $script:DialogFailure = $null
        $timer.Add_Tick({
            param($sender,$eventArgs)
            $state = $sender.Tag
            if ($state.Action -and -not $state.Ran) {
                $state.Ran = $true
                try { & $state.Action $state.Dialog } catch { $script:DialogFailure=$_; $state.Dialog.Close() }
            }
            if ($state.Watch.Elapsed.TotalSeconds -gt 20) { $script:DialogFailure='Details test dialog timed out'; $state.Dialog.Close() }
        })
        $timer.Start()
        try { if ($Owner) { $result=$Dialog.ShowDialog($Owner) } else { $result=$Dialog.ShowDialog() } }
        finally { $timer.Stop(); $timer.Dispose() }
        if ($script:DialogFailure) { throw $script:DialogFailure }
        return $result
    }
    $rows = Get-FSLogixProfiles -ProfileRoots (Split-Path -Parent $userDirectory)
    Check 'GUI log handler cannot corrupt profile array' $rows.Count 1
    $profileRow = $rows[0]
    $beforeBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($live))
    $auditFile = @(Get-ChildItem -LiteralPath $audit -Filter actions_*.csv)[0].FullName
    $beforeAudit = [IO.File]::ReadAllText($auditFile)
    $cmbTheme.SelectedItem = 'Dark'
    $script:CapturedHistory = $null
    function Show-FSLogixAuditHistoryDialog {
        param($AuditRoot,$Sid,$User)
        $script:CapturedHistory = @{AuditRoot=$AuditRoot;Sid=$Sid;User=$User}
    }
    $script:NextDialogAction = {
        param($dialog)
        $state = $dialog.Tag
        Check 'details title identifies selected user' $dialog.Text 'User details - alice'
        Check 'details uses selected dark theme' $dialog.BackColor.ToArgb() $script:Themes.Dark.FormBackColor.ToArgb()
        Check 'details form is resizable' $dialog.FormBorderStyle 'Sizable'
        Check 'details has four actual tabs' $dialog.Controls.Find('DetailsTabs',$true)[0].TabPages.Count 4
        Check 'live grid contains both physical files' $state.LiveGrid.Rows.Count 2
        Check 'retired grid contains matching backup' $state.RetiredGrid.Rows.Count 1
        Check 'history grid contains real audit record' $state.HistoryGrid.Rows.Count 1
        Check 'unconfigured sessions grid is empty' $state.SessionGrid.Rows.Count 0
        Check 'availability begins unqueried' $state.Snapshot.AvailabilityStatus 'NotChecked'
        Check 'initial Horizon status is explicit' ($state.SummaryLabel.Text -match 'Horizon: NotConfigured') $true
        Check 'metadata origin is visible' ($state.SummaryLabel.Text -match 'from the profile scan') $true
        Check 'all grids are readonly' (@(@($state.LiveGrid,$state.RetiredGrid,$state.HistoryGrid,$state.SessionGrid) | Where-Object {-not $_.ReadOnly}).Count) 0
        Check 'row insertion disabled' (@(@($state.LiveGrid,$state.RetiredGrid,$state.HistoryGrid,$state.SessionGrid) | Where-Object AllowUserToAddRows).Count) 0
        Check 'close button fits footer' ($dialog.Controls.Find('DetailsClose',$true)[0].Bottom -le $dialog.Controls.Find('DetailsClose',$true)[0].Parent.ClientSize.Height) $true
        $state.LiveGrid.Rows[0].Selected = $true
        Check 'selected live file exposes full path' ($state.DetailText.Text.Contains($state.LiveGrid.Rows[0].Tag.Path)) $true
        $tabs = $dialog.Controls.Find('DetailsTabs',$true)[0]; $tabs.SelectedIndex=2
        $state.HistoryGrid.Rows[0].Selected = $true
        Check 'selected history exposes multiline reason' ($state.DetailText.Text -match 'CHG555' -and $state.DetailText.Text -match 'Long reason') $true
        Check 'selected history exposes destination' ($state.DetailText.Text.Contains($script:TestRetiredPath)) $true
        $state.RefreshButton.PerformClick()
        Check 'refresh button uses actual local lock probe' (($state.Snapshot.Containers | Where-Object Path -eq $script:TestLivePath).Availability) 'InUse'
        Check 'refresh returns to usable controls' $state.RefreshButton.Enabled $true
        Check 'refresh describes best effort checks' $state.Snapshot.AvailabilityStatus 'Refreshed (best effort)'
        $dialog.Controls.Find('DetailsOpenHistory',$true)[0].PerformClick()
        Check 'open history uses exact stable SID' $script:CapturedHistory.Sid 'S-1-5-21-5-6-7-1001'
        Check 'open history retains audit environment' $script:CapturedHistory.AuditRoot $script:TestAuditRoot
        Check 'known SID history link avoids broad username filter' ([string]::IsNullOrWhiteSpace($script:CapturedHistory.User)) $true
        $dialog.CancelButton.PerformClick()
    }
    $script:TestLivePath=$live; $script:TestRetiredPath=$retired; $script:TestAuditRoot=$audit
    $locked = [IO.File]::Open($live,'Open','ReadWrite','None')
    try { Show-FSLogixProfileDetailsDialog -ProfileObject $profileRow -AuditRoot $audit } finally { $locked.Dispose() }
    Check 'dialog never changes live bytes' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($live))) $beforeBytes
    Check 'dialog never changes audit file' ([IO.File]::ReadAllText($auditFile)) $beforeAudit

    $script:NextDialogAction = {
        param($dialog)
        Check 'unavailable audit source shown explicitly' $dialog.Tag.Snapshot.AuditStatus 'Unavailable'
        Check 'unavailable audit error remains readable' ($dialog.Tag.DetailText.Text -match 'Audit history unavailable') $true
        Check 'no rows presented as successful history' $dialog.Tag.HistoryGrid.Rows.Count 0
        $dialog.CancelButton.PerformClick()
    }
    [IO.File]::WriteAllText($auditFile,'invalid audit header')
    Show-FSLogixProfileDetailsDialog -ProfileObject $profileRow -AuditRoot $audit
    Write-Host "ALL $script:checks NATIVE PROFILE DETAILS CHECKS PASSED"
} finally {
    if (Get-Variable form -ErrorAction SilentlyContinue) { $form.Close(); $form.Dispose() }
    $prefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\.details-ui_'
    if ($fixture.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}
