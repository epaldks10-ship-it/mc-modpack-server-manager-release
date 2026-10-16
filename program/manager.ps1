# Modpack server manager GUI. Started by 모드팩서버관리.exe in the package root, which runs it without a console window.
# Tabs: my servers (the server runs inside this window), new server (install.ps1 runs hidden, output shown here), manual.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, Microsoft.VisualBasic
Add-Type -AssemblyName System.IO.Compression.FileSystem
[Windows.Forms.Application]::EnableVisualStyles()
# There is no console, so every error has to reach the user as a dialog (and a log line for whoever helps them)
$ErrLog = Join-Path $PSScriptRoot 'logs\manager-errors.txt'
function Write-ErrLog($msg) {
    try { New-Item -ItemType Directory -Force (Split-Path $ErrLog -Parent) | Out-Null; Add-Content -LiteralPath $ErrLog -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $msg" -Encoding UTF8 } catch { }
}
function Show-Msg($text, $icon = 'Information') { [void][Windows.Forms.MessageBox]::Show($text, '모드팩 서버 관리', 'OK', $icon) }
trap { Write-ErrLog "$($_.Exception.Message) $($_.ScriptStackTrace)"; Show-Msg "프로그램 오류: $($_.Exception.Message)" 'Error'; exit 1 }
# Errors inside button handlers would otherwise vanish and the button would just seem dead
[Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')
[Windows.Forms.Application]::add_ThreadException({
        param($s, $e)
        Write-ErrLog "$($e.Exception.Message) $($e.Exception.StackTrace)"
        Show-Msg "문제가 생겼어요: $($e.Exception.Message)`n`n(기록: _program\logs\manager-errors.txt)" 'Error'
    })

# One window at a time: a second copy would mistake the first one's server for a leftover and try to stop it
$mutexName = 'Local\mcsm-' + ([BitConverter]::ToString((New-Object Security.Cryptography.SHA1Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($PSScriptRoot.ToLower()))) -replace '-', '').Substring(0, 16)
$created = $false
$script:instanceMutex = New-Object Threading.Mutex($true, $mutexName, [ref]$created)
if (-not $created) {
    [void][Windows.Forms.MessageBox]::Show("모드팩 서버 관리 프로그램이 이미 열려 있어요.`n작업 표시줄에서 열려 있는 창을 찾아 주세요.", '모드팩 서버 관리', 'OK', 'Information')
    exit 0
}

function Invoke-Api([string]$Url, [int]$TimeoutSec = 20, [string]$Method = 'Get', $Body = $null) {
    # Every web call gets a time limit, so a slow connection can't freeze the window for minutes.
    # Piping through ForEach-Object unrolls JSON arrays, which Windows PowerShell 5.1 otherwise hands over as one object.
    if ($Body) { return (Invoke-RestMethod -Uri $Url -Method $Method -TimeoutSec $TimeoutSec -ContentType 'application/json' -Body $Body | ForEach-Object { $_ }) }
    return (Invoke-RestMethod -Uri $Url -Method $Method -TimeoutSec $TimeoutSec | ForEach-Object { $_ })
}
function Get-WebBytes([string]$Url, [int]$TimeoutMs = 8000) {
    $req = [Net.HttpWebRequest]::Create($Url); $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
    $resp = $req.GetResponse()
    try { $ms = New-Object IO.MemoryStream; $resp.GetResponseStream().CopyTo($ms); return , $ms.ToArray() } finally { $resp.Close() }
}

# Runs a console program without a window and collects its output on background threads.
# PowerShell script blocks can't run on those threads, so the UI timer drains the queue instead.
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Collections.Concurrent;
using System.Text;
public class McProc {
    public Process P;
    public ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    public McProc(string exe, string args, string workDir, int codePage) {
        var psi = new ProcessStartInfo(exe, args);
        psi.WorkingDirectory = workDir; psi.UseShellExecute = false; psi.CreateNoWindow = true;
        psi.RedirectStandardInput = true; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.GetEncoding(codePage);
        psi.StandardErrorEncoding = Encoding.GetEncoding(codePage);
        P = new Process(); P.StartInfo = psi;
        P.OutputDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
        P.ErrorDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
        // .NET Framework builds the stdin writer from Console.InputEncoding and, for UTF-8, writes a BOM
        // that the server reads as a bogus "?" command. The ANSI code page has no BOM and is what Java reads.
        Encoding old = null;
        try { old = Console.InputEncoding; Console.InputEncoding = Encoding.Default; } catch { }
        try { P.Start(); } finally { try { if (old != null) Console.InputEncoding = old; } catch { } }
        P.BeginOutputReadLine(); P.BeginErrorReadLine();
    }
    public void Send(string line) {
        try { P.StandardInput.Write(line + "\n"); P.StandardInput.Flush(); } catch { }
    }
    public bool Running { get { try { return !P.HasExited; } catch { return false; } } }
    public int Code { get { try { return P.HasExited ? P.ExitCode : -999; } catch { return -999; } } }
    public void Kill() { try { if (!P.HasExited) P.Kill(); } catch { } }
}
'@

$Prog = $PSScriptRoot
$Root = Split-Path $Prog -Parent
$ServersDir = Join-Path $Root 'servers'
$GameRoot = Join-Path $Root 'game'       # game (client) folders the official launcher plays from
$PlayitDir = Join-Path $Prog 'playit'
$PlayitKeyFile = Join-Path $PlayitDir 'secret-key.dpapi'      # encrypted for this Windows user on this PC
$PlayitKeyPlain = Join-Path $PlayitDir 'secret-key.txt'       # older plain-text form, converted on first start
Add-Type -AssemblyName System.Security
$KeyEntropy = [Text.Encoding]::UTF8.GetBytes('mcsm-playit')
$PlayitLog = Join-Path $PlayitDir 'playit.log'
$PlayitAddrFile = Join-Path $PlayitDir 'address.txt'          # the address friends type in; not a secret
$Cp949 = [Text.Encoding]::GetEncoding(949)
$Utf8 = New-Object Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force $ServersDir | Out-Null

# ---------------- program self-update from the public release repo ----------------
# Development happens in a private repo; only releases are pushed here (see _dev\release.ps1).
$UpdateBase = 'https://raw.githubusercontent.com/epaldks10-ship-it/mc-modpack-server-manager-release/main'
$UpdatableFiles = @('manager.ps1', 'install.ps1', 'packs.json', 'client-only-mods.txt', 'manual.html', 'version.txt')
# Later releases may add program files; the manifest is signed, so any plain file name of these kinds is accepted
function Test-UpdatableFile([string]$path) { return ($path -in $UpdatableFiles) -or ($path -match '^[A-Za-z0-9_-]+\.(ps1|json|txt|html)$') }
$AppVersion = '0.0.0'
$vf = Join-Path $Prog 'version.txt'; if (Test-Path -LiteralPath $vf) { $AppVersion = ([IO.File]::ReadAllText($vf)).Trim() }
# Releases are signed with a key that lives only on the developer's PC (%APPDATA%\mcsm-release), never on GitHub,
# so a hijacked GitHub account still cannot push a fake update to anyone.
$UpdatePublicKey = '<RSAKeyValue><Modulus>wXz1yU+YDIoKe4S680x7saNhbFzm4qbt3MF2upIthdWQ5iq5MGc8LZcUD0v1hKDAuCIKZL6J/zYnP27olo/ZwSVF7aMaAPZ4itpysxc+Tg+e38rtmh+yqdnZP7XVNVpFw6x+mE5nOqIHzaljzaNT9HuOA2OnN7bVbM8IuCC9t6qUzAi8fFyyzhT1LTUduLaEg1WclRthX42nQqtl1FlENFR2a4BxCc3bmoH1rOxX1LViTsyzySX/83u1MnNpASaPZt0bERHL/Ed7F/Jd3xU6PeoX86tqYjxhgeya2eYaWnc/Wn1GL7mP8u9DksBsu0I2tp9DqBnG7/CfC8jYz2TFpPA+CwJzVsLsvlf7O6G4E8GR5FqfuZcuJNUO9AXnT7CFqwCPNiDWO5FkKLo6Y3IkwXyYnK4lDImfc1BMYLNDpxvDuUM2epao4vMsW3DY+3qFI8OdSg5ieT1oNessB0b4JeOfrZFEjeD+43zKWmH7bCCFIOqXj1uvYPF216yCiCxh</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'
$script:launcherUpdated = $false
function Update-Launcher($remote, $wc) {
    # The launcher sits outside "files": versions before 1.0.3 refuse a manifest that lists a file they don't know.
    # It is checked on every start, so PCs that update from an old version still get it on the next run.
    $l = $remote.launcher
    if (-not $l -or $l.path -ne 'launcher.exe' -or -not $l.sha256) { return }
    $exe = Join-Path $Root '모드팩서버관리.exe'
    $want = ([string]$l.sha256).ToUpper()
    if ((Test-Path -LiteralPath $exe) -and (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash -eq $want) { return }
    $tmp = "$exe.download"; $old = "$exe.old"
    try { $wc.DownloadFile("$UpdateBase/program/launcher.exe", $tmp) } catch { return }
    if ((Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash -ne $want) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; return }
    try {
        # Renaming works even while Windows still holds the old file, so swap by renaming
        if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $exe) { Move-Item -LiteralPath $exe -Destination $old -Force }
        Move-Item -LiteralPath $tmp -Destination $exe -Force
        Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
        $script:launcherUpdated = $true
    }
    catch {
        if (-not (Test-Path -LiteralPath $exe) -and (Test-Path -LiteralPath $old)) { Move-Item -LiteralPath $old -Destination $exe -Force }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}
function Invoke-SelfUpdate {
    # Returns $true when newer program files were installed and the manager should restart
    if ($env:MCSM_NO_UPDATE) { return $false }
    try {
        # Short time limit: an offline PC should open the program right away, not after a long wait
        $bytes = Get-WebBytes "$UpdateBase/version.json" 5000
        $sig = [Convert]::FromBase64String(([Text.Encoding]::ASCII.GetString((Get-WebBytes "$UpdateBase/version.json.sig" 5000))).Trim())
    }
    catch { return $false }   # offline or nothing released yet: run as is
    $wc = New-Object Net.WebClient
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.FromXmlString($UpdatePublicKey)
    if (-not $rsa.VerifyData($bytes, 'SHA256', $sig)) { return $false }   # not signed by us: ignore it
    try { $remote = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json } catch { return $false }
    Update-Launcher $remote $wc
    try { if ([version]$remote.version -le [version]$AppVersion) { return $false } } catch { return $false }
    $stage = Join-Path $Prog 'update-staging'
    New-Item -ItemType Directory -Force $stage | Out-Null
    foreach ($f in $remote.files) {
        # Only known program files, and only if every one arrives intact; otherwise nothing changes
        if (-not (Test-UpdatableFile $f.path)) { return $false }
        $dst = Join-Path $stage $f.path
        try { $wc.DownloadFile("$UpdateBase/program/$($f.path)", $dst) } catch { return $false }
        if ((Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash -ne ([string]$f.sha256).ToUpper()) { return $false }
    }
    foreach ($f in $remote.files) { Copy-Item -LiteralPath (Join-Path $stage $f.path) -Destination (Join-Path $Prog $f.path) -Force }
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText((Join-Path $Prog 'updated-notice.txt'), "$AppVersion → $($remote.version)`r`n`r`n$($remote.notes)", $Utf8)
    return $true
}
$updated = Invoke-SelfUpdate
# Packages from before the launcher existed still have the .bat; once the .exe is here, retire the .bat
$legacyBat = Join-Path $Root '모드팩서버관리.bat'
$script:retiredBat = $false
if ((Test-Path -LiteralPath (Join-Path $Root '모드팩서버관리.exe')) -and (Test-Path -LiteralPath $legacyBat)) {
    try {
        $keep = Join-Path $Prog 'old-launcher'; New-Item -ItemType Directory -Force $keep | Out-Null
        Move-Item -LiteralPath $legacyBat -Destination $keep -Force
        $script:retiredBat = $true
    }
    catch { }
}
if ($updated) {
    # Restart through the launcher so the new version also opens without a console window
    $script:instanceMutex.ReleaseMutex(); $script:instanceMutex.Dispose()
    $exe = Join-Path $Root '모드팩서버관리.exe'
    if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe }
    else { Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $Prog 'manager.ps1')`"" }
    exit 0
}

$packs = @((Get-Content (Join-Path $Prog 'packs.json') -Raw -Encoding UTF8 | ConvertFrom-Json).packs)
$totalRam = [int][math]::Floor((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$font = New-Object Drawing.Font('Malgun Gothic', 10)
$bold = New-Object Drawing.Font('Malgun Gothic', 13, [Drawing.FontStyle]::Bold)
$big = New-Object Drawing.Font('Malgun Gothic', 16, [Drawing.FontStyle]::Bold)
$mono = New-Object Drawing.Font('Consolas', 9)

function New-Ctl($type, $x, $y, $w, $h, $text = '') {
    $c = New-Object "Windows.Forms.$type"
    $c.Location = New-Object Drawing.Point($x, $y); $c.Size = New-Object Drawing.Size($w, $h)
    if ($text) { $c.Text = $text }
    $c.Font = $font
    return $c
}
function Open-Url($u) { Start-Process $u }
function Ask-YesNo($text) { return [Windows.Forms.MessageBox]::Show($text, '모드팩 서버 관리', 'YesNo', 'Question') -eq 'Yes' }
function Ask-Text($prompt, $default = '') { return [Microsoft.VisualBasic.Interaction]::InputBox($prompt, '모드팩 서버 관리', $default) }
function Pump($ms) { $sw = [Diagnostics.Stopwatch]::StartNew(); while ($sw.ElapsedMilliseconds -lt $ms) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 30 } }

function Read-Json($path) { if (Test-Path -LiteralPath $path) { return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } return $null }
function Write-Json($path, $obj) { [IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 6), $Utf8) }
function Set-InfoField($dir, $key, $value) {
    $p = Join-Path $dir 'server-info.json'
    $i = Read-Json $p; if (-not $i) { $i = [pscustomobject]@{} }
    $i | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force
    Write-Json $p $i
}

$form = New-Object Windows.Forms.Form
$form.Text = "마인크래프트 모드팩 서버 관리  v$AppVersion"
$form.Size = New-Object Drawing.Size(1010, 720)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false
$form.Font = $font

$tabs = New-Object Windows.Forms.TabControl
$tabs.Location = New-Object Drawing.Point(10, 10); $tabs.Size = New-Object Drawing.Size(975, 660)
$tabMy = New-Object Windows.Forms.TabPage; $tabMy.Text = '  내 서버  '
$tabNew = New-Object Windows.Forms.TabPage; $tabNew.Text = '  새 서버 만들기  '
$tabJoin = New-Object Windows.Forms.TabPage; $tabJoin.Text = '  친구 서버 들어가기  '
$tabHelp = New-Object Windows.Forms.TabPage; $tabHelp.Text = '  사용 설명서  '
$tabs.TabPages.AddRange(@($tabMy, $tabNew, $tabJoin, $tabHelp))
$form.Controls.Add($tabs)

# =====================================================================================
# Tab: new server
# =====================================================================================
$lblPick = New-Ctl Label 10 10 260 22 '① 모드팩을 고르세요'
$lstPacks = New-Ctl ListBox 10 35 290 540
foreach ($p in $packs) { [void]$lstPacks.Items.Add($p.name) }

$lblName = New-Ctl Label 320 35 630 28; $lblName.Font = $bold
$lblDesc = New-Ctl Label 320 68 630 48
$lblInfo = New-Ctl Label 320 118 630 22; $lblInfo.ForeColor = [Drawing.Color]::DimGray
$lnkPage = New-Ctl LinkLabel 320 142 630 22 '모드팩 페이지 열기 (친구들도 여기서 받아요)'

$lblVer = New-Ctl Label 320 185 630 22 '② 버전을 고르세요 (친구들과 같은 버전이어야 해요)'
$cmbVer = New-Ctl ComboBox 320 210 630 28; $cmbVer.DropDownStyle = 'DropDownList'

$lblSrv = New-Ctl Label 320 255 630 22 '③ 서버 이름 (영어/숫자만, 폴더 이름이 돼요)'
$txtName = New-Ctl TextBox 320 280 420 28

$lblRam = New-Ctl Label 320 325 630 22 "④ 서버 메모리(램) GB  -  이 컴퓨터 램: 약 ${totalRam}GB"
$numRam = New-Ctl NumericUpDown 320 350 80 28
$numRam.Minimum = 2; $numRam.Maximum = [Math]::Max(2, $totalRam - 2)
$lblRamHint = New-Ctl Label 410 352 540 40 '이 컴퓨터에서 게임도 같이 하면 너무 높이지 마세요.'; $lblRamHint.ForeColor = [Drawing.Color]::DimGray

$chkEula = New-Ctl CheckBox 320 400 420 26 '마인크래프트 이용약관(EULA)에 동의합니다'
$lnkEula = New-Ctl LinkLabel 745 404 150 22 '약관 보기'

$btnInstall = New-Ctl Button 320 440 260 48 '서버 만들기'
$btnInstall.Font = $bold
$lblWork = New-Ctl Label 595 440 360 50 ''; $lblWork.ForeColor = [Drawing.Color]::DarkGreen
$txtInstallLog = New-Ctl TextBox 320 497 630 118
$txtInstallLog.Multiline = $true; $txtInstallLog.ReadOnly = $true; $txtInstallLog.ScrollBars = 'Vertical'; $txtInstallLog.Font = $mono
$txtInstallLog.BackColor = [Drawing.Color]::White

$tabNew.Controls.AddRange(@($lblPick, $lstPacks, $lblName, $lblDesc, $lblInfo, $lnkPage, $lblVer, $cmbVer, $lblSrv, $txtName,
        $lblRam, $numRam, $lblRamHint, $chkEula, $lnkEula, $btnInstall, $lblWork, $txtInstallLog))

$script:versions = @()

function ConvertTo-SafeName([string]$s) {
    # "Create+" -> "CreatePlus", "COBBLEVERSE - Pokemon" -> "COBBLEVERSE-Pokemon", "v37 HF" -> "v37-HF"
    $s = $s -replace '\[.*?\]|\(.*?\)', '' -replace '\+', 'Plus' -replace '[^A-Za-z0-9 ._-]', ' '
    return (($s.Trim() -replace '[\s_-]+', '-') -replace '\.+$', '').Trim('-')
}
function Get-DefaultName($p, [string]$versionLabel) {
    $n = ConvertTo-SafeName $p.name
    if ($versionLabel) { $n = "$n-$(ConvertTo-SafeName $versionLabel)" }
    if ($n.Length -gt 60) { $n = $n.Substring(0, 60).TrimEnd('-', '.') }
    return $n
}
function Test-ServerName([string]$name) {
    # Letters/digits/space/._- ; must not end in a dot or space (Windows drops them) or be a reserved device name
    if ($name -notmatch '^[A-Za-z0-9]([A-Za-z0-9 ._-]{0,58}[A-Za-z0-9_-])?$') { return $false }
    if (($name -split '\.')[0].Trim() -match '^(?i)(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') { return $false }
    return $true
}

function Get-Versions($p) {
    if ($p.source -eq 'curseforge') {
        return @($p.versions | ForEach-Object { [pscustomobject]@{ key = $_.label; label = $_.label; text = "$($_.label)   (마크 $($p.mc), $($_.date), $([math]::Round($_.size / 1GB, 1))GB)" } })
    }
    $vs = @(Invoke-Api "https://api.modrinth.com/v2/project/$($p.slug)/version")
    return @($vs | Where-Object { ($_.loaders | Where-Object { $_ -in 'forge', 'neoforge', 'fabric' }) -and ($_.game_versions | Where-Object { $_ -notmatch '^1\.(1[0-6]|[0-9])(\.|$)' }) } |
        Select-Object -First 20 | ForEach-Object {
            $tag = ''; if ($_.version_type -ne 'release') { $tag = " [$($_.version_type) 테스트판]" }
            [pscustomobject]@{ key = $_.id; label = $_.version_number; text = "$($_.version_number)$tag   (마크 $($_.game_versions -join ','), $($_.loaders -join ','), $($_.date_published.Substring(0, 10)))" }
        })
}

$lstPacks.Add_SelectedIndexChanged({
        $p = $packs[$lstPacks.SelectedIndex]
        $lblName.Text = $p.name
        $lblDesc.Text = $p.desc
        $src = 'CurseForge'; if ($p.source -eq 'modrinth') { $src = 'Modrinth' }
        $lblInfo.Text = "출처: $src   |   권장 서버 램: $($p.ramGB)GB"
        $numRam.Value = [Math]::Min($numRam.Maximum, [Math]::Max($numRam.Minimum, $p.ramGB))
        $cmbVer.Items.Clear(); $cmbVer.Items.Add('버전 목록 불러오는 중...') | Out-Null; $cmbVer.SelectedIndex = 0
        $form.Refresh()
        try { $script:versions = Get-Versions $p } catch { $script:versions = @(); Show-Msg "버전 목록을 불러오지 못했어요. 인터넷 연결을 확인하세요.`n$($_.Exception.Message)" 'Warning' }
        $cmbVer.Items.Clear()
        foreach ($v in $script:versions) { [void]$cmbVer.Items.Add($v.text) }
        $txtName.Text = Get-DefaultName $p ''
        if ($cmbVer.Items.Count) { $cmbVer.SelectedIndex = 0 }   # fires the handler below, which adds the version
    })
$cmbVer.Add_SelectedIndexChanged({
        if ($lstPacks.SelectedIndex -lt 0 -or $cmbVer.SelectedIndex -lt 0 -or $cmbVer.SelectedIndex -ge $script:versions.Count) { return }
        $txtName.Text = Get-DefaultName $packs[$lstPacks.SelectedIndex] $script:versions[$cmbVer.SelectedIndex].label
    })
$lnkPage.Add_LinkClicked({ if ($lstPacks.SelectedIndex -ge 0) { Open-Url $packs[$lstPacks.SelectedIndex].page } })
$lnkEula.Add_LinkClicked({ Open-Url 'https://aka.ms/MinecraftEULA' })

$script:installProc = $null   # McProc running install.ps1 without any window
$script:statusFile = ''
$script:installLast = ''
$installTimer = New-Object Windows.Forms.Timer; $installTimer.Interval = 400
$installTimer.Add_Tick({
        $p = $script:installProc; if (-not $p) { return }
        $sb = New-Object Text.StringBuilder; $line = $null
        while ($p.Lines.TryDequeue([ref]$line)) {
            $t = $line.TrimEnd()
            if (-not $t.Trim()) { continue }
            [void]$sb.Append($t).Append("`r`n"); $script:installLast = $t.Trim()
            # The reason, not whatever footer line came last, is what the user needs to see
            if ($t -match '설치 실패:\s*(.+)$') { $script:installErr = $Matches[1].Trim() }
        }
        $kind = $script:jobKind
        if ($sb.Length) {
            if ($kind -eq 'join') { $txtJoinLog.AppendText($sb.ToString()) }
            elseif ($kind -eq 'game') { if (-not $script:srv) { $txtConsole.AppendText($sb.ToString()) } }
            else { $txtInstallLog.AppendText($sb.ToString()) }
            if ($kind -eq 'update') { $txtConsole.AppendText($sb.ToString()) }
        }
        $head = '설치 중이에요. 프로그램을 닫지 마세요.'; if ($kind -eq 'update') { $head = '모드팩 업데이트 중이에요. 프로그램을 닫지 마세요.' }
        if ($kind -in 'game', 'join') { $head = '게임 준비 중이에요. (처음엔 몇 분 걸려요)' }
        if ($p.Running) {
            if ($kind -eq 'join') { $lblJoinWork.Text = "$head`n$($script:installLast)" }
            elseif ($kind -eq 'game') { $lblStage.Text = "$head  $($script:installLast)" }
            else { $lblWork.Text = "$head`n$($script:installLast)" }
            if ($kind -eq 'update') { $lblStage.Text = "$head  $($script:installLast)" }
            return
        }
        if (-not $p.Lines.IsEmpty) { return }
        $installTimer.Stop()
        $ok = (Test-Path $script:statusFile) -and ((Get-Content $script:statusFile -Raw).Trim() -eq 'ok')
        Remove-Item $script:statusFile -ErrorAction SilentlyContinue
        $script:installProc = $null
        $btnInstall.Enabled = $true
        if (-not $script:srv) { $btnStart.Enabled = $true; $btnLocal.Enabled = $true }
        $script:updCache = @{}
        $btnPlay.Enabled = $true; $btnJoin.Enabled = $true; $btnJoinAgain.Enabled = $true
        if ($kind -in 'game', 'join') { Complete-GameJob $ok; return }
        if ($script:jobKind -eq 'update') {
            if ($ok) { $lblStage.Text = '모드팩 업데이트가 끝났어요. 친구들에게도 새 버전으로 업데이트하라고 알려 주세요.'; $lblWork.Text = '' }
            else { $lblStage.Text = "업데이트에 실패했어요. 서버는 예전 버전 그대로예요. 이유: $($script:installErr)" }
            Update-Servers; Show-SrvInfo
        }
        elseif ($ok) { $lblWork.ForeColor = [Drawing.Color]::DarkGreen; $lblWork.Text = '완료! [내 서버] 탭을 확인하세요.'; Update-Servers; $tabs.SelectedTab = $tabMy }
        else { $lblWork.ForeColor = [Drawing.Color]::Firebrick; $lblWork.Text = "설치에 실패했어요. 이유: $($script:installErr)`n인터넷을 확인하고 같은 이름으로 다시 해 보세요." }
    })
function Stop-InstallJob {
    # Ends install.ps1 together with the curl / Java installer it started; the leftover folder is cleaned on next start
    $p = $script:installProc; if (-not $p) { return }
    & taskkill.exe /T /F /PID $p.P.Id 2>$null | Out-Null
    $script:installProc = $null; $installTimer.Stop()
}

$btnInstall.Add_Click({
        if ($lstPacks.SelectedIndex -lt 0) { Show-Msg '먼저 왼쪽에서 모드팩을 고르세요.'; return }
        if ($cmbVer.SelectedIndex -lt 0 -or -not $script:versions.Count) { Show-Msg '버전을 고르세요.'; return }
        $name = $txtName.Text.Trim()
        if (-not (Test-ServerName $name)) { Show-Msg "서버 이름은 영어, 숫자, 띄어쓰기, - _ . 만 쓸 수 있어요.`n(점으로 끝나거나 CON, NUL 같은 Windows 예약어는 안 돼요)"; return }
        $target = Join-Path $ServersDir $name
        if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath (Join-Path $target '.installing'))) { Show-Msg "'$name' 서버가 이미 있어요. 다른 이름을 써 주세요."; return }
        if (-not $chkEula.Checked) {
            if (-not (Ask-YesNo "이용약관(EULA)에 동의하지 않으면 서버가 켜지지 않아요.`n그래도 계속할까요?")) { return }
        }
        $p = $packs[$lstPacks.SelectedIndex]
        $v = $script:versions[$cmbVer.SelectedIndex]
        $extra = ''; if ($chkEula.Checked) { $extra = ' -AcceptEula' }
        Start-InstallJob "-PackId $($p.id) -VersionKey `"$($v.key)`" -Name `"$name`" -RamGB $([int]$numRam.Value)$extra" 'install'
    })

function Start-InstallJob([string]$installArgs, [string]$kind) {
    # install.ps1 runs hidden inside this program; its output shows in the log box and a status file reports the result
    if ($script:installProc) { Show-Msg '다른 설치나 업데이트가 진행 중이에요. 끝난 다음에 해 주세요.'; return }
    $script:jobKind = $kind; $script:installLast = ''; $script:installErr = '(아래 기록을 확인하세요)'
    $script:statusFile = Join-Path $env:TEMP "mcserver-install-$([guid]::NewGuid().ToString('N')).txt"
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Prog 'install.ps1')`" $installArgs -StatusFile `"$script:statusFile`" -NoPause"
    if ($kind -eq 'join') { $txtJoinLog.Clear() } elseif ($kind -ne 'game') { $txtInstallLog.Clear() }
    if ($kind -eq 'update' -or ($kind -eq 'game' -and -not $script:srv)) { $txtConsole.Clear() }
    $script:installProc = New-Object McProc('powershell.exe', $argLine, $Prog, [Text.Encoding]::Default.CodePage)
    $btnInstall.Enabled = $false; $btnUpdate.Enabled = $false; $btnStart.Enabled = $false; $btnLocal.Enabled = $false
    $btnPlay.Enabled = $false; $btnJoin.Enabled = $false; $btnJoinAgain.Enabled = $false
    if ($kind -eq 'join') { $lblJoinWork.ForeColor = [Drawing.Color]::DarkGreen; $lblJoinWork.Text = '준비 중...' }
    elseif ($kind -eq 'game') { $lblStage.Text = '게임 준비 중...' }
    else { $lblWork.ForeColor = [Drawing.Color]::DarkGreen; $lblWork.Text = '준비 중...' }
    $installTimer.Start()
}

# ---------------- modpack updates ----------------
$script:updCache = @{}
function Get-UpdateTarget($i) {
    # Newest release of the same pack for the same Minecraft version and loader, if it is newer than the installed one
    $p = $packs | Where-Object { $_.id -eq $i.pack } | Select-Object -First 1
    if (-not $p) { return $null }
    $ck = "$($i.pack)|$($i.mc)|$($i.loader)"
    if (-not $script:updCache.ContainsKey($ck)) {
        $list = @()
        if ($p.source -eq 'curseforge') {
            if ($p.mc -eq $i.mc) { $list = @($p.versions | ForEach-Object { @{ key = $_.label; label = $_.label } }) }
        }
        else {
            $vs = @(Invoke-Api "https://api.modrinth.com/v2/project/$($p.slug)/version" | ForEach-Object { $_ })
            $list = @($vs | Where-Object { $_.game_versions -contains $i.mc -and $_.loaders -contains $i.loader -and $_.version_type -eq 'release' } | ForEach-Object { @{ key = $_.id; label = $_.version_number } })
        }
        $script:updCache[$ck] = $list   # newest first
    }
    $list = @($script:updCache[$ck])
    if (-not $list.Count) { return $null }
    $at = -1; for ($k = 0; $k -lt $list.Count; $k++) { if ($list[$k].label -eq $i.version) { $at = $k; break } }
    if ($at -eq 0) { return $null }
    return $list[0]
}
function Update-UpdateButton {
    $btnUpdate.Tag = $null; $btnUpdate.Text = '모드팩 업데이트 확인'; $btnUpdate.BackColor = [Drawing.SystemColors]::Control; $btnUpdate.UseVisualStyleBackColor = $true; $btnUpdate.Enabled = $false
    $d = Get-SelDir; if (-not $d) { return }
    $i = Read-Json (Join-Path $d 'server-info.json'); if (-not $i -or -not $i.pack) { return }
    try { $t = Get-UpdateTarget $i } catch { $btnUpdate.Text = '업데이트 확인 실패 (인터넷 확인)'; return }
    if ($t) {
        $btnUpdate.Text = "모드팩 업데이트: $($t.label) 있음!"; $btnUpdate.BackColor = [Drawing.Color]::Gold; $btnUpdate.Tag = $t
        $btnUpdate.Enabled = -not $script:srv -and -not $script:installProc
    }
    else { $btnUpdate.Text = '모드팩이 최신 버전이에요' }
}
function Start-PackUpdate {
    $d = Get-SelDir; $t = $btnUpdate.Tag; if (-not $d -or -not $t) { return }
    if (-not (Assert-ServerOff $d)) { return }
    $i = Read-Json (Join-Path $d 'server-info.json')
    $name = $lstSrv.SelectedItem
    $q = "'$name' 서버의 모드팩을 $($i.version) → $($t.label) 로 업데이트할까요?`n`n" +
    "- 월드, 화이트리스트, 직접 추가한 모드는 그대로 옮겨요.`n- 시작하기 전에 월드를 자동으로 백업해요.`n" +
    "- 예전 서버는 servers_old 폴더에 그대로 보관해요.`n- 친구들도 모드팩을 $($t.label) 로 업데이트해야 들어올 수 있어요."
    if (-not (Ask-YesNo $q)) { return }
    $extra = ''; if (Test-Eula $d) { $extra = ' -AcceptEula' }
    Start-InstallJob "-PackId $($i.pack) -VersionKey `"$($t.key)`" -Name `"$name`" -RamGB $(Get-ServerRam $d) -Update$extra" 'update'
}

# =====================================================================================
# Tab: my servers (server console lives here)
# =====================================================================================
$lblMy = New-Ctl Label 10 10 230 22 '만들어 둔 서버'
$lstSrv = New-Ctl ListBox 10 35 235 150
$btnPlay = New-Ctl Button 10 186 235 42 '▶ 마인크래프트 켜기'; $btnPlay.Font = $bold; $btnPlay.BackColor = [Drawing.Color]::FromArgb(214, 240, 214)
$btnSettings = New-Ctl Button 10 232 235 34 '서버 설정 (난이도, 인원 등)'
$btnMods = New-Ctl Button 10 270 235 34 '모드 추가 / 관리'
$btnBackup = New-Ctl Button 10 308 235 34 '백업 / 월드 관리'
$btnFriend = New-Ctl Button 10 346 235 34 '친구 접속 안내'
$btnPlayit = New-Ctl Button 10 384 235 34 'Playit 연결 설정'
$btnSecurity = New-Ctl Button 10 422 235 34 '보안 점검'
$btnUpdate = New-Ctl Button 10 460 235 34 '모드팩 업데이트 확인'
$btnFolder = New-Ctl Button 10 498 235 34 '서버 폴더 열기'
$lblPlayit = New-Ctl Label 10 536 235 50 ''
$btnCopyAddr = New-Ctl Button 10 588 235 30 '친구에게 줄 주소 복사'

$lblState = New-Ctl Label 260 35 695 48 '● 꺼짐'
$lblState.Font = $big; $lblState.ForeColor = [Drawing.Color]::White; $lblState.BackColor = [Drawing.Color]::Gray; $lblState.TextAlign = 'MiddleLeft'
$prg = New-Object Windows.Forms.ProgressBar; $prg.Location = New-Object Drawing.Point(260, 88); $prg.Size = New-Object Drawing.Size(695, 18); $prg.Style = 'Continuous'
$lblStage = New-Ctl Label 260 110 695 24 ''
$lblSrvInfo = New-Ctl Label 260 136 455 44 ''; $lblSrvInfo.ForeColor = [Drawing.Color]::DimGray
$lblRamSrv = New-Ctl Label 720 140 80 22 '서버 램(GB)'
$numRamSrv = New-Ctl NumericUpDown 800 137 55 28; $numRamSrv.Minimum = 2; $numRamSrv.Maximum = [Math]::Max(2, $totalRam - 2)
$btnRamSrv = New-Ctl Button 860 135 95 30 '램 바꾸기'
$btnStart = New-Ctl Button 260 184 160 42 '▶ 친구랑 하기'; $btnStart.Font = $bold
$btnLocal = New-Ctl Button 426 184 150 42 '▶ 혼자 하기'; $btnLocal.Font = $bold
$btnStop = New-Ctl Button 582 184 150 42 '■ 서버 끄기'; $btnStop.Font = $bold; $btnStop.Enabled = $false
$btnAddFriend = New-Ctl Button 738 184 120 42 '친구 추가'
$lblPlayers = New-Ctl Label 862 184 93 42 '접속 0명'; $lblPlayers.TextAlign = 'MiddleCenter'; $lblPlayers.Font = $bold
$tip = New-Object Windows.Forms.ToolTip
$tip.SetToolTip($btnStart, '서버를 열고 Playit으로 친구들이 들어올 수 있게 해요.')
$tip.SetToolTip($btnLocal, '같은 월드를 내 컴퓨터에서만 열어요. 마인크래프트에서 localhost 로 접속하세요.')
$tip.SetToolTip($btnAddFriend, '화이트리스트에 닉네임을 추가해요. 나도 처음 한 번 추가해야 해요.')
$txtConsole = New-Ctl TextBox 260 232 695 340
$txtConsole.Multiline = $true; $txtConsole.ReadOnly = $true; $txtConsole.ScrollBars = 'Vertical'; $txtConsole.WordWrap = $false
$txtConsole.Font = $mono; $txtConsole.BackColor = [Drawing.Color]::FromArgb(24, 24, 24); $txtConsole.ForeColor = [Drawing.Color]::Gainsboro
$txtCmd = New-Ctl TextBox 260 580 590 28
$btnSend = New-Ctl Button 856 578 99 32 '명령 보내기'
$tip.SetToolTip($btnPlay, '서버와 똑같은 모드팩 게임을 준비하고 마인크래프트 런처를 열어요. 멀티플레이에 내 서버가 들어 있어요.')
$tabMy.Controls.AddRange(@($lblMy, $lstSrv, $btnPlay, $btnSettings, $btnFolder, $btnMods, $btnFriend, $btnBackup, $btnPlayit, $btnSecurity, $btnUpdate, $lblPlayit, $btnCopyAddr,
        $lblState, $prg, $lblStage, $lblSrvInfo, $lblRamSrv, $numRamSrv, $btnRamSrv, $btnStart, $btnLocal, $btnStop, $btnAddFriend, $lblPlayers, $txtConsole, $txtCmd, $btnSend))

function Update-Servers {
    $keep = $lstSrv.SelectedItem
    $lstSrv.Items.Clear()
    Get-ChildItem -LiteralPath $ServersDir -Directory |
        Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName '서버켜기.bat')) -and -not (Test-Path -LiteralPath (Join-Path $_.FullName '.installing')) } |
        ForEach-Object { [void]$lstSrv.Items.Add($_.Name) }
    if ($keep -and $lstSrv.Items.Contains($keep)) { $lstSrv.SelectedItem = $keep }
    elseif ($lstSrv.Items.Count) { $lstSrv.SelectedIndex = 0 }
    else { $lblSrvInfo.Text = "아직 서버가 없어요. [새 서버 만들기] 탭에서 만들어 보세요." }
}
function Get-SelDir { if ($lstSrv.SelectedIndex -lt 0) { return $null }; return Join-Path $ServersDir $lstSrv.SelectedItem }
function Test-Eula($d) { $e = Join-Path $d 'eula.txt'; return (Test-Path -LiteralPath $e) -and ((Get-Content -LiteralPath $e -Raw) -match 'eula\s*=\s*true') }

function Show-SrvInfo {
    $d = Get-SelDir; if (-not $d) { return }
    $i = Read-Json (Join-Path $d 'server-info.json')
    if ($i) {
        $eula = ''; if (-not (Test-Eula $d)) { $eula = '   |   EULA 동의 안 함 (켤 때 물어봐요)' }
        $boot = ''; if ($i.bootSeconds) { $boot = "   |   지난번 켜는 데 $([int]$i.bootSeconds)초" }
        $lblSrvInfo.Text = "$($i.packName)  $($i.version)`n마인크래프트 $($i.mc) / $($i.loader) $($i.loaderVersion)$boot$eula"
    }
    else { $lblSrvInfo.Text = $lstSrv.SelectedItem }
    $numRamSrv.Value = [Math]::Min($numRamSrv.Maximum, [Math]::Max($numRamSrv.Minimum, (Get-ServerRam $d)))
    Update-UpdateButton
}

function Get-ServerRam($d) {
    $jvm = Join-Path $d 'user_jvm_args.txt'
    # Only a real setting line counts: the pack's own comments mention "-Xmx3G" as an example
    if (Test-Path -LiteralPath $jvm) { $m = [regex]::Match((Get-Content -LiteralPath $jvm -Raw), '(?m)^\s*-Xmx(\d+)[Gg]'); if ($m.Success) { return [int]$m.Groups[1].Value } }
    return 4
}
function Set-ServerRam($d, [int]$gb) {
    $jvm = Join-Path $d 'user_jvm_args.txt'; $latin1 = [Text.Encoding]::GetEncoding(28591)
    $keep = @(); if (Test-Path -LiteralPath $jvm) { $keep = @([IO.File]::ReadAllLines($jvm, $latin1) | Where-Object { $_ -notmatch '^\s*-Xm[sx]' }) }
    [IO.File]::WriteAllLines($jvm, [string[]](@($keep) + "-Xms$([Math]::Min(4, $gb))G" + "-Xmx${gb}G"), $latin1)
    Set-InfoField $d 'ramGB' $gb
}
$lstSrv.Add_SelectedIndexChanged({ Show-SrvInfo })

# ---------------- running a server inside the window ----------------
$script:srv = $null   # state of the server this window runs (only one at a time)

function Set-State($text, $color) { $lblState.Text = $text; $lblState.BackColor = $color }
function Get-LaunchInfo($d) {
    # 서버켜기.bat is the single source of truth for the java version and arguments
    $bat = Join-Path $d '서버켜기.bat'
    $line = [IO.File]::ReadAllLines($bat, $Cp949) | Where-Object { $_ -match '^"%PROG%\\java\\(\d+)\\bin\\java\.exe"\s+(.+)$' } | Select-Object -First 1
    if (-not $line) { return $null }
    [void]($line -match '^"%PROG%\\java\\(\d+)\\bin\\java\.exe"\s+(.+)$')
    return @{ major = $Matches[1]; args = $Matches[2].Trim() }
}
function Test-PortBusy { return [bool]([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object { $_.Port -eq 25565 }) }

function Start-Server([switch]$Local) {
    $d = Get-SelDir
    if (-not $d) { Show-Msg '왼쪽 목록에서 서버를 고르세요.'; return }
    if ($script:srv) { Show-Msg '이미 켜져 있는 서버가 있어요.'; return }
    if ($script:installProc) { Show-Msg '설치나 업데이트가 끝난 다음에 켜 주세요.'; return }
    if ($script:autoBk) { Show-Msg '자동 백업이 끝난 다음에 켜 주세요. (잠깐이면 돼요)'; return }
    if (Test-PortBusy) {
        # A server this program lost track of can be saved and stopped from here; anything else needs the user
        if (@(Get-OrphanServers).Count) { if (-not (Stop-Orphans -Ask)) { return } }
        if (Test-PortBusy) { Show-Msg "다른 서버가 이미 켜져 있어요 (25565번 포트 사용 중).`n서버켜기.bat 으로 켠 검은 창이 있다면 그 창에 stop 을 입력해서 먼저 꺼 주세요." 'Warning'; return }
    }
    if (-not (Test-Eula $d)) {
        if (-not (Ask-YesNo "서버를 켜려면 마인크래프트 이용약관(EULA)에 동의해야 해요.`n(약관: https://aka.ms/MinecraftEULA)`n`n동의하고 켤까요?")) { return }
        [IO.File]::WriteAllText((Join-Path $d 'eula.txt'), "eula=true`r`n", $Utf8)
    }
    Set-SafeDefaults $d
    $li = Get-LaunchInfo $d
    if (-not $li) { Show-Msg '서버켜기.bat 에서 실행 정보를 찾지 못했어요.' 'Error'; return }
    $java = Join-Path $Prog "java\$($li.major)\bin\java.exe"
    if (-not (Test-Path -LiteralPath $java)) { Show-Msg "Java $($li.major) 이(가) 없어요. _program\java 폴더를 확인하세요." 'Error'; return }

    $why = ''
    if ($Local) {
        # "혼자 하기" promises nobody else can join, so a Playit left over from an earlier "친구랑 하기" must go
        if ($script:playit) { $script:playit.Kill(); $script:playit = $null }
    }
    else {
        # "친구랑 하기" without a working Playit would leave the user believing friends can join
        $why = ''
        if (-not (Test-Path -LiteralPath (Join-Path $PlayitDir 'playit.exe'))) { $why = 'Playit 프로그램 파일(_program\playit\playit.exe)이 없어서' }
        elseif (-not (Get-PlayitKey)) {
            $why = 'Playit 연결 설정이 아직 안 돼 있어서'
            if ($script:playitKeyForeign) { $why = '다른 PC에서 옮겨 와서 Playit 키를 이 PC에서 한 번 다시 넣어야 해서' }
        }
        if ($why -and -not (Ask-YesNo "$why 친구들은 들어올 수 없어요.`n([Playit 연결 설정]에서 넣을 수 있어요. 나는 localhost 로 들어갈 수 있어요)`n`n그래도 켤까요?")) { return }
        Start-Playit
    }
    $i = Read-Json (Join-Path $d 'server-info.json')
    $mods = @(Get-ChildItem -LiteralPath (Join-Path $d 'mods') -Filter '*.jar' -ErrorAction SilentlyContinue).Count
    $expect = 40 + [int]($mods * 0.35); if ($i -and $i.bootSeconds) { $expect = [int]$i.bootSeconds }
    $txtConsole.Clear()
    $txtConsole.AppendText("[관리 프로그램] '$($lstSrv.SelectedItem)' 서버를 켜는 중이에요. 끌 때는 [■ 서버 끄기]를 눌러 주세요.`r`n")
    $proc = New-Object McProc($java, $li.args, $d, [Text.Encoding]::Default.CodePage)
    $script:srv = [pscustomobject]@{
        dir = $d; name = $lstSrv.SelectedItem; proc = $proc; sw = [Diagnostics.Stopwatch]::StartNew(); expect = $expect
        done = $false; stopping = $false; stage = 0; spawn = 0; players = @{}; tail = New-Object System.Collections.Generic.List[string]; stopSw = $null
        local = [bool]$Local; noPlayit = [bool]$why; warned = @{}; askNick = $null
    }
    $lstSrv.Enabled = $false; $btnStart.Enabled = $false; $btnLocal.Enabled = $false; $btnStop.Enabled = $true; $btnMods.Enabled = $false; $btnUpdate.Enabled = $false; $btnRamSrv.Enabled = $false
    $prg.Value = 0; $lblPlayers.Text = '접속 0명'
    $mode = '친구랑 하기'; if ($Local) { $mode = '혼자 하기' }
    Set-State "● 켜는 중...  ($mode, 다 켜질 때까지 기다려 주세요)" ([Drawing.Color]::DarkOrange)
}

function Stop-Server([switch]$NoAsk) {
    $s = $script:srv; if (-not $s -or $s.stopping) { return }
    if (-not $s.done -and $s.stage -lt 3) {
        # Still loading mods: no world is open yet, so ending the process is safe
        if (-not $NoAsk -and -not (Ask-YesNo '아직 켜지는 중이에요. 그만 켜고 끌까요?')) { return }
        $s.stopping = $true; $s.proc.Kill(); return
    }
    $s.stopping = $true; $s.stopSw = [Diagnostics.Stopwatch]::StartNew()
    $s.proc.Send('stop')
    Set-State '● 끄는 중...  (월드를 저장하고 있어요)' ([Drawing.Color]::SlateGray)
}

function Find-CulpritMod($s) {
    # A client-only mod on a server shows up as "Mod File: .../mods/x.jar" next to a client-class error.
    # Other failures (a missing dependency, a broken config) also list mod files; parking those would make things worse.
    $text = $s.tail -join "`n"
    $cr = Get-ChildItem -LiteralPath (Join-Path $s.dir 'crash-reports') -Filter '*.txt' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-5) } | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($cr) { $text += "`n" + [IO.File]::ReadAllText($cr.FullName) }
    if ($text -notmatch 'invalid dist|net[/.]minecraft[/.]client[/.]') { return $null }
    $m = [regex]::Match($text, 'Mod File:\s*/?(?<p>[^\r\n]+?\.jar)')
    if (-not $m.Success) { return $null }
    $jar = Join-Path (Join-Path $s.dir 'mods') (Split-Path ($m.Groups['p'].Value -replace '/', '\') -Leaf)
    if (Test-Path -LiteralPath $jar) { return $jar } return $null
}

function Complete-Server {
    $s = $script:srv; $script:srv = $null
    $code = $s.proc.Code
    $lstSrv.Enabled = $true; $btnStart.Enabled = $true; $btnLocal.Enabled = $true; $btnStop.Enabled = $false; $btnMods.Enabled = $true; $btnRamSrv.Enabled = $true
    # No server, no reason to keep a public address open
    if ($script:playit) { $script:playit.Kill(); $script:playit = $null }
    Update-PlayitLabel
    Update-UpdateButton
    $lblPlayers.Text = '접속 0명'; $prg.Value = 0
    if ($s.done -or $s.stopping) {
        Set-State '● 꺼짐' ([Drawing.Color]::Gray); $lblStage.Text = '서버가 안전하게 꺼졌어요.'
        $txtConsole.AppendText("`r`n[관리 프로그램] 서버가 꺼졌어요.`r`n")
        # Stopped while still loading: no world was opened, so there is nothing new to back up
        if ($s.done) { Start-AutoBackup $s.dir }
        return
    }
    Set-State '● 서버가 켜지다가 멈췄어요' ([Drawing.Color]::Firebrick)
    $all = $s.tail -join "`n"
    $hint = '아래 로그를 확인하세요. 모르겠으면 [서버 폴더 열기] → crash-reports 폴더의 최신 파일을 도와줄 사람에게 보여 주세요.'
    if ($all -match 'Could not reserve enough space|Invalid maximum heap size|Error occurred during initialization of VM') {
        $hint = '이 컴퓨터에 서버 램으로 줄 메모리가 모자라요. 오른쪽 위 [서버 램] 숫자를 1~2 낮추고 [램 바꾸기]를 누른 뒤 다시 켜 보세요.'
    }
    elseif ($all -match 'OutOfMemoryError') { $hint = '서버 램이 모자라요. 오른쪽 위 [서버 램] 숫자를 1~2 올리고 [램 바꾸기]를 누른 뒤 다시 켜 보세요.' }
    elseif ($all -match 'FAILED TO BIND TO PORT|Address already in use') { $hint = '다른 서버가 이미 25565번 포트를 쓰고 있어요. 프로그램을 닫았다가 다시 켜면 찾아서 꺼 드려요.' }
    $lblStage.Text = $hint
    $txtConsole.AppendText("`r`n[관리 프로그램] 서버가 멈췄어요 (종료 코드 $code). $hint`r`n")
    $jar = Find-CulpritMod $s
    if ($jar -and (Ask-YesNo "'$(Split-Path $jar -Leaf)' 모드 때문에 서버가 안 켜진 것 같아요.`n(화면 전용 모드일 가능성이 높아요)`n`n이 모드를 _client_only_mods 폴더로 옮기고 다시 켤까요?")) {
        $park = Join-Path $s.dir '_client_only_mods'
        New-Item -ItemType Directory -Force $park | Out-Null
        Move-Item -LiteralPath $jar -Destination $park -Force
        Start-Server -Local:$s.local
    }
}

$StageText = @('Java 시작하는 중', '모드 로더 준비하는 중', '모드 불러오는 중', '월드 불러오는 중', '스폰 지역 만드는 중')
function Show-OpenBanner($s) {
    if ($s.local) {
        Set-State '● 서버 열림!  (혼자 하기: 주소 localhost)' ([Drawing.Color]::ForestGreen)
        $lblStage.Text = "게임은 왼쪽 [▶ 마인크래프트 켜기]로 켜세요. 멀티플레이에 내 서버가 들어 있어요. 끌 때는 [서버 끄기]."
    }
    elseif ($s.noPlayit) {
        # Started anyway after the "no Playit" warning: say plainly that friends still can't join
        Set-State '● 서버 열림!  (Playit이 없어서 지금은 나만: 주소 localhost)' ([Drawing.Color]::DarkOrange)
        if (Test-Path -LiteralPath (Join-Path $PlayitDir 'playit.exe')) { $lblStage.Text = "친구들도 들어오게 하려면 → [Playit 연결 설정]에서 비밀 키를 저장하세요. 서버를 끄지 않아도 바로 연결돼요." }
        else { $lblStage.Text = "_program\playit\playit.exe 파일이 없어요 (백신이 지웠을 수 있어요). 프로그램 압축 파일을 다시 풀어서 그 파일만 제자리에 넣어 주세요." }
    }
    else {
        $addr = Get-PlayitAddress
        if ($addr) {
            Set-State "● 서버 열림!  친구들은 $addr 로 접속" ([Drawing.Color]::ForestGreen)
            $lblStage.Text = "나는 왼쪽 [▶ 마인크래프트 켜기]로 접속. 친구들에게는 [친구 접속 안내] 글을 보내 주세요. 끌 때는 [서버 끄기]."
        }
        else {
            Set-State '● 서버 열림!  친구들이 들어올 수 있어요' ([Drawing.Color]::ForestGreen)
            $lblStage.Text = "나는 왼쪽 [▶ 마인크래프트 켜기]로 접속. 친구용 주소는 왼쪽 아래 [친구에게 줄 주소 넣기]에서 한 번 넣어 두세요."
        }
    }
}

function Find-JoinProblem($s, [string]$line) {
    # Friends who bounce off the server rarely know why; the log does, so say it in plain words
    $why = ''
    if ($line -match 'lost connection: (.+)$') { $why = $Matches[1] }
    elseif ($line -match 'Disconnecting .*?\): (.+)$') { $why = $Matches[1] }
    if (-not $why) { return $null }
    $name = ''
    if ($line -match 'name=([A-Za-z0-9_]{3,16})[,\]]') { $name = $Matches[1] }
    elseif ($line -match 'Disconnecting ([A-Za-z0-9_]{3,16}) \(') { $name = $Matches[1] }
    elseif ($line -match ':\s([A-Za-z0-9_]{3,16})\s(\(/[^)]*\)\s)?lost connection') { $name = $Matches[1] }
    $who = '어떤 친구가'; $whose = '친구의'
    if ($name) { $who = "'$name' 님이"; $whose = "'$name' 님의" }
    $i = Read-Json (Join-Path $s.dir 'server-info.json')
    $kind = ''; $msg = ''
    if ($why -match '(?i)white-?list') { $kind = 'wl'; $msg = "$who 화이트리스트에 없어서 못 들어왔어요. → [친구 추가]에 닉네임을 넣어 주세요." }
    elseif ($why -match '(?i)banned') { $kind = 'ban'; $msg = "$who 차단된 사람이라 못 들어왔어요." }
    elseif ($why -match '(?i)server is full') { $kind = 'full'; $msg = "서버 인원이 꽉 차서 $who 못 들어왔어요. → [서버 설정]에서 최대 인원을 늘려 주세요." }
    elseif ($why -match '(?i)verify username|invalid session|authenticat|multiplayer is disabled') { $kind = 'auth'; $msg = "$whose 마인크래프트 로그인 확인이 안 됐어요. → 런처를 껐다가 다시 로그인해서 실행하라고 알려 주세요. (정품 계정만 들어올 수 있어요)" }
    elseif ($why -match '(?i)mod|channel|registr|negotiat|forge|fabric|mismatch|missing') { $kind = 'mods'; $msg = "$whose 모드팩이 서버와 달라서 튕겼어요. → [친구 접속 안내]대로 $($i.packName) $($i.version) 버전과 추가 모드를 똑같이 맞추라고 알려 주세요." }
    elseif ($why -match '(?i)outdated|incompatible|version') { $kind = 'ver'; $msg = "$whose 마인크래프트 버전이 달라요. → 모드팩 앱에서 모드팩을 실행해서(마인크래프트 $($i.mc)) 접속하라고 알려 주세요." }
    if (-not $kind) { return $null }
    # One bounce often logs two lines; say it once a minute per friend
    $key = "$kind|$name"
    if ($s.warned.ContainsKey($key) -and ((Get-Date) - $s.warned[$key]).TotalSeconds -lt 60) { return $null }
    $s.warned[$key] = Get-Date
    $lblStage.Text = $msg
    if ($kind -eq 'wl' -and $name) { $s.askNick = $name }
    return $msg
}

function Read-ServerOutput {
    $s = $script:srv; if (-not $s) { return }
    $sb = New-Object Text.StringBuilder; $line = $null; $n = 0
    while ($n -lt 800 -and $s.proc.Lines.TryDequeue([ref]$line)) {
        $n++
        [void]$sb.Append($line).Append("`r`n")
        $s.tail.Add($line); if ($s.tail.Count -gt 400) { $s.tail.RemoveAt(0) }
        if ($s.stage -lt 1 -and $line -match 'ModLauncher|Fabric Loader|Loading Minecraft|fml|Launching target') { $s.stage = 1 }
        if ($s.stage -lt 2 -and $line -match '[Mm]od|[Mm]ixin') { $s.stage = 2 }
        if ($s.stage -lt 3 -and $line -match 'Preparing level|Loading properties|Starting Minecraft server') { $s.stage = 3 }
        if ($line -match 'Preparing spawn area: (\d+)%') { $s.stage = 4; $s.spawn = [int]$Matches[1] }
        if (-not $s.done -and $line -match 'Done \([\d.,]+s\)!') {
            $s.done = $true
            Set-InfoField $s.dir 'bootSeconds' ([int]$s.sw.Elapsed.TotalSeconds)
            $prg.Value = 100
            Show-OpenBanner $s
            # An empty whitelist locks everyone out, the host included
            $wl = Read-Json (Join-Path $s.dir 'whitelist.json')
            if (-not @($wl).Count -and -not (Test-Path -LiteralPath (Join-Path $s.dir 'whitelist-pending.txt'))) {
                $txtConsole.AppendText("[관리 프로그램] 화이트리스트가 비어 있어요. [친구 추가]로 내 닉네임부터 추가해야 나도 들어갈 수 있어요.`r`n")
                $lblStage.Text = '화이트리스트가 비어 있어요. [친구 추가]로 내 닉네임부터 추가하세요!'
            }
            [System.Media.SystemSounds]::Asterisk.Play()
            # Friends queued while the server was off
            $pend = Join-Path $s.dir 'whitelist-pending.txt'
            if (Test-Path -LiteralPath $pend) {
                Get-Content -LiteralPath $pend | Where-Object { $_.Trim() } | ForEach-Object {
                    $s.proc.Send("whitelist add $($_.Trim())")
                    $txtConsole.AppendText("[관리 프로그램] 기다리던 친구를 화이트리스트에 추가해요: $($_.Trim())`r`n")
                }
                Remove-Item -LiteralPath $pend
            }
        }
        if ($line -match ': (\S+) joined the game') { $s.players[$Matches[1]] = $true }
        if ($line -match ': (\S+) left the game') { $s.players.Remove($Matches[1]) }
        if ($line -match 'lost connection: |Disconnecting ') { $note = Find-JoinProblem $s $line; if ($note) { [void]$sb.Append("[관리 프로그램] ※ $note`r`n") } }
    }
    if ($sb.Length) {
        if ($txtConsole.TextLength -gt 400000) { $txtConsole.Text = $txtConsole.Text.Substring($txtConsole.TextLength - 200000) }
        $txtConsole.AppendText($sb.ToString())
    }
    if ($s.askNick -and -not $script:askingJoin) {
        # Asked after the read loop: the timer keeps ticking while the question is open
        $n = $s.askNick; $s.askNick = $null; $script:askingJoin = $true
        $ok = Ask-YesNo "'$n' 님이 들어오려고 했는데 화이트리스트에 없어서 막혔어요.`n`n지금 '$n' 님을 추가할까요? (아는 친구일 때만 [예]를 누르세요)"
        $script:askingJoin = $false
        if ($script:srv -ne $s) { return }
        if ($ok) { $s.proc.Send("whitelist add $n"); $txtConsole.AppendText("> whitelist add $n`r`n[관리 프로그램] '$n' 님을 추가했어요. 다시 접속하라고 알려 주세요.`r`n") }
    }
    $lblPlayers.Text = "접속 $($s.players.Count)명"
    if (-not $s.done -and -not $s.stopping) {
        # Time-based estimate, nudged forward by the stage the log has reached
        $el = $s.sw.Elapsed.TotalSeconds
        $pct = [Math]::Min(95, [int](100 * $el / [Math]::Max(10, $s.expect)))
        $floor = @(0, 5, 10, 75, 80)[$s.stage]; if ($s.stage -eq 4) { $floor = 80 + [int]($s.spawn * 0.18) }
        $prg.Value = [Math]::Max($pct, [Math]::Min(98, $floor))
        $left = [int]($s.expect - $el)
        $leftText = '거의 다 됐어요'; if ($left -gt 60) { $leftText = "약 $([int]($left / 60))분 $($left % 60)초 남음" } elseif ($left -gt 5) { $leftText = "약 $($left)초 남음" }
        $stageText = $StageText[$s.stage]; if ($s.stage -eq 4) { $stageText += " $($s.spawn)%" }
        $lblStage.Text = "$stageText...   ($leftText, 처음 켤 때는 더 오래 걸려요)"
    }
    if ($s.stopping -and $s.stopSw -and $s.stopSw.Elapsed.TotalSeconds -gt 120 -and $s.proc.Running) {
        $s.stopSw = $null
        if (Ask-YesNo '서버가 2분 넘게 안 꺼지고 있어요. 강제로 끌까요? (월드 일부가 저장 안 될 수 있어요)') { $s.proc.Kill() } else { $s.stopSw = [Diagnostics.Stopwatch]::StartNew() }
    }
    if (-not $s.proc.Running -and $s.proc.Lines.IsEmpty) { Complete-Server }
}

$btnUpdate.Add_Click({ Start-PackUpdate })
$btnStart.Add_Click({ Start-Server })
$btnLocal.Add_Click({ Start-Server -Local })
$btnStop.Add_Click({ Stop-Server })
$btnSend.Add_Click({
        $c = $txtCmd.Text.Trim().TrimStart('/'); if (-not $c) { return }
        if (-not $script:srv) { Show-Msg '서버가 켜져 있을 때만 명령을 보낼 수 있어요.'; return }
        if ($c -eq 'stop') { Stop-Server; $txtCmd.Clear(); return }
        $script:srv.proc.Send($c); $txtConsole.AppendText("> $c`r`n"); $txtCmd.Clear()
    })
$txtCmd.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; $btnSend.PerformClick() } })
$btnAddFriend.Add_Click({
        $d = Get-SelDir; if (-not $d) { return }
        $nick = (Ask-Text "들여보낼 친구의 마인크래프트 닉네임을 입력하세요.`n(자바 에디션 계정 이름)").Trim()
        if (-not $nick) { return }
        if ($nick -notmatch '^[A-Za-z0-9_]{3,16}$') { Show-Msg '마인크래프트 닉네임은 영어, 숫자, _ 로 3~16글자예요.'; return }
        if (-not (Add-Whitelist $d $nick)) { Show-Msg "'$nick' 님은 서버가 다음에 켜질 때 자동으로 추가할게요." }
    })
function Add-Whitelist($d, [string]$nick) {
    # Returns $true when the running server took it right away, $false when it waits for the next start
    if ($script:srv -and $script:srv.done -and $script:srv.dir -eq $d) { $script:srv.proc.Send("whitelist add $nick"); $txtConsole.AppendText("> whitelist add $nick`r`n"); return $true }
    Add-Content -LiteralPath (Join-Path $d 'whitelist-pending.txt') -Value $nick
    return $false
}
$btnFolder.Add_Click({ $d = Get-SelDir; if ($d) { Start-Process explorer.exe "`"$d`"" } })
$btnBackup.Add_Click({ Show-Backups })
$btnFriend.Add_Click({ Show-FriendGuide })
$btnSettings.Add_Click({ Show-ServerSettings })
$btnRamSrv.Add_Click({
        $d = Get-SelDir; if (-not $d) { return }
        if (-not (Assert-ServerOff $d)) { return }
        Set-ServerRam $d ([int]$numRamSrv.Value)
        Show-SrvInfo
        Show-Msg "서버 램을 $([int]$numRamSrv.Value)GB로 바꿨어요. 다음에 켤 때부터 적용돼요."
    })

# ---------------- Playit ----------------
$script:playit = $null
$script:playitKeyForeign = $false
function Save-PlayitKey([string]$key) {
    # DPAPI ties the key to this Windows account on this PC: a copied folder is useless to anyone else
    $enc = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($key), $KeyEntropy, 'CurrentUser')
    New-Item -ItemType Directory -Force $PlayitDir | Out-Null
    [IO.File]::WriteAllText($PlayitKeyFile, [Convert]::ToBase64String($enc), $Utf8)
    $script:playitKeyForeign = $false
}
function Get-PlayitKey {
    if (Test-Path -LiteralPath $PlayitKeyFile) {
        try {
            $raw = [Convert]::FromBase64String(([IO.File]::ReadAllText($PlayitKeyFile)).Trim())
            $script:playitKeyForeign = $false
            return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($raw, $KeyEntropy, 'CurrentUser'))
        }
        catch { $script:playitKeyForeign = $true; return '' }   # encrypted on another PC or Windows account
    }
    return ''
}
if (Test-Path -LiteralPath $PlayitKeyPlain) {
    $k = ([IO.File]::ReadAllText($PlayitKeyPlain)).Trim()
    if ($k) { Save-PlayitKey $k }
    Remove-Item -LiteralPath $PlayitKeyPlain -Force
}
function Start-Playit {
    $exe = Join-Path $PlayitDir 'playit.exe'
    $key = Get-PlayitKey
    if (-not $key -or -not (Test-Path -LiteralPath $exe)) { return }
    if ($script:playit -and $script:playit.Running) { return }
    # Playit appends to its log forever; start fresh once it gets big
    if ((Test-Path -LiteralPath $PlayitLog) -and (Get-Item -LiteralPath $PlayitLog).Length -gt 5MB) { Remove-Item -LiteralPath $PlayitLog -Force -ErrorAction SilentlyContinue }
    # A dedicated pipe name keeps this copy apart from any other playit running on the PC
    $script:playit = New-Object McProc($exe, "--secret $key --socket-path \\.\pipe\playitd-mcserver -l `"$PlayitLog`"", $PlayitDir, 65001)
}
function ConvertTo-PlayitAddress([string]$t) {
    # Accepts what people paste: "https://x.joinmc.link/", " x.joinmc.link:12345 " ...
    $t = ($t.Trim() -replace '^[A-Za-z]+://', '') -replace '/.*$', ''
    if ($t -match '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+(:\d{1,5})?$') { return $t.ToLower() }
    return $null
}
function Get-PlayitAddress {
    if (Test-Path -LiteralPath $PlayitAddrFile) { return ([IO.File]::ReadAllText($PlayitAddrFile)).Trim() }
    return ''
}
function Set-PlayitAddress([string]$a) {
    if ($a) { [IO.File]::WriteAllText($PlayitAddrFile, $a, $Utf8) } else { Remove-Item -LiteralPath $PlayitAddrFile -Force -ErrorAction SilentlyContinue }
    $btnCopyAddr.Text = '친구에게 줄 주소 복사'; if (-not $a) { $btnCopyAddr.Text = '친구에게 줄 주소 넣기' }
    if ($script:srv -and $script:srv.done -and -not $script:srv.stopping) { Show-OpenBanner $script:srv }
}
function Find-PlayitAddressInLog {
    # Playit prints the tunnel address when it connects; joinmc.link / ply.gg are its public tunnel domains
    try { $text = (Get-Content -LiteralPath $PlayitLog -Tail 400 -ErrorAction Stop) -join "`n" } catch { return $null }
    $m = [regex]::Matches($text, '\b[a-z0-9-]+(\.[a-z0-9-]+)*\.(joinmc\.link|ply\.gg)(:\d{2,5})?\b')
    if ($m.Count) { return $m[$m.Count - 1].Value }
    return $null
}
function Update-PlayitLabel {
    # Playit's own output is not shown anywhere; drain it so it doesn't pile up in memory
    # (its console output may carry the tunnel address too, so look before throwing it away)
    $found = $null
    if ($script:playit) {
        $x = $null
        while ($script:playit.Lines.TryDequeue([ref]$x)) { if (-not $found -and $x -match '\b[a-z0-9-]+(\.[a-z0-9-]+)*\.(joinmc\.link|ply\.gg)(:\d{2,5})?\b') { $found = $Matches[0] } }
    }
    if ($script:playit -and $script:playit.Running -and -not (Get-PlayitAddress)) {
        if (-not $found) { $found = Find-PlayitAddressInLog }
        if ($found) { Set-PlayitAddress $found }
    }
    $exe = Join-Path $PlayitDir 'playit.exe'
    if (-not (Test-Path -LiteralPath $exe)) { $lblPlayit.ForeColor = [Drawing.Color]::Firebrick; $lblPlayit.Text = "Playit: 프로그램 파일이 없어요`n(_program\playit\playit.exe)"; return }
    if (-not (Get-PlayitKey)) {
        $lblPlayit.ForeColor = [Drawing.Color]::DarkOrange
        if ($script:playitKeyForeign) { $lblPlayit.Text = "Playit: 이 PC에서 키를 한 번 다시 넣어 주세요`n(다른 PC에서 옮겨 와서 그래요)" }
        else { $lblPlayit.Text = "Playit: 연결 안 됨`n친구들이 들어오려면 [Playit 연결 설정]을 먼저 해 주세요." }
        return
    }
    if ($script:playit -and $script:playit.Running) {
        $last = ''
        try { $last = (Get-Content -LiteralPath $PlayitLog -Tail 1 -ErrorAction Stop) -replace '^\S+\s+(INFO|WARN|ERROR)\s+\S+:\s*', '' } catch { }
        if ($last.Length -gt 80) { $last = $last.Substring(0, 80) + '...' }
        $addr = Get-PlayitAddress; if ($addr) { $last = "주소: $addr" }
        $lblPlayit.ForeColor = [Drawing.Color]::ForestGreen; $lblPlayit.Text = "Playit: 실행 중`n$last"; return
    }
    $lblPlayit.ForeColor = [Drawing.Color]::DimGray; $lblPlayit.Text = "Playit: 준비됨`n서버를 켜면 같이 켜져요."
}
$btnPlayit.Add_Click({ Show-PlayitSetup })
$btnCopyAddr.Add_Click({
        $a = Get-PlayitAddress
        if (-not $a) { Show-PlayitSetup; return }
        [Windows.Forms.Clipboard]::SetText($a)
        $lblStage.Text = "주소를 복사했어요: $a   → 카톡이나 디스코드에 붙여 넣어서 친구에게 보내 주세요."
    })

function Show-PlayitSetup {
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Playit 연결 설정'; $f.Size = New-Object Drawing.Size(640, 530); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.Font = $font
    $t = New-Ctl Label 15 12 600 60 "Playit은 친구들이 들어올 인터넷 주소를 만들어 주는 무료 서비스예요.`n아래 순서대로 한 번만 하면 돼요."
    $s1 = New-Ctl Label 15 80 600 24 '① playit.gg 에 로그인(가입)한 뒤, 아래 버튼으로 "비밀 키(Secret Key)"를 만드세요.'
    $b1 = New-Ctl Button 15 106 300 34 '비밀 키 만드는 페이지 열기'
    $s2 = New-Ctl Label 15 152 600 24 '② 화면에 나온 비밀 키를 복사해서 여기에 붙여 넣고 [저장]을 누르세요.'
    $tk = New-Ctl TextBox 15 178 480 28; $tk.UseSystemPasswordChar = $true; $tk.Text = Get-PlayitKey
    $bs = New-Ctl Button 505 176 105 32 '저장'
    $s3 = New-Ctl Label 15 220 600 44 "③ playit.gg 의 Tunnels(터널) 메뉴에서 [Add Tunnel] 을 누르고`n    종류 Minecraft Java, 주소 127.0.0.1, 포트 25565 로 터널을 만드세요."
    $b3 = New-Ctl Button 15 268 300 34 '터널 페이지 열기'
    $s4 = New-Ctl Label 15 315 600 44 "④ 터널 목록에 나온 주소(예: 어쩌구.joinmc.link)를 복사해서 아래 칸에 붙여 넣고 [저장]을 누르세요.`n    주소는 바뀌지 않아요. 친구 접속 안내와 화면에 자동으로 넣어 줘요."
    $ta = New-Ctl TextBox 15 362 480 28; $ta.Text = Get-PlayitAddress
    $ba = New-Ctl Button 505 360 105 32 '저장'
    $warn = New-Ctl Label 15 412 600 60 "비밀 키는 비밀번호 같은 거예요. 다른 사람에게 보여 주거나 보내지 마세요.`n저장한 키는 이 PC에서만 풀리게 암호화돼요. 다른 PC로 옮기면 한 번 다시 넣어야 해요."; $warn.ForeColor = [Drawing.Color]::Firebrick
    $b1.Add_Click({ Open-Url 'https://playit.gg/account/setup/wizard/new-account/docker/docker-name' })
    $b3.Add_Click({ Open-Url 'https://playit.gg/account/tunnels' })
    $bs.Add_Click({
            $k = $tk.Text.Trim()
            if ($k.Length -lt 16 -or $k -match '\s') { Show-Msg '비밀 키가 올바르지 않은 것 같아요. 다시 복사해서 붙여 넣어 주세요.'; return }
            Save-PlayitKey $k
            if ($script:playit) { $script:playit.Kill(); $script:playit = $null }
            # A server opened with "혼자 하기" must stay private; one opened with "친구랑 하기" connects right away
            $s = $script:srv
            if ($s -and -not $s.local) {
                Start-Playit
                if ($s.noPlayit -and $script:playit) { $s.noPlayit = $false; if ($s.done -and -not $s.stopping) { Show-OpenBanner $s } }
            }
            Update-PlayitLabel
            Show-Msg '저장했어요. 서버를 켜면 Playit도 같이 켜져요.'
        })
    $ba.Add_Click({
            if (-not $ta.Text.Trim()) { Set-PlayitAddress ''; Update-PlayitLabel; Show-Msg '주소를 지웠어요.'; return }
            $a = ConvertTo-PlayitAddress $ta.Text
            if (-not $a -or $a -match '^(www\.)?playit\.gg$') { Show-Msg "주소가 올바르지 않은 것 같아요.`nplayit.gg 의 터널 목록에 나온 '어쩌구.joinmc.link' 같은 주소를 그대로 복사해서 넣어 주세요."; return }
            $ta.Text = $a
            Set-PlayitAddress $a; Update-PlayitLabel
            Show-Msg "저장했어요: $a`n이제 [친구 접속 안내]에 이 주소가 자동으로 들어가요."
        })
    $f.Controls.AddRange(@($t, $s1, $b1, $s2, $tk, $bs, $s3, $b3, $s4, $ta, $ba, $warn))
    [void]$f.ShowDialog($form)
}

# ---------------- Mods: add / remove ----------------
function Get-AddedMods($d) { $a = Read-Json (Join-Path $d 'added-mods.json'); if ($a) { return @($a) } return @() }
function Save-AddedMods($d, $list) { [IO.File]::WriteAllText((Join-Path $d 'added-mods.json'), (ConvertTo-Json -InputObject @($list) -Depth 4), $Utf8) }

function Update-FriendGuide($d) {
    # Keeps the "extra mods" section of the friend guide in step with added-mods.json
    $g = Join-Path $d '친구접속안내.txt'
    $text = ''; if (Test-Path -LiteralPath $g) { $text = [IO.File]::ReadAllText($g, $Cp949) }
    $text = ($text -replace '(?s)\r?\n\[ 추가 모드 \].*$', '').TrimEnd()
    # Step 3 carries the Playit address once the host has saved it, so the copied guide is complete on its own
    $addr = Get-PlayitAddress
    $step3 = '3. 게임 실행 -> 멀티플레이 -> 서버 추가 -> 방장이 알려준 주소 입력'
    if ($addr) { $step3 = "3. 게임 실행 -> 멀티플레이 -> 서버 추가 -> 서버 주소에  $addr  입력" }
    $text = $text -replace '(?m)^3\. 게임 실행 -> 멀티플레이 -> 서버 추가 -> [^\r\n]*', $step3.Replace('$', '$$')
    # The easy way goes first: this program on the friend's PC reads the join code and does everything
    $text = $text -replace '(?s)\[ 제일 쉬운 방법 \].*?\[ 직접 하는 방법 \][^\r\n]*\r?\n', ''
    $code = Get-JoinCode $d
    if ($code) {
        $nl = $text.IndexOf("`n"); if ($nl -lt 0) { $nl = $text.Length - 1 }
        $easy = "[ 제일 쉬운 방법 ]  프로그램이 모드팩 설치부터 서버 접속 준비까지 다 해 줘요`r`n" +
        "1. '모드팩서버관리' 프로그램 받기: $ProgramZipUrl`r`n" +
        "   (받은 파일 오른쪽 클릭 -> [압축 풀기] -> 모드팩서버관리.exe 실행. 파란 경고창이 뜨면 [추가 정보] -> [실행])`r`n" +
        "2. [친구 서버 들어가기] 탭 -> 이 글을 통째로 붙여 넣기 -> [설치하고 게임 켜기]`r`n" +
        "3. 마인크래프트 런처가 열리면 '모드팩: ...' 을 고르고 [플레이] -> 멀티플레이 -> 서버 접속`r`n" +
        "   (방장에게 내 닉네임을 꼭 알려 주세요. 화이트리스트에 있어야 들어올 수 있어요)`r`n" +
        "접속 코드: $code`r`n`r`n" +
        "[ 직접 하는 방법 ]  CurseForge/Modrinth 앱을 쓸 때`r`n"
        $text = $text.Substring(0, $nl + 1) + "`r`n" + $easy + $text.Substring($nl + 1).TrimStart("`r", "`n")
    }
    $client = @(Get-AddedMods $d | Where-Object { $_.forClient })
    if ($client.Count) {
        $text += "`r`n`r`n[ 추가 모드 ]  방장이 따로 넣은 모드예요. 꼭 같이 넣어야 접속돼요! (제일 쉬운 방법으로 하면 자동으로 들어가요)`r`n"
        $text += "  방장이 보내 준 '친구용_추가모드' 폴더의 파일을 모두 내 모드팩의 mods 폴더에 넣으세요.`r`n"
        $text += "  (CurseForge/Modrinth 앱에서 모드팩 오른쪽 위 점 3개 -> Open Folder -> mods)`r`n"
        foreach ($m in $client) { $text += "  - $($m.title)  ($($m.file))`r`n" }
    }
    [IO.File]::WriteAllText($g, $text + "`r`n", $Cp949)
}

function Get-InstalledProjects($d) {
    # One Modrinth call maps every jar in mods/ to its project, so dependencies already present are skipped
    $set = @{}
    $hashes = @(Get-ChildItem -LiteralPath (Join-Path $d 'mods') -Filter '*.jar' -ErrorAction SilentlyContinue | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA1).Hash.ToLower() })
    if (-not $hashes.Count) { return $set }
    $body = @{ hashes = $hashes; algorithm = 'sha1' } | ConvertTo-Json
    $r = Invoke-Api 'https://api.modrinth.com/v2/version_files' 30 'Post' $body
    foreach ($p in $r.PSObject.Properties) { $set[$p.Value.project_id] = $true }
    return $set
}

function Add-ModrinthMod($d, $projectId, $mc, $loader, $installed, $log) {
    if ($installed.ContainsKey($projectId)) { return }
    $installed[$projectId] = $true
    $proj = Invoke-Api "https://api.modrinth.com/v2/project/$projectId"
    $q = 'loaders=' + [uri]::EscapeDataString('["' + $loader + '"]') + '&game_versions=' + [uri]::EscapeDataString('["' + $mc + '"]')
    # Pipe to unroll: PS 5.1 hands a JSON array over as a single object
    $vers = @(Invoke-Api "https://api.modrinth.com/v2/project/$projectId/version?$q" | ForEach-Object { $_ })
    if (-not $vers.Count) { throw "'$($proj.title)' 은(는) 마인크래프트 $mc / $loader 용 파일이 없어요." }
    $ver = $vers | Where-Object { $_.version_type -eq 'release' } | Select-Object -First 1
    if (-not $ver) { $ver = $vers[0] }
    $file = $ver.files | Where-Object primary | Select-Object -First 1; if (-not $file) { $file = $ver.files[0] }
    $serverSide = $proj.server_side -ne 'unsupported'
    $clientSide = $proj.client_side -ne 'unsupported'
    $friendDir = Join-Path $d '친구용_추가모드'
    New-Item -ItemType Directory -Force $friendDir | Out-Null
    $dl = Join-Path $friendDir $file.filename
    & curl.exe -L --fail -s -S --max-time 300 -o $dl $file.url
    if ($LASTEXITCODE -ne 0 -or (Get-FileHash -LiteralPath $dl -Algorithm SHA1).Hash -ne $file.hashes.sha1.ToUpper()) { throw "'$($proj.title)' 파일을 받지 못했어요." }
    if ($serverSide) { Copy-Item -LiteralPath $dl -Destination (Join-Path $d 'mods') -Force }
    if (-not $clientSide) { Remove-Item -LiteralPath $dl }   # server-only: friends don't need it
    $list = @(Get-AddedMods $d | Where-Object { $_.projectId -ne $projectId })
    $list += [pscustomobject]@{ projectId = $projectId; title = $proj.title; file = $file.filename; onServer = $serverSide; forClient = $clientSide; source = 'modrinth' }
    Save-AddedMods $d $list
    $where = @(); if ($serverSide) { $where += '서버' }; if ($clientSide) { $where += '친구용 폴더' }
    $log.Invoke("추가: $($proj.title) $($ver.version_number)  ->  $($where -join ', ')")
    foreach ($dep in @($ver.dependencies | Where-Object { $_.dependency_type -eq 'required' })) {
        $pid2 = $dep.project_id
        if (-not $pid2 -and $dep.version_id) { $pid2 = (Invoke-Api "https://api.modrinth.com/v2/version/$($dep.version_id)").project_id }
        if ($pid2) { Add-ModrinthMod $d $pid2 $mc $loader $installed $log }
    }
}

function Show-ModManager {
    $d = Get-SelDir; if (-not $d) { return }
    if (-not (Assert-ServerOff $d)) { return }
    $i = Read-Json (Join-Path $d 'server-info.json')
    if (-not $i -or -not $i.mc -or -not $i.loader) { Show-Msg '이 서버의 마인크래프트 버전 정보를 찾지 못했어요 (server-info.json).' 'Error'; return }
    $mc = $i.mc; $loader = $i.loader

    $f = New-Object Windows.Forms.Form
    $f.Text = "모드 추가 / 관리 - $($lstSrv.SelectedItem)  (마인크래프트 $mc / $loader)"; $f.Size = New-Object Drawing.Size(900, 640); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.Font = $font
    $l1 = New-Ctl Label 15 10 860 22 "Modrinth 에서 이 서버에 맞는 모드(마크 $mc, $loader)만 검색해요. 필요한 선행 모드도 같이 받아요."
    $tq = New-Ctl TextBox 15 38 600 28
    $bq = New-Ctl Button 625 36 120 32 '검색'
    $lv = New-Object Windows.Forms.ListView; $lv.Location = New-Object Drawing.Point(15, 75); $lv.Size = New-Object Drawing.Size(860, 230); $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.Font = $font
    [void]$lv.Columns.Add('모드', 230); [void]$lv.Columns.Add('설명', 430); [void]$lv.Columns.Add('다운로드', 90); [void]$lv.Columns.Add('종류', 90)
    $ba = New-Ctl Button 15 312 220 36 '선택한 모드 추가'
    $bf = New-Ctl Button 245 312 220 36 '내 컴퓨터의 .jar 파일 추가'
    $bo = New-Ctl Button 475 312 220 36 '친구용 추가모드 폴더 열기'
    $l2 = New-Ctl Label 15 360 860 22 '이 서버에 직접 추가한 모드'
    $lb = New-Ctl ListBox 15 385 600 130
    $br = New-Ctl Button 625 385 250 36 '선택한 모드 빼기'
    $lg = New-Ctl TextBox 15 525 860 70; $lg.Multiline = $true; $lg.ReadOnly = $true; $lg.ScrollBars = 'Vertical'
    $f.Controls.AddRange(@($l1, $tq, $bq, $lv, $ba, $bf, $bo, $l2, $lb, $br, $lg))
    $log = { param($m) $lg.AppendText("$m`r`n"); [Windows.Forms.Application]::DoEvents() }
    $refresh = { $lb.Items.Clear(); foreach ($m in (Get-AddedMods $d)) { $where = @(); if ($m.onServer) { $where += '서버' }; if ($m.forClient) { $where += '친구' }; [void]$lb.Items.Add("$($m.title)   [$($where -join '+')]   $($m.file)") } }
    $script:modHits = @()
    $bq.Add_Click({
            $facets = [uri]::EscapeDataString("[[`"project_type:mod`"],[`"versions:$mc`"],[`"categories:$loader`"]]")
            try { $r = Invoke-Api "https://api.modrinth.com/v2/search?query=$([uri]::EscapeDataString($tq.Text))&facets=$facets&limit=30" }
            catch { $log.Invoke("검색 실패: $($_.Exception.Message)"); return }
            $script:modHits = @($r.hits)
            $lv.Items.Clear()
            foreach ($h in $script:modHits) {
                $kind = '서버+친구'; if ($h.server_side -eq 'unsupported') { $kind = '화면 전용' } elseif ($h.client_side -eq 'unsupported') { $kind = '서버 전용' }
                $it = New-Object Windows.Forms.ListViewItem($h.title)
                [void]$it.SubItems.Add($h.description); [void]$it.SubItems.Add([string]$h.downloads); [void]$it.SubItems.Add($kind)
                [void]$lv.Items.Add($it)
            }
            $log.Invoke("검색 결과 $($script:modHits.Count)개")
        })
    $tq.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; $bq.PerformClick() } })
    $ba.Add_Click({
            if ($lv.SelectedIndices.Count -eq 0) { Show-Msg '목록에서 추가할 모드를 고르세요.'; return }
            $h = $script:modHits[$lv.SelectedIndices[0]]
            if ($h.server_side -eq 'unsupported' -and -not (Ask-YesNo "'$($h.title)' 은(는) 화면 전용 모드라서 서버에는 넣지 않고 친구용 폴더에만 넣어요. 계속할까요?")) { return }
            $f.Cursor = 'WaitCursor'
            try {
                $inst = Get-InstalledProjects $d
                if ($inst.ContainsKey($h.project_id)) { Show-Msg "'$($h.title)' 은(는) 이미 이 서버에 들어 있어요." }
                else { Add-ModrinthMod $d $h.project_id $mc $loader $inst $log; Update-FriendGuide $d; $log.Invoke('완료! 친구들에게도 친구용_추가모드 폴더의 파일을 보내 주세요.') }
            }
            catch { $log.Invoke("실패: $($_.Exception.Message)") }
            finally { $f.Cursor = 'Default'; & $refresh }
        })
    $bf.Add_Click({
            $o = New-Object Windows.Forms.OpenFileDialog; $o.Filter = '모드 파일 (*.jar)|*.jar'; $o.Multiselect = $true
            if ($o.ShowDialog($f) -ne 'OK') { return }
            $friendDir = Join-Path $d '친구용_추가모드'; New-Item -ItemType Directory -Force $friendDir | Out-Null
            $list = @(Get-AddedMods $d)
            foreach ($p in $o.FileNames) {
                $leaf = Split-Path $p -Leaf
                Copy-Item -LiteralPath $p -Destination (Join-Path $d 'mods') -Force
                Copy-Item -LiteralPath $p -Destination $friendDir -Force
                $list = @($list | Where-Object { $_.file -ne $leaf }) + [pscustomobject]@{ projectId = ''; title = $leaf; file = $leaf; onServer = $true; forClient = $true; source = 'file' }
                $log.Invoke("추가: $leaf  ->  서버, 친구용 폴더")
            }
            Save-AddedMods $d $list; Update-FriendGuide $d; & $refresh
            $log.Invoke('선행 모드가 필요한 모드라면 그 모드도 따로 추가해야 해요.')
        })
    $bo.Add_Click({ $fd = Join-Path $d '친구용_추가모드'; New-Item -ItemType Directory -Force $fd | Out-Null; Start-Process explorer.exe "`"$fd`"" })
    $br.Add_Click({
            if ($lb.SelectedIndex -lt 0) { return }
            $list = @(Get-AddedMods $d); $m = $list[$lb.SelectedIndex]
            if (-not (Ask-YesNo "'$($m.title)' 을(를) 서버에서 뺄까요?`n이 모드로 만든 아이템이나 블록은 월드에서 사라져요.")) { return }
            $rm = Join-Path $d '_removed_mods'; New-Item -ItemType Directory -Force $rm | Out-Null
            foreach ($p in @((Join-Path $d "mods\$($m.file)"), (Join-Path $d "친구용_추가모드\$($m.file)"))) { if (Test-Path -LiteralPath $p) { Move-Item -LiteralPath $p -Destination $rm -Force } }
            Save-AddedMods $d @($list | Where-Object { $_.file -ne $m.file }); Update-FriendGuide $d; & $refresh
            $log.Invoke("뺐어요: $($m.title)  (파일은 _removed_mods 폴더에 있어요)")
        })
    & $refresh
    [void]$f.ShowDialog($form)
}
$btnMods.Add_Click({ Show-ModManager })

# ---------------- Security check ----------------
function ConvertFrom-PropEscape([string]$v) { return [regex]::Replace($v, '\\u([0-9a-fA-F]{4})', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) }) }
function ConvertTo-PropEscape([string]$v) {
    # Java properties are read as ISO-8859-1 by older servers; \uXXXX escapes keep Korean text intact on every version
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $v.ToCharArray()) { if ([int]$ch -gt 126) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) } else { [void]$sb.Append($ch) } }
    return $sb.ToString()
}
function Get-Props($d) {
    $p = Join-Path $d 'server.properties'; $h = [ordered]@{}
    if (Test-Path -LiteralPath $p) { foreach ($l in [IO.File]::ReadAllLines($p)) { if ($l -match '^\s*([^#=]+?)\s*=(.*)$') { $h[$Matches[1]] = ConvertFrom-PropEscape $Matches[2].Trim() } } }
    return $h
}
function Set-Props($d, [hashtable]$changes) {
    # Rewrites only the given keys; Latin-1 keeps any other bytes in the file untouched, new values are pure ASCII
    $p = Join-Path $d 'server.properties'; $enc = [Text.Encoding]::GetEncoding(28591)
    $lines = @(); if (Test-Path -LiteralPath $p) { $lines = @([IO.File]::ReadAllLines($p, $enc)) }
    foreach ($k in $changes.Keys) {
        $val = ConvertTo-PropEscape ([string]$changes[$k])
        $found = $false
        $lines = @($lines | ForEach-Object { if ($_ -match "^\s*$([regex]::Escape($k))\s*=") { $found = $true; "$k=$val" } else { $_ } })
        if (-not $found) { $lines += "$k=$val" }
    }
    [IO.File]::WriteAllLines($p, [string[]]$lines, $enc)
}

function Get-SecurityReport($d) {
    $r = New-Object System.Collections.Generic.List[object]
    function Add-Item($ok, $title, $detail, $fix = $null) { $r.Add([pscustomobject]@{ ok = $ok; title = $title; detail = $detail; fix = $fix }) }
    $pr = Get-Props $d
    Add-Item ($pr['online-mode'] -ne 'false') '정품 인증 (online-mode)' '꺼져 있으면 아무 닉네임으로나 들어와서 남인 척할 수 있어요.' @{ 'online-mode' = 'true' }
    Add-Item ($pr['white-list'] -eq 'true' -and $pr['enforce-whitelist'] -eq 'true') '화이트리스트' '허락한 사람만 들어올 수 있게 해요. 주소가 퍼져도 모르는 사람은 못 들어와요.' @{ 'white-list' = 'true'; 'enforce-whitelist' = 'true' }
    Add-Item ($pr['enable-rcon'] -ne 'true') '원격 관리(RCON) 꺼짐' '켜져 있으면 비밀번호만 알면 밖에서 서버 명령을 내릴 수 있어요. 쓸 일이 없어요.' @{ 'enable-rcon' = 'false' }
    Add-Item ($pr['enable-query'] -ne 'true') '서버 정보 조회(Query) 꺼짐' '켜져 있으면 접속자 목록 등을 밖에서 조회할 수 있어요.' @{ 'enable-query' = 'false' }
    Add-Item ($pr['server-ip'] -eq '127.0.0.1') '내 PC 안에서만 접속 받기' '같은 와이파이(카페, 기숙사)의 다른 사람이 서버에 직접 붙지 못하게 해요. 친구들은 Playit 주소로 들어와서 영향이 없어요.' @{ 'server-ip' = '127.0.0.1' }
    $jvm = Join-Path $d 'user_jvm_args.txt'
    $hasLog4j = (Test-Path -LiteralPath $jvm) -and ((Get-Content -LiteralPath $jvm -Raw) -match 'formatMsgNoLookups=true')
    Add-Item $hasLog4j 'Log4j 보호 옵션' '예전에 유명했던 Log4Shell 공격을 한 번 더 막아 주는 옵션이에요. (최신 마크는 이미 막혀 있어요)' 'log4j'
    $ops = @(Read-Json (Join-Path $d 'ops.json') | Where-Object { $_ })
    $opNames = ($ops | ForEach-Object { $_.name }) -join ', '
    Add-Item ($ops.Count -le 3) "관리자(OP) $($ops.Count)명" "관리자는 서버를 마음대로 바꿀 수 있어요. 믿을 수 있는 사람만 두세요. $opNames"
    $cloud = $Root -match '(?i)OneDrive|Dropbox|Google ?Drive|iCloud|MEGA'
    Add-Item (-not $cloud) '클라우드 동기화 폴더 아님' "프로그램 폴더가 클라우드 동기화 폴더 안에 있으면 월드와 서버 파일이 인터넷에 올라가요. 지금 위치: $Root"
    Add-Item (-not (Test-Path -LiteralPath $PlayitKeyPlain)) 'Playit 비밀 키 암호화' '키를 이 PC에서만 풀리게 암호화해서 저장해요. 폴더가 새어 나가도 남이 키를 쓸 수 없어요.'
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Add-Item (-not $admin) '관리자 권한으로 실행 안 함' '서버를 관리자 권한으로 돌리면, 모드에 문제가 있을 때 컴퓨터 전체가 위험해져요. 그냥 더블클릭해서 실행하세요.'
    $fw = $null
    try {
        $javaDir = Join-Path $Prog 'java'
        $fw = @(Get-NetFirewallApplicationFilter -ErrorAction Stop | Where-Object { $_.Program -like "$javaDir*" } | Get-NetFirewallRule -ErrorAction Stop |
            Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and ($_.Profile -match 'Public|Any') })
    }
    catch { }
    if ($null -ne $fw) { Add-Item ($fw.Count -eq 0) '방화벽: 공용 네트워크에 서버가 안 열림' 'Playit을 쓰면 방화벽을 열 필요가 없어요. 카페 와이파이 같은 공용 네트워크에서 서버가 노출되지 않게, 처음 뜨는 방화벽 허용 창은 [취소]를 누르세요. 이미 허용했다면 제어판 → Windows Defender 방화벽 → 앱 허용에서 OpenJDK의 "공용" 체크를 끄세요.' }
    return $r
}

function Set-SafeDefaults($d) {
    # Applied silently on every start so nobody has to remember the security check
    # server-ip 127.0.0.1: only this PC (and the Playit tunnel running on it) can reach the server, not the local network
    Set-Props $d @{ 'online-mode' = 'true'; 'white-list' = 'true'; 'enforce-whitelist' = 'true'; 'enable-rcon' = 'false'; 'enable-query' = 'false'; 'server-ip' = '127.0.0.1' }
    $jvm = Join-Path $d 'user_jvm_args.txt'
    if ((Test-Path -LiteralPath $jvm) -and -not ((Get-Content -LiteralPath $jvm -Raw) -match 'formatMsgNoLookups=true')) {
        Add-Content -LiteralPath $jvm -Value '-Dlog4j2.formatMsgNoLookups=true' -Encoding ascii
    }
}

function Repair-Security($d, $report) {
    $props = @{}
    foreach ($it in $report) {
        if ($it.ok -or -not $it.fix) { continue }
        if ($it.fix -is [hashtable]) { foreach ($k in $it.fix.Keys) { $props[$k] = $it.fix[$k] } }
        elseif ($it.fix -eq 'log4j') { Add-Content -LiteralPath (Join-Path $d 'user_jvm_args.txt') -Value '-Dlog4j2.formatMsgNoLookups=true' -Encoding ascii }
    }
    if ($props.Count) { Set-Props $d $props }
}

function Show-Security {
    $d = Get-SelDir; if (-not $d) { Show-Msg '왼쪽 목록에서 서버를 고르세요.'; return }
    $f = New-Object Windows.Forms.Form
    $f.Text = "보안 점검 - $($lstSrv.SelectedItem)"; $f.Size = New-Object Drawing.Size(900, 660); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.Font = $font
    $lv = New-Object Windows.Forms.ListView; $lv.Location = New-Object Drawing.Point(15, 15); $lv.Size = New-Object Drawing.Size(855, 250); $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.Font = $font
    [void]$lv.Columns.Add('결과', 70); [void]$lv.Columns.Add('항목', 250); [void]$lv.Columns.Add('설명', 520)
    $bfix = New-Ctl Button 15 272 300 36 '고칠 수 있는 것 자동으로 고치기'
    $lnote = New-Ctl Label 325 278 545 24 ''; $lnote.ForeColor = [Drawing.Color]::DimGray
    $tips = New-Ctl TextBox 15 318 855 250; $tips.Multiline = $true; $tips.ReadOnly = $true; $tips.ScrollBars = 'Vertical'; $tips.BackColor = [Drawing.Color]::White
    $bTun = New-Ctl Button 15 575 270 36 'playit.gg 터널 페이지 열기'
    $bGuide = New-Ctl Button 295 575 270 36 '친구 접속 안내 열기'
    $bTun.Add_Click({ Open-Url 'https://playit.gg/account/tunnels' })
    $bGuide.Add_Click({ $f.Close(); Show-FriendGuide })
    $tips.Text = @"
[ 평소에 지킬 것 ]
 - 친구들에게는 Playit 주소(어쩌구.joinmc.link)만 알려 주세요. 우리 집 IP 주소는 절대 알려 주지 마세요.
   공격이 들어와도 Playit 쪽이 먼저 맞아서 우리 집 인터넷까지는 잘 안 와요.
 - 공유기 포트포워딩(25565)은 하지 마세요. Playit을 쓰면 필요 없고, 하면 집 IP가 그대로 드러나요.
 - 서버 주소를 유튜브, 디스코드 공개 채널, 커뮤니티에 올리지 마세요.

[ 공격을 받는 것 같을 때 (갑자기 렉, 다들 접속이 끊김) - 순서대로 하세요 ]
 1. 메인 화면에서 [■ 서버 끄기] → "꺼짐"이 될 때까지 기다리기
 2. 아래 [playit.gg 터널 페이지 열기] → 지금 쓰던 터널을 지우기(Delete)
 3. 같은 페이지에서 [Add Tunnel] → Minecraft Java, 127.0.0.1, 25565 로 새로 만들기
    (처음 연결할 때 [Playit 연결 설정] 창 ③단계와 같아요)
 4. 새로 생긴 주소를 복사 → 아래 [친구 접속 안내 열기] → 믿는 친구에게만 새 주소와 함께 보내기
 5. 메인 화면에서 [▶ 친구랑 하기]로 다시 켜기
 → 예전 주소는 없어졌으니 공격이 더는 우리 서버에 닿지 않아요.

[ 계정과 파일 ]
 - Playit 비밀 키는 이 PC의 이 Windows 계정에서만 풀리게 암호화해서 저장해요. 그래도 폴더를 남에게 주거나 클라우드에 올리지 마세요.
 - 비밀 키가 새어 나간 것 같으면 playit.gg 에서 그 에이전트를 지우고 키를 새로 만드세요.
 - playit.gg 계정과 마인크래프트(마이크로소프트) 계정에는 2단계 인증을 켜 두세요.

[ 모드 ]
 - 모드는 Modrinth, CurseForge 공식 사이트에서만 받으세요. 출처 모를 .jar 파일에는 악성코드가 들어 있을 수 있어요(2023년 실제 사건).
 - 이 프로그램이 받는 파일은 해시값으로 원본이 맞는지 확인하고 있어요.

[ 서버 운영 ]
 - 관리자(OP)는 꼭 필요한 사람만. 친구 추가는 화이트리스트로만 하세요.
 - 월드 백업을 자주 하세요. 누가 망가뜨려도 되돌릴 수 있어요.
 - 서버는 일반 권한으로 실행하세요(관리자 권한 X).
"@
    # A TextBox only breaks lines on CRLF; this script file is saved with LF
    $tips.Text = $tips.Text -replace "`r?`n", "`r`n"
    $f.Controls.AddRange(@($lv, $bfix, $lnote, $tips, $bTun, $bGuide))
    $fill = {
        $lv.Items.Clear(); $script:secReport = Get-SecurityReport $d; $bad = 0
        foreach ($it in $script:secReport) {
            $mark = '✔ 안전'; if (-not $it.ok) { $mark = '⚠ 확인'; $bad++ }
            $row = New-Object Windows.Forms.ListViewItem($mark); [void]$row.SubItems.Add($it.title); [void]$row.SubItems.Add($it.detail)
            if (-not $it.ok) { $row.ForeColor = [Drawing.Color]::Firebrick }
            [void]$lv.Items.Add($row)
        }
        $lnote.Text = "확인이 필요한 항목 $($bad)개"
    }
    $bfix.Add_Click({
            if (-not (Assert-ServerOff $d)) { return }
            Repair-Security $d $script:secReport; & $fill
            $left = @($script:secReport | Where-Object { -not $_.ok }).Count
            if ($left) { Show-Msg "자동으로 고칠 수 있는 건 고쳤어요. 남은 $($left)개는 설명을 보고 직접 확인해 주세요." } else { Show-Msg '모두 안전해요.' }
        })
    & $fill
    [void]$f.ShowDialog($form)
}
$btnSecurity.Add_Click({ Show-Security })

# ---------------- is a server really running? (however it was started) ----------------
function Get-LevelDir($d) { $lv = (Get-Props $d)['level-name']; if (-not $lv) { $lv = 'world' }; return Join-Path $d $lv }
function Test-ServerRunning($d) {
    if ($script:srv -and $script:srv.dir -eq $d) { return $true }
    # Minecraft keeps world\session.lock open the whole time it runs, whether started here, by the .bat or left over
    $lock = Join-Path (Get-LevelDir $d) 'session.lock'
    if (-not (Test-Path -LiteralPath $lock)) { return $false }
    try { $fs = [IO.File]::Open($lock, 'Open', 'ReadWrite', 'None'); $fs.Close(); return $false } catch { return $true }
}
function Assert-ServerOff($d) {
    if ($script:autoBk -and $script:autoBk.dir -eq $d) { Show-Msg '지금 월드를 자동으로 백업하고 있어요. 위의 상태가 "꺼짐"이 된 다음에 해 주세요. (잠깐이면 돼요)'; return $false }
    if (-not (Test-ServerRunning $d)) { return $true }
    $how = '[■ 서버 끄기]를 누르고 "꺼짐"이 된 다음에 해 주세요.'
    if (-not ($script:srv -and $script:srv.dir -eq $d)) { $how = "이 프로그램 밖에서 켜진 서버예요. 프로그램을 닫았다가 다시 켜면 찾아서 안전하게 꺼 드려요." }
    Show-Msg "서버가 켜져 있어서 지금은 할 수 없어요.`n$how" 'Warning'
    return $false
}

# ---------------- servers left running after the program was closed abnormally ----------------
$Launcher = Join-Path $Root '모드팩서버관리.exe'
function Get-OrphanServers {
    $javaRoot = Join-Path $Prog 'java'
    $mine = 0; if ($script:srv) { $mine = $script:srv.proc.P.Id }
    return @(Get-CimInstance Win32_Process -Filter "Name='java.exe'" | Where-Object {
            $_.ExecutablePath -like "$javaRoot*" -and $_.ProcessId -ne $mine -and $_.CommandLine -notmatch 'installServer' })
}
function Stop-Orphans([switch]$Ask) {
    $orphans = Get-OrphanServers
    if (-not $orphans.Count) { return $true }
    if ($Ask -and -not (Ask-YesNo "이 프로그램 밖에서 돌아가고 있는 서버가 있어요.`n(프로그램이 비정상적으로 꺼졌거나, 서버켜기.bat 으로 켠 서버예요)`n`n지금 월드를 저장하고 안전하게 끌까요?`n[아니요]를 누르면 계속 돌아가지만, 이 프로그램으로는 조작할 수 없어요.")) { return $false }
    Set-State '● 남아 있던 서버를 저장하고 끄는 중...' ([Drawing.Color]::SlateGray); $form.Refresh()
    foreach ($o in $orphans) {
        # Ctrl+C makes Java run Minecraft's shutdown hook, which saves every world before exiting
        if (Test-Path -LiteralPath $Launcher) { Start-Process -FilePath $Launcher -ArgumentList "--ctrlc $($o.ProcessId)" -WindowStyle Hidden -Wait }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (@(Get-OrphanServers).Count -and $sw.Elapsed.TotalSeconds -lt 120) { Pump 500 }
    $left = Get-OrphanServers
    if ($left.Count -and (Ask-YesNo '남아 있던 서버가 2분 넘게 안 꺼지고 있어요. 강제로 끌까요? (최근 몇 분 진행이 저장 안 될 수 있어요)')) {
        foreach ($o in $left) { Stop-Process -Id $o.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Set-State '● 꺼짐' ([Drawing.Color]::Gray)
    return -not @(Get-OrphanServers).Count
}
function Stop-OrphanPlayit {
    # A Playit started by an earlier, crashed session would clash with the one this session starts
    # Only this package's own copy: another copy of the program on the same PC may be running its own Playit
    Get-CimInstance Win32_Process -Filter "Name='playit.exe'" | Where-Object { $_.CommandLine -match 'playitd-mcserver' -and $_.ExecutablePath -like "$PlayitDir\*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

# ---------------- installs or updates that never finished ----------------
function Repair-Leftovers {
    $notes = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $ServersDir -Directory)) {
        $mk = Join-Path $f.FullName '.installing'
        if (-not (Test-Path -LiteralPath $mk)) { continue }
        $of = ''; if ((Get-Content -LiteralPath $mk -Raw) -match 'update-of=(.*)') { $of = $Matches[1].Trim() }
        try {
            if ($of -and $f.Name -eq $of) { Remove-Item -LiteralPath $mk -Force; continue }   # stopped right after the swap: it is complete
            if ($of) {
                $orig = Join-Path $ServersDir $of
                if (Test-Path -LiteralPath $orig) {
                    # Update stopped before the swap: give the world back to the original server if it had moved
                    $tw = Get-LevelDir $f.FullName; $ow = Join-Path $orig (Split-Path $tw -Leaf)
                    if ((Test-Path -LiteralPath (Join-Path $tw 'level.dat')) -and -not (Test-Path -LiteralPath $ow)) { Move-Item -LiteralPath $tw -Destination $ow; $notes += "'$of' 서버의 월드를 원래 자리로 되돌렸어요." }
                    Remove-Item -LiteralPath $f.FullName -Recurse -Force
                    $notes += "'$of' 모드팩 업데이트가 중간에 끊겨서 취소했어요. 서버는 예전 버전 그대로예요."
                }
                else {
                    # The old server was already archived: finishing the swap completes the update
                    Rename-Item -LiteralPath $f.FullName -NewName $of
                    Remove-Item -LiteralPath (Join-Path $orig '.installing') -Force
                    $notes += "'$of' 모드팩 업데이트를 마저 끝냈어요."
                }
            }
            else { Remove-Item -LiteralPath $f.FullName -Recurse -Force; $notes += "끝나지 못한 서버 만들기('$($f.Name)')를 정리했어요. 다시 만들면 돼요." }
        }
        catch { $notes += "'$($f.Name)' 정리 중 문제가 생겼어요: $($_.Exception.Message)" }
    }
    if ($notes.Count) { Show-Msg ($notes -join "`n") }
}

# ---------------- backups and world reset (all in-app, server must be off) ----------------
function Start-ZipProc($w, $out) {
    # Zips the world in a background PowerShell so the window stays responsive on big worlds
    $cmd = "Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::CreateFromDirectory('$($w -replace "'", "''")', '$($out -replace "'", "''")')"
    return New-Object McProc('powershell.exe', "-NoProfile -Command `"$cmd`"", (Split-Path $out -Parent), [Text.Encoding]::Default.CodePage)
}
function New-WorldBackup($d, [string]$tag) {
    $w = Get-LevelDir $d
    if (-not (Test-Path -LiteralPath $w)) { return $null }
    $bk = Join-Path $d 'backups'; New-Item -ItemType Directory -Force $bk | Out-Null
    $zip = Join-Path $bk ("${tag}_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.zip')
    # Written under a temporary name: a half-made zip must never show up as a backup you can restore
    $p = Start-ZipProc $w "$zip.part"
    while ($p.Running) { Pump 300 }
    if ((Test-Path -LiteralPath "$zip.part") -and (Get-Item -LiteralPath "$zip.part").Length -gt 0) { Move-Item -LiteralPath "$zip.part" -Destination $zip; return $zip }
    Remove-Item -LiteralPath "$zip.part" -Force -ErrorAction SilentlyContinue
    return $null
}

# Every clean stop leaves a backup behind, so a beginner always has yesterday's world even if they never pressed a button
$AutoBackupKeep = 5
$script:autoBk = $null
function Start-AutoBackup($d) {
    $w = Get-LevelDir $d
    if (-not (Test-Path -LiteralPath (Join-Path $w 'level.dat'))) { return }
    $bk = Join-Path $d 'backups'; New-Item -ItemType Directory -Force $bk | Out-Null
    Get-ChildItem -LiteralPath $bk -Filter '*.part' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    $size = [long](Get-ChildItem -LiteralPath $w -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($d))
    if ($drive.AvailableFreeSpace -lt ($size + 2GB)) {
        $txtConsole.AppendText("[관리 프로그램] 디스크 공간이 모자라서 이번에는 자동 백업을 건너뛰었어요. 오래된 백업이나 servers_old 폴더를 지우면 공간이 생겨요.`r`n")
        return
    }
    $zip = Join-Path $bk ('auto_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.zip')
    $script:autoBk = [pscustomobject]@{ proc = (Start-ZipProc $w "$zip.part"); dir = $d; zip = $zip }
    $btnStart.Enabled = $false; $btnLocal.Enabled = $false
    Set-State '● 자동 백업 중...  (금방 끝나요)' ([Drawing.Color]::SlateGray)
    $lblStage.Text = '서버는 안전하게 꺼졌어요. 월드를 자동으로 백업하고 있어요.'
}
function Complete-AutoBackup {
    $b = $script:autoBk; $script:autoBk = $null
    if (-not $b) { return }
    $part = "$($b.zip).part"
    $btnStart.Enabled = -not $script:srv; $btnLocal.Enabled = -not $script:srv
    if ((Test-Path -LiteralPath $part) -and (Get-Item -LiteralPath $part).Length -gt 0) {
        Move-Item -LiteralPath $part -Destination $b.zip
        # Only the automatic ones are pruned; backups the user made by hand stay until they delete them
        Get-ChildItem -LiteralPath (Split-Path $b.zip -Parent) -Filter 'auto_*.zip' | Sort-Object Name -Descending | Select-Object -Skip $AutoBackupKeep |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $txtConsole.AppendText("[관리 프로그램] 월드를 자동으로 백업했어요: $(Split-Path $b.zip -Leaf) (최근 $($AutoBackupKeep)개만 남겨요)`r`n")
        if (-not $script:srv) { Set-State '● 꺼짐' ([Drawing.Color]::Gray); $lblStage.Text = '서버가 안전하게 꺼졌고, 월드도 자동으로 백업했어요.' }
    }
    else {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        $txtConsole.AppendText("[관리 프로그램] 자동 백업을 만들지 못했어요. [백업 / 월드 관리] → [지금 백업하기]로 한 번 해 주세요.`r`n")
        if (-not $script:srv) { Set-State '● 꺼짐' ([Drawing.Color]::Gray); $lblStage.Text = '서버는 안전하게 꺼졌어요. (자동 백업은 실패했어요)' }
    }
}
function Restore-WorldBackup($d, [string]$zip) {
    $w = Get-LevelDir $d
    $tmp = Join-Path $d ('_restore_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
    # Older backups hold a "world" folder; newer ones hold the world's contents directly
    $src = $tmp; $top = @(Get-ChildItem -LiteralPath $tmp -Force)
    if ($top.Count -eq 1 -and $top[0].PSIsContainer -and -not (Test-Path -LiteralPath (Join-Path $tmp 'level.dat'))) { $src = $top[0].FullName }
    if (-not (Test-Path -LiteralPath (Join-Path $src 'level.dat'))) { Remove-Item -LiteralPath $tmp -Recurse -Force; throw '이 백업 파일에는 월드가 들어 있지 않아요.' }
    if (Test-Path -LiteralPath $w) { Remove-Item -LiteralPath $w -Recurse -Force }
    Move-Item -LiteralPath $src -Destination $w
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}

function Show-Backups {
    $d = Get-SelDir; if (-not $d) { return }
    $f = New-Object Windows.Forms.Form
    $f.Text = "백업 / 월드 관리 - $($lstSrv.SelectedItem)"; $f.Size = New-Object Drawing.Size(760, 520); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.Font = $font
    $l1 = New-Ctl Label 15 12 720 40 "서버를 끌 때마다 자동으로 백업해요(auto_, 최근 $($AutoBackupKeep)개). 아래 기능은 모두 서버를 끈 상태에서만 돼요.`n되돌리거나 새로 만들기 전에 지금 월드를 자동으로 한 번 더 백업해요."
    $lv = New-Object Windows.Forms.ListView; $lv.Location = New-Object Drawing.Point(15, 58); $lv.Size = New-Object Drawing.Size(715, 280); $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.Font = $font
    [void]$lv.Columns.Add('백업', 360); [void]$lv.Columns.Add('만든 때', 190); [void]$lv.Columns.Add('크기', 140)
    $bNow = New-Ctl Button 15 348 230 38 '지금 백업하기'
    $bRestore = New-Ctl Button 255 348 230 38 '선택한 백업으로 되돌리기'
    $bOpen = New-Ctl Button 495 348 235 38 '백업 폴더 열기'
    $bReset = New-Ctl Button 15 400 300 38 '월드 새로 만들기 (처음부터)'
    $bReset.ForeColor = [Drawing.Color]::Firebrick
    $lst = New-Ctl Label 330 395 400 75 ''; $lst.ForeColor = [Drawing.Color]::DarkGreen
    $f.Controls.AddRange(@($l1, $lv, $bNow, $bRestore, $bOpen, $bReset, $lst))
    $fill = {
        $lv.Items.Clear()
        $script:bkFiles = @(Get-ChildItem -LiteralPath (Join-Path $d 'backups') -Filter '*.zip' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
        foreach ($b in $script:bkFiles) {
            $it = New-Object Windows.Forms.ListViewItem($b.Name)
            [void]$it.SubItems.Add($b.LastWriteTime.ToString('yyyy-MM-dd HH:mm')); [void]$it.SubItems.Add(('{0:N0} MB' -f ($b.Length / 1MB)))
            [void]$lv.Items.Add($it)
        }
    }
    $bNow.Add_Click({
            if (-not (Assert-ServerOff $d)) { return }
            $lst.Text = '백업하는 중... (월드가 크면 몇 분 걸려요)'; $f.Cursor = 'WaitCursor'
            $z = New-WorldBackup $d 'backup'
            $f.Cursor = 'Default'
            if ($z) { $lst.Text = "백업했어요: $(Split-Path $z -Leaf)" } else { $lst.Text = '백업할 월드가 없어요. (서버를 한 번도 안 켰다면 월드가 아직 없어요)' }
            & $fill
        })
    $bRestore.Add_Click({
            if ($lv.SelectedIndices.Count -eq 0) { Show-Msg '목록에서 되돌릴 백업을 고르세요.'; return }
            if (-not (Assert-ServerOff $d)) { return }
            $b = $script:bkFiles[$lv.SelectedIndices[0]]
            if (-not (Ask-YesNo "'$($b.Name)' 시점으로 월드를 되돌릴까요?`n지금 월드는 되돌리기 전에 자동으로 백업해 둬요.")) { return }
            $f.Cursor = 'WaitCursor'; $lst.Text = '지금 월드를 백업하는 중...'
            try {
                if ((Test-Path -LiteralPath (Get-LevelDir $d)) -and -not (New-WorldBackup $d 'before-restore')) { throw '지금 월드를 백업하지 못해서 되돌리기를 멈췄어요.' }
                $lst.Text = '되돌리는 중...'; Pump 50
                Restore-WorldBackup $d $b.FullName
                $lst.Text = "되돌렸어요: $($b.Name)"
            }
            catch { Show-Msg "되돌리지 못했어요: $($_.Exception.Message)" 'Error'; $lst.Text = '' }
            finally { $f.Cursor = 'Default'; & $fill }
        })
    $bOpen.Add_Click({ $bd = Join-Path $d 'backups'; New-Item -ItemType Directory -Force $bd | Out-Null; Start-Process explorer.exe "`"$bd`"" })
    $bReset.Add_Click({
            if (-not (Assert-ServerOff $d)) { return }
            if (-not (Ask-YesNo "월드를 처음부터 새로 만들까요?`n지금 월드는 자동으로 백업해 둬서, 나중에 [선택한 백업으로 되돌리기]로 돌아올 수 있어요.`n`n화이트리스트, 설정, 모드는 그대로예요.")) { return }
            $seed = (Ask-Text "새 월드의 시드(seed)를 정할 수 있어요.`n모르면 비워 두세요 (무작위).").Trim()
            $f.Cursor = 'WaitCursor'; $lst.Text = '지금 월드를 백업하는 중...'
            try {
                $w = Get-LevelDir $d
                if (Test-Path -LiteralPath $w) {
                    if (-not (New-WorldBackup $d 'before-reset')) { throw '지금 월드를 백업하지 못해서 멈췄어요.' }
                    # Datapacks that came with the modpack stay; everything else goes
                    $dp = Join-Path $w 'datapacks'; $keep = Join-Path $d ('_dp_' + [guid]::NewGuid().ToString('N').Substring(0, 6))
                    if (Test-Path -LiteralPath $dp) { Move-Item -LiteralPath $dp -Destination $keep }
                    Remove-Item -LiteralPath $w -Recurse -Force
                    if (Test-Path -LiteralPath $keep) { New-Item -ItemType Directory -Force $w | Out-Null; Move-Item -LiteralPath $keep -Destination (Join-Path $w 'datapacks') }
                }
                Set-Props $d @{ 'level-seed' = $seed }
                $lst.Text = '새 월드는 다음에 서버를 켤 때 만들어져요.'
            }
            catch { Show-Msg "새로 만들지 못했어요: $($_.Exception.Message)" 'Error'; $lst.Text = '' }
            finally { $f.Cursor = 'Default'; & $fill }
        })
    & $fill
    [void]$f.ShowDialog($form)
}

# ---------------- server settings (server.properties without Notepad) ----------------
function Show-ServerSettings {
    $d = Get-SelDir; if (-not $d) { return }
    $pr = Get-Props $d
    $f = New-Object Windows.Forms.Form
    $f.Text = "서버 설정 - $($lstSrv.SelectedItem)"; $f.Size = New-Object Drawing.Size(620, 640); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.Font = $font
    $running = Test-ServerRunning $d
    $top = New-Ctl Label 15 10 580 40 '바꾼 설정은 다음에 서버를 켤 때부터 적용돼요.'
    if ($running) { $top.Text = '서버가 켜져 있어서 지금은 볼 수만 있어요. 서버를 끈 다음에 바꿔 주세요.'; $top.ForeColor = [Drawing.Color]::Firebrick }
    $f.Controls.Add($top)
    $y = 55; $ctl = @{}
    function Row($label) { $l = New-Ctl Label 15 ($script:rowY + 3) 230 24 $label; $f.Controls.Add($l) }
    $script:rowY = $y
    function Add-Combo($key, $label, $opts, $def) {
        Row $label
        $c = New-Ctl ComboBox 250 $script:rowY 330 28; $c.DropDownStyle = 'DropDownList'
        foreach ($o in $opts) { [void]$c.Items.Add($o[1]) }
        $cur = $pr[$key]; if (-not $cur) { $cur = $def }
        $idx = 0; for ($i = 0; $i -lt $opts.Count; $i++) { if ($opts[$i][0] -eq $cur) { $idx = $i } }
        $c.SelectedIndex = $idx; $f.Controls.Add($c); $ctl[$key] = @{ kind = 'combo'; c = $c; opts = $opts }; $script:rowY += 36
    }
    function Add-Num($key, $label, $min, $max, $def) {
        Row $label
        $n = New-Ctl NumericUpDown 250 $script:rowY 90 28; $n.Minimum = $min; $n.Maximum = $max
        $v = $def; if ($pr[$key] -match '^\d+$') { $v = [int]$pr[$key] }; $n.Value = [Math]::Min($max, [Math]::Max($min, $v))
        $f.Controls.Add($n); $ctl[$key] = @{ kind = 'num'; c = $n }; $script:rowY += 36
    }
    function Add-Check($key, $label, $def) {
        $c = New-Ctl CheckBox 15 $script:rowY 565 26 $label
        $v = $pr[$key]; if (-not $v) { $v = $def }; $c.Checked = $v -eq 'true'
        $f.Controls.Add($c); $ctl[$key] = @{ kind = 'check'; c = $c }; $script:rowY += 32
    }
    Row '서버 설명 (목록에 보이는 글)'
    $motd = New-Ctl TextBox 250 $script:rowY 330 28; $motd.Text = $pr['motd']; $f.Controls.Add($motd); $script:rowY += 36
    Add-Combo 'difficulty' '난이도' @(@('peaceful', '평화로움 (몬스터 없음)'), @('easy', '쉬움'), @('normal', '보통'), @('hard', '어려움')) 'normal'
    Add-Combo 'gamemode' '처음 들어온 사람의 게임 모드' @(@('survival', '서바이벌'), @('creative', '크리에이티브'), @('adventure', '모험'), @('spectator', '관전')) 'survival'
    Add-Num 'max-players' '최대 인원' 1 100 10
    Add-Num 'view-distance' '시야 거리 (낮추면 렉이 줄어요)' 3 32 10
    Add-Num 'simulation-distance' '움직이는 거리 (낮추면 렉이 줄어요)' 3 32 10
    Add-Num 'spawn-protection' '스폰 보호 범위 (블록)' 0 64 16
    Add-Check 'pvp' '플레이어끼리 공격 가능 (PvP)' 'true'
    Add-Check 'hardcore' '하드코어 (죽으면 관전 모드)' 'false'
    Add-Check 'allow-flight' '비행 허용 (모드팩은 켜 두는 게 좋아요. 끄면 날개나 탈것을 쓸 때 쫓겨날 수 있어요)' 'true'
    Add-Check 'allow-nether' '지옥(네더) 허용' 'true'
    Add-Check 'spawn-monsters' '몬스터 나오기' 'true'
    Add-Check 'enable-command-block' '명령 블록 허용' 'false'
    $bs = New-Ctl Button 15 ($script:rowY + 10) 270 40 '저장'; $bs.Font = $bold
    $bc = New-Ctl Button 300 ($script:rowY + 10) 140 40 '닫기'
    $bs.Enabled = -not $running
    $f.Controls.AddRange(@($bs, $bc))
    $f.ClientSize = New-Object Drawing.Size(600, ($script:rowY + 65))
    $bc.Add_Click({ $f.Close() })
    $bs.Add_Click({
            if (-not (Assert-ServerOff $d)) { return }
            $ch = @{ 'motd' = ($motd.Text -replace '[\r\n]', ' ') }
            foreach ($k in $ctl.Keys) {
                $e = $ctl[$k]
                switch ($e.kind) {
                    'combo' { $ch[$k] = $e.opts[$e.c.SelectedIndex][0] }
                    'num' { $ch[$k] = [string][int]$e.c.Value }
                    'check' { $ch[$k] = ([string]$e.c.Checked).ToLower() }
                }
            }
            Set-Props $d $ch
            Show-Msg '저장했어요. 다음에 서버를 켤 때부터 적용돼요.'
            $f.Close()
        })
    [void]$f.ShowDialog($form)
}

# ---------------- friend guide (copy to clipboard instead of Notepad) ----------------
function Show-FriendGuide {
    $d = Get-SelDir; if (-not $d) { return }
    Update-FriendGuide $d
    $g = Join-Path $d '친구접속안내.txt'
    $text = ''; if (Test-Path -LiteralPath $g) { $text = [IO.File]::ReadAllText($g, $Cp949) }
    $f = New-Object Windows.Forms.Form
    $f.Text = "친구 접속 안내 - $($lstSrv.SelectedItem)"; $f.Size = New-Object Drawing.Size(760, 560); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.Font = $font
    $l = New-Ctl Label 15 10 720 24 '아래 글을 복사해서 카톡이나 디스코드로 친구에게 보내 주세요.'
    $tb = New-Ctl TextBox 15 38 715 400; $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'; $tb.Text = ($text -replace "`r?`n", "`r`n"); $tb.BackColor = [Drawing.Color]::White
    $bc = New-Ctl Button 15 448 230 40 '글 전체 복사'; $bc.Font = $bold
    $bm = New-Ctl Button 255 448 260 40 '친구용 추가모드 폴더 열기'
    $done = New-Ctl Label 525 455 205 30 ''; $done.ForeColor = [Drawing.Color]::DarkGreen
    $bm.Enabled = Test-Path -LiteralPath (Join-Path $d '친구용_추가모드')
    $bc.Add_Click({ [Windows.Forms.Clipboard]::SetText($tb.Text); $done.Text = '복사했어요!' })
    $bm.Add_Click({ Start-Process explorer.exe "`"$(Join-Path $d '친구용_추가모드')`"" })
    $f.Controls.AddRange(@($l, $tb, $bc, $bm, $done))
    [void]$f.ShowDialog($form)
}

# =====================================================================================
# Playing: the same modpack as a game installation in the official Minecraft Launcher
# (install.ps1 -Client does the work; logging in stays with the launcher and the player's account)
# =====================================================================================
$ProgramZipUrl = 'https://github.com/epaldks10-ship-it/mc-modpack-server-manager-release/releases/latest/download/ModpackServerManager.zip'
function Get-McDirPath { if ($env:MCSM_MCDIR) { return $env:MCSM_MCDIR } return Join-Path $env:APPDATA '.minecraft' }
function Test-McLauncher {
    if (Test-Path -LiteralPath (Join-Path (Get-McDirPath) 'launcher_profiles.json')) { return $true }
    if (Ask-YesNo "공식 마인크래프트 런처를 찾지 못했어요.`n`n① 지금 열리는 페이지에서 런처를 받아 설치`n② 런처를 한 번 켜서 마이크로소프트 계정으로 로그인`n③ 이 버튼을 다시 누르기`n`n다운로드 페이지를 열까요?") { Open-Url 'https://www.minecraft.net/download' }
    return $false
}
function Get-LauncherProcs {
    if ($env:MCSM_MCDIR) { return @() }   # the simulator never touches the real launcher
    return @(Get-CimInstance Win32_Process -Filter "Name='Minecraft.exe' OR Name='MinecraftLauncher.exe'" -ErrorAction SilentlyContinue)
}
function Close-McLauncher {
    # The launcher keeps its installation list in memory and writes it back on exit, so it must be closed while we add ours
    $procs = Get-LauncherProcs
    if (-not $procs.Count) { return $true }
    if (-not (Ask-YesNo "마인크래프트 런처가 켜져 있어요.`n런처에 모드팩을 넣으려면 잠깐 닫아야 해요. (다 되면 다시 열어 드려요)`n`n런처를 닫을까요?")) { return $false }
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Pump 1500
    return $true
}
function Start-McLauncher {
    if ($env:MCSM_MCDIR) { return $true }
    $pkg = Get-AppxPackage -Name 'Microsoft.4297127D64EC6' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pkg) { Start-Process explorer.exe "shell:AppsFolder\$($pkg.PackageFamilyName)!Minecraft"; return $true }
    foreach ($exe in @("${env:ProgramFiles(x86)}\Minecraft Launcher\MinecraftLauncher.exe", "$env:ProgramFiles\Minecraft Launcher\MinecraftLauncher.exe", "$env:LOCALAPPDATA\Programs\Minecraft Launcher\MinecraftLauncher.exe")) {
        if (Test-Path -LiteralPath $exe) { Start-Process -FilePath $exe; return $true }
    }
    return $false
}
function Test-GameRunning([string]$gd) {
    return [bool](Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($gd) })
}
function Get-GameRam([int]$serverRam = 0) {
    # What is left after Windows (about 3GB) and a server running on the same PC, between 3 and 8GB
    return [int][Math]::Max(3, [Math]::Min(8, $totalRam - $serverRam - 3))
}
function Stop-GameIfRunning([string]$gd) {
    # A game left open (or frozen on an error screen) would hold its files; offer to close it
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='javaw.exe' OR Name='java.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($gd) })
    if (-not $procs.Count) { return $true }
    if (-not (Ask-YesNo "이 서버용 마인크래프트가 아직 켜져 있어요. (멈춘 상태일 수도 있어요)`n`n게임을 닫고 다시 준비할까요?")) { return $false }
    foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    Pump 2000
    return $true
}

function Start-HostGame {
    $d = Get-SelDir; if (-not $d) { Show-Msg '왼쪽 목록에서 서버를 고르세요.'; return }
    if ($script:installProc) { Show-Msg '다른 설치나 업데이트가 진행 중이에요. 끝난 다음에 해 주세요.'; return }
    $i = Read-Json (Join-Path $d 'server-info.json'); if (-not $i -or -not $i.pack) { Show-Msg '이 서버의 모드팩 정보를 찾지 못했어요.' 'Warning'; return }
    if (-not (Test-McLauncher)) { return }
    $name = $lstSrv.SelectedItem
    $gd = Join-Path $GameRoot $name
    if (-not (Stop-GameIfRunning $gd)) { return }
    # The host needs to be on the whitelist too; ask once here instead of letting the first join bounce
    $wl = Read-Json (Join-Path $d 'whitelist.json')
    if (-not @($wl).Count -and -not (Test-Path -LiteralPath (Join-Path $d 'whitelist-pending.txt'))) {
        $nick = (Ask-Text "내 마인크래프트 닉네임(자바 에디션 계정 이름)을 입력하세요.`n내 서버에 들어가려면 화이트리스트에 내 이름이 있어야 해요.").Trim()
        if ($nick -match '^[A-Za-z0-9_]{3,16}$') { [void](Add-Whitelist $d $nick) }
        elseif ($nick) { Show-Msg '마인크래프트 닉네임은 영어, 숫자, _ 로 3~16글자예요. 나중에 [친구 추가]로 넣어 주세요.' }
    }
    if (-not (Close-McLauncher)) { return }
    $sr = 0; if ($totalRam -lt 24) { $sr = Get-ServerRam $d }
    # Server and game share this PC's memory; a modpack game wants about 6GB, Windows about 3GB
    if ($sr -and ($totalRam - $sr - 3) -lt 6 -and $sr -gt 4) {
        if (Ask-YesNo "이 컴퓨터의 램은 약 $($totalRam)GB예요. 서버($($sr)GB)와 게임을 같이 켜면 램이 모자라서 게임이 멈출 수 있어요.`n`n서버 램을 4GB로 줄이고 게임에 더 줄까요? (권장, 서버를 다음에 켤 때부터 적용돼요)") {
            Set-ServerRam $d 4; $sr = 4; Show-SrvInfo
            if ($script:srv) { Show-Msg "서버 램을 4GB로 바꿨어요. 지금 켜진 서버에는 [■ 서버 끄기] → 다시 켜기를 해야 적용돼요." }
        }
    }
    $script:gameJob = @{ gameDir = $gd }
    Start-InstallJob "-Client -PackId $($i.pack) -VersionKey `"$($i.version)`" -Name `"$name`" -FromServer `"$d`" -GameDir `"$gd`" -Address localhost -GameRamGB $(Get-GameRam $sr)" 'game'
}
$btnPlay.Add_Click({ Start-HostGame })

function Complete-GameJob([bool]$ok) {
    $kind = $script:jobKind
    if (-not $ok) {
        if ($kind -eq 'join') { $lblJoinWork.ForeColor = [Drawing.Color]::Firebrick; $lblJoinWork.Text = "게임 준비에 실패했어요. 이유: $($script:installErr)" }
        else { $lblStage.Text = "게임 준비에 실패했어요. 이유: $($script:installErr)" }
        Show-Msg "게임 준비에 실패했어요.`n이유: $($script:installErr)`n`n인터넷을 확인하고 다시 눌러 주세요." 'Warning'
        return
    }
    $m = Read-Json (Join-Path $script:gameJob.gameDir 'mcsm-game.json')
    $opened = Start-McLauncher
    $steps = "런처가 열리면:`n① [플레이] 버튼 옆의 설치 목록에서 '$($m.profileName)' 고르기`n② [플레이] → 마인크래프트가 켜지면 [멀티플레이]`n③ 맨 위의 '$($m.serverEntry)' 를 골라 [서버 접속]"
    if (-not $opened) { $steps = "마인크래프트 런처를 직접 열어 주세요.`n" + $steps }
    if ($kind -eq 'game') {
        $lblStage.Text = "게임 준비 완료! 런처에서 '$($m.profileName)' → [플레이] → 멀티플레이 → '$($m.serverEntry)'"
        if (-not $script:srv) { $steps += "`n`n※ 지금 서버가 꺼져 있어요. 게임이 켜지는 동안 [▶ 친구랑 하기] 또는 [▶ 혼자 하기]로 서버도 켜 주세요." }
    }
    else { $lblJoinWork.ForeColor = [Drawing.Color]::DarkGreen; $lblJoinWork.Text = "준비 완료! 런처에서 '$($m.profileName)' → [플레이] → 멀티플레이 → '$($m.serverEntry)'"; Update-JoinedList }
    if ([int]$m.ramGB -lt 4) { $steps += "`n`n※ 이 컴퓨터 램이 넉넉하지 않아서 게임 램을 $($m.ramGB)GB로 잡았어요. 버벅이면 다른 프로그램을 닫아 주세요." }
    Show-Msg "게임 준비가 끝났어요!`n`n$steps"
}

# ---------------- join code: everything a friend's copy needs to set up the same game ----------------
function ConvertTo-B64Url([string]$s) { return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function ConvertFrom-B64Url([string]$s) {
    $s = $s.Replace('-', '+').Replace('_', '/'); while ($s.Length % 4) { $s += '=' }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s))
}
function Get-VersionKey($d, $i) {
    # CurseForge versions are named by label; Modrinth ones by id (older servers kept only the label, look it up once)
    if ($i.PSObject.Properties['versionKey'] -and $i.versionKey) { return $i.versionKey }
    $p = $packs | Where-Object { $_.id -eq $i.pack } | Select-Object -First 1
    if (-not $p -or $p.source -ne 'modrinth') { return $i.version }
    try {
        $v = @(Invoke-Api "https://api.modrinth.com/v2/project/$($p.slug)/version" | ForEach-Object { $_ }) | Where-Object { $_.version_number -eq $i.version } | Select-Object -First 1
        if ($v) { Set-InfoField $d 'versionKey' $v.id; return $v.id }
    }
    catch { }
    return $i.version
}
function Get-JoinCode($d) {
    $i = Read-Json (Join-Path $d 'server-info.json'); if (-not $i -or -not $i.pack) { return '' }
    $mods = @(Get-AddedMods $d | Where-Object { $_.forClient -and $_.projectId } | ForEach-Object { [ordered]@{ p = $_.projectId; f = $_.file } })
    $o = [ordered]@{ v = 1; p = $i.pack; k = (Get-VersionKey $d $i); n = (Split-Path $d -Leaf); a = (Get-PlayitAddress); m = $mods }
    return 'MCSM1-' + (ConvertTo-B64Url ($o | ConvertTo-Json -Compress -Depth 4))
}
function Read-JoinCode([string]$text) {
    $m = [regex]::Match($text, 'MCSM1-([A-Za-z0-9_-]{8,})'); if (-not $m.Success) { return $null }
    try { $c = ConvertFrom-B64Url $m.Groups[1].Value | ConvertFrom-Json } catch { return $null }
    if (-not $c.p -or -not $c.k -or "$($c.n)" -notmatch '^[A-Za-z0-9]([A-Za-z0-9 ._-]{0,58}[A-Za-z0-9_-])?$') { return $null }
    return $c
}

# =====================================================================================
# Tab: join a friend's server
# =====================================================================================
$lblJ1 = New-Ctl Label 10 10 940 44 "방장(서버를 연 친구)이 보내 준 [친구 접속 안내] 글을 통째로 아래 칸에 붙여 넣으세요.`n글 안의 접속 코드를 보고 같은 모드팩, 같은 버전, 추가 모드까지 알아서 설치해요. CurseForge 앱은 필요 없어요."
$txtCode = New-Ctl TextBox 10 58 940 84; $txtCode.Multiline = $true; $txtCode.ScrollBars = 'Vertical'
$lblJInfo = New-Ctl Label 10 148 940 44 '(아직 붙여 넣지 않았어요)'; $lblJInfo.ForeColor = [Drawing.Color]::DimGray
$lblJAddr = New-Ctl Label 10 200 100 24 '서버 주소'
$txtJAddr = New-Ctl TextBox 110 197 360 28
$lblJRam = New-Ctl Label 500 200 110 24 '게임 램(GB)'
$numJRam = New-Ctl NumericUpDown 610 197 60 28; $numJRam.Minimum = 2; $numJRam.Maximum = [Math]::Max(2, $totalRam - 2); $numJRam.Value = [Math]::Min($numJRam.Maximum, (Get-GameRam 0))
$btnJoin = New-Ctl Button 10 236 300 48 '▶ 설치하고 게임 켜기'; $btnJoin.Font = $bold; $btnJoin.BackColor = [Drawing.Color]::FromArgb(214, 240, 214)
$lblJoinWork = New-Ctl Label 320 236 630 48 ''; $lblJoinWork.ForeColor = [Drawing.Color]::DarkGreen
$lblJList = New-Ctl Label 10 296 400 22 '설치해 둔 친구 서버 (다음부터는 여기서 바로 켜요)'
$lstJoined = New-Ctl ListBox 10 320 400 210
$btnJoinAgain = New-Ctl Button 10 536 195 38 '▶ 게임 켜기'; $btnJoinAgain.Font = $bold
$btnJoinDel = New-Ctl Button 215 536 195 38 '지우기'
$txtJoinLog = New-Ctl TextBox 420 296 530 320; $txtJoinLog.Multiline = $true; $txtJoinLog.ReadOnly = $true; $txtJoinLog.ScrollBars = 'Vertical'; $txtJoinLog.Font = $mono; $txtJoinLog.BackColor = [Drawing.Color]::White
$tabJoin.Controls.AddRange(@($lblJ1, $txtCode, $lblJInfo, $lblJAddr, $txtJAddr, $lblJRam, $numJRam, $btnJoin, $lblJoinWork, $lblJList, $lstJoined, $btnJoinAgain, $btnJoinDel, $txtJoinLog))

$script:joinCode = $null
$txtCode.Add_TextChanged({
        $c = Read-JoinCode $txtCode.Text
        $script:joinCode = $c
        if (-not $c) {
            $lblJInfo.ForeColor = [Drawing.Color]::Firebrick
            $lblJInfo.Text = '접속 코드(MCSM1-로 시작)를 찾지 못했어요. 방장에게 [친구 접속 안내]의 [글 전체 복사]로 다시 받아 주세요.'
            if (-not $txtCode.Text.Trim()) { $lblJInfo.ForeColor = [Drawing.Color]::DimGray; $lblJInfo.Text = '(아직 붙여 넣지 않았어요)' }
            return
        }
        $p = $packs | Where-Object { $_.id -eq $c.p } | Select-Object -First 1
        $ver = $c.k; if ($p -and $p.source -eq 'curseforge' -and -not ($p.versions | Where-Object label -eq $c.k)) { $p = $null }
        if (-not $p) { $lblJInfo.ForeColor = [Drawing.Color]::Firebrick; $lblJInfo.Text = '이 프로그램이 모르는 모드팩이나 버전이에요. 프로그램을 껐다가 다시 켜서 최신 버전으로 업데이트한 다음 다시 붙여 넣어 주세요.'; $script:joinCode = $null; return }
        $lblJInfo.ForeColor = [Drawing.Color]::DarkGreen
        $lblJInfo.Text = "서버: $($c.n)   |   모드팩: $($p.name)   |   방장이 추가한 모드: $(@($c.m).Count)개`n아래 [▶ 설치하고 게임 켜기]를 누르세요."
        if ($c.a) { $txtJAddr.Text = $c.a }
    })
function ConvertTo-ModsB64($list) {
    # Written by hand: Windows PowerShell 5.1 re-serializes arrays that came out of ConvertFrom-Json as {"value":[...],"Count":n}
    $items = @(foreach ($x in @($list)) {
            if ("$($x.p)" -match '^[A-Za-z0-9]{4,16}$' -and "$($x.f)" -match '^[A-Za-z0-9 ._+()\[\]-]+\.jar$') { '{"p":"' + $x.p + '","f":"' + $x.f + '"}' }
        })
    if (-not $items.Count) { return '' }
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('[' + ($items -join ',') + ']'))
}
function Start-JoinGame($c, [string]$addr, [int]$ram, $modsB64 = $null) {   # untyped: a [string] parameter would turn $null into ''
    if ($script:installProc) { Show-Msg '다른 설치가 진행 중이에요. 끝난 다음에 해 주세요.'; return }
    if ($addr -match '^\s*localhost\s*$') { $addr = 'localhost' } else { $addr = ConvertTo-PlayitAddress $addr }
    if (-not $addr) { Show-Msg "서버 주소를 넣어 주세요.`n방장에게 '어쩌구.joinmc.link' 같은 주소를 물어봐서 [서버 주소] 칸에 넣으면 돼요."; return }
    if (-not (Test-McLauncher)) { return }
    $gd = Join-Path $GameRoot "join-$($c.n)"
    if (-not (Stop-GameIfRunning $gd)) { return }
    if (-not (Close-McLauncher)) { return }
    $mods = $modsB64; if ($null -eq $mods) { $mods = ConvertTo-ModsB64 $c.m }
    $script:gameJob = @{ gameDir = $gd }
    $tabs.SelectedTab = $tabJoin
    Start-InstallJob "-Client -PackId $($c.p) -VersionKey `"$($c.k)`" -Name `"$($c.n)`" -GameDir `"$gd`" -Address `"$addr`" -AddedMods `"$mods`" -GameRamGB $ram" 'join'
}
$btnJoin.Add_Click({
        if (-not $script:joinCode) { Show-Msg '먼저 방장이 보내 준 안내 글(접속 코드)을 위 칸에 붙여 넣어 주세요.'; return }
        Start-JoinGame $script:joinCode $txtJAddr.Text ([int]$numJRam.Value)
    })
$script:joined = @()
function Update-JoinedList {
    $lstJoined.Items.Clear(); $script:joined = @()
    foreach ($g in @(Get-ChildItem -LiteralPath $GameRoot -Directory -Filter 'join-*' -ErrorAction SilentlyContinue)) {
        $m = Read-Json (Join-Path $g.FullName 'mcsm-game.json'); if (-not $m) { continue }
        $script:joined += , @($g.FullName, $m)
        [void]$lstJoined.Items.Add("$($m.name)  -  $($m.packName) $($m.version)  ($($m.address))")
    }
    if ($lstJoined.Items.Count) { $lstJoined.SelectedIndex = 0 }
}
$btnJoinAgain.Add_Click({
        if ($lstJoined.SelectedIndex -lt 0) { Show-Msg '목록에서 친구 서버를 고르세요.'; return }
        $m = $script:joined[$lstJoined.SelectedIndex][1]
        # The same added-mods value as last time, untouched, so an unchanged game is recognised and left alone
        $c = [pscustomobject]@{ p = $m.pack; k = $m.versionKey; n = $m.name }
        Start-JoinGame $c $m.address ([int]$m.ramGB) ([string]$m.addedMods)
    })
$btnJoinDel.Add_Click({
        if ($lstJoined.SelectedIndex -lt 0) { return }
        $g = $script:joined[$lstJoined.SelectedIndex]
        if (-not (Ask-YesNo "'$($g[1].name)' 게임 폴더를 지울까요?`n(모드팩 파일과 이 서버용 설정, 스크린샷이 지워져요. 서버의 월드는 방장 PC에 있어서 괜찮아요)")) { return }
        if (Test-GameRunning $g[0]) { Show-Msg '이 서버용 마인크래프트가 켜져 있어요. 게임을 끈 다음 다시 해 주세요.'; return }
        if (-not (Close-McLauncher)) { return }
        try {
            $pf = Join-Path (Get-McDirPath) 'launcher_profiles.json'
            $j = Get-Content -LiteralPath $pf -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.profiles.PSObject.Properties[$g[1].profile]) { $j.profiles.PSObject.Properties.Remove($g[1].profile); [IO.File]::WriteAllText($pf, ($j | ConvertTo-Json -Depth 20), $Utf8) }
        }
        catch { }
        & robocopy.exe (New-Item -ItemType Directory -Force (Join-Path $env:TEMP 'mcsm-empty')).FullName $g[0] /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
        Remove-Item -LiteralPath $g[0] -Recurse -Force -ErrorAction SilentlyContinue
        Update-JoinedList
    })
Update-JoinedList

# =====================================================================================
# Tab: manual (local file, works offline and without any login)
# =====================================================================================
$web = New-Object Windows.Forms.WebBrowser
$web.Location = New-Object Drawing.Point(5, 5); $web.Size = New-Object Drawing.Size(955, 610)
$web.ScriptErrorsSuppressed = $true; $web.IsWebBrowserContextMenuEnabled = $false
$manual = Join-Path $Prog 'manual.html'
if (Test-Path -LiteralPath $manual) { $web.Url = New-Object Uri($manual) }
$web.Add_Navigating({ param($s, $e) if ($e.Url.Scheme -like 'http*') { $e.Cancel = $true; Open-Url $e.Url.AbsoluteUri } })
$tabHelp.Controls.Add($web)

# =====================================================================================
# Timers and closing
# =====================================================================================
$uiTimer = New-Object Windows.Forms.Timer; $uiTimer.Interval = 250
$script:tick = 0
$uiTimer.Add_Tick({
        Read-ServerOutput
        if ($script:autoBk -and -not $script:autoBk.proc.Running) { Complete-AutoBackup }
        $script:tick++
        if ($script:tick % 12 -eq 0) { Update-PlayitLabel }
    })

$form.Add_FormClosing({
        param($s, $e)
        $shutdown = $e.CloseReason -eq 'WindowsShutDown'
        if ($script:installProc) {
            if (-not $shutdown -and -not (Ask-YesNo "서버 만들기나 업데이트가 아직 진행 중이에요.`n지금 닫으면 중단돼요. (다음에 프로그램을 켜면 정리하고, 다시 하면 돼요)`n`n그래도 닫을까요?")) { $e.Cancel = $true; return }
            Stop-InstallJob
        }
        if ($script:srv) {
            # Windows is shutting down: save without asking, there is no time for questions
            if (-not $shutdown -and -not (Ask-YesNo "서버가 아직 켜져 있어요.`n서버를 안전하게 끄고 프로그램을 닫을까요?")) { $e.Cancel = $true; return }
            Stop-Server -NoAsk
            $limit = 180; if ($shutdown) { $limit = 60 }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($script:srv -and $sw.Elapsed.TotalSeconds -lt $limit) { Pump 250; Read-ServerOutput }
            if ($script:srv) { $script:srv.proc.Kill() }
        }
        if ($script:autoBk) {
            # Let the automatic backup finish; a shutdown has no time for it, and a half-made zip is thrown away
            $limit = 600; if ($shutdown) { $limit = 0 }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($script:autoBk -and $script:autoBk.proc.Running -and $sw.Elapsed.TotalSeconds -lt $limit) { Pump 250 }
            if ($script:autoBk -and $script:autoBk.proc.Running) { $script:autoBk.proc.Kill(); Pump 500 }
            Complete-AutoBackup
        }
        if ($script:playit) { $script:playit.Kill() }
    })

$form.Add_Shown({
        # Clean up after a crash or power cut before the user does anything
        Repair-Leftovers
        if (@(Get-OrphanServers).Count) { [void](Stop-Orphans -Ask) }
        if (-not @(Get-OrphanServers).Count) { Stop-OrphanPlayit }
        Update-Servers
        $notice = Join-Path $Prog 'updated-notice.txt'
        if (Test-Path -LiteralPath $notice) {
            Show-Msg ("프로그램을 새 버전으로 업데이트했어요.`n`n" + [IO.File]::ReadAllText($notice))
            Remove-Item -LiteralPath $notice -ErrorAction SilentlyContinue
        }
        if ($script:retiredBat) {
            Show-Msg "이제부터는 폴더의 '모드팩서버관리.exe'로 프로그램을 켜 주세요.`n검은 창 없이 바로 열려요. (예전 모드팩서버관리.bat 은 정리했어요)"
        }
    })

Update-Servers
Update-PlayitLabel
if (-not (Get-PlayitAddress)) { $btnCopyAddr.Text = '친구에게 줄 주소 넣기' }
if ($lstSrv.Items.Count) { $tabs.SelectedTab = $tabMy } else { $tabs.SelectedTab = $tabNew }
$uiTimer.Start()
[void]$form.ShowDialog()
