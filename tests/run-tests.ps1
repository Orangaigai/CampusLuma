$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$powershellExe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
& (Join-Path $root 'build.ps1')
& $powershellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-ui-layout.ps1')
if($LASTEXITCODE -ne 0) { throw 'Window layout checks failed.' }
& $powershellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-run-journal.ps1')
if($LASTEXITCODE -ne 0) { throw 'Run journal tests failed.' }
& $powershellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-schedule-recovery.ps1')
if($LASTEXITCODE -ne 0) { throw 'Schedule recovery tests failed.' }
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path -LiteralPath $compiler)) { $compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
& $compiler /nologo /target:exe /codepage:65001 ('/out:'+(Join-Path $root 'CoreTests.exe')) ('/reference:'+(Join-Path $root 'CampusLuma.Core.dll')) /reference:System.Web.Extensions.dll /reference:System.Security.dll (Join-Path $PSScriptRoot 'CoreTests.cs')
if($LASTEXITCODE -ne 0) { throw 'Core test build failed.' }
& $compiler /nologo /target:exe /codepage:65001 ('/out:'+(Join-Path $root 'SchoolRuleTests.exe')) ('/reference:'+(Join-Path $root 'CampusLuma.Core.dll')) /reference:System.Web.Extensions.dll /reference:System.Security.dll (Join-Path $PSScriptRoot 'SchoolRuleTests.cs')
if($LASTEXITCODE -ne 0) { throw 'School-rule test build failed.' }
& (Join-Path $root 'SchoolRuleTests.exe') (Join-Path $root 'artifacts\school-rule-tests')
if($LASTEXITCODE -ne 0) { throw 'School-rule tests failed.' }
& (Join-Path $root 'CoreTests.exe') (Join-Path $root 'artifacts\core-test-data')
if($LASTEXITCODE -ne 0) { throw 'Core tests failed.' }
foreach($script in @('verify-credential-bridge.ps1','verify-scheduler.ps1','verify-wrapper.ps1','verify-hidden-task.ps1','verify-clock-trigger.ps1','verify-time-editor.ps1','verify-provider-process.ps1','verify-school-selector.ps1','verify-school-dispatch.ps1','verify-service-selector.ps1','verify-snnu-worker.ps1','verify-hunan-worker.ps1')) {
    & $powershellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $script)
    if($LASTEXITCODE -ne 0) { throw ('Integration failed: '+$script) }
}
& $powershellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-catchup-worker.ps1')
if($LASTEXITCODE -ne 0){throw 'Guarded catch-up integration failed.'}
& $powershellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root 'engine\tests\verify-reconnect.ps1')
if($LASTEXITCODE -ne 0) { throw 'Network workflow fixtures failed.' }
Push-Location (Join-Path $root 'engine')
try { & node.exe --test --test-concurrency=2 tests/portal.test.mjs tests/school-rules.test.mjs tests/snnu-preflight.test.mjs tests/snnu-auth.test.mjs tests/drcom-auth.test.mjs tests/sam-browser.test.mjs tests/next-schools.test.mjs; if($LASTEXITCODE -ne 0) { throw 'Browser and portal fixtures failed.' } } finally { Pop-Location }
$preview=Start-Process -FilePath (Join-Path $root 'CampusLuma.exe') -ArgumentList @('--ui-test','--data-directory',('"'+(Join-Path $root 'artifacts\ui-test-data')+'"'),'--output',('"'+(Join-Path $root 'artifacts\connection-window.png')+'"')) -WindowStyle Hidden -PassThru
if(-not $preview.WaitForExit(15000) -or $preview.ExitCode -ne 0) { throw 'WPF interaction smoke test failed.' }
& $powershellExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'verify-journal-ui.ps1')
if($LASTEXITCODE -ne 0) { throw 'Run journal desktop verification failed.' }
Write-Output 'PASS all core, credential, scheduling, wrapper, hidden-task, browser and WPF tests.'
