$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Add-Type -AssemblyName System.IO.Compression.FileSystem
$results=foreach($id in @('snnu','hnust','hunnu','sam')){
    $pack=Get-Content -LiteralPath (Join-Path $root ('artifacts\'+$id+'-trial-package.json')) -Raw|ConvertFrom-Json
    if((Get-FileHash -LiteralPath $pack.Archive).Hash -cne $pack.Sha256){throw ($id+' archive hash mismatch.')}
    $archive=[IO.Compression.ZipFile]::OpenRead($pack.Archive)
    try {
        $prefix=[IO.Path]::GetFileName($pack.Directory)+'/'
        $entries=New-Object 'Collections.Generic.Dictionary[string,IO.Compression.ZipArchiveEntry]' ([StringComparer]::Ordinal)
        foreach($item in $archive.Entries){$key=$item.FullName.Replace('\','/');if($entries.ContainsKey($key)){throw 'Duplicate normalized ZIP path.'};$entries.Add($key,$item)}
        $entry=$entries[$prefix+'build-manifest.json'];if(-not $entry){throw 'Archive manifest missing.'}
        $reader=New-Object IO.StreamReader($entry.Open());try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}
        foreach($file in $manifest.Files){
            $entry=$entries[$prefix+$file.File.Replace('\','/')];if(-not $entry){throw ('Archive runtime file missing: '+$file.File)}
            $stream=$entry.Open();$sha=[Security.Cryptography.SHA256]::Create()
            try{$actual=[BitConverter]::ToString($sha.ComputeHash($stream)).Replace('-','')}finally{$stream.Dispose();$sha.Dispose()}
            if($actual -cne $file.Sha256){throw ('Archive content mismatch: '+$file.File)}
        }
        $files=@($archive.Entries|Where-Object {$_.FullName -notmatch '[\\/]$'})
        if($files.Count -ne $manifest.Files.Count+1){throw ($id+' archive contains unexpected or missing files.')}
        if($manifest.RealCampusVerified){throw 'Prototype archive incorrectly claims campus acceptance.'}
        [pscustomobject]@{Id=$id;Passed=$true;Archive=$pack.Archive;Sha256=$pack.Sha256;Files=$files.Count;MiB=[Math]::Round((Get-Item -LiteralPath $pack.Archive).Length/1MB,1);SourceCommit=$manifest.SourceCommit;RealCampusVerified=$false}
        Write-Host ('PASS actual ZIP contents and hashes: '+$id)
    }finally{$archive.Dispose()}
}
$results|ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $root 'artifacts\four-release-zip-check.json') -Encoding UTF8
