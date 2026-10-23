$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $root 'artifacts\wrapper-fixture'
foreach($directory in @('scripts','engine','adapters','data')) { $null=New-Item -ItemType Directory -Path (Join-Path $fixture $directory) -Force }
Copy-Item -LiteralPath (Join-Path $root 'scripts\run-once.ps1') -Destination (Join-Path $fixture 'scripts') -Force
Copy-Item -LiteralPath (Join-Path $root 'CampusLuma.Core.dll') -Destination $fixture -Force
Copy-Item -LiteralPath (Join-Path $root 'engine\campus-auth.ps1') -Destination (Join-Path $fixture 'engine') -Force
Copy-Item -LiteralPath (Join-Path $root 'adapters\xtu.json') -Destination (Join-Path $fixture 'adapters') -Force
Copy-Item -LiteralPath (Join-Path $root 'artifacts\core-test-data\settings.json') -Destination (Join-Path $fixture 'data') -Force
Copy-Item -LiteralPath (Join-Path $root 'artifacts\core-test-data\credential.json') -Destination (Join-Path $fixture 'data') -Force
$mock=@'
$global:fixtureMode=Get-Content -LiteralPath (Join-Path $DataDirectory 'mode.txt')
$global:fixtureOnline=($global:fixtureMode -eq 'online')
function global:netsh {
    $operation=$args -join ' '
    if($operation -like 'wlan show interfaces*') { '    Name : WLAN';if($global:fixtureMode -eq 'home') { '    SSID : HomeWiFi' } else { '    SSID : XTU-FREE-2' } }
    elseif($operation -like 'wlan show networks*') { 'SSID 1 : HomeWiFi' }
    else { throw 'Fixture forbids any native network mutation.' }
    $global:LASTEXITCODE=0
}
function global:curl.exe {
    if($global:fixtureOnline) { $global:LASTEXITCODE=0; 'Microsoft Connect Test' } else { $global:LASTEXITCODE=7 }
}
'@
$engine=Get-Content -LiteralPath (Join-Path $root 'engine\campus-network-reconnect.ps1') -Raw -Encoding UTF8
$fixtureMutex='Local\CampusLumaWrapper'+[guid]::NewGuid().ToString('N')
$engine=$engine.Replace('Local\XTUCampusNetworkReconnect',$fixtureMutex)
$firstNewline=$engine.IndexOf("`n")
$engine=$engine.Substring(0,$firstNewline+1)+$mock+"`n"+$engine.Substring($firstNewline+1)
$engine | Set-Content -LiteralPath (Join-Path $fixture 'engine\campus-network-reconnect.ps1') -Encoding UTF8
@'
param([string]$InterfaceName)
return 0
'@ | Set-Content -LiteralPath (Join-Path $fixture 'engine\wifi-scan.ps1') -Encoding UTF8
@'
param([Uri]$PortalUri,[System.Management.Automation.PSCredential]$Credential,[string]$DataDirectory)
if($Credential.UserName -cne 'fixture-student' -or $Credential.GetNetworkCredential().Password -cne 'fixture-password-not-real') { throw 'Credential bridge mismatch.' }
if($global:fixtureMode -eq 'failure') { return [pscustomobject]@{Code='AUTH_TIME_RESTRICTED';Submitted=$false} }
if($global:fixtureMode -ne 'auth') { throw 'Provider invoked unexpectedly.' }
$global:fixtureOnline=$true
Set-Content -LiteralPath (Join-Path $DataDirectory 'submitted.txt') -Value 'fixture only'
[pscustomobject]@{Code='ONLINE_AFTER_AUTH';Submitted=$true}
'@ | Set-Content -LiteralPath (Join-Path $fixture 'engine\campus-auth-provider.ps1') -Encoding UTF8
$expected=@{online='ALREADY_ONLINE';auth='ONLINE_AFTER_AUTH';home='CAMPUS_NOT_VISIBLE';failure='AUTH_TIME_RESTRICTED';'busy-stale'='RUN_SKIPPED';'busy-empty'='RUN_SKIPPED'}
$historyPath=Join-Path $fixture 'data\run-history.json'
$historyBefore=if(Test-Path -LiteralPath $historyPath){(Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8|ConvertFrom-Json).Count}else{0}
foreach($mode in @('online','auth','home','failure','busy-stale','busy-empty')) {
    Set-Content -LiteralPath (Join-Path $fixture 'data\mode.txt') -Value $mode -Encoding ASCII
    $submitted=Join-Path $fixture 'data\submitted.txt'
    if(Test-Path -LiteralPath $submitted) { Remove-Item -LiteralPath $submitted }
    $log=Join-Path $fixture 'data\campus-network-reconnect.log'
    if($mode -in @('failure','busy-stale')) {
        Set-Content -LiteralPath $log -Value '2026-10-01 07:01:00 Campus Wi-Fi online; no authentication needed.' -Encoding UTF8
    } elseif($mode -eq 'busy-empty' -and (Test-Path -LiteralPath $log)) { Remove-Item -LiteralPath $log }
    $mutex=$null; $ownsMutex=$false
    try {
        if($mode -like 'busy-*') {
            $mutex=New-Object Threading.Mutex($false,$fixtureMutex)
            $ownsMutex=$mutex.WaitOne(0)
            if(-not $ownsMutex) { throw 'Cannot own the isolated test mutex.' }
        }
        & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $fixture 'scripts\run-once.ps1') -DataDirectory (Join-Path $fixture 'data')
        $actualExit=$LASTEXITCODE
    } finally {
        if($ownsMutex) { $mutex.ReleaseMutex() }
        if($null -ne $mutex) { $mutex.Dispose() }
    }
    $expectedExit=if($mode -eq 'failure'){1}else{0}
    if($actualExit -ne $expectedExit) { throw ('Wrapper fixture failed: '+$mode) }
    $result=Get-Content -LiteralPath (Join-Path $fixture 'data\last-run.json') -Raw | ConvertFrom-Json
    if($result.Code -cne $expected[$mode]) { throw ('Wrong wrapper result: '+$result.Code) }
    if((Test-Path -LiteralPath $submitted) -ne ($mode -eq 'auth')) { throw 'Wrong submission decision.' }
    if($result.Success -ne ($mode -in @('online','auth'))) { throw ('False success or failure: '+$mode) }
    if($mode -like 'busy-*' -and $result.AuthenticationAttempted) { throw 'A skipped run must not claim an authentication attempt.' }
    if(-not $result.RunId -or -not $result.CompletedAt -or $result.DurationMs -lt 0){throw 'Wrapper did not record timing and invocation identity.'}
    Write-Output ('PASS independent wrapper: '+$mode)
}
$history=Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8|ConvertFrom-Json
if($history.Count -ne [Math]::Min(100,$historyBefore+6)){throw 'Wrapper history lost an invocation.'}
if((Get-Content -LiteralPath $historyPath -Raw -Encoding UTF8) -match 'fixture-student|fixture-password-not-real'){throw 'Wrapper history leaked the fixture account or password.'}
Write-Output 'PASS wrapper writes bounded, credential-free history for all six outcomes.'
@{Code='LOCAL_WRAPPER_CHAIN_VERIFIED';NetworkCommandsMocked=$true;RealCredentialSubmission=$false;Cases=@('already-online','DPAPI-auth-recovery','home-no-campus','failure-after-stale-success','busy-with-stale-success','busy-with-no-log')} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'artifacts\wrapper-result.json') -Encoding UTF8
