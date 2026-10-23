param([AllowNull()][Uri]$PortalUri, [string]$DataDirectory = $PSScriptRoot)
$ErrorActionPreference = 'Stop'
$credentialPath = Join-Path $DataDirectory 'credential.json'
$rejectionPath = Join-Path $DataDirectory 'last-auth-rejection.txt'
if(-not (Test-Path -LiteralPath $credentialPath)) { return [pscustomobject]@{Attempted=$false;Code='CREDENTIAL_NOT_SET'} }
$bytes=$null
try {
    Add-Type -AssemblyName System.Security
    $saved=Get-Content -LiteralPath $credentialPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $settings=Get-Content -LiteralPath (Join-Path $DataDirectory 'settings.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $credentialSchool=if($saved.SchoolId){[string]$saved.SchoolId}else{'xtu'}
    if($credentialSchool -cne $settings.Adapter) { return [pscustomobject]@{Attempted=$false;Code='CREDENTIAL_SCHOOL_MISMATCH'} }
    if($settings.Username -cne $saved.Username) { return [pscustomobject]@{Attempted=$false;Code='CREDENTIAL_ACCOUNT_MISMATCH'} }
    if((Test-Path -LiteralPath $rejectionPath) -and (Get-Item -LiteralPath $rejectionPath).LastWriteTimeUtc -ge
        (Get-Item -LiteralPath $credentialPath).LastWriteTimeUtc) {
        $paused=$null
        try { $paused=Get-Content -LiteralPath $rejectionPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        if($null -eq $paused -or $paused.Marker -ne 'CredentialRejected' -or [object]::Equals($paused.Service,$settings.Service)) {
            return [pscustomobject]@{Attempted=$false;Code='LOGIN_BLOCKED_AFTER_REJECTION'}
        }
    }
    $bytes=[Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($saved.PasswordCipher),
        [Text.Encoding]::UTF8.GetBytes('CampusLuma/v1'),[Security.Cryptography.DataProtectionScope]::CurrentUser)
    $secure=ConvertTo-SecureString ([Text.Encoding]::UTF8.GetString($bytes)) -AsPlainText -Force
    $credential=New-Object System.Management.Automation.PSCredential($saved.Username,$secure)
    $reply=& (Join-Path $PSScriptRoot 'campus-auth-provider.ps1') -PortalUri $PortalUri -Credential $credential -DataDirectory $DataDirectory -SchoolId $settings.Adapter -Service $settings.Service
    if($reply.Code -eq 'LOGIN_REJECTED') { @{Marker='CredentialRejected';Service=$settings.Service} | ConvertTo-Json | Set-Content -LiteralPath $rejectionPath -Encoding UTF8 }
    $authResult = @{Attempted=[bool]$reply.Submitted;Code=[string]$reply.Code}
    foreach($field in @('ErrorType','ErrorStage','ErrorCode','StartupAttempts')) {
        if($null -ne $reply.$field) { $authResult[$field]=$reply.$field }
    }
    return [pscustomobject]$authResult
} catch { return [pscustomobject]@{Attempted=$false;Code='CREDENTIAL_OR_PROVIDER_ERROR'} }
finally { if($bytes) { [Array]::Clear($bytes,0,$bytes.Length) } }
