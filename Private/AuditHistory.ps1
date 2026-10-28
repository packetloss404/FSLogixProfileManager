function Get-FSLogixAuditHistory {
    <#
    .SYNOPSIS
        Read and search monthly FSLogix audit CSVs without changing them.
    .DESCRIPTION
        Returns an array, newest first. Text filters are literal and case insensitive;
        Sid, Action and ContainerPath match whole values. Date limits include the entire
        selected UTC calendar day. Malformed or unreadable files fail the query explicitly
        rather than returning a misleading partial history. Missing optional legacy
        columns are normalized to empty strings; TimestampUtc, Action and Result are required.
    #>
    [CmdletBinding()]
    param(
        [string]$AuditRoot = (Get-FSLogixAuditRoot),
        [string]$User,
        [string]$Sid,
        [string]$Reason,
        [string]$Actor,
        [string]$Action,
        [datetime]$FromDate,
        [datetime]$ToDate,
        [string[]]$ContainerPath
    )

    if ([string]::IsNullOrWhiteSpace($AuditRoot)) { throw 'An audit directory is required.' }
    if ($PSBoundParameters.ContainsKey('FromDate') -and $PSBoundParameters.ContainsKey('ToDate') -and $FromDate.Date -gt $ToDate.Date) {
        throw 'The From date must not be after the To date.'
    }
    if (-not (Test-Path -LiteralPath $AuditRoot -PathType Container -ErrorAction Stop)) {
        throw "Audit directory is unavailable: $AuditRoot"
    }
    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    $columns = @('TimestampUtc','Actor','ActorHost','Tool','Action','Mode','Reason','TargetUser','TargetSid','SourcePath','DestPath','SizeGB','Result','HolderInfo','HorizonSessionState')
    $records = New-Object System.Collections.Generic.List[object]
    $files = @(Get-ChildItem -LiteralPath $AuditRoot -Filter 'actions_*.csv' -File -ErrorAction Stop | Where-Object { $_.Name -match '^actions_\d{4}-(0[1-9]|1[0-2])\.csv$' } | Sort-Object Name)
    foreach ($file in $files) {
        $stream = $null; $parser = $null
        try {
            # Audit writers can append while a reader is open. A partial record is an
            # explicit query error; Refresh can retry after the writer completes.
            $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($stream, [Text.Encoding]::UTF8, $true)
            $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
            $parser.SetDelimiters(',')
            $parser.HasFieldsEnclosedInQuotes = $true
            $parser.TrimWhiteSpace = $false
            if ($parser.EndOfData) { throw 'The file has no CSV header.' }
            $header = $parser.ReadFields()
            $seen = @{}
            foreach ($name in $header) {
                if ([string]::IsNullOrWhiteSpace($name) -or $seen.ContainsKey($name)) { throw 'CSV header has an empty or duplicate column.' }
                $seen[$name] = $true
            }
            foreach ($required in @('TimestampUtc','Action','Result')) {
                if (-not $seen.ContainsKey($required)) { throw "CSV header is missing $required." }
            }
            $rowNumber = 1
            while (-not $parser.EndOfData) {
                $rowNumber++
                $fields = $parser.ReadFields()
                if ($fields.Count -ne $header.Count) { throw "Record $rowNumber has $($fields.Count) fields; expected $($header.Count)." }
                $values = [ordered]@{}
                for ($index = 0; $index -lt $header.Count; $index++) { $values[$header[$index]] = $fields[$index] }
                foreach ($name in $columns) { if (-not $values.Contains($name)) { $values[$name] = '' } }
                $timestamp = [datetimeoffset]::MinValue
                if (-not [datetimeoffset]::TryParse([string]$values.TimestampUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$timestamp)) {
                    throw "Record $rowNumber has an invalid TimestampUtc."
                }
                $values.TimestampUtc = $timestamp.UtcDateTime
                $values['AuditFile'] = $file.FullName
                $values['AuditRow'] = $rowNumber
                $record = [pscustomobject]$values

                if ($User -and $record.TargetUser.IndexOf($User, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                if ($Sid -and -not [string]::Equals($record.TargetSid, $Sid, [StringComparison]::OrdinalIgnoreCase)) { continue }
                if ($Reason -and $record.Reason.IndexOf($Reason, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                if ($Actor -and $record.Actor.IndexOf($Actor, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
                if ($Action -and $Action -ne 'All' -and -not [string]::Equals($record.Action, $Action, [StringComparison]::OrdinalIgnoreCase)) { continue }
                if ($PSBoundParameters.ContainsKey('FromDate') -and $record.TimestampUtc.Date -lt $FromDate.Date) { continue }
                if ($PSBoundParameters.ContainsKey('ToDate') -and $record.TimestampUtc.Date -gt $ToDate.Date) { continue }
                if ($ContainerPath -and @($ContainerPath | Where-Object {
                    [string]::Equals($_, $record.SourcePath, [StringComparison]::OrdinalIgnoreCase) -or
                    [string]::Equals($_, $record.DestPath, [StringComparison]::OrdinalIgnoreCase)
                }).Count -eq 0) { continue }
                $records.Add($record)
            }
        } catch {
            throw "Unable to read audit history from '$($file.FullName)': $($_.Exception.Message)"
        } finally {
            if ($parser) { $parser.Dispose() }
            elseif ($stream) { $stream.Dispose() }
        }
    }
    return ,@($records | Sort-Object TimestampUtc, AuditFile, AuditRow -Descending)
}
