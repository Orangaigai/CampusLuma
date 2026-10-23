param([string]$Portal='')
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
if(-not (Test-Path -LiteralPath (Join-Path $root 'development.mode'))){throw 'Build trials only from the independent development copy.'}
$sourceRule=Get-Content -LiteralPath (Join-Path $root 'adapters\snnu.json') -Raw -Encoding UTF8|ConvertFrom-Json
$preferredPortal=$sourceRule.fallbackPortal
if($Portal){
    $uri=$null
    if(-not [Uri]::TryCreate($Portal,[UriKind]::Absolute,[ref]$uri) -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
        $uri.GetLeftPart([UriPartial]::Authority) -cnotin $sourceRule.trustedOrigins -or
        $uri.AbsolutePath -cnotin @('/',$sourceRule.researchProfile.loginPage,$sourceRule.researchProfile.loginAction,$sourceRule.researchProfile.statusPage)){
        throw 'Preferred portal must be a registered SNNU page without credentials or session parameters.'
    }
    $preferredPortal=$uri.GetLeftPart([UriPartial]::Authority)+$(if($uri.AbsolutePath -ceq '/'){'/'}else{$sourceRule.researchProfile.loginPage})
}
& (Join-Path $root 'build.ps1')
$name='CampusLuma-SNNU-Trial-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$stage=Join-Path $root ('artifacts\releases\'+$name)
foreach($directory in @('ui','engine','engine\node_modules','scripts','adapters','runtime','data')){$null=New-Item -ItemType Directory -Path (Join-Path $stage $directory) -Force}
foreach($file in @('CampusLuma.exe','CampusLuma.Core.dll','LICENSE','THIRD-PARTY.md')){Copy-Item -LiteralPath (Join-Path $root $file) -Destination $stage}
Copy-Item -LiteralPath (Join-Path $root 'ui\MainWindow.xaml') -Destination (Join-Path $stage 'ui')
foreach($file in @('run-once.ps1','run-hidden.vbs','schedule.ps1')){Copy-Item -LiteralPath (Join-Path $root ('scripts\'+$file)) -Destination (Join-Path $stage 'scripts')}
foreach($file in @('campus-network-reconnect.ps1','campus-auth.ps1','campus-auth-provider.ps1','wifi-scan.ps1','auth-provider.mjs','school-rules.mjs','browser-profile.mjs','snnu-preflight.mjs','snnu-auth.mjs','drcom-profile.mjs','connectivity.mjs')){
    Copy-Item -LiteralPath (Join-Path $root ('engine\'+$file)) -Destination (Join-Path $stage 'engine')
}
foreach($dependency in @('iconv-lite','safer-buffer')){Copy-Item -LiteralPath (Join-Path $root ('engine\node_modules\'+$dependency)) -Destination (Join-Path $stage 'engine\node_modules') -Recurse}
$node=(Get-Command node.exe).Source
$version=(& $node --version).Trim()
if($version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$'){throw 'Invalid Node runtime version.'}
Copy-Item -LiteralPath $node -Destination (Join-Path $stage 'runtime\node.exe')
& (Join-Path $root 'tools\copy-node-license.ps1') -NodeVersion $version -Destination (Join-Path $stage 'runtime\NODE-LICENSE.txt')
[IO.File]::WriteAllText((Join-Path $stage 'development.mode'),'snnu-trial',(New-Object Text.UTF8Encoding($false)))
$rule=Get-Content -LiteralPath (Join-Path $root 'adapters\snnu.json') -Raw -Encoding UTF8|ConvertFrom-Json
$rule.enabled=$true;$rule.verification='仅用于本人校内现场验收，尚未正式验证；普通开发版中的该学校仍保持禁用。'
$rule|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $stage 'adapters\snnu.json') -Encoding UTF8
@{Version=1;Adapter='snnu';School=$rule.name;Ssid='SNNU';Interface='WLAN';Portal=$preferredPortal;Username='';Service=$null;Mode='custom';Start='07:01';End='23:00';IntervalMinutes=120;Times=@('07:01')}|
    ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $stage 'data\settings.json') -Encoding UTF8
@'
@echo off
start "" "%~dp0CampusLuma.exe" --data-directory "%~dp0data"
'@|Set-Content -LiteralPath (Join-Path $stage 'Start-SNNU.cmd') -Encoding ASCII
Copy-Item -LiteralPath (Join-Path $stage 'Start-SNNU.cmd') -Destination (Join-Path $stage '开始测试.cmd')
$readme=@'
# 陕师大校园网自动连接 · 试验版

这是待校内验收的原型，不是正式支持声明。Windows 10/11 x64；已带 Node 运行时，无需另装 Node 或浏览器认证组件。首次使用不会自动启用定时任务。

1. 解压整个文件夹到可写位置，双击“开始测试.cmd”。不要在压缩包内直接运行。
2. 填自己的校园账号、密码，选择实际已开通的校园网/运营商服务；先用“立即连接”测试。
3. 当前 Wi-Fi 应为 SNNU，或它在附近可见。已联网时跳过认证，在家附近没有 SNNU 时退出。
4. 确认真正恢复外网后，再选择自己需要的时间并“保存并启用”。07:01 只是初始示例，不代表已确认学校开网时间。
5. 运行日志及加密凭据在本文件夹 data 中。密码只由当前 Windows 用户解密；不要把自己使用后的整个文件夹转发，分享原始压缩包即可。
6. 遇到验证码时手动认证一次；密码错误后暂停尝试，修改密码或改正服务后重试。门户显示在线但外网不通时会报告异常，不自动下线其他会话。
7. 本版绕过系统代理但不暂停 TUN；首次验收请关闭 TUN。需开机、已登录且不睡眠。
8. 反馈时提供错误码、时间和已选服务即可；不要发密码、Cookie 或原始抓包。`last-auth-result.json` 有脱敏阶段和请求次数。

任务仅使用 CampusLuma Trial-snnu 前缀，与日用版和普通开发版分开。关闭窗口后已启用计划仍有效；移动文件夹前先暂停、移动后重新保存。停用时先点击“暂停”。

学校门户使用 HTTP；本地密码用 DPAPI 加密。软件不替用户办理运营商业务。
'@
if($Portal){$readme+="`r`n`r`n本包已预设优先读取的入口：$preferredPortal 。它只用于获取本次新表单与会话，失效后仍尝试学校根入口发现当前端口。入口由使用者提供，尚未通过校内实际认证，不代表已验证该账号或运营商。`r`n"}
[IO.File]::WriteAllText((Join-Path $stage '使用说明.md'),$readme,(New-Object Text.UTF8Encoding($true)))
$revision=(& git -C $root rev-parse HEAD).Trim()
$files=@(Get-ChildItem -LiteralPath $stage -File -Recurse|ForEach-Object{@{File=$_.FullName.Substring($stage.Length+1);Sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}})
@{BuildTime=(Get-Date).ToString('o');SourceCommit=$revision;Trial=$true;RealCampusVerified=$false;NodeVersion=$version;Files=$files}|
    ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $stage 'build-manifest.json') -Encoding UTF8
$zip=$stage+'.zip'
Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal
@{Directory=$stage;Archive=$zip;Sha256=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash;NodeVersion=$version;PreferredPortal=$preferredPortal;RealCampusVerified=$false}|
    ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'artifacts\snnu-trial-package.json') -Encoding UTF8
Write-Output ('SNNU trial archive: '+$zip)
