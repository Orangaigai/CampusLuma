$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $project 'build.ps1')
if($LASTEXITCODE -ne 0){throw 'Build failed.'}
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path -LiteralPath $compiler)){$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
foreach($name in @('CoreTests','SchoolRuleTests')){
    & $compiler /nologo /target:exe /codepage:65001 ('/out:'+(Join-Path $project ($name+'.exe'))) ('/reference:'+(Join-Path $project 'CampusLuma.Core.dll')) /reference:System.Web.Extensions.dll /reference:System.Security.dll (Join-Path $PSScriptRoot ($name+'.cs'))
    if($LASTEXITCODE -ne 0){throw ($name+' compilation failed.')}
    $data=if($name -eq 'CoreTests'){'core-test-data'}else{'school-rule-tests'}
    & (Join-Path $project ($name+'.exe')) (Join-Path $project ('artifacts\'+$data))
    if($LASTEXITCODE -ne 0){throw ($name+' failed.')}
}
foreach($test in @('verify-run-journal.ps1','verify-schedule-recovery.ps1','verify-credential-bridge.ps1','verify-wrapper.ps1','verify-catchup-worker.ps1','verify-school-dispatch.ps1','verify-snnu-worker.ps1','verify-hunan-worker.ps1')){
    & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $test)
    if($LASTEXITCODE -ne 0){throw ('Isolated integration failed: '+$test)}
}
& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $project 'engine\tests\verify-reconnect.ps1')
if($LASTEXITCODE -ne 0){throw 'Wi-Fi fixtures failed.'}
Push-Location (Join-Path $project 'engine')
try{
    $files=@(Get-ChildItem -LiteralPath (Join-Path $project 'engine\tests') -Filter '*.test.mjs' | Sort-Object Name | ForEach-Object {$_.FullName})
    & node.exe --test --test-concurrency=2 @files
    if($LASTEXITCODE -ne 0){throw 'Browser / protocol fixtures failed.'}
}finally{Pop-Location}
Write-Output 'PASS isolated build, core, storage, recovery, worker, Wi-Fi, browser and protocol tests; no real school login or network mutation.'
