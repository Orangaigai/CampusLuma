param([string]$OutputDirectory='')
$ErrorActionPreference='Stop'
$projectPath=Split-Path $PSScriptRoot -Parent
if(-not $OutputDirectory){$OutputDirectory=Join-Path $projectPath 'artifacts\交接'}
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
$commit=(& git -C $projectPath rev-parse --verify 'HEAD^{commit}').Trim()
if($LASTEXITCODE -ne 0 -or $commit -notmatch '^[a-f0-9]{40}$'){throw '无法取得源码提交号。'}
$dirty=(& git -C $projectPath status --porcelain --untracked-files=normal) -join ''
if($LASTEXITCODE -ne 0 -or $dirty){throw '开发目录还有未提交修改，请先提交后再导出源码。'}
$null=New-Item -ItemType Directory -Path $OutputDirectory -Force
$name='CampusLuma-开发源码-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+$commit.Substring(0,7)
$partial=Join-Path $OutputDirectory ($name+'.partial.zip')
$zipPath=Join-Path $OutputDirectory ($name+'.zip')
if((Test-Path -LiteralPath $partial) -or (Test-Path -LiteralPath $zipPath)){throw '该源码包已存在，请稍后重试。'}
& git -C $projectPath archive --format=zip --prefix=CampusLuma/ ('--output='+$partial) HEAD
if($LASTEXITCODE -ne 0){throw '源码导出失败。'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
$archive=[IO.Compression.ZipFile]::Open($partial,[IO.Compression.ZipArchiveMode]::Update)
try{
    foreach($entry in $archive.Entries){
        $path=$entry.FullName.Replace('\','/')
        if(-not $path.StartsWith('CampusLuma/') -or $path -match '(^|/)\.\.?(/|$)' -or
            $path -match '^CampusLuma/(\.git/|artifacts/|reports/|data/|runtime/)' -or
            $path -match '(^|/)(node_modules|\.codex-remote-attachments)/' -or
            $entry.Name -match '^(credential|settings|local-settings|data-location|last-run|run-history|schedule-receipt|campus-settings|last-auth-result)\.json$' -or
            $entry.Name -match '\.(exe|dll|log)$'){throw ('源码包包含不应分发的文件：'+$path)}
    }
    $version=@{Project='CampusLuma';Flavor='Development';Commit=$commit;CreatedAt=(Get-Date).ToString('o');DependenciesBundled=$false;LocalConfigurationBundled=$false;GitHistoryBundled=$false}
    $metadata=$archive.CreateEntry('CampusLuma/SOURCE-VERSION.json')
    $writer=New-Object IO.StreamWriter($metadata.Open(),(New-Object Text.UTF8Encoding($false)))
    try{$writer.Write(($version|ConvertTo-Json -Depth 3))}finally{$writer.Dispose()}
}finally{$archive.Dispose()}
# Both paths were resolved inside the same explicit output directory; do not
# replace an existing package or move any project directory.
[IO.File]::Move($partial,$zipPath)
$stream=[IO.File]::OpenRead($zipPath)
try{$sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}}finally{$stream.Dispose()}
$result=@{Code='DEVELOPMENT_SOURCE_EXPORTED';Commit=$commit;Zip=$zipPath;Sha256=$hash;ContainsLocalCredentials=$false;ContainsGitHistory=$false}
$result|ConvertTo-Json -Depth 3|Set-Content -LiteralPath (Join-Path $OutputDirectory ($name+'.json')) -Encoding UTF8
$result|ConvertTo-Json -Compress
