<#
.SYNOPSIS
    Command-line FSLogix profile reset tool (rename-based).

.DESCRIPTION
    Scans one or more FSLogix profile roots (UNC shares), groups containers by
    user identity, and retires profiles by RENAMING containers (never deleting).

    A safety contract enforced by this entry point:
      * At least one of -User / -LastUsedDays / -All is required. A bare call
        with no filter is refused outright.
      * -WhatIf is the standard one; -Confirm gates any non-WhatIf run.
      * In-use detection is on by default. Pass -CheckInUse:$false to disable
        (off is the unsafe choice).

    All scan/classify/retire/restore logic lives in FSLogixProfileCore.psm1.
    This script is a thin CLI shell over it.

    Breaking changes vs the v1 CLI:
      * The custom -WhatIf switch is gone. Use the standard -WhatIf that
        SupportsShouldProcess provides. -Confirm is now wired up too.
      * The -OnlyOdfc and -OnlyProfile switches are gone. Use -Scope Office /
        -Scope Profile. -Scope All is the default.
      * A bare call with no filter is refused (was: retired the entire share).
      * Scheduled tasks that ran the bare form will now exit with an error.

.PARAMETER ProfileRoot
    Single FSLogix root (UNC). Default: '\\fml-fslogix\FSLogixUserProfiles'.
    Accepts a single path; for multiple roots use -ProfileRoots.

.PARAMETER ProfileRoots
    Multiple FSLogix roots (Cloud Cache). Mutually exclusive with -ProfileRoot.

.PARAMETER User
    Target users. Wildcards allowed. Multiple values allowed.

.PARAMETER LastUsedDays
    Filter to profiles whose last write is older than this many days.

.PARAMETER All
    Explicitly opt in to processing every discovered profile. Without -All,
    a call that has no -User and no -LastUsedDays is refused.

.PARAMETER Scope
    Which container classes to retire: All (default), Office, or Profile.

.PARAMETER CheckInUse
    Skip containers that are currently held open. Default: $true. Pass
    -CheckInUse:$false to override (unsafe).

.PARAMETER ListOnly
    Show what would be targeted and exit. No rename.

.PARAMETER Force
    Permit retiring a row whose username and SID could not be parsed out of
    the share layout. Off by default.

.EXAMPLE
    # Dry run for one user.
    .\FSLogixResetProfile.ps1 -User vditest1 -WhatIf

.EXAMPLE
    # Live: every user whose profile hasn't been touched in 60 days, all
    # containers, with confirmation prompts.
    .\FSLogixResetProfile.ps1 -LastUsedDays 60

.EXAMPLE
    # Multi-root: scan both providers as independent shares.
    .\FSLogixResetProfile.ps1 -ProfileRoots '\\fs1\Profiles','\\fs2\Profiles' -User vdi* -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(ParameterSetName = 'Single')]
    [string]$ProfileRoot = '\\fml-fslogix\FSLogixUserProfiles',

    [Parameter(ParameterSetName = 'Multi', Mandatory = $true)]
    [string[]]$ProfileRoots,

    [string[]]$User,

    [int]$LastUsedDays = 0,

    [switch]$All,

    [ValidateSet('All', 'Office', 'Profile')]
    [string]$Scope = 'All',

    [switch]$CheckInUse = $true,

    [switch]$ListOnly,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------------------------------
#  Load the shared core
# --------------------------------------------------------------------------------------------------
$modulePath = Join-Path $PSScriptRoot 'FSLogixProfileCore.psm1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "FSLogixProfileCore.psm1 not found at: $modulePath"
}
Import-Module $modulePath -Force

# --------------------------------------------------------------------------------------------------
#  Roots + filter sanity
# --------------------------------------------------------------------------------------------------
if ($PSCmdlet.ParameterSetName -eq 'Single') {
    $roots = if ($ProfileRoot -match ';') {
        $ProfileRoot -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    } else {
        @($ProfileRoot)
    }
} else {
    $roots = @($ProfileRoots | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if ($roots.Count -eq 0) {
    Write-Error "No profile roots specified."
    exit 1
}

# Bare call with no filter: refused. This is the headline safety fix.
if (-not $User -and $LastUsedDays -le 0 -and -not $All) {
    Write-Error "Refusing to run with no filter. Specify -User, -LastUsedDays, or -All."
    exit 1
}

$isSim = $WhatIfPreference
$mode  = if ($isSim) { 'WHATIF' } else { 'LIVE' }

Write-Host "FSLogixResetProfile.ps1 - v0.8.0" -ForegroundColor Cyan
Write-Host ("ProfileRoot(s): {0}" -f ($roots -join '; '))
Write-Host ("User filter  : {0}" -f ($User -join ', '))
Write-Host ("LastUsedDays : {0}" -f $LastUsedDays)
Write-Host ("All          : {0}" -f $All.IsPresent)
Write-Host ("Scope        : {0}" -f $Scope)
Write-Host ("CheckInUse   : {0}" -f ([bool]$CheckInUse))
Write-Host ("WhatIf       : {0}" -f $isSim)
Write-Host ""

# --------------------------------------------------------------------------------------------------
#  Scan + filter
# --------------------------------------------------------------------------------------------------
$profiles = @(Get-FSLogixProfiles -ProfileRoots $roots)

# Direct call (not @( ... )) so the module's leading-comma return unwraps
# cleanly. Wrapping with @() would give a 1-element array containing the
# real result, which makes .Count always 1 for empty results.
$filtered = Select-FSLogixProfile -Source $profiles -UserFilter $User -AgeDays $LastUsedDays

if ($null -eq $filtered -or $filtered.Count -eq 0) {
    Write-Output "No profiles matched the filters."
    exit 0
}

Write-Output ("Matched {0} user profile(s):" -f $filtered.Count)
$filtered |
    Select-Object UserName, ContainerCount, TotalSizeGB, LastWriteTime, ADStatus, HealthIssues |
    Format-Table -AutoSize | Out-String | Write-Output

if ($ListOnly) {
    Write-Host "ListOnly: no changes made." -ForegroundColor Cyan
    exit 0
}

# --------------------------------------------------------------------------------------------------
#  Per-batch confirmation (only for live runs; WhatIf never prompts)
# --------------------------------------------------------------------------------------------------
if (-not $isSim -and $ConfirmPreference -ne 'None') {
    $names = @($filtered | ForEach-Object { $_.UserName } | Sort-Object)
    $displayNames = if ($names.Count -le 5) { $names -join ', ' } else {
        ($names[0..4] -join ', ') + " (+$($names.Count - 5) more)"
    }
    $message = "Retire profiles for:`n$displayNames`n`nScope: $Scope`nIn-use check: $CheckInUse`n`nProceed?"
    $yes = New-Object System.Management.Automation.Host.ChoiceDescription '&Yes', 'Perform the rename.'
    $no  = New-Object System.Management.Automation.Host.ChoiceDescription '&No',  'Cancel without changes.'
    $options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)
    $choice = $host.UI.PromptForChoice("Confirm - $mode", $message, $options, 1)  # 1 = default No
    if ($choice -ne 0) {
        Write-Host "Cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# --------------------------------------------------------------------------------------------------
#  Execute
# --------------------------------------------------------------------------------------------------
$results = @()
foreach ($profile in $filtered) {
    if (-not $PSCmdlet.ShouldProcess($profile.UserName, "Retire (scope=$Scope, checkInUse=$([bool]$CheckInUse))")) {
        continue
    }
    $r = Rename-FSLogixProfileObject `
        -ProfileObject $profile `
        -Scope $Scope `
        -CheckInUse:$CheckInUse `
        -Force:$Force `
        -Confirm:$false
    $results += $r
}

# --------------------------------------------------------------------------------------------------
#  Report
# --------------------------------------------------------------------------------------------------
$totals = [PSCustomObject]@{
    Planned       = 0
    Renamed       = 0
    SkippedInUse  = 0
    SkippedExists = 0
    Missing       = 0
    Failed        = 0
    AbortedCount  = 0
    AbortReasons  = @()
}
foreach ($r in $results) {
    $totals.Planned       += $r.Planned
    $totals.Renamed       += $r.Renamed
    $totals.SkippedInUse  += $r.SkippedInUse
    $totals.SkippedExists += $r.SkippedExists
    $totals.Missing       += $r.Missing
    $totals.Failed        += $r.Failed
    if ($r.Aborted) {
        $totals.AbortedCount++
        $totals.AbortReasons += "$($r.UserName): $($r.AbortReason)"
    }
}

Write-Host ""
Write-Output "[$mode] Summary"
Write-Output ("  Planned:           {0}" -f $totals.Planned)
Write-Output ("  Renamed:           {0}" -f $totals.Renamed)
Write-Output ("  Skipped (in-use):  {0}" -f $totals.SkippedInUse)
Write-Output ("  Skipped (exists):  {0}" -f $totals.SkippedExists)
Write-Output ("  Missing:           {0}" -f $totals.Missing)
Write-Output ("  Failed:            {0}" -f $totals.Failed)
if ($totals.AbortedCount -gt 0) {
    Write-Host ""
    Write-Output "Aborted:"
    foreach ($reason in $totals.AbortReasons) { Write-Output "  $reason" }
}

exit 0
