<#
CLI end-to-end tests using real child Windows PowerShell processes and disposable
local profile trees. No AD, Hyper-V, Horizon or real SMB server is required.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FSLogixResetProfile.ps1
#>
$ErrorActionPreference = 'Stop'
$cliPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixResetProfile.ps1'
$script:fail = 0
$script:checks = 0
function Check($name, $actual, $expected) {
    $script:checks++
    if ("$actual" -eq "$expected") { Write-Host "  ok   $name" }
    else { Write-Host "  FAIL $name : got '$actual' want '$expected'"; $script:fail++ }
}
function Quote-PS([string]$Value) { return "'" + $Value.Replace("'", "''") + "'" }

# EncodedCommand preserves arrays, quotes, spaces and switch:$false on PowerShell
# 5.1, unlike flattening arguments into a -File command line.
function Invoke-CLI {
    param([hashtable]$Parameters)
    $arguments = foreach ($key in $Parameters.Keys) {
        $value = $Parameters[$key]
        if ($value -is [bool]) {
            '-{0}:${1}' -f $key, $value.ToString().ToLowerInvariant()
        } elseif ($value -is [array]) {
            '-{0} @({1})' -f $key, (($value | ForEach-Object { Quote-PS "$_" }) -join ',')
        } else { '-{0} {1}' -f $key, (Quote-PS "$value") }
    }
    $command = '& ' + (Quote-PS $cliPath) + ' ' + ($arguments -join ' ')
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand ' + $encoded
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($psi)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(45000)) {
            $process.Kill()
            throw "CLI timed out: $command"
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = $stdout.GetAwaiter().GetResult()
            StdErr = $stderr.GetAwaiter().GetResult()
        }
    } finally { $process.Dispose() }
}

$testRoot = [IO.Path]::GetFullPath((Join-Path $env:TEMP ('fscli_' + [guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($testRoot)
function New-Fixture([string]$Name) {
    $path = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}
function New-Container([string]$Root, [string]$UserName, [string]$Name, [int]$AgeDays = 30) {
    $rid = 1000
    foreach ($character in $UserName.ToCharArray()) { $rid += [int]$character }
    $directory = Join-Path $Root ('S-1-5-21-7-7-7-' + $rid + '_' + $UserName)
    [void][IO.Directory]::CreateDirectory($directory)
    $path = Join-Path $directory $Name
    $bytes = New-Object byte[] 4096
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('vhdxfile'), $bytes, 8)
    [IO.File]::WriteAllBytes($path, $bytes)
    [IO.File]::SetLastWriteTime($path, (Get-Date).AddDays(-$AgeDays))
    return $path
}
function Has-SummaryValue($Result, [string]$Name, [int]$Value) {
    return $Result.StdOut -match ('(?m)^\s*' + [regex]::Escape($Name) + ':\s+' + $Value + '\s*$')
}
try {
    $root = New-Fixture 'filters with spaces'
    $erin = New-Container $root 'erin' 'Profile_erin.vhdx'
    $office = New-Container $root 'erin' 'ODFC_erin.vhdx'
    $unknown = New-Container $root 'erin' 'custom.vhdx'
    $evan = New-Container $root 'evan' 'Profile_evan.vhdx'
    $recent = New-Container $root 'recent' 'Profile_recent.vhdx' 0

    Write-Host '-- input safety and filters --'
    $r = Invoke-CLI @{}
    Check 'no arguments refused before default root access' ($r.StdErr -match 'Refusing') $true
    $r = Invoke-CLI @{ ProfileRoot=$root }
    Check 'bare refused' $r.ExitCode 1
    Check 'bare diagnostic' ($r.StdErr -match 'Refusing') $true
    $r = Invoke-CLI @{ ProfileRoot=$root; User=' '; WhatIf=$true }
    Check 'blank user refused' $r.ExitCode 1
    $r = Invoke-CLI @{ ProfileRoot=$root; LastUsedDays=-1; WhatIf=$true }
    Check 'negative age refused' $r.ExitCode 1
    $r = Invoke-CLI @{ ProfileRoot=' '; All=$true; WhatIf=$true }
    Check 'blank root refused' $r.ExitCode 1
    $r = Invoke-CLI @{ ProfileRoot=(Join-Path $testRoot 'missing'); All=$true; WhatIf=$true }
    Check 'missing root refused' $r.ExitCode 1
    $r = Invoke-CLI @{ ProfileRoot=$root; All=$true; Scope='invalid'; WhatIf=$true }
    Check 'invalid scope refused' $r.ExitCode 1
    $r = Invoke-CLI @{ ProfileRoot=$root; ProfileRoots=@($root); All=$true; WhatIf=$true }
    Check 'conflicting root parameters refused' $r.ExitCode 1
    $r = Invoke-CLI @{ ProfileRoot=$root; User='erin'; Confirm=$false }
    Check 'live reason required' $r.ExitCode 1
    Check 'live reason refusal preserves file' ([IO.File]::Exists($erin)) $true
    $r = Invoke-CLI @{ ProfileRoot=$root; User='erin'; ListOnly=$true }
    Check 'list requires no reason' $r.ExitCode 0
    Check 'single-user filter count' ($r.StdOut -match 'Matched 1 user profile') $true
    Check 'list preserves file' ([IO.File]::Exists($erin)) $true
    $r = Invoke-CLI @{ ProfileRoot=$root; User='e*'; ListOnly=$true }
    Check 'wildcard user count' ($r.StdOut -match 'Matched 2 user profile') $true
    $r = Invoke-CLI @{ ProfileRoot=$root; User=@('erin','recent'); ListOnly=$true }
    Check 'multiple users count' ($r.StdOut -match 'Matched 2 user profile') $true
    $r = Invoke-CLI @{ ProfileRoot=$root; LastUsedDays=10; ListOnly=$true }
    Check 'age count' ($r.StdOut -match 'Matched 2 user profile') $true
    $r = Invoke-CLI @{ ProfileRoot=$root; User='e*'; LastUsedDays=100; ListOnly=$true }
    Check 'combined filters intersect' ($r.StdOut -match 'No profiles matched') $true
    $r = Invoke-CLI @{ ProfileRoot=$root; User='nobody'; WhatIf=$true }
    Check 'no match code' $r.ExitCode 0
    Check 'no match diagnostic' ($r.StdOut -match 'No profiles matched') $true
    $empty = New-Fixture 'empty'
    $r = Invoke-CLI @{ ProfileRoot=$empty; All=$true; WhatIf=$true }
    Check 'empty root count' ($r.StdOut -match 'No profiles matched') $true

    # A readable root with an unreadable subtree is an incomplete inventory,
    # even when other profiles could be listed or retired successfully.
    $incompleteRoot = New-Fixture 'incomplete'
    $readableFile = New-Container $incompleteRoot 'visible' 'Profile_visible.vhdx'
    $blockedDirectory = Join-Path $incompleteRoot 'blocked'
    [void][IO.Directory]::CreateDirectory($blockedDirectory)
    $originalAcl = Get-Acl -LiteralPath $blockedDirectory
    $deniedAcl = Get-Acl -LiteralPath $blockedDirectory
    $operatorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $denyList = New-Object Security.AccessControl.FileSystemAccessRule($operatorSid, [Security.AccessControl.FileSystemRights]::ListDirectory, [Security.AccessControl.AccessControlType]::Deny)
    [void]$deniedAcl.AddAccessRule($denyList)
    try {
        Set-Acl -LiteralPath $blockedDirectory -AclObject $deniedAcl
        $r = Invoke-CLI @{ ProfileRoot=$incompleteRoot; All=$true; ListOnly=$true }
        Check 'incomplete scan list fails' $r.ExitCode 1
        $r = Invoke-CLI @{ ProfileRoot=$incompleteRoot; All=$true; Reason='incomplete test'; AuditRoot=(Join-Path $testRoot 'incomplete audit'); Confirm=$false }
        Check 'incomplete scan reset fails' $r.ExitCode 1
        Check 'incomplete scan preserves readable container' ([IO.File]::Exists($readableFile)) $true
    } finally {
        Set-Acl -LiteralPath $blockedDirectory -AclObject $originalAcl
    }

    Write-Host '-- simulation scopes and actual filesystem --'
    $audit = Join-Path $testRoot 'simulation audit'
    $r = Invoke-CLI @{ ProfileRoot=$root; User='erin'; WhatIf=$true; AuditRoot=$audit }
    Check 'whatif exit' $r.ExitCode 0
    Check 'whatif summary' ($r.StdOut -match '\[WHATIF\] Summary') $true
    Check 'whatif all planned' (Has-SummaryValue $r 'Planned' 3) $true
    Check 'whatif no renames' (Has-SummaryValue $r 'Renamed' 0) $true
    Check 'whatif source preserved' ([IO.File]::Exists($erin)) $true
    Check 'whatif no audit directory' ([IO.Directory]::Exists($audit)) $false
    Check 'whatif no retired directory' ([IO.Directory]::Exists((Join-Path $root '_retired'))) $false
    foreach ($scope in @('Office','Profile')) {
        $r = Invoke-CLI @{ ProfileRoot=$root; User='erin'; Scope=$scope; WhatIf=$true }
        Check "$scope simulation planned" (Has-SummaryValue $r 'Planned' 1) $true
    }

    Write-Host '-- live move, scopes, reason and audit --'
    $liveAudit = Join-Path $testRoot 'live audit'
    $r = Invoke-CLI @{ ProfileRoot=$root; User='erin'; Scope='Office'; Reason="CHG-123 operator's test"; AuditRoot=$liveAudit; Confirm=$false }
    if ($r.ExitCode -ne 0) { Write-Host $r.StdOut }
    Check 'live office exit' $r.ExitCode 0
    Check 'live office renamed' (Has-SummaryValue $r 'Renamed' 1) $true
    Check 'live office moved' ([IO.File]::Exists($office)) $false
    Check 'profile scope excluded' ([IO.File]::Exists($erin)) $true
    Check 'unknown scope excluded' ([IO.File]::Exists($unknown)) $true
    $retired = @(Get-ChildItem -LiteralPath (Join-Path $root '_retired') -File -Recurse -Filter '*.vhdx')
    Check 'move destination count' $retired.Count 1
    Check 'move destination timestamp' ($retired[0].Name -match '^ODFC_erin-old-\d{8}-\d{6}\.vhdx$') $true
    $rows = @(Get-ChildItem -LiteralPath $liveAudit -Filter '*.csv' | ForEach-Object { Import-Csv -LiteralPath $_.FullName })
    $completed = @($rows | Where-Object { $_.Action -eq 'RETIRE' -and $_.Result -eq 'OK' })
    Check 'successful audit row' $completed.Count 1
    Check 'audit reason round trips' $completed[0].Reason "CHG-123 operator's test"
    $r = Invoke-CLI @{ ProfileRoot=$root; User='erin'; Scope='Profile'; Reason='legacy test'; AuditRoot=$liveAudit; MoveToRetired=$false; Confirm=$false }
    Check 'legacy in-place exit' $r.ExitCode 0
    Check 'legacy profile renamed' ([IO.File]::Exists($erin)) $false
    Check 'legacy target exists in user directory' (@(Get-ChildItem -LiteralPath (Split-Path $erin) -Filter 'Profile_erin-old-*.vhdx').Count) 1
    Check 'legacy unknown preserved' ([IO.File]::Exists($unknown)) $true

    Write-Host '-- multi-root aggregation and default atomicity --'
    $replica1 = New-Fixture 'replica1'
    $replica2 = New-Fixture 'replica2'
    $file1 = New-Container $replica1 'cloud' 'Profile_cloud.vhdx'
    $file2 = New-Container $replica2 'cloud' 'Profile_cloud.vhdx'
    $r = Invoke-CLI @{ ProfileRoots=@($replica1,$replica2); User='cloud'; WhatIf=$true }
    Check 'multi-root code' $r.ExitCode 0
    Check 'multi-root one user' ($r.StdOut -match 'Matched 1 user profile') $true
    Check 'multi-root planned replicas' (Has-SummaryValue $r 'Planned' 2) $true
    $r = Invoke-CLI @{ ProfileRoots=@($replica1,$replica1); User='cloud'; WhatIf=$true }
    Check 'duplicate roots scanned once' (Has-SummaryValue $r 'Planned' 1) $true
    $r = Invoke-CLI @{ ProfileRoot=($replica1 + ';' + $replica2); All=$true; WhatIf=$true }
    Check 'semicolon roots planned replicas' (Has-SummaryValue $r 'Planned' 2) $true
    $lock = [IO.File]::Open($file2, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $r = Invoke-CLI @{ ProfileRoots=@($replica1,$replica2); User='cloud'; Reason='atomicity test'; AuditRoot=$liveAudit; Confirm=$false }
        Check 'locked replica fails batch' $r.ExitCode 1
        Check 'locked replica abort diagnostic' ($r.StdOut -match 'All-or-nothing') $true
        Check 'unlocked replica preserved' ([IO.File]::Exists($file1)) $true
        Check 'locked replica preserved' ([IO.File]::Exists($file2)) $true
    } finally { $lock.Dispose() }
    $r = Invoke-CLI @{ ProfileRoots=@($replica1,$replica2); User='cloud'; Reason='replica retirement'; AuditRoot=$liveAudit; Confirm=$false }
    Check 'multi-root live code' $r.ExitCode 0
    Check 'multi-root renamed replicas' (Has-SummaryValue $r 'Renamed' 2) $true
    Check 'multi-root first moved' ([IO.File]::Exists($file1)) $false
    Check 'multi-root second moved' ([IO.File]::Exists($file2)) $false

    $partial1 = New-Fixture 'partial1'
    $partial2 = New-Fixture 'partial2'
    $partialFile1 = New-Container $partial1 'partial' 'Profile_partial.vhdx'
    $partialFile2 = New-Container $partial2 'partial' 'Profile_partial.vhdx'
    $partialLock = [IO.File]::Open($partialFile2, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $r = Invoke-CLI @{ ProfileRoots=@($partial1,$partial2); User='partial'; Reason='explicit partial'; AuditRoot=$liveAudit; AllOrNothing=$false; Confirm=$false }
        Check 'explicit partial batch exit' $r.ExitCode 0
        Check 'explicit partial batch moves free copy' ([IO.File]::Exists($partialFile1)) $false
        Check 'explicit partial batch skips locked copy' ([IO.File]::Exists($partialFile2)) $true
        Check 'explicit partial batch skip count' (Has-SummaryValue $r 'Skipped (in-use)' 1) $true
    } finally { $partialLock.Dispose() }
    $r = Invoke-CLI @{ ProfileRoot=$partial2; User='partial'; Reason='no lock probe'; AuditRoot=$liveAudit; CheckInUse=$false; Confirm=$false }
    Check 'disabled lock probe exit' $r.ExitCode 0
    Check 'disabled lock probe used' ($r.StdOut -match 'CheckInUse\s+: False') $true
    Check 'disabled lock probe retires file' ([IO.File]::Exists($partialFile2)) $false

    Write-Host '-- unresolved identity and unavailable audit safety --'
    $unresolved = New-Fixture 'unresolved'
    $unresolvedDir = Join-Path $unresolved 'mystery'
    [void][IO.Directory]::CreateDirectory($unresolvedDir)
    $opaque = Join-Path $unresolvedDir 'custom.vhdx'
    [IO.File]::WriteAllText($opaque, 'fixture')
    $r = Invoke-CLI @{ ProfileRoot=$unresolved; All=$true; Reason='unknown test'; AuditRoot=$liveAudit; Confirm=$false }
    Check 'unknown identity abort exit' $r.ExitCode 1
    Check 'unknown identity preserved' ([IO.File]::Exists($opaque)) $true
    $r = Invoke-CLI @{ ProfileRoot=$unresolved; All=$true; Force=$true; Reason='verified unknown'; AuditRoot=$liveAudit; Confirm=$false }
    Check 'force unknown exit' $r.ExitCode 0
    Check 'force unknown moved' ([IO.File]::Exists($opaque)) $false
    $auditRoot = New-Fixture 'audit-block'
    $auditSource = New-Container $auditRoot 'safe' 'Profile_safe.vhdx'
    $blockedAudit = Join-Path $testRoot 'audit-is-a-file'
    [IO.File]::WriteAllText($blockedAudit, 'not a directory')
    $r = Invoke-CLI @{ ProfileRoot=$auditRoot; All=$true; Reason='audit failure'; AuditRoot=$blockedAudit; Confirm=$false }
    Check 'unavailable audit exit' $r.ExitCode 1
    Check 'unavailable audit preserves source' ([IO.File]::Exists($auditSource)) $true

    Write-Host '-- standard confirmation and help --'
    $r = Invoke-CLI @{ ProfileRoot=$auditRoot; All=$true; Reason='confirmation test'; AuditRoot=$liveAudit }
    Check 'noninteractive live requires confirmation' $r.ExitCode 1
    Check 'unconfirmed source preserved' ([IO.File]::Exists($auditSource)) $true
    $help = Get-Help $cliPath | Out-String
    foreach ($parameter in @('WhatIf','Confirm','Scope','Reason','AuditRoot','MoveToRetired','AllOrNothing')) {
        Check "help $parameter" ($help.Contains('-' + $parameter)) $true
    }
} finally {
    # Verify the absolute target is the exact disposable directory created above.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $fixturePrefix = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($fixturePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^fscli_[a-f0-9]{32}$') {
        throw "Refusing to remove unexpected test directory: $resolved"
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
Write-Host ""
if ($script:fail) { Write-Host "$script:fail OF $script:checks CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "ALL $script:checks CLI CHECKS PASSED" -ForegroundColor Green
exit 0
