<# Run each suite in its own Windows PowerShell 5.1 STA process. #>
#Requires -Version 5.1
[CmdletBinding()]
param([int]$TimeoutSeconds = 180)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$shellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$parseFailures = @()
Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object {
    $_.Extension -in '.ps1','.psm1' -and $_.FullName -notmatch '[\\/]\.git[\\/]'
} | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    $parseFailures += @($errors)
}
if ($parseFailures.Count) { $parseFailures | ForEach-Object { Write-Error $_ -ErrorAction Continue }; exit 1 }
$failures = 0
foreach ($suite in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'Test-*.ps1' -File | Sort-Object Name)) {
    Write-Host "Running $($suite.Name)"
    $process = New-Object Diagnostics.Process
    $process.StartInfo.FileName = $shellPath
    $process.StartInfo.Arguments = '-NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "' + $suite.FullName + '"'
    $process.StartInfo.WorkingDirectory = $repoRoot
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        [void]$process.Start()
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            Write-Host "FAIL: $($suite.Name) exceeded $TimeoutSeconds seconds"
            $failures++
        } else {
            $process.WaitForExit()
            if ($process.ExitCode -ne 0) {
                Write-Host "FAIL: $($suite.Name) exited $($process.ExitCode)"
                $failures++
            }
        }
        Write-Host $outputTask.GetAwaiter().GetResult()
        Write-Host $errorTask.GetAwaiter().GetResult()
    } finally {
        $process.Dispose()
    }
}
if ($failures) { Write-Host "$failures SUITE(S) FAILED"; exit 1 }
Write-Host 'ALL SUITES PASSED'
