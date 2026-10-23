param(
    [AllowNull()][Uri]$PortalUri,
    [Parameter(Mandatory)][System.Management.Automation.PSCredential]$Credential,
    [ValidateSet('authenticate', 'verify_login', 'inspect_self')][string]$Mode = 'authenticate',
    [ValidatePattern('^[0-9A-Fa-f:-]{12,17}$')][string]$TargetMac,
    [string]$DataDirectory = $PSScriptRoot,
    [ValidatePattern('^[a-z][a-z0-9_-]{0,47}$')][string]$SchoolId = 'xtu',
    [AllowNull()][object]$Service = $null,
    [ValidateRange(1,120)][int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$bundledNode=Join-Path (Split-Path $PSScriptRoot -Parent) 'runtime\node.exe'
$node = if(Test-Path -LiteralPath $bundledNode){$bundledNode}else{Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source}
if (-not $node) { return [pscustomobject]@{ Code = 'NODE_NOT_FOUND'; Submitted = $false } }

$request = @{
    schoolId = $SchoolId
    service = if($null -eq $Service){$null}else{[string]$Service}
    username = $Credential.UserName
    password = $Credential.GetNetworkCredential().Password
    mode = $Mode
    targetMac = $TargetMac
    portalUrl = if ($PortalUri) { $PortalUri.AbsoluteUri } else { $null }
    network = if($SchoolId -in @('hnust','hunnu')) {
        try {
            $settingsFile=Join-Path $DataDirectory 'settings.json'
            $configured=Get-Content -LiteralPath $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $adapter=Get-NetAdapter -Name $configured.Interface -ErrorAction Stop | Where-Object { $_.Name -ceq $configured.Interface -and $_.HardwareInterface -and $_.Status -eq 'Up' } | Select-Object -First 1
            if($adapter) {
                $addresses=@(Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(169\.254\.|198\.(18|19)\.|127\.)' })
                if($addresses.Count -eq 1){ @{ipv4=[string]$addresses[0].IPAddress;mac=[string]$adapter.MacAddress} }else{$null}
            } else {$null}
        } catch {$null}
    } else {$null}
} | ConvertTo-Json -Compress

$process = $null
try {
    # Use explicit stdin bytes and redirected streams. PowerShell 5.1 native
    # pipelines can add a BOM or treat harmless OCR stderr warnings as errors.
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $node
    $start.Arguments = '"{0}"' -f (Join-Path $PSScriptRoot 'auth-provider.mjs')
    $start.WorkingDirectory = $PSScriptRoot
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $start.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    $null = $process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($request)
    $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $process.StandardInput.Close()
    # Leave time for Wi-Fi association, connectivity checks and result writing
    # within the enclosing task's three-minute limit.
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $null = & "$env:WINDIR\System32\taskkill.exe" /PID $process.Id /T /F 2>$null
        return [pscustomobject]@{ Code = 'PROVIDER_TIMEOUT'; Submitted = $false }
    }
    $response = $stdoutTask.Result -split '\r?\n' | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1
    if ($process.ExitCode -ne 0 -or -not $response) {
        return [pscustomobject]@{ Code = 'PROVIDER_PROCESS_ERROR' }
    }
    $reply = $response | ConvertFrom-Json
    if ($reply.Code -notmatch '^[A-Z_]+$') {
        return [pscustomobject]@{ Code = 'INVALID_PROVIDER_RESULT' }
    }
    $safeMetadata = @{}
    foreach ($field in @('ErrorType','ErrorStage','ErrorCode')) {
        if ([string]$reply.$field -cmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$') { $safeMetadata[$field] = [string]$reply.$field }
    }
    if ($reply.StartupAttempts -in @(1,2)) { $safeMetadata.StartupAttempts = [int]$reply.StartupAttempts }
    if ($Mode -eq 'authenticate') {
        $savedResult = @{ Time = (Get-Date).ToString('o'); Code = [string]$reply.Code;
           Submitted = [bool]$reply.Submitted; PortalSource = [string]$reply.PortalSource; InternetVerified = [bool]$reply.InternetVerified;
           Phase = [string]$reply.Phase; Requests = [int]$reply.Requests; InternetChecks = [int]$reply.InternetChecks }
        foreach ($field in $safeMetadata.Keys) { $savedResult[$field] = $safeMetadata[$field] }
        $savedResult | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $DataDirectory 'last-auth-result.json') -Encoding UTF8
    }
    $providerResult = @{ Code = [string]$reply.Code; Submitted = [bool]$reply.Submitted; TargetDevice = $reply.TargetDevice }
    foreach ($field in $safeMetadata.Keys) { $providerResult[$field] = $safeMetadata[$field] }
    return [pscustomobject]$providerResult
} catch {
    return [pscustomobject]@{ Code = 'PROVIDER_PROCESS_ERROR' }
} finally {
    if ($null -ne $process) { $process.Dispose() }
    $request = $null
    $bytes = $null
}
