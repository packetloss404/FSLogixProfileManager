<#
Smoke tests for FSLogixProfileCore.psm1.

Pure-logic and filesystem tests only - no share, no AD, no Hyper-V, no Horizon.
Creates a throwaway tree under %TEMP% and removes it again.

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-FSLogixProfileCore.ps1

Exits 1 if any check fails.
#>

$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'FSLogixProfileCore.psm1') -Force
$fail=0
function Check($name,$actual,$expected){
  if("$actual" -eq "$expected"){Write-Host "  ok   $name"}else{Write-Host "  FAIL $name : got '$actual' want '$expected'";$script:fail++}
}
Write-Host "-- classification --"
Check 'Profile_'  (Get-FSLogixContainerClass -FileName 'Profile_jsmith.vhdx') 'Profile'
Check 'ODFC_'     (Get-FSLogixContainerClass -FileName 'ODFC_jsmith.vhdx')    'Office'
Check 'O365_'     (Get-FSLogixContainerClass -FileName 'O365_jsmith.vhdx')    'Office'
Check 'officeadm' (Get-FSLogixContainerClass -FileName 'Profile_officeadmin.vhdx') 'Profile'
Check 'unknown'   (Get-FSLogixContainerClass -FileName 'legacy.vhdx')         'Unknown'

Write-Host "-- retired detection --"
Check 'live'      ([bool](Test-FSLogixRetiredName -FileName 'Profile_bob.vhdx')) 'False'
Check 'legacy'    (Test-FSLogixRetiredName -FileName 'Profile_bob-old.vhdx').LiveName 'Profile_bob.vhdx'
$r = Test-FSLogixRetiredName -FileName 'Profile_bob-old-20260802-114500.vhdx'
Check 'stamped'   $r.LiveName 'Profile_bob.vhdx'
Check 'stampdate' $r.RetiredOn.ToString('yyyy-MM-dd HH:mm:ss') '2026-08-02 11:45:00'
Check 'target'    (Get-FSLogixRetireTargetName -FileName 'Profile_bob.vhdx' -BatchStamp '20260802-114500') 'Profile_bob-old-20260802-114500.vhdx'

Write-Host "-- identity (both FlipFlop orders + NoProfileContainingFolder) --"
$i = Resolve-FSLogixIdentity -FolderLeaf 'jsmith_S-1-5-21-111-222-333-1001' -FileName 'Profile_jsmith.vhdx'
Check 'userfirst.u' $i.UserName 'jsmith'; Check 'userfirst.s' $i.Sid 'S-1-5-21-111-222-333-1001'; Check 'userfirst.src' $i.Source 'FolderUserFirst'
$i = Resolve-FSLogixIdentity -FolderLeaf 'S-1-5-21-111-222-333-1001_jsmith' -FileName 'Profile_jsmith.vhdx'
Check 'sidfirst.u'  $i.UserName 'jsmith'; Check 'sidfirst.s'  $i.Sid 'S-1-5-21-111-222-333-1001'; Check 'sidfirst.src' $i.Source 'FolderSidFirst'
$i = Resolve-FSLogixIdentity -FolderLeaf 'FSLogixUserProfiles' -FileName 'Profile_jsmith.vhdx'
Check 'noflder.u'   $i.UserName 'jsmith'; Check 'noflder.src' $i.Source 'FileNamePrefix'
$i = Resolve-FSLogixIdentity -FolderLeaf 'randomjunk' -FileName 'blob.vhdx'
Check 'unresolved'  $i.Source 'Unresolved'
$i = Resolve-FSLogixIdentity -FolderLeaf 'S-1-5-21-111-222-333-1001_jsmith' -FileName 'Profile_jsmith-old-20260802-114500.vhdx'
Check 'retired.u'   $i.UserName 'jsmith'

Write-Host "-- ldap escaping --"
Check 'ldap' (Get-FSLogixLdapEscapedValue -Value 'bad*(name)') 'bad\2a\28name\29'

Write-Host "-- scan over a fake share --"
$root = Join-Path $env:TEMP ('fsl_' + (Get-Random))
$u1 = Join-Path $root 'S-1-5-21-1-2-3-1001_alice'; $u2 = Join-Path $root 'bob_S-1-5-21-1-2-3-1002'
New-Item -ItemType Directory -Path $u1,$u2 -Force | Out-Null
function Mk($p,$kb){ $f=[IO.File]::Create($p); $f.SetLength($kb*1KB); $f.Close() }
Mk (Join-Path $u1 'Profile_alice.vhdx') 4096
Mk (Join-Path $u1 'ODFC_alice.vhdx') 1024
Mk (Join-Path $u1 'Profile_alice-old-20260101-090000.vhdx') 2048
Mk (Join-Path $u1 'Profile_alice.vhdx.meta') 1
Mk (Join-Path $u1 'Profile_alice.vhdx.metadata') 1
Mk (Join-Path $u1 'Profile_alice.VHDX.lock') 1
Mk (Join-Path $u2 'Profile_bob.vhdx') 8192
Set-FSLogixLogHandler { param($m,$l) }
$p = Get-FSLogixProfiles -ProfileRoots @($root)
Check 'usercount' $p.Count 2
$alice = $p | Where-Object UserName -eq 'alice'
Check 'alice.live'    $alice.ContainerCount 2
Check 'alice.retired' $alice.RetiredContainers.Count 1
Check 'alice.office'  $alice.OfficeSizeGB 0.001
Check 'alice.total'   $alice.TotalSizeGB 0.005
Check 'alice.hasret'  ($alice.HealthIssues -contains 'HAS_RETIRED') 'True'
$plan = Get-FSLogixRetirePlan -ProfileObject $alice -Scope 'Profile' -BatchStamp '20260802-120000'
Check 'plan.count'  $plan.Count 1
Check 'plan.dest'   (Split-Path -Leaf $plan[0].DestPath) 'Profile_alice-old-20260802-120000.vhdx'
Check 'plan.state'  $plan[0].State 'Ready'

Write-Host "-- single-user share must not unroll to a scalar --"
$solo = Join-Path $env:TEMP ('fsl_' + (Get-Random)); $s1 = Join-Path $solo 'S-1-5-21-9-9-9-1_carol'
New-Item -ItemType Directory -Path $s1 -Force | Out-Null; Mk (Join-Path $s1 'Profile_carol.vhdx') 512
$one = Get-FSLogixProfiles -ProfileRoots @($solo)
Check 'solo.isarray' ($one -is [array]) 'True'
Check 'solo.count'   (Select-FSLogixProfile -Source $one -UserFilter 'carol').Count 1
Check 'empty.count'  (Select-FSLogixProfile -Source (Get-FSLogixProfiles -ProfileRoots @($solo)) -UserFilter 'nobody').Count 0
Check 'bracket.safe' (Select-FSLogixProfile -Source $one -UserFilter '[').Count 0

Write-Host "-- retired report --"
$ret = Get-FSLogixRetiredContainer -ProfileRoots @($root)
Check 'ret.count'   $ret.Count 1
Check 'ret.datesrc' $ret[0].DateSource 'stamp'
Check 'ret.sibling' $ret[0].HasLiveSibling 'True'

Write-Host "-- rename under WhatIf --"
# The handoff's "obvious next test": retire under -WhatIf against the synthetic
# share. Must report zero renames, must not touch the file, and must return the
# same structured shape the GUI now renders into the result dialog.
$root2 = Join-Path $env:TEMP ('fsl_' + (Get-Random))
$dave  = Join-Path $root2 'S-1-5-21-9-9-9-2_dave'
New-Item -ItemType Directory -Path $dave -Force | Out-Null
Mk (Join-Path $dave 'Profile_dave.vhdx') 2048
$profiles = @(Get-FSLogixProfiles -ProfileRoots @($root2))
$daveRow  = $profiles | Where-Object { $_.UserName -eq 'dave' }
$result   = Rename-FSLogixProfileObject -ProfileObject $daveRow -Scope 'All' -WhatIf -Confirm:$false
Check 'wi.mode'     $result.Mode        'WHATIF'
Check 'wi.renamed'  $result.Renamed     0
Check 'wi.planned'  $result.Planned     1
# The container on disk is still the live one - no rename happened.
Check 'wi.untouched' (Test-Path -LiteralPath (Join-Path $dave 'Profile_dave.vhdx')) 'True'
# Module returns a log path even in WhatIf.
Check 'wi.logpath'   ([bool]$result.LogPath) 'True'
Remove-Item $root2 -Recurse -Force

Write-Host "-- move to retired --"
# The Phase 4d feature: the retired file lands under <root>\_retired\<user>\<stamp>\
# instead of in the user's writable directory. The original path is empty
# after a live run, and the file at the new path has the expected name.
$root3 = Join-Path $env:TEMP ('fsl_' + (Get-Random))
$frank = Join-Path $root3 'S-1-5-21-9-9-9-3_frank'
New-Item -ItemType Directory -Path $frank -Force | Out-Null
Mk (Join-Path $frank 'Profile_frank.vhdx') 2048
$profiles = @(Get-FSLogixProfiles -ProfileRoots @($root3))
$frankRow = $profiles | Where-Object { $_.UserName -eq 'frank' }
$result   = Rename-FSLogixProfileObject -ProfileObject $frankRow -Scope 'All' -MoveToRetired -Confirm:$false
Check 'mv.renamed'  $result.Renamed     1
# The original location is empty - the file left the user's directory.
Check 'mv.sourcegone' (Test-Path -LiteralPath (Join-Path $frank 'Profile_frank.vhdx')) 'False'
# The file is now under _retired\frank\<batch>\.
$retiredDir = Join-Path (Join-Path (Join-Path $root3 '_retired') 'frank') $result.BatchStamp
Check 'mv.retireddir' (Test-Path -LiteralPath $retiredDir) 'True'
$moved = Get-ChildItem -LiteralPath $retiredDir -Filter 'Profile_frank-old-*.vhdx' -File
Check 'mv.movedone'   ([bool]$moved) 'True'
Remove-Item $root3 -Recurse -Force

Remove-Item $root,$solo -Recurse -Force
Write-Host ""
if($fail){Write-Host "$fail CHECK(S) FAILED" -ForegroundColor Red; exit 1}else{Write-Host "ALL CHECKS PASSED" -ForegroundColor Green}
