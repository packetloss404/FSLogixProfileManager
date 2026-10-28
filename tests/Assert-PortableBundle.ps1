<# CI smoke check against the relocated portable artifact, not the source checkout. #>
#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$BundlePath)
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Run with -STA.' }
$bundle = (Resolve-Path -LiteralPath $BundlePath -ErrorAction Stop).Path
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('fslogix_portable_' + [guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($fixture)
    $expectedModule = Join-Path $bundle 'FSLogixProfileCore.psm1'
    Import-Module $expectedModule -Force
    foreach ($name in @('Get-FSLogixEnvironmentStore','Get-FSLogixAuditHistory','Get-FSLogixProfileDetails')) {
        $command = Get-Command $name -Module FSLogixProfileCore -ErrorAction Stop
        if ($command.Module.Path -ne $expectedModule) { throw "Feature $name loaded outside the portable artifact." }
    }
    . (Join-Path $bundle 'FSLogixProfileGUI.ps1') -DefaultProfileRoot $fixture -EnvironmentStorePath (Join-Path $fixture 'environments.json') -InitializeOnly
    $form.ShowInTaskbar = $false; $form.StartPosition = 'Manual'; $form.Location = New-Object Drawing.Point(-3000,-3000)
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    foreach ($name in @('EnvironmentSelector','EnvironmentManage','ProfileDetailsButton','AuditHistoryButton')) {
        if ($form.Controls.Find($name, $true).Count -ne 1) { throw "Portable GUI is missing $name." }
    }
    if (-not $chkWhatIf.Checked -or $btnDelete.Enabled) { throw 'Portable GUI did not start with safe defaults.' }
    if (Test-Path -LiteralPath (Join-Path $fixture 'environments.json')) { throw 'Portable initialization unexpectedly wrote saved settings.' }
    Write-Host 'PORTABLE BUNDLE SMOKE CHECK PASSED'
} finally {
    if (Get-Variable form -ErrorAction SilentlyContinue) { if ($form -and -not $form.IsDisposed) { $form.Close(); $form.Dispose() } }
    Remove-Module FSLogixProfileCore -Force -ErrorAction SilentlyContinue
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath($fixture)
    if ($resolved.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'fslogix_portable_*') {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    }
}
