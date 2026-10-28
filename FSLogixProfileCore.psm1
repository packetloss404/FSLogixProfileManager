<#
FSLogixProfileCore.psm1
Shared discovery / classification / retire / restore core for the FSLogix Profile Manager.

Imported by both entry points:
  FSLogixProfileGUI.ps1     - WinForms GUI (requires -STA)
  FSLogixResetProfile.ps1   - CLI

Nothing in this module touches WinForms, so it is safe to import into a background
runspace. All user-visible messaging goes through Write-FSLogixLog, which the host
redirects with Set-FSLogixLogHandler.
#>

#Requires -Version 5.1

# --------------------------------------------------------------------
#  Module constants and state
# --------------------------------------------------------------------

# Only these are FSLogix containers. Get-ChildItem -Filter *.vhd* is a prefix match
# on Windows and also returns .vhdx.meta / .vhdx.metadata / .vhdx.lock sidecars, so
# every scan re-filters on the real extension.
$script:ContainerExtensions = @('.vhd', '.vhdx')

# A retired container is "<name>-old.<ext>" (legacy, date unknown) or
# "<name>-old-yyyyMMdd-HHmmss.<ext>" (current).
$script:RetiredSuffixRegex   = '-old(?:-(?<stamp>\d{8}-\d{6}))?$'
$script:SupersededSuffixRegex = '-superseded-(?<stamp>\d{8}-\d{6})$'

# FSLogix folder naming. Both orders are supported: the layout depends on the
# FlipFlopProfileDirectoryName policy, whose *default* is SID-first.
$script:SidFirstFolderRegex  = '^(?<sid>S-1-5-21(?:-\d+)+)_(?<user>.+)$'
$script:UserFirstFolderRegex = '^(?<user>.+)_(?<sid>S-1-5-21(?:-\d+)+)$'

# Container filename prefixes. FSLogix writes Profile_<user>, ODFC_<user> and, on
# older Office Container builds, O365_<user>. VHDNamePattern can change these, so
# they are overridable via Set-FSLogixNamePrefix.
$script:ProfilePrefixes = @('Profile')
$script:OfficePrefixes  = @('ODFC', 'O365')

$script:LogHandler          = $null
$script:AuditRoot           = $null
$script:AuditRootIsExplicit = $false
$script:ADCheckEnabled      = $false
$script:ADCheckCache        = @{}
$script:HorizonConnection   = $null
$script:CimSessionCache     = @{}
$script:SmbProbeFailed      = @{}

# --------------------------------------------------------------------
#  Logging
# --------------------------------------------------------------------

function Set-FSLogixLogHandler {
    <#
    .SYNOPSIS
        Redirect module log output to the host (GUI log panel, console, queue, ...).
    .DESCRIPTION
        The handler receives two positional arguments: message and level. Pass $null
        to restore the default console behaviour.
    #>
    [CmdletBinding()]
    param([scriptblock]$Handler)
    $script:LogHandler = $Handler
}

function Write-FSLogixLog {
    <#
    .SYNOPSIS
        Emit a log line through the configured handler, or to the console.
    .DESCRIPTION
        PROGRESS lines are transient status updates ("scanned 400 of 2000"); hosts are
        expected to show them in a status bar rather than append them to a log buffer.
    #>
    [CmdletBinding()]
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'PROGRESS')]
        [string]$Level = 'INFO'
    )

    if ($script:LogHandler) {
        try { $null = & $script:LogHandler $Message $Level } catch { }
        return
    }

    switch ($Level) {
        'ERROR'    { Write-Host $Message -ForegroundColor Red }
        'WARN'     { Write-Host $Message -ForegroundColor Yellow }
        'PROGRESS' { Write-Host $Message -ForegroundColor DarkGray }
        default    { Write-Host $Message }
    }
}

# --------------------------------------------------------------------
#  Container naming: classification, retired detection, retire targets
# --------------------------------------------------------------------

function Set-FSLogixNamePrefix {
    <#
    .SYNOPSIS
        Override the container filename prefixes used for Profile/Office classification.
    .DESCRIPTION
        Needed when VHDNamePattern has been customised. Anything matching neither list
        classifies as Unknown and is excluded from -Scope Profile / -Scope Office
        targeting rather than being swept into whichever bucket happens to be default.
    #>
    [CmdletBinding()]
    param(
        [string[]]$ProfilePrefix,
        [string[]]$OfficePrefix
    )
    if ($ProfilePrefix) { $script:ProfilePrefixes = $ProfilePrefix }
    if ($OfficePrefix)  { $script:OfficePrefixes  = $OfficePrefix }
}

function Get-FSLogixContainerClass {
    <#
    .SYNOPSIS
        Classify a container filename as Profile, Office or Unknown.
    .DESCRIPTION
        Matched positively on the leaf filename only. The previous "anything containing
        odfc or office is an Office container" rule misclassified O365_*.vhdx as a
        profile container, misclassified users whose name contained "office", and - when
        applied to a full path, as the retire and preview paths used to do - classified
        every container under an \ODFC\ share as Office.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$FileName)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)

    foreach ($prefix in $script:OfficePrefixes) {
        if ($base -like ($prefix + '_*')) { return 'Office' }
    }
    foreach ($prefix in $script:ProfilePrefixes) {
        if ($base -like ($prefix + '_*')) { return 'Profile' }
    }
    return 'Unknown'
}

function Test-FSLogixRetiredName {
    <#
    .SYNOPSIS
        Return retirement details for a container filename, or $null if it is live.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$FileName)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    if ($base -notmatch $script:RetiredSuffixRegex) { return $null }

    $stamp     = $Matches['stamp']
    $retiredOn = $null
    if ($stamp) {
        try {
            $retiredOn = [datetime]::ParseExact($stamp, 'yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
        } catch {
            $retiredOn = $null
        }
    }

    [PSCustomObject]@{
        Stamp     = $stamp
        RetiredOn = $retiredOn
        LiveName  = ($base -replace $script:RetiredSuffixRegex, '') + [System.IO.Path]::GetExtension($FileName)
    }
}

function Test-FSLogixSupersededName {
    <#
    .SYNOPSIS
        True if the filename is a container displaced by a restore operation.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$FileName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    return ($base -match $script:SupersededSuffixRegex)
}

function New-FSLogixBatchStamp {
    <#
    .SYNOPSIS
        Timestamp that groups every file retired by one operation into one batch.
    .DESCRIPTION
        A fixed "-old" suffix could not distinguish batches, had no retirement date
        (Rename-Item preserves LastWriteTime), and collided on the second reset - at
        which point the collision guard skipped the live container and renamed the
        previous backup instead.
    #>
    [CmdletBinding()]
    param()
    return (Get-Date -Format 'yyyyMMdd-HHmmss')
}

function Get-FSLogixRetireTargetName {
    <#
    .SYNOPSIS
        Build the retired filename for a live container within a batch.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][ValidatePattern('^\d{8}-\d{6}$')][string]$BatchStamp
    )
    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    $ext  = [System.IO.Path]::GetExtension($FileName)
    return ('{0}-old-{1}{2}' -f $base, $BatchStamp, $ext)
}

# --------------------------------------------------------------------
#  Identity: parse username + SID out of an FSLogix folder or filename
# --------------------------------------------------------------------

function Resolve-FSLogixIdentity {
    <#
    .SYNOPSIS
        Derive username and SID from a container's folder leaf, falling back to the filename.
    .DESCRIPTION
        Handles both FlipFlopProfileDirectoryName layouts, plus NoProfileContainingFolder
        (containers written straight into the VHDLocations root, so identity has to come
        from Profile_<user>.vhdx). Returns Source = 'Unresolved' when nothing matches -
        callers must refuse destructive work on those rows, because an unresolved row is
        keyed on its directory and its identity is a guess.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FolderLeaf,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    if ($FolderLeaf -match $script:SidFirstFolderRegex) {
        return [PSCustomObject]@{ UserName = $Matches['user']; Sid = $Matches['sid']; Source = 'FolderSidFirst' }
    }
    if ($FolderLeaf -match $script:UserFirstFolderRegex) {
        return [PSCustomObject]@{ UserName = $Matches['user']; Sid = $Matches['sid']; Source = 'FolderUserFirst' }
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
    # Strip a retirement/superseded suffix first so retired files resolve to the same user.
    $base = $base -replace $script:RetiredSuffixRegex, ''
    $base = $base -replace $script:SupersededSuffixRegex, ''

    if ($base -match $script:SidFirstFolderRegex) {
        return [PSCustomObject]@{ UserName = $Matches['user']; Sid = $Matches['sid']; Source = 'FileNameSidFirst' }
    }
    if ($base -match $script:UserFirstFolderRegex) {
        return [PSCustomObject]@{ UserName = $Matches['user']; Sid = $Matches['sid']; Source = 'FileNameUserFirst' }
    }

    # NoProfileContainingFolder layout: Profile_jsmith.vhdx / ODFC_jsmith.vhdx.
    $allPrefixes = @($script:ProfilePrefixes) + @($script:OfficePrefixes)
    foreach ($prefix in $allPrefixes) {
        if ($base -like ($prefix + '_*')) {
            $candidate = $base.Substring($prefix.Length + 1)
            if (-not [string]::IsNullOrWhiteSpace($candidate)) {
                return [PSCustomObject]@{ UserName = $candidate; Sid = $null; Source = 'FileNamePrefix' }
            }
        }
    }

    return [PSCustomObject]@{ UserName = $FolderLeaf; Sid = $null; Source = 'Unresolved' }
}

# --------------------------------------------------------------------
#  In-use detection
# --------------------------------------------------------------------

function Test-FSLogixFileInUse {
    <#
    .SYNOPSIS
        Probe whether a container is held open. Returns Free, InUse, AccessDenied or Missing.
    .DESCRIPTION
        Opens for Read with FileShare.None: enough to detect a mounted container without
        requiring write access on the share. The previous ReadWrite/None probe reported
        every container as in-use for a read-only operator, which - with skip-in-use on
        by default - produced resets that silently did nothing and still reported success.

        This is a weak signal on its own. It does not see a Cloud Cache session (I/O goes
        via the session host's local cache, not the provider copy) and it cannot name the
        holder. Prefer Get-FSLogixOpenHandle where the file server allows it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return 'Missing' }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        return 'Free'
    } catch [System.UnauthorizedAccessException] {
        return 'AccessDenied'
    } catch [System.IO.IOException] {
        return 'InUse'
    } catch {
        return 'InUse'
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Get-FSLogixOpenHandle {
    <#
    .SYNOPSIS
        Ask the file server which sessions hold a container open.
    .DESCRIPTION
        Authoritative where Test-FSLogixFileInUse is a guess, and it names the holding
        user and client machine - which is what an admin actually needs before retiring
        someone's profile. Requires SMB admin rights on the file server; returns $null
        (not an empty list) when it could not be queried, so callers can tell "nobody has
        it open" apart from "I could not find out".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$Path,
        [string]$FileServer
    )

    $first = @($Path)[0]
    if (-not $FileServer) {
        if ($first -match '^\\\\(?<server>[^\\]+)\\') { $FileServer = $Matches['server'] }
        else { return $null }
    }

    # This result can only be authoritative for the server actually queried.
    foreach ($target in $Path) {
        if ($target -notmatch '^\\\\(?<server>[^\\]+)\\' -or $Matches['server'] -ne $FileServer) {
            Write-FSLogixLog 'SMB handle requests must target one UNC server; falling back to lock probing.' 'WARN'
            return $null
        }
    }

    if ($script:SmbProbeFailed.ContainsKey($FileServer)) { return $null }

    try {
        if (-not (Get-Command Get-SmbOpenFile -ErrorAction SilentlyContinue)) {
            $script:SmbProbeFailed[$FileServer] = $true
            return $null
        }

        if (-not $script:CimSessionCache.ContainsKey($FileServer)) {
            $script:CimSessionCache[$FileServer] = New-CimSession -ComputerName $FileServer -ErrorAction Stop
        }
        $open = @(Get-SmbOpenFile -CimSession $script:CimSessionCache[$FileServer] -ErrorAction Stop)
    } catch {
        Write-FSLogixLog "SMB open-file query failed against $FileServer ($($_.Exception.Message)); falling back to lock probing." 'WARN'
        $script:SmbProbeFailed[$FileServer] = $true
        return $null
    }

    $results = @()
    foreach ($target in $Path) {
        $leaf   = Split-Path -Leaf $target
        $parent = Split-Path -Leaf (Split-Path -Parent $target)
        # Get-SmbOpenFile reports the server-local path, so match on the tail.
        $tail   = '*\{0}\{1}' -f [System.Management.Automation.WildcardPattern]::Escape($parent), [System.Management.Automation.WildcardPattern]::Escape($leaf)
        foreach ($handle in ($open | Where-Object { $_.Path -like $tail })) {
            $results += [PSCustomObject]@{
                Path           = $target
                ClientUserName = $handle.ClientUserName
                ClientComputer = $handle.ClientComputerName
                SessionId      = $handle.SessionId
            }
        }
    }
    return , $results
}

function Get-FSLogixContainerState {
    <#
    .SYNOPSIS
        Combined availability check for one container: Free, InUse, AccessDenied or Missing.
    .DESCRIPTION
        Uses the SMB open-file list when available (and records the holder), otherwise
        falls back to the local lock probe.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $OpenHandles
    )

    if ($null -ne $OpenHandles) {
        $holder = @($OpenHandles) | Where-Object { $_.Path -eq $Path } | Select-Object -First 1
        if ($holder) {
            return [PSCustomObject]@{ State = 'InUse'; Holder = ('{0} on {1}' -f $holder.ClientUserName, $holder.ClientComputer) }
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            return [PSCustomObject]@{ State = 'Missing'; Holder = $null }
        }
        return [PSCustomObject]@{ State = 'Free'; Holder = $null }
    }

    return [PSCustomObject]@{ State = (Test-FSLogixFileInUse -Path $Path); Holder = $null }
}

# --------------------------------------------------------------------
#  VHD inspection
# --------------------------------------------------------------------

function Test-FSLogixVhdSignature {
    <#
    .SYNOPSIS
        Read the VHD/VHDX file signature. Returns Valid, Invalid or Unknown.
    .DESCRIPTION
        A structural sanity check that works without the Hyper-V module and tolerates a
        mounted container (it shares read/write). Not a substitute for Test-VHD, but it
        catches truncated and zero-filled containers, which filename matching never did:
        FSLogix does not rename a broken container to *CORRUPT*, it hands out a temp
        profile and leaves the file exactly where it is.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($stream.Length -lt 512) { return 'Invalid' }

        $buffer = New-Object byte[] 8
        [void]$stream.Read($buffer, 0, 8)
        if ([System.Text.Encoding]::ASCII.GetString($buffer) -eq 'vhdxfile') { return 'Valid' }

        # VHD (not VHDX) keeps a "conectix" cookie in the 512-byte footer.
        [void]$stream.Seek(-512, [System.IO.SeekOrigin]::End)
        [void]$stream.Read($buffer, 0, 8)
        if ([System.Text.Encoding]::ASCII.GetString($buffer) -eq 'conectix') { return 'Valid' }

        return 'Invalid'
    } catch {
        return 'Unknown'
    } finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Get-FSLogixVhdMaxSizeGB {
    <#
    .SYNOPSIS
        Read a container's real maximum virtual size, in GB. Returns $null if unknown.
    .DESCRIPTION
        Requires the Hyper-V module's Get-VHD, which parses the VHD footer over SMB and
        costs a round trip per file - so callers gate this behind an explicit opt-in.

        It deliberately does NOT guess. The previous fallback returned "the first of
        30/50/100/120 GB larger than the current file", which made Max GB exceed the
        file size by construction, carried no information, and reported 30 GB for a
        130 GB container. $null renders as a blank cell instead.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($null -eq $script:HasGetVhd) {
        $script:HasGetVhd = [bool](Get-Command Get-VHD -ErrorAction SilentlyContinue)
        if (-not $script:HasGetVhd) {
            Write-FSLogixLog "Hyper-V Get-VHD not available - Max GB will be blank unless -ConfiguredMaxSizeGB is supplied." 'WARN'
        }
    }
    if (-not $script:HasGetVhd) { return $null }

    try {
        $vhd = Get-VHD -Path $Path -ErrorAction Stop
        if ($vhd -and $vhd.Size -gt 0) { return [Math]::Round($vhd.Size / 1GB, 2) }
    } catch {
        # Unreadable footer, no rights, or not a VHD; leave unknown.
    }
    return $null
}

function Get-FSLogixSettings {
    <#
    .SYNOPSIS
        Read FSLogix policy from a session host's registry.
    .DESCRIPTION
        Lets the tool configure itself from the environment instead of assuming a layout:
        VHDLocations/CCDLocations, the real SizeInMBs ceiling, and the two settings that
        determine how folders and files are named. Falls back to remote-registry when the
        local machine is not an FSLogix host. Returns $null when nothing could be read.
    #>
    [CmdletBinding()]
    param([string]$ComputerName)

    $paths = @{
        Profiles = 'SOFTWARE\FSLogix\Profiles'
        ODFC     = 'SOFTWARE\FSLogix\ODFC'
    }

    $read = {
        param($HiveKey, $SubKey)
        try {
            $key = $HiveKey.OpenSubKey($SubKey)
            if (-not $key) { return $null }
            $values = @{}
            foreach ($name in $key.GetValueNames()) { $values[$name] = $key.GetValue($name) }
            $key.Close()
            return $values
        } catch { return $null }
    }

    try {
        if ($ComputerName -and $ComputerName -ne $env:COMPUTERNAME) {
            $hive = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $ComputerName)
        } else {
            $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)
        }
    } catch {
        Write-FSLogixLog "Could not open the registry on '$ComputerName': $($_.Exception.Message)" 'WARN'
        return $null
    }

    try {
        $profiles = & $read $hive $paths.Profiles
        $odfc     = & $read $hive $paths.ODFC
        if (-not $profiles -and -not $odfc) {
            Write-FSLogixLog "No FSLogix policy found under HKLM\SOFTWARE\FSLogix on '$(if ($ComputerName) { $ComputerName } else { $env:COMPUTERNAME })'." 'WARN'
            return $null
        }

        $flip = 0
        if ($profiles -and $profiles.ContainsKey('FlipFlopProfileDirectoryName')) { $flip = [int]$profiles['FlipFlopProfileDirectoryName'] }

        return [PSCustomObject]@{
            ComputerName             = if ($ComputerName) { $ComputerName } else { $env:COMPUTERNAME }
            VHDLocations             = if ($profiles -and $profiles.ContainsKey('VHDLocations')) { @($profiles['VHDLocations']) } else { @() }
            CCDLocations             = if ($profiles -and $profiles.ContainsKey('CCDLocations')) { @($profiles['CCDLocations']) } else { @() }
            ODFCLocations            = if ($odfc -and $odfc.ContainsKey('VHDLocations')) { @($odfc['VHDLocations']) } else { @() }
            ProfileMaxSizeGB         = if ($profiles -and $profiles.ContainsKey('SizeInMBs')) { [Math]::Round([double]$profiles['SizeInMBs'] / 1024, 2) } else { $null }
            OfficeMaxSizeGB          = if ($odfc -and $odfc.ContainsKey('SizeInMBs')) { [Math]::Round([double]$odfc['SizeInMBs'] / 1024, 2) } else { $null }
            FlipFlopDirectoryName    = ($flip -ne 0)
            NoProfileContainingFolder = if ($profiles -and $profiles.ContainsKey('NoProfileContainingFolder')) { ([int]$profiles['NoProfileContainingFolder'] -ne 0) } else { $false }
            VHDNamePattern           = if ($profiles -and $profiles.ContainsKey('VHDNamePattern')) { $profiles['VHDNamePattern'] } else { $null }
            IsCloudCache             = ($profiles -and $profiles.ContainsKey('CCDLocations'))
        }
    } finally {
        if ($hive) { $hive.Close() }
    }
}

function Get-FSLogixContainerHealth {
    <#
    .SYNOPSIS
        Health flags for one live container.
    .DESCRIPTION
        NEAR_LIMIT fires only when a real ceiling is known, from Get-VHD or from the
        registry's SizeInMBs. The old heuristic compared on-disk size against a hardcoded
        30/50/100/120 GB list, so a 46 GB container on a 100 GB limit was flagged and a
        105 GB container was flagged by nothing at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [double]$SizeGB,
        $MaxSizeGB,
        [string]$Signature = 'Unknown',
        [int]$WarnAtPercent = 90
    )

    $issues = @()

    if ($SizeGB -lt 0.001) { $issues += 'EMPTY' }
    if ($Signature -eq 'Invalid') { $issues += 'BAD_SIGNATURE' }

    if ($null -ne $MaxSizeGB -and $MaxSizeGB -gt 0) {
        if ($SizeGB -ge ($MaxSizeGB * ($WarnAtPercent / 100.0))) { $issues += 'NEAR_LIMIT' }
        if ($SizeGB -gt $MaxSizeGB) { $issues += 'OVER_LIMIT' }
    }

    # Kept for containers an admin has already marked by hand.
    if ((Split-Path -Leaf $Path) -match 'CORRUPT') { $issues += 'CORRUPT' }

    return , $issues
}

# --------------------------------------------------------------------
#  Active Directory (orphan detection, last logon)
# --------------------------------------------------------------------

function Initialize-FSLogixADCheck {
    <#
    .SYNOPSIS
        Probe AD reachability once per session. Orphan detection stays off if it fails.
    #>
    [CmdletBinding()]
    param()
    try {
        $searcher = [adsisearcher]'(objectClass=domainDNS)'
        $searcher.SizeLimit = 1
        [void]$searcher.FindOne()
        $script:ADCheckEnabled = $true
        Write-FSLogixLog 'AD connectivity verified - orphan detection enabled.' 'INFO'
    } catch {
        $script:ADCheckEnabled = $false
        Write-FSLogixLog "AD not reachable - orphan detection disabled ($($_.Exception.Message))." 'WARN'
    }
    return $script:ADCheckEnabled
}

function Clear-FSLogixADCache {
    [CmdletBinding()]
    param()
    $script:ADCheckCache = @{}
}

function Get-FSLogixADStatus {
    <#
    .SYNOPSIS
        Resolve an account by SID (preferred) or sAMAccountName, returning status and last logon.
    .DESCRIPTION
        The SID is the only identity in the folder name that survives a rename and works
        across a forest. Matching on the folder-derived sAMAccountName flagged every
        renamed or trusted-domain user as ORPHAN - and ORPHAN rows are highlighted as
        safe to retire.

        Fails safe: anything other than a definite "not found" reports OK, so a broken
        query never marks a live account as an orphan.
    #>
    [CmdletBinding()]
    param(
        [string]$Sid,
        [string]$UserName
    )

    if (-not $script:ADCheckEnabled) {
        return [PSCustomObject]@{ Status = 'UNKNOWN'; LastLogon = $null; Disabled = $null; ResolvedName = $null }
    }

    $cacheKey = if ($Sid) { "sid:$Sid" } else { "sam:$UserName" }
    if ($script:ADCheckCache.ContainsKey($cacheKey)) { return $script:ADCheckCache[$cacheKey] }

    $result = [PSCustomObject]@{ Status = 'OK'; LastLogon = $null; Disabled = $null; ResolvedName = $null }

    try {
        $entry = $null

        if ($Sid) {
            # Serverless SID bind: forest-wide and immune to account renames.
            try {
                $candidate = [ADSI]"LDAP://<SID=$Sid>"
                if ($candidate -and $candidate.Path) { $entry = $candidate }
            } catch {
                $entry = $null
            }
        }

        if (-not $entry -and $UserName) {
            $escaped  = Get-FSLogixLdapEscapedValue -Value $UserName
            $searcher = [adsisearcher]"(sAMAccountName=$escaped)"
            $searcher.SizeLimit = 1
            [void]$searcher.PropertiesToLoad.AddRange(@('samaccountname', 'lastlogontimestamp', 'useraccountcontrol', 'objectsid'))
            $found = $searcher.FindOne()
            if ($found) { $entry = $found.GetDirectoryEntry() }
        }

        if (-not $entry) {
            $result.Status = 'ORPHAN'
        } else {
            $result.ResolvedName = [string]$entry.Properties['samaccountname'].Value

            $uac = $entry.Properties['userAccountControl'].Value
            if ($null -ne $uac) { $result.Disabled = (([int]$uac -band 2) -eq 2) }

            $raw = $entry.Properties['lastLogonTimestamp'].Value
            if ($null -ne $raw) {
                try {
                    # IADsLargeInteger comes back as a COM object; the ADSI cast handles both shapes.
                    $ticks = if ($raw -is [long]) { $raw } else {
                        ([long]$raw.GetType().InvokeMember('HighPart', 'GetProperty', $null, $raw, $null) -shl 32) -bor
                        ([long]$raw.GetType().InvokeMember('LowPart',  'GetProperty', $null, $raw, $null) -band 0xFFFFFFFFL)
                    }
                    if ($ticks -gt 0) { $result.LastLogon = [datetime]::FromFileTimeUtc($ticks).ToLocalTime() }
                } catch {
                    $result.LastLogon = $null
                }
            }
        }
    } catch {
        # Query failure must never look like an orphan.
        $result.Status = 'UNKNOWN'
    }

    $script:ADCheckCache[$cacheKey] = $result
    return $result
}

function Get-FSLogixLdapEscapedValue {
    <#
    .SYNOPSIS
        Escape LDAP filter metacharacters (RFC 4515) in a folder-derived value.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)

    $sb = [System.Text.StringBuilder]::new()
    foreach ($char in $Value.ToCharArray()) {
        switch ($char) {
            '\'     { [void]$sb.Append('\5c') }
            '*'     { [void]$sb.Append('\2a') }
            '('     { [void]$sb.Append('\28') }
            ')'     { [void]$sb.Append('\29') }
            "`0"    { [void]$sb.Append('\00') }
            '/'     { [void]$sb.Append('\2f') }
            default { [void]$sb.Append($char) }
        }
    }
    return $sb.ToString()
}

# --------------------------------------------------------------------
#  Audit trail
# --------------------------------------------------------------------

function Set-FSLogixAuditRoot {
    <#
    .SYNOPSIS
        Point the audit trail at a central share.
    .DESCRIPTION
        ACL it so operators hold Write/AppendData but neither Delete nor Modify-existing,
        and remove CREATOR OWNER - otherwise it is logging, not audit. Once set explicitly,
        a failed audit write aborts the operation that triggered it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $script:AuditRoot           = $Path
    $script:AuditRootIsExplicit = $true
}

function Get-FSLogixAuditRoot {
    [CmdletBinding()]
    param()
    if ($script:AuditRoot) { return $script:AuditRoot }
    return (Join-Path $env:ProgramData 'FSLogixProfileManager\Audit')
}

function Get-FSLogixAuditConfiguration {
    [CmdletBinding()]
    param()
    return [PSCustomObject]@{ Path = (Get-FSLogixAuditRoot); IsExplicit = $script:AuditRootIsExplicit }
}

function Reset-FSLogixAuditRoot {
    [CmdletBinding()]
    param()
    $script:AuditRoot = $null
    $script:AuditRootIsExplicit = $false
}

function Write-FSLogixAudit {
    <#
    .SYNOPSIS
        Append one row to the monthly audit CSV.
    .DESCRIPTION
        One row per file action, recording who did it, from where, in what mode, and why.
        When -Critical is set and a central audit root was configured explicitly, a failed
        write throws - a rename that cannot be recorded must not happen.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Record,
        [switch]$Critical
    )

    $row = @{
        TimestampUtc        = (Get-Date).ToUniversalTime().ToString('o')
        Actor               = "$env:USERDOMAIN\$env:USERNAME"
        ActorHost           = $env:COMPUTERNAME
        Tool                = 'FSLogixProfileManager'
        Action              = ''
        Mode                = ''
        Reason              = ''
        TargetUser          = ''
        TargetSid           = ''
        SourcePath          = ''
        DestPath            = ''
        SizeGB              = ''
        Result              = ''
        HolderInfo          = ''
        HorizonSessionState = ''
    }
    foreach ($key in $Record.Keys) { $row[$key] = $Record[$key] }

    $root  = Get-FSLogixAuditRoot
    $file  = Join-Path $root ('actions_{0}.csv' -f (Get-Date -Format 'yyyy-MM'))
    $mutex = $null

    try {
        if (-not (Test-Path -LiteralPath $root)) {
            [void](New-Item -Path $root -ItemType Directory -Force -ErrorAction Stop)
        }
        $mutex = New-Object System.Threading.Mutex($false, 'Global\FSLogixProfileManagerAudit')
        if (-not $mutex.WaitOne(10000)) { throw 'Timed out waiting for the audit writer.' }
        [PSCustomObject]$row | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding UTF8 -Append -ErrorAction Stop
    } catch {
        $message = "Audit write failed ($file): $($_.Exception.Message)"
        if ($Critical -and $script:AuditRootIsExplicit) { throw $message }
        Write-FSLogixLog $message 'WARN'
    } finally {
        if ($mutex) {
            try { $mutex.ReleaseMutex() } catch { }
            $mutex.Dispose()
        }
    }
}

# --------------------------------------------------------------------
#  Horizon session gate (optional)
# --------------------------------------------------------------------

function Invoke-FSLogixHorizonRequest {
    [CmdletBinding()]
    param([hashtable]$Request, [switch]$SkipCertificateCheck)

    # Certificate bypass is a per-connection lab option, never process-wide state.
    $previousCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        if ($SkipCertificateCheck) {
            if ((Get-Command Invoke-RestMethod).Parameters.ContainsKey('SkipCertificateCheck')) {
                $Request.SkipCertificateCheck = $true
            } else {
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            }
        }
        $response = Invoke-RestMethod @Request
        # Preserve [] as an authoritative empty result, distinct from JSON null.
        return ,$response
    } finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
    }
}

function Connect-FSLogixHorizon {
    <#
    .SYNOPSIS
        Log in to a Horizon Connection Server's REST API.
    .DESCRIPTION
        Optional. When connected, retire operations can refuse to touch a container while
        the owner has a Horizon session - including a DISCONNECTED one, which still holds
        the Instant Clone alive and the container mounted. When not connected, callers
        must say so rather than implying the check passed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][pscredential]$Credential,
        [string]$Domain,
        [switch]$SkipCertificateCheck
    )

    [System.Net.ServicePointManager]::SecurityProtocol = `
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

    $user = $Credential.UserName
    if (-not $Domain -and $user -match '^(?<domain>[^\\]+)\\(?<name>.+)$') {
        $Domain = $Matches['domain']
        $user   = $Matches['name']
    }

    $body = @{
        username = $user
        password = $Credential.GetNetworkCredential().Password
        domain   = $Domain
    } | ConvertTo-Json

    # A failed reconnect must not leave an old server looking connected.
    $script:HorizonConnection = $null
    $response = Invoke-FSLogixHorizonRequest -Request @{
        Method = 'Post'; Uri = "https://$Server/rest/login"; Body = $body
        ContentType = 'application/json'; ErrorAction = 'Stop'
    } -SkipCertificateCheck:$SkipCertificateCheck
    if ([string]::IsNullOrWhiteSpace($response.access_token)) {
        throw 'Horizon login did not return an access token.'
    }

    $script:HorizonConnection = [PSCustomObject]@{
        Server  = $Server
        Headers = @{ Authorization = "Bearer $($response.access_token)" }
        SkipCertificateCheck = [bool]$SkipCertificateCheck
    }
    Write-FSLogixLog "Connected to Horizon Connection Server $Server." 'INFO'
    return $script:HorizonConnection
}

function Disconnect-FSLogixHorizon {
    [CmdletBinding()]
    param()
    $script:HorizonConnection = $null
}

function Test-FSLogixHorizonConnected {
    [CmdletBinding()]
    param()
    return ($null -ne $script:HorizonConnection)
}

function Get-FSLogixHorizonServer {
    [CmdletBinding()]
    param()
    if ($script:HorizonConnection) { return [string]$script:HorizonConnection.Server }
    return $null
}

function Get-FSLogixHorizonSession {
    <#
    .SYNOPSIS
        Return the Horizon sessions belonging to a user, or $null if not connected.
    .DESCRIPTION
        Endpoint versions move between Horizon 8 releases; check /rest/swagger.yaml on
        your build if the inventory path 404s.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$UserName)

    if (-not $script:HorizonConnection) { return $null }

    try {
        $sessions = Invoke-FSLogixHorizonRequest -Request @{
            Method = 'Get'; Uri = "https://$($script:HorizonConnection.Server)/rest/inventory/v1/sessions"
            Headers = $script:HorizonConnection.Headers; ErrorAction = 'Stop'
        } -SkipCertificateCheck:$script:HorizonConnection.SkipCertificateCheck
        if ($null -eq $sessions) { throw 'Horizon returned no session inventory.' }
        foreach ($session in @($sessions)) {
            if ($session.user_name -isnot [string] -or [string]::IsNullOrWhiteSpace($session.user_name)) {
                throw 'Unrecognized Horizon session response. Check API compatibility before retirement.'
            }
        }
        # Match domain-qualified, bare and UPN-style names conservatively.
        $userPattern = '(^|\\)' + [regex]::Escape($UserName) + '(@[^@\\]+)?$'
        return , @($sessions | Where-Object { $_.user_name -match $userPattern })
    } catch {
        Write-FSLogixLog "Horizon session query failed for '$UserName': $($_.Exception.Message)" 'WARN'
        return $null
    }
}

function Stop-FSLogixHorizonSession {
    <#
    .SYNOPSIS
        Log a Horizon session off. Never disconnect - a disconnected session keeps the
        container mounted.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][string]$SessionId)

    if (-not $script:HorizonConnection) { throw 'Not connected to a Horizon Connection Server.' }

    if ($PSCmdlet.ShouldProcess($SessionId, 'Log off Horizon session')) {
        $encodedId = [uri]::EscapeDataString($SessionId)
        Invoke-FSLogixHorizonRequest -Request @{
            Method = 'Post'; Uri = "https://$($script:HorizonConnection.Server)/rest/inventory/v1/sessions/$encodedId/logoff"
            Headers = $script:HorizonConnection.Headers; ErrorAction = 'Stop'
        } -SkipCertificateCheck:$script:HorizonConnection.SkipCertificateCheck
        Write-FSLogixLog "Logged off Horizon session $SessionId." 'INFO'
    }
}

# --------------------------------------------------------------------
#  Discovery
# --------------------------------------------------------------------

function Get-FSLogixRestoreInfo {
    # Moved retirements carry a relative original path. Never trust a manifest to
    # direct a restore outside the scanned root or back into the retirement tree.
    param($File, [string]$Root)
    $retired = Test-FSLogixRetiredName -FileName $File.Name
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $retiredRoot = Join-Path $rootPath '_retired'
    $isMoved = $File.FullName.StartsWith($retiredRoot + '\', [StringComparison]::OrdinalIgnoreCase)
    $info = [PSCustomObject]@{ LivePath = $null; UserName = $null; Sid = $null; IsSafe = $false; IsMoved = $isMoved }
    if (-not $retired) { return $info }
    if (-not $isMoved) {
        $info.LivePath = Join-Path $File.DirectoryName $retired.LiveName
        $info.IsSafe = $true
        return $info
    }
    $manifestPath = $File.FullName + '.restore.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { return $info }
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ([IO.Path]::IsPathRooted($manifest.OriginalRelativePath)) { return $info }
        $candidate = [IO.Path]::GetFullPath((Join-Path $rootPath $manifest.OriginalRelativePath))
        if (-not $candidate.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase) -or
            $candidate.StartsWith($retiredRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($candidate) -ne $retired.LiveName) { return $info }
        $info.LivePath = $candidate
        $info.UserName = $manifest.UserName
        $info.Sid = $manifest.Sid
        $info.IsSafe = $true
    } catch { }
    return $info
}

function Get-FSLogixProfiles {
    <#
    .SYNOPSIS
        Scan one or more FSLogix roots and aggregate containers into one object per user.
    .PARAMETER ProfileRoots
        UNC or local roots. Multiple roots are merged by user identity.
    .PARAMETER CloudCacheMode
        Treat the roots as Cloud Cache replicas of the same containers rather than as
        independent shares: sizes and counts are reported once instead of once per
        provider, and retire operations become all-or-nothing across replicas.
    .PARAMETER ReadVhdMetadata
        Read each container's real max size (Get-VHD) and file signature. Accurate, but
        a network round trip per file - leave it off for a first pass over a large share.
    .PARAMETER ConfiguredMaxSizeGB
        The SizeInMBs ceiling from FSLogix policy, used when Get-VHD is unavailable.
    .OUTPUTS
        Always an array, even for zero or one user.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$ProfileRoots,
        [switch]$CheckOrphans,
        [switch]$ReadVhdMetadata,
        [switch]$CloudCacheMode,
        [switch]$ErrorOnIncomplete,
        [double]$ConfiguredMaxSizeGB = 0,
        [double]$ConfiguredOfficeMaxSizeGB = 0,
        [int]$ProgressEvery = 250
    )

    $userTable  = @{}
    $scanErrors = @()
    $seenLogical = @{}   # Cloud Cache de-duplication: <userkey>|<filename> -> $true
    $fileCount  = 0

    if ($CheckOrphans) { [void](Initialize-FSLogixADCheck) }

    foreach ($root in $ProfileRoots) {
        $root = "$root".Trim()
        if ([string]::IsNullOrWhiteSpace($root)) { continue }

        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            if ($ErrorOnIncomplete) { throw "Profile root is unavailable: $root. Scan is incomplete; no actions should be taken." }
            Write-FSLogixLog "Profile root not found: $root" 'WARN'
            continue
        }

        Write-FSLogixLog "Scanning: $root" 'INFO'

        $rootErrors = @()
        $candidates = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.vhd* -ErrorAction SilentlyContinue -ErrorVariable +rootErrors)

        # -Filter *.vhd* is a prefix match: it also returns .vhdx.meta, .vhdx.metadata and
        # .vhdx.lock, which Cloud Cache writes next to every container. Treating those as
        # containers inflated counts, tripped the EMPTY health flag, and renamed FSLogix
        # metadata to <name>.vhdx-old.meta.
        $files = @($candidates | Where-Object { $script:ContainerExtensions -contains $_.Extension.ToLowerInvariant() })

        $skipped = $candidates.Count - $files.Count
        if ($skipped -gt 0) {
            Write-FSLogixLog "Ignored $skipped non-container file(s) (.meta/.metadata/.lock sidecars) under $root." 'INFO'
        }
        if ($rootErrors.Count -gt 0) {
            $scanErrors += $rootErrors
            if ($ErrorOnIncomplete) { throw "Scan is incomplete: $($rootErrors.Count) path(s) under $root could not be read. No actions should be taken." }
            Write-FSLogixLog "$($rootErrors.Count) path(s) under $root could not be read (access denied or path too long) - results for this root are INCOMPLETE." 'ERROR'
        }
        Write-FSLogixLog "Found $($files.Count) container file(s) under $root." 'INFO'

        foreach ($file in $files) {
            # Superseded containers are backups created by restore, never live targets.
            if (Test-FSLogixSupersededName -FileName $file.Name) { continue }
            $fileCount++
            if ($ProgressEvery -gt 0 -and ($fileCount % $ProgressEvery) -eq 0) {
                Write-FSLogixLog "Processed $fileCount container(s)..." 'PROGRESS'
            }

            $folderLeaf = Split-Path $file.DirectoryName -Leaf
            $identity   = Resolve-FSLogixIdentity -FolderLeaf $folderLeaf -FileName $file.Name
            if (Test-FSLogixRetiredName -FileName $file.Name) {
                $restoreInfo = Get-FSLogixRestoreInfo -File $file -Root $root
                if ($restoreInfo.UserName) {
                    $identity = [PSCustomObject]@{ UserName = $restoreInfo.UserName; Sid = $restoreInfo.Sid; Source = 'RetirementManifest' }
                }
            }

            # Unresolved rows are keyed on the directory, never on a shared guessed name.
            # Keying them on the folder leaf let a flat share collapse every container in
            # the estate into a single row that one click would then retire wholesale.
            $userKey = if ($identity.Source -eq 'Unresolved') {
                'path:' + $file.DirectoryName.ToLowerInvariant()
            } elseif ($identity.Sid) {
                'sid:' + $identity.Sid
            } else {
                'user:' + $identity.UserName.ToLowerInvariant()
            }

            if ($CloudCacheMode) {
                $logicalKey = $userKey + '|' + $file.Name.ToLowerInvariant()
                if ($seenLogical.ContainsKey($logicalKey)) {
                    # Same logical container on another provider: record the replica path
                    # but do not double-count its size.
                    if ($userTable.ContainsKey($userKey)) {
                        $existing = $userTable[$userKey].Containers | Where-Object { $_.Name -eq $file.Name } | Select-Object -First 1
                        if ($existing) { $existing.ReplicaPaths += $file.FullName }
                        [void]$userTable[$userKey].ProfileRoots.Add($root)
                    }
                    continue
                }
                $seenLogical[$logicalKey] = $true
            }

            $sizeGB  = [Math]::Round($file.Length / 1GB, 3)
            $retired = Test-FSLogixRetiredName -FileName $file.Name
            $class   = Get-FSLogixContainerClass -FileName $file.Name

            if (-not $userTable.ContainsKey($userKey)) {
                $userTable[$userKey] = [PSCustomObject]@{
                    UserName           = $identity.UserName
                    CloudCacheMode     = [bool]$CloudCacheMode
                    ExpectedProfileRoots = @($ProfileRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [IO.Path]::GetFullPath($_.Trim()).TrimEnd('\') })
                    Sid                = $identity.Sid
                    IdentitySource     = $identity.Source
                    IsIdentityResolved = ($identity.Source -ne 'Unresolved')
                    ContainerCount     = 0
                    Containers         = @()
                    RetiredContainers  = @()
                    ProfileSizeGB      = 0.0
                    OfficeSizeGB       = 0.0
                    UnknownSizeGB      = 0.0
                    TotalSizeGB        = 0.0
                    RetiredSizeGB      = 0.0
                    MaxSizeGB          = $null
                    LastWriteTime      = $file.LastWriteTime
                    RootFolder         = $file.DirectoryName
                    SIDs               = [System.Collections.Generic.HashSet[string]]::new()
                    ProfileRoots       = [System.Collections.Generic.HashSet[string]]::new()
                    HealthIssues       = [System.Collections.Generic.HashSet[string]]::new()
                    ADStatus           = 'UNKNOWN'
                    ADLastLogon        = $null
                    ADDisabled         = $null
                    ADResolvedName     = $null
                }
            }

            $entry = $userTable[$userKey]
            if ($identity.Sid) { [void]$entry.SIDs.Add($identity.Sid) }
            [void]$entry.ProfileRoots.Add($root)
            if (-not $entry.IsIdentityResolved) { [void]$entry.HealthIssues.Add('UNPARSED_NAME') }

            $maxSize   = $null
            $signature = 'Unknown'
            if ($ReadVhdMetadata -and -not $retired) {
                $maxSize   = Get-FSLogixVhdMaxSizeGB -Path $file.FullName
                $signature = Test-FSLogixVhdSignature -Path $file.FullName
            }
            if ($null -eq $maxSize) {
                if ($class -eq 'Office' -and $ConfiguredOfficeMaxSizeGB -gt 0) { $maxSize = $ConfiguredOfficeMaxSizeGB }
                elseif ($class -ne 'Office' -and $ConfiguredMaxSizeGB -gt 0)   { $maxSize = $ConfiguredMaxSizeGB }
            }

            $container = [PSCustomObject]@{
                Path          = $file.FullName
                Name          = $file.Name
                Directory     = $file.DirectoryName
                Root          = $root
                Class         = $class
                SizeGB        = $sizeGB
                LastWriteTime = $file.LastWriteTime
                IsRetired     = ($null -ne $retired)
                RetiredOn     = if ($retired) { $retired.RetiredOn } else { $null }
                RetiredStamp  = if ($retired) { $retired.Stamp } else { $null }
                LiveName      = if ($retired) { $retired.LiveName } else { $file.Name }
                MaxSizeGB     = $maxSize
                Signature     = $signature
                Issues        = @()
                ReplicaPaths  = @()
            }

            if ($retired) {
                # Retired containers are reported, never re-targeted. Leaving them in the
                # live set is what caused a second reset to skip the live container (its
                # -old target already existed) and rename the previous backup to -old-old.
                $entry.RetiredContainers += $container
                $entry.RetiredSizeGB     += $sizeGB
                [void]$entry.HealthIssues.Add('HAS_RETIRED')
                if ($entry.ContainerCount -eq 0 -and $file.LastWriteTime -gt $entry.LastWriteTime) { $entry.LastWriteTime = $file.LastWriteTime }
                continue
            }

            $container.Issues = Get-FSLogixContainerHealth -Path $file.FullName -SizeGB $sizeGB -MaxSizeGB $maxSize -Signature $signature
            foreach ($issue in $container.Issues) { [void]$entry.HealthIssues.Add($issue) }

            $entry.Containers += $container
            $entry.ContainerCount++

            switch ($class) {
                'Office'  { $entry.OfficeSizeGB  += $sizeGB }
                'Profile' { $entry.ProfileSizeGB += $sizeGB }
                default   { $entry.UnknownSizeGB += $sizeGB; [void]$entry.HealthIssues.Add('UNKNOWN_TYPE') }
            }
            $entry.TotalSizeGB = [Math]::Round($entry.ProfileSizeGB + $entry.OfficeSizeGB + $entry.UnknownSizeGB, 3)

            if ($null -ne $maxSize -and ($null -eq $entry.MaxSizeGB -or $maxSize -gt $entry.MaxSizeGB)) {
                $entry.MaxSizeGB = $maxSize
            }
            if ($entry.ContainerCount -eq 1 -or $file.LastWriteTime -gt $entry.LastWriteTime) { $entry.LastWriteTime = $file.LastWriteTime }
        }
    }

    foreach ($entry in $userTable.Values) {
        if ($entry.ContainerCount -eq 0 -and $entry.RetiredContainers.Count -gt 0) {
            [void]$entry.HealthIssues.Add('NO_LIVE_CONTAINER')
        }
        if ($entry.SIDs.Count -gt 1) { [void]$entry.HealthIssues.Add('MULTIPLE_SIDS') }
    }

    if ($CheckOrphans -and $script:ADCheckEnabled) {
        Write-FSLogixLog "Checking AD status for $($userTable.Count) user(s)..." 'INFO'
        $orphans = 0
        foreach ($entry in $userTable.Values) {
            $status = Get-FSLogixADStatus -Sid $entry.Sid -UserName $entry.UserName
            $entry.ADStatus       = $status.Status
            $entry.ADLastLogon    = $status.LastLogon
            $entry.ADDisabled     = $status.Disabled
            $entry.ADResolvedName = $status.ResolvedName
            if ($status.Status -eq 'ORPHAN') {
                [void]$entry.HealthIssues.Add('ORPHAN')
                $orphans++
            }
            if ($status.Disabled -eq $true) { [void]$entry.HealthIssues.Add('AD_DISABLED') }
        }
        Write-FSLogixLog "Found $orphans orphaned profile(s)." 'INFO'
    }

    if ($scanErrors.Count -gt 0) {
        Write-FSLogixLog "Scan completed with $($scanErrors.Count) unreadable path(s). Treat the results as incomplete." 'ERROR'
    }
    Write-FSLogixLog "Total unique users found: $($userTable.Count)" 'INFO'

    # Always an array. Returning the raw pipeline unrolled a single user to a scalar,
    # which then failed to bind to the filter's IEnumerable parameter - the GUI errored
    # and the CLI silently reported "no profiles matched". Note the leading comma: @()
    # alone is not enough, because PowerShell re-unrolls a one-element array on output.
    return , @($userTable.Values | Sort-Object UserName)
}

function Select-FSLogixProfile {
    <#
    .SYNOPSIS
        Filter discovered profiles by name, age, health or AD state.
    .PARAMETER UserFilter
        Wildcard patterns. Values are escaped before the implicit *...* wrap, so a literal
        '[' typed into a filter box no longer throws an invalid-pattern error.
    #>
    [CmdletBinding()]
    param(
        $Source,
        [string[]]$UserFilter,
        [switch]$ExactPattern,
        [int]$AgeDays = 0,
        [switch]$OnlyIssues,
        [switch]$OnlyOrphans,
        [int]$ADLastLogonDays = 0
    )

    $filtered = @($Source | Where-Object { $null -ne $_ })

    if ($UserFilter) {
        $patterns = @($UserFilter | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($patterns.Count -gt 0) {
            $filtered = @($filtered | Where-Object {
                $name = $_.UserName
                $hit  = $false
                foreach ($pattern in $patterns) {
                    $effective = if ($ExactPattern) { $pattern } else { '*' + [System.Management.Automation.WildcardPattern]::Escape($pattern) + '*' }
                    if ($name -like $effective) { $hit = $true; break }
                }
                $hit
            })
        }
    }

    if ($AgeDays -gt 0) {
        $threshold = (Get-Date).AddDays(-$AgeDays)
        $filtered = @($filtered | Where-Object { $_.LastWriteTime -lt $threshold })
    }

    if ($ADLastLogonDays -gt 0) {
        $threshold = (Get-Date).AddDays(-$ADLastLogonDays)
        # A null LastLogon means "not known", which must not be read as "not used".
        $filtered = @($filtered | Where-Object { $null -ne $_.ADLastLogon -and $_.ADLastLogon -lt $threshold })
    }

    if ($OnlyIssues)  { $filtered = @($filtered | Where-Object { $_.HealthIssues.Count -gt 0 }) }
    if ($OnlyOrphans) { $filtered = @($filtered | Where-Object { $_.ADStatus -eq 'ORPHAN' }) }

    return , @($filtered)
}

# --------------------------------------------------------------------
#  Retire plan and execution
# --------------------------------------------------------------------

function Get-FSLogixRetirePlan {
    <#
    .SYNOPSIS
        Work out exactly which files a retire would touch, and whether each one is ready.
    .DESCRIPTION
        The preview dialog and the retire itself both build the plan from this function,
        so what the operator is shown is what will be attempted. Previously the preview
        applied its own copy of the targeting rules and always probed for in-use files
        even when the retire was configured to ignore them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$ProfileObject,
        [ValidateSet('All', 'Office', 'Profile')][string]$Scope = 'All',
        [ValidatePattern('^\d{8}-\d{6}$')][string]$BatchStamp,
        [switch]$CheckInUse,
        [switch]$MoveToRetired
    )

    if (-not $BatchStamp) { $BatchStamp = New-FSLogixBatchStamp }

    $targets = switch ($Scope) {
        'Office'  { @($ProfileObject.Containers | Where-Object { $_.Class -eq 'Office' }) }
        'Profile' { @($ProfileObject.Containers | Where-Object { $_.Class -eq 'Profile' }) }
        default   { @($ProfileObject.Containers) }
    }

    # Expand logical Cloud Cache containers into every physical provider path.
    $physical = @()
    foreach ($target in $targets) {
        $physical += $target
        foreach ($replica in @($target.ReplicaPaths)) {
            $replicaRoot = @($ProfileObject.ProfileRoots | Where-Object {
                $replica.StartsWith([IO.Path]::GetFullPath($_).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
            } | Sort-Object Length -Descending | Select-Object -First 1)
            if ($replicaRoot.Count -ne 1) { throw "Cannot resolve replica root: $replica" }
            $copy = $target.PSObject.Copy()
            $copy.Path = $replica
            $copy.Root = $replicaRoot[0]
            $copy.Directory = Split-Path -Parent $replica
            $physical += $copy
        }
    }
    $targets = @($physical | Sort-Object Path -Unique)
    $handlesByServer = @{}
    if ($CheckInUse) {
        foreach ($serverGroup in @($targets | Group-Object -Property {
            if ($_.Path -match '^\\\\(?<server>[^\\]+)\\') { $Matches['server'].ToLowerInvariant() } else { '[local]' }
        })) {
            $handlesByServer[$serverGroup.Name] = Get-FSLogixOpenHandle -Path @($serverGroup.Group.Path)
        }
    }

    $safeUser = ($ProfileObject.UserName -replace ('[' + [regex]::Escape(-join [System.IO.Path]::GetInvalidFileNameChars()) + ']'), '_')
    if ([string]::IsNullOrWhiteSpace($safeUser) -or $safeUser -in @('.', '..')) { $safeUser = '_user' }

    $plan = @()
    foreach ($container in $targets) {
        $newName = Get-FSLogixRetireTargetName -FileName $container.Name -BatchStamp $BatchStamp
        if ($MoveToRetired) {
            # Lift the retired file out of the user's writable directory into
            # <root>\_retired\<user>\<batch-stamp>\. Operators must configure ACLs
            # and quota exclusions for that location separately.
            $newDir  = Join-Path (Join-Path (Join-Path $container.Root '_retired') $safeUser) $BatchStamp
            $newPath = Join-Path $newDir $newName
        } else {
            $newPath = Join-Path $container.Directory $newName
        }

        $state  = 'Ready'
        $holder = $null
        $note   = ''

        if (-not (Test-Path -LiteralPath $container.Path)) {
            $state = 'Missing'
            $note  = 'Container no longer present.'
        } elseif (Test-Path -LiteralPath $newPath) {
            $state = 'Exists'
            $note  = 'Retire target already exists.'
        } elseif ($CheckInUse) {
            $serverKey = if ($container.Path -match '^\\\\(?<server>[^\\]+)\\') { $Matches['server'].ToLowerInvariant() } else { '[local]' }
            $handles = $handlesByServer[$serverKey]
            $probe = Get-FSLogixContainerState -Path $container.Path -OpenHandles $handles
            switch ($probe.State) {
                'InUse'        { $state = 'InUse';        $holder = $probe.Holder; $note = 'Held open.' }
                'AccessDenied' { $state = 'AccessDenied'; $note = 'No rights to open the container; rename will probably fail.' }
                'Missing'      { $state = 'Missing';      $note = 'Container no longer present.' }
            }
        }

        $plan += [PSCustomObject]@{
            UserName     = $ProfileObject.UserName
            Class        = $container.Class
            SourcePath   = $container.Path
            DestPath     = $newPath
            DestName     = $newName
            SizeGB       = $container.SizeGB
            Root         = $container.Root
            ReplicaPaths = $container.ReplicaPaths
            State        = $state
            Holder       = $holder
            Note         = $note
        }
    }

    # Duplicate destinations (for example duplicate names beneath one root) must
    # never overwrite a backup during a move.
    foreach ($group in @($plan | Group-Object DestPath | Where-Object Count -gt 1)) {
        foreach ($item in $group.Group) { $item.State = 'Exists'; $item.Note = 'Multiple containers resolve to the same retirement path.' }
    }
    if ($ProfileObject.CloudCacheMode) {
        foreach ($logical in @($ProfileObject.Containers)) {
            $paths = @($logical.Path) + @($logical.ReplicaPaths)
            $logicalPlans = @($plan | Where-Object { $paths -contains $_.SourcePath })
            $presentRoots = @($logicalPlans | ForEach-Object { [IO.Path]::GetFullPath($_.Root).TrimEnd('\') })
            $missingRoots = @($ProfileObject.ExpectedProfileRoots | Where-Object { $presentRoots -notcontains $_ })
            if ($missingRoots.Count -gt 0) {
                foreach ($item in $logicalPlans) {
                    $item.State = 'Missing'
                    $item.Note = 'Cloud Cache replica not discovered in configured provider(s): ' + ($missingRoots -join ', ')
                }
            }
        }
    }

    return , @($plan)
}

function Rename-FSLogixProfileObject {
    <#
    .SYNOPSIS
        Retire a user's containers by renaming them to <name>-old-<batch stamp>.<ext>.
    .DESCRIPTION
        Never deletes. Returns a structured result so the caller can report what actually
        happened - the previous version returned only a log path, so a run in which every
        rename failed with Access Denied looked identical to a clean one.
    .PARAMETER AllOrNothing
        Required for Cloud Cache: abort the whole user rather than leave replicas
        half-retired, and roll back any rename already made if a later one fails. A
        partially retired replica set either resyncs the surviving copy back (silently
        undoing the reset) or diverges.
    .PARAMETER Force
        Permit retiring a row whose username and SID could not be parsed out of the share
        layout. Off by default: an unresolved row's identity is a guess.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]$ProfileObject,
        [ValidateSet('All', 'Office', 'Profile')][string]$Scope = 'All',
        [bool]$CheckInUse = $true,
        [string]$Reason,
        [ValidatePattern('^\d{8}-\d{6}$')][string]$BatchStamp,
        [switch]$AllOrNothing,
        [switch]$Force,
        [switch]$RequireHorizonCheck,
        [switch]$MoveToRetired
    )

    if (-not $BatchStamp) { $BatchStamp = New-FSLogixBatchStamp }
    if ($ProfileObject.CloudCacheMode) { $AllOrNothing = $true }

    $user   = $ProfileObject.UserName
    $sid    = $ProfileObject.Sid
    $isSim  = $WhatIfPreference
    $mode   = if ($isSim) { 'WHATIF' } else { 'LIVE' }
    $safeUser = ($user -replace ('[' + [regex]::Escape(-join [System.IO.Path]::GetInvalidFileNameChars()) + ']'), '_')
    $logPath  = Join-Path $env:TEMP ('FSLogix_Rename_{0}_{1}_{2}.log' -f $safeUser, $mode, (Get-Date -Format 'yyyyMMddHHmmss'))

    $result = [PSCustomObject]@{
        UserName      = $user
        Sid           = $sid
        Mode          = $mode
        Scope         = $Scope
        BatchStamp    = $BatchStamp
        LogPath       = $logPath
        Planned       = 0
        Renamed       = 0
        SkippedInUse  = 0
        SkippedExists = 0
        Missing       = 0
        Failed        = 0
        Aborted       = $false
        AbortReason   = $null
        Errors        = @()
        Actions       = @()
    }

    $writer = $null
    try {
        $writer = [System.IO.StreamWriter]::new($logPath, $true, [System.Text.Encoding]::UTF8)
    } catch {
        Write-FSLogixLog "Could not open log file '$logPath': $($_.Exception.Message)" 'WARN'
    }

    $log = {
        param([string]$Message, [string]$Level = 'INFO')
        $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        if ($writer) { try { $writer.WriteLine($line) } catch { } }
        Write-FSLogixLog $Message $Level
    }

    try {
        & $log ("Retire '{0}' | mode={1} scope={2} batch={3} checkInUse={4} allOrNothing={5}" -f $user, $mode, $Scope, $BatchStamp, $CheckInUse, [bool]$AllOrNothing)
        & $log ("Actor: {0}\{1} on {2} | Reason: {3}" -f $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME, $(if ($Reason) { $Reason } else { '(none given)' }))

        if (-not $ProfileObject.IsIdentityResolved -and -not $Force) {
            $result.Aborted     = $true
            $result.AbortReason = "Identity could not be parsed from the share layout for '$user'. Re-run with -Force only if you are certain which account this is."
            & $log $result.AbortReason 'ERROR'
            return $result
        }

        if ($RequireHorizonCheck) {
            if (-not (Test-FSLogixHorizonConnected)) {
                $result.Aborted     = $true
                $result.AbortReason = 'A Horizon session check was required but no Connection Server is configured.'
                & $log $result.AbortReason 'ERROR'
                return $result
            }
            $sessions = Get-FSLogixHorizonSession -UserName $user
            if ($null -eq $sessions) {
                $result.Aborted = $true
                $result.AbortReason = 'The required Horizon session check failed. No changes made.'
                return $result
            }
            if ($sessions.Count -gt 0) {
                $states = ($sessions | ForEach-Object { $_.session_state }) -join ', '
                $result.Aborted     = $true
                $result.AbortReason = "'$user' has $($sessions.Count) Horizon session(s) [$states]. Log the user off and let the clone refresh before retiring."
                & $log $result.AbortReason 'ERROR'
                return $result
            }
        }

        $plan = Get-FSLogixRetirePlan -ProfileObject $ProfileObject -Scope $Scope -BatchStamp $BatchStamp -CheckInUse:$CheckInUse -MoveToRetired:$MoveToRetired
        $result.Planned = $plan.Count

        if ($plan.Count -eq 0) {
            & $log "No $Scope containers to retire for '$user'." 'WARN'
            return $result
        }

        $notReady = @($plan | Where-Object { $_.State -ne 'Ready' })
        if ($AllOrNothing -and $notReady.Count -gt 0) {
            $result.Aborted     = $true
            $result.AbortReason = "All-or-nothing: $($notReady.Count) of $($plan.Count) target(s) are not ready across $($ProfileObject.ProfileRoots.Count) root(s). No changes made."
            & $log $result.AbortReason 'ERROR'
            foreach ($item in $notReady) { & $log ("  {0} -> {1} {2}" -f $item.SourcePath, $item.State, $item.Note) 'ERROR' }
            return $result
        }

        $completed = @()
        foreach ($item in $plan) {
            if ($item.State -ne 'Ready') {
              switch ($item.State) {
                'Missing'      { $result.Missing++;       & $log "Missing (skip): $($item.SourcePath)" 'WARN' }
                'Exists'       { $result.SkippedExists++; & $log "Retire target exists (skip): $($item.DestPath)" 'WARN' }
                'InUse'        { $result.SkippedInUse++;  & $log ("IN USE (skip): {0}{1}" -f $item.SourcePath, $(if ($item.Holder) { " [held by $($item.Holder)]" } else { '' })) 'WARN' }
                'AccessDenied' { $result.Failed++;        & $log "Access denied (skip): $($item.SourcePath)" 'ERROR'; $result.Errors += "Access denied: $($item.SourcePath)" }
              }
              continue
            }

            if (-not $PSCmdlet.ShouldProcess($item.SourcePath, "Retire to $($item.DestName)")) {
                if ($isSim) {
                    & $log "WHATIF: would rename $($item.SourcePath) -> $($item.DestPath)"
                    $result.Actions += $item
                } else {
                    & $log "Skipped by operator: $($item.SourcePath)" 'WARN'
                }
                continue
            }

            try {
                # Record intent before touching a container. A required central audit
                # failure must leave the filesystem unchanged.
                Write-FSLogixAudit -Critical -Record @{
                    Action = 'RETIRE'; Mode = $mode; Reason = $Reason
                    TargetUser = $user; TargetSid = $sid
                    SourcePath = $item.SourcePath; DestPath = $item.DestPath
                    SizeGB = $item.SizeGB; Result = 'STARTED'; HolderInfo = $item.Holder
                }
                if ($MoveToRetired) {
                    # Move across directories - the dest lives under
                    # <root>\_retired\<user>\<batch-stamp>\. Create the
                    # directory first; the share is expected to ACL it
                    # operators-only.
                    $destDir = Split-Path -Parent $item.DestPath
                    if (-not (Test-Path -LiteralPath $destDir)) {
                        [void](New-Item -Path $destDir -ItemType Directory -Force -ErrorAction Stop)
                    }
                    $rootPrefix = [IO.Path]::GetFullPath($item.Root).TrimEnd('\') + '\'
                    if (-not $item.SourcePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Source is outside the profile root.' }
                    $manifest = [ordered]@{
                        OriginalRelativePath = $item.SourcePath.Substring($rootPrefix.Length)
                        UserName = $user; Sid = $sid; BatchStamp = $BatchStamp
                    }
                    $manifestPath = $item.DestPath + '.restore.json'
                    if (Test-Path -LiteralPath $manifestPath) {
                        $existingManifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                        if ($existingManifest.OriginalRelativePath -ne $manifest.OriginalRelativePath -or
                            $existingManifest.UserName -ne $manifest.UserName -or
                            $existingManifest.Sid -ne $manifest.Sid) { throw "A different restore manifest already exists: $manifestPath" }
                    } else {
                        $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8 -ErrorAction Stop
                    }
                    [IO.File]::Move($item.SourcePath, $item.DestPath)
                } else {
                    Rename-Item -LiteralPath $item.SourcePath -NewName $item.DestName -ErrorAction Stop
                }
                $result.Renamed++
                $completed += $item
                $result.Actions += $item
                & $log (("{0} {1} -> {2}") -f $(if ($MoveToRetired) { 'Moved' } else { 'Renamed' }), $item.SourcePath, $item.DestPath) 'INFO'
                Write-FSLogixAudit -Critical -Record @{
                    Action = 'RETIRE'; Mode = $mode; Reason = $Reason
                    TargetUser = $user; TargetSid = $sid
                    SourcePath = $item.SourcePath; DestPath = $item.DestPath
                    SizeGB = $item.SizeGB; Result = 'OK'; HolderInfo = $item.Holder
                }
            } catch {
                $result.Failed++
                $result.Errors += "$($item.SourcePath): $($_.Exception.Message)"
                & $log ("ERROR renaming {0}: {1}" -f $item.SourcePath, $_.Exception.Message) 'ERROR'
                Write-FSLogixAudit -Record @{
                    Action = 'RETIRE'; Mode = $mode; Reason = $Reason
                    TargetUser = $user; TargetSid = $sid
                    SourcePath = $item.SourcePath; DestPath = $item.DestPath
                    SizeGB = $item.SizeGB; Result = "FAILED: $($_.Exception.Message)"
                }

                if ($AllOrNothing -or $script:AuditRootIsExplicit) {
                    & $log "All-or-nothing: rolling back $($completed.Count) rename(s) for '$user'." 'ERROR'
                    $rolledBack = 0
                    foreach ($done in ($completed | Sort-Object -Property SourcePath -Descending)) {
                        try {
                            if ($MoveToRetired) {
                                [IO.File]::Move($done.DestPath, $done.SourcePath)
                            } else {
                                Rename-Item -LiteralPath $done.DestPath -NewName (Split-Path -Leaf $done.SourcePath) -ErrorAction Stop
                            }
                            $rolledBack++
                            & $log "Rolled back $($done.DestPath) -> $($done.SourcePath)" 'WARN'
                            Write-FSLogixAudit -Record @{
                                Action = 'RETIRE-ROLLBACK'; Mode = $mode; Reason = $Reason
                                TargetUser = $user; TargetSid = $sid
                                SourcePath = $done.DestPath; DestPath = $done.SourcePath; Result = 'OK'
                            }
                        } catch {
                            & $log "ROLLBACK FAILED for $($done.DestPath): $($_.Exception.Message). Manual repair required." 'ERROR'
                            $result.Errors += "Rollback failed: $($done.DestPath)"
                        }
                    }
                    $result.Renamed     = $completed.Count - $rolledBack
                    $result.Aborted     = $true
                    $result.AbortReason = if ($result.Renamed -eq 0) { 'Retirement failed; completed file moves were rolled back.' } else { 'Retirement failed and rollback was incomplete. Manual repair is required.' }
                    return $result
                }
            }
        }

        & $log ("Completed '{0}': renamed={1} inUse={2} exists={3} missing={4} failed={5}" -f `
            $user, $result.Renamed, $result.SkippedInUse, $result.SkippedExists, $result.Missing, $result.Failed)
    } finally {
        if ($writer) { try { $writer.Flush(); $writer.Dispose() } catch { } }
    }

    return $result
}

# --------------------------------------------------------------------
#  Restore
# --------------------------------------------------------------------

function Restore-FSLogixProfileBatch {
    <#
    .SYNOPSIS
        Bring a retired batch back into service.
    .DESCRIPTION
        Restores whole batches rather than single files: a reset retires the Profile and
        Office containers together (and, under Cloud Cache, every replica), so restoring
        one file at a time recreates the mismatched-pair problem it was meant to fix.

        Nothing is deleted. If a live container exists - the user logged on after the
        reset and got a fresh one - it is displaced to <name>-superseded-<stamp> first, so
        the restore is itself reversible.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][PSCustomObject[]]$Container,
        [string]$UserName = '(unknown)',
        [string]$Sid,
        [bool]$CheckInUse = $true,
        [string]$Reason,
        [switch]$SkipSignatureCheck
    )

    $isSim = $WhatIfPreference
    $mode  = if ($isSim) { 'WHATIF' } else { 'LIVE' }

    $result = [PSCustomObject]@{
        UserName    = $UserName
        Mode        = $mode
        Planned     = @($Container).Count
        Restored    = 0
        Displaced   = 0
        Failed      = 0
        Aborted     = $false
        AbortReason = $null
        Errors      = @()
    }

    # Validate the entire batch against current filesystem state, not report fields.
    $plan = @()
    foreach ($item in @($Container)) {
        try {
            $file = Get-Item -LiteralPath $item.Path -ErrorAction Stop
            $retired = Test-FSLogixRetiredName -FileName $file.Name
            if (-not $retired -or $script:ContainerExtensions -notcontains $file.Extension.ToLowerInvariant()) { throw 'Not a retired container.' }
            $root = if ($item.Root) { $item.Root } else { $file.DirectoryName }
            $info = Get-FSLogixRestoreInfo -File $file -Root $root
            if (-not $info.IsSafe) { throw 'Original path is unknown or the restore manifest is invalid. Manual recovery is required.' }
            if (-not $SkipSignatureCheck -and (Test-FSLogixVhdSignature -Path $file.FullName) -ne 'Valid') { throw 'VHD signature could not be validated.' }
            $livePath = $info.LivePath
            if ($CheckInUse) {
                foreach ($probePath in @($file.FullName, $livePath)) {
                    if ((Test-Path -LiteralPath $probePath) -and
                        (Get-FSLogixContainerState -Path $probePath -OpenHandles (Get-FSLogixOpenHandle -Path @($probePath))).State -ne 'Free') {
                        throw "Container cannot be safely opened: $probePath"
                    }
                }
            }
            $displaceTo = $null
            if (Test-Path -LiteralPath $livePath) {
                $base = [IO.Path]::GetFileNameWithoutExtension($retired.LiveName)
                $ext = [IO.Path]::GetExtension($retired.LiveName)
                $displaceTo = Join-Path (Split-Path -Parent $livePath) ('{0}-superseded-{1}{2}' -f $base, (New-FSLogixBatchStamp), $ext)
                if (Test-Path -LiteralPath $displaceTo) { throw "Displacement target already exists: $displaceTo" }
            }
            if ($plan.LivePath -contains $livePath) { throw "Multiple retired containers target $livePath. Select one retirement batch." }
            $identity = Resolve-FSLogixIdentity -FolderLeaf (Split-Path (Split-Path -Parent $livePath) -Leaf) -FileName (Split-Path -Leaf $livePath)
            $auditUser = if ($info.UserName) { $info.UserName } elseif ($identity.Source -ne 'Unresolved') { $identity.UserName } else { $UserName }
            $auditSid = if ($info.Sid) { $info.Sid } elseif ($identity.Sid) { $identity.Sid } else { $Sid }
            $plan += [PSCustomObject]@{ RetiredPath = $file.FullName; LivePath = $livePath; DisplaceTo = $displaceTo; SizeGB = $item.SizeGB; DidDisplace = $false; DidRestore = $false; TargetUser = $auditUser; TargetSid = $auditSid }
        } catch {
            $result.Aborted = $true
            $result.AbortReason = $_.Exception.Message
            return $result
        }
    }
    if (-not $PSCmdlet.ShouldProcess(($plan.LivePath -join ', '), "Restore $($plan.Count) retired container(s), preserving any current live files")) { return $result }
    try {
        # Audit all intents before the first mutation. Required audit outages fail closed.
        foreach ($step in $plan) {
            Write-FSLogixAudit -Critical -Record @{ Action = 'RESTORE'; Mode = $mode; Reason = $Reason; TargetUser = $step.TargetUser; TargetSid = $step.TargetSid; SourcePath = $step.RetiredPath; DestPath = $step.LivePath; Result = 'STARTED' }
        }
        foreach ($step in $plan) {
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $step.LivePath))
            if ($step.DisplaceTo) {
                [IO.File]::Move($step.LivePath, $step.DisplaceTo)
                $step.DidDisplace = $true
                $result.Displaced++
                Write-FSLogixAudit -Critical -Record @{ Action = 'RESTORE-DISPLACE'; Mode = $mode; Reason = $Reason; TargetUser = $step.TargetUser; TargetSid = $step.TargetSid; SourcePath = $step.LivePath; DestPath = $step.DisplaceTo; Result = 'OK' }
            }
            [IO.File]::Move($step.RetiredPath, $step.LivePath)
            $step.DidRestore = $true
            $result.Restored++
            Write-FSLogixLog "Restored $($step.RetiredPath) -> $($step.LivePath)" 'INFO'
            Write-FSLogixAudit -Critical -Record @{ Action = 'RESTORE'; Mode = $mode; Reason = $Reason; TargetUser = $step.TargetUser; TargetSid = $step.TargetSid; SourcePath = $step.RetiredPath; DestPath = $step.LivePath; SizeGB = $step.SizeGB; Result = 'OK' }
        }
    } catch {
        $result.Failed++
        $result.Aborted = $true
        $result.AbortReason = 'Restore failed; rollback attempted. Review Errors for any manual recovery required.'
        $result.Errors += $_.Exception.Message
        # Reverse execution order, restoring both the original retirement and current live file.
        [array]::Reverse($plan)
        foreach ($step in $plan) {
            try {
                if ($step.DidRestore) { [IO.File]::Move($step.LivePath, $step.RetiredPath); $result.Restored-- }
                if ($step.DidDisplace) { [IO.File]::Move($step.DisplaceTo, $step.LivePath); $result.Displaced-- }
                Write-FSLogixAudit -Record @{ Action = 'RESTORE-ROLLBACK'; Mode = $mode; Reason = $Reason; TargetUser = $step.TargetUser; TargetSid = $step.TargetSid; SourcePath = $step.LivePath; DestPath = $step.RetiredPath; Result = 'OK' }
            } catch { $result.Errors += "Rollback failed: $($_.Exception.Message)" }
        }
    }

    return $result
}

# --------------------------------------------------------------------
#  Retired container lifecycle (report + purge)
# --------------------------------------------------------------------

function Get-FSLogixRetiredContainer {
    <#
    .SYNOPSIS
        Report every retired container under the roots, with age and reclaimable size.
    .DESCRIPTION
        Retired containers are never removed by the retire path, so without this they
        accumulate until the share fills - and because Rename-Item preserves LastWriteTime,
        containers retired before the timestamped suffix have no recorded retirement date.
        Those are reported with DateSource = 'mtime-approx'.

        HasLiveSibling is the important column: a retired container with no live sibling is
        the only copy of that profile.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]]$ProfileRoots,
        [int]$OlderThanDays = 0,
        [switch]$ErrorOnIncomplete
    )

    $now     = Get-Date
    $results = @()

    foreach ($root in $ProfileRoots) {
        $root = "$root".Trim()
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root -PathType Container)) {
            if ($ErrorOnIncomplete) { throw "Retired-container root is unavailable: $root. Report is incomplete." }
            continue
        }

        $reportErrors = @()
        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.vhd* -ErrorAction SilentlyContinue -ErrorVariable +reportErrors |
                   Where-Object { $script:ContainerExtensions -contains $_.Extension.ToLowerInvariant() })
        if ($ErrorOnIncomplete -and $reportErrors.Count -gt 0) { throw "Retired-container report is incomplete: $($reportErrors.Count) path(s) under $root could not be read." }

        foreach ($file in $files) {
            $retired = Test-FSLogixRetiredName -FileName $file.Name
            if (-not $retired) { continue }

            $retiredOn  = if ($retired.RetiredOn) { $retired.RetiredOn } else { $file.LastWriteTime }
            $dateSource = if ($retired.RetiredOn) { 'stamp' } else { 'mtime-approx' }
            $ageDays    = [int][Math]::Floor(($now - $retiredOn).TotalDays)
            if ($OlderThanDays -gt 0 -and $ageDays -lt $OlderThanDays) { continue }

            $identity = Resolve-FSLogixIdentity -FolderLeaf (Split-Path $file.DirectoryName -Leaf) -FileName $file.Name
            $restoreInfo = Get-FSLogixRestoreInfo -File $file -Root $root
            $livePath = $restoreInfo.LivePath
            if ($restoreInfo.UserName) { $identity = [PSCustomObject]@{ UserName = $restoreInfo.UserName; Sid = $restoreInfo.Sid } }

            $results += [PSCustomObject]@{
                UserName       = $identity.UserName
                Sid            = $identity.Sid
                Path           = $file.FullName
                Name           = $file.Name
                Directory      = $file.DirectoryName
                Root           = $root
                Class          = Get-FSLogixContainerClass -FileName $retired.LiveName
                SizeGB         = [Math]::Round($file.Length / 1GB, 3)
                RetiredOn      = $retiredOn
                AgeDays        = $ageDays
                BatchStamp     = $retired.Stamp
                DateSource     = $dateSource
                LiveName       = $retired.LiveName
                LivePath       = $livePath
                CanRestore     = $restoreInfo.IsSafe
                HasLiveSibling = ($restoreInfo.IsSafe -and (Test-Path -LiteralPath $livePath -PathType Leaf))
            }
        }
    }

    return , @($results | Sort-Object UserName, RetiredOn)
}

function Remove-FSLogixRetiredContainer {
    <#
    .SYNOPSIS
        Delete retired containers, subject to a retention floor and a last-copy guard.
    .DESCRIPTION
        The only function in the module that deletes anything, and the guards are not
        optional by accident:
          - RetentionFloorDays is a hard floor. Asking for a shorter age is refused.
          - A retired container with no live sibling is the user's only profile; removing
            it needs -AllowLastCopy stated explicitly.
          - Containers whose retirement date is only approximate (legacy '-old' with no
            stamp) need -IncludeUndated.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)][PSCustomObject[]]$Container,
        [ValidateRange(90, 2147483647)][int]$RetentionFloorDays = 90,
        [switch]$AllowLastCopy,
        [switch]$IncludeUndated,
        [string]$Reason
    )

    $mode   = if ($WhatIfPreference) { 'WHATIF' } else { 'LIVE' }
    $result = [PSCustomObject]@{
        Mode = $mode; Planned = @($Container).Count; Removed = 0; ReclaimedGB = 0.0
        SkippedTooNew = 0; SkippedLastCopy = 0; SkippedUndated = 0; Failed = 0; Errors = @()
    }

    foreach ($item in @($Container)) {
        # A report can be stale or supplied by a caller. Re-read all deletion guards
        # from the file and its retirement suffix immediately before acting.
        try {
            $file = Get-Item -LiteralPath $item.Path -ErrorAction Stop
            $retired = Test-FSLogixRetiredName -FileName $file.Name
            if ($file.PSIsContainer -or $script:ContainerExtensions -notcontains $file.Extension.ToLowerInvariant() -or -not $retired) { throw 'Refusing to purge a file that is not a retired VHD/VHDX container.' }
            $root = if ($item.Root) { $item.Root } else { $file.DirectoryName }
            $restoreInfo = Get-FSLogixRestoreInfo -File $file -Root $root
            $retiredOn = if ($retired.RetiredOn) { $retired.RetiredOn } else { $file.LastWriteTime }
            $item = [PSCustomObject]@{
                Path = $file.FullName; SizeGB = [Math]::Round($file.Length / 1GB, 3)
                AgeDays = [int][Math]::Floor(((Get-Date) - $retiredOn).TotalDays)
                DateSource = $(if ($retired.RetiredOn) { 'stamp' } else { 'mtime-approx' })
                HasLiveSibling = ($restoreInfo.IsSafe -and (Test-Path -LiteralPath $restoreInfo.LivePath -PathType Leaf))
                UserName = $item.UserName; Sid = $item.Sid
            }
        } catch {
            $result.Failed++
            $result.Errors += $_.Exception.Message
            continue
        }
        if ($item.AgeDays -lt $RetentionFloorDays) {
            $result.SkippedTooNew++
            Write-FSLogixLog "Retention floor ($RetentionFloorDays d): keeping $($item.Path) (age $($item.AgeDays) d)." 'WARN'
            continue
        }
        if ($item.DateSource -ne 'stamp' -and -not $IncludeUndated) {
            $result.SkippedUndated++
            Write-FSLogixLog "Retirement date unknown for $($item.Path); use -IncludeUndated to purge legacy '-old' files." 'WARN'
            continue
        }
        if (-not $item.HasLiveSibling -and -not $AllowLastCopy) {
            $result.SkippedLastCopy++
            Write-FSLogixLog "LAST COPY: $($item.Path) has no live container for '$($item.UserName)'. Not deleted." 'ERROR'
            continue
        }

        if ($PSCmdlet.ShouldProcess($item.Path, "Delete retired container ($($item.SizeGB) GB, age $($item.AgeDays) d)")) {
            try {
                Write-FSLogixAudit -Critical -Record @{
                    Action = 'PURGE'; Mode = $mode; Reason = $Reason
                    TargetUser = $item.UserName; TargetSid = $item.Sid
                    SourcePath = $item.Path; SizeGB = $item.SizeGB; Result = 'STARTED'
                }
                Remove-Item -LiteralPath $item.Path -Force -ErrorAction Stop
                $result.Removed++
                $result.ReclaimedGB = [Math]::Round($result.ReclaimedGB + $item.SizeGB, 3)
                Write-FSLogixLog "Purged $($item.Path) ($($item.SizeGB) GB)." 'INFO'
                Write-FSLogixAudit -Critical -Record @{
                    Action = 'PURGE'; Mode = $mode; Reason = $Reason
                    TargetUser = $item.UserName; TargetSid = $item.Sid
                    SourcePath = $item.Path; SizeGB = $item.SizeGB; Result = 'OK'
                }
            } catch {
                $result.Failed++
                $result.Errors += "$($item.Path): $($_.Exception.Message)"
                Write-FSLogixLog "ERROR purging $($item.Path): $($_.Exception.Message)" 'ERROR'
            }
        } elseif ($WhatIfPreference) {
            Write-FSLogixLog "WHATIF: would purge $($item.Path) ($($item.SizeGB) GB)." 'INFO'
        }
    }

    return $result
}

# Feature data helpers share this module's state and stay independent of WinForms.
foreach ($featureSource in @('Environments.ps1', 'AuditHistory.ps1', 'ProfileDetails.ps1')) {
    $featurePath = Join-Path (Join-Path $PSScriptRoot 'Private') $featureSource
    if (-not (Test-Path -LiteralPath $featurePath -PathType Leaf)) { throw "Required core feature file is missing: $featurePath. Copy the Private directory with the scripts." }
    . $featurePath
}

Export-ModuleMember -Function @(
    'Set-FSLogixLogHandler'
    'Write-FSLogixLog'
    'Set-FSLogixNamePrefix'
    'Get-FSLogixContainerClass'
    'Test-FSLogixRetiredName'
    'Test-FSLogixSupersededName'
    'New-FSLogixBatchStamp'
    'Get-FSLogixRetireTargetName'
    'Resolve-FSLogixIdentity'
    'Test-FSLogixFileInUse'
    'Get-FSLogixOpenHandle'
    'Get-FSLogixContainerState'
    'Test-FSLogixVhdSignature'
    'Get-FSLogixVhdMaxSizeGB'
    'Get-FSLogixSettings'
    'Get-FSLogixContainerHealth'
    'Initialize-FSLogixADCheck'
    'Clear-FSLogixADCache'
    'Get-FSLogixADStatus'
    'Get-FSLogixLdapEscapedValue'
    'Set-FSLogixAuditRoot'
    'Get-FSLogixAuditRoot'
    'Get-FSLogixAuditConfiguration'
    'Reset-FSLogixAuditRoot'
    'Write-FSLogixAudit'
    'Connect-FSLogixHorizon'
    'Disconnect-FSLogixHorizon'
    'Test-FSLogixHorizonConnected'
    'Get-FSLogixHorizonServer'
    'Get-FSLogixHorizonSession'
    'Stop-FSLogixHorizonSession'
    'Get-FSLogixProfiles'
    'Select-FSLogixProfile'
    'Get-FSLogixRetirePlan'
    'Rename-FSLogixProfileObject'
    'Restore-FSLogixProfileBatch'
    'Get-FSLogixRetiredContainer'
    'Remove-FSLogixRetiredContainer'
    'Get-FSLogixEnvironmentStorePath'
    'ConvertTo-FSLogixEnvironmentSettings'
    'Get-FSLogixEnvironmentStore'
    'Save-FSLogixEnvironment'
    'Remove-FSLogixEnvironment'
    'Set-FSLogixActiveEnvironment'
    'Get-FSLogixAuditHistory'
    'Get-FSLogixProfileDetails'
)
