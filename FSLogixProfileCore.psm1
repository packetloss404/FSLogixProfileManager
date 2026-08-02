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
        try { & $script:LogHandler $Message $Level } catch { }
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
        [Parameter(Mandatory = $true)][string]$BatchStamp
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
        $tail   = '*\{0}\{1}' -f $parent, $leaf
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
        [void]$mutex.WaitOne(10000)
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

    if ($SkipCertificateCheck) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }

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

    $response = Invoke-RestMethod -Method Post -Uri "https://$Server/rest/login" -Body $body -ContentType 'application/json' -ErrorAction Stop

    $script:HorizonConnection = [PSCustomObject]@{
        Server  = $Server
        Headers = @{ Authorization = "Bearer $($response.access_token)" }
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
        $sessions = Invoke-RestMethod -Method Get `
            -Uri "https://$($script:HorizonConnection.Server)/rest/inventory/v1/sessions" `
            -Headers $script:HorizonConnection.Headers -ErrorAction Stop
        return , @($sessions | Where-Object { $_.user_name -match ('\\' + [regex]::Escape($UserName) + '$') })
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
        Invoke-RestMethod -Method Post `
            -Uri "https://$($script:HorizonConnection.Server)/rest/inventory/v1/sessions/$SessionId/logoff" `
            -Headers $script:HorizonConnection.Headers -ErrorAction Stop
        Write-FSLogixLog "Logged off Horizon session $SessionId." 'INFO'
    }
}

# --------------------------------------------------------------------
#  Discovery
# --------------------------------------------------------------------

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

        if (-not (Test-Path -LiteralPath $root)) {
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
            Write-FSLogixLog "$($rootErrors.Count) path(s) under $root could not be read (access denied or path too long) - results for this root are INCOMPLETE." 'ERROR'
        }
        Write-FSLogixLog "Found $($files.Count) container file(s) under $root." 'INFO'

        foreach ($file in $files) {
            $fileCount++
            if ($ProgressEvery -gt 0 -and ($fileCount % $ProgressEvery) -eq 0) {
                Write-FSLogixLog "Processed $fileCount container(s)..." 'PROGRESS'
            }

            $folderLeaf = Split-Path $file.DirectoryName -Leaf
            $identity   = Resolve-FSLogixIdentity -FolderLeaf $folderLeaf -FileName $file.Name

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
                continue
            }

            $container.Issues = @(Get-FSLogixContainerHealth -Path $file.FullName -SizeGB $sizeGB -MaxSizeGB $maxSize -Signature $signature)
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
            if ($file.LastWriteTime -gt $entry.LastWriteTime) { $entry.LastWriteTime = $file.LastWriteTime }
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
        [string]$BatchStamp,
        [switch]$CheckInUse,
        [switch]$MoveToRetired
    )

    if (-not $BatchStamp) { $BatchStamp = New-FSLogixBatchStamp }

    $targets = switch ($Scope) {
        'Office'  { @($ProfileObject.Containers | Where-Object { $_.Class -eq 'Office' }) }
        'Profile' { @($ProfileObject.Containers | Where-Object { $_.Class -eq 'Profile' }) }
        default   { @($ProfileObject.Containers) }
    }

    $handles = $null
    if ($CheckInUse -and $targets.Count -gt 0) {
        $handles = Get-FSLogixOpenHandle -Path @($targets.Path)
    }

    $safeUser = ($ProfileObject.UserName -replace ('[' + [regex]::Escape(-join [System.IO.Path]::GetInvalidFileNameChars()) + ']'), '_')

    $plan = @()
    foreach ($container in $targets) {
        $newName = Get-FSLogixRetireTargetName -FileName $container.Name -BatchStamp $BatchStamp
        if ($MoveToRetired) {
            # Lift the retired file out of the user's writable directory into
            # <root>\_retired\<user>\<batch-stamp>\ so it stops counting against
            # the user's FSRM quota and falls outside the user's ACL scope.
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
        [string]$BatchStamp,
        [switch]$AllOrNothing,
        [switch]$Force,
        [switch]$RequireHorizonCheck,
        [switch]$MoveToRetired
    )

    if (-not $BatchStamp) { $BatchStamp = New-FSLogixBatchStamp }

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
            $sessions = @(Get-FSLogixHorizonSession -UserName $user)
            if ($sessions.Count -gt 0) {
                $states = ($sessions | ForEach-Object { $_.session_state }) -join ', '
                $result.Aborted     = $true
                $result.AbortReason = "'$user' has $($sessions.Count) Horizon session(s) [$states]. Log the user off and let the clone refresh before retiring."
                & $log $result.AbortReason 'ERROR'
                return $result
            }
        }

        $plan = @(Get-FSLogixRetirePlan -ProfileObject $ProfileObject -Scope $Scope -BatchStamp $BatchStamp -CheckInUse:$CheckInUse -MoveToRetired:$MoveToRetired)
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
            switch ($item.State) {
                'Missing'      { $result.Missing++;       & $log "Missing (skip): $($item.SourcePath)" 'WARN'; continue }
                'Exists'       { $result.SkippedExists++; & $log "Retire target exists (skip): $($item.DestPath)" 'WARN'; continue }
                'InUse'        { $result.SkippedInUse++;  & $log ("IN USE (skip): {0}{1}" -f $item.SourcePath, $(if ($item.Holder) { " [held by $($item.Holder)]" } else { '' })) 'WARN'; continue }
                'AccessDenied' { $result.Failed++;        & $log "Access denied (skip): $($item.SourcePath)" 'ERROR'; $result.Errors += "Access denied: $($item.SourcePath)"; continue }
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
                if ($MoveToRetired) {
                    # Move across directories - the dest lives under
                    # <root>\_retired\<user>\<batch-stamp>\. Create the
                    # directory first; the share is expected to ACL it
                    # operators-only.
                    $destDir = Split-Path -Parent $item.DestPath
                    if (-not (Test-Path -LiteralPath $destDir)) {
                        [void](New-Item -Path $destDir -ItemType Directory -Force -ErrorAction Stop)
                    }
                    Move-Item -LiteralPath $item.SourcePath -Destination $item.DestPath -Force -ErrorAction Stop
                } else {
                    Rename-Item -LiteralPath $item.SourcePath -NewName $item.DestName -ErrorAction Stop
                }
                $result.Renamed++
                $completed += $item
                $result.Actions += $item
                & $log (if ($MoveToRetired) { "Moved {0} -> {1}" } else { "Renamed {0} -> {1}" } -f $item.SourcePath, $item.DestPath) 'INFO'
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

                if ($AllOrNothing) {
                    & $log "All-or-nothing: rolling back $($completed.Count) rename(s) for '$user'." 'ERROR'
                    foreach ($done in ($completed | Sort-Object -Property SourcePath -Descending)) {
                        try {
                            if ($MoveToRetired) {
                                Move-Item -LiteralPath $done.DestPath -Destination $done.SourcePath -Force -ErrorAction Stop
                            } else {
                                Rename-Item -LiteralPath $done.DestPath -NewName (Split-Path -Leaf $done.SourcePath) -ErrorAction Stop
                            }
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
                    $result.Renamed     = 0
                    $result.Aborted     = $true
                    $result.AbortReason = 'Rename failed part-way; the batch was rolled back.'
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

    # Phase 1: validate everything before touching anything.
    $plan = @()
    foreach ($item in @($Container)) {
        $retired = Test-FSLogixRetiredName -FileName $item.Name
        if (-not $retired) {
            $result.Aborted     = $true
            $result.AbortReason = "'$($item.Name)' is not a retired container."
            return $result
        }

        $livePath = Join-Path $item.Directory $retired.LiveName

        if (-not (Test-Path -LiteralPath $item.Path)) {
            $result.Aborted     = $true
            $result.AbortReason = "Retired container has gone: $($item.Path)"
            return $result
        }

        if (-not $SkipSignatureCheck) {
            $signature = Test-FSLogixVhdSignature -Path $item.Path
            if ($signature -eq 'Invalid') {
                $result.Aborted     = $true
                $result.AbortReason = "$($item.Name) fails its VHD signature check; refusing to restore it."
                return $result
            }
        }

        $displaceTo = $null
        if (Test-Path -LiteralPath $livePath) {
            if ($CheckInUse) {
                $state = (Get-FSLogixContainerState -Path $livePath -OpenHandles (Get-FSLogixOpenHandle -Path @($livePath))).State
                if ($state -eq 'InUse') {
                    $result.Aborted     = $true
                    $result.AbortReason = "The current container $livePath is mounted. Log the user off first."
                    return $result
                }
            }
            $base = [System.IO.Path]::GetFileNameWithoutExtension($retired.LiveName)
            $ext  = [System.IO.Path]::GetExtension($retired.LiveName)
            $displaceTo = Join-Path $item.Directory ('{0}-superseded-{1}{2}' -f $base, (New-FSLogixBatchStamp), $ext)
        }

        $plan += [PSCustomObject]@{
            RetiredPath = $item.Path
            LivePath    = $livePath
            LiveName    = $retired.LiveName
            DisplaceTo  = $displaceTo
            SizeGB      = $item.SizeGB
        }
    }

    # Phase 2: execute. Two renames per file, zero deletions.
    foreach ($step in $plan) {
        try {
            if ($step.DisplaceTo) {
                if ($PSCmdlet.ShouldProcess($step.LivePath, "Displace to $(Split-Path -Leaf $step.DisplaceTo)")) {
                    Rename-Item -LiteralPath $step.LivePath -NewName (Split-Path -Leaf $step.DisplaceTo) -ErrorAction Stop
                    $result.Displaced++
                    Write-FSLogixLog "Displaced current container $($step.LivePath) -> $($step.DisplaceTo)" 'WARN'
                    Write-FSLogixAudit -Critical -Record @{
                        Action = 'RESTORE-DISPLACE'; Mode = $mode; Reason = $Reason
                        TargetUser = $UserName; TargetSid = $Sid
                        SourcePath = $step.LivePath; DestPath = $step.DisplaceTo; Result = 'OK'
                    }
                }
            }

            if ($PSCmdlet.ShouldProcess($step.RetiredPath, "Restore to $($step.LiveName)")) {
                Rename-Item -LiteralPath $step.RetiredPath -NewName $step.LiveName -ErrorAction Stop
                $result.Restored++
                Write-FSLogixLog "Restored $($step.RetiredPath) -> $($step.LivePath)" 'INFO'
                Write-FSLogixAudit -Critical -Record @{
                    Action = 'RESTORE'; Mode = $mode; Reason = $Reason
                    TargetUser = $UserName; TargetSid = $Sid
                    SourcePath = $step.RetiredPath; DestPath = $step.LivePath
                    SizeGB = $step.SizeGB; Result = 'OK'
                }
            } elseif ($isSim) {
                Write-FSLogixLog "WHATIF: would restore $($step.RetiredPath) -> $($step.LivePath)" 'INFO'
            }
        } catch {
            $result.Failed++
            $result.Errors += "$($step.RetiredPath): $($_.Exception.Message)"
            Write-FSLogixLog "ERROR restoring $($step.RetiredPath): $($_.Exception.Message)" 'ERROR'
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
        [int]$OlderThanDays = 0
    )

    $now     = Get-Date
    $results = @()

    foreach ($root in $ProfileRoots) {
        $root = "$root".Trim()
        if ([string]::IsNullOrWhiteSpace($root) -or -not (Test-Path -LiteralPath $root)) { continue }

        $files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.vhd* -ErrorAction SilentlyContinue |
                   Where-Object { $script:ContainerExtensions -contains $_.Extension.ToLowerInvariant() })

        foreach ($file in $files) {
            $retired = Test-FSLogixRetiredName -FileName $file.Name
            if (-not $retired) { continue }

            $retiredOn  = if ($retired.RetiredOn) { $retired.RetiredOn } else { $file.LastWriteTime }
            $dateSource = if ($retired.RetiredOn) { 'stamp' } else { 'mtime-approx' }
            $ageDays    = [int]($now - $retiredOn).TotalDays
            if ($OlderThanDays -gt 0 -and $ageDays -lt $OlderThanDays) { continue }

            $identity = Resolve-FSLogixIdentity -FolderLeaf (Split-Path $file.DirectoryName -Leaf) -FileName $file.Name
            $livePath = Join-Path $file.DirectoryName $retired.LiveName

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
                HasLiveSibling = (Test-Path -LiteralPath $livePath)
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
        [int]$RetentionFloorDays = 90,
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
    'Write-FSLogixAudit'
    'Connect-FSLogixHorizon'
    'Disconnect-FSLogixHorizon'
    'Test-FSLogixHorizonConnected'
    'Get-FSLogixHorizonSession'
    'Stop-FSLogixHorizonSession'
    'Get-FSLogixProfiles'
    'Select-FSLogixProfile'
    'Get-FSLogixRetirePlan'
    'Rename-FSLogixProfileObject'
    'Restore-FSLogixProfileBatch'
    'Get-FSLogixRetiredContainer'
    'Remove-FSLogixRetiredContainer'
)
