<#
Real Windows filesystem lifecycle regressions. No real profiles or external services.
Uses synthetic VHDX signature fixtures (not mountable virtual disks).
#>
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixProfileCore.psm1') -Force
$module = Get-Module FSLogixProfileCore
$script:checks = 0
function Assert($name, $actual, $expected) {
    $script:checks++
    if ("$actual" -ne "$expected") { throw "$name : got '$actual', expected '$expected'" }
    Write-Host "  ok $name"
}
function New-Container([string]$path, [string]$payload = 'original') {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
    $bytes = New-Object byte[] (2MB)
    $content = [Text.Encoding]::ASCII.GetBytes('vhdxfile' + $payload)
    [Array]::Copy($content, $bytes, $content.Length)
    [IO.File]::WriteAllBytes($path, $bytes)
    return $path
}
function New-User([string]$root, [string]$name = 'alice') {
    return Join-Path $root ($name + '_S-1-5-21-1-2-3-1001')
}
function Scan-One([string[]]$roots, [switch]$CloudCacheMode) {
    $profiles = Get-FSLogixProfiles -ProfileRoots $roots -CloudCacheMode:$CloudCacheMode
    return $profiles[0]
}
function Retired-One([string]$root) {
    $records = Get-FSLogixRetiredContainer -ProfileRoots $root
    return $records[0]
}
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('fslogix_lifecycle_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($sandbox)
Set-FSLogixLogHandler { param($message, $level) if ($level -eq 'ERROR') { Write-Host $message } }
$audit = Join-Path $sandbox 'audit'
Set-FSLogixAuditRoot $audit
try {
    Write-Host '-- scoped live retire, move/report/restore, displaced-file preservation --'
    $root = Join-Path $sandbox 'scope'
    $userDir = New-User $root
    $profile = New-Container (Join-Path $userDir 'Profile_alice.vhdx')
    $office = New-Container (Join-Path $userDir 'ODFC_alice.vhdx')
    $unknown = New-Container (Join-Path $userDir 'custom.vhdx')
    $r = Rename-FSLogixProfileObject -ProfileObject (Scan-One $root) -Scope Office -MoveToRetired -Reason 'lifecycle test' -BatchStamp '20000101-000001' -Confirm:$false
    Assert 'only Office moved' $r.Renamed 1
    Assert 'Office move has no failures' $r.Failed 0
    Assert 'Profile remains' (Test-Path -LiteralPath $profile) $true
    Assert 'Unknown remains' (Test-Path -LiteralPath $unknown) $true
    Assert 'Office left user folder' (Test-Path -LiteralPath $office) $false
    $record = Retired-One $root
    Assert 'manifest remembers original live path' $record.LivePath $office
    Assert 'moved identity retains SID' $record.Sid 'S-1-5-21-1-2-3-1001'
    Assert 'moved file restore is available' $record.CanRestore $true
    Assert 'no live sibling yet' $record.HasLiveSibling $false
    $r = Restore-FSLogixProfileBatch -Container $record -WhatIf -Confirm:$false
    Assert 'restore WhatIf changes no files' $r.Restored 0
    Assert 'restore WhatIf leaves retirement' (Test-Path -LiteralPath $record.Path) $true
    $null = New-Container $office 'replacement'
    $r = Restore-FSLogixProfileBatch -Container $record -Reason 'restore test' -Confirm:$false
    Assert 'moved restore succeeds' $r.Restored 1
    Assert 'current live is displaced' $r.Displaced 1
    Assert 'restores to original path' (Test-Path -LiteralPath $office) $true
    Assert 'retired file leaves retirement tree' (Test-Path -LiteralPath $record.Path) $false
    Assert 'original bytes restored' ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($office), 8, 8)) 'original'
    $backups = @(Get-ChildItem -LiteralPath $userDir -Filter '*-superseded-*' -File)
    Assert 'replacement preserved once' $backups.Count 1
    Assert 'replacement bytes preserved' ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($backups[0].FullName), 8, 11)) 'replacement'
    Assert 'superseded never scanned as live' (Scan-One $root).ContainerCount 3

    Write-Host '-- multi-container plans, actual locks, collision guards --'
    $root = Join-Path $sandbox 'locks'
    $userDir = New-User $root
    $p = New-Container (Join-Path $userDir 'Profile_alice.vhdx')
    $o = New-Container (Join-Path $userDir 'ODFC_alice.vhdx')
    $row = Scan-One $root
    $handle = [IO.File]::Open($p, 'Open', 'ReadWrite', 'None')
    try {
        $r = Rename-FSLogixProfileObject -ProfileObject $row -Reason test -Confirm:$false
        Assert 'locked container skipped' $r.SkippedInUse 1
        Assert 'unlocked Office still retires' $r.Renamed 1
        Assert 'locked source remains' (Test-Path -LiteralPath $p) $true
    } finally { $handle.Dispose() }
    $old = New-Container (Join-Path $userDir 'Profile_alice-old-20000101-000002.vhdx') 'backup'
    $r = Rename-FSLogixProfileObject -ProfileObject (Scan-One $root) -Scope Profile -BatchStamp '20000101-000002' -Reason test -Confirm:$false
    Assert 'existing backup skipped' $r.SkippedExists 1
    Assert 'collision makes no changes' $r.Renamed 0
    Assert 'backup bytes unchanged' ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($old), 8, 6)) 'backup'

    Write-Host '-- Cloud Cache expands every replica and aborts on any locked replica --'
    $a = Join-Path $sandbox 'cacheA'; $b = Join-Path $sandbox 'cacheB'
    $pa = New-Container (Join-Path (New-User $a) 'Profile_alice.vhdx')
    $pb = New-Container (Join-Path (New-User $b) 'Profile_alice.vhdx')
    $row = Scan-One @($a, $b) -CloudCacheMode
    Assert 'replica count is logical' $row.ContainerCount 1
    $plan = Get-FSLogixRetirePlan -ProfileObject $row -CheckInUse
    Assert 'retire plan includes both providers' $plan.Count 2
    $incomplete = Scan-One @($a, $b, (Join-Path $sandbox 'missingProvider')) -CloudCacheMode
    $r = Rename-FSLogixProfileObject -ProfileObject $incomplete -MoveToRetired -Reason test -Confirm:$false
    Assert 'undiscovered Cloud Cache provider aborts retirement' $r.Aborted $true
    Assert 'incomplete Cloud Cache scan leaves known provider intact' (Test-Path -LiteralPath $pa) $true
    $handle = [IO.File]::Open($pb, 'Open', 'ReadWrite', 'None')
    try {
        $r = Rename-FSLogixProfileObject -ProfileObject $row -MoveToRetired -Reason test -Confirm:$false
        Assert 'one locked replica aborts entire operation' $r.Aborted $true
        Assert 'ready provider unchanged' (Test-Path -LiteralPath $pa) $true
    } finally { $handle.Dispose() }
    $r = Rename-FSLogixProfileObject -ProfileObject $row -MoveToRetired -Reason test -Confirm:$false
    Assert 'all physical replicas retired' $r.Renamed 2
    Assert 'provider A source gone' (Test-Path -LiteralPath $pa) $false
    Assert 'provider B source gone' (Test-Path -LiteralPath $pb) $false
    $records = Get-FSLogixRetiredContainer -ProfileRoots @($a, $b)
    Assert 'retired report includes both replicas' $records.Count 2
    $r = Restore-FSLogixProfileBatch -Container $records -Reason test -Confirm:$false
    Assert 'both provider replicas restored' $r.Restored 2

    Write-Host '-- deterministic mid-operation failures roll back whole batches --'
    $root = Join-Path $sandbox 'rollback'
    $p = New-Container (Join-Path (New-User $root) 'Profile_alice.vhdx')
    $o = New-Container (Join-Path (New-User $root) 'ODFC_alice.vhdx')
    # Keep real audit writes, but fail the second successful RETIRE audit entry.
    & $module {
        $script:SavedAudit = ${function:Write-FSLogixAudit}
        $script:InjectedAuditCount = 0
        function script:Write-FSLogixAudit {
            param([hashtable]$Record, [switch]$Critical)
            if ($Record.Action -eq 'RETIRE' -and $Record.Result -eq 'OK') {
                $script:InjectedAuditCount++
                if ($script:InjectedAuditCount -eq 2) { throw 'Injected audit outage after second move' }
            }
            & $script:SavedAudit -Record $Record -Critical:$Critical
        }
    }
    try {
        $r = Rename-FSLogixProfileObject -ProfileObject (Scan-One $root) -MoveToRetired -AllOrNothing -BatchStamp '20000101-000005' -Reason test -Confirm:$false
        Assert 'mid-retirement failure aborts batch' $r.Aborted $true
        Assert 'retire rollback reports zero remaining moves' $r.Renamed 0
        Assert 'Profile restored by retire rollback' (Test-Path -LiteralPath $p) $true
        Assert 'Office restored by retire rollback' (Test-Path -LiteralPath $o) $true
    } finally { & $module { ${function:Write-FSLogixAudit} = $script:SavedAudit } }
    # Same stamp succeeds after rollback; safe orphan metadata permits retry.
    $r = Rename-FSLogixProfileObject -ProfileObject (Scan-One $root) -MoveToRetired -AllOrNothing -BatchStamp '20000101-000005' -Reason test -Confirm:$false
    Assert 'retirement can retry after rolled-back move' $r.Renamed 2
    $records = Get-FSLogixRetiredContainer -ProfileRoots $root
    $null = New-Container $p 'newProfile'
    $null = New-Container $o 'newOffice'
    & $module {
        $script:InjectedAuditCount = 0
        function script:Write-FSLogixAudit {
            param([hashtable]$Record, [switch]$Critical)
            if ($Record.Action -eq 'RESTORE' -and $Record.Result -eq 'OK') {
                $script:InjectedAuditCount++
                if ($script:InjectedAuditCount -eq 2) { throw 'Injected audit outage after second restore' }
            }
            & $script:SavedAudit -Record $Record -Critical:$Critical
        }
    }
    try {
        $r = Restore-FSLogixProfileBatch -Container $records -Reason test -Confirm:$false
        Assert 'mid-restore failure aborts batch' $r.Aborted $true
        Assert 'restore rollback reports zero restored files' $r.Restored 0
        Assert 'restore rollback reports zero displaced files' $r.Displaced 0
        Assert 'new Profile preserved by restore rollback' ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($p), 8, 10)) 'newProfile'
        Assert 'new Office preserved by restore rollback' ([Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($o), 8, 9)) 'newOffice'
        Assert 'both retired files remain after restore rollback' (@($records | Where-Object { Test-Path -LiteralPath $_.Path }).Count) 2
    } finally { & $module { ${function:Write-FSLogixAudit} = $script:SavedAudit } }

    Write-Host '-- required audit failure blocks retire, restore and irreversible purge --'
    $root = Join-Path $sandbox 'auditFailure'
    $p = New-Container (Join-Path (New-User $root) 'Profile_alice.vhdx')
    $badAudit = Join-Path $sandbox 'not-a-directory'
    [IO.File]::WriteAllText($badAudit, 'block directory creation')
    Set-FSLogixAuditRoot $badAudit
    $r = Rename-FSLogixProfileObject -ProfileObject (Scan-One $root) -Reason test -Confirm:$false
    Assert 'audit outage prevents retirement' $r.Renamed 0
    Assert 'audit outage leaves live file' (Test-Path -LiteralPath $p) $true
    Set-FSLogixAuditRoot $audit
    $r = Rename-FSLogixProfileObject -ProfileObject (Scan-One $root) -BatchStamp '20000101-000003' -Reason test -Confirm:$false
    $record = Retired-One $root
    Set-FSLogixAuditRoot $badAudit
    $r = Restore-FSLogixProfileBatch -Container $record -Reason test -Confirm:$false
    Assert 'audit outage prevents restore' $r.Restored 0
    Assert 'audit outage leaves retired file' (Test-Path -LiteralPath $record.Path) $true
    $null = New-Container $p 'newer'
    $r = Remove-FSLogixRetiredContainer -Container $record -Reason test -Confirm:$false
    Assert 'audit outage prevents purge' $r.Removed 0
    Assert 'audit outage preserves backup' (Test-Path -LiteralPath $record.Path) $true
    Set-FSLogixAuditRoot $audit

    Write-Host '-- purge revalidates stale report, retention, file type, last copy --'
    $records = Get-FSLogixRetiredContainer -ProfileRoots $root
    $record = $records[0]
    Assert 'live sibling is present in report' $record.HasLiveSibling $true
    [IO.File]::Move($p, $p + '.saved')
    $r = Remove-FSLogixRetiredContainer -Container $record -Reason test -Confirm:$false
    Assert 'stale live-sibling report cannot delete last copy' $r.SkippedLastCopy 1
    [IO.File]::Move($p + '.saved', $p)
    $r = Remove-FSLogixRetiredContainer -Container $record -WhatIf -Confirm:$false
    Assert 'purge WhatIf preserves retired file' (Test-Path -LiteralPath $record.Path) $true
    $r = Remove-FSLogixRetiredContainer -Container $record -Reason test -Confirm:$false
    Assert 'eligible purge removes one actual backup' $r.Removed 1
    Assert 'eligible purge leaves live file' (Test-Path -LiteralPath $p) $true
    $spoof = [PSCustomObject]@{ Path = $p; Root = $root; AgeDays = 9999; DateSource = 'stamp'; HasLiveSibling = $true; SizeGB = 999; UserName = 'alice'; Sid = '' }
    $r = Remove-FSLogixRetiredContainer -Container $spoof -AllowLastCopy -IncludeUndated -Reason test -Confirm:$false
    Assert 'caller cannot spoof a live file into purge' $r.Failed 1
    Assert 'spoof attempt preserves live file' (Test-Path -LiteralPath $p) $true
    $new = New-Container (Join-Path (New-User $root) ('Profile_alice-old-' + (New-FSLogixBatchStamp) + '.vhdx'))
    $record = Retired-One $root
    $record.AgeDays = 9999
    $r = Remove-FSLogixRetiredContainer -Container $record -AllowLastCopy -Reason test -Confirm:$false
    Assert 'spoofed age cannot bypass floor' $r.SkippedTooNew 1
    $threw = $false
    try { $null = Remove-FSLogixRetiredContainer -Container $record -RetentionFloorDays 0 -Confirm:$false } catch { $threw = $true }
    Assert '90-day minimum cannot be lowered' $threw $true
    $legacy = New-Container (Join-Path (New-User $root) 'ODFC_alice-old.vhdx')
    [IO.File]::SetLastWriteTime($legacy, (Get-Date).AddDays(-100))
    $records = Get-FSLogixRetiredContainer -ProfileRoots $root
    $legacyRecord = $records | Where-Object Name -eq 'ODFC_alice-old.vhdx'
    $r = Remove-FSLogixRetiredContainer -Container $legacyRecord -AllowLastCopy -Reason test -Confirm:$false
    Assert 'legacy retirement requires IncludeUndated' $r.SkippedUndated 1

    $root = Join-Path $sandbox 'scanHealth'
    $p = New-Container (Join-Path (New-User $root) 'Profile_alice.vhdx')
    [IO.File]::SetLastWriteTime($p, (Get-Date).AddDays(-100))
    $null = New-Container (Join-Path (New-User $root) 'ODFC_alice-old-20000101-000006.vhdx')
    $row = Scan-One $root
    $filtered = Select-FSLogixProfile -Source @($row) -AgeDays 60
    Assert 'newly touched retirement does not hide old live usage' $filtered.Count 1
    Assert 'health contains no nested array strings' ($row.HealthIssues -contains 'System.Object[]') $false
    $profiles = Get-FSLogixProfiles -ProfileRoots $root -ReadVhdMetadata -ConfiguredMaxSizeGB 0.001
    Assert 'scan checks fixture signature' $profiles[0].Containers[0].Signature 'Valid'
    Assert 'scan propagates actual over-limit health' ($profiles[0].HealthIssues -contains 'OVER_LIMIT') $true

    Write-Host '-- actual health, filters, retired timestamps and malformed metadata --'
    $row = Scan-One $root
    Assert 'valid fixture signature is valid' (Test-FSLogixVhdSignature -Path $p) 'Valid'
    $health = Get-FSLogixContainerHealth -Path $p -SizeGB 101 -MaxSizeGB 100 -Signature Invalid
    Assert 'bad signature reported' ($health -contains 'BAD_SIGNATURE') $true
    Assert 'over-limit reported' ($health -contains 'OVER_LIMIT') $true
    $filtered = Select-FSLogixProfile -Source @($row) -ADLastLogonDays 30
    Assert 'unknown AD logon is excluded by inactivity filter' $filtered.Count 0
    $row.ADLastLogon = (Get-Date).AddDays(-100)
    $filtered = Select-FSLogixProfile -Source @($row) -ADLastLogonDays 30
    Assert 'known inactive AD logon matches' $filtered.Count 1
    $root = Join-Path $sandbox 'malformed'
    $moved = New-Container (Join-Path $root '_retired\alice\20000101-000004\Profile_alice-old-20000101-000004.vhdx')
    $record = Retired-One $root
    Assert 'old moved file with no manifest has no safe restore' $record.CanRestore $false
    $r = Restore-FSLogixProfileBatch -Container $record -Reason test -Confirm:$false
    Assert 'unknown original path aborts restore' $r.Aborted $true
    @{ OriginalRelativePath = '..\escape\Profile_alice.vhdx'; UserName = 'alice' } | ConvertTo-Json | Set-Content -LiteralPath ($moved + '.restore.json')
    $record = Retired-One $root
    Assert 'manifest path traversal refused' $record.CanRestore $false

    Write-Host '-- required Horizon gate distinguishes unknown, active and empty sessions --'
    $root = Join-Path $sandbox 'horizonGate'
    $p = New-Container (Join-Path (New-User $root) 'Profile_alice.vhdx')
    $row = Scan-One $root
    Disconnect-FSLogixHorizon
    $r = Rename-FSLogixProfileObject -ProfileObject $row -RequireHorizonCheck -Reason test -Confirm:$false
    Assert 'required Horizon check aborts without a connection' $r.Aborted $true
    & $module {
        $script:SavedSessionQuery = ${function:Get-FSLogixHorizonSession}
        $script:HorizonConnection = [PSCustomObject]@{ Server = 'test.invalid' }
        $script:GateSessions = $null
        function script:Get-FSLogixHorizonSession {
            param([string]$UserName)
            if ($null -eq $script:GateSessions) { return $null }
            return , $script:GateSessions
        }
    }
    try {
        $r = Rename-FSLogixProfileObject -ProfileObject $row -RequireHorizonCheck -Reason test -Confirm:$false
        Assert 'unknown Horizon query aborts retirement' $r.Aborted $true
        & $module { $script:GateSessions = @([PSCustomObject]@{ user_name = 'DOMAIN\alice'; session_state = 'DISCONNECTED' }) }
        $r = Rename-FSLogixProfileObject -ProfileObject $row -RequireHorizonCheck -Reason test -Confirm:$false
        Assert 'disconnected Horizon session aborts retirement' $r.Aborted $true
        Assert 'Horizon refusal preserves live container' (Test-Path -LiteralPath $p) $true
        & $module { $script:GateSessions = @() }
        $r = Rename-FSLogixProfileObject -ProfileObject $row -RequireHorizonCheck -WhatIf -Confirm:$false
        Assert 'verified empty Horizon session collection permits planning' $r.Aborted $false
        Assert 'verified empty Horizon result produces real container plan' $r.Planned 1
    } finally {
        & $module { ${function:Get-FSLogixHorizonSession} = $script:SavedSessionQuery; $script:HorizonConnection = $null }
    }
    Write-Host '-- searchable audit links retain each identity in a multi-user restore --'
    $root = Join-Path $sandbox 'auditIdentity'
    $aliceSid = 'S-1-5-21-1-2-3-2001'; $bobSid = 'S-1-5-21-1-2-3-2002'
    $null = New-Container (Join-Path $root ("alice_$aliceSid\Profile_alice.vhdx"))
    $null = New-Container (Join-Path $root ("bob_$bobSid\Profile_bob.vhdx"))
    $identities = Get-FSLogixProfiles -ProfileRoots $root
    foreach ($identityRow in $identities) {
        $null = Rename-FSLogixProfileObject -ProfileObject $identityRow -MoveToRetired -Reason 'audit identity retire' -Confirm:$false
    }
    $records = Get-FSLogixRetiredContainer -ProfileRoots $root
    $r = Restore-FSLogixProfileBatch -Container $records -Reason 'audit identity restore' -Confirm:$false
    Assert 'multi-user batch restores both identities' $r.Restored 2
    $aliceHistory = Get-FSLogixAuditHistory -AuditRoot $audit -Sid $aliceSid -Action RESTORE
    $bobHistory = Get-FSLogixAuditHistory -AuditRoot $audit -Sid $bobSid -Action RESTORE
    Assert 'Alice SID search finds restore intent and completion' $aliceHistory.Count 2
    Assert 'Bob SID search finds restore intent and completion' $bobHistory.Count 2
    Assert 'Bob restore records keep Bob username' (@($bobHistory | Where-Object TargetUser -ne 'bob').Count) 0
    $aliceRow = $identities | Where-Object Sid -eq $aliceSid
    $details = Get-FSLogixProfileDetails -ProfileObject $aliceRow -AuditRoot $audit
    Assert 'details links actual retirement and restoration' (@($details.AuditHistory | Where-Object Action -eq RESTORE).Count) 2
    Assert 'details excludes other restored identity' (@($details.AuditHistory | Where-Object TargetSid -eq $bobSid).Count) 0
    $auditFiles = @(Get-ChildItem -LiteralPath $audit -Filter actions_*.csv)
    $rows = @(Import-Csv -LiteralPath $auditFiles[0].FullName)
    Assert 'live actions produce real audit records' ($rows.Count -gt 0) $true
    Assert 'audit records carry operator reason' (@($rows | Where-Object Reason -eq 'restore test').Count -gt 0) $true
    Assert 'rollback audit records retain per-file SID' (@($rows | Where-Object { $_.Action -eq 'RESTORE-ROLLBACK' -and -not $_.TargetSid }).Count) 0
    Write-Host "ALL $script:checks LIFECYCLE CHECKS PASSED"
} finally {
    $resolvedSandbox = [IO.Path]::GetFullPath($sandbox)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedSandbox.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolvedSandbox) -like 'fslogix_lifecycle_*') {
        Remove-Item -LiteralPath $resolvedSandbox -Recurse -Force -ErrorAction Stop
    }
}
