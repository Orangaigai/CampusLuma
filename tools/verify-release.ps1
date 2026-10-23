param([Parameter(Mandatory)][string]$Archive)
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$Archive=[IO.Path]::GetFullPath($Archive)
$output=Join-Path $project ('artifacts\release-check-'+[guid]::NewGuid().ToString('N'))
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead($Archive)
try{
    $manifestEntry=@($zip.Entries|Where-Object {$_.FullName.Replace('\','/').EndsWith('/build-manifest.json')})
    if($manifestEntry.Count -ne 1){throw 'Expected exactly one build manifest.'}
    $reader=New-Object IO.StreamReader($manifestEntry[0].Open())
    try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
    if($manifest.PersonalConfigurationIncluded -ne $false -or $manifest.SourceCommit -notmatch '^[0-9a-f]{40}$'){throw 'Invalid release metadata.'}
    $prefix=$manifestEntry[0].FullName.Replace('\','/').Substring(0,$manifestEntry[0].FullName.Length-'build-manifest.json'.Length)
    $entries=@{}
    foreach($entry in $zip.Entries){
        $name=$entry.FullName.Replace('\','/')
        if(-not $name.StartsWith($prefix) -or $name -match '(^|/)\.\.?(/|$)' -or $entries.ContainsKey($name)){throw 'Unsafe or duplicate ZIP path.'}
        $entries[$name]=$entry
    }
    $actualFiles=@($zip.Entries|Where-Object {-not $_.FullName.Replace('\','/').EndsWith('/')})
    if($actualFiles.Count -ne $manifest.Files.Count+1){throw 'Unexpected ZIP file count.'}
    foreach($file in $manifest.Files){
        $entry=$entries[$prefix+$file.File]
        if(-not $entry){throw ('Missing package file: '+$file.File)}
        $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
        try{$actual=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose();$sha.Dispose()}
        if($actual -cne $file.Sha256){throw ('Hash mismatch: '+$file.File)}
        if($file.File -notlike 'engine/node_modules/*' -and $file.File -match '(^|/)(credential|settings|data-location|last-run|run-history|schedule-receipt)\.json$|\.(har|log|recovery)$'){throw 'Private state in package.'}
    }
}finally{$zip.Dispose()}
[IO.Compression.ZipFile]::ExtractToDirectory($Archive,$output)
$pack=Join-Path $output $prefix.TrimEnd('/')
$enabled=@(Get-ChildItem -LiteralPath (Join-Path $pack 'adapters') -Filter '*.json'|ForEach-Object {Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8|ConvertFrom-Json}|Where-Object {$_.enabled})
if($enabled.Count -ne 1 -or $enabled[0].id -cne 'xtu' -or -not(Test-Path -LiteralPath (Join-Path $pack 'development.mode'))){throw 'Preview isolation or school defaults changed.'}
$state=Join-Path $output 'isolated-state'
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$oldPath=$env:PATH
try{
    $env:PATH=''
    $check=(& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $pack 'scripts\run-once.ps1') -DataDirectory $state -CheckOnly)|ConvertFrom-Json
    if($LASTEXITCODE -ne 0 -or -not $check.Success -or -not $check.NodeReady -or -not $check.DependenciesReady){throw 'Bundled environment check failed.'}
    $probe=@'
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const root=process.argv[2];
const {launchBrowser,solveCaptcha}=await import(pathToFileURL(join(root,'engine','xtu-browser.mjs')));
const browser=await launchBrowser();
try {
  const context=await browser.newContext();
  await context.route('**/*',route=>route.abort());
  const page=await context.newPage();
  await page.setContent('<div id="sample" style="width:120px;height:40px;background:white;color:black;font:28px Arial;letter-spacing:3px;line-height:40px">1234</div>');
  const answer=await solveCaptcha(await page.locator('#sample').screenshot());
  if(answer!=='1234')throw new Error('Packaged OCR model failed.');
  console.log('PASS bundled Node, Edge, browser engine and local OCR without external page access.');
} finally {await browser.close();}
'@
    $probeFile=Join-Path $output 'package-probe.mjs'
    [IO.File]::WriteAllText($probeFile,$probe,(New-Object Text.UTF8Encoding($false)))
    & (Join-Path $pack 'runtime\node.exe') $probeFile $pack
    if($LASTEXITCODE -ne 0){throw 'Packaged runtime probe failed.'}
}finally{$env:PATH=$oldPath}
$png=Join-Path $output 'window.png'
$process=Start-Process -FilePath (Join-Path $pack 'CampusLuma.exe') -ArgumentList @('--render-preview','--data-directory',('"'+$state+'"'),'--output',('"'+$png+'"')) -WindowStyle Hidden -PassThru
if(-not $process.WaitForExit(15000) -or $process.ExitCode -ne 0 -or -not(Test-Path -LiteralPath $png)){throw 'Packaged window failed to render.'}
$result=@{Passed=$true;SourceCommit=$manifest.SourceCommit;Files=$manifest.Files.Count;FreshExtraction=$true;SystemNodeRequired=$false;RealAuthenticationRun=$false;TaskCreated=$false}
$result|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
$result|ConvertTo-Json
