param([Parameter(Mandatory)][ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+$')][string]$NodeVersion,[Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
foreach($id in @('snnu','hnust','hunnu','sam')){
 try {
  $pointer=Join-Path $root ('artifacts\'+$id+'-trial-package.json');if(-not(Test-Path -LiteralPath $pointer)){continue}
  $pack=Get-Content -LiteralPath $pointer -Raw|ConvertFrom-Json
  $manifest=Get-Content -LiteralPath (Join-Path $pack.Directory 'build-manifest.json') -Raw|ConvertFrom-Json
  if($manifest.NodeVersion -cne $NodeVersion){continue}
  $file=$manifest.Files|Where-Object {$_.File.Replace('/','\') -ceq 'runtime\NODE-LICENSE.txt'}|Select-Object -First 1
  $license=Join-Path $pack.Directory 'runtime\NODE-LICENSE.txt'
  if($file -and (Get-FileHash -LiteralPath $license).Hash -ceq $file.Sha256){Copy-Item -LiteralPath $license -Destination $Destination;Write-Output 'Node license reused from a verified build of the same version.';return}
 }catch{}
}
$previous=[Net.ServicePointManager]::SecurityProtocol
try{[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;Invoke-WebRequest -UseBasicParsing -Uri ('https://raw.githubusercontent.com/nodejs/node/'+$NodeVersion+'/LICENSE') -OutFile $Destination -TimeoutSec 20}
finally{[Net.ServicePointManager]::SecurityProtocol=$previous}
if(-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -lt 1000){throw 'Official Node license download is incomplete.'}
