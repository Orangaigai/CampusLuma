$ErrorActionPreference='Stop'
$project=if($env:CAMPUSLUMA_TEST_PROJECT){$env:CAMPUSLUMA_TEST_PROJECT}else{Split-Path $PSScriptRoot -Parent}
$fixture=Join-Path $project ('artifacts\provider-process-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path (Join-Path $fixture 'node_modules\playwright-core') -Force
Copy-Item -LiteralPath (Join-Path $project 'engine\campus-auth-provider.ps1') -Destination $fixture
Set-Content -LiteralPath (Join-Path $fixture 'node_modules\playwright-core\package.json') -Value '{}' -Encoding ASCII
$credential=New-Object Management.Automation.PSCredential('fixture-student',(ConvertTo-SecureString 'fixture-password-not-real' -AsPlainText -Force))
$entry=if(Test-Path -LiteralPath (Join-Path $project 'engine\auth-provider.mjs')){'auth-provider.mjs'}else{'xtu-browser.mjs'}
$nodeFile=Join-Path $fixture $entry
# This Node stub has no network code. It consumes only fictional credentials.
$stub=@'
import fs from 'node:fs';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
let input = '';
for await (const chunk of process.stdin) input += chunk;
const payload = JSON.parse(input.replace(/^\uFEFF/, ''));
if (payload.username !== 'fixture-student' || payload.password !== 'fixture-password-not-real') process.exit(2);
const mode = fs.readFileSync(new URL('./mode.txt', import.meta.url), 'utf8').trim();
if (mode === 'failure') process.exit(1);
if (mode === 'startup-failure') {
  process.stdout.write(JSON.stringify({ Code: 'BROWSER_START_FAILED', Submitted: false,
    ErrorType: 'Error', ErrorStage: 'CREATE_CONTEXT', ErrorCode: 'EDGE_PROCESS_CLOSED', StartupAttempts: 2,
    Message: 'fixture-secret-not-for-logs' }));
  process.exit(0);
}
if (mode === 'timeout') {
  const child = spawn(process.execPath, [fileURLToPath(new URL('./sleep.mjs', import.meta.url))], { windowsHide: true, stdio: 'ignore' });
  fs.writeFileSync(new URL('./children.json', import.meta.url), JSON.stringify([process.pid, child.pid]));
  setInterval(() => {}, 1000);
} else {
  process.stderr.write('Fixture stderr warning, not an authentication failure.\n');
  process.stdout.write(JSON.stringify({ Code: 'ONLINE_AFTER_AUTH', Submitted: true, PortalSource: 'FIXTURE' }));
}
'@
[IO.File]::WriteAllText($nodeFile,$stub,(New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $fixture 'sleep.mjs'),'setInterval(() => {}, 1000);',(New-Object Text.UTF8Encoding($false)))
$cases=@()
foreach($mode in @('success','failure','timeout','startup-failure')) {
    Set-Content -LiteralPath (Join-Path $fixture 'mode.txt') -Value $mode -Encoding ASCII
    $reply=& (Join-Path $fixture 'campus-auth-provider.ps1') -Credential $credential -DataDirectory $fixture -TimeoutSeconds 2
    $expected=switch($mode){success{'ONLINE_AFTER_AUTH'}failure{'PROVIDER_PROCESS_ERROR'}timeout{'PROVIDER_TIMEOUT'}startup-failure{'BROWSER_START_FAILED'}}
    if($reply.Code -cne $expected) { throw ('Unexpected provider result: '+$mode+' '+$reply.Code) }
    if($mode -eq 'startup-failure') {
        $savedText=Get-Content -LiteralPath (Join-Path $fixture 'last-auth-result.json') -Raw
        $saved=$savedText | ConvertFrom-Json
        if($reply.Submitted -or $saved.Submitted -or $saved.ErrorStage -cne 'CREATE_CONTEXT' -or
            $saved.ErrorCode -cne 'EDGE_PROCESS_CLOSED' -or $saved.StartupAttempts -ne 2 -or
            $savedText -match 'fixture-secret-not-for-logs') { throw 'Startup diagnostics missing or not sanitized.' }
    }
    if($mode -eq 'timeout') {
        $pids=Get-Content -LiteralPath (Join-Path $fixture 'children.json') -Raw | ConvertFrom-Json
        foreach($testPid in $pids) { if(Get-Process -Id $testPid -ErrorAction SilentlyContinue) { throw 'Timed-out fixture process was not terminated.' } }
    }
    $cases+=@{Mode=$mode;Code=$reply.Code}
    Write-Output ('PASS provider stdin/stderr/exit/timeout: '+$mode)
}
@{Passed=$true;RealNetworkModified=$false;RealCredentialsUsed=$false;TimeoutTreeCleaned=$true;Cases=$cases} | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $project 'artifacts\provider-process-result.json') -Encoding UTF8
