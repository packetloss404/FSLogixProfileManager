#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run native GUI tests with -STA.' }
$script:checks = 0
function Assert([string]$Name, [bool]$Condition) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:checks++; Write-Host "  ok   $Name"
}
$fixture = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('.audit-gui-fixture_' + [guid]::NewGuid().ToString('N'))))
$script:DialogAction = $null; $script:DialogFailure = $null; $script:LastDialog = $null
try {
    [void][IO.Directory]::CreateDirectory($fixture)
    $audit = Join-Path $fixture 'audit'; [void][IO.Directory]::CreateDirectory($audit)
    function New-Row($Time, $User, $Sid, $Action, $Result, $Reason) {
        [pscustomobject]@{
            TimestampUtc=$Time;TargetUser=$User;TargetSid=$Sid;Action=$Action;Result=$Result;Reason=$Reason
            Actor='LAB\operator';ActorHost='desktop';Mode='LIVE';SourcePath='D:\full source\Profile.vhdx';DestPath='D:\full destination\Profile-old.vhdx'
        }
    }
    $longReason = 'CHG42 [literal] ' + ('A detailed explanation ' * 15) + "`r`nSecond line."
    @(
        (New-Row '2026-10-10T00:00:00Z' 'alice' 'S-1-5-21-1' 'RETIRE' 'STARTED' $longReason),
        (New-Row '2026-10-10T23:59:59Z' 'alice' 'S-1-5-21-1' 'RETIRE' 'OK' $longReason),
        (New-Row '2026-10-11T12:00:00Z' 'alice' 'S-1-5-21-2' 'RESTORE' 'OK' 'CHG43')
    ) | Export-Csv -LiteralPath (Join-Path $audit 'actions_2026-10.csv') -NoTypeInformation -Encoding UTF8
    @(
        (New-Row '2026-09-10T12:00:00Z' 'bob' 'S-1-5-21-3' 'RETIRE-ROLLBACK' 'OK' 'CHG40'),
        (New-Row '2026-09-09T12:00:00Z' 'a[1]' '' 'PURGE' 'FAILED: denied' 'literal * ticket')
    ) | Export-Csv -LiteralPath (Join-Path $audit 'actions_2026-09.csv') -NoTypeInformation -Encoding UTF8
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixProfileGUI.ps1') -DefaultProfileRoot $fixture -EnvironmentStorePath (Join-Path $fixture 'environments.json') -InitializeOnly
    $form.ShowInTaskbar = $false; $form.StartPosition = 'Manual'; $form.Location = [Drawing.Point]::new(-3000,-3000)
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    Set-FSLogixAuditRoot -Path $audit
    function Show-FSLogixDialog {
        param([Windows.Forms.Form]$Dialog, [Windows.Forms.IWin32Window]$Owner)
        $script:LastDialog = $Dialog
        $Dialog.ShowInTaskbar = $false; $Dialog.StartPosition = 'Manual'; $Dialog.Location = [Drawing.Point]::new(-3000,-3000)
        $driver = New-Object Windows.Forms.Timer
        $driver.Interval = 50; $driver.Tag = @{Dialog=$Dialog;Action=$script:DialogAction;Ran=$false;Watch=[Diagnostics.Stopwatch]::StartNew()}
        $script:DialogAction = $null; $script:DialogFailure = $null
        $driver.Add_Tick({
            param($sender, $eventArgs)
            $state = $sender.Tag
            if (-not $state.Ran) {
                $state.Ran = $true
                try { & $state.Action $state.Dialog } catch { $script:DialogFailure = $_; $state.Dialog.Close() }
            }
            if ($state.Watch.Elapsed.TotalSeconds -gt 20) { $script:DialogFailure = 'Audit dialog timed out'; $state.Dialog.Close() }
        })
        $driver.Start()
        try { $result = $Dialog.ShowDialog() } finally { $driver.Stop(); $driver.Dispose() }
        if ($script:DialogFailure) { throw $script:DialogFailure }
        return $result
    }
    $script:DialogAction = {
        param($dialog)
        $table = $dialog.Controls.Find('AuditHistoryGrid', $true)[0]
        $status = $dialog.Controls.Find('AuditHistoryStatus', $true)[0]
        $user = $dialog.Controls.Find('AuditUserFilter', $true)[0]
        $sid = $dialog.Controls.Find('AuditSidFilter', $true)[0]
        $reason = $dialog.Controls.Find('AuditReasonFilter', $true)[0]
        $actor = $dialog.Controls.Find('AuditActorFilter', $true)[0]
        $action = $dialog.Controls.Find('AuditActionFilter', $true)[0]
        $from = $dialog.Controls.Find('AuditFromDate', $true)[0]
        $to = $dialog.Controls.Find('AuditToDate', $true)[0]
        $apply = $dialog.Controls.Find('AuditApply', $true)[0]
        $clear = $dialog.Controls.Find('AuditClear', $true)[0]
        $refresh = $dialog.Controls.Find('AuditRefresh', $true)[0]
        $details = $dialog.Controls.Find('AuditRecordDetails', $true)[0]
        Assert 'toolbar opens real audit dialog' ($dialog.Name -eq 'AuditHistoryDialog')
        Assert 'initial grid loads both monthly files' ($table.Rows.Count -eq 5)
        Assert 'audit grid is read only' ($table.ReadOnly -and -not $table.AllowUserToDeleteRows)
        Assert 'newest timestamp is first' ($table.Rows[0].Tag.TargetSid -eq 'S-1-5-21-2')
        Assert 'date pickers default to unbounded search' (-not $from.Checked -and -not $to.Checked)
        $user.Text = 'ALI'; $apply.PerformClick()
        Assert 'user filter works through actual Apply button' ($table.Rows.Count -eq 3)
        $sid.Text = 'S-1-5-21-1'; $apply.PerformClick()
        Assert 'SID filter separates equal usernames' ($table.Rows.Count -eq 2)
        $reason.Text = '[literal]'; $actor.Text = 'OPERATOR'; $action.SelectedItem = 'RETIRE'; $apply.PerformClick()
        Assert 'ticket operator and action filters combine' ($table.Rows.Count -eq 2)
        $table.ClearSelection(); $table.Rows[0].Selected = $true
        Assert 'selected row shows complete untruncated reason' ($details.Text.Contains($longReason))
        Assert 'selected row shows complete source and destination' ($details.Text.Contains('D:\full source\Profile.vhdx') -and $details.Text.Contains('D:\full destination\Profile-old.vhdx'))
        Assert 'selected row includes provenance' ($details.Text.Contains('AuditFile:') -and $details.Text.Contains('AuditRow:'))
        $clear.PerformClick()
        Assert 'Clear resets every filter' ($table.Rows.Count -eq 5 -and $user.Text -eq '' -and $sid.Text -eq '' -and $reason.Text -eq '' -and $actor.Text -eq '' -and $action.SelectedItem -eq 'All')
        $table.Sort($table.Columns['TimestampUtc'], [ComponentModel.ListSortDirection]::Ascending)
        Assert 'actual grid sorting uses timestamp values' ($table.Rows[0].Tag.TargetUser -eq 'a[1]')
        $from.Value = [datetime]'2026-10-10'; $from.Checked = $true
        $to.Value = [datetime]'2026-10-10'; $to.Checked = $true; $apply.PerformClick()
        Assert 'date UI includes both ends of selected UTC day' ($table.Rows.Count -eq 2)
        $from.Value = [datetime]'2026-10-12'; $apply.PerformClick()
        Assert 'reversed dates visibly fail and clear stale results' ($table.Rows.Count -eq 0 -and $status.Text -like 'History unavailable:*From date*')
        $clear.PerformClick(); $user.Text = 'nobody'; $apply.PerformClick()
        Assert 'no matches is distinct from unavailable history' ($table.Rows.Count -eq 0 -and $status.Text -like 'No audit records match*')
        $clear.PerformClick(); $user.Text = '['; $apply.PerformClick()
        Assert 'GUI literal bracket search remains safe' ($table.Rows.Count -eq 1 -and $table.Rows[0].Tag.TargetUser -eq 'a[1]')
        $clear.PerformClick(); $action.SelectedItem = 'RETIRE-ROLLBACK'; $apply.PerformClick()
        Assert 'rollback records are searchable without hiding state' ($table.Rows.Count -eq 1 -and $table.Rows[0].Cells['Result'].Value -eq 'OK')
        $clear.PerformClick()
        $bad = Join-Path $audit 'actions_2026-01.csv'
        [IO.File]::WriteAllText($bad, 'TimestampUtc,Action,Result' + "`r`n" + 'invalid,RETIRE,OK')
        $refresh.PerformClick()
        Assert 'malformed file is visible unavailable state' ($table.Rows.Count -eq 0 -and $status.Text -like 'History unavailable:*actions_2026-01.csv*')
        [IO.File]::Delete($bad); $refresh.PerformClick()
        Assert 'Refresh recovers after source error' ($table.Rows.Count -eq 5)
        Write-FSLogixAudit -Critical -Record @{Action='RESTORE';Result='OK';Reason='New record';TargetUser='carol';TargetSid='S-1-5-21-4'}
        $refresh.PerformClick()
        Assert 'Refresh reads newly appended real audit row' ($table.Rows.Count -eq 6 -and @($table.Rows | Where-Object {$_.Tag.TargetUser -eq 'carol'}).Count -eq 1)
        Assert 'record detail view is read only' $details.ReadOnly
        $dialog.CancelButton.PerformClick()
    }
    $btnAuditHistory.PerformClick()
    Assert 'closed audit dialog releases controls' $script:LastDialog.IsDisposed
    $cmbTheme.SelectedItem = 'Dark'
    $script:DialogAction = {
        param($dialog)
        Assert 'audit dialog follows Dark form palette' ($dialog.BackColor.ToArgb() -eq $script:Themes.Dark.FormBackColor.ToArgb())
        Assert 'audit grid follows Dark text palette' ($dialog.Controls.Find('AuditHistoryGrid',$true)[0].DefaultCellStyle.ForeColor.ToArgb() -eq $script:Themes.Dark.GridForeColor.ToArgb())
        Assert 'record pane follows Dark background palette' ($dialog.Controls.Find('AuditRecordDetails',$true)[0].BackColor.ToArgb() -eq $script:Themes.Dark.TextBoxBackColor.ToArgb())
        Assert 'Dark success status remains readable' ($dialog.Controls.Find('AuditHistoryStatus',$true)[0].ForeColor.ToArgb() -eq [Drawing.Color]::LightGreen.ToArgb())
        $dialog.CancelButton.PerformClick()
    }
    $btnAuditHistory.PerformClick()
    $script:DialogAction = {
        param($dialog)
        $table = $dialog.Controls.Find('AuditHistoryGrid', $true)[0]
        Assert 'caller can preset exact SID filter' ($table.Rows.Count -eq 2 -and $dialog.Controls.Find('AuditSidFilter',$true)[0].Text -eq 'S-1-5-21-1')
        $dialog.CancelButton.PerformClick()
    }
    Show-FSLogixAuditHistoryDialog -AuditRoot $audit -User alice -Sid 'S-1-5-21-1'
    $missing = Join-Path $fixture 'missing'
    $script:DialogAction = {
        param($dialog)
        Assert 'missing audit root visibly unavailable' ($dialog.Controls.Find('AuditHistoryStatus',$true)[0].Text -like 'History unavailable:*')
        Assert 'missing history has no misleading rows' ($dialog.Controls.Find('AuditHistoryGrid',$true)[0].Rows.Count -eq 0)
        Assert 'Dark error status remains readable' ($dialog.Controls.Find('AuditHistoryStatus',$true)[0].ForeColor.ToArgb() -eq [Drawing.Color]::LightCoral.ToArgb())
        $dialog.CancelButton.PerformClick()
    }
    Show-FSLogixAuditHistoryDialog -AuditRoot $missing
    Assert 'viewing missing audit root never creates it' (-not (Test-Path -LiteralPath $missing))
    Write-Host "ALL $script:checks AUDIT GUI CHECKS PASSED"
} finally {
    if (Get-Variable form -ErrorAction SilentlyContinue) { $form.Close(); $form.Dispose() }
    $prefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\.audit-gui-fixture_'
    if ($fixture.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
