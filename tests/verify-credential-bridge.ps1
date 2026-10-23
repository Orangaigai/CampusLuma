$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$data=Join-Path $root 'artifacts\core-test-data'
$fixture=Join-Path $root 'artifacts\credential-bridge'
$null=New-Item -ItemType Directory -Path $fixture -Force
Copy-Item -LiteralPath (Join-Path $root 'engine\campus-auth.ps1') -Destination $fixture -Force
@'
param([Uri]$PortalUri,[System.Management.Automation.PSCredential]$Credential,[string]$DataDirectory)
if($Credential.UserName -cne 'fixture-student' -or $Credential.GetNetworkCredential().Password -cne 'fixture-password-not-real') { throw 'Fixture credential mismatch.' }
if($PortalUri.AbsoluteUri -ne 'https://zz.xtu.edu.cn/pc/center') { throw 'Portal parameter not forwarded.' }
[pscustomobject]@{Code='ONLINE_AFTER_AUTH';Submitted=$true}
'@ | Set-Content -LiteralPath (Join-Path $fixture 'campus-auth-provider.ps1') -Encoding UTF8
$reply=& (Join-Path $fixture 'campus-auth.ps1') -DataDirectory $data -PortalUri 'https://zz.xtu.edu.cn/pc/center'
if($reply.Code -ne 'ONLINE_AFTER_AUTH' -or -not $reply.Attempted) { throw ('Credential bridge failed: '+$reply.Code) }
$marker=Join-Path $data 'last-auth-rejection.txt'
try {
    Set-Content -LiteralPath $marker -Value 'fixture rejection' -Encoding ASCII
    $reply=& (Join-Path $fixture 'campus-auth.ps1') -DataDirectory $data -PortalUri 'https://zz.xtu.edu.cn/pc/center'
    if($reply.Code -ne 'LOGIN_BLOCKED_AFTER_REJECTION' -or $reply.Attempted) { throw 'Rejection pause was not enforced.' }
} finally { if(Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker } }
Write-Output 'PASS GUI DPAPI credential -> PowerShell -> provider, and rejection pause.'
