function Get-FSLogixProfileDetails {
    <#
    .SYNOPSIS
        Build a read-only per-identity detail snapshot from a discovered profile.
    .DESCRIPTION
        Scan metadata is labelled separately from current file metadata. SMB/lock and
        Horizon checks run only when RefreshAvailability is requested. No containers,
        audit files, sessions, or configuration are modified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ProfileObject,
        [string]$AuditRoot,
        [switch]$RefreshAvailability
    )

    $messages = New-Object System.Collections.ArrayList
    $knownPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $physical = @()
    foreach ($container in @($ProfileObject.Containers)) {
        if ($null -eq $container) { continue }
        foreach ($path in @($container.Path) + @($container.ReplicaPaths)) {
            if ([string]::IsNullOrWhiteSpace($path) -or -not $knownPaths.Add([IO.Path]::GetFullPath($path))) { continue }
            $physical += [pscustomobject]@{ Path = [IO.Path]::GetFullPath($path); Container = $container; IsReplica = ($path -ne $container.Path) }
        }
    }
    foreach ($old in @($ProfileObject.RetiredContainers)) {
        if ($old.Path) { [void]$knownPaths.Add([IO.Path]::GetFullPath($old.Path)) }
        if ($old.LivePath) { [void]$knownPaths.Add([IO.Path]::GetFullPath($old.LivePath)) }
        elseif ($old.Directory -and $old.LiveName) { [void]$knownPaths.Add([IO.Path]::GetFullPath((Join-Path $old.Directory $old.LiveName))) }
    }

    $handlesByServer = @{}
    if ($RefreshAvailability) {
        foreach ($server in @($physical | Group-Object -Property {
            if ($_.Path -match '^\\\\(?<server>[^\\]+)\\') { $Matches.server.ToLowerInvariant() } else { '[local]' }
        })) {
            try { $handlesByServer[$server.Name] = Get-FSLogixOpenHandle -Path @($server.Group.Path) }
            catch {
                $handlesByServer[$server.Name] = $null
                [void]$messages.Add("SMB lookup failed: $($_.Exception.Message). File locks use the fallback probe.")
            }
        }
    }

    $containers = @()
    foreach ($entry in $physical) {
        $source = $entry.Container
        $currentSize = $null; $currentWrite = $null; $metadataStatus = 'Current'; $metadataError = ''
        try {
            $file = Get-Item -LiteralPath $entry.Path -ErrorAction Stop
            if ($file.PSIsContainer) { throw 'Container path is a directory.' }
            $currentSize = [Math]::Round($file.Length / 1GB, 3)
            $currentWrite = $file.LastWriteTime
        } catch {
            $metadataStatus = if ($_.Exception -is [UnauthorizedAccessException]) { 'AccessDenied' } elseif ($_.CategoryInfo.Category -eq 'ObjectNotFound') { 'Missing' } else { 'Unknown' }
            $metadataError = $_.Exception.Message
        }
        $state = 'NotChecked'; $holder = ''; $availabilitySource = 'Not checked'
        if ($RefreshAvailability) {
            $serverKey = if ($entry.Path -match '^\\\\(?<server>[^\\]+)\\') { $Matches.server.ToLowerInvariant() } else { '[local]' }
            try {
                $handles = $handlesByServer[$serverKey]
                $probe = Get-FSLogixContainerState -Path $entry.Path -OpenHandles $handles
                $state = $probe.State; $holder = $probe.Holder
                $availabilitySource = if ($null -eq $handles) { 'Exclusive-open probe (best effort)' } else { 'SMB open handles (best effort)' }
                if ($state -notin @('Free','InUse','AccessDenied','Missing')) { $state = 'Unknown' }
            } catch {
                $state = 'Unknown'; $availabilitySource = 'Probe failed'
                [void]$messages.Add("Availability failed for $($entry.Path): $($_.Exception.Message)")
            }
        }
        # Never let a successful weak probe conceal a failed metadata read.
        if ($metadataStatus -in @('Unknown','AccessDenied','Missing')) { $state = $metadataStatus }
        $containers += [pscustomobject]@{
            Name = [IO.Path]::GetFileName($entry.Path); Class = $source.Class
            IsReplica = $entry.IsReplica; SizeGB = $currentSize; LastWriteTime = $currentWrite
            Availability = $state; Holder = $holder; AvailabilitySource = $availabilitySource
            Signature = $(if (-not $entry.IsReplica -and $source.Signature) { $source.Signature } else { 'Unknown' })
            MaxSizeGB = $(if (-not $entry.IsReplica) { $source.MaxSizeGB } else { $null })
            Health = $(if ($entry.IsReplica) { 'Not inspected' } else { @($source.Issues) -join ', ' })
            MetadataOrigin = $(if ($entry.IsReplica) { 'Replica path recorded; no replica-specific scan health metadata' } else { 'Primary file scan metadata' })
            Path = $entry.Path; ScanSizeGB = $source.SizeGB; ScanLastWriteTime = $source.LastWriteTime
            MetadataStatus = $metadataStatus; MetadataError = $metadataError
        }
    }

    $retired = @(); $retiredStatus = 'Available'
    $roots = @($ProfileObject.ProfileRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    try {
        foreach ($root in $roots) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "Profile root unavailable: $root" }
        }
        if ($roots.Count -gt 0) {
            # The report is read-only. Escalate enumeration errors rather than showing
            # an incomplete list as an authoritative empty recovery history.
            $retiredErrors = @()
            $allRetired = Get-FSLogixRetiredContainer -ProfileRoots $roots -ErrorOnIncomplete -ErrorVariable +retiredErrors
            if ($retiredErrors.Count -gt 0) { throw 'One or more retirement paths could not be read.' }
            $retired = @($allRetired | Where-Object {
                if ($ProfileObject.Sid -and $_.Sid) { $_.Sid -eq $ProfileObject.Sid }
                elseif ($_.LivePath -and $knownPaths.Contains([IO.Path]::GetFullPath($_.LivePath))) { $true }
                elseif ($_.Path -and $knownPaths.Contains([IO.Path]::GetFullPath($_.Path))) { $true }
                elseif (-not $ProfileObject.Sid -and $ProfileObject.IsIdentityResolved -and -not $_.Sid) { $_.UserName -eq $ProfileObject.UserName }
                else { $false }
            })
        }
        foreach ($item in $retired) {
            if ($item.Path) { [void]$knownPaths.Add([IO.Path]::GetFullPath($item.Path)) }
            if ($item.LivePath) { [void]$knownPaths.Add([IO.Path]::GetFullPath($item.LivePath)) }
        }
    } catch {
        $retiredStatus = 'Unavailable'; $retired = @()
        [void]$messages.Add("Retired history unavailable: $($_.Exception.Message)")
    }

    $history = @(); $historyStatus = 'Available'
    try {
        $historyArgs = @{}
        if ($PSBoundParameters.ContainsKey('AuditRoot')) { $historyArgs.AuditRoot = $AuditRoot }
        $allHistory = Get-FSLogixAuditHistory @historyArgs
        $history = @($allHistory | Where-Object {
            if ($ProfileObject.Sid -and $_.TargetSid) { $_.TargetSid -eq $ProfileObject.Sid }
            elseif (-not $ProfileObject.Sid -and $_.TargetSid) { $false }
            elseif (($_.SourcePath -and $knownPaths.Contains($_.SourcePath)) -or ($_.DestPath -and $knownPaths.Contains($_.DestPath))) { $true }
            elseif (-not $ProfileObject.Sid -and $ProfileObject.IsIdentityResolved) { $_.TargetUser -eq $ProfileObject.UserName }
            else { $false }
        })
    } catch {
        $historyStatus = 'Unavailable'
        [void]$messages.Add("Audit history unavailable: $($_.Exception.Message)")
    }

    $sessionStatus = 'NotConfigured'; $sessions = @()
    if (Test-FSLogixHorizonConnected) {
        $sessionStatus = 'NotChecked'
        if ($RefreshAvailability) {
            try {
                $rawSessions = Get-FSLogixHorizonSession -UserName $ProfileObject.UserName
                if ($null -eq $rawSessions) { throw 'The connected server did not return a verified session inventory.' }
                $sessionStatus = 'Verified'
                $sessions = @($rawSessions | ForEach-Object {
                    $machine = @($_.machine_dns_name, $_.machine_name, $_.dns_name, $_.computer_name, $_.desktop_name) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
                    $state = @($_.session_state, $_.state) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
                    [pscustomobject]@{ Id = $_.id; UserName = $_.user_name; State = $state; Host = $machine }
                })
            } catch {
                $sessionStatus = 'Unknown'
                [void]$messages.Add("Horizon session status unknown: $($_.Exception.Message)")
            }
        }
    }

    [pscustomobject]@{
        UserName = $ProfileObject.UserName; Sid = $ProfileObject.Sid
        SIDs = @($ProfileObject.SIDs); IdentitySource = $ProfileObject.IdentitySource
        ADStatus = $ProfileObject.ADStatus; ADLastLogon = $ProfileObject.ADLastLogon
        ADDisabled = $ProfileObject.ADDisabled; ADResolvedName = $ProfileObject.ADResolvedName
        HealthIssues = @($ProfileObject.HealthIssues); ProfileRoots = $roots
        ScanContainerCount = $ProfileObject.ContainerCount; ScanTotalSizeGB = $ProfileObject.TotalSizeGB
        SnapshotAt = Get-Date; Containers = @($containers); RetiredContainers = @($retired)
        AuditHistory = @($history); HorizonSessions = @($sessions)
        AvailabilityStatus = $(if ($RefreshAvailability) { 'Refreshed (best effort)' } else { 'NotChecked' })
        RetiredStatus = $retiredStatus; AuditStatus = $historyStatus; HorizonStatus = $sessionStatus
        Messages = @($messages)
        MetadataNote = 'AD, health, signature and maximum size are from the profile scan. Refresh updates file metadata and availability; it does not run a new AD or VHD metadata scan.'
    }
}
