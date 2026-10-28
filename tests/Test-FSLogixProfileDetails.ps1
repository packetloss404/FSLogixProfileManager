<# Read-only details tests with actual local files/locks and stubbed external adapters. #>
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixProfileCore.psm1') -Force
$module = Get-Module FSLogixProfileCore
$script:checks = 0
function Check($Name, $Actual, $Expected) {
    if ("$Actual" -ne "$Expected") { throw "$Name : got '$Actual', expected '$Expected'" }
    $script:checks++; Write-Host "  ok   $Name"
}
$fixture = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('.details-fixture_' + [guid]::NewGuid().ToString('N'))))
function New-DetailsFile([string]$Path) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    $bytes = New-Object byte[] 4096
    [Text.Encoding]::ASCII.GetBytes('vhdxfile').CopyTo($bytes, 0)
    [IO.File]::WriteAllBytes($Path, $bytes)
    return $Path
}
try {
    $rootA = Join-Path $fixture 'providerA'; $rootB = Join-Path $fixture 'providerB'
    $sid = 'S-1-5-21-10-20-30-1001'; $otherSid = 'S-1-5-21-10-20-30-1002'
    $live = New-DetailsFile (Join-Path $rootA ("alice_$sid\Profile_alice.vhdx"))
    $office = New-DetailsFile (Join-Path $rootA ("alice_$sid\ODFC_alice.vhdx"))
    $replica = New-DetailsFile (Join-Path $rootB ("alice_$sid\Profile_alice.vhdx"))
    $otherLive = New-DetailsFile (Join-Path $rootA ("alice_$otherSid\Profile_alice.vhdx"))
    $retiredPath = New-DetailsFile (Join-Path $rootA ("alice_$sid\Profile_alice-old-20200101-010101.vhdx"))
    $otherRetired = New-DetailsFile (Join-Path $rootA ("alice_$otherSid\Profile_alice-old-20200101-010101.vhdx"))
    $audit = Join-Path $fixture 'audit'; [void][IO.Directory]::CreateDirectory($audit)
    Set-FSLogixAuditRoot $audit
    Set-FSLogixLogHandler { param($Message,$Level) }
    $rows = Get-FSLogixProfiles -ProfileRoots @($rootA,$rootB) -CloudCacheMode
    $row = $rows | Where-Object Sid -eq $sid
    $row.ADStatus = 'OK'; $row.ADDisabled = $false; $row.ADResolvedName = 'renamedAlice'
    $row.ADLastLogon = (Get-Date).AddDays(-10)
    Write-FSLogixAudit -Record @{Action='RETIRE';Mode='LIVE';Reason='CHG101';TargetUser='alice';TargetSid=$sid;SourcePath=$live;DestPath=$retiredPath;Result='OK'}
    Write-FSLogixAudit -Record @{Action='RESTORE';Mode='LIVE';Reason='Legacy path match';TargetUser='(unknown)';SourcePath=$retiredPath;DestPath=$live;Result='OK'}
    Write-FSLogixAudit -Record @{Action='RETIRE';Mode='LIVE';Reason='Wrong SID';TargetUser='alice';TargetSid=$otherSid;SourcePath=$live;Result='OK'}
    Write-FSLogixAudit -Record @{Action='RETIRE';Mode='LIVE';Reason='Same username only';TargetUser='alice';SourcePath=$otherLive;Result='OK'}
    $beforeBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($live))
    $auditFile = @(Get-ChildItem -LiteralPath $audit -Filter actions_*.csv)[0].FullName
    $beforeAudit = [IO.File]::ReadAllText($auditFile)

    $details = Get-FSLogixProfileDetails -ProfileObject $row -AuditRoot $audit
    Check 'stable SID retained' $details.Sid $sid
    Check 'AD metadata retained' $details.ADResolvedName 'renamedAlice'
    Check 'logical count is distinct from physical files' $details.ScanContainerCount 2
    Check 'physical replicas expanded' $details.Containers.Count 3
    Check 'replica identified explicitly' (@($details.Containers | Where-Object IsReplica).Count) 1
    Check 'initial availability is not checked' $details.AvailabilityStatus 'NotChecked'
    Check 'initial local file state is not checked' (($details.Containers | Where-Object Path -eq $live).Availability) 'NotChecked'
    Check 'unknown signature stays unknown' (($details.Containers | Where-Object Path -eq $live).Signature) 'Unknown'
    Check 'unknown maximum stays null' ($null -eq ($details.Containers | Where-Object Path -eq $live).MaxSizeGB) $true
    Check 'current file size is actual disk length' (($details.Containers | Where-Object Path -eq $live).SizeGB) 0
    Check 'retired files use stable SID isolation' $details.RetiredContainers.Count 1
    Check 'retired history points to original live file' $details.RetiredContainers[0].LivePath $live
    Check 'history matches SID plus legacy exact paths' $details.AuditHistory.Count 2
    Check 'wrong explicit SID is excluded even on same path' (@($details.AuditHistory | Where-Object Reason -eq 'Wrong SID').Count) 0
    Check 'same-name different identity excluded' (@($details.AuditHistory | Where-Object Reason -eq 'Same username only').Count) 0
    Check 'no Horizon connection is explicit' $details.HorizonStatus 'NotConfigured'
    Check 'snapshot describes metadata origin' ($details.MetadataNote -match 'from the profile scan') $true
    $primaryContainer = $row.Containers | Where-Object Path -eq $live
    $primaryContainer.Signature='Valid'; $primaryContainer.MaxSizeGB=40; $primaryContainer.Issues=@('NEAR_LIMIT')
    $details = Get-FSLogixProfileDetails -ProfileObject $row -AuditRoot $audit
    Check 'primary signature remains scan metadata' (($details.Containers | Where-Object Path -eq $live).Signature) 'Valid'
    Check 'replica never inherits primary valid signature' (($details.Containers | Where-Object Path -eq $replica).Signature) 'Unknown'
    Check 'replica never inherits primary maximum size' ($null -eq ($details.Containers | Where-Object Path -eq $replica).MaxSizeGB) $true
    Check 'replica health is visibly uninspected' (($details.Containers | Where-Object Path -eq $replica).Health) 'Not inspected'
    $lock = [IO.File]::Open($live, 'Open', 'ReadWrite', 'None')
    try {
        $details = Get-FSLogixProfileDetails -ProfileObject $row -AuditRoot $audit -RefreshAvailability
        Check 'real local file lock is detected' (($details.Containers | Where-Object Path -eq $live).Availability) 'InUse'
        Check 'unlocked replica remains free' (($details.Containers | Where-Object Path -eq $replica).Availability) 'Free'
        Check 'fallback probe is labelled best effort' (($details.Containers | Where-Object Path -eq $replica).AvailabilitySource -match 'best effort') $true
    } finally { $lock.Dispose() }
    Check 'details never modifies container bytes' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($live))) $beforeBytes
    Check 'details never appends audit events' ([IO.File]::ReadAllText($auditFile)) $beforeAudit

    $missingRow = $row.PSObject.Copy()
    $missingRow.Containers = @($row.Containers[0].PSObject.Copy())
    $missingRow.Containers[0].Path = Join-Path $rootA 'missing.vhdx'; $missingRow.Containers[0].ReplicaPaths = @()
    $missingRow.ProfileRoots = @((Join-Path $fixture 'unavailable'))
    $details = Get-FSLogixProfileDetails -ProfileObject $missingRow -AuditRoot $audit -RefreshAvailability
    Check 'vanished container is missing' $details.Containers[0].Availability 'Missing'
    Check 'missing metadata is unknown size' ($null -eq $details.Containers[0].SizeGB) $true
    Check 'unavailable retirement root is visible' $details.RetiredStatus 'Unavailable'
    Check 'retirement warning has reason' (($details.Messages -join ' ') -match 'Profile root unavailable') $true

    & $module {
        $script:DetailsSavedState = ${function:Get-FSLogixContainerState}
        function script:Get-FSLogixContainerState { param($Path,$OpenHandles) throw 'synthetic probe failure' }
    }
    try {
        $details = Get-FSLogixProfileDetails -ProfileObject $row -AuditRoot $audit -RefreshAvailability
        Check 'probe errors cannot show Free' (@($details.Containers | Where-Object Availability -eq 'Unknown').Count) 3
        Check 'probe error reason visible' (($details.Messages -join ' ') -match 'synthetic probe failure') $true
    } finally { & $module { ${function:Get-FSLogixContainerState} = $script:DetailsSavedState } }

    & $module {
        $script:DetailsSavedSession = ${function:Get-FSLogixHorizonSession}
        $script:DetailsSessionCalls = 0
        $script:HorizonConnection = [pscustomobject]@{Server='synthetic.invalid'}
        function script:Get-FSLogixHorizonSession {
            param($UserName)
            $script:DetailsSessionCalls++
            return ,@([pscustomobject]@{id='session-01';user_name='LAB\alice';session_state='DISCONNECTED';machine_dns_name='desktop01.lab.invalid'})
        }
    }
    try {
        $details = Get-FSLogixProfileDetails -ProfileObject $row -AuditRoot $audit
        Check 'connected Horizon is not queried on open' (& $module {$script:DetailsSessionCalls}) 0
        Check 'unqueried connection shown honestly' $details.HorizonStatus 'NotChecked'
        $details = Get-FSLogixProfileDetails -ProfileObject $row -AuditRoot $audit -RefreshAvailability
        Check 'explicit refresh queries connected Horizon' (& $module {$script:DetailsSessionCalls}) 1
        Check 'valid response marked verified' $details.HorizonStatus 'Verified'
        Check 'disconnected state visible' $details.HorizonSessions[0].State 'DISCONNECTED'
        Check 'session host visible if supplied' $details.HorizonSessions[0].Host 'desktop01.lab.invalid'
        & $module { function script:Get-FSLogixHorizonSession {param($UserName) return $null} }
        $details = Get-FSLogixProfileDetails -ProfileObject $row -AuditRoot $audit -RefreshAvailability
        Check 'unknown Horizon response not empty verified sessions' $details.HorizonStatus 'Unknown'
        Check 'Horizon uncertainty explained' (($details.Messages -join ' ') -match 'session status unknown') $true
    } finally { & $module { ${function:Get-FSLogixHorizonSession} = $script:DetailsSavedSession; $script:HorizonConnection = $null } }

    [IO.File]::WriteAllText($auditFile, 'malformed CSV header')
    $details = Get-FSLogixProfileDetails -ProfileObject $row -AuditRoot $audit
    Check 'malformed audit source is unavailable' $details.AuditStatus 'Unavailable'
    Check 'unavailable audit is explained' (($details.Messages -join ' ') -match 'Audit history unavailable') $true
    $empty = $row.PSObject.Copy(); $empty.Containers=@(); $empty.RetiredContainers=@(); $empty.ProfileRoots=@()
    $details = Get-FSLogixProfileDetails -ProfileObject $empty -AuditRoot $audit
    Check 'zero live files retains array shape' ($details.Containers -is [array] -and $details.Containers.Count -eq 0) $true
    Write-Host "ALL $script:checks PROFILE DETAILS CHECKS PASSED"
} finally {
    $prefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\.details-fixture_'
    if ($fixture.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $fixture -Recurse -Force -ErrorAction SilentlyContinue }
}
