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

.PARAMETER Reason
    Required for live resets. Ticket or explanation recorded in every audit row.

.PARAMETER AuditRoot
    Optional central audit directory. An unavailable explicit audit root aborts
    the reset before any container is changed.

.PARAMETER MoveToRetired
    Move retired files to the root's _retired directory. Default: $true.
    Pass -MoveToRetired:$false for legacy in-place retirement.

.PARAMETER AllOrNothing
    Abort or roll back a user's batch when a target cannot be retired. Default:
    $true, including across multiple Cloud Cache roots.

.EXAMPLE
    # Dry run for one user.
    .\FSLogixResetProfile.ps1 -User vditest1 -WhatIf

.EXAMPLE
    # Live: every user whose profile hasn't been touched in 60 days, all
    # containers, with confirmation prompts.
    .\FSLogixResetProfile.ps1 -LastUsedDays 60 -Reason 'CHG1234'

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

    [ValidateRange(0, 365000)]
    [int]$LastUsedDays = 0,

    [switch]$All,

    [ValidateSet('All', 'Office', 'Profile')]
    [string]$Scope = 'All',

    [switch]$CheckInUse = $true,

    [switch]$ListOnly,

    [switch]$Force,

    [string]$Reason,

    [string]$AuditRoot,

    [switch]$MoveToRetired = $true,

    [switch]$AllOrNothing = $true
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
    $roots = @($ProfileRoot -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} else {
    $roots = @($ProfileRoots | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$roots = @($roots | Select-Object -Unique)

if ($roots.Count -eq 0) {
    Write-Error "No profile roots specified."
    exit 1
}

if ($PSBoundParameters.ContainsKey('User') -and @($User | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
    throw 'User filters must not be blank. Use -All to explicitly select every user.'
}

# Bare call with no filter: refused. This is the headline safety fix.
if (-not $User -and $LastUsedDays -le 0 -and -not $All) {
    Write-Error "Refusing to run with no filter. Specify -User, -LastUsedDays, or -All."
    exit 1
}

foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Profile root is unavailable or is not a directory: $root"
    }
}

$isSim = $WhatIfPreference
$mode  = if ($isSim) { 'WHATIF' } else { 'LIVE' }
if (-not $isSim -and -not $ListOnly -and [string]::IsNullOrWhiteSpace($Reason)) {
    throw 'A nonblank -Reason (ticket or explanation) is required for a live reset.'
}
if ($PSBoundParameters.ContainsKey('AuditRoot')) {
    if ([string]::IsNullOrWhiteSpace($AuditRoot)) { throw 'AuditRoot must not be blank.' }
    Set-FSLogixAuditRoot -Path $AuditRoot
}

Write-Host "FSLogixResetProfile.ps1 - v0.9.0" -ForegroundColor Cyan
Write-Host ("ProfileRoot(s): {0}" -f ($roots -join '; '))
Write-Host ("User filter  : {0}" -f ($User -join ', '))
Write-Host ("LastUsedDays : {0}" -f $LastUsedDays)
Write-Host ("All          : {0}" -f $All.IsPresent)
Write-Host ("Scope        : {0}" -f $Scope)
Write-Host ("CheckInUse   : {0}" -f ([bool]$CheckInUse))
Write-Host ("MoveToRetired: {0}" -f ([bool]$MoveToRetired))
Write-Host ("AllOrNothing : {0}" -f ([bool]$AllOrNothing))
Write-Host ("WhatIf       : {0}" -f $isSim)
Write-Host ""

# --------------------------------------------------------------------------------------------------
#  Scan + filter
# --------------------------------------------------------------------------------------------------
$profiles = Get-FSLogixProfiles -ProfileRoots $roots -ErrorOnIncomplete

# Direct call (not @( ... )) so the module's leading-comma return unwraps
# cleanly. Wrapping with @() would give a 1-element array containing the
# real result, which makes .Count always 1 for empty results.
$filtered = Select-FSLogixProfile -Source $profiles -UserFilter $User -ExactPattern -AgeDays $LastUsedDays

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
if (-not $isSim -and -not $PSCmdlet.ShouldProcess(($filtered.UserName -join ', '), "Retire profiles (scope=$Scope, checkInUse=$([bool]$CheckInUse))")) {
    Write-Output 'Cancelled: no changes made.'
    exit 0
}

# --------------------------------------------------------------------------------------------------
#  Execute
# --------------------------------------------------------------------------------------------------
$results = @()
foreach ($profileRow in $filtered) {
    $r = Rename-FSLogixProfileObject `
        -ProfileObject $profileRow `
        -Scope $Scope `
        -CheckInUse:$CheckInUse `
        -Force:$Force `
        -Reason $Reason `
        -MoveToRetired:$MoveToRetired `
        -AllOrNothing:$AllOrNothing `
        -WhatIf:$isSim `
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

if ($totals.Failed -gt 0 -or $totals.AbortedCount -gt 0 -or $totals.Missing -gt 0) { exit 1 }
exit 0
