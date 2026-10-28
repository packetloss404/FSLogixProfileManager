#Requires -Version 5.1
$ErrorActionPreference='Stop'
if([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA'){throw 'Run with -STA.'}
Add-Type -AssemblyName System.Windows.Forms
$script:Checks=0
function Check($Name,$Actual,$Expected){if("$Actual" -ne "$Expected"){throw "$Name : got '$Actual' expected '$Expected'"};$script:Checks++;Write-Host "  ok $Name"}
$fixture=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('.environment-gui_'+[guid]::NewGuid().ToString('N'))))
$rootA=Join-Path $fixture 'Profiles A';$rootB=Join-Path $fixture 'Profiles B';$storePath=Join-Path $fixture 'environments.json'
[void][IO.Directory]::CreateDirectory((Join-Path $rootA 'alice_S-1-5-21-1-2-3-1001'))
[void][IO.Directory]::CreateDirectory($rootB)
$container=Join-Path $rootA 'alice_S-1-5-21-1-2-3-1001\Profile_alice.vhdx'
[IO.File]::WriteAllBytes($container,(New-Object byte[] 4096))
$script:NextEnvironmentDialogAction=$null;$script:EnvironmentDialogFailure=$null
$script:EnvironmentMessages=New-Object Collections.ArrayList;$script:EnvironmentAnswer=[Windows.Forms.DialogResult]::Yes
try{
    $guiPath=Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixProfileGUI.ps1'
    . $guiPath -DefaultProfileRoot $rootA -EnvironmentStorePath $storePath -InitializeOnly
    $form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=New-Object Drawing.Point(-3000,-3000);$form.Show()
    function Show-FSLogixMessage{
        param($Text,$Caption,$Buttons,$Icon,$DefaultButton)
        [void]$script:EnvironmentMessages.Add([pscustomobject]@{Text=$Text;Caption=$Caption;Buttons="$Buttons";DefaultButton="$DefaultButton"})
        if("$Buttons" -eq 'YesNo'){return $script:EnvironmentAnswer};return [Windows.Forms.DialogResult]::OK
    }
    function Show-FSLogixDialog{
        param([Windows.Forms.Form]$Dialog,[Windows.Forms.IWin32Window]$Owner)
        $Dialog.ShowInTaskbar=$false;$Dialog.StartPosition='Manual';$Dialog.Location=New-Object Drawing.Point(-3000,-3000)
        $timer=New-Object Windows.Forms.Timer;$timer.Interval=40
        $timer.Tag=@{Dialog=$Dialog;Action=$script:NextEnvironmentDialogAction;Ran=$false;Watch=[Diagnostics.Stopwatch]::StartNew()}
        $script:NextEnvironmentDialogAction=$null;$script:EnvironmentDialogFailure=$null
        $timer.Add_Tick({param($sender,$args)
            $state=$sender.Tag
            if($state.Action -and -not $state.Ran){$state.Ran=$true;try{& $state.Action $state.Dialog}catch{$script:EnvironmentDialogFailure=$_;$state.Dialog.Close()}}
            if($state.Watch.Elapsed.TotalSeconds -gt 20){$script:EnvironmentDialogFailure='Environment dialog timed out: '+$state.Dialog.Text;$state.Dialog.Close()}
        })
        $timer.Start()
        try{if($Owner){$result=$Dialog.ShowDialog($Owner)}else{$result=$Dialog.ShowDialog()}}finally{$timer.Stop();$timer.Dispose()}
        if($script:EnvironmentDialogFailure){throw $script:EnvironmentDialogFailure};return $result
    }
    $manage=$script:FeatureToolbar.Controls | Where-Object Name -eq EnvironmentManage
    Check 'environment selector starts empty' $script:EnvironmentCombo.Items.Count 0
    Check 'initialization does not create settings' (Test-Path -LiteralPath $storePath) $false
    Check 'Apply disabled without an environment' $script:EnvironmentApplyButton.Enabled $false
    $txtRoot.Text=$rootA+'; '+$rootB
    $txtFilter.Text='ali[ce]';$chkAge.Checked=$true;$numAge.Value=60
    $chkADAge.Checked=$true;$numADAge.Value=120;$chkOnlyIssues.Checked=$true;$chkCheckOrphans.Checked=$true
    $chkHighlight.Checked=$false;$numHighlight.Value=75
    $cmbTheme.SelectedItem='Dark';$grid.Columns[7].DisplayIndex=0;$grid.Columns[7].Width=260
    $script:SortColumn=5;$script:SortAscending=$false
    Set-FSLogixAuditRoot -Path (Join-Path $fixture 'centralAudit')
    $chkWhatIf.Checked=$false;$chkCheckInUse.Checked=$false;$chkPreview.Checked=$false;$chkMoveRetired.Checked=$false;$chkDeleteOdfc.Checked=$true
    $txtReason.Text='must not persist ticket'
    $script:NextEnvironmentDialogAction={param($dialog)
        Check 'Save button fits dialog' ($dialog.AcceptButton.Bottom -le $dialog.ClientSize.Height) $true
        $dialog.Controls['EnvironmentName'].Text='Production'
        $dialog.Controls['EnvironmentHorizonServer'].Text='connection.production.test'
        $dialog.AcceptButton.PerformClick()
        if($dialog.DialogResult -ne 'OK'){throw ('Save did not complete: '+$dialog.Controls['EnvironmentStatus'].Text)}
    }
    $manage.PerformClick()
    $store=Get-FSLogixEnvironmentStore -Path $storePath
    Check 'actual Save button writes named environment' $store.Environments[0].Name Production
    Check 'selector refreshes after save' $script:EnvironmentCombo.Items.Count 1
    Check 'saved multi-root configuration' $store.Environments[0].Settings.ProfileRoots.Count 2
    Check 'saved Horizon name is a reconnect hint' $store.Environments[0].Settings.HorizonServer connection.production.test
    Check 'saved audit config uses module explicit state' $store.Environments[0].Settings.AuditRootIsExplicit $true
    Check 'ticket is excluded from saved file' ([IO.File]::ReadAllText($storePath).Contains('must not persist ticket')) $false
    Check 'live-mode flag is excluded' (@($store.Environments[0].Settings.PSObject.Properties.Name) -contains 'WhatIf') $false
    Check 'credential fields are excluded' ([IO.File]::ReadAllText($storePath) -match 'Password|access_token|SkipCertificateCheck') $false
    $before=[IO.File]::ReadAllText($storePath);$script:EnvironmentAnswer=[Windows.Forms.DialogResult]::No
    $script:NextEnvironmentDialogAction={param($dialog)
        $dialog.AcceptButton.PerformClick()
        Check 'replacement defaults to No' $script:EnvironmentMessages[$script:EnvironmentMessages.Count-1].DefaultButton Button2
        Check 'declined replace keeps manager open' $dialog.Visible $true
        $dialog.CancelButton.PerformClick()
    }
    $manage.PerformClick();Check 'declined replacement preserves store' ([IO.File]::ReadAllText($storePath)) $before
    $script:EnvironmentAnswer=[Windows.Forms.DialogResult]::Yes
    $script:NextEnvironmentDialogAction={param($dialog)
        $dialog.Controls['EnvironmentName'].Text='Invalid'
        $dialog.Controls['EnvironmentHorizonServer'].Text='https://user:secret@server.invalid'
        $dialog.AcceptButton.PerformClick()
        Check 'invalid save stays open' $dialog.Visible $true
        Check 'invalid save reports validation error' ($dialog.Controls['EnvironmentStatus'].Text -match 'Horizon server') $true
        $dialog.CancelButton.PerformClick()
    }
    $manage.PerformClick()
    Check 'invalid GUI save preserves settings' ([IO.File]::ReadAllText($storePath)) $before

    # Produce actual scanned rows before switching. Applying cannot keep stale selections.
    $chkAge.Checked=$false;$chkADAge.Checked=$false;$chkOnlyIssues.Checked=$false;$chkCheckOrphans.Checked=$false;$txtFilter.Clear()
    $txtRoot.Text=$rootA;$btnLoad.PerformClick()
    Check 'fixture scan produced real row before apply' $grid.Rows.Count 1
    $grid.Rows[0].Selected=$true
    $module=Get-Module FSLogixProfileCore
    & $module {$script:HorizonConnection=[pscustomobject]@{Server='old.test';Headers=@{Authorization='synthetic-token'}};$script:ADCheckCache=@{old='cached'}}
    $cmbTheme.SelectedItem='Light';$grid.Columns[7].DisplayIndex=7;$grid.Columns[7].Width=180
    $script:EnvironmentCombo.SelectedItem='Production';$script:EnvironmentApplyButton.PerformClick()
    Check 'apply restores roots' $txtRoot.Text ($rootA+'; '+$rootB)
    Check 'apply clears old rows' $grid.Rows.Count 0
    Check 'apply clears scanned backing profiles' $script:AllProfiles.Count 0
    Check 'apply invalidates scan' $script:ScanIsComplete $false
    Check 'apply disables reset' $btnDelete.Enabled $false
    Check 'apply requires Horizon reconnect' (Test-FSLogixHorizonConnected) $false
    Check 'apply clears AD cache' (& $module {$script:ADCheckCache.Count}) 0
    Check 'apply retains server hint' $script:HorizonServerHint connection.production.test
    Check 'apply forces simulation' $chkWhatIf.Checked $true
    Check 'apply restores lock checks' $chkCheckInUse.Checked $true
    Check 'apply restores preview' $chkPreview.Checked $true
    Check 'apply restores move safety' $chkMoveRetired.Checked $true
    Check 'apply restores all scope' $chkDeleteOdfc.Checked $false
    Check 'apply clears ticket' $txtReason.Text ''
    Check 'apply restores literal filter' $txtFilter.Text 'ali[ce]'
    Check 'apply restores age setting' $numAge.Value 60
    Check 'apply restores AD age setting' $numADAge.Value 120
    Check 'apply restores theme' $script:CurrentTheme Dark
    Check 'apply restores column order' $grid.Columns[7].DisplayIndex 0
    Check 'apply restores column width' $grid.Columns[7].Width 260
    Check 'apply restores sort column' $script:SortColumn 5
    Check 'apply restores sort direction' $script:SortAscending $false
    Check 'apply leaves real container untouched' (Test-Path -LiteralPath $container) $true
    Check 'apply starts no background scan' ($null -eq $script:ScanState.PowerShell) $true
    $config=Get-FSLogixAuditConfiguration
    Check 'apply restores explicit audit path' $config.Path (Join-Path $fixture centralAudit)
    Check 'apply restores explicit audit behavior' $config.IsExplicit $true

    # Default auditing must retain best-effort semantics, not become explicitly required.
    Reset-FSLogixAuditRoot
    $defaultSettings=Get-FSLogixEnvironmentUIState;$defaultSettings.ProfileRoots=@($rootB)
    [void](Save-FSLogixEnvironment -Name Lab -Settings $defaultSettings -Path $storePath)
    [void](Update-FSLogixEnvironmentSelector -SelectedName Lab)
    Set-FSLogixAuditRoot -Path (Join-Path $fixture requiredAudit)
    $script:EnvironmentApplyButton.PerformClick()
    Check 'default audit state remains nonexplicit' (Get-FSLogixAuditConfiguration).IsExplicit $false

    # A fresh process exercises actual startup restore and explicit-root precedence.
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    foreach($override in @($false,$true)){
        $childResult=Join-Path $fixture ('startup_'+$override+'.json')
        $command=". '"+$guiPath.Replace("'","''")+"' -EnvironmentStorePath '"+$storePath.Replace("'","''")+"' -InitializeOnly"
        if($override){$command+=" -DefaultProfileRoot '"+$rootA.Replace("'","''")+"'"}
        $command+="; @{Roots=`$txtRoot.Text;Filter=`$txtFilter.Text;WhatIf=`$chkWhatIf.Checked;Rows=`$grid.Rows.Count;Connected=(Test-FSLogixHorizonConnected)} | ConvertTo-Json | Set-Content -LiteralPath '"+$childResult.Replace("'","''")+"'; `$form.Dispose()"
        $start=New-Object Diagnostics.ProcessStartInfo;$start.FileName=$shell
        $start.Arguments='-NoProfile -NonInteractive -STA -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $process=New-Object Diagnostics.Process;$process.StartInfo=$start;[void]$process.Start()
        try{if(-not $process.WaitForExit(30000)){$process.Kill();throw 'Startup process timed out.'};Check 'startup process succeeds' $process.ExitCode 0}finally{$process.Dispose()}
        $startup=Get-Content -LiteralPath $childResult -Raw | ConvertFrom-Json
        if($override){Check 'explicit root overrides last selected environment' $startup.Roots $rootA;Check 'explicit root does not restore filters' $startup.Filter ''}
        else{Check 'startup restores selected environment roots' $startup.Roots $rootB;Check 'startup restores saved filter' $startup.Filter 'ali[ce]'}
        Check 'startup always enables WhatIf' $startup.WhatIf $true
        Check 'startup does not scan automatically' $startup.Rows 0
        Check 'startup does not reconnect automatically' $startup.Connected $false
    }
    # Delete through the manager affects preferences only.
    $script:NextEnvironmentDialogAction={param($dialog)
        $dialog.Controls['EnvironmentName'].Text='Lab'
        $dialog.Controls['EnvironmentDelete'].PerformClick()
    }
    $manage.PerformClick()
    $store=Get-FSLogixEnvironmentStore -Path $storePath
    Check 'Delete control removes selected saved config' $store.Environments.Count 1
    Check 'Delete leaves profile files untouched' (Test-Path -LiteralPath $container) $true
    Check 'Delete does not change current roots' $txtRoot.Text $rootB

    # The same initialization path used at launch reports corrupt stores without replacing them.
    $corruptPath=Join-Path $fixture 'corrupt.json'
    [IO.File]::WriteAllText($corruptPath,'{broken')
    $rootsBefore=$txtRoot.Text
    Initialize-FSLogixEnvironmentUI -StorePath $corruptPath -RestoreActive
    Check 'corrupt store startup reports error' $script:EnvironmentMessages[$script:EnvironmentMessages.Count-1].Caption 'Environment error'
    Check 'corrupt store startup disables apply' $script:EnvironmentApplyButton.Enabled $false
    Check 'corrupt store startup preserves roots' $txtRoot.Text $rootsBefore
    Check 'corrupt store startup preserves original file' ([IO.File]::ReadAllText($corruptPath)) '{broken'
    Write-Host "ALL $script:Checks ENVIRONMENT GUI CHECKS PASSED"
}finally{
    if($form){$form.Dispose()}
    $prefix=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if($fixture.StartsWith($prefix) -and (Split-Path -Leaf $fixture) -like '.environment-gui_*'){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
