<#
Local adapter contract tests, NOT validation against a real Horizon/AD/SMB host.
REST and Get-VHD are stubbed inside the module; file locks and signatures are real.
#>
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixProfileCore.psm1'
Import-Module $modulePath -Force
$module = Get-Module FSLogixProfileCore
$script:checks = 0
function Assert($Name, $Condition) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:checks++
    Write-Host "  ok   $Name"
}
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('fsl_adapters_' + [guid]::NewGuid().ToString('N'))
$previousCallback = [Net.ServicePointManager]::ServerCertificateValidationCallback
try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    Set-FSLogixLogHandler { param($Message, $Level) }
    $vhdx = Join-Path $testRoot 'Profile_alice.vhdx'
    $data = New-Object byte[] 4096
    [Text.Encoding]::ASCII.GetBytes('vhdxfile').CopyTo($data, 0)
    [IO.File]::WriteAllBytes($vhdx, $data)
    Assert 'VHDX signature' ((Test-FSLogixVhdSignature $vhdx) -eq 'Valid')
    $vhd = Join-Path $testRoot 'Profile_alice.vhd'
    $data = New-Object byte[] 4096
    [Text.Encoding]::ASCII.GetBytes('conectix').CopyTo($data, $data.Length - 512)
    [IO.File]::WriteAllBytes($vhd, $data)
    Assert 'VHD footer signature' ((Test-FSLogixVhdSignature $vhd) -eq 'Valid')
    $bad = Join-Path $testRoot 'bad.vhdx'
    [IO.File]::WriteAllBytes($bad, (New-Object byte[] 4096))
    Assert 'invalid signature' ((Test-FSLogixVhdSignature $bad) -eq 'Invalid')
    Assert 'missing signature unknown' ((Test-FSLogixVhdSignature (Join-Path $testRoot 'missing.vhdx')) -eq 'Unknown')
    Assert 'free local file' ((Test-FSLogixFileInUse $vhdx) -eq 'Free')
    $locked = [IO.File]::Open($vhdx, 'Open', 'ReadWrite', 'None')
    try { Assert 'real exclusive lock' ((Test-FSLogixFileInUse $vhdx) -eq 'InUse') } finally { $locked.Dispose() }
    Assert 'missing local file' ((Test-FSLogixFileInUse (Join-Path $testRoot 'missing.vhdx')) -eq 'Missing')
    $handles = @([pscustomobject]@{Path=$vhdx;ClientUserName='LAB\alice';ClientComputer='desktop01'})
    $state = Get-FSLogixContainerState -Path $vhdx -OpenHandles $handles
    Assert 'SMB holder contract' ($state.State -eq 'InUse' -and $state.Holder -eq 'LAB\alice on desktop01')
    Assert 'empty SMB list contract' ((Get-FSLogixContainerState -Path $vhdx -OpenHandles @()).State -eq 'Free')
    Assert 'mixed-server public handle request is unknown' ($null -eq (Get-FSLogixOpenHandle -Path @('\\server-a\profiles\alice.vhdx','\\server-b\profiles\alice.vhdx')))
    Assert 'mismatched explicit server is unknown' ($null -eq (Get-FSLogixOpenHandle -Path '\\server-a\profiles\alice.vhdx' -FileServer 'server-b'))
    Assert 'AD disabled means unknown' ((Get-FSLogixADStatus -UserName alice).Status -eq 'UNKNOWN')
    $caught = $false
    try { [void](Get-FSLogixProfiles -ProfileRoots @($testRoot, (Join-Path $testRoot 'missing-root')) -ErrorOnIncomplete) } catch { $caught = $true }
    Assert 'strict discovery refuses an unavailable provider' $caught
    $caught = $false
    try { [void](Get-FSLogixRetiredContainer -ProfileRoots (Join-Path $testRoot 'missing-root') -ErrorOnIncomplete) } catch { $caught = $true }
    Assert 'strict retired report refuses an unavailable root' $caught
    & $module {
        function script:Get-ChildItem {
            [CmdletBinding()]
            param($LiteralPath, [switch]$Recurse, [switch]$File, $Filter)
            Write-Error 'synthetic access denied during enumeration'
        }
    }
    try {
        $caught = $false
        try { [void](Get-FSLogixProfiles -ProfileRoots $testRoot -ErrorOnIncomplete) } catch { $caught = $true }
        Assert 'strict discovery refuses partial enumeration' $caught
        $caught = $false
        try { [void](Get-FSLogixRetiredContainer -ProfileRoots $testRoot -ErrorOnIncomplete) } catch { $caught = $true }
        Assert 'strict retired report refuses partial enumeration' $caught
    } finally { & $module { Remove-Item Function:Get-ChildItem } }
    Set-FSLogixLogHandler { param($Message, $Level) 'handler return value must not become data' }
    $profiles = Get-FSLogixProfiles -ProfileRoots $testRoot
    Assert 'logging callback results never contaminate collection data' ($profiles -is [array] -and @($profiles | Where-Object {$_.Containers -is [array]}).Count -eq $profiles.Count)
    Set-FSLogixLogHandler { param($Message, $Level) }

    # Test metadata adapter without installing Hyper-V or inventing a size.
    & $module {
        function script:Get-VHD { [CmdletBinding()] param($Path) [pscustomobject]@{Size=40GB} }
        $script:HasGetVhd = $null
    }
    Assert 'Get-VHD size adapter' ((Get-FSLogixVhdMaxSizeGB $vhdx) -eq 40)
    & $module { function script:Get-VHD { [CmdletBinding()] param($Path) throw 'metadata unavailable' } }
    Assert 'Get-VHD error stays unknown' ($null -eq (Get-FSLogixVhdMaxSizeGB $vhdx))
    $issues = Get-FSLogixContainerHealth -Path $vhdx -SizeGB 95 -MaxSizeGB 100
    Assert 'known ceiling near limit' ($issues -contains 'NEAR_LIMIT' -and $issues -notcontains 'OVER_LIMIT')
    $issues = Get-FSLogixContainerHealth -Path $vhdx -SizeGB 105 -MaxSizeGB 100 -Signature Invalid
    Assert 'over limit and bad signature' ($issues -contains 'OVER_LIMIT' -and $issues -contains 'BAD_SIGNATURE')
    $issues = Get-FSLogixContainerHealth -Path $vhdx -SizeGB 105 -MaxSizeGB $null
    Assert 'unknown ceiling has no guessed limit' ($issues -notcontains 'NEAR_LIMIT' -and $issues -notcontains 'OVER_LIMIT')

    & $module {
        $script:RestCalls = New-Object System.Collections.ArrayList
        $script:RestFailure = $false
        $script:LoginToken = 'synthetic-token'
        $script:RestSessions = @(
            [pscustomobject]@{id='one';user_name='LAB\alice';session_state='CONNECTED'},
            [pscustomobject]@{id='two';user_name='LAB\bob';session_state='DISCONNECTED'}
        )
        function script:Invoke-RestMethod {
            [CmdletBinding()]
            param($Method, $Uri, $Body, $ContentType, $Headers)
            [void]$script:RestCalls.Add([pscustomobject]@{Method=$Method;Uri=$Uri;Body=$Body;Headers=$Headers;Callback=[Net.ServicePointManager]::ServerCertificateValidationCallback})
            if ($script:RestFailure) { throw 'synthetic REST outage' }
            if ($Uri -like '*/rest/login') { return [pscustomobject]@{access_token=$script:LoginToken} }
            if ($Method -eq 'Get') { return ,$script:RestSessions }
        }
    }
    $credential = New-Object pscredential('LAB\operator', (ConvertTo-SecureString 'synthetic-password' -AsPlainText -Force))
    [void](Connect-FSLogixHorizon -Server 'synthetic.invalid' -Credential $credential -SkipCertificateCheck)
    Assert 'Horizon connected after token' (Test-FSLogixHorizonConnected)
    Assert 'Horizon server getter exposes only server name' ((Get-FSLogixHorizonServer) -eq 'synthetic.invalid')
    $calls = & $module { ,@($script:RestCalls) }
    $login = $calls[0].Body | ConvertFrom-Json
    Assert 'domain credential parsed' ($login.username -eq 'operator' -and $login.domain -eq 'LAB')
    Assert 'login URI contract' ($calls[0].Uri -eq 'https://synthetic.invalid/rest/login' -and $calls[0].Method -eq 'Post')
    Assert 'lab callback active only in request' ($null -ne $calls[0].Callback)
    Assert 'lab callback restored after login' ([object]::Equals($previousCallback, [Net.ServicePointManager]::ServerCertificateValidationCallback))
    $sessions = Get-FSLogixHorizonSession -UserName alice
    Assert 'session filtering contract' ($sessions.Count -eq 1 -and $sessions[0].id -eq 'one')
    $sessions = Get-FSLogixHorizonSession -UserName nobody
    Assert 'empty session result is an array' ($sessions -is [array] -and $sessions.Count -eq 0)
    $sessions = Get-FSLogixHorizonSession -UserName bob
    Assert 'disconnected session remains a blocker' ($sessions.Count -eq 1 -and $sessions[0].session_state -eq 'DISCONNECTED')
    Assert 'callback restored after query' ([object]::Equals($previousCallback, [Net.ServicePointManager]::ServerCertificateValidationCallback))
    $before = (& $module { $script:RestCalls.Count })
    Stop-FSLogixHorizonSession -SessionId 'one' -WhatIf
    Assert 'logoff WhatIf makes no HTTP request' ((& $module { $script:RestCalls.Count }) -eq $before)
    Stop-FSLogixHorizonSession -SessionId 'one/unsafe' -Confirm:$false
    $last = & $module { $script:RestCalls[$script:RestCalls.Count - 1] }
    Assert 'logoff request and encoded ID' ($last.Method -eq 'Post' -and $last.Uri -like '*/sessions/one%2Funsafe/logoff')
    Assert 'bearer header contract' ($last.Headers.Authorization -eq 'Bearer synthetic-token')
    & $module { $script:RestFailure = $true }
    Assert 'query failure is unknown' ($null -eq (Get-FSLogixHorizonSession -UserName alice))
    Assert 'callback restored on query failure' ([object]::Equals($previousCallback, [Net.ServicePointManager]::ServerCertificateValidationCallback))
    $caught = $false
    try { [void](Connect-FSLogixHorizon -Server 'synthetic.invalid' -Credential $credential -SkipCertificateCheck) } catch { $caught = $true }
    Assert 'login failure surfaces' $caught
    Assert 'failed reconnect clears old connection' (-not (Test-FSLogixHorizonConnected))
    Assert 'cleared connection has no saved server value' ($null -eq (Get-FSLogixHorizonServer))
    Assert 'callback restored on login failure' ([object]::Equals($previousCallback, [Net.ServicePointManager]::ServerCertificateValidationCallback))
    & $module { $script:RestFailure = $false; $script:LoginToken = '' }
    $caught = $false
    try { [void](Connect-FSLogixHorizon -Server 'synthetic.invalid' -Credential $credential) } catch { $caught = $true }
    Assert 'missing token rejected' ($caught -and -not (Test-FSLogixHorizonConnected))
    [void](Disconnect-FSLogixHorizon)
    Assert 'disconnected query is unknown' ($null -eq (Get-FSLogixHorizonSession -UserName alice))

    & $module { $script:LoginToken = 'synthetic-token' }
    [void](Connect-FSLogixHorizon -Server 'synthetic.invalid' -Credential $credential)
    & $module { $script:RestSessions = @() }
    $sessions = Get-FSLogixHorizonSession -UserName alice
    Assert 'actual empty inventory remains authoritative' ($sessions -is [array] -and $sessions.Count -eq 0)
    & $module { $script:RestSessions = $null }
    Assert 'null inventory is unknown' ($null -eq (Get-FSLogixHorizonSession -UserName alice))
    & $module { $script:RestSessions = [pscustomobject]@{error='schema changed'} }
    Assert 'malformed successful response is unknown' ($null -eq (Get-FSLogixHorizonSession -UserName alice))
    & $module { $script:RestSessions = @([pscustomobject]@{user_name='alice'}, [pscustomobject]@{user_name='alice@lab.invalid'}) }
    $sessions = Get-FSLogixHorizonSession -UserName alice
    Assert 'bare and UPN sessions block retirement' ($sessions.Count -eq 2)
    & $module { $script:RestSessions = @([pscustomobject]@{user_name='LAB\bob'}, [pscustomobject]@{unexpected='shape'}) }
    Assert 'partially malformed inventory is unknown' ($null -eq (Get-FSLogixHorizonSession -UserName alice))

    # No actual UNC access: verify separate-server query/fallback routing.
    & $module {
        $script:SmbCalls = New-Object Collections.ArrayList
        $script:StateCalls = New-Object Collections.ArrayList
        function script:Get-FSLogixOpenHandle {
            param([string[]]$Path)
            [void]$script:SmbCalls.Add(@($Path))
            if ($Path[0] -like '\\server-a\*') { return ,@() }
            return $null
        }
        function script:Get-FSLogixContainerState {
            param($Path, $OpenHandles)
            [void]$script:StateCalls.Add([pscustomobject]@{Path=$Path;Unknown=($null -eq $OpenHandles)})
            [pscustomobject]@{State=$(if ($null -eq $OpenHandles) {'InUse'} else {'Free'});Holder='synthetic holder'}
        }
        function script:Test-Path { param($LiteralPath, $PathType) return ($LiteralPath -notmatch '-old-') }
    }
    $fakeRow = [pscustomobject]@{
        UserName='alice'; ProfileRoots=@('\\server-a\profiles','\\server-b\profiles')
        Containers=@(
            [pscustomobject]@{Name='Profile_alice.vhdx';Path='\\server-a\profiles\alice\Profile_alice.vhdx';Directory='\\server-a\profiles\alice';Root='\\server-a\profiles';Class='Profile';SizeGB=1;ReplicaPaths=@()},
            [pscustomobject]@{Name='Profile_alice.vhdx';Path='\\server-b\profiles\alice\Profile_alice.vhdx';Directory='\\server-b\profiles\alice';Root='\\server-b\profiles';Class='Profile';SizeGB=1;ReplicaPaths=@()}
        )
    }
    $plan = Get-FSLogixRetirePlan -ProfileObject $fakeRow -CheckInUse -BatchStamp '20260101-000000'
    Assert 'one SMB query per server' ((& $module { $script:SmbCalls.Count }) -eq 2)
    Assert 'SMB queries never mix servers' ((& $module { @($script:SmbCalls | Where-Object Count -ne 1).Count }) -eq 0)
    Assert 'unknown second server uses lock fallback' (($plan | Where-Object SourcePath -like '\\server-b\*').State -eq 'InUse')
    Assert 'empty first server result remains known' (($plan | Where-Object SourcePath -like '\\server-a\*').State -eq 'Ready')
    Write-Host "ALL $script:checks ADAPTER CHECKS PASSED (external services stubbed)"
} finally {
    [Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCallback
    Remove-Module FSLogixProfileCore -Force
    # Only remove the unique fixture path created above.
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
