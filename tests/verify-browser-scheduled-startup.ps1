param([string]$RuntimeRoot='')
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
if(-not $RuntimeRoot){$RuntimeRoot=$project}
$fixture=Join-Path $project ('artifacts\incident-20261019\scheduled-browser-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture -Force
Copy-Item -LiteralPath (Join-Path $RuntimeRoot 'scripts\run-hidden.vbs') -Destination (Join-Path $fixture 'run-hidden.vbs')
$smoke=@'
import { pathToFileURL } from 'node:url';
import { join } from 'node:path';
const root=process.argv[2];
const {launchBrowser}=await import(pathToFileURL(join(root,'engine','xtu-browser.mjs')));
const {prepareBrowserSession}=await import(pathToFileURL(join(root,'engine','browser-startup.mjs')));
const cases=[];
for(const mode of ['normal','transient-startup-failure']){
  let launches=0,session;
  try{
    session=await prepareBrowserSession(async()=>{
      launches++;
      if(mode==='transient-startup-failure'&&launches===1)throw new Error('Fixture browser closed before navigation');
      return launchBrowser();
    });
    await session.page.route('**/*',route=>route.abort());
    await session.page.setContent('<title>CampusLuma offline runtime check</title>');
    if(await session.page.title()!=='CampusLuma offline runtime check')throw new Error('Local page failed');
    if(session.StartupAttempts!==(mode==='normal'?1:2))throw new Error('Unexpected retry count');
    cases.push({Mode:mode,Passed:true,StartupAttempts:session.StartupAttempts,Version:session.browser.version()});
  }finally{await session?.browser.close();}
}
process.stdout.write(JSON.stringify({Passed:true,RealNetworkModified:false,RealCredentialsUsed:false,Cases:cases})+'\n');
'@
$worker=@'
param([string]$DataDirectory)
$ErrorActionPreference='Stop'
try{
  $root=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'runtime-root.txt') -Raw -Encoding UTF8
  $json=@(& node.exe (Join-Path $PSScriptRoot 'smoke.mjs') $root.Trim()) -join [Environment]::NewLine
  if($LASTEXITCODE -ne 0){throw 'Node smoke failed.'}
  $reply=$json | ConvertFrom-Json
  if(-not $reply.Passed){throw 'Browser smoke failed.'}
  $json | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'result.json') -Encoding UTF8
  exit 0
}catch{
  @{Passed=$false;ErrorType=$_.Exception.GetType().Name}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $PSScriptRoot 'result.json') -Encoding UTF8
  exit 1
}
'@
[IO.File]::WriteAllText((Join-Path $fixture 'smoke.mjs'),$smoke,(New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $fixture 'run-once.ps1'),$worker,(New-Object Text.UTF8Encoding($true)))
[IO.File]::WriteAllText((Join-Path $fixture 'runtime-root.txt'),$RuntimeRoot,(New-Object Text.UTF8Encoding($true)))
$scheduler=New-Object -ComObject Schedule.Service
$scheduler.Connect()
$folder=$scheduler.GetFolder('\')
$taskName='CampusLuma Test-'+[guid]::NewGuid().ToString('N')+' 01'
$registered=$false
try{
  $definition=$scheduler.NewTask(0)
  $definition.Principal.UserId=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $definition.Principal.LogonType=3
  $definition.Settings.ExecutionTimeLimit='PT1M'
  $definition.Settings.DisallowStartIfOnBatteries=$false
  $definition.Settings.StopIfGoingOnBatteries=$false
  $definition.Settings.MultipleInstances=2
  $trigger=$definition.Triggers.Create(1)
  $trigger.StartBoundary=(Get-Date).AddSeconds(12).ToString('s')
  $action=$definition.Actions.Create(0)
  $action.Path=Join-Path $env:WINDIR 'System32\wscript.exe'
  $action.Arguments='//B //NoLogo "{0}" "{1}"' -f (Join-Path $fixture 'run-hidden.vbs'),$fixture
  $action.WorkingDirectory=$fixture
  $null=$folder.RegisterTaskDefinition($taskName,$definition,6,$null,$null,3)
  $registered=$true
  $deadline=(Get-Date).AddSeconds(50)
  do{
    Start-Sleep -Milliseconds 500
    $task=$folder.GetTask($taskName)
    $resultPath=Join-Path $fixture 'result.json'
    if((Test-Path -LiteralPath $resultPath)-and $task.State -ne 4){break}
  }while((Get-Date)-lt $deadline)
  if(-not(Test-Path -LiteralPath $resultPath)){throw 'Scheduled browser check timed out.'}
  $result=Get-Content -LiteralPath $resultPath -Raw|ConvertFrom-Json
  if(-not $result.Passed -or $task.LastTaskResult -ne 0){throw 'Scheduled browser check failed.'}
  $report=@{Passed=$true;RuntimeRoot=$RuntimeRoot;ClockTriggered=$true;TaskName=$taskName;
    WindowsLastRun=$task.LastRunTime.ToString('s');ExitCode=$task.LastTaskResult;
    RealCredentialsUsed=$false;RealNetworkModified=$false;Cases=$result.Cases}
}finally{
  if($registered){$folder.DeleteTask($taskName,0)}
}
$report.TemporaryTaskRemoved=$true
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $project 'artifacts\incident-20261019\scheduled-browser-result.json') -Encoding UTF8
$report|ConvertTo-Json -Depth 6
