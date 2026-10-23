# Windows PowerShell 5.1. Run from a committed, clean source checkout.
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$version=[IO.File]::ReadAllText((Join-Path $project 'VERSION')).Trim()
if($version -notmatch '^\d+\.\d+\.\d+(?:-[a-z0-9.]+)?$'){throw 'Invalid release version.'}
$revision=(& git -C $project rev-parse HEAD).Trim()
if($LASTEXITCODE -ne 0 -or $revision -notmatch '^[0-9a-f]{40}$'){throw 'A committed source checkout is required.'}
$dirty=(& git -C $project status --porcelain --untracked-files=normal) -join ''
if($LASTEXITCODE -ne 0 -or $dirty){throw 'Commit or remove pending source changes before packaging.'}
& node.exe (Join-Path $project 'tools\check-public.mjs')
if($LASTEXITCODE -ne 0){throw 'Public source audit failed.'}
$ps=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $project 'build.ps1')
if($LASTEXITCODE -ne 0){throw 'Release build failed.'}
$name='CampusLuma-v'+$version+'-windows-x64'
$output=Join-Path $project 'artifacts\releases'
$stage=Join-Path $output $name
$zip=$stage+'.zip'
if((Test-Path -LiteralPath $stage) -or (Test-Path -LiteralPath $zip)){throw 'Release output exists; inspect it before rebuilding.'}
foreach($directory in @('ui','engine','scripts','adapters','runtime','docs')){[IO.Directory]::CreateDirectory((Join-Path $stage $directory))|Out-Null}
foreach($file in @('CampusLuma.exe','CampusLuma.Core.dll','LICENSE','THIRD-PARTY.md','README.md','CHANGELOG.md','CONTRIBUTING.md','CODE_OF_CONDUCT.md','SECURITY.md','VERIFICATION.md','VERSION','development.mode','启动微光校园.cmd')){
    Copy-Item -LiteralPath (Join-Path $project $file) -Destination $stage
}
$publicFiles=@(& git -C $project ls-files -- ui scripts adapters engine docs)
if($LASTEXITCODE -ne 0){throw 'Cannot enumerate public runtime files.'}
foreach($relative in $publicFiles){
    if($relative -like 'engine/tests/*'){continue}
    $destination=Join-Path $stage $relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))|Out-Null
    Copy-Item -LiteralPath (Join-Path $project $relative) -Destination $destination
}
Copy-Item -LiteralPath (Join-Path $project 'docs\USAGE.md') -Destination (Join-Path $stage '使用说明.md')
$modules=Join-Path $project 'engine\node_modules'
if(-not(Test-Path -LiteralPath (Join-Path $modules 'ddddocr-node\package.json'))){throw 'Run npm ci before packaging.'}
& "$env:WINDIR\System32\robocopy.exe" $modules (Join-Path $stage 'engine\node_modules') /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XF '*.log' '*.har' '*.dmp' /XD '.turbo' (Join-Path $modules 'onnxruntime-node\bin\napi-v3\darwin') (Join-Path $modules 'onnxruntime-node\bin\napi-v3\linux') (Join-Path $modules 'onnxruntime-node\bin\napi-v3\win32\arm64')
if($LASTEXITCODE -gt 7){throw 'Dependency copy failed.'}
$global:LASTEXITCODE=0
$node=(Get-Command node.exe -ErrorAction Stop).Source
$nodeVersion=(& $node --version).Trim()
$arch=(& $node -p 'process.arch').Trim()
if($arch -cne 'x64'){throw 'Windows x64 Node is required for this package.'}
Copy-Item -LiteralPath $node -Destination (Join-Path $stage 'runtime\node.exe')
& (Join-Path $project 'tools\copy-node-license.ps1') -NodeVersion $nodeVersion -Destination (Join-Path $stage 'runtime\NODE-LICENSE.txt')
if(-not(Test-Path -LiteralPath (Join-Path $stage 'engine\node_modules\playwright-core\LICENSE'))){throw 'Playwright license is missing.'}
$privateFiles=@(Get-ChildItem -LiteralPath $stage -Recurse -File | Where-Object {$_.Name -match '^(credential|settings|data-location|last-run|run-history|schedule-receipt|last-auth-result)\.json$' -or $_.Extension -in @('.har','.log','.recovery')})
if($privateFiles.Count){throw 'Package contains private state or diagnostics.'}
$manifest=@{Project='CampusLuma';Version=$version;SourceCommit=$revision;NodeVersion=$nodeVersion;Platform='windows-x64';Preview=$true;DefaultEnabledSchools=@('xtu');PersonalConfigurationIncluded=$false;Files=@()}
foreach($file in (Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName)){
    $stream=[IO.File]::OpenRead($file.FullName);$sha=[Security.Cryptography.SHA256]::Create()
    try{$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose();$sha.Dispose()}
    $manifest.Files+=@{File=$file.FullName.Substring($stage.Length+1).Replace('\','/');Sha256=$hash}
}
[IO.File]::WriteAllText((Join-Path $stage 'build-manifest.json'),($manifest|ConvertTo-Json -Depth 5),(New-Object Text.UTF8Encoding($false)))
Add-Type -AssemblyName System.IO.Compression.FileSystem
$partial=$zip+'.partial'
[IO.Compression.ZipFile]::CreateFromDirectory($stage,$partial,[IO.Compression.CompressionLevel]::Optimal,$true)
[IO.File]::Move($partial,$zip)
$stream=[IO.File]::OpenRead($zip);$sha=[Security.Cryptography.SHA256]::Create()
try{$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$stream.Dispose();$sha.Dispose()}
[IO.File]::WriteAllText((Join-Path $output 'SHA256SUMS.txt'),($hash+'  '+[IO.Path]::GetFileName($zip)+"`n"),(New-Object Text.UTF8Encoding($false)))
@{Archive=$zip;Sha256=$hash;SourceCommit=$revision;Files=$manifest.Files.Count}|ConvertTo-Json
