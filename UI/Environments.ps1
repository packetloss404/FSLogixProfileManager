# Host integration for saved environments; dot-sourced after the main controls exist.
function Get-FSLogixEnvironmentUIState {
    $audit = Get-FSLogixAuditConfiguration
    $server = Get-FSLogixHorizonServer
    if (-not $server) { $server = "$script:HorizonServerHint" }
    return ConvertTo-FSLogixEnvironmentSettings ([ordered]@{
        ProfileRoots=@($txtRoot.Text -split ';' | ForEach-Object {$_.Trim()} | Where-Object {$_})
        AuditRoot=$audit.Path; AuditRootIsExplicit=[bool]$audit.IsExplicit
        HorizonServer="$server"; Theme=$cmbTheme.SelectedItem.ToString()
        UserFilter=$txtFilter.Text; AgeEnabled=[bool]$chkAge.Checked; AgeDays=[int]$numAge.Value
        ADAgeEnabled=[bool]$chkADAge.Checked; ADAgeDays=[int]$numADAge.Value
        OnlyIssues=[bool]$chkOnlyIssues.Checked; CheckAD=[bool]$chkCheckOrphans.Checked
        HighlightEnabled=[bool]$chkHighlight.Checked; HighlightGB=[int]$numHighlight.Value
        Columns=@($grid.Columns | ForEach-Object { [pscustomobject]@{Index=[int]$_.Index;DisplayIndex=[int]$_.DisplayIndex;Width=[int]$_.Width} })
        SortColumn=[int]$script:SortColumn; SortAscending=[bool]$script:SortAscending
    })
}

function Set-FSLogixEnvironmentUIState {
    param([Parameter(Mandatory=$true)]$Settings)
    # Validate before touching controls. Settings cannot authorize live operations.
    $state = ConvertTo-FSLogixEnvironmentSettings $Settings
    if ($script:ScanState.PowerShell) { throw 'Wait for the current scan to finish before changing environments.' }
    Disconnect-FSLogixHorizon
    Clear-FSLogixADCache
    $script:HorizonServerHint = $state.HorizonServer
    $script:AllProfiles = @()
    $grid.Rows.Clear(); $grid.ClearSelection()
    $script:ScanIsComplete = $false
    $btnDelete.Enabled = $false
    $chkWhatIf.Checked = $true
    $chkCheckInUse.Checked = $true
    $chkPreview.Checked = $true
    $chkMoveRetired.Checked = $true
    $chkDeleteOdfc.Checked = $false
    $chkDeleteProfile.Checked = $false
    $txtReason.Clear()
    $txtRoot.Text = $state.ProfileRoots -join '; '
    if ($state.AuditRootIsExplicit) { Set-FSLogixAuditRoot -Path $state.AuditRoot } else { Reset-FSLogixAuditRoot }
    $script:AuditRootIsExplicit = $state.AuditRootIsExplicit
    $txtFilter.Text = $state.UserFilter
    $numAge.Value = $state.AgeDays; $chkAge.Checked = $state.AgeEnabled
    $numADAge.Value = $state.ADAgeDays; $chkADAge.Checked = $state.ADAgeEnabled
    $chkOnlyIssues.Checked = $state.OnlyIssues
    $chkCheckOrphans.Checked = $state.CheckAD
    $numHighlight.Value = $state.HighlightGB; $chkHighlight.Checked = $state.HighlightEnabled
    $script:SortColumn = $state.SortColumn; $script:SortAscending = $state.SortAscending
    foreach ($column in $grid.Columns) { $column.HeaderCell.SortGlyphDirection = 'None' }
    foreach ($column in @($state.Columns | Sort-Object DisplayIndex)) {
        $grid.Columns[$column.Index].DisplayIndex = $column.DisplayIndex
        $grid.Columns[$column.Index].Width = $column.Width
    }
    if ($script:SortColumn -ge 0) { $grid.Columns[$script:SortColumn].HeaderCell.SortGlyphDirection = $(if ($script:SortAscending) {'Ascending'} else {'Descending'}) }
    $cmbTheme.SelectedItem = $state.Theme
    Apply-Theme $state.Theme
    $script:lblStatus.Text = 'Environment applied. Load profiles before resetting.'
    Set-ResetButtonAppearance
}

function Update-FSLogixEnvironmentSelector {
    param([string]$SelectedName)
    $store = Get-FSLogixEnvironmentStore -Path $script:EnvironmentStorePath
    $script:EnvironmentCombo.Items.Clear()
    foreach ($item in $store.Environments) { [void]$script:EnvironmentCombo.Items.Add($item.Name) }
    if (-not $SelectedName) { $SelectedName = $store.ActiveEnvironment }
    if ($SelectedName -and $script:EnvironmentCombo.Items.Contains($SelectedName)) { $script:EnvironmentCombo.SelectedItem = $SelectedName }
    $script:EnvironmentApplyButton.Enabled = $script:EnvironmentCombo.SelectedIndex -ge 0
    return $store
}

function Invoke-FSLogixSelectedEnvironment {
    if (-not $script:EnvironmentCombo.SelectedItem) { return }
    $name = $script:EnvironmentCombo.SelectedItem.ToString()
    try {
        $store = Get-FSLogixEnvironmentStore -Path $script:EnvironmentStorePath
        $item = @($store.Environments | Where-Object Name -eq $name)[0]
        if (-not $item) { throw "Environment not found: $name" }
        # Record selection first so an unwritable store cannot partially switch UI state.
        if ($script:ScanState.PowerShell) { throw 'Wait for the current scan to finish before changing environments.' }
        [void](Set-FSLogixActiveEnvironment -Name $name -Path $script:EnvironmentStorePath)
        Set-FSLogixEnvironmentUIState -Settings $item.Settings
        $script:ActiveEnvironmentName = $name
        Add-LogMessage "Applied environment '$name'. Horizon authentication and a fresh scan are required." INFO
    } catch {
        Add-LogMessage "Environment could not be applied: $($_.Exception.Message)" ERROR
        [void](Show-FSLogixMessage -Text $_.Exception.Message -Caption 'Environment error' -Icon Error)
    }
}

function Show-FSLogixEnvironmentDialog {
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = 'Save / Manage Environments'
    $dialog.ClientSize = New-Object Drawing.Size(540,280)
    $dialog.StartPosition = 'CenterParent'; $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false; $dialog.MinimizeBox = $false
    $label = New-Object Windows.Forms.Label
    $label.Text = 'Environment name:'; $label.Location = New-Object Drawing.Point(14,18); $label.AutoSize=$true
    $dialog.Controls.Add($label)
    $name = New-Object Windows.Forms.ComboBox
    $name.Name='EnvironmentName'; $name.Location=New-Object Drawing.Point(160,14); $name.Size=New-Object Drawing.Size(360,24)
    $name.DropDownStyle='DropDown'
    try {
        $store=Get-FSLogixEnvironmentStore -Path $script:EnvironmentStorePath
        foreach($entry in $store.Environments){[void]$name.Items.Add($entry.Name)}
    } catch {
        $dialog.Dispose()
        [void](Show-FSLogixMessage -Text $_.Exception.Message -Caption 'Environment error' -Icon Error)
        return
    }
    if($script:EnvironmentCombo.SelectedItem){$name.Text=$script:EnvironmentCombo.SelectedItem.ToString()}
    $dialog.Controls.Add($name)
    $label=New-Object Windows.Forms.Label
    $label.Text='Horizon server (optional):';$label.Location=New-Object Drawing.Point(14,58);$label.AutoSize=$true
    $dialog.Controls.Add($label)
    $server=New-Object Windows.Forms.TextBox
    $server.Name='EnvironmentHorizonServer';$server.Location=New-Object Drawing.Point(160,54);$server.Size=New-Object Drawing.Size(360,24)
    $server.Text="$script:HorizonServerHint"
    $connectedServer=Get-FSLogixHorizonServer
    if($connectedServer){$server.Text=$connectedServer}
    $dialog.Controls.Add($server)
    $hint=New-Object Windows.Forms.Label
    $hint.Text='Save captures the current roots, audit destination, filters, theme and grid layout. Credentials and live-mode choices are never saved. Apply requires a new scan and reconnect.'
    $hint.Location=New-Object Drawing.Point(14,96);$hint.Size=New-Object Drawing.Size(506,68)
    $dialog.Controls.Add($hint)
    $status=New-Object Windows.Forms.Label
    $status.Name='EnvironmentStatus';$status.Location=New-Object Drawing.Point(14,170);$status.Size=New-Object Drawing.Size(506,45)
    $status.ForeColor=[Drawing.Color]::DarkRed;$dialog.Controls.Add($status)
    $save=New-Object Windows.Forms.Button
    $save.Name='EnvironmentSave';$save.Text='Save';$save.Location=New-Object Drawing.Point(260,232);$save.Size=New-Object Drawing.Size(80,30)
    $delete=New-Object Windows.Forms.Button
    $delete.Name='EnvironmentDelete';$delete.Text='Delete';$delete.Location=New-Object Drawing.Point(14,232);$delete.Size=New-Object Drawing.Size(80,30)
    $cancel=New-Object Windows.Forms.Button
    $cancel.Name='EnvironmentCancel';$cancel.Text='Close';$cancel.Location=New-Object Drawing.Point(440,232);$cancel.Size=New-Object Drawing.Size(80,30);$cancel.DialogResult='Cancel'
    $dialog.Controls.AddRange(@($save,$delete,$cancel));$dialog.CancelButton=$cancel;$dialog.AcceptButton=$save
    $save.Add_Click({
        try {
            $settings=Get-FSLogixEnvironmentUIState
            $settings.HorizonServer=$server.Text
            $existing=Get-FSLogixEnvironmentStore -Path $script:EnvironmentStorePath
            if(@($existing.Environments | Where-Object Name -eq $name.Text.Trim()).Count){
                if((Show-FSLogixMessage -Text "Replace saved environment '$($name.Text.Trim())' with the current settings?" -Caption 'Replace environment' -Buttons YesNo -Icon Question -DefaultButton Button2) -ne [Windows.Forms.DialogResult]::Yes){return}
            }
            [void](Save-FSLogixEnvironment -Name $name.Text -Settings $settings -Path $script:EnvironmentStorePath)
            $script:HorizonServerHint=$settings.HorizonServer.Trim()
            $script:ActiveEnvironmentName=$name.Text.Trim()
            [void](Update-FSLogixEnvironmentSelector -SelectedName $script:ActiveEnvironmentName)
            Add-LogMessage "Saved environment '$script:ActiveEnvironmentName'." INFO
            $dialog.DialogResult='OK';$dialog.Close()
        } catch {$status.Text=$_.Exception.Message}
    })
    $delete.Add_Click({
        try {
            $deleteName=$name.Text.Trim()
            if(-not $deleteName){throw 'Choose an environment to delete.'}
            if((Show-FSLogixMessage -Text "Delete saved environment '$deleteName'? Current controls and profile files are unchanged." -Caption 'Delete environment' -Buttons YesNo -Icon Question -DefaultButton Button2) -ne [Windows.Forms.DialogResult]::Yes){return}
            [void](Remove-FSLogixEnvironment -Name $deleteName -Path $script:EnvironmentStorePath)
            [void](Update-FSLogixEnvironmentSelector)
            if($script:ActiveEnvironmentName -eq $deleteName){$script:ActiveEnvironmentName=''}
            $dialog.DialogResult='OK';$dialog.Close()
        } catch {$status.Text=$_.Exception.Message}
    })
    try{[void](Show-FSLogixDialog -Dialog $dialog -Owner $form)}finally{$dialog.Dispose()}
}

function Initialize-FSLogixEnvironmentUI {
    param([string]$StorePath, [switch]$RestoreActive)
    $script:EnvironmentStorePath=Get-FSLogixEnvironmentStorePath $StorePath
    $script:ActiveEnvironmentName=''
    $label=New-Object Windows.Forms.Label
    $label.Text='Environment:';$label.AutoSize=$true;$label.Margin=New-Object Windows.Forms.Padding(0,8,4,0)
    $script:EnvironmentCombo=New-Object Windows.Forms.ComboBox
    $script:EnvironmentCombo.Name='EnvironmentSelector';$script:EnvironmentCombo.Width=180;$script:EnvironmentCombo.DropDownStyle='DropDownList'
    $script:EnvironmentApplyButton=New-Object Windows.Forms.Button
    $script:EnvironmentApplyButton.Name='EnvironmentApply';$script:EnvironmentApplyButton.Text='Apply';$script:EnvironmentApplyButton.Width=60
    $manage=New-Object Windows.Forms.Button
    $manage.Name='EnvironmentManage';$manage.Text='Save / Manage...';$manage.Width=115
    $script:FeatureToolbar.Controls.AddRange(@($label,$script:EnvironmentCombo,$script:EnvironmentApplyButton,$manage))
    $script:EnvironmentCombo.Add_SelectedIndexChanged({$script:EnvironmentApplyButton.Enabled=$script:EnvironmentCombo.SelectedIndex -ge 0})
    $script:EnvironmentApplyButton.Add_Click({Invoke-FSLogixSelectedEnvironment})
    $manage.Add_Click({Show-FSLogixEnvironmentDialog})
    try {
        $store=Update-FSLogixEnvironmentSelector
        if($RestoreActive -and $store.ActiveEnvironment){
            # Startup restore is read-only: the saved selection is already persisted.
            $item=@($store.Environments | Where-Object Name -eq $store.ActiveEnvironment)[0]
            Set-FSLogixEnvironmentUIState $item.Settings
            $script:ActiveEnvironmentName=$store.ActiveEnvironment
            Add-LogMessage "Restored saved environment '$script:ActiveEnvironmentName'." INFO
        }
    } catch {
        $script:EnvironmentApplyButton.Enabled=$false
        Add-LogMessage "Saved environments unavailable: $($_.Exception.Message)" ERROR
        [void](Show-FSLogixMessage -Text "Saved environments could not be read. The existing file was preserved.`n$($_.Exception.Message)" -Caption 'Environment error' -Icon Error)
    }
}
