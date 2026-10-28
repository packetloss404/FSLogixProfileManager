# Named operator preferences. This file is dot-sourced by the core module.
function Test-FSLogixEnvironmentAbsolutePath {
    param([string]$Path)
    return ($Path -match '^[A-Za-z]:[\\/]' -or $Path -match '^\\\\[^\\/]+[\\/][^\\/]+(?:[\\/]|$)')
}

function Get-FSLogixEnvironmentStorePath {
    [CmdletBinding()]
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'LOCALAPPDATA is not available. Specify an environment store path.' }
        $Path = Join-Path $env:LOCALAPPDATA 'FSLogixProfileManager\environments.json'
    }
    if (-not (Test-FSLogixEnvironmentAbsolutePath $Path)) { throw 'Environment store path must be absolute.' }
    return [IO.Path]::GetFullPath($Path)
}

function Get-FSLogixEnvironmentProperty {
    param($Object, [string]$Name, $Default)
    if ($Object -is [Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return ,$Object[$Name] }
    } elseif ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return ,$Object.$Name }
    return ,$Default
}

function Test-FSLogixEnvironmentKeys {
    param($Object, [string[]]$Allowed)
    if ($Object -is [Collections.IDictionary]) { $keys = @($Object.Keys) }
    elseif ($null -ne $Object -and $Object -is [pscustomobject]) { $keys = @($Object.PSObject.Properties.Name) }
    else { throw 'Expected an environment settings object.' }
    foreach ($key in $keys) { if ($Allowed -notcontains "$key") { throw "Unsupported environment field: $key" } }
}

function ConvertTo-FSLogixEnvironmentSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)]$Settings)
    $defaults = [ordered]@{
        ProfileRoots=@(); AuditRoot=''; AuditRootIsExplicit=$false; HorizonServer=''; Theme='Light'
        UserFilter=''; AgeEnabled=$false; AgeDays=30; ADAgeEnabled=$false; ADAgeDays=90
        OnlyIssues=$false; CheckAD=$false; HighlightEnabled=$true; HighlightGB=20
        Columns=@(); SortColumn=-1; SortAscending=$true
    }
    Test-FSLogixEnvironmentKeys $Settings @($defaults.Keys)
    $result = [ordered]@{}
    foreach ($key in $defaults.Keys) { $result[$key] = Get-FSLogixEnvironmentProperty $Settings $key $defaults[$key] }
    $roots = @($result.ProfileRoots)
    if ($roots.Count -eq 0) { throw 'An environment must contain at least one profile root.' }
    $cleanRoots = @()
    foreach ($root in $roots) {
        if ($root -isnot [string] -or [string]::IsNullOrWhiteSpace($root) -or -not (Test-FSLogixEnvironmentAbsolutePath $root)) { throw 'Profile roots must be nonblank absolute paths.' }
        $root = $root.Trim()
        if ($root -match '[\x00-\x1f;]') { throw 'Profile roots cannot contain control characters or semicolons.' }
        if ($cleanRoots -notcontains $root) { $cleanRoots += $root }
    }
    $result.ProfileRoots = @($cleanRoots)
    foreach ($key in @('AuditRoot','HorizonServer','Theme','UserFilter')) {
        if ($result[$key] -isnot [string] -or $result[$key].Length -gt 32768) { throw "Invalid text setting: $key" }
    }
    $result.AuditRoot = $result.AuditRoot.Trim()
    if ($result.AuditRoot -match '[\x00-\x1f]') { throw 'Audit root cannot contain control characters.' }
    if ($result.AuditRoot -and -not (Test-FSLogixEnvironmentAbsolutePath $result.AuditRoot)) { throw 'Audit root must be an absolute path.' }
    $result.HorizonServer = $result.HorizonServer.Trim()
    if ($result.HorizonServer -and $result.HorizonServer -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-]*(?::[0-9]{1,5})?$') { throw 'Horizon server must be a host name with an optional port, without credentials or a URL path.' }
    if ($result.Theme -notin @('Light','Dark')) { throw 'Theme must be Light or Dark.' }
    foreach ($key in @('AuditRootIsExplicit','AgeEnabled','ADAgeEnabled','OnlyIssues','CheckAD','HighlightEnabled','SortAscending')) {
        if ($result[$key] -isnot [bool]) { throw "Invalid Boolean setting: $key" }
    }
    if ($result.AuditRootIsExplicit -and -not $result.AuditRoot) { throw 'An explicit audit root cannot be blank.' }
    foreach ($key in @('AgeDays','ADAgeDays','HighlightGB','SortColumn')) {
        if ($result[$key] -isnot [int] -and $result[$key] -isnot [long]) { throw "Invalid integer setting: $key" }
    }
    if ($result.AgeDays -lt 1 -or $result.AgeDays -gt 3650 -or $result.ADAgeDays -lt 1 -or $result.ADAgeDays -gt 3650) { throw 'Age filters must be between 1 and 3650 days.' }
    if ($result.HighlightGB -lt 1 -or $result.HighlightGB -gt 10000) { throw 'Highlight threshold must be between 1 and 10000 GB.' }
    if ($result.SortColumn -lt -1 -or $result.SortColumn -gt 9) { throw 'Sort column must be between -1 and 9.' }
    $columns = @($result.Columns)
    if ($columns.Count -notin @(0,10)) { throw 'Column layout must contain all ten columns or be empty.' }
    $cleanColumns = @()
    foreach ($column in $columns) {
        Test-FSLogixEnvironmentKeys $column @('Index','DisplayIndex','Width')
        foreach ($key in @('Index','DisplayIndex','Width')) {
            $value = Get-FSLogixEnvironmentProperty $column $key $null
            if ($value -isnot [int] -and $value -isnot [long]) { throw "Invalid column value: $key" }
        }
        if ($column.Index -lt 0 -or $column.Index -gt 9 -or $column.DisplayIndex -lt 0 -or $column.DisplayIndex -gt 9 -or $column.Width -lt 20 -or $column.Width -gt 2000) { throw 'Column layout is outside supported bounds.' }
        $cleanColumns += [pscustomobject]@{Index=[int]$column.Index; DisplayIndex=[int]$column.DisplayIndex; Width=[int]$column.Width}
    }
    if ($cleanColumns.Count -and (@($cleanColumns.Index | Select-Object -Unique).Count -ne 10 -or @($cleanColumns.DisplayIndex | Select-Object -Unique).Count -ne 10)) { throw 'Column indices and display positions must be unique.' }
    $result.Columns = @($cleanColumns)
    return [pscustomobject]$result
}

function Get-FSLogixEnvironmentStore {
    [CmdletBinding()]
    param([string]$Path)
    $Path = Get-FSLogixEnvironmentStorePath $Path
    $stream = $null; $reader = $null
    try {
        # File.Exists silently returns false for access-denied paths. Open directly
        # so only genuinely missing files/parents become an empty settings store.
        try {
            $sharing = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
            $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $sharing)
        } catch [IO.FileNotFoundException] {
            return [pscustomobject]@{SchemaVersion=1; ActiveEnvironment=''; Environments=@()}
        } catch [IO.DirectoryNotFoundException] {
            return [pscustomobject]@{SchemaVersion=1; ActiveEnvironment=''; Environments=@()}
        }
        if ($stream.Length -gt 4MB) { throw 'Environment store exceeds the 4 MB size limit.' }
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
        $store = $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Cannot read environment store '$Path': $($_.Exception.Message)"
    } finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
    Test-FSLogixEnvironmentKeys $store @('SchemaVersion','ActiveEnvironment','Environments')
    if ($store.SchemaVersion -ne 1 -or ($store.SchemaVersion -isnot [int] -and $store.SchemaVersion -isnot [long])) { throw 'Unsupported environment store schema version.' }
    if ($store.ActiveEnvironment -isnot [string] -or $null -eq $store.Environments) { throw 'Environment store is missing required fields.' }
    $environments = @()
    foreach ($item in @($store.Environments)) {
        Test-FSLogixEnvironmentKeys $item @('Name','Settings')
        $name = "$($item.Name)".Trim()
        if ($item.Name -isnot [string] -or -not $name -or $name.Length -gt 100 -or $name -match '[\x00-\x1f]') { throw 'Environment names must contain 1-100 printable characters.' }
        if (@($environments | Where-Object Name -eq $name).Count) { throw "Duplicate environment name: $name" }
        $environments += [pscustomobject]@{Name=$name; Settings=(ConvertTo-FSLogixEnvironmentSettings $item.Settings)}
    }
    if ($store.ActiveEnvironment -and @($environments | Where-Object Name -eq $store.ActiveEnvironment).Count -ne 1) { throw 'Active environment does not exist in the store.' }
    return [pscustomobject]@{SchemaVersion=1; ActiveEnvironment=$store.ActiveEnvironment; Environments=@($environments | Sort-Object Name)}
}

function Invoke-FSLogixEnvironmentStoreUpdate {
    param([string]$Path, [scriptblock]$Update)
    $Path = Get-FSLogixEnvironmentStorePath $Path
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant()))).Replace('-','') } finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('Global\FSLogixEnvironments_' + $hash))
    $held = $false; $temporary = $null; $previous = $null
    try {
        try { $held = $mutex.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $held = $true }
        if (-not $held) { throw 'Timed out waiting for the environment settings writer.' }
        $store = Get-FSLogixEnvironmentStore -Path $Path
        & $Update $store
        $json = $store | ConvertTo-Json -Depth 8
        $encoding = New-Object Text.UTF8Encoding($true)
        if (($encoding.GetByteCount($json) + $encoding.GetPreamble().Length) -gt 4MB) {
            throw 'Environment store would exceed the 4 MB size limit. Remove saved environments before adding more.'
        }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
        $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($temporary, $json, $encoding)
        if ([IO.File]::Exists($Path)) {
            # PS5.1 binds a null backup name as an empty string on some hosts.
            $previous = $temporary + '.previous'
            [IO.File]::Replace($temporary, $Path, $previous)
        } else { [IO.File]::Move($temporary, $Path) }
        return $store
    } finally {
        if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        if ($previous -and [IO.File]::Exists($previous)) { [IO.File]::Delete($previous) }
        if ($held) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Save-FSLogixEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Name, [Parameter(Mandatory=$true)]$Settings, [string]$Path)
    $Name = $Name.Trim()
    if (-not $Name -or $Name.Length -gt 100 -or $Name -match '[\x00-\x1f]') { throw 'Environment names must contain 1-100 printable characters.' }
    $normalized = ConvertTo-FSLogixEnvironmentSettings $Settings
    return Invoke-FSLogixEnvironmentStoreUpdate -Path $Path -Update {
        param($store)
        $store.Environments = @($store.Environments | Where-Object Name -ne $Name) + @([pscustomobject]@{Name=$Name;Settings=$normalized})
        $store.Environments = @($store.Environments | Sort-Object Name)
        $store.ActiveEnvironment = $Name
    }
}

function Remove-FSLogixEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$Name, [string]$Path)
    return Invoke-FSLogixEnvironmentStoreUpdate -Path $Path -Update {
        param($store)
        if (@($store.Environments | Where-Object Name -eq $Name).Count -ne 1) { throw "Environment not found: $Name" }
        $store.Environments = @($store.Environments | Where-Object Name -ne $Name)
        if ($store.ActiveEnvironment -eq $Name) { $store.ActiveEnvironment = '' }
    }
}

function Set-FSLogixActiveEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Name, [string]$Path)
    return Invoke-FSLogixEnvironmentStoreUpdate -Path $Path -Update {
        param($store)
        if ($Name -and @($store.Environments | Where-Object Name -eq $Name).Count -ne 1) { throw "Environment not found: $Name" }
        $store.ActiveEnvironment = $Name
    }
}
