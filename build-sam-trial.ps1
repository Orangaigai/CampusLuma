$ErrorActionPreference='Stop'
$root=$PSScriptRoot
if(-not (Test-Path -LiteralPath (Join-Path $root 'development.mode'))){throw 'Build trials from the independent development copy only.'}
& (Join-Path $root 'build.ps1')
$ids=@('cuit','scit','ysu','uestc-telecom','qlu','dlut-panjin','mnnu-yuanshan')
$name='CampusLuma-SAM-Trial-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)
$stage=Join-Path $root ('artifacts\releases\'+$name)
foreach($directory in @('ui','engine','scripts','adapters','runtime','data')){$null=New-Item -ItemType Directory -Path (Join-Path $stage $directory) -Force}
foreach($file in @('CampusLuma.exe','CampusLuma.Core.dll','LICENSE','THIRD-PARTY.md')){Copy-Item -LiteralPath (Join-Path $root $file) -Destination $stage}
Copy-Item -LiteralPath (Join-Path $root 'ui\MainWindow.xaml') -Destination (Join-Path $stage 'ui')
foreach($file in @('run-once.ps1','run-hidden.vbs','schedule.ps1','collect-campus.ps1')){Copy-Item -LiteralPath (Join-Path $root ('scripts\'+$file)) -Destination (Join-Path $stage 'scripts')}
foreach($file in @('campus-network-reconnect.ps1','campus-auth.ps1','campus-auth-provider.ps1','wifi-scan.ps1','auth-provider.mjs','school-rules.mjs','browser-profile.mjs','browser-service.mjs','browser-entry.mjs','collect-portal.mjs','browser-auth.mjs','snnu-preflight.mjs','drcom-profile.mjs','drcom-auth.mjs','connectivity.mjs')){
    Copy-Item -LiteralPath (Join-Path $root ('engine\'+$file)) -Destination (Join-Path $stage 'engine')
}
# Native robocopy handles long dependency paths. Keep runtime assets and
# licenses; omit upstream test snapshots and native binaries for other OSes.
$modules=Join-Path $root 'engine\node_modules'
& "$env:WINDIR\System32\robocopy.exe" $modules (Join-Path $stage 'engine\node_modules') /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XD '__image_snapshots__' '__tests__' 'test' 'tests' 'fixtures' 'examples' 'docs' (Join-Path $modules 'onnxruntime-node\bin\napi-v3\darwin') (Join-Path $modules 'onnxruntime-node\bin\napi-v3\linux') (Join-Path $modules 'onnxruntime-node\bin\napi-v3\win32\arm64')
if($LASTEXITCODE -gt 7){throw 'Browser/OCR runtime dependency copy failed.'}
$global:LASTEXITCODE=0
foreach($file in @('package.json','package-lock.json')){Copy-Item -LiteralPath (Join-Path $root ('engine\'+$file)) -Destination (Join-Path $stage 'engine')}
$node=(Get-Command node.exe).Source;$version=(& $node --version).Trim()
if($version -notmatch '^v[0-9]+\.[0-9]+\.[0-9]+$'){throw 'Invalid Node version.'}
Copy-Item -LiteralPath $node -Destination (Join-Path $stage 'runtime\node.exe')
& (Join-Path $root 'tools\copy-node-license.ps1') -NodeVersion $version -Destination (Join-Path $stage 'runtime\NODE-LICENSE.txt')
[IO.File]::WriteAllText((Join-Path $stage 'development.mode'),'sam-trial',(New-Object Text.UTF8Encoding($false)))
foreach($id in $ids){
    $r=Get-Content -LiteralPath (Join-Path $root ('adapters\'+$id+'.json')) -Raw -Encoding UTF8|ConvertFrom-Json
    $r.enabled=$true;$r.verification='仅用于本人校内验收的试验包，尚未通过校内真实认证。'
    $r|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $stage ('adapters\'+$id+'.json')) -Encoding UTF8
}
$default=Get-Content -LiteralPath (Join-Path $stage 'adapters\cuit.json') -Raw -Encoding UTF8|ConvertFrom-Json
@{Version=1;Adapter='cuit';School=$default.name;Ssid=$default.defaultSsid;Interface='WLAN';Portal=$default.fallbackPortal;Username='';Service=$null;Mode='custom';Start='07:01';End='23:00';IntervalMinutes=120;Times=@('07:01')}|
    ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $stage 'data\settings.json') -Encoding UTF8
@'
@echo off
start "" "%~dp0CampusLuma.exe" --data-directory "%~dp0data"
'@|Set-Content -LiteralPath (Join-Path $stage 'Start.cmd') -Encoding ASCII
@'
@echo off
echo 1. QLU  2. DLUT-Panjin  3. MNNU-Yuanshan
choice /c 123 /n /m "School: "
if errorlevel 3 (set "school=mnnu-yuanshan") else if errorlevel 2 (set "school=dlut-panjin") else (set "school=qlu")
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\collect-campus.ps1" -SchoolId %school%
pause
'@|Set-Content -LiteralPath (Join-Path $stage 'Collect-Entry.cmd') -Encoding ASCII
@'
# 校园网自动连接 · 新锐捷七校试验版

仅完成公开资料核对和隔离模拟验证，七校均未完成校内真实认证验收。闽南圆山的最新实际网关尚未核实，属于受限原型，请先运行 Collect-Entry.cmd 核对本次入口。

1. Windows 10/11 x64，需要已安装 Microsoft Edge；自带 Node 和认证依赖。解压整个文件夹后打开 Start.cmd。
2. 选择本校及正确校区，填写本人的账号密码、实际 Wi-Fi 名称、已开通的运营商。燕大和电子科大不猜 Wi-Fi 默认名称。
3. 成信大仅航空港；电子科大仅清水河电信（110.184.24.61），不适用于所有 UESTC-WiFi 或宿舍；另含四川工科、燕大、齐鲁工大、大工盘锦和闽南圆山受限原型。齐鲁工大选择“互联网”；大工和闽南没有新增未经证实的运营商选择框。
4. 在校内先点“立即连接”，确认外网和远控实际可用，再设时间并“保存并启用”。07:01 只是示例，各校开网时间尚未确认。首次打开不会创建任务。
5. 到点只执行一次。目标 Wi-Fi 可见时优先连接，外网已可用即结束，无须重复密码认证；附近没有目标 Wi-Fi 时保留现有网络退出。
6. 每次从本校网络获取新入口；只有账号登录页、缺少本次网关跳转时停止，避免把统一身份登录当作联网。运营商只按本人选择精确匹配，找不到或有歧义就停止。
7. 需要电脑开机、已登录且不睡眠。锁屏和熄屏可以。后台 Edge 直连绕过系统代理；首次验收请关闭 TUN，全局加 TUN 尚未通过。
8. 密码仅以本机当前 Windows 用户 DPAPI 加密保存。data 是个人目录，不能转发；反馈仅需脱敏状态码、阶段和时间，不发密码、Cookie、完整认证地址。
9. 使用 CampusLuma Trial-sam 独立任务前缀。点“暂停”停用本包计划。移动目录前先暂停，移动后重新保存。分享原始 ZIP。

本版只做 Wi-Fi 自动连接；不宣称已支持有线网、多物理网卡绑定或任意学校。验证码由原浏览器引擎处理，仍可能识别失败；学校更换统一认证主机或页面时需要更新规则。

大工盘锦通知写 DLUT-PanJin，手册写 DUT-Panjin，以电脑现场显示的名称为准，可修改校园网框。大工旧 172.17.3.10 和闽南旧 10.254.1.12 接口不使用。新三校只在新 Portal/CAS 且本次网关参数完整时认证；发现旧页面或仅有自助登录时停止。闽南现有资料只确认 10.254.1.200 自助地址，不能据此保证圆山新认证网关相同。

Collect-Entry.cmd 不读取密码、不填写账号、不提交登录、不切换 Wi-Fi。先手动连本校 Wi-Fi，选择学校，报告保存到 reports。已联网时不会强制制造掉线；在本人自助平台准备好未认证状态后才能采集未认证入口。报告不含 Cookie、输入值或查询参数值，不代表认证通过。
'@|Set-Content -LiteralPath (Join-Path $stage '使用说明.md') -Encoding UTF8
$revision=(& git -C $root rev-parse HEAD).Trim()
& $node (Join-Path $root 'tools\build-manifest.mjs') $stage $revision $version
if($LASTEXITCODE -ne 0){throw 'Runtime manifest generation failed.'}
$zip=$stage+'.zip';Compress-Archive -LiteralPath $stage -DestinationPath $zip -CompressionLevel Optimal
@{SchoolIds=$ids;Directory=$stage;Archive=$zip;Sha256=(Get-FileHash -LiteralPath $zip).Hash;RealCampusVerified=$false;NodeVersion=$version}|
    ConvertTo-Json|Set-Content -LiteralPath (Join-Path $root 'artifacts\sam-trial-package.json') -Encoding UTF8
Write-Output ('Trial archive: '+$zip)
