function New-FSLogixDetailsGrid {
    param([string]$Name, [object[]]$Columns)
    $view = New-Object System.Windows.Forms.DataGridView
    $view.Name = $Name; $view.Dock = 'Fill'; $view.ReadOnly = $true
    $view.AllowUserToAddRows = $false; $view.AllowUserToDeleteRows = $false
    $view.AllowUserToOrderColumns = $true; $view.MultiSelect = $false
    $view.SelectionMode = 'FullRowSelect'; $view.AutoGenerateColumns = $false
    foreach ($column in $Columns) {
        $cell = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $cell.Name = $column[0]; $cell.HeaderText = $column[1]; $cell.Width = $column[2]
        $cell.SortMode = 'Automatic'
        [void]$view.Columns.Add($cell)
    }
    $view.Add_SelectionChanged({
        param($sender, $eventArgs)
        $dialog = $sender.FindForm()
        if (-not $dialog -or -not $dialog.Tag -or -not $dialog.Tag.DetailText) { return }
        if ($sender.SelectedRows.Count -eq 0) { return }
        $record = $sender.SelectedRows[0].Tag
        if ($null -eq $record) { return }
        $lines = @($record.PSObject.Properties | ForEach-Object {
            $value = if ($null -eq $_.Value) { '(unknown)' } elseif ($_.Value -is [datetime]) { $_.Value.ToString('yyyy-MM-dd HH:mm:ss K') } else { [string]$_.Value }
            '{0}: {1}' -f $_.Name, $value
        })
        $dialog.Tag.DetailText.Text = $lines -join "`r`n"
    })
    return $view
}

function Set-FSLogixDetailsGridRows {
    param([System.Windows.Forms.DataGridView]$Grid, $Records)
    $Grid.Rows.Clear()
    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $index = $Grid.Rows.Add(); $row = $Grid.Rows[$index]; $row.Tag = $record
        foreach ($column in $Grid.Columns) {
            $value = $record.($column.Name)
            if ($null -ne $value) { $row.Cells[$column.Index].Value = $value }
        }
    }
    $Grid.ClearSelection()
}

function Refresh-FSLogixProfileDetailsDialog {
    param([System.Windows.Forms.Form]$Dialog, [switch]$RefreshAvailability)
    $state = $Dialog.Tag
    $Dialog.UseWaitCursor = $true; $state.RefreshButton.Enabled = $false
    $state.StatusLabel.Text = 'Reading profile details...'
    $Dialog.Refresh()
    try {
        $arguments = @{ ProfileObject = $state.ProfileObject; RefreshAvailability = [bool]$RefreshAvailability }
        if ($state.HasAuditRoot) { $arguments.AuditRoot = $state.AuditRoot }
        $snapshot = Get-FSLogixProfileDetails @arguments
        $state.Snapshot = $snapshot
        Set-FSLogixDetailsGridRows -Grid $state.LiveGrid -Records $snapshot.Containers
        Set-FSLogixDetailsGridRows -Grid $state.RetiredGrid -Records $snapshot.RetiredContainers
        Set-FSLogixDetailsGridRows -Grid $state.HistoryGrid -Records $snapshot.AuditHistory
        Set-FSLogixDetailsGridRows -Grid $state.SessionGrid -Records $snapshot.HorizonSessions
        $state.SummaryLabel.Text = @(
            "User: $($snapshot.UserName)    SID: $(if ($snapshot.Sid) {$snapshot.Sid} else {'(unresolved)'})    Identity: $($snapshot.IdentitySource)"
            "AD (scan): $($snapshot.ADStatus)    Disabled: $(if ($null -eq $snapshot.ADDisabled) {'unknown'} else {$snapshot.ADDisabled})    Last logon: $(if ($snapshot.ADLastLogon) {$snapshot.ADLastLogon} else {'unknown'})"
            "Health (scan): $(if ($snapshot.HealthIssues.Count) {$snapshot.HealthIssues -join ', '} else {'No flags recorded'})"
            "Scan totals: $($snapshot.ScanContainerCount) logical container(s), $($snapshot.ScanTotalSizeGB) GB    Physical files: $($snapshot.Containers.Count)"
            "Availability: $($snapshot.AvailabilityStatus)    Horizon: $($snapshot.HorizonStatus)    Retired: $($snapshot.RetiredStatus)    Audit: $($snapshot.AuditStatus)"
            $snapshot.MetadataNote
        ) -join "`r`n"
        $state.DetailText.Text = $(if ($snapshot.Messages.Count) { $snapshot.Messages -join "`r`n" } else { 'Select a row to see its full paths and values. Refresh checks file locks and connected Horizon sessions. A Free result is best-effort.' })
        $state.StatusLabel.Text = "Snapshot: $($snapshot.SnapshotAt.ToString('yyyy-MM-dd HH:mm:ss')) | History records: $($snapshot.AuditHistory.Count) | Retired files: $($snapshot.RetiredContainers.Count)"
        if ($snapshot.Messages.Count) { $state.StatusLabel.Text += " | $($snapshot.Messages.Count) source warning(s); see details." }
    } catch {
        $state.StatusLabel.Text = 'Details unavailable. The previous snapshot has not been refreshed.'
        $state.DetailText.Text = $_.Exception.Message
    } finally {
        $Dialog.UseWaitCursor = $false; $state.RefreshButton.Enabled = $true
    }
}

function Show-FSLogixProfileDetailsDialog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$ProfileObject, [string]$AuditRoot)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Name = 'ProfileDetailsDialog'
    $dialog.Text = "User details - $($ProfileObject.UserName)"
    $dialog.Size = New-Object System.Drawing.Size(1100, 760)
    $dialog.MinimumSize = New-Object System.Drawing.Size(840, 640)
    $dialog.StartPosition = 'CenterParent'; $dialog.AutoScaleMode = 'None'

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'; $layout.Padding = New-Object System.Windows.Forms.Padding(10)
    $layout.ColumnCount = 1; $layout.RowCount = 4
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 138)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 100)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 138)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Absolute', 40)))
    $dialog.Controls.Add($layout)

    $summary = New-Object System.Windows.Forms.Label
    $summary.Name = 'DetailsSummary'; $summary.Dock = 'Fill'; $summary.AutoEllipsis = $false
    $layout.Controls.Add($summary, 0, 0)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Name = 'DetailsTabs'; $tabs.Dock = 'Fill'
    $layout.Controls.Add($tabs, 0, 1)
    $live = New-FSLogixDetailsGrid -Name 'DetailsLiveGrid' -Columns @(
        @('Name','Container',170), @('Class','Class',75), @('IsReplica','Replica',55), @('SizeGB','Current GB',75), @('LastWriteTime','Current Last Write',145),
        @('Availability','Availability',90), @('Holder','Holder',170), @('Signature','Signature (scan)',110), @('Path','Full Path',420)
    )
    $retired = New-FSLogixDetailsGrid -Name 'DetailsRetiredGrid' -Columns @(
        @('RetiredOn','Retired',145), @('Class','Class',75), @('SizeGB','GB',70), @('CanRestore','Can Restore',80),
        @('HasLiveSibling','Live Sibling',80), @('LivePath','Original Live Path',380), @('Path','Retired Path',420)
    )
    $history = New-FSLogixDetailsGrid -Name 'DetailsHistoryGrid' -Columns @(
        @('TimestampUtc','Timestamp (UTC)',150), @('Action','Action',140), @('Result','Result',150), @('Reason','Reason / Ticket',220),
        @('Actor','Operator',160), @('SourcePath','Source',360), @('DestPath','Destination',360)
    )
    $sessions = New-FSLogixDetailsGrid -Name 'DetailsSessionGrid' -Columns @(
        @('UserName','Session User',200), @('State','Session State',150), @('Host','Host (if supplied)',280), @('Id','Session ID',250)
    )
    foreach ($tabSpec in @(@('Live files',$live), @('Retired files',$retired), @('Audit history',$history), @('Horizon sessions',$sessions))) {
        $page = New-Object System.Windows.Forms.TabPage
        $page.Text = $tabSpec[0]; $page.Controls.Add($tabSpec[1]); [void]$tabs.TabPages.Add($page)
    }

    $details = New-Object System.Windows.Forms.TextBox
    $details.Name = 'DetailsRecordText'; $details.Multiline = $true; $details.ReadOnly = $true
    $details.Dock = 'Fill'; $details.ScrollBars = 'Both'; $details.WordWrap = $false; $details.MaxLength = 0
    $layout.Controls.Add($details, 0, 2)

    $footer = New-Object System.Windows.Forms.TableLayoutPanel
    $footer.Dock = 'Fill'; $footer.ColumnCount = 4; $footer.RowCount = 1
    [void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Percent',100)))
    [void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute',120)))
    [void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute',160)))
    [void]$footer.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle('Absolute',90)))
    $layout.Controls.Add($footer, 0, 3)
    $status = New-Object System.Windows.Forms.Label
    $status.Name = 'DetailsStatus'; $status.Dock = 'Fill'; $status.TextAlign = 'MiddleLeft'; $status.AutoEllipsis = $true
    $footer.Controls.Add($status, 0, 0)
    $openHistory = New-Object System.Windows.Forms.Button
    $openHistory.Name = 'DetailsOpenHistory'; $openHistory.Text = 'Open audit history'; $openHistory.Dock = 'Fill'
    $footer.Controls.Add($openHistory, 1, 0)
    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Name = 'DetailsRefresh'; $refresh.Text = 'Refresh availability'; $refresh.Dock = 'Fill'
    $footer.Controls.Add($refresh, 2, 0)
    $close = New-Object System.Windows.Forms.Button
    $close.Name = 'DetailsClose'; $close.Text = 'Close'; $close.Dock = 'Fill'; $close.DialogResult = 'Cancel'
    $footer.Controls.Add($close, 3, 0)
    $dialog.CancelButton = $close
    $dialog.Tag = @{
        ProfileObject = $ProfileObject; AuditRoot = $AuditRoot; HasAuditRoot = $PSBoundParameters.ContainsKey('AuditRoot')
        SummaryLabel = $summary; StatusLabel = $status; DetailText = $details; RefreshButton = $refresh
        LiveGrid = $live; RetiredGrid = $retired; HistoryGrid = $history; SessionGrid = $sessions; Snapshot = $null
    }
    $refresh.Add_Click({ param($sender, $eventArgs) Refresh-FSLogixProfileDetailsDialog -Dialog $sender.FindForm() -RefreshAvailability })
    $openHistory.Add_Click({
        param($sender, $eventArgs)
        $state = $sender.FindForm().Tag
        $arguments = @{}
        if ($state.HasAuditRoot) { $arguments.AuditRoot = $state.AuditRoot }
        if ($state.ProfileObject.Sid) { $arguments.Sid = $state.ProfileObject.Sid }
        else { $arguments.User = $state.ProfileObject.UserName }
        Show-FSLogixAuditHistoryDialog @arguments
    })

    if ($script:Themes -and $script:CurrentTheme) {
        $theme = $script:Themes[$script:CurrentTheme]
        if ($theme) {
            $dialog.BackColor = $theme.FormBackColor; $dialog.ForeColor = $theme.FormForeColor
            foreach ($page in $tabs.TabPages) { $page.BackColor = $theme.FormBackColor; $page.ForeColor = $theme.FormForeColor }
            foreach ($view in @($live,$retired,$history,$sessions)) {
                $view.BackgroundColor = $theme.GridBackColor
                $view.DefaultCellStyle.BackColor = $theme.GridBackColor; $view.DefaultCellStyle.ForeColor = $theme.GridForeColor
                $view.ColumnHeadersDefaultCellStyle.BackColor = $theme.GridHeaderBackColor; $view.ColumnHeadersDefaultCellStyle.ForeColor = $theme.GridHeaderForeColor
                $view.EnableHeadersVisualStyles = $false; $view.GridColor = $theme.FormForeColor
            }
            $details.BackColor = $theme.TextBoxBackColor; $details.ForeColor = $theme.TextBoxForeColor
            foreach ($button in @($openHistory,$refresh,$close)) { $button.BackColor = $theme.ButtonBackColor; $button.ForeColor = $theme.ButtonForeColor }
        }
    }
    try {
        $dialog.Add_Shown({ param($sender, $eventArgs) Refresh-FSLogixProfileDetailsDialog -Dialog $sender })
        [void](Show-FSLogixDialog -Dialog $dialog)
    } finally { $dialog.Dispose() }
}
