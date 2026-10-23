param([Parameter(Mandatory)][ValidateSet('qlu','dlut-panjin','mnnu-yuanshan')][string]$SchoolId)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
try {
 $rule=Get-Content -LiteralPath (Join-Path $root ('adapters\'+$SchoolId+'.json')) -Raw -Encoding UTF8|ConvertFrom-Json
 $expected=@($rule.defaultSsid)+@($rule.ssidHints)
 $settingsFile=Join-Path $root 'data\settings.json'
 if(Test-Path -LiteralPath $settingsFile){$settings=Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8|ConvertFrom-Json;if($settings.Adapter -ceq $SchoolId -and $settings.Ssid){$expected+=@([string]$settings.Ssid)}}
 $networkLines=@(& "$env:WINDIR\System32\netsh.exe" wlan show interfaces)
 if($LASTEXITCODE -ne 0){throw 'WIFI_STATUS_UNAVAILABLE'}
 $current=$null;foreach($line in $networkLines){if($line -match '^\s*SSID\s*:\s*(.+?)\s*$'){$current=$Matches[1];break}}
 $onTarget=@($expected|Where-Object {$_ -and $_ -ceq $current}).Count -gt 0
 $node=Join-Path $root 'runtime\node.exe';if(-not(Test-Path -LiteralPath $node)){$node=(Get-Command node.exe -ErrorAction Stop).Source}
 Write-Output '仅核对校园网入口，不读取密码、不登录、不切换网络。'
 $flag=if($onTarget){'on-target'}else{'not-on-target'}
 & $node (Join-Path $root 'engine\collect-portal.mjs') $SchoolId (Join-Path $root 'reports') $flag
 if($LASTEXITCODE -ne 0){throw 'Collection process failed.'}
 Write-Output ('报告保存到 reports\入口-'+$SchoolId+'.json。报告只用于核对入口，不代表认证通过。')
}catch{$code=if($_.Exception.Message -ceq 'WIFI_STATUS_UNAVAILABLE'){'WIFI_STATUS_UNAVAILABLE'}else{'COLLECTION_PROCESS_ERROR'};@{Code=$code;CredentialSubmission=$false}|ConvertTo-Json -Compress;Write-Output '入口采集未完成，请确认已安装 Edge、已连接本校 Wi-Fi，并保存以上错误码。';exit 1}
