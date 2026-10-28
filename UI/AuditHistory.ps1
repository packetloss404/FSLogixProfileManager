function Show-FSLogixAuditHistoryDialog {
    [CmdletBinding()]
    param(
        [string]$AuditRoot = (Get-FSLogixAuditRoot),
        [string]$User,
        [string]$Sid
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Name = 'AuditHistoryDialog'
    $dialog.Text = 'Audit History'
    $dialog.Size = New-Object System.Drawing.Size(1160, 740)
    $dialog.MinimumSize = New-Object System.Drawing.Size(900, 600)
    $dialog.StartPosition = 'CenterParent'
    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.RowCount = 5
    $layout.Padding = New-Object System.Windows.Forms.Padding(8)
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 65)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('Percent', 35)))
    [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle('AutoSize')))
    $dialog.Controls.Add($layout)
    $rootLabel = New-Object System.Windows.Forms.Label
    $rootLabel.Name = 'AuditRootLabel'; $rootLabel.AutoSize = $true
    $rootLabel.Text = "Audit directory: $AuditRoot"
    $rootLabel.MaximumSize = New-Object System.Drawing.Size(1100, 0)
    $layout.Controls.Add($rootLabel, 0, 0)

    $filters = New-Object System.Windows.Forms.FlowLayoutPanel
    $filters.Dock = 'Fill'; $filters.AutoSize = $true; $filters.WrapContents = $true
    $filters.Padding = New-Object System.Windows.Forms.Padding(0, 5, 0, 5)
    $layout.Controls.Add($filters, 0, 1)
    function Add-AuditLabel([string]$Text) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text; $label.AutoSize = $true
        $label.Margin = New-Object System.Windows.Forms.Padding(3, 7, 0, 3)
        $filters.Controls.Add($label)
    }
    function Add-AuditText([string]$Name, [int]$Width) {
        $control = New-Object System.Windows.Forms.TextBox
        $control.Name = $Name; $control.Width = $Width
        $filters.Controls.Add($control)
        return $control
    }
    Add-AuditLabel 'User:'; $txtUser = Add-AuditText 'AuditUserFilter' 105; $txtUser.Text = $User
    Add-AuditLabel 'SID:'; $txtSid = Add-AuditText 'AuditSidFilter' 185; $txtSid.Text = $Sid
    Add-AuditLabel 'Ticket / reason:'; $txtReasonFilter = Add-AuditText 'AuditReasonFilter' 130
    Add-AuditLabel 'Operator:'; $txtActor = Add-AuditText 'AuditActorFilter' 125
    Add-AuditLabel 'Action:'
    $actionFilter = New-Object System.Windows.Forms.ComboBox
    $actionFilter.Name = 'AuditActionFilter'; $actionFilter.Width = 145
    $actionFilter.DropDownStyle = 'DropDownList'
    [void]$actionFilter.Items.AddRange(@('All','RETIRE','RETIRE-ROLLBACK','RESTORE','RESTORE-DISPLACE','RESTORE-ROLLBACK','PURGE'))
    $actionFilter.SelectedIndex = 0; $filters.Controls.Add($actionFilter)
    $filters.SetFlowBreak($actionFilter, $true)
    Add-AuditLabel 'From (UTC):'
    $fromPicker = New-Object System.Windows.Forms.DateTimePicker
    $fromPicker.Name = 'AuditFromDate'; $fromPicker.Format = 'Short'; $fromPicker.Width = 130
    $fromPicker.ShowCheckBox = $true; $fromPicker.Checked = $false; $filters.Controls.Add($fromPicker)
    Add-AuditLabel 'Through (UTC):'
    $toPicker = New-Object System.Windows.Forms.DateTimePicker
    $toPicker.Name = 'AuditToDate'; $toPicker.Format = 'Short'; $toPicker.Width = 130
    $toPicker.ShowCheckBox = $true; $toPicker.Checked = $false; $filters.Controls.Add($toPicker)
    $apply = New-Object System.Windows.Forms.Button
    $apply.Name = 'AuditApply'; $apply.Text = 'Apply'; $apply.AutoSize = $true; $filters.Controls.Add($apply)
    $clear = New-Object System.Windows.Forms.Button
    $clear.Name = 'AuditClear'; $clear.Text = 'Clear filters'; $clear.AutoSize = $true; $filters.Controls.Add($clear)
    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Name = 'AuditRefresh'; $refresh.Text = 'Refresh'; $refresh.AutoSize = $true; $filters.Controls.Add($refresh)

    $historyGrid = New-Object System.Windows.Forms.DataGridView
    $historyGrid.Name = 'AuditHistoryGrid'; $historyGrid.Dock = 'Fill'
    $historyGrid.ReadOnly = $true; $historyGrid.AllowUserToAddRows = $false
    $historyGrid.AllowUserToDeleteRows = $false; $historyGrid.AllowUserToOrderColumns = $true
    $historyGrid.AutoGenerateColumns = $false; $historyGrid.SelectionMode = 'FullRowSelect'; $historyGrid.MultiSelect = $false
    $historyGrid.RowHeadersVisible = $false
    $columnDefs = @(
        @('TimestampUtc','Time (UTC)',145), @('TargetUser','User',105), @('TargetSid','SID',185),
        @('Action','Action',140), @('Result','Result',180), @('Reason','Ticket / reason',170),
        @('Actor','Operator',140), @('ActorHost','Host',110), @('Mode','Mode',75),
        @('SourcePath','Source',300), @('DestPath','Destination',300)
    )
    foreach ($definition in $columnDefs) {
        $column = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $column.Name = $definition[0]; $column.HeaderText = $definition[1]; $column.Width = $definition[2]
        $column.SortMode = 'Automatic'
        if ($column.Name -eq 'TimestampUtc') { $column.ValueType = [datetime]; $column.DefaultCellStyle.Format = 'yyyy-MM-dd HH:mm:ss' }
        [void]$historyGrid.Columns.Add($column)
    }
    $layout.Controls.Add($historyGrid, 0, 2)
    $details = New-Object System.Windows.Forms.TextBox
    $details.Name = 'AuditRecordDetails'; $details.Dock = 'Fill'; $details.Multiline = $true
    $details.ReadOnly = $true; $details.ScrollBars = 'Both'; $details.WordWrap = $false
    $details.Font = New-Object System.Drawing.Font('Consolas', 9)
    $details.Text = 'Select an audit row to inspect its complete record.'
    $layout.Controls.Add($details, 0, 3)
    $footer = New-Object System.Windows.Forms.FlowLayoutPanel
    $footer.Dock = 'Fill'; $footer.AutoSize = $true
    $status = New-Object System.Windows.Forms.Label
    $status.Name = 'AuditHistoryStatus'; $status.AutoSize = $true
    $status.Margin = New-Object System.Windows.Forms.Padding(3, 7, 12, 3)
    $status.MaximumSize = New-Object System.Drawing.Size(950, 0)
    $footer.Controls.Add($status)
    $close = New-Object System.Windows.Forms.Button
    $close.Name = 'AuditClose'; $close.Text = 'Close'; $close.DialogResult = 'Cancel'; $close.AutoSize = $true
    $footer.Controls.Add($close); $layout.Controls.Add($footer, 0, 4)
    $dialog.CancelButton = $close; $dialog.AcceptButton = $apply

    $successColor = [System.Drawing.Color]::DarkGreen
    $errorColor = [System.Drawing.Color]::Firebrick
    if ($script:Themes -and $script:CurrentTheme -and $script:Themes[$script:CurrentTheme]) {
        $theme = $script:Themes[$script:CurrentTheme]
        $dialog.BackColor = $theme.FormBackColor; $dialog.ForeColor = $theme.FormForeColor
        function Set-AuditControlTheme($Control) {
            if ($Control -is [System.Windows.Forms.TextBox] -or $Control -is [System.Windows.Forms.ComboBox]) {
                $Control.BackColor = $theme.TextBoxBackColor; $Control.ForeColor = $theme.TextBoxForeColor
            } elseif ($Control -is [System.Windows.Forms.Button]) {
                $Control.BackColor = $theme.ButtonBackColor; $Control.ForeColor = $theme.ButtonForeColor
            } elseif ($Control -is [System.Windows.Forms.Label]) { $Control.ForeColor = $theme.FormForeColor }
            foreach ($child in $Control.Controls) { Set-AuditControlTheme $child }
        }
        Set-AuditControlTheme $layout
        $historyGrid.BackgroundColor = $theme.GridBackColor
        $historyGrid.DefaultCellStyle.BackColor = $theme.GridBackColor; $historyGrid.DefaultCellStyle.ForeColor = $theme.GridForeColor
        $historyGrid.ColumnHeadersDefaultCellStyle.BackColor = $theme.GridHeaderBackColor; $historyGrid.ColumnHeadersDefaultCellStyle.ForeColor = $theme.GridHeaderForeColor
        $historyGrid.EnableHeadersVisualStyles = $false; $historyGrid.GridColor = $theme.FormForeColor
        if ($script:CurrentTheme -eq 'Dark') {
            $successColor = [System.Drawing.Color]::LightGreen
            $errorColor = [System.Drawing.Color]::LightCoral
        }
    }

    $historyGrid.Add_SelectionChanged({
        if ($historyGrid.SelectedRows.Count -eq 0 -or -not $historyGrid.SelectedRows[0].Tag) { return }
        $record = $historyGrid.SelectedRows[0].Tag
        $lines = foreach ($property in $record.PSObject.Properties) {
            $value = if ($property.Value -is [datetime]) { $property.Value.ToString('o') } else { [string]$property.Value }
            '{0}: {1}' -f $property.Name, $value
        }
        $details.Text = $lines -join "`r`n"
    })
    function Refresh-AuditHistoryView {
        $historyGrid.Rows.Clear()
        $details.Text = 'Select an audit row to inspect its complete record.'
        $query = @{
            AuditRoot = $AuditRoot; User = $txtUser.Text.Trim(); Sid = $txtSid.Text.Trim()
            Reason = $txtReasonFilter.Text; Actor = $txtActor.Text.Trim(); Action = [string]$actionFilter.SelectedItem
        }
        if ($fromPicker.Checked) { $query.FromDate = $fromPicker.Value.Date }
        if ($toPicker.Checked) { $query.ToDate = $toPicker.Value.Date }
        try {
            $records = Get-FSLogixAuditHistory @query
            foreach ($record in $records) {
                $rowIndex = $historyGrid.Rows.Add()
                $row = $historyGrid.Rows[$rowIndex]
                foreach ($definition in $columnDefs) { $row.Cells[$definition[0]].Value = $record.($definition[0]) }
                $row.Tag = $record
            }
            $status.ForeColor = $successColor
            $status.Text = if ($records.Count) { "$($records.Count) audit record(s). Times and date filters use UTC." } else { 'No audit records match these filters. Times and date filters use UTC.' }
            $historyGrid.ClearSelection()
        } catch {
            $status.ForeColor = $errorColor
            $status.Text = 'History unavailable: ' + $_.Exception.Message
            if (Get-Command Add-LogMessage -ErrorAction SilentlyContinue) { Add-LogMessage $status.Text 'ERROR' }
        }
    }
    $apply.Add_Click({ Refresh-AuditHistoryView })
    $refresh.Add_Click({ Refresh-AuditHistoryView })
    $clear.Add_Click({
        $txtUser.Clear(); $txtSid.Clear(); $txtReasonFilter.Clear(); $txtActor.Clear()
        $actionFilter.SelectedIndex = 0; $fromPicker.Checked = $false; $toPicker.Checked = $false
        Refresh-AuditHistoryView
    })
    try {
        Refresh-AuditHistoryView
        [void](Show-FSLogixDialog -Dialog $dialog)
    } finally { $dialog.Dispose() }
}
