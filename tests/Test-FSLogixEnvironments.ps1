#Requires -Version 5.1
$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixProfileCore.psm1') -Force
$script:Checks=0
function Check($Name,$Actual,$Expected){if("$Actual" -ne "$Expected"){throw "$Name : got '$Actual' expected '$Expected'"};$script:Checks++;Write-Host "  ok $Name"}
function Refuses($Name,[scriptblock]$Action){$caught=$false;try{& $Action | Out-Null}catch{$caught=$true};Check $Name $caught $true}
$fixture=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot ('.env-fixture_'+[guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($fixture)
$path=Join-Path $fixture 'settings\environments.json'
$settings=@{
    ProfileRoots=@('\\server\Profiles [lab]','D:\Profiles');AuditRoot='\\server\Audit';AuditRootIsExplicit=$true
    HorizonServer='connection.example.test:443';Theme='Dark';UserFilter='name[1]';AgeEnabled=$true;AgeDays=75
    ADAgeEnabled=$true;ADAgeDays=99;OnlyIssues=$true;CheckAD=$true;HighlightEnabled=$false;HighlightGB=150
    Columns=@(0..9 | ForEach-Object {[pscustomobject]@{Index=$_;DisplayIndex=(9-$_);Width=(100+$_)}})
    SortColumn=5;SortAscending=$false
}
try{
    $store=Get-FSLogixEnvironmentStore -Path $path
    Check 'missing store has schema1' $store.SchemaVersion 1
    Check 'missing store has zero environments' $store.Environments.Count 0
    Check 'read creates no settings file' (Test-Path -LiteralPath $path) $false
    $store=Save-FSLogixEnvironment -Name 'Production' -Settings $settings -Path $path
    Check 'save creates actual file' (Test-Path -LiteralPath $path) $true
    Check 'save makes environment active' $store.ActiveEnvironment 'Production'
    $store=Get-FSLogixEnvironmentStore -Path $path
    Check 'one environment remains an array' ($store.Environments -is [array]) $true
    Check 'root array round trips' $store.Environments[0].Settings.ProfileRoots.Count 2
    Check 'literal path round trips' $store.Environments[0].Settings.ProfileRoots[0] '\\server\Profiles [lab]'
    Check 'explicit audit state round trips' $store.Environments[0].Settings.AuditRootIsExplicit $true
    Check 'Horizon hint round trips' $store.Environments[0].Settings.HorizonServer 'connection.example.test:443'
    Check 'filter brackets remain literal' $store.Environments[0].Settings.UserFilter 'name[1]'
    Check 'theme round trips' $store.Environments[0].Settings.Theme Dark
    Check 'column order round trips' $store.Environments[0].Settings.Columns[0].DisplayIndex 9
    Check 'column width round trips' $store.Environments[0].Settings.Columns[9].Width 109
    Check 'sort direction round trips' $store.Environments[0].Settings.SortAscending $false
    $settings.UserFilter='updated'
    $store=Save-FSLogixEnvironment -Name 'production' -Settings $settings -Path $path
    Check 'case-insensitive update does not duplicate' $store.Environments.Count 1
    Check 'update replaces settings' $store.Environments[0].Settings.UserFilter updated
    $store=Save-FSLogixEnvironment -Name 'Lab' -Settings @{ProfileRoots=@('D:\Lab')} -Path $path
    Check 'multiple environments preserved' $store.Environments.Count 2
    Check 'defaults supplied for sparse settings' ($store.Environments | Where-Object Name -eq Lab).Settings.AgeDays 30
    Check 'empty column array preserved' ($store.Environments | Where-Object Name -eq Lab).Settings.Columns.Count 0
    $store=Set-FSLogixActiveEnvironment -Name production -Path $path
    Check 'active environment changes' $store.ActiveEnvironment production
    $before=[IO.File]::ReadAllText($path)
    Refuses 'nonexistent active selection refused' {Set-FSLogixActiveEnvironment -Name Missing -Path $path}
    Check 'invalid selection preserves exact store' ([IO.File]::ReadAllText($path)) $before
    Refuses 'missing delete refused' {Remove-FSLogixEnvironment -Name Missing -Path $path}
    Refuses 'blank name refused' {Save-FSLogixEnvironment -Name ' ' -Settings $settings -Path $path}
    Refuses 'control-character name refused' {Save-FSLogixEnvironment -Name "bad`nname" -Settings $settings -Path $path}
    Refuses 'relative store path refused' {Get-FSLogixEnvironmentStore -Path 'relative.json'}
    Refuses 'drive-relative store path refused' {Get-FSLogixEnvironmentStore -Path 'D:relative.json'}
    Refuses 'relative root refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('relative')} -Path $path}
    Refuses 'drive-relative root refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('D:relative')} -Path $path}
    Refuses 'empty roots refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@()} -Path $path}
    Refuses 'semicolon root refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('D:\a;D:\b')} -Path $path}
    Refuses 'string Boolean refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('D:\a');CheckAD='false'} -Path $path}
    Refuses 'unknown theme refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('D:\a');Theme='Other'} -Path $path}
    Refuses 'out-of-range age refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('D:\a');AgeDays=0} -Path $path}
    Refuses 'unknown live setting refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('D:\a');WhatIf=$false} -Path $path}
    Refuses 'credential field refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('D:\a');Password='secret'} -Path $path}
    Refuses 'credential in Horizon hint refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('D:\a');HorizonServer='https://user:pass@example.test'} -Path $path}
    Refuses 'blank explicit audit root refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('D:\a');AuditRootIsExplicit=$true} -Path $path}
    Refuses 'audit root control character refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('D:\a');AuditRoot="D:\au`ndit"} -Path $path}
    $badColumns=@(0..9 | ForEach-Object {[pscustomobject]@{Index=$_;DisplayIndex=0;Width=100}})
    Refuses 'duplicate display order refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('D:\a');Columns=$badColumns} -Path $path}
    Refuses 'partial column layout refused' {Save-FSLogixEnvironment -Name bad -Settings @{ProfileRoots=@('D:\a');Columns=@($badColumns[0])} -Path $path}
    Check 'all validation failures preserve exact file' ([IO.File]::ReadAllText($path)) $before
    $store=Remove-FSLogixEnvironment -Name production -Path $path
    Check 'remove active environment clears selection' $store.ActiveEnvironment ''
    Check 'delete preserves another environment' $store.Environments[0].Name Lab
    $store=Remove-FSLogixEnvironment -Name Lab -Path $path
    Check 'delete final environment yields empty array' $store.Environments.Count 0
    Check 'empty saved store loads' (Get-FSLogixEnvironmentStore -Path $path).Environments.Count 0
    # A valid compact store near the limit can grow during normalization. Refuse
    # before creating/replacing anything, keeping the previous file readable.
    $limitPath=Join-Path $fixture 'limit.json'
    $largeFilter='x'*32768
    $limitStore=[pscustomobject]@{SchemaVersion=1;ActiveEnvironment='';Environments=@(1..125 | ForEach-Object {
        [pscustomobject]@{Name=('Environment'+$_);Settings=@{ProfileRoots=@('D:\Profiles');UserFilter=$largeFilter}}
    })}
    $limitJson=$limitStore | ConvertTo-Json -Depth 6 -Compress
    [IO.File]::WriteAllText($limitPath,$limitJson,(New-Object Text.UTF8Encoding($true)))
    Check 'near-limit fixture is within reader bound' ((Get-Item -LiteralPath $limitPath).Length -lt 4MB) $true
    Check 'near-limit fixture is readable' (Get-FSLogixEnvironmentStore -Path $limitPath).Environments.Count 125
    $sizeRefused=$false
    try{Save-FSLogixEnvironment -Name 'One more' -Settings @{ProfileRoots=@('D:\More')} -Path $limitPath | Out-Null}catch{$sizeRefused=$_.Exception.Message -match '4 MB size limit'}
    Check 'oversized update refused before replace' $sizeRefused $true
    Check 'oversized update preserves exact prior file' ([IO.File]::ReadAllText($limitPath) -ceq $limitJson) $true
    Check 'prior environment store remains readable' (Get-FSLogixEnvironmentStore -Path $limitPath).Environments.Count 125
    Check 'oversized update leaves no temporary file' (@(Get-ChildItem -LiteralPath $fixture -Filter 'limit.json.*' | Where-Object Name -ne 'limit.json').Count) 0
    $deniedPath=Join-Path $fixture 'unreadable.json'
    [void](Save-FSLogixEnvironment -Name Protected -Settings @{ProfileRoots=@('D:\Protected')} -Path $deniedPath)
    $protectedText=[IO.File]::ReadAllText($deniedPath)
    $originalAcl=Get-Acl -LiteralPath $deniedPath
    $deniedAcl=Get-Acl -LiteralPath $deniedPath
    $operatorSid=[Security.Principal.WindowsIdentity]::GetCurrent().User
    $denyRights=[Security.AccessControl.FileSystemRights]::ReadData -bor [Security.AccessControl.FileSystemRights]::ReadAttributes
    $denyRead=New-Object Security.AccessControl.FileSystemAccessRule($operatorSid,$denyRights,[Security.AccessControl.AccessControlType]::Deny)
    [void]$deniedAcl.AddAccessRule($denyRead)
    try{
        Set-Acl -LiteralPath $deniedPath -AclObject $deniedAcl
        $readRefused=$false
        try{Get-FSLogixEnvironmentStore -Path $deniedPath | Out-Null}catch{$readRefused=$_.Exception.Message -match 'Cannot read environment store'}
        Check 'inaccessible store is an explicit read error' $readRefused $true
        Refuses 'inaccessible store cannot be replaced by save' {Save-FSLogixEnvironment -Name Bad -Settings @{ProfileRoots=@('D:\Bad')} -Path $deniedPath}
    }finally{Set-Acl -LiteralPath $deniedPath -AclObject $originalAcl}
    Check 'inaccessible store remains unchanged after access returns' ([IO.File]::ReadAllText($deniedPath) -ceq $protectedText) $true
    [IO.File]::WriteAllText($path,'{invalid json')
    Refuses 'malformed store read refused' {Get-FSLogixEnvironmentStore -Path $path}
    Refuses 'malformed store cannot be overwritten by save' {Save-FSLogixEnvironment -Name Lab -Settings $settings -Path $path}
    Check 'corrupt store preserved for recovery' ([IO.File]::ReadAllText($path)) '{invalid json'
    [IO.File]::WriteAllText($path,'{"SchemaVersion":99,"ActiveEnvironment":"","Environments":[]}')
    Refuses 'newer schema refused' {Get-FSLogixEnvironmentStore -Path $path}
    [IO.File]::WriteAllText($path,'{"SchemaVersion":1,"ActiveEnvironment":"Missing","Environments":[]}')
    Refuses 'dangling active name refused' {Get-FSLogixEnvironmentStore -Path $path}
    [IO.File]::WriteAllText($path,'{"SchemaVersion":1,"ActiveEnvironment":"","Environments":[],"Token":"secret"}')
    Refuses 'unknown root fields refused' {Get-FSLogixEnvironmentStore -Path $path}
    Refuses 'directory cannot be used as a store file' {Get-FSLogixEnvironmentStore -Path $fixture}
    [IO.File]::Delete($path)

    # Real concurrent processes exercise the read/modify/write mutex and atomic replacement.
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $modulePath=Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixProfileCore.psm1'
    $processes=@()
    foreach($name in @('ConcurrentA','ConcurrentB')){
        $command="Import-Module '"+$modulePath.Replace("'","''")+"' -Force; Save-FSLogixEnvironment -Name '"+$name+"' -Settings @{ProfileRoots=@('D:\Concurrent')} -Path '"+$path.Replace("'","''")+"' | Out-Null"
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$shell;$start.Arguments='-NoProfile -NonInteractive -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
        $process=New-Object Diagnostics.Process;$process.StartInfo=$start;[void]$process.Start();$processes+=$process
    }
    foreach($process in $processes){try{if(-not $process.WaitForExit(30000)){$process.Kill();throw 'Concurrent writer timed out.'};Check 'concurrent writer succeeds' $process.ExitCode 0}finally{$process.Dispose()}}
    $store=Get-FSLogixEnvironmentStore -Path $path
    Check 'concurrent updates preserve both environments' $store.Environments.Count 2
    Check 'atomic writer leaves no temporary file' (@(Get-ChildItem -LiteralPath (Split-Path -Parent $path) -Filter '*.tmp').Count) 0
    Check 'default store path targets current user' ((Get-FSLogixEnvironmentStorePath).StartsWith($env:LOCALAPPDATA,[StringComparison]::OrdinalIgnoreCase)) $true
    Write-Host "ALL $script:Checks ENVIRONMENT CHECKS PASSED"
}finally{
    $workspacePrefix=[IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'
    if($fixture.StartsWith($workspacePrefix) -and (Split-Path -Leaf $fixture) -like '.env-fixture_*'){Remove-Item -LiteralPath $fixture -Recurse -Force}
}
