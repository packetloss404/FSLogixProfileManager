#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixProfileCore.psm1') -Force
$script:checks = 0
function Assert([string]$Name, [bool]$Condition) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:checks++; Write-Host "  ok   $Name"
}
function Assert-Throws([string]$Name, [scriptblock]$Action) {
    $caught = $false
    try { & $Action } catch { $caught = $true }
    Assert $Name $caught
}
$fixture = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('.audit-fixture_' + [guid]::NewGuid().ToString('N'))))
try {
    [void][IO.Directory]::CreateDirectory($fixture)
    $audit = Join-Path $fixture 'audit'; [void][IO.Directory]::CreateDirectory($audit)
    Set-FSLogixAuditRoot -Path $audit
    $empty = Get-FSLogixAuditHistory
    Assert 'empty history is an array' ($empty -is [array] -and $empty.Count -eq 0)
    Assert 'empty query creates no audit files' (@(Get-ChildItem -LiteralPath $audit).Count -eq 0)
    function New-Row($Timestamp, $User, $Sid, $Action, $Result, $Reason, $Source) {
        [pscustomobject][ordered]@{
            TimestampUtc=$Timestamp; Actor='LAB\ops[1]'; ActorHost='host01'; Tool='FSLogixProfileManager'
            Action=$Action; Mode='LIVE'; Reason=$Reason; TargetUser=$User; TargetSid=$Sid
            SourcePath=$Source; DestPath=($Source + '-old'); SizeGB='1.25'; Result=$Result
            HolderInfo=''; HorizonSessionState=''; ExtraField='preserve me'
        }
    }
    $source = 'D:\Profiles\alice_S-1-5-21-1\Profile_alice.vhdx'
    $multiline = "CHG-42 [literal], `"quoted`"`r`nSecond line: caf$([char]0x00e9)"
    @(
        (New-Row '2026-10-10T00:00:00.0000000Z' 'alice' 'S-1-5-21-1' 'RETIRE' 'STARTED' $multiline $source),
        (New-Row '2026-10-10T23:59:59.9999999Z' 'alice' 'S-1-5-21-1' 'RETIRE' 'OK' $multiline $source),
        (New-Row '2026-10-11T12:00:00.0000000Z' 'alice' 'S-1-5-21-2' 'RESTORE' 'OK' 'CHG-43' 'D:\Other\Profile_alice.vhdx')
    ) | Export-Csv -LiteralPath (Join-Path $audit 'actions_2026-10.csv') -NoTypeInformation -Encoding UTF8
    @(
        (New-Row '2026-09-10T12:00:00.0000000Z' 'bob' 'S-1-5-21-3' 'RETIRE-ROLLBACK' 'OK' 'CHG-40' 'D:\Profiles\bob.vhdx'),
        (New-Row '2026-09-09T12:00:00.0000000Z' 'a[1]' '' 'PURGE' 'FAILED: denied' 'literal * ticket' 'D:\Profiles\a[1].vhdx')
    ) | Export-Csv -LiteralPath (Join-Path $audit 'actions_2026-09.csv') -NoTypeInformation -Encoding UTF8
    [IO.File]::WriteAllText((Join-Path $audit 'unrelated.csv'), 'not audit data')
    [IO.File]::WriteAllText((Join-Path $audit 'actions_2026-99.csv'), 'not a real monthly audit')
    $before = @(Get-ChildItem -LiteralPath $audit -File | Get-FileHash | Select-Object Path,Hash)
    $rows = Get-FSLogixAuditHistory -AuditRoot $audit
    Assert 'multiple months load all five rows' ($rows.Count -eq 5)
    Assert 'timestamps are typed UTC DateTime' ($rows[0].TimestampUtc -is [datetime] -and $rows[0].TimestampUtc.Kind -eq 'Utc')
    Assert 'history is newest first' ($rows[0].TargetSid -eq 'S-1-5-21-2' -and $rows[4].TargetUser -eq 'a[1]')
    Assert 'all original fields retained' ($rows[0].ExtraField -eq 'preserve me' -and $rows[0].ActorHost -eq 'host01')
    Assert 'file provenance retained' ((Split-Path -Leaf $rows[0].AuditFile) -eq 'actions_2026-10.csv' -and $rows[0].AuditRow -eq 4)
    $found = Get-FSLogixAuditHistory -User 'ALI'
    Assert 'user filter is case insensitive substring' ($found.Count -eq 3)
    $found = Get-FSLogixAuditHistory -Sid 's-1-5-21-1'
    Assert 'SID filter keeps same-name identities separate' ($found.Count -eq 2)
    $found = Get-FSLogixAuditHistory -Sid 'S-1-5-21'
    Assert 'SID is a whole-value match' ($found.Count -eq 0)
    $found = Get-FSLogixAuditHistory -User '['
    Assert 'brackets are literal search input' ($found.Count -eq 1 -and $found[0].TargetUser -eq 'a[1]')
    $found = Get-FSLogixAuditHistory -Reason '*'
    Assert 'asterisk is literal search input' ($found.Count -eq 1 -and $found[0].Action -eq 'PURGE')
    $found = Get-FSLogixAuditHistory -Reason '[literal]' -Actor 'OPS[1]' -Action 'retire'
    Assert 'combined filters intersect literally' ($found.Count -eq 2)
    Assert 'UTF8 multiline quoted reason round trips' ($found[0].Reason -eq $multiline)
    $found = Get-FSLogixAuditHistory -Action 'RETIRE'
    Assert 'action match excludes rollback suffix' ($found.Count -eq 2)
    $found = Get-FSLogixAuditHistory -Action All
    Assert 'All action includes rollback and failure records' ($found.Count -eq 5 -and @($found | Where-Object Result -like 'FAILED:*').Count -eq 1)
    $found = Get-FSLogixAuditHistory -FromDate ([datetime]'2026-10-10') -ToDate ([datetime]'2026-10-10')
    Assert 'date bounds include whole UTC calendar day' ($found.Count -eq 2)
    $found = Get-FSLogixAuditHistory -FromDate ([datetime]'2026-10-11')
    Assert 'From date can be used alone' ($found.Count -eq 1)
    $found = Get-FSLogixAuditHistory -ToDate ([datetime]'2026-09-10')
    Assert 'To date can be used alone' ($found.Count -eq 2)
    $found = Get-FSLogixAuditHistory -ContainerPath $source.ToUpperInvariant()
    Assert 'container path match is whole and case insensitive' ($found.Count -eq 2)
    $found = Get-FSLogixAuditHistory -ContainerPath ($source + '-old')
    Assert 'container path also matches destination' ($found.Count -eq 2)
    $found = Get-FSLogixAuditHistory -ContainerPath $source -Sid 'S-1-5-21-2'
    Assert 'path and SID filter intersect' ($found.Count -eq 0)
    $found = Get-FSLogixAuditHistory -User bob
    Assert 'single record still returns an array' ($found -is [array] -and $found.Count -eq 1)
    $found = Get-FSLogixAuditHistory -User nobody
    Assert 'no matches returns empty array' ($found -is [array] -and $found.Count -eq 0)
    Assert-Throws 'reversed date range is rejected' { Get-FSLogixAuditHistory -FromDate ([datetime]'2026-10-11') -ToDate ([datetime]'2026-10-10') }
    Assert-Throws 'missing audit directory is unavailable' { Get-FSLogixAuditHistory -AuditRoot (Join-Path $fixture 'missing') }
    Assert 'query never creates unavailable directory' (-not (Test-Path -LiteralPath (Join-Path $fixture 'missing')))
    $locked = [IO.File]::Open((Join-Path $audit 'actions_2026-10.csv'), 'Open', 'Read', 'None')
    try { Assert-Throws 'unreadable audit file is explicit error' { Get-FSLogixAuditHistory } } finally { $locked.Dispose() }
    $after = @(Get-ChildItem -LiteralPath $audit -File | Get-FileHash | Select-Object Path,Hash)
    Assert 'queries never modify audit source files' (($before | ConvertTo-Json -Compress) -eq ($after | ConvertTo-Json -Compress))
    $bad = Join-Path $fixture 'bad'; [void][IO.Directory]::CreateDirectory($bad)
    $badFile = Join-Path $bad 'actions_2026-01.csv'
    [IO.File]::WriteAllText($badFile, 'TimestampUtc,Action,Result' + "`r`n" + 'not-a-date,RETIRE,OK')
    Assert-Throws 'invalid date is explicit error even for excluded user' { Get-FSLogixAuditHistory -AuditRoot $bad -User nobody }
    [IO.File]::WriteAllText($badFile, 'Action,Result' + "`r`n" + 'RETIRE,OK')
    Assert-Throws 'missing timestamp header is explicit error' { Get-FSLogixAuditHistory -AuditRoot $bad }
    [IO.File]::WriteAllText($badFile, 'TimestampUtc,Action,Result,Result' + "`r`n" + '2026-01-01,RETIRE,OK,OK')
    Assert-Throws 'duplicate CSV header is explicit error' { Get-FSLogixAuditHistory -AuditRoot $bad }
    [IO.File]::WriteAllText($badFile, 'TimestampUtc,Action,Result' + "`r`n" + '2026-01-01,RETIRE,OK,extra')
    Assert-Throws 'extra CSV field is explicit error' { Get-FSLogixAuditHistory -AuditRoot $bad }
    [IO.File]::WriteAllText($badFile, 'TimestampUtc,Action,Result' + "`r`n" + '2026-01-01,RETIRE,"unterminated')
    Assert-Throws 'malformed quoted record is explicit error' { Get-FSLogixAuditHistory -AuditRoot $bad }
    [IO.File]::WriteAllText($badFile, '')
    Assert-Throws 'zero-byte monthly file is explicit error' { Get-FSLogixAuditHistory -AuditRoot $bad }
    [IO.File]::WriteAllText($badFile, 'TimestampUtc,Action,Result' + "`r`n" + '2026-01-01T01:00:00+01:00,RETIRE,OK')
    $legacy = Get-FSLogixAuditHistory -AuditRoot $bad
    Assert 'minimal legacy schema is normalized' ($legacy.Count -eq 1 -and $legacy[0].TargetSid -eq '' -and $legacy[0].Reason -eq '')
    Assert 'offset timestamp is normalized to UTC' ($legacy[0].TimestampUtc.ToString('o') -eq '2026-01-01T00:00:00.0000000Z')
    $native = Join-Path $fixture 'native'; [void][IO.Directory]::CreateDirectory($native)
    Set-FSLogixAuditRoot -Path $native
    Write-FSLogixAudit -Critical -Record @{Action='RETIRE';Mode='LIVE';Reason='ACTUAL-WRITER';TargetUser='alice';TargetSid='S-1-5-21-1';Result='STARTED'}
    $written = Get-FSLogixAuditHistory -Reason 'ACTUAL-WRITER'
    Assert 'reader interoperates with actual audit writer' ($written.Count -eq 1 -and $written[0].Result -eq 'STARTED')
    Write-Host "ALL $script:checks AUDIT HISTORY CHECKS PASSED"
} finally {
    $prefix = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\.audit-fixture_'
    if ($fixture.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
