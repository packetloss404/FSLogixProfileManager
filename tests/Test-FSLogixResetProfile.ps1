<#
CLI smoke tests for FSLogixResetProfile.ps1.

Spawns the script as a child process and checks exit code + a few key output
lines. Pure logic lives in Test-FSLogixProfileCore.ps1; this file covers the
entry point's safety contract: bare-call refusal, -All opt-in, -WhatIf working
through SupportsShouldProcess, and -LastUsedDays filtering.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FSLogixResetProfile.ps1

Exits 1 if any check fails.
#>

$ErrorActionPreference = 'Stop'
$cliPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixResetProfile.ps1'
$fail = 0

function Check($name, $actual, $expected) {
    if ("$actual" -eq "$expected") { Write-Host "  ok   $name" }
    else { Write-Host "  FAIL $name : got '$actual' want '$expected'"; $script:fail++ }
}

# Helper: invoke the CLI with a shared fake root, return exit code + stdout.
function Invoke-CLI {
    param(
        [string]$Root,
        [string[]]$CliArgs
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $cliPath + '" -ProfileRoot "' + $Root + '" ' + ($CliArgs -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $p.ExitCode
        StdOut   = $out
        StdErr   = $err
    }
}

# Build a tiny fake share: one user with one live container.
# (No retired file - the discovery order would otherwise seed the user's
# LastWriteTime from the retired file's mtime, not the live one.)
$root = Join-Path $env:TEMP ('fscli_' + (Get-Random))
$dir  = Join-Path $root 'S-1-5-21-7-7-7-1000_erin'
New-Item -ItemType Directory -Path $dir -Force | Out-Null
function Mk($p, $kb) { $f = [IO.File]::Create($p); $f.SetLength($kb * 1KB); $f.Close() }
Mk (Join-Path $dir 'Profile_erin.vhdx')            4096
# Make the live container look older than the age filter the test uses.
(Get-Item (Join-Path $dir 'Profile_erin.vhdx')).LastWriteTime = (Get-Date).AddDays(-30)

try {
    Write-Host "-- safety contract --"

    # Bare call (no filter): must exit non-zero.
    $r = Invoke-CLI -Root $root -CliArgs @()
    Check 'bare.refused'     $r.ExitCode                  1
    Check 'bare.refused.msg' ($r.StdErr.Contains('Refusing'))   'True'

    # -User alone: must accept and run a WhatIf dry run.
    $r = Invoke-CLI -Root $root -CliArgs @('-User', 'erin', '-WhatIf')
    Check 'user.whatif.code' $r.ExitCode                       0
    Check 'user.whatif.mark' ($r.StdOut.Contains('[WHATIF] Summary')) 'True'

    # -All alone: must also be accepted.
    $r = Invoke-CLI -Root $root -CliArgs @('-All', '-WhatIf')
    Check 'all.whatif.code'  $r.ExitCode                       0
    Check 'all.whatif.mark'  ($r.StdOut.Contains('[WHATIF] Summary')) 'True'

    # -LastUsedDays alone: must also be accepted.
    $r = Invoke-CLI -Root $root -CliArgs @('-LastUsedDays', '1', '-WhatIf')
    Check 'age.whatif.code'  $r.ExitCode                       0
    Check 'age.whatif.mark'  ($r.StdOut.Contains('[WHATIF] Summary')) 'True'

    # Unknown user: no profiles matched, but no error.
    $r = Invoke-CLI -Root $root -CliArgs @('-User', 'nobody', '-WhatIf')
    Check 'nomatch.code'     $r.ExitCode                       0
    Check 'nomatch.msg'      ($r.StdOut.Contains('No profiles matched')) 'True'

    Write-Host "-- help / param shape --"

    # [CmdletBinding(SupportsShouldProcess)] makes -WhatIf and -Confirm part of
    # the parameter set, so they show up in Get-Help's SYNTAX block.
    $help = Get-Help $cliPath | Out-String
    Check 'help.whatif'      ($help.Contains('-WhatIf'))   'True'
    Check 'help.confirm'     ($help.Contains('-Confirm'))  'True'
    Check 'help.scope'       ($help.Contains('-Scope'))    'True'
}
finally {
    cmd /c "rmdir /s /q `"$root`""
}

Write-Host ""
if ($fail) { Write-Host "$fail CHECK(S) FAILED" -ForegroundColor Red; exit 1 }
else { Write-Host "ALL CHECKS PASSED" -ForegroundColor Green }
