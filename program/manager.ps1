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

# Mod files infected by the 2023 "fractureiser" malware carry its download address built byte by byte.
# This is that exact bytecode (the SIG3 pattern of the community scanner nekodetector), searched in every
# class of a jar and of the jars inside it. Normal mods never contain it.
Add-Type -ReferencedAssemblies System.IO.Compression -TypeDefinition @'
using System;
using System.IO;
using System.IO.Compression;
public static class McsmScan {
    static readonly byte[] Sig = {
        0x10,0x38,0x54,0x59,0x04,0x10,0x35,0x54,0x59,0x05,0x10,0x2E,0x54,0x59,0x06,0x10,0x32,0x54,0x59,0x07,0x10,0x31,0x54,0x59,0x08,
        0x10,0x37,0x54,0x59,0x10,0x06,0x10,0x2E,0x54,0x59,0x10,0x07,0x10,0x31,0x54,0x59,0x10,0x08,0x10,0x34,0x54,0x59,0x10,0x09,
        0x10,0x34,0x54,0x59,0x10,0x0A,0x10,0x2E,0x54,0x59,0x10,0x0B,0x10,0x31,0x54,0x59,0x10,0x0C,0x10,0x33,0x54,0x59,0x10,0x0D,0x10,0x30 };
    static bool Has(byte[] b, int n) {
        for (int i = 0; i + Sig.Length <= n; i++) {
            if (b[i] != 0x10 || b[i + 1] != 0x38) continue;
            int j = 2; while (j < Sig.Length && b[i + j] == Sig[j]) j++;
            if (j == Sig.Length) return true;
        }
        return false;
    }
    static byte[] Read(Stream s, long max, out int n) {
        var ms = new MemoryStream(); var buf = new byte[65536]; int r;
        while ((r = s.Read(buf, 0, buf.Length)) > 0) { ms.Write(buf, 0, r); if (ms.Length > max) break; }
        n = (int)ms.Length; return ms.GetBuffer();
    }
    static bool Zip(Stream s, int depth) {
        using (var z = new ZipArchive(s, ZipArchiveMode.Read)) {
            foreach (var e in z.Entries) {
                string name = e.FullName.ToLowerInvariant();
                if (name.EndsWith(".class")) {
                    int n; using (var es = e.Open()) { var b = Read(es, 8L << 20, out n); if (Has(b, n)) return true; }
                }
                else if (name.EndsWith(".jar") && depth < 3) {
                    int n; byte[] b; using (var es = e.Open()) { b = Read(es, 256L << 20, out n); }
                    try { if (Zip(new MemoryStream(b, 0, n), depth + 1)) return true; } catch (InvalidDataException) { }
                }
            }
        }
        return false;
    }
    // 1 = infected, 0 = clean, -1 = not a readable jar
    public static int ScanJar(string path) {
        try { using (var f = File.OpenRead(path)) { return Zip(f, 0) ? 1 : 0; } }
        catch (InvalidDataException) { return -1; }
        catch (IOException) { return -1; }
        catch (UnauthorizedAccessException) { return -1; }
    }
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

# packs.json comes with the program (and its updates); custom-packs.json holds the ones the user added and is never replaced
$CustomPacksFile = Join-Path $Prog 'custom-packs.json'
function Read-AllPacks {
    $all = @((Get-Content (Join-Path $Prog 'packs.json') -Raw -Encoding UTF8 | ConvertFrom-Json).packs | ForEach-Object { $_ })
    if (Test-Path -LiteralPath $CustomPacksFile) {
        try {
            $ids = @($all | ForEach-Object { $_.id })
            $all += @((Get-Content -LiteralPath $CustomPacksFile -Raw -Encoding UTF8 | ConvertFrom-Json).packs | ForEach-Object { $_ } | Where-Object { $_.id -and $_.id -notin $ids })
        }
        catch { }
    }
    return , $all
}
$packs = Read-AllPacks
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
# A JSON list (whitelist.json, ops.json...) as separate items. Read-Json hands a list on as one object in Windows PowerShell 5.1,
# so @(Read-Json x | ...) would see three names as one (and an empty list as one item)
function Read-JsonList($path) { $j = Read-Json $path; return @($j | Where-Object { $null -ne $_ }) }
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
$lstPacks = New-Ctl ListBox 10 35 290 492
$btnAddPack = New-Ctl Button 10 532 150 40 '+ 모드팩 추가'; $btnAddPack.Font = $bold
$btnDelPack = New-Ctl Button 165 532 135 40 '목록에서 빼기'; $btnDelPack.Enabled = $false
function Update-PackList([string]$selectId = '') {
    $script:packs = Read-AllPacks
    $script:packListBusy = $true
    $lstPacks.Items.Clear()
    foreach ($p in $script:packs) { $n = $p.name; if ($p.custom) { $n = "★ $n" }; [void]$lstPacks.Items.Add($n) }
    $script:packListBusy = $false; $btnDelPack.Enabled = $false
    if ($selectId) { $k = [array]::IndexOf(@($script:packs | ForEach-Object { $_.id }), $selectId); if ($k -ge 0) { $lstPacks.SelectedIndex = $k } }
}
foreach ($p in $packs) { $n = $p.name; if ($p.custom) { $n = "★ $n" }; [void]$lstPacks.Items.Add($n) }

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

$tabNew.Controls.AddRange(@($lblPick, $lstPacks, $btnAddPack, $btnDelPack, $lblName, $lblDesc, $lblInfo, $lnkPage, $lblVer, $cmbVer, $lblSrv, $txtName,
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

# ---------------- modpacks the user adds (Modrinth by address, CurseForge by project ID) ----------------
function Get-CfJson([string]$url) {
    # curl's raw bytes, read back as UTF-8 (PowerShell 5.1 would decode native output with the console code page)
    $tmp = Join-Path $env:TEMP "mcsm-cf-$([guid]::NewGuid().ToString('N')).json"
    try {
        & curl.exe -s -L --max-time 30 -o $tmp $url
        if (-not (Test-Path -LiteralPath $tmp)) { throw 'CurseForge에 연결하지 못했어요. 인터넷을 확인해 주세요.' }
        $raw = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
        try { return $raw | ConvertFrom-Json } catch { throw 'CurseForge가 응답하지 않아요. 잠시 뒤에 다시 해 주세요.' }
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
function ConvertTo-PackRecord($p) {
    # Fresh objects only: Windows PowerShell 5.1 mangles arrays that came out of ConvertFrom-Json when they are written back
    $o = [ordered]@{}
    foreach ($k in 'id', 'name', 'source', 'slug', 'page', 'desc', 'mc', 'loader', 'ramGB', 'clientHow', 'cfId', 'refreshed') { if ($null -ne $p.$k -and "$($p.$k)" -ne '') { $o[$k] = $p.$k } }
    $o['custom'] = $true
    if ($p.source -eq 'curseforge') { $o['versions'] = @(foreach ($v in @($p.versions)) { [ordered]@{ label = [string]$v.label; date = [string]$v.date; url = [string]$v.url; size = [long]$v.size } }) }
    return $o
}
function Save-CustomPacks($list) {
    $recs = @(foreach ($p in @($list)) { ConvertTo-PackRecord $p })
    [IO.File]::WriteAllText($CustomPacksFile, ([ordered]@{ packs = $recs } | ConvertTo-Json -Depth 6), $Utf8)
}
function Get-CustomPacks { return @($packs | Where-Object { $_.custom }) }
function Add-CustomPack($p, [switch]$NoSelect) {
    # A CurseForge pack already in the list keeps its versions and gains the new ones
    $list = @(Get-CustomPacks | Where-Object { $_.id -ne $p.id })
    $old = Get-CustomPacks | Where-Object { $_.id -eq $p.id } | Select-Object -First 1
    if ($old -and $p.source -eq 'curseforge') {
        $have = @($p.versions | ForEach-Object { $_.label })
        $p.versions = @(@($p.versions) + @($old.versions | Where-Object { $_.label -notin $have }))
    }
    Save-CustomPacks (@($list) + $p)
    if ($NoSelect) { Update-PackList } else { Update-PackList $p.id }
}
function Test-ServerPackUrl([string]$u) { return $u -match '^https://(mediafilez|edge)\.forgecdn\.net/files/\d+/\d+/[^/?#]+$' }

function New-CfPack([int]$projId, [int]$maxVersions = 8) {
    $list = Get-CfJson "https://www.curseforge.com/api/v1/mods/$projId/files?pageIndex=0&pageSize=50&sort=dateCreated&sortDescending=true&removeAlphas=false"
    if (-not $list.data) { throw "CurseForge에서 $projId 번 모드팩을 찾지 못했어요. 숫자를 다시 확인해 주세요.`n(다운로드 주소 끝의 숫자는 파일 번호라서 안 돼요. 모드팩 페이지 주소를 그대로 붙여 넣어도 돼요)" }
    $mains = @($list.data | Where-Object { $_.hasServerPack -or $_.additionalServerPackFilesCount -gt 0 } | Select-Object -First $maxVersions)
    if (-not $mains.Count) { throw '이 모드팩은 CurseForge에 서버팩을 올려 두지 않았어요. 서버팩이 있는 모드팩만 넣을 수 있어요.' }
    # The pack's name is what every file's display name starts with ("All the Mods 9-1.1.1" -> "All the Mods 9")
    $names = @($mains | ForEach-Object { [string]$_.displayName })
    # Only a trailing version is cut: '-1.1.1', ' v39' (the 9 in 'All the Mods 9' is part of the name)
    $cut = @($names | ForEach-Object { ($_ -replace '[\s_-]+(v\d+[\w.+-]*|v?\d+(\.\d+)+[\w.+-]*)$', '').Trim(' ', '-', '_') })
    $name = ($cut | Group-Object | Sort-Object Count -Descending | Select-Object -First 1).Name
    if (-not $name) { $name = "CurseForge $projId" }
    $vers = @(foreach ($m in $mains) {
            $add = Get-CfJson "https://www.curseforge.com/api/v1/mods/$projId/files/$($m.id)/additional-files"
            $sf = @($add.data | Where-Object { $_.fileName -match '(?i)server' -and $_.fileName -match '\.zip$' }) + @($add.data | Where-Object { $_.fileName -match '\.zip$' }) | Select-Object -First 1
            if (-not $sf) { continue }
            $label = ([string]$m.displayName); if ($label.StartsWith($name)) { $label = $label.Substring($name.Length).Trim(' ', '-', '_') }; if (-not $label) { $label = [string]$m.displayName }
            [pscustomobject]@{ label = $label; date = ([string]$m.dateCreated).Substring(0, 10); url = "https://mediafilez.forgecdn.net/files/$([int][math]::Floor($sf.id / 1000))/$($sf.id % 1000)/$([uri]::EscapeDataString($sf.fileName))"; size = [long]$sf.fileLength
                mc = @($m.gameVersions | Where-Object { $_ -match '^\d+\.\d+' })[0]; loader = (@($m.gameVersions | Where-Object { $_ -match '^(Forge|NeoForge|Fabric)$' })[0]) }
        })
    if (-not $vers.Count) { throw '서버팩 파일을 찾지 못했어요.' }
    $top = $vers[0]
    if (-not $top.loader) { throw '이 모드팩의 로더는 지원하지 않아요 (Forge/NeoForge/Fabric만 가능).' }
    # One Minecraft version per list entry, as with the built-in packs
    $vers = @($vers | Where-Object { $_.mc -eq $top.mc })
    return [pscustomobject]@{
        id = "cf-$projId"; name = $name; source = 'curseforge'; cfId = $projId; page = "https://www.curseforge.com/projects/$projId"
        desc = "직접 추가한 CurseForge 모드팩이에요. (서버팩이 있는 버전 $($vers.Count)개)"; mc = $top.mc; loader = ([string]$top.loader).ToLower(); ramGB = 6
        clientHow = "CurseForge 앱에서 '$name' 검색 후 같은 버전 설치"; custom = $true; refreshed = (Get-Date -Format 'yyyy-MM-dd')
        versions = @($vers | ForEach-Object { [pscustomobject]@{ label = $_.label; date = $_.date; url = $_.url; size = $_.size } })
    }
}
function New-MrPack([string]$text) {
    $slug = $text
    if ($text -match 'modrinth\.com/(mod|plugin|resourcepack|shader|datapack)/') { throw '이건 모드팩이 아니라 모드(또는 리소스팩)예요. 모드는 [내 서버] → [모드 추가 / 관리]에서 넣어요.' }
    if ($text -match 'modrinth\.com/(modpack|project)/([A-Za-z0-9_-]+)') { $slug = $Matches[2] }
    elseif ($text -notmatch '^[A-Za-z0-9_-]{2,64}$') { throw '주소를 알아보지 못했어요. Modrinth 모드팩 페이지의 주소를 그대로 붙여 넣어 주세요.' }
    try { $pr = Invoke-RestMethod "https://api.modrinth.com/v2/project/$slug" -TimeoutSec 20 } catch { throw "Modrinth에서 '$slug' 모드팩을 찾지 못했어요." }
    if ($pr.project_type -ne 'modpack') { throw "'$($pr.title)'은(는) 모드팩이 아니라 모드예요. 모드는 [내 서버] → [모드 추가 / 관리]에서 넣어요." }
    if (-not (@($pr.loaders) | Where-Object { $_ -in 'forge', 'neoforge', 'fabric' })) { throw '이 모드팩의 로더는 지원하지 않아요 (Forge/NeoForge/Fabric만 가능).' }
    $desc = [string]$pr.description; if ($desc.Length -gt 140) { $desc = $desc.Substring(0, 140) + '...' }
    return [pscustomobject]@{
        id = "mr-$($pr.slug)"; name = [string]$pr.title; source = 'modrinth'; slug = [string]$pr.slug; page = "https://modrinth.com/modpack/$($pr.slug)"
        desc = "$desc (직접 추가한 모드팩)"; ramGB = 6; clientHow = "Modrinth 앱에서 '$($pr.title)' 검색 후 같은 버전 설치"; custom = $true
    }
}
function Get-CfProjectId([string]$text) {
    # A page address names the pack by slug; the number in ".../download/8980840" is a file, not the pack
    if ($text -match 'curseforge\.com/projects/(\d{3,9})\b') { return [int]$Matches[1] }
    if ($text -match 'curseforge\.com/minecraft/(mc-mods|texture-packs|shaders|data-packs|worlds|customization|bukkit-plugins)/') { throw '이건 모드팩이 아니라 모드(또는 리소스팩)예요. 모드는 [내 서버] → [모드 추가 / 관리]에서 넣어요.' }
    if ($text -notmatch 'curseforge\.com/minecraft/modpacks/([A-Za-z0-9_-]+)') { throw "주소를 알아보지 못했어요. CurseForge 모드팩 페이지의 주소를 그대로 붙여 넣거나,`n모드팩 페이지 오른쪽 'About Project' 칸의 Project ID 숫자를 넣어 주세요." }
    $slug = $Matches[1]
    # curseforge.com answers page and search requests only to browsers; CFWidget maps the slug to the project number
    $j = $null; try { $j = Get-CfJson "https://api.cfwidget.com/minecraft/modpacks/$slug" } catch { }
    if (-not $j -or -not $j.id) { throw "주소로 모드팩 번호를 찾지 못했어요.`n모드팩 페이지 오른쪽 'About Project' 칸의 Project ID 숫자를 넣어 주세요." }
    return [int]$j.id
}
function Show-AddPack {
    $text = ("" + (Ask-Text "넣을 모드팩을 알려 주세요.`n`n· Modrinth: 모드팩 페이지 주소를 붙여 넣기`n   (예: https://modrinth.com/modpack/better-mc-forge-bmc4)`n`n· CurseForge: 모드팩 페이지 주소를 붙여 넣기, 또는 'About Project' 칸의 Project ID 숫자`n   (예: https://www.curseforge.com/minecraft/modpacks/all-the-mods-9 또는 715572)")).Trim()
    if (-not $text) { return }
    $form.Cursor = 'WaitCursor'; $lblWork.ForeColor = [Drawing.Color]::DarkGreen; $lblWork.Text = '모드팩 정보를 확인하는 중...'; $form.Refresh()
    try {
        if ($text -match '^\d{3,9}$') { $p = New-CfPack ([int]$text) }
        elseif ($text -match 'curseforge\.com') { $p = New-CfPack (Get-CfProjectId $text) }
        else { $p = New-MrPack $text }
        # Already built in? Same Modrinth project, same CurseForge project, or a name that starts the same way
        $norm = { param($s) ([string]$s).ToLower() -replace '[^a-z0-9]', '' }
        $nn = & $norm $p.name
        $dup = $packs | Where-Object { -not $_.custom -and (($p.slug -and $_.slug -eq $p.slug) -or ($p.cfId -and "$($_.cfId)" -eq "$($p.cfId)") -or ($nn.Length -ge 6 -and (& $norm $_.name).StartsWith($nn))) } | Select-Object -First 1
        if ($dup) { $form.Cursor = 'Default'; $lblWork.Text = ''; Show-Msg "'$($dup.name)'은(는) 이미 목록에 있어요. 그걸 고르면 돼요."; Update-PackList $dup.id; return }
        if (@($packs | Where-Object { $_.id -eq $p.id -and -not $_.custom }).Count) { $form.Cursor = 'Default'; $lblWork.Text = ''; Show-Msg "'$($p.name)'은(는) 이미 목록에 있어요."; Update-PackList $p.id; return }
        Add-CustomPack $p
        $lblWork.Text = ''
        Show-Msg "'$($p.name)' 모드팩을 목록에 넣었어요. (★ 표시)`n이제 버전을 고르고 [서버 만들기]를 누르면 돼요."
    }
    catch { $lblWork.Text = ''; Show-Msg "모드팩을 넣지 못했어요.`n$($_.Exception.Message)" 'Warning' }
    finally { $form.Cursor = 'Default' }
}
$btnAddPack.Add_Click({ Show-AddPack })
$btnDelPack.Add_Click({
        if ($lstPacks.SelectedIndex -lt 0) { return }
        $p = $packs[$lstPacks.SelectedIndex]; if (-not $p.custom) { return }
        if (-not (Ask-YesNo "'$($p.name)'을(를) 목록에서 뺄까요?`n(이 모드팩으로 만든 서버는 그대로 있지만, 모드팩 업데이트 확인과 [마인크래프트 켜기]는 다시 넣어야 돼요)")) { return }
        Save-CustomPacks @(Get-CustomPacks | Where-Object { $_.id -ne $p.id })
        Update-PackList
    })

$lstPacks.Add_SelectedIndexChanged({
        if ($lstPacks.SelectedIndex -lt 0 -or $script:packListBusy) { return }
        $p = $packs[$lstPacks.SelectedIndex]
        $btnDelPack.Enabled = [bool]$p.custom
        if ($p.custom -and $p.source -eq 'curseforge' -and $p.cfId -and "$($p.refreshed)" -ne (Get-Date -Format 'yyyy-MM-dd')) {
            # Once a day, new CurseForge versions of an added pack are picked up when it is selected
            $lblWork.Text = '새 버전이 있는지 확인하는 중...'; $form.Refresh()
            # Add-CustomPack re-selects the pack, which runs this handler again with the fresh list
            try { $fresh = New-CfPack ([int]$p.cfId); $lblWork.Text = ''; Add-CustomPack $fresh; return } catch { $lblWork.Text = '' }
        }
        $lblName.Text = $p.name
        $lblDesc.Text = $p.desc
        $src = 'CurseForge'; if ($p.source -eq 'modrinth') { $src = 'Modrinth' }
        $lblInfo.Text = "출처: $src   |   권장 서버 램: $($p.ramGB)GB"
        $numRam.Value = [Math]::Min($numRam.Maximum, [Math]::Max($numRam.Minimum, $p.ramGB))
        $cmbVer.Items.Clear(); $cmbVer.Items.Add('버전 목록 불러오는 중...') | Out-Null; $cmbVer.SelectedIndex = 0
        $form.Refresh()
        # @(): a one-version list would otherwise lose its Count in PowerShell 5.1
        try { $script:versions = @(Get-Versions $p) } catch { $script:versions = @(); Show-Msg "버전 목록을 불러오지 못했어요. 인터넷 연결을 확인하세요.`n$($_.Exception.Message)" 'Warning' }
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
        $btnUpdate.Text = "새 버전 있음: $($t.label)"; if ($t.label.Length -gt 12) { $btnUpdate.Text = '새 버전 있음! (눌러서 보기)' }; $btnUpdate.BackColor = [Drawing.Color]::Gold; $btnUpdate.Tag = $t
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
$lstSrv = New-Ctl ListBox 10 35 235 112
$btnPlay = New-Ctl Button 10 148 235 42 '▶ 마인크래프트 켜기'; $btnPlay.Font = $bold; $btnPlay.BackColor = [Drawing.Color]::FromArgb(214, 240, 214)
$btnSettings = New-Ctl Button 10 194 235 34 '서버 설정 (난이도, 인원 등)'
$btnMods = New-Ctl Button 10 232 235 34 '모드 추가 / 관리'
$btnBackup = New-Ctl Button 10 270 235 34 '백업 / 월드 관리'
$btnInvite = New-Ctl Button 10 308 235 34 '친구 초대 링크 복사'; $btnInvite.BackColor = [Drawing.Color]::FromArgb(222, 234, 250)
$btnFriend = New-Ctl Button 10 346 235 34 '친구 접속 안내'
$btnPlayit = New-Ctl Button 10 384 235 34 'Playit 연결 설정'
$btnSecurity = New-Ctl Button 10 422 235 34 '보안 점검'
$btnUpdate = New-Ctl Button 10 460 235 34 '모드팩 업데이트 확인'
$btnFolder = New-Ctl Button 10 498 235 34 '서버 폴더 열기'
$lblPlayit = New-Ctl Label 10 535 235 58 ''
$btnCopyAddr = New-Ctl Button 10 594 235 30 '친구에게 줄 주소 복사'

$lblState = New-Ctl Label 260 35 695 48 '● 꺼짐'
$lblState.Font = $big; $lblState.ForeColor = [Drawing.Color]::White; $lblState.BackColor = [Drawing.Color]::Gray; $lblState.TextAlign = 'MiddleLeft'
$prg = New-Object Windows.Forms.ProgressBar; $prg.Location = New-Object Drawing.Point(260, 88); $prg.Size = New-Object Drawing.Size(695, 18); $prg.Style = 'Continuous'
$lblStage = New-Ctl Label 260 110 695 40 ''
$lblSrvInfo = New-Ctl Label 260 152 455 60 ''; $lblSrvInfo.AutoEllipsis = $true; $lblSrvInfo.ForeColor = [Drawing.Color]::DimGray
$lblRamSrv = New-Ctl Label 718 158 90 22 '서버 램(GB)'
$numRamSrv = New-Ctl NumericUpDown 808 155 50 28; $numRamSrv.Minimum = 2; $numRamSrv.Maximum = [Math]::Max(2, $totalRam - 2)
$btnRamSrv = New-Ctl Button 862 153 93 30 '램 바꾸기'
$btnStart = New-Ctl Button 260 216 160 42 '▶ 친구랑 하기'; $btnStart.Font = $bold
$btnLocal = New-Ctl Button 426 216 150 42 '▶ 혼자 하기'; $btnLocal.Font = $bold
$btnStop = New-Ctl Button 582 216 150 42 '■ 서버 끄기'; $btnStop.Font = $bold; $btnStop.Enabled = $false
$btnAddFriend = New-Ctl Button 738 216 110 42 '친구 추가'
$lblPlayers = New-Ctl Label 852 216 103 42 '접속 0명'; $lblPlayers.TextAlign = 'MiddleCenter'; $lblPlayers.Font = $bold
$tip = New-Object Windows.Forms.ToolTip
$tip.SetToolTip($btnStart, '서버를 열고 Playit으로 친구들이 들어올 수 있게 해요.')
$tip.SetToolTip($btnLocal, '같은 월드를 내 컴퓨터에서만 열어요. 마인크래프트에서 127.0.0.1 로 접속하세요.')
$tip.SetToolTip($btnAddFriend, '화이트리스트에 닉네임을 추가해요. 나도 처음 한 번 추가해야 해요.')
$txtConsole = New-Ctl TextBox 260 264 695 308
$txtConsole.Multiline = $true; $txtConsole.ReadOnly = $true; $txtConsole.ScrollBars = 'Vertical'; $txtConsole.WordWrap = $false
$txtConsole.Font = $mono; $txtConsole.BackColor = [Drawing.Color]::FromArgb(24, 24, 24); $txtConsole.ForeColor = [Drawing.Color]::Gainsboro
$txtCmd = New-Ctl TextBox 260 580 590 28
$btnSend = New-Ctl Button 856 578 99 32 '명령 보내기'
$tip.SetToolTip($btnPlay, '서버와 똑같은 모드팩 게임을 준비하고 마인크래프트 런처를 열어요. 멀티플레이에 내 서버가 들어 있어요.')
$tip.SetToolTip($btnInvite, '링크 하나만 카톡이나 디스코드에 붙여 넣으면, 친구는 모드팩과 내가 추가한 모드까지 자동으로 받아요.')
$tabMy.Controls.AddRange(@($lblMy, $lstSrv, $btnPlay, $btnSettings, $btnFolder, $btnMods, $btnInvite, $btnFriend, $btnBackup, $btnPlayit, $btnSecurity, $btnUpdate, $lblPlayit, $btnCopyAddr,
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
$script:wlSent = New-Object System.Collections.Queue   # names sent with "whitelist add", answered by the server in order

function Set-State($text, $color) { $lblState.Text = $text; $lblState.BackColor = $color }
function Get-LaunchInfo($d) {
    # 서버켜기.bat is the single source of truth for the java version and arguments
    $bat = Join-Path $d '서버켜기.bat'
    $line = [IO.File]::ReadAllLines($bat, $Cp949) | Where-Object { $_ -match '^"%PROG%\\java\\(\d+)\\bin\\java\.exe"\s+(.+)$' } | Select-Object -First 1
    if (-not $line) { return $null }
    [void]($line -match '^"%PROG%\\java\\(\d+)\\bin\\java\.exe"\s+(.+)$')
    return @{ major = $Matches[1]; args = $Matches[2].Trim() }
}
# ---------------- mod files: malware check before anything runs them ----------------
function Test-ModFiles([string]$dir, [string]$cacheFile) {
    # Infected jar paths in $dir. Files already checked (same name, size and time) are not opened again,
    # so only the first check of a big pack takes a while.
    $cache = @{}
    if (Test-Path -LiteralPath $cacheFile) { try { foreach ($p in (Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties) { $cache[$p.Name] = [int]$p.Value } } catch { } }
    $jars = @(); if (Test-Path -LiteralPath $dir) { $jars = @(Get-ChildItem -LiteralPath $dir -Filter '*.jar' -File -Recurse -ErrorAction SilentlyContinue) }
    $bad = New-Object System.Collections.Generic.List[string]; $seen = @{}; $k = 0; $label = $lblStage.Text
    foreach ($j in $jars) {
        $k++
        $key = "$($j.Name)|$($j.Length)|$($j.LastWriteTimeUtc.Ticks)"
        if ($cache.ContainsKey($key)) { $r = $cache[$key] }
        else {
            $lblStage.Text = "모드 파일에 악성코드가 없는지 확인하는 중... ($k/$($jars.Count))  처음 한 번만 오래 걸려요."
            [Windows.Forms.Application]::DoEvents()
            $r = [McsmScan]::ScanJar($j.FullName)
        }
        $seen[$key] = $r
        if ($r -eq 1) { $bad.Add($j.FullName) }
    }
    $lblStage.Text = $label
    try { [IO.File]::WriteAllText($cacheFile, (ConvertTo-Json -InputObject $seen -Compress), $Utf8) } catch { }
    return $bad.ToArray()   # unrolled on purpose: callers wrap it in @(), and ', ' would make an empty result count as one
}
function Confirm-ModsSafe($d, [string]$dir, [string]$cacheFile) {
    # $true when nothing is infected; otherwise says so, offers to move the files away, and the caller stops
    $bad = @(Test-ModFiles $dir $cacheFile)
    if (-not $bad.Count) { return $true }
    $names = ($bad | ForEach-Object { ' - ' + (Split-Path $_ -Leaf) }) -join "`n"
    Write-SecurityLog @{ dir = $d; secLogged = 0 } "악성코드 감염 모드 발견: $((($bad | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))"
    $q = Join-Path $d '격리된_위험한_모드'
    if (Ask-YesNo ("⚠ 악성코드(fractureiser)에 감염된 모드 파일을 찾았어요. 그래서 켜지 않았어요.`n`n$names`n`n" +
            "이 파일을 '격리된_위험한_모드' 폴더로 옮길까요? (권장, 다시는 실행되지 않게 이름 끝에 .위험 을 붙여요)`n`n" +
            "옮긴 다음에는 Windows 보안 → 바이러스 및 위협 방지 → [전체 검사]를 꼭 해 주세요.`n이 모드는 공식 사이트(Modrinth, CurseForge)에서 다시 받아야 해요.")) {
        New-Item -ItemType Directory -Force $q | Out-Null
        foreach ($b in $bad) { Move-Item -LiteralPath $b -Destination (Join-Path $q ((Split-Path $b -Leaf) + '.위험')) -Force -ErrorAction SilentlyContinue }
        Show-Msg "격리 폴더로 옮겼어요: $q`n빠진 모드 때문에 안 켜지면 그 모드를 공식 사이트에서 다시 받아 넣어 주세요."
    }
    return $false
}
function Test-PcInfected {
    # fractureiser's own files on Windows live in "%LOCALAPPDATA%\Microsoft Edge" (with a space; the real Edge folders are
    # "MicrosoftEdge" and "Microsoft\Edge"). Source: fractureiser-investigation docs/users.md
    return Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft Edge')
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
    if (-not (Confirm-ModsSafe $d (Join-Path $d 'mods') (Join-Path $d 'mod-scan.json'))) { return }
    Set-InviteMotd $d
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
        if ($why -and -not (Ask-YesNo "$why 친구들은 들어올 수 없어요.`n([Playit 연결 설정]에서 넣을 수 있어요. 나는 127.0.0.1 로 들어갈 수 있어요)`n`n그래도 켤까요?")) { return }
        Start-Playit
    }
    $i = Read-Json (Join-Path $d 'server-info.json')
    $mods = @(Get-ChildItem -LiteralPath (Join-Path $d 'mods') -Filter '*.jar' -ErrorAction SilentlyContinue).Count
    $expect = 40 + [int]($mods * 0.35); if ($i -and $i.bootSeconds) { $expect = [int]$i.bootSeconds }
    $txtConsole.Clear()
    $txtConsole.AppendText("[관리 프로그램] '$($lstSrv.SelectedItem)' 서버를 켜는 중이에요. 끌 때는 [■ 서버 끄기]를 눌러 주세요.`r`n")
    $script:wlSent.Clear()
    $proc = New-Object McProc($java, $li.args, $d, [Text.Encoding]::Default.CodePage)
    $script:srv = [pscustomobject]@{
        dir = $d; name = $lstSrv.SelectedItem; proc = $proc; sw = [Diagnostics.Stopwatch]::StartNew(); expect = $expect
        done = $false; stopping = $false; stage = 0; spawn = 0; players = @{}; tail = New-Object System.Collections.Generic.List[string]; stopSw = $null
        local = [bool]$Local; noPlayit = [bool]$why; warned = @{}; askNick = $null; wlBad = $null
        bkSw = $null; playedSinceBk = $false; lag = New-Object System.Collections.Generic.List[datetime]; lagHint = [datetime]::MinValue
        wlNames = @{}; bounces = New-Object System.Collections.Generic.List[datetime]; strangers = @{}; declined = @{}; attack = $null; attackSaid = [datetime]::MinValue; quiet = $false; secLogged = 0
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
    # A backup still zipping would catch the world halfway through the final save; the stop leaves a fresh one anyway
    Stop-LiveBackup '서버를 끄는 중이라 켜진 채로 하던 백업은 멈췄어요. (끈 다음에 자동으로 다시 백업해요)'
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
    Stop-LiveBackup '서버가 꺼져서 켜진 채로 하던 백업은 멈췄어요.'
    $lstSrv.Enabled = $true; $btnStart.Enabled = $true; $btnLocal.Enabled = $true; $btnStop.Enabled = $false; $btnMods.Enabled = $true; $btnRamSrv.Enabled = $true
    # No server, no reason to keep a public address open
    $script:playitPausedUntil = $null
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
        Set-State '● 서버 열림!  (혼자 하기: 주소 127.0.0.1)' ([Drawing.Color]::ForestGreen)
        $lblStage.Text = "게임은 왼쪽 [▶ 마인크래프트 켜기]로 켜세요. 멀티플레이에 내 서버가 들어 있어요. 끌 때는 [서버 끄기]."
    }
    elseif ($s.noPlayit) {
        # Started anyway after the "no Playit" warning: say plainly that friends still can't join
        Set-State '● 서버 열림!  (Playit이 없어서 지금은 나만: 주소 127.0.0.1)' ([Drawing.Color]::DarkOrange)
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

function Get-Bounce([string]$line) {
    # Reason and (if the log has it) the name from a "lost connection" / "Disconnecting" line
    $why = ''
    if ($line -match 'lost connection: (.+)$') { $why = $Matches[1] }
    elseif ($line -match 'Disconnecting .*?\): (.+)$') { $why = $Matches[1] }
    if (-not $why) { return $null }
    $name = ''
    if ($line -match 'name=([A-Za-z0-9_]{3,16})[,\]]') { $name = $Matches[1] }
    elseif ($line -match 'Disconnecting ([A-Za-z0-9_]{3,16}) \(') { $name = $Matches[1] }
    elseif ($line -match ':\s([A-Za-z0-9_]{3,16})\s(\(/[^)]*\)\s)?lost connection') { $name = $Matches[1] }
    return @{ why = $why; name = $name }
}

# ---------------- strangers at the door: the address reached people it shouldn't have ----------------
# Everyone arrives through Playit, so the server sees 127.0.0.1 for all of them and IP bans can't tell anyone apart.
# What it can see: names that aren't on the whitelist, and how fast refused connections come in.
$AttackStrangers = 6      # different unknown names within 10 minutes
$AttackBounces = 20       # refused connections within 1 minute
$FloodBounces = 60        # refused connections within 1 minute: cut the Playit connection for a while
$FloodPauseMinutes = 10
$script:playitPausedUntil = $null

# ---------------- operators: the host, and nobody else unless they really mean it ----------------
# Spawn protection only works while the server has an operator, so the host is made one at every start.
function Get-HostNick($d) {
    $i = Read-Json (Join-Path $d 'server-info.json')
    if ($i -and $i.PSObject.Properties['host'] -and "$($i.host)" -match '^[A-Za-z0-9_]{3,16}$') { return "$($i.host)" }
    return ''
}
function Set-HostOp($s, $pendNames) {
    $h = Get-HostNick $s.dir
    if (-not $h) {
        # Servers made before this: the name this PC's game logs show, if that player is let in here
        $k = Get-KnownNick
        if ($k -and ((Read-WhitelistNames $s.dir).ContainsKey($k.ToLower()) -or @($pendNames | Where-Object { $_ -ieq $k }).Count)) { Set-InfoField $s.dir 'host' $k; $h = $k }
    }
    if (-not $h) { return }
    $ops = @(Read-JsonList (Join-Path $s.dir 'ops.json'))
    if (@($ops | Where-Object { "$($_.name)" -ieq $h }).Count) { return }
    $s.proc.Send("op $h")
    $txtConsole.AppendText("[관리 프로그램] 방장 '$h' 님을 관리자(OP)로 정했어요. 관리자가 있어야 스폰 보호가 작동해요.`r`n")
}

# ---------------- when each whitelisted player last came, so unused entries can be removed ----------------
function Read-Seen($d) {
    $h = @{}; $j = Read-Json (Join-Path $d 'players-seen.json')
    if ($j) { foreach ($p in $j.PSObject.Properties) { $h[$p.Name] = "$($p.Value)" } }
    return $h
}
function Write-Seen($d, $h) { try { [IO.File]::WriteAllText((Join-Path $d 'players-seen.json'), (ConvertTo-Json -InputObject $h -Compress), $Utf8) } catch { } }
function Set-PlayerSeen($d, [string]$name) { $h = Read-Seen $d; $h[$name.ToLower()] = (Get-Date -Format 'yyyy-MM-dd'); Write-Seen $d $h }
function Start-SeenClock($d) {
    # Whitelisted names with no record yet start counting today (nobody is called inactive on day one)
    $h = Read-Seen $d; $n = 0
    foreach ($k in @((Read-WhitelistNames $d).Keys)) { if (-not $h.ContainsKey($k)) { $h[$k] = (Get-Date -Format 'yyyy-MM-dd'); $n++ } }
    if ($n) { Write-Seen $d $h }
}
$StaleDays = 30
function Get-StaleFriends($d) {
    $h = Read-Seen $d; $host0 = (Get-HostNick $d).ToLower(); $cut = (Get-Date).AddDays(-$StaleDays).ToString('yyyy-MM-dd')
    $out = foreach ($w in @(Read-JsonList (Join-Path $d 'whitelist.json'))) {
        $k = "$($w.name)".ToLower()
        if ($k -and $k -ne $host0 -and $h.ContainsKey($k) -and $h[$k] -lt $cut) { "$($w.name)" }
    }
    return @($out)
}

function Read-WhitelistNames($d) {
    $h = @{}
    foreach ($w in @(Read-JsonList (Join-Path $d 'whitelist.json'))) { if ($w.name) { $h[([string]$w.name).ToLower()] = $true } }
    return $h
}
function Write-SecurityLog($s, [string]$text) {
    # Kept beside the server so the security check can show how often strangers knock; a flood is capped, not written line by line
    if ($s.secLogged -ge 300) { return }
    $s.secLogged++
    try { Add-Content -LiteralPath (Join-Path $s.dir 'security-log.txt') -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $text" -Encoding UTF8 } catch { }
}
function Add-Bounce($s, $b) {
    # Friends on the whitelist bounce for ordinary reasons (wrong mods, timeouts) and don't count,
    # unless the login check failed: that is someone using a friend's name without the friend's account
    $now = Get-Date; $name = $b.name
    if ($name -and $s.wlNames.ContainsKey($name.ToLower()) -and $b.why -notmatch '(?i)verify username|invalid session|authenticat') { return }
    $s.bounces.Add($now)
    while ($s.bounces.Count -and ($now - $s.bounces[0]).TotalSeconds -gt 60) { $s.bounces.RemoveAt(0) }
    if ($name) {
        if (-not $s.strangers.ContainsKey($name)) { Write-SecurityLog $s "모르는 사람 접속 시도: $name ($($b.why))" }
        $s.strangers[$name] = $now
    }
    else { Write-SecurityLog $s "이름 없는 접속 시도 ($($b.why))" }
    foreach ($k in @($s.strangers.Keys)) { if (($now - $s.strangers[$k]).TotalMinutes -gt 10) { $s.strangers.Remove($k) } }
    if ($s.bounces.Count -ge $FloodBounces -and -not $s.local) { Suspend-Playit $s; return }
    if (-not $s.attack -and ($now - $s.attackSaid).TotalMinutes -ge 30 -and ($s.strangers.Count -ge $AttackStrangers -or $s.bounces.Count -ge $AttackBounces)) {
        $s.attack = "최근 10분 동안 모르는 이름 $($s.strangers.Count)개, 최근 1분 동안 막힌 접속 $($s.bounces.Count)번"
        $s.quiet = $true
        Write-SecurityLog $s "공격 의심: $($s.attack)"
    }
}
function Suspend-Playit($s) {
    # A flood this size is no friend: take the public address offline for a while. The server and the world keep running.
    if ($script:playitPausedUntil) { return }
    $script:playitPausedUntil = (Get-Date).AddMinutes($FloodPauseMinutes)
    if ($script:playit) { $script:playit.Kill(); $script:playit = $null }
    $s.attack = "1분 동안 막힌 접속이 $($s.bounces.Count)번이라 Playit 연결을 $($FloodPauseMinutes)분 동안 끊었어요"
    $s.quiet = $true; $s.attackSaid = [datetime]::MinValue
    $s.bounces.Clear()
    Write-SecurityLog $s "접속 폭주: Playit 연결을 $($FloodPauseMinutes)분 동안 끊었어요"
    $txtConsole.AppendText("[관리 프로그램] ※ 짧은 시간에 이상한 접속이 너무 많이 들어와서 Playit 연결을 $($FloodPauseMinutes)분 동안 끊었어요. 서버와 월드는 그대로 켜져 있어요.`r`n")
    Update-PlayitLabel
}
function Resume-Playit {
    $u = $script:playitPausedUntil; if (-not $u -or (Get-Date) -lt $u) { return }
    $script:playitPausedUntil = $null
    $s = $script:srv
    if ($s -and $s.done -and -not $s.stopping -and -not $s.local) {
        Start-Playit
        $txtConsole.AppendText("[관리 프로그램] Playit 연결을 다시 켰어요. 또 몰려오면 다시 끊어요. 제일 확실한 방법은 주소를 바꾸는 거예요: [보안 점검] → [주소 바꾸기 도우미]`r`n")
    }
    Update-PlayitLabel
}

# ---------------- lag: say so before friends start complaining ----------------
function Add-Lag($s) {
    $now = Get-Date; $s.lag.Add($now)
    while ($s.lag.Count -and ($now - $s.lag[0]).TotalMinutes -gt 5) { $s.lag.RemoveAt(0) }
    if ($s.lag.Count -lt 4 -or ($now - $s.lagHint).TotalMinutes -lt 30) { return $null }
    $s.lagHint = $now
    $pr = Get-Props $s.dir
    $vd = $pr['view-distance']; if (-not $vd) { $vd = '10' }
    $msg = "서버가 버거워하고 있어요 (최근 5분 동안 $($s.lag.Count)번 밀림, 접속 $($s.players.Count)명). 서버를 끈 다음 [서버 설정]에서 시야 거리($vd)를 6~8로 낮추거나 [서버 램]을 늘려 보세요."
    $lblStage.Text = $msg
    return $msg
}

function Find-JoinProblem($s, $b) {
    # Friends who bounce off the server rarely know why; the log does, so say it in plain words
    $why = $b.why; $name = $b.name
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
    # While strangers keep knocking, nobody gets a "let them in?" question: one wrong click would let in the wrong person
    if ($s.quiet -and $kind -eq 'wl') { return $msg }
    $lblStage.Text = $msg
    if ($kind -eq 'wl' -and $name -and -not $s.declined.ContainsKey($name.ToLower())) { $s.askNick = $name }
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
            $s.bkSw = [Diagnostics.Stopwatch]::StartNew()
            $s.wlNames = Read-WhitelistNames $s.dir
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
            $pendNames = @()
            if (Test-Path -LiteralPath $pend) {
                $pendNames = @(Get-Content -LiteralPath $pend | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                foreach ($pn in $pendNames) {
                    $script:wlSent.Enqueue($pn); $s.proc.Send("whitelist add $pn")
                    $txtConsole.AppendText("[관리 프로그램] 기다리던 친구를 화이트리스트에 추가해요: $pn`r`n")
                }
                Remove-Item -LiteralPath $pend
            }
            Set-HostOp $s $pendNames
            Start-SeenClock $s.dir
            if ($script:modsChangedNote) {
                $script:modsChangedNote = $false
                $txtConsole.AppendText("[관리 프로그램] ※ 지난번과 모드가 달라졌어요. 프로그램을 쓰는 친구는 [▶ 게임 켜기]만 누르면 알아서 맞춰요 (1.0.13 이상).`r`n" +
                    "   앱으로 하는 친구와 처음 오는 친구에게는 [친구 초대 링크 복사]로 새 링크를 보내 주세요. 페이지가 바뀐 모드를 알려 줘요.`r`n")
                $lblStage.Text = '모드가 바뀌었어요. 앱으로 하는 친구에게는 [친구 초대 링크 복사]로 새 링크를 보내 주세요. (프로그램 쓰는 친구는 알아서 맞춰요)'
            }
        }
        if ($line -match ': (\S+) joined the game') { $s.players[$Matches[1]] = $true; $s.playedSinceBk = $true; Set-PlayerSeen $s.dir $Matches[1] }
        if ($line -match ': (\S+) left the game') { $s.players.Remove($Matches[1]) }
        if ($line -match 'lost connection: |Disconnecting ') {
            $b = Get-Bounce $line
            if ($b) {
                if ($s.done) { Add-Bounce $s $b }
                $note = Find-JoinProblem $s $b; if ($note) { [void]$sb.Append("[관리 프로그램] ※ $note`r`n") }
            }
        }
        if ($s.done -and $line -match "Can't keep up!") { $note = Add-Lag $s; if ($note) { [void]$sb.Append("[관리 프로그램] ※ $note`r`n") } }
        if ($script:liveBk -and -not $script:liveBk.proc -and $script:liveBk.dir -eq $s.dir -and $line -match 'Saved the game') { Start-LiveBackupZip }
        if ($line -match 'Added (\S+) to the whitelist') { $s.wlNames[$Matches[1].ToLower()] = $true }
        if ($line -match 'Added \S+ to the whitelist|Player is already whitelisted' -and $script:wlSent.Count) { [void]$script:wlSent.Dequeue() }
        if ($line -match 'That player does not exist') {
            # The whitelist only takes real Minecraft account names; a typo would otherwise fail silently
            $who = '방금 넣은 닉네임'; if ($script:wlSent.Count) { $who = "'$($script:wlSent.Dequeue())'" }
            $note = "$who 은(는) 마인크래프트에 없는 이름이라 화이트리스트에 못 넣었어요. 철자를 확인하고 [친구 추가]로 다시 넣어 주세요."
            [void]$sb.Append("[관리 프로그램] ※ $note`r`n"); $lblStage.Text = $note; $s.wlBad = $note
        }
    }
    if ($sb.Length) {
        if ($txtConsole.TextLength -gt 400000) { $txtConsole.Text = $txtConsole.Text.Substring($txtConsole.TextLength - 200000) }
        $txtConsole.AppendText($sb.ToString())
    }
    if ($s.wlBad -and -not $script:askingJoin) {
        $n = $s.wlBad; $s.wlBad = $null; $script:askingJoin = $true
        Show-Msg $n 'Warning'
        $script:askingJoin = $false
        if ($script:srv -ne $s) { return }
    }
    if ($s.attack -and -not $script:askingJoin) {
        $what = $s.attack; $s.attack = $null; $s.attackSaid = Get-Date; $s.askNick = $null; $script:askingJoin = $true
        $names = (@($s.strangers.Keys) | Select-Object -First 8) -join ', '; if (-not $names) { $names = '(이름 없음)' }
        $lblStage.Text = "⚠ 모르는 사람들이 들어오려고 해요. 화이트리스트가 막고 있어요. ($what)"
        $txtConsole.AppendText("[관리 프로그램] ※ 공격 의심: $what. 모르는 이름: $names`r`n")
        $ok = Ask-YesNo ("⚠ 모르는 사람들이 서버에 계속 들어오려고 해요.`n($what)`n모르는 이름: $names`n`n" +
            "화이트리스트가 막고 있어서 아무도 못 들어왔어요. 이제부터 들어오려는 사람마다 묻지 않을게요.`n" +
            "(아는 친구라면 [친구 추가]로 직접 넣으면 돼요)`n`n" +
            "모르는 이름이 섞여 있으면 서버 주소가 퍼진 거예요. 주소를 바꾸면 공격이 더는 닿지 않아요.`n지금 [주소 바꾸기 도우미]를 열까요?")
        $script:askingJoin = $false
        if ($script:srv -ne $s) { return }
        if ($ok) { Show-AddressReset }
    }
    if ($s.askNick -and -not $script:askingJoin) {
        # Asked after the read loop: the timer keeps ticking while the question is open
        $n = $s.askNick; $s.askNick = $null; $script:askingJoin = $true
        $ok = Ask-YesNo "'$n' 님이 들어오려고 했는데 화이트리스트에 없어서 막혔어요.`n`n지금 '$n' 님을 추가할까요? (아는 친구일 때만 [예]를 누르세요)"
        $script:askingJoin = $false
        if ($script:srv -ne $s) { return }
        if ($ok) { $script:wlSent.Enqueue($n); $s.proc.Send("whitelist add $n"); $txtConsole.AppendText("> whitelist add $n`r`n[관리 프로그램] '$n' 님을 추가했어요. 다시 접속하라고 알려 주세요.`r`n") }
        else { $s.declined[$n.ToLower()] = $true; Write-SecurityLog $s "들여보내지 않음: $n" }   # asked once is enough; it won't come up again until the next start
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
        if ($c -match '^/?op\s+([A-Za-z0-9_]{3,16})\s*$') {
            $who = $Matches[1]; $h = Get-HostNick $script:srv.dir
            if ($who -ine $h -and -not (Ask-YesNo ("'$who' 님을 관리자(OP)로 만들까요?`n`n관리자는 아이템을 마음대로 만들고, 다른 사람을 쫓아내고, 월드를 망가뜨릴 수도 있어요.`n" +
                        "그 친구 계정이 털리면 모르는 사람이 관리자가 돼요.`n정말 믿을 수 있는 사람일 때만 [예]를 누르세요."))) { return }
        }
        $script:srv.proc.Send($c); $txtConsole.AppendText("> $c`r`n"); $txtCmd.Clear()
    })
$txtCmd.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; $btnSend.PerformClick() } })
$btnAddFriend.Add_Click({
        $d = Get-SelDir; if (-not $d) { return }
        # First entry is usually the host's own name: offer the one this PC's game logs show
        $def = ''; if (-not @(Read-JsonList (Join-Path $d 'whitelist.json')).Count) { $def = Get-KnownNick }
        $nick = ("" + (Ask-Text "들여보낼 친구의 마인크래프트 닉네임을 입력하세요.`n(자바 에디션 계정 이름. 처음엔 내 닉네임부터 넣으세요)" $def)).Trim()
        if (-not $nick) { return }
        if ($nick -notmatch '^[A-Za-z0-9_]{3,16}$') { Show-Msg '마인크래프트 닉네임은 영어, 숫자, _ 로 3~16글자예요.'; return }
        if (-not (Add-Whitelist $d $nick)) { Show-Msg "'$nick' 님은 서버가 다음에 켜질 때 자동으로 추가할게요." }
    })
function Add-Whitelist($d, [string]$nick) {
    # Returns $true when the running server took it right away, $false when it waits for the next start
    if ($script:srv -and $script:srv.done -and $script:srv.dir -eq $d) { $script:wlSent.Enqueue($nick); $script:srv.proc.Send("whitelist add $nick"); $txtConsole.AppendText("> whitelist add $nick`r`n"); return $true }
    Add-Content -LiteralPath (Join-Path $d 'whitelist-pending.txt') -Value $nick
    return $false
}
$btnFolder.Add_Click({ $d = Get-SelDir; if ($d) { Start-Process explorer.exe "`"$d`"" } })
$btnBackup.Add_Click({ Show-Backups })
$btnFriend.Add_Click({ Show-FriendGuide })
$btnInvite.Add_Click({
        $d = Get-SelDir; if (-not $d) { Show-Msg '왼쪽 목록에서 서버를 고르세요.'; return }
        $form.Cursor = 'WaitCursor'
        try { $lblStage.Text = Copy-Invite $d } finally { $form.Cursor = 'Default' }
    })
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
    if ($script:playitPausedUntil) { return }   # taking a break from a flood; Resume-Playit brings it back
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
function Invoke-PlayitRundata([string]$key) {
    # The same call the Playit agent makes for itself (playit-agent, packages/playitd: POST /v1/agents/rundata)
    return Invoke-RestMethod -Method Post -Uri 'https://api.playit.gg/v1/agents/rundata' -Headers @{ Authorization = "Agent-Key $key" } -ContentType 'application/json' -Body '{}' -TimeoutSec 5
}
function Sync-PlayitAddress {
    # Asks Playit which address this agent's Minecraft tunnel has, so nobody has to copy it by hand.
    # note: ok / nokey / badkey / notunnel / pending / offline
    $key = Get-PlayitKey
    if (-not $key) { return @{ address = $null; note = 'nokey' } }
    try { $res = Invoke-PlayitRundata $key } catch {
        $why = 'offline'; if ("$($_.ErrorDetails.Message)$($_.Exception.Message)" -match 'InvalidAgentKey|401|403') { $why = 'badkey' }
        return @{ address = $null; note = $why }
    }
    if ($res.status -ne 'success') { $why = 'offline'; if ("$($res.data.message)" -match 'InvalidAgentKey') { $why = 'badkey' }; return @{ address = $null; note = $why } }
    $tunnels = @($res.data.tunnels | ForEach-Object { $_ } | Where-Object { $_ -and -not $_.disabled_reason })
    $mc = @($tunnels | Where-Object { "$($_.tunnel_type)" -match 'minecraft-java' }) + $tunnels | Select-Object -First 1
    if (-not $mc) { $n = 'notunnel'; if (@($res.data.pending | ForEach-Object { $_ }).Count) { $n = 'pending' }; return @{ address = $null; note = $n } }
    $a = ConvertTo-PlayitAddress ([string]$mc.display_address)
    if (-not $a) { return @{ address = $null; note = 'notunnel' } }
    if ($a -ne (Get-PlayitAddress)) { Set-PlayitAddress $a }
    return @{ address = $a; note = 'ok' }
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
        if ($script:playitKeyForeign) { $lblPlayit.Text = "Playit: 키를 한 번 다시 넣어 주세요`n(다른 PC에서 옮겨 와서 그래요)" }
        else { $lblPlayit.Text = "Playit: 연결 안 됨`n친구랑 하려면 [Playit 연결 설정]부터" }
        return
    }
    if ($script:playitPausedUntil) {
        $left = [Math]::Max(1, [int][Math]::Ceiling(($script:playitPausedUntil - (Get-Date)).TotalMinutes))
        $lblPlayit.ForeColor = [Drawing.Color]::Firebrick; $lblPlayit.Text = "Playit: 공격 의심으로 쉬는 중`n약 $($left)분 뒤 다시 연결해요"; return
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

function Get-PlayitNoteText($r) {
    switch ($r.note) {
        'ok' { return "친구용 주소를 Playit에서 가져왔어요: $($r.address)`n[친구 접속 안내]에 자동으로 들어가요." }
        'nokey' { return '먼저 ② 비밀 키를 저장해 주세요.' }
        'badkey' { return "Playit이 이 비밀 키를 모른대요.`n② [비밀 키 만드는 페이지 열기]에서 키를 다시 만들어 복사한 다음 붙여 넣고 [저장]을 눌러 주세요." }
        'pending' { return '터널을 만드는 중이래요. 1~2분 뒤에 [자동으로 가져오기]를 눌러 주세요.' }
        'notunnel' { return "아직 터널이 없어요.`n③ [터널 페이지 열기] → [Create Tunnel] → Minecraft Java, 127.0.0.1, 25565 로 만든 다음 [자동으로 가져오기]를 눌러 주세요." }
        default { return '지금은 Playit에 연결이 안 돼요. 인터넷을 확인하고 나중에 [자동으로 가져오기]를 눌러 주세요.' }
    }
}
function Get-PlayitKeyFromText([string]$t) {
    # People paste what the page shows: the bare key, "SECRET_KEY=<key>", or the whole docker command
    $t = $t.Trim()
    $m = [regex]::Match($t, 'SECRET_KEY\s*[=:]\s*["'']?([A-Za-z0-9_-]{16,})'); if ($m.Success) { return $m.Groups[1].Value }
    if ($t -match '^[A-Za-z0-9_-]{16,}$') { return $t }
    $m = [regex]::Matches($t, '\b[0-9a-fA-F]{32,}\b'); if ($m.Count -eq 1) { return $m[0].Value }
    return $null
}
function Show-PlayitSetup {
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Playit 연결 설정'; $f.Size = New-Object Drawing.Size(660, 722); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.Font = $font
    # playit.gg is in English: every step names the exact button or box to look for
    $t = New-Ctl Label 15 12 620 44 "Playit은 친구들이 들어올 인터넷 주소를 만들어 주는 무료 서비스예요.`n처음 한 번만 ①~⑤를 하면 돼요. 사이트가 영어라서 버튼과 칸 이름을 영어 그대로 적었어요."
    $s1 = New-Ctl Label 15 64 620 44 "① [playit.gg 열기] → 계정이 없으면 'Create a new account'로 가입해요(이메일, 비밀번호).`n    받은 메일의 인증 링크까지 누르면 끝이에요. 계정이 있으면 로그인만 해요."
    $b1 = New-Ctl Button 15 110 300 34 'playit.gg 열기'
    $s2 = New-Ctl Label 15 156 620 84 ("② [비밀 키 만드는 페이지 열기] → 'Docker' 고르기 → Agent Name에 영어 이름(예: mcserver)`n" +
        "    → 'Create Agent' → 'Docker run' 옆 [Copy]를 누르고 아래 칸에 붙여 넣은 다음 [저장].`n" +
        "    (명령어 줄이 통째로 들어가도 키만 골라내요. 저장하면 Playit이 바로 연결돼요)")
    $tk = New-Ctl TextBox 15 286 500 28; $tk.UseSystemPasswordChar = $true; $tk.Text = Get-PlayitKey
    $bs = New-Ctl Button 525 284 110 32 '저장'
    $b2 = New-Ctl Button 15 244 300 34 '비밀 키 만드는 페이지 열기'
    $s3 = New-Ctl Label 15 328 620 104 ("③ [터널 페이지 열기] → 'Create Tunnel'(처음엔 'Create your first tunnel'), 칸마다 고르고 'Next'.`n" +
        "    이름(예: minecraft) → Tunnel Type: Minecraft Java → Public Endpoint: Free Network`n" +
        "    → Assign to Agent: ②에서 넣은 이름 → Origin Config: 127.0.0.1 / 25565 그대로`n" +
        "    → 맨 아래 'Create Tunnel'. (Premium은 돈이 들어요. 고르지 마세요)")
    $b3 = New-Ctl Button 15 436 300 34 '터널 페이지 열기'
    $s4 = New-Ctl Label 15 482 620 44 "④ 친구용 주소(예: 어쩌구.tun.ply.gg)는 1분 안에 아래 칸에 저절로 들어가요.`n    [자동으로 가져오기]로 바로 받거나, 터널 화면 맨 위의 주소를 붙여 넣고 [저장]해도 돼요."
    $ta = New-Ctl TextBox 15 530 350 28; $ta.Text = Get-PlayitAddress
    $bAuto = New-Ctl Button 375 528 140 32 '자동으로 가져오기'
    $ba = New-Ctl Button 525 528 110 32 '저장'
    $s5 = New-Ctl Label 15 574 620 44 "⑤ 끝! 이제 [▶ 친구랑 하기]로 서버를 켜면 Playit도 같이 켜져요.`n    왼쪽 아래에 'Playit: 실행 중'과 주소가 보이면 친구들이 들어올 수 있어요."; $s5.ForeColor = [Drawing.Color]::DarkGreen
    $warn = New-Ctl Label 15 626 620 44 "비밀 키는 비밀번호 같은 거예요. 다른 사람에게 보여 주거나 보내지 마세요.`n저장한 키는 이 PC에서만 풀리게 암호화돼요. 다른 PC로 옮기면 한 번 다시 넣어야 해요."; $warn.ForeColor = [Drawing.Color]::Firebrick
    $b1.Add_Click({ Open-Url 'https://playit.gg/login' })
    $b2.Add_Click({ Open-Url 'https://playit.gg/account/setup/wizard/new-account/docker/docker-name' })
    $b3.Add_Click({ Open-Url 'https://playit.gg/account/tunnels' })
    $bs.Add_Click({
            $k = Get-PlayitKeyFromText $tk.Text
            if (-not $k) { Show-Msg "비밀 키를 찾지 못했어요.`n② 페이지에 나온 SECRET_KEY 줄(또는 긴 영어·숫자 글자)을 다시 복사해서 붙여 넣어 주세요."; return }
            $tk.Text = $k
            Save-PlayitKey $k
            if ($script:playit) { $script:playit.Kill(); $script:playit = $null }
            # A server opened with "혼자 하기" must stay private; one opened with "친구랑 하기" connects right away.
            # With no server running Playit connects too: playit.gg only lets a tunnel be assigned to an agent that has
            # connected once, and with nothing on port 25565 there is nothing to reach.
            $s = $script:srv
            if (-not $s -or -not $s.local) {
                Start-Playit
                if ($s -and $s.noPlayit -and $script:playit) { $s.noPlayit = $false; if ($s.done -and -not $s.stopping) { Show-OpenBanner $s } }
            }
            Update-PlayitLabel
            $r = Sync-PlayitAddress; if ($r.address) { $ta.Text = $r.address }
            Show-Msg ('저장했어요. 서버를 켜면 Playit도 같이 켜져요.' + "`n`n" + (Get-PlayitNoteText $r))
        })
    $ba.Add_Click({
            if (-not $ta.Text.Trim()) { Set-PlayitAddress ''; Update-PlayitLabel; Show-Msg '주소를 지웠어요.'; return }
            $a = ConvertTo-PlayitAddress $ta.Text
            if (-not $a -or $a -match '^(www\.)?playit\.gg$') { Show-Msg "주소가 올바르지 않은 것 같아요.`nplayit.gg 의 터널 목록에 나온 '어쩌구.joinmc.link' 같은 주소를 그대로 복사해서 넣어 주세요."; return }
            $ta.Text = $a
            Set-PlayitAddress $a; Update-PlayitLabel
            Show-Msg "저장했어요: $a`n이제 [친구 접속 안내]에 이 주소가 자동으로 들어가요."
        })
    $bAuto.Add_Click({ $f.Cursor = 'WaitCursor'; $r = Sync-PlayitAddress; $f.Cursor = 'Default'; if ($r.address) { $ta.Text = $r.address }; Update-PlayitLabel; Show-Msg (Get-PlayitNoteText $r) })
    $f.Controls.AddRange(@($t, $s1, $b1, $b2, $s2, $tk, $bs, $s3, $b3, $s4, $ta, $bAuto, $ba, $s5, $warn))
    [void]$f.ShowDialog($form)
}

# ---------------- Mods: add / remove ----------------
function Get-AddedMods($d) { $a = Read-Json (Join-Path $d 'added-mods.json'); if ($a) { return @($a) } return @() }
function Save-AddedMods($d, $list) { [IO.File]::WriteAllText((Join-Path $d 'added-mods.json'), (ConvertTo-Json -InputObject @($list) -Depth 4), $Utf8) }

function Resolve-FileMods($d) {
    # A .jar added from disk is often a Modrinth file under another name. Found by its hash, it goes into the invite
    # like any other Modrinth mod, so friends get it automatically instead of from a folder sent by hand.
    $list = @(Get-AddedMods $d)
    $todo = @($list | Where-Object { $_.source -eq 'file' -and -not $_.projectId -and -not $_.PSObject.Properties['mrChecked'] })
    if (-not $todo.Count) { return 0 }
    $friendDir = Join-Path $d '친구용_추가모드'
    $byHash = @{}
    foreach ($m in $todo) {
        $p = Join-Path $friendDir $m.file; if (-not (Test-Path -LiteralPath $p)) { $p = Join-Path $d "mods\$($m.file)" }
        if (Test-Path -LiteralPath $p) { $byHash[(Get-FileHash -LiteralPath $p -Algorithm SHA1).Hash.ToLower()] = $m }
    }
    $vers = @{}; $projs = @{}
    if ($byHash.Count) {
        try {
            $r = Invoke-Api 'https://api.modrinth.com/v2/version_files' 30 'Post' (@{ hashes = @($byHash.Keys); algorithm = 'sha1' } | ConvertTo-Json)
            foreach ($pp in $r.PSObject.Properties) { $vers[$pp.Name] = $pp.Value }
            $ids = @($vers.Values | ForEach-Object { $_.project_id } | Select-Object -Unique)
            if ($ids.Count) {
                $q = [uri]::EscapeDataString('["' + ($ids -join '","') + '"]')
                foreach ($pj in @(Invoke-Api "https://api.modrinth.com/v2/projects?ids=$q" | ForEach-Object { $_ })) { $projs[$pj.id] = $pj }
            }
        }
        catch { return 0 }   # offline: try again next time
    }
    $found = 0
    foreach ($h in $byHash.Keys) {
        $m = $byHash[$h]; $v = $vers[$h]
        $m | Add-Member -NotePropertyName mrChecked -NotePropertyValue $true -Force
        if (-not $v) { continue }
        $file = $v.files | Where-Object { $_.hashes.sha1 -eq $h } | Select-Object -First 1
        # Only names the friend's installer accepts (same rule as ConvertTo-ModsB64 and install.ps1)
        if (-not $file -or "$($v.project_id)" -notmatch '^[A-Za-z0-9]{4,16}$' -or "$($file.filename)" -notmatch '^[A-Za-z0-9 ._+()\[\]-]+\.jar$') { continue }
        $pj = $projs[$v.project_id]
        $m | Add-Member -NotePropertyName projectId -NotePropertyValue $v.project_id -Force
        $m | Add-Member -NotePropertyName mrFile -NotePropertyValue $file.filename -Force
        if ($pj -and $pj.title) { $m | Add-Member -NotePropertyName title -NotePropertyValue $pj.title -Force }
        if ($pj -and $pj.client_side -eq 'unsupported') {
            # Server-only after all: friends must not get it (and it can crash a game)
            $m | Add-Member -NotePropertyName forClient -NotePropertyValue $false -Force
            Remove-Item -LiteralPath (Join-Path $friendDir $m.file) -Force -ErrorAction SilentlyContinue
        }
        $found++
    }
    # Entries whose file is gone can't be looked up; mark them so they aren't hashed again every time
    foreach ($m in $todo) { if (-not $m.PSObject.Properties['mrChecked']) { $m | Add-Member -NotePropertyName mrChecked -NotePropertyValue $true -Force } }
    Save-AddedMods $d $list
    return $found
}

function Update-FriendGuide($d) {
    # Keeps the "extra mods" section of the friend guide in step with added-mods.json
    [void](Resolve-FileMods $d)
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
    if ($code -and (Test-InvitePage)) {
        $nl = $text.IndexOf("`n"); if ($nl -lt 0) { $nl = $text.Length - 1 }
        $easy = "[ 제일 쉬운 방법 ]  링크 하나로 모드팩 설치부터 서버 접속 준비까지 다 돼요`r`n" +
        "1. PC에서 초대 링크 열기: $InvitePage#$code`r`n" +
        "2. 페이지 안내대로 프로그램을 받아서 켜면(이미 있으면 [초대 코드 복사] 후 켜기) 코드가 저절로 들어가요`r`n" +
        "3. [설치하고 게임 켜기] -> 런처에서 '모드팩: ...' 을 고르고 [플레이] -> 멀티플레이 -> 서버 접속`r`n" +
        "   (방장에게 내 닉네임을 꼭 알려 주세요. 화이트리스트에 있어야 들어올 수 있어요)`r`n" +
        "프로그램 없이(CurseForge/Modrinth 앱, Mac) 하는 순서: $($InvitePage)?mode=manual#$code`r`n" +
        "접속 코드: $code`r`n`r`n" +
        "[ 직접 하는 방법 ]  CurseForge/Modrinth 앱을 쓸 때`r`n"
        $text = $text.Substring(0, $nl + 1) + "`r`n" + $easy + $text.Substring($nl + 1).TrimStart("`r", "`n")
    }
    elseif ($code) {
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
        # Every extra mod is named with where it officially comes from; no file is handed over (that would be redistribution)
        $text += "`r`n`r`n[ 추가 모드 ]  방장이 따로 넣은 모드예요. 꼭 같이 넣어야 접속돼요!`r`n"
        $text += "  [자동] 표시는 제일 쉬운 방법(이 프로그램)으로 하면 알아서 들어가요.`r`n"
        $text += "  직접 넣을 때는 아래 링크에서 받아서 내 모드팩의 mods 폴더에 넣으세요. (게임을 끈 상태에서)`r`n"
        $text += "  (CurseForge/Modrinth 앱: 모드팩 오른쪽 위 점 3개 -> Open Folder -> mods)`r`n"
        foreach ($m in $client) {
            if ($m.projectId) { $text += "  - [자동] $($m.title)  https://modrinth.com/project/$($m.projectId)`r`n" }
            elseif ($m.PSObject.Properties['sourceUrl'] -and (Test-ModUrl $m.sourceUrl)) { $text += "  - [링크] $($m.title)  $($m.sourceUrl)`r`n" }
            else { $text += "  - [방장에게 물어보기] $($m.title)  (받는 곳을 방장이 아직 안 적었어요)`r`n" }
        }
        if (@($client | Where-Object { -not $_.projectId }).Count) { $text += "  [링크] 모드는 이 프로그램으로 해도 직접 받아서 넣어야 해요. 설치가 끝나면 프로그램이 어디에 넣는지 알려 줘요.`r`n" }
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

function Request-ModSource($d, [string]$file, $log) {
    # A jar that is not on Modrinth: friends get a link to where it officially comes from, never the file itself
    $list = @(Get-AddedMods $d); $m = $list | Where-Object { $_.file -eq $file } | Select-Object -First 1
    if (-not $m) { return $false }
    $cur = ''; if ($m.PSObject.Properties['sourceUrl']) { $cur = [string]$m.sourceUrl }
    $u = ("" + (Ask-Text ("'$file' 은(는) Modrinth에서 못 찾았어요.`n모드 파일을 친구에게 직접 보내면 재배포라 문제가 될 수 있어서, 친구에게는 원본 링크를 알려 줘요.`n`n" +
                "이 모드를 받은 공식 페이지 주소를 넣어 주세요. (CurseForge, GitHub 등, https:// 로 시작)`n모르면 비워 두세요. 나중에 [선택한 모드의 원본 주소 넣기]로 넣을 수 있어요.") $cur)).Trim()
    if (-not $u) { if ($log) { $log.Invoke("'$file': 원본 주소가 없어요. 친구가 이 모드를 받을 방법을 알려 줄 수 없어요.") }; return $false }
    if (-not (Test-ModUrl $u)) { Show-Msg "주소가 올바르지 않아요. https:// 로 시작하는 페이지 주소를 그대로 복사해서 넣어 주세요."; return $false }
    $m | Add-Member -NotePropertyName sourceUrl -NotePropertyValue $u -Force
    Save-AddedMods $d $list; Update-FriendGuide $d
    if ($log) { $log.Invoke("'$file': 친구에게 원본 링크($(Get-UrlSite $u))를 알려 줄게요.") }
    return $true
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
    $bo = New-Ctl Button 475 312 220 36 '선택한 모드의 원본 주소 넣기'
    $bi = New-Ctl Button 705 312 170 36 '초대 링크 복사'; $bi.BackColor = [Drawing.Color]::FromArgb(222, 234, 250)
    $l2 = New-Ctl Label 15 360 860 22 "이 서버에 직접 추가한 모드   ([자동] 친구 PC가 알아서 받아요  /  [링크] 친구가 원본 페이지에서 받아요  /  [주소 필요])"
    $lb = New-Ctl ListBox 15 385 600 130
    $br = New-Ctl Button 625 385 250 36 '선택한 모드 빼기'
    $lg = New-Ctl TextBox 15 525 860 70; $lg.Multiline = $true; $lg.ReadOnly = $true; $lg.ScrollBars = 'Vertical'
    $f.Controls.AddRange(@($l1, $tq, $bq, $lv, $ba, $bf, $bo, $bi, $l2, $lb, $br, $lg))
    $log = { param($m) $lg.AppendText("$m`r`n"); [Windows.Forms.Application]::DoEvents() }
    $refresh = {
        $lb.Items.Clear()
        foreach ($m in (Get-AddedMods $d)) {
            $where = @(); if ($m.onServer) { $where += '서버' }; if ($m.forClient) { $where += '친구' }
            $how = ''
            if ($m.forClient) { $how = '[자동] '; if (-not $m.projectId) { $how = '[주소 필요] '; if ($m.PSObject.Properties['sourceUrl'] -and (Test-ModUrl $m.sourceUrl)) { $how = '[링크] ' } } }
            [void]$lb.Items.Add("$how$($m.title)   [$($where -join '+')]   $($m.file)")
        }
    }
    $bi.Add_Click({ $f.Cursor = 'WaitCursor'; try { $log.Invoke((Copy-Invite $d)) } finally { $f.Cursor = 'Default'; & $refresh } })
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
                else { Add-ModrinthMod $d $h.project_id $mc $loader $inst $log; Update-FriendGuide $d; $log.Invoke('완료! [초대 링크 복사]로 친구들에게 새 링크를 보내 주세요. 친구는 링크만 열면 이 모드까지 자동으로 받아요.') }
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
                if ([McsmScan]::ScanJar($p) -eq 1) {
                    Write-SecurityLog @{ dir = $d; secLogged = 0 } "악성코드 감염 모드 추가 거부: $leaf"
                    Show-Msg "⚠ '$leaf' 은(는) 악성코드(fractureiser)에 감염된 파일이에요. 추가하지 않았어요.`n`n이 파일은 지우고, Windows 보안에서 [전체 검사]를 해 주세요. 모드는 공식 사이트(Modrinth, CurseForge)에서만 받으세요." 'Warning'
                    continue
                }
                Copy-Item -LiteralPath $p -Destination (Join-Path $d 'mods') -Force
                Copy-Item -LiteralPath $p -Destination $friendDir -Force
                $list = @($list | Where-Object { $_.file -ne $leaf }) + [pscustomobject]@{ projectId = ''; title = $leaf; file = $leaf; onServer = $true; forClient = $true; source = 'file' }
                $log.Invoke("추가: $leaf  ->  서버")
            }
            Save-AddedMods $d $list
            $f.Cursor = 'WaitCursor'
            try {
                # Look the files up on Modrinth now, so the host knows right away which ones the invite link can carry
                $before = @(Get-AddedMods $d | Where-Object { $_.forClient -and -not $_.projectId }).Count
                Update-FriendGuide $d
                $after = @(Get-AddedMods $d | Where-Object { $_.forClient -and -not $_.projectId })
                if ($before -gt $after.Count) { $log.Invoke("Modrinth에서 찾은 모드 $($before - $after.Count)개는 친구가 초대 링크로 자동으로 받아요.") }
                # Not on Modrinth: the file itself must not be passed on, so ask where it officially comes from
                foreach ($m in @($after | Where-Object { -not ($_.PSObject.Properties['sourceUrl'] -and (Test-ModUrl $_.sourceUrl)) })) { [void](Request-ModSource $d $m.file $log) }
            }
            finally { $f.Cursor = 'Default'; & $refresh }
            $log.Invoke('선행 모드가 필요한 모드라면 그 모드도 따로 추가해야 해요. 다 넣었으면 [초대 링크 복사]로 친구들에게 새 링크를 보내 주세요.')
        })
    $bo.Add_Click({
            if ($lb.SelectedIndex -lt 0) { Show-Msg '아래 목록에서 모드를 고르세요.'; return }
            $m = @(Get-AddedMods $d)[$lb.SelectedIndex]
            if ($m.projectId) { Show-Msg "'$($m.title)' 은(는) Modrinth 모드라서 친구 PC가 알아서 받아요. 주소를 넣을 필요가 없어요."; return }
            [void](Request-ModSource $d $m.file $log); & $refresh
        })
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
function ConvertFrom-PropEscape([string]$v) {
    # Java properties escapes: \uXXXX, \n, \t, \r, and a backslash before any other character stands for that character
    return [regex]::Replace($v, '\\(u[0-9a-fA-F]{4}|.)', { param($m) $x = $m.Groups[1].Value
            if ($x.Length -eq 5) { return [string][char][Convert]::ToInt32($x.Substring(1), 16) }
            switch -CaseSensitive ($x) { 'n' { "`n" } 't' { "`t" } 'r' { "`r" } default { $x } } })
}
function ConvertTo-PropEscape([string]$v) {
    # Java properties are read as ISO-8859-1 by older servers; \uXXXX escapes keep Korean text intact on every version
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $v.ToCharArray()) {
        if ([int]$ch -gt 126) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) }
        elseif ($ch -eq [char]10) { [void]$sb.Append('\n') } elseif ($ch -eq [char]13) { [void]$sb.Append('\r') } elseif ($ch -eq [char]92) { [void]$sb.Append('\\') }
        else { [void]$sb.Append($ch) }
    }
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
    $knock = 0; $flood = $false; $since = (Get-Date).AddDays(-1).ToString('yyyy-MM-dd HH:mm:ss')
    $sl = Join-Path $d 'security-log.txt'
    if (Test-Path -LiteralPath $sl) {
        foreach ($l in @(Get-Content -LiteralPath $sl -Tail 2000 -Encoding UTF8)) {
            if ($l.Length -lt 19 -or $l.Substring(0, 19) -lt $since) { continue }
            if ($l -match '모르는 사람 접속 시도|이름 없는 접속 시도') { $knock++ }
            if ($l -match '접속 폭주|공격 의심') { $flood = $true }
        }
    }
    Add-Item ($knock -lt 5 -and -not $flood) "낯선 접속 시도 $($knock)번 (최근 24시간)" '화이트리스트에 없는 사람이 들어오려고 한 횟수예요 (모두 막혔어요). 많거나 공격 의심 기록이 있으면 주소가 퍼진 거예요. 아래 [주소 바꾸기 도우미]로 주소를 바꾸세요. 기록은 서버 폴더의 security-log.txt에 있어요.'
    $ops = @(Read-JsonList (Join-Path $d 'ops.json'))
    $hn = Get-HostNick $d
    $others = @($ops | Where-Object { "$($_.name)" -ine $hn } | ForEach-Object { "$($_.name)" })
    if ($hn) {
        $why = "관리자는 아이템을 마음대로 만들고 월드를 망가뜨릴 수도 있어요. 친구 계정이 털리면 그 사람이 관리자가 돼요."
        if ($others.Count) { $why += " 방장 말고 관리자인 사람: $($others -join ', '). 자동으로 고치면 관리자에서 빼요." }
        elseif (-not $ops.Count) { $why += " 서버를 켜면 방장($hn)을 자동으로 관리자로 정해요. 관리자가 있어야 스폰 보호가 작동해요." }
        Add-Item ($others.Count -eq 0) "관리자(OP)는 방장만" $why 'ops'
    }
    else { Add-Item ($ops.Count -le 1) "관리자(OP) $($ops.Count)명" "방장 닉네임을 아직 몰라요. [▶ 마인크래프트 켜기]를 한 번 하면 알게 되고, 그다음부터 방장만 관리자로 둬요. $($others -join ', ')" }
    $stale = @(Get-StaleFriends $d)
    Add-Item ($stale.Count -eq 0) "오래 안 들어온 친구 $($stale.Count)명 ($($StaleDays)일 넘게)" "친구 계정이 털리면 그 계정으로 들어올 수 있어요. 안 오는 친구는 화이트리스트에서 빼 두세요. 다시 오면 [친구 추가]로 넣으면 돼요. $($stale -join ', ')" 'wl-stale'
    $bc = Get-BackupCopyDir $d
    Add-Item ([bool]$bc -and (Test-Path -LiteralPath $bc)) '백업을 PC 밖에도 복사' "디스크가 고장 나거나 랜섬웨어에 걸리면 월드와 이 PC 안의 백업이 같이 사라져요. [백업 / 월드 관리] → [복사할 곳 고르기]에서 OneDrive 폴더나 USB를 골라 두세요. $bc"
    $scan = Read-Json (Join-Path $d 'mod-scan.json'); $scanned = 0; $infected = 0
    if ($scan) { foreach ($p in $scan.PSObject.Properties) { $scanned++; if ([int]$p.Value -eq 1) { $infected++ } } }
    $pcBad = Test-PcInfected
    $scanText = "서버를 켤 때마다 모드 파일에 악성코드(fractureiser)가 없는지 확인해요. 지금까지 $($scanned)개 확인."
    if ($infected) { $scanText = "감염된 모드 파일 $($infected)개가 있어요. 서버를 켜면 격리 폴더로 옮기자고 물어봐요. 그다음 Windows 보안에서 [전체 검사]를 하세요." }
    if ($pcBad) { $scanText = "이 PC에서 악성코드가 남기는 폴더를 찾았어요: $(Join-Path $env:LOCALAPPDATA 'Microsoft Edge'). 마인크래프트를 다 끄고 이 폴더를 지운 다음, Windows 보안에서 [전체 검사]를 하세요." }
    Add-Item (-not $infected -and -not $pcBad) '모드 파일 악성코드 검사' $scanText
    $cloud = $Root -match '(?i)OneDrive|Dropbox|Google ?Drive|iCloud|MEGA'
    Add-Item (-not $cloud) '클라우드 동기화 폴더 아님' "클라우드 동기화 폴더 안이면 월드와 서버 파일이 인터넷에 올라가요. 프로그램 폴더 위치: $Root"
    Add-Item (-not (Test-Path -LiteralPath $PlayitKeyPlain)) 'Playit 비밀 키 암호화' '키를 이 PC에서만 풀리게 암호화해서 저장해요. 폴더가 새어 나가도 남이 키를 쓸 수 없어요.'
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Add-Item (-not $admin) '관리자 권한으로 실행 안 함' '관리자 권한으로 돌리면 모드 문제가 컴퓨터 전체로 번질 수 있어요. 그냥 더블클릭해서 실행하세요.'
    $fw = $null
    try {
        $javaDir = Join-Path $Prog 'java'
        $fw = @(Get-NetFirewallApplicationFilter -ErrorAction Stop | Where-Object { $_.Program -like "$javaDir*" } | Get-NetFirewallRule -ErrorAction Stop |
            Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' -and ($_.Profile -match 'Public|Any') })
    }
    catch { }
    if ($null -ne $fw) { Add-Item ($fw.Count -eq 0) '방화벽: 공용 네트워크에 안 열림' 'Playit을 쓰면 방화벽을 열 필요가 없어요. 카페 와이파이 같은 공용 네트워크에서 서버가 노출되지 않게, 처음 뜨는 방화벽 허용 창은 [취소]를 누르세요. 이미 허용했다면 제어판 → Windows Defender 방화벽 → 앱 허용에서 OpenJDK의 "공용" 체크를 끄세요.' }
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
    # Garbage collector tuned for servers (short pauses instead of a freeze every few minutes, which many players feel at once).
    # A pack that ships its own -XX: settings knows its mods better, so those are left alone. Checked against bundled Java 17 and 21.
    if ((Test-Path -LiteralPath $jvm) -and -not ((Get-Content -LiteralPath $jvm -Raw) -match '(?m)^\s*-XX:')) {
        $latin1 = [Text.Encoding]::GetEncoding(28591)
        $lines = @([IO.File]::ReadAllLines($jvm, $latin1)) + $ServerGcFlags
        [IO.File]::WriteAllLines($jvm, [string[]]$lines, $latin1)
    }
}
$ServerGcFlags = @('-XX:+UseG1GC', '-XX:+ParallelRefProcEnabled', '-XX:MaxGCPauseMillis=200', '-XX:+UnlockExperimentalVMOptions', '-XX:+DisableExplicitGC',
    '-XX:G1NewSizePercent=30', '-XX:G1MaxNewSizePercent=40', '-XX:G1HeapRegionSize=8M', '-XX:G1ReservePercent=20', '-XX:InitiatingHeapOccupancyPercent=15',
    '-XX:SurvivorRatio=32', '-XX:MaxTenuringThreshold=1', '-XX:+PerfDisableSharedMem')

function Repair-Security($d, $report) {
    $props = @{}
    foreach ($it in $report) {
        if ($it.ok -or -not $it.fix) { continue }
        if ($it.fix -is [hashtable]) { foreach ($k in $it.fix.Keys) { $props[$k] = $it.fix[$k] } }
        elseif ($it.fix -eq 'log4j') { Add-Content -LiteralPath (Join-Path $d 'user_jvm_args.txt') -Value '-Dlog4j2.formatMsgNoLookups=true' -Encoding ascii }
        elseif ($it.fix -eq 'ops') {
            # Runs only while the server is off (the fix button checks), so the files can be edited directly
            $hn = Get-HostNick $d; $op = Join-Path $d 'ops.json'
            $ops = @(Read-JsonList $op); $others = @($ops | Where-Object { "$($_.name)" -ine $hn })
            if ($hn -and $others.Count -and (Ask-YesNo "이 사람들을 관리자(OP)에서 뺄까요? (화이트리스트에는 그대로 있어서 계속 들어올 수 있어요)`n`n$((($others | ForEach-Object { $_.name }) -join ', '))")) {
                [IO.File]::WriteAllText($op, (ConvertTo-Json -InputObject @($ops | Where-Object { "$($_.name)" -ieq $hn }) -Depth 4), $Utf8)
            }
        }
        elseif ($it.fix -eq 'wl-stale') {
            $stale = @(Get-StaleFriends $d); $wf = Join-Path $d 'whitelist.json'
            if ($stale.Count -and (Ask-YesNo "$($StaleDays)일 넘게 안 들어온 이 친구들을 화이트리스트에서 뺄까요?`n다시 오면 [친구 추가]로 넣으면 돼요.`n`n$($stale -join ', ')")) {
                $keep = @(Read-JsonList $wf | Where-Object { "$($_.name)" -notin $stale })
                [IO.File]::WriteAllText($wf, (ConvertTo-Json -InputObject $keep -Depth 4), $Utf8)
            }
        }
    }
    if ($props.Count) { Set-Props $d $props }
}

function Show-Security {
    $d = Get-SelDir; if (-not $d) { Show-Msg '왼쪽 목록에서 서버를 고르세요.'; return }
    $f = New-Object Windows.Forms.Form
    $f.Text = "보안 점검 - $($lstSrv.SelectedItem)"; $f.Size = New-Object Drawing.Size(1000, 660); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.Font = $font
    $lv = New-Object Windows.Forms.ListView; $lv.Location = New-Object Drawing.Point(15, 15); $lv.Size = New-Object Drawing.Size(955, 196); $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.Font = $font; $lv.ShowItemToolTips = $true; $lv.HideSelection = $false
    [void]$lv.Columns.Add('결과', 84); [void]$lv.Columns.Add('항목', 270); [void]$lv.Columns.Add('설명', 578)
    # The list cuts long explanations short; the full one for the chosen row is shown underneath
    $ldet = New-Ctl Label 15 214 955 54 ''; $ldet.ForeColor = [Drawing.Color]::FromArgb(40, 40, 40)
    $lv.Add_SelectedIndexChanged({ if ($lv.SelectedItems.Count) { $s = $lv.SelectedItems[0]; $ldet.Text = "$($s.SubItems[1].Text): $($s.ToolTipText)" } })
    $bfix = New-Ctl Button 15 272 300 36 '고칠 수 있는 것 자동으로 고치기'
    $lnote = New-Ctl Label 325 278 645 24 ''; $lnote.ForeColor = [Drawing.Color]::DimGray
    $tips = New-Ctl TextBox 15 318 955 250; $tips.Multiline = $true; $tips.ReadOnly = $true; $tips.ScrollBars = 'Vertical'; $tips.BackColor = [Drawing.Color]::White
    $bReset = New-Ctl Button 15 575 270 36 '주소 바꾸기 도우미'; $bReset.Font = $bold
    $bTun = New-Ctl Button 295 575 270 36 'playit.gg 터널 페이지 열기'
    $bGuide = New-Ctl Button 575 575 270 36 '친구 접속 안내 열기'
    $bReset.Add_Click({ $f.Close(); Show-AddressReset })
    $bTun.Add_Click({ Open-Url 'https://playit.gg/account/tunnels' })
    $bGuide.Add_Click({ $f.Close(); Show-FriendGuide })
    $tips.Text = @"
[ 평소에 지킬 것 ]
 - 친구들에게는 Playit 주소(어쩌구.joinmc.link)만 알려 주세요. 우리 집 IP 주소는 절대 알려 주지 마세요.
   공격이 들어와도 Playit 쪽이 먼저 맞아서 우리 집 인터넷까지는 잘 안 와요.
 - 공유기 포트포워딩(25565)은 하지 마세요. Playit을 쓰면 필요 없고, 하면 집 IP가 그대로 드러나요.
 - 서버 주소를 유튜브, 디스코드 공개 채널, 커뮤니티에 올리지 마세요.

[ 프로그램이 알아서 막는 것 ]
 - 화이트리스트에 없는 사람이 계속 들어오려고 하면(10분에 모르는 이름 $($AttackStrangers)개, 또는 1분에 $($AttackBounces)번)
   알려 드리고, 그때부터는 "추가할까요?"를 묻지 않아요. 실수로 모르는 사람을 들여보내는 일이 없게요.
 - 1분에 $($FloodBounces)번 넘게 몰려오면 Playit 연결을 $($FloodPauseMinutes)분 동안 끊어요. 서버와 월드는 그대로 켜져 있어요.
 - 친구 닉네임으로 들어오려다 정품 확인에 실패한 것도 공격으로 세요. (정품 인증 덕분에 남의 이름으로는 못 들어와요)
 - 기록은 서버 폴더의 security-log.txt 에 남고, 위 목록에 최근 24시간 횟수가 보여요.

[ 공격을 받는 것 같을 때 (갑자기 렉, 다들 접속이 끊김, 모르는 이름이 계속 보임) ]
 → 아래 [주소 바꾸기 도우미]를 누르고 순서대로 하세요. 서버를 끄지 않아도 돼요.
 1. 터널 페이지에서 지금 쓰던 터널을 지우고(Delete), [Create Tunnel] → Minecraft Java, 127.0.0.1, 25565 로 새로 만들기
 2. [새 주소 가져오기]
 3. [새 초대 링크 복사] → 믿는 친구에게만 보내기
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
    $f.Controls.AddRange(@($lv, $ldet, $bfix, $lnote, $tips, $bReset, $bTun, $bGuide))
    $fill = {
        $lv.Items.Clear(); $script:secReport = Get-SecurityReport $d; $bad = 0
        foreach ($it in $script:secReport) {
            $mark = '✔ 안전'; if (-not $it.ok) { $mark = '⚠ 확인'; $bad++ }
            # The list shows the first sentence; the label under it shows all of it
            $first1 = ($it.detail -split '(?<=[.요다])\s+', 2)[0]
            $row = New-Object Windows.Forms.ListViewItem($mark); [void]$row.SubItems.Add($it.title); [void]$row.SubItems.Add($first1)
            if (-not $it.ok) { $row.ForeColor = [Drawing.Color]::Firebrick }
            $row.ToolTipText = $it.detail
            [void]$lv.Items.Add($row)
        }
        # Start on the first item that needs attention (or the first one), so its full explanation is visible right away
        if ($lv.Items.Count) { $first = @($lv.Items | Where-Object { $_.ForeColor -eq [Drawing.Color]::Firebrick }) + @($lv.Items[0]) | Select-Object -First 1; $first.Selected = $true }
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

function Show-AddressReset {
    # A leaked address is fixed by giving the server a new one: the old tunnel is deleted, so attacks on it go nowhere
    $d = $null; if ($script:srv) { $d = $script:srv.dir } else { $d = Get-SelDir }
    $old = Get-PlayitAddress
    $f = New-Object Windows.Forms.Form
    $f.Text = '주소 바꾸기 도우미'; $f.Size = New-Object Drawing.Size(640, 600); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.Font = $font
    $oldText = $old; if (-not $oldText) { $oldText = '(아직 없어요)' }
    $t = New-Ctl Label 15 12 600 64 "서버 주소가 모르는 사람에게 퍼졌을 때 새 주소로 바꿔요. 서버는 켜 둔 채로 해도 돼요.`n(터널을 지우는 순간 지금 접속한 친구들은 끊겨요. 새 링크로 다시 들어오면 돼요)`n지금 주소: $oldText"
    $s1 = New-Ctl Label 15 86 600 44 "① [터널 페이지 열기] → 지금 쓰던 터널을 지우고(Delete) [Create Tunnel]을 눌러`n    Minecraft Java, 127.0.0.1, 25565 로 새로 만들어요."
    $b1 = New-Ctl Button 15 134 260 36 '터널 페이지 열기'
    $s2 = New-Ctl Label 15 184 600 24 '② 새 터널을 만들었으면 눌러요. Playit에서 새 주소를 가져와요.'
    $b2 = New-Ctl Button 15 212 260 36 '새 주소 가져오기'
    $l2 = New-Ctl Label 15 254 600 76 ''
    $s3 = New-Ctl Label 15 338 600 24 '③ 새 초대 링크를 복사해서 믿는 친구에게만 보내요.'
    $b3 = New-Ctl Button 15 366 260 36 '새 초대 링크 복사'; $b3.Enabled = $false
    $l3 = New-Ctl Label 15 408 600 76 ''; $l3.ForeColor = [Drawing.Color]::DarkGreen
    $warn = New-Ctl Label 15 494 600 44 '새 주소는 단톡방 공지, 공개 채널, 커뮤니티에 올리지 마세요. 1:1이나 믿는 사람만 있는 방에만 보내요.'; $warn.ForeColor = [Drawing.Color]::Firebrick
    $b1.Add_Click({ Open-Url 'https://playit.gg/account/tunnels' })
    $b2.Add_Click({
            $f.Cursor = 'WaitCursor'; $r = Sync-PlayitAddress; $f.Cursor = 'Default'; Update-PlayitLabel
            if (-not $r.address) { $l2.ForeColor = [Drawing.Color]::Firebrick; $l2.Text = Get-PlayitNoteText $r; return }
            if ($old -and $r.address -eq $old) { $l2.ForeColor = [Drawing.Color]::DarkOrange; $l2.Text = "아직 예전 주소예요 ($($r.address)).`n예전 터널을 지웠는지 확인하고, 1~2분 뒤 다시 눌러 주세요."; return }
            $l2.ForeColor = [Drawing.Color]::DarkGreen; $l2.Text = "새 주소: $($r.address)"; $b3.Enabled = [bool]$d
            if ($script:srv -and $script:srv.done -and -not $script:srv.stopping) { Show-OpenBanner $script:srv }
        })
    $b3.Add_Click({ $l3.Text = Copy-Invite $d })
    $f.Controls.AddRange(@($t, $s1, $b1, $s2, $b2, $l2, $s3, $b3, $l3, $warn))
    [void]$f.ShowDialog($form)
}

# ---------------- is a server really running? (however it was started) ----------------
# ---------------- the server tells friends' programs what it runs now ----------------
# Minecraft's server list shows two lines of the server description. The current invitation goes on a line after those,
# so a friend's copy can ask the server (the same status request the server list makes) whether mods changed since it
# installed, and catch up without a new link. Anyone who can reach the address could read it, but that is what the
# server itself shows a connecting game anyway: address, modpack and mod list.
$MotdSyncTag = 'mcsm-sync:'
function Get-UserMotd([string]$m) { $i = $m.IndexOf("`n`n$MotdSyncTag"); if ($i -ge 0) { return $m.Substring(0, $i) }; return $m }
function Set-InviteMotd($d) {
    $user = Get-UserMotd ([string](Get-Props $d)['motd']); if (-not $user.Trim()) { $user = Split-Path $d -Leaf }
    $code = Get-JoinCode $d; if (-not $code) { return }
    # A modpack may set its description from a mod; this one still lands in server.properties, which is what most use
    Set-Props $d @{ 'motd' = "$user`n`n$MotdSyncTag$code" }
    $i = Read-Json (Join-Path $d 'server-info.json')
    $sig = ConvertTo-ModsB64 (Read-JoinCode $code).m
    $prev = ''; if ($i -and $i.PSObject.Properties['lastMods']) { $prev = [string]$i.lastMods }
    if ($i -and $i.PSObject.Properties['lastMods'] -and $prev -ne $sig) { $script:modsChangedNote = $true }
    Set-InfoField $d 'lastMods' $sig
}
function Read-VarInt($st) {
    $v = 0; $shift = 0
    while ($true) { $b = $st.ReadByte(); if ($b -lt 0) { throw 'closed' }; $v = $v -bor (($b -band 0x7F) -shl $shift); if (-not ($b -band 0x80)) { return $v }; $shift += 7; if ($shift -gt 28) { throw 'bad varint' } }
}
function ConvertTo-VarInt([int]$v) { $b = New-Object System.Collections.Generic.List[byte]; do { $t = $v -band 0x7F; $v = $v -shr 7; if ($v) { $t = $t -bor 0x80 }; $b.Add([byte]$t) } while ($v); return , $b.ToArray() }
function Get-ChatText($o) {
    # A server description is either text or a chat object ({ text, extra: [...] })
    if ($null -eq $o) { return '' }; if ($o -is [string]) { return $o }
    $t = ''; if ($o.PSObject.Properties['text']) { $t = [string]$o.text }
    if ($o.PSObject.Properties['extra']) { foreach ($x in @($o.extra)) { $t += Get-ChatText $x } }
    return $t
}
function Get-ServerDescription([string]$addr, [int]$timeoutMs = 5000) {
    # The status request a game's server list sends; nothing logs in
    $hostName = $addr; $port = 25565
    if ($addr -match '^(.+):(\d{1,5})$') { $hostName = $Matches[1]; $port = [int]$Matches[2] }
    if ($hostName -notmatch '^[A-Za-z0-9.-]+$') { return $null }
    $c = New-Object Net.Sockets.TcpClient
    try {
        $iar = $c.BeginConnect($hostName, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { return $null }
        $c.EndConnect($iar); $st = $c.GetStream(); $st.ReadTimeout = $timeoutMs; $st.WriteTimeout = $timeoutMs
        $hb = [Text.Encoding]::UTF8.GetBytes($hostName)
        $body = (ConvertTo-VarInt 0) + (ConvertTo-VarInt 767) + (ConvertTo-VarInt $hb.Length) + $hb + [byte[]]@((($port -shr 8) -band 0xFF), ($port -band 0xFF)) + (ConvertTo-VarInt 1)
        $pkt = [byte[]]((ConvertTo-VarInt $body.Length) + $body + [byte[]](1, 0)); $st.Write($pkt, 0, $pkt.Length)
        $len = Read-VarInt $st; if ($len -le 0 -or $len -gt 2MB) { return $null }
        $buf = New-Object byte[] $len; $got = 0
        while ($got -lt $len) { $n = $st.Read($buf, $got, $len - $got); if ($n -le 0) { return $null }; $got += $n }
        $ms = New-Object IO.MemoryStream(, $buf)
        if ((Read-VarInt $ms) -ne 0) { return $null }
        $sl = Read-VarInt $ms
        $j = [Text.Encoding]::UTF8.GetString($buf, [int]$ms.Position, $sl) | ConvertFrom-Json
        return Get-ChatText $j.description
    }
    catch { return $null }
    finally { $c.Close() }
}
function Find-HostCode([string]$addr, [string]$name) {
    # The host's current invitation, read from its running server; $null when it is off or older than 1.0.13
    $desc = Get-ServerDescription $addr; if (-not $desc) { return $null }
    $i = $desc.IndexOf($MotdSyncTag); if ($i -lt 0) { return $null }
    $c = Read-JoinCode $desc.Substring($i + $MotdSyncTag.Length)
    if (-not $c -or $c.n -ne $name) { return $null }
    return $c
}
function ConvertFrom-ModsB64([string]$b64) {
    if (-not $b64) { return @() }
    try { return @([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { $_ }) } catch { return @() }
}
function Get-JoinChanges($oldMods, $oldLinks, $new) {
    # What the host changed: Modrinth mods by file, link-only mods by address
    $om = @{}; foreach ($x in @($oldMods)) { if ($x) { $om["$($x.f)"] = $x } }
    $nm = @{}; foreach ($x in @($new.m)) { if ($x) { $nm["$($x.f)"] = $x } }
    $ol = @{}; foreach ($x in @($oldLinks)) { if ($x) { $ol["$($x.u)"] = $x } }
    $nl = @{}; foreach ($x in @($new.l)) { if ($x) { $nl["$($x.u)"] = $x } }
    $r = [pscustomobject]@{
        addMods = @($nm.Keys | Where-Object { -not $om.ContainsKey($_) } | ForEach-Object { $nm[$_] })
        delMods = @($om.Keys | Where-Object { -not $nm.ContainsKey($_) } | ForEach-Object { $om[$_] })
        addLinks = @($nl.Keys | Where-Object { -not $ol.ContainsKey($_) } | ForEach-Object { $nl[$_] })
        delLinks = @($ol.Keys | Where-Object { -not $nl.ContainsKey($_) } | ForEach-Object { $ol[$_] })
    }
    $r | Add-Member -NotePropertyName any -NotePropertyValue ([bool]($r.addMods.Count + $r.delMods.Count + $r.addLinks.Count + $r.delLinks.Count))
    return $r
}

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

function Test-BackupSpace($d, $w) {
    $size = [long](Get-ChildItem -LiteralPath $w -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($d))
    return $drive.AvailableFreeSpace -ge ($size + 2GB)
}

# Every clean stop leaves a backup behind, so a beginner always has yesterday's world even if they never pressed a button
$AutoBackupKeep = 5
$script:autoBk = $null
function Start-AutoBackup($d) {
    $w = Get-LevelDir $d
    if (-not (Test-Path -LiteralPath (Join-Path $w 'level.dat'))) { return }
    $bk = Join-Path $d 'backups'; New-Item -ItemType Directory -Force $bk | Out-Null
    Get-ChildItem -LiteralPath $bk -Filter '*.part' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    if (-not (Test-BackupSpace $d $w)) {
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
        Copy-BackupOut $b.dir $b.zip
        if (-not $script:srv) { Set-State '● 꺼짐' ([Drawing.Color]::Gray); $lblStage.Text = '서버가 안전하게 꺼졌고, 월드도 자동으로 백업했어요.' }
    }
    else {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        $txtConsole.AppendText("[관리 프로그램] 자동 백업을 만들지 못했어요. [백업 / 월드 관리] → [지금 백업하기]로 한 번 해 주세요.`r`n")
        if (-not $script:srv) { Set-State '● 꺼짐' ([Drawing.Color]::Gray); $lblStage.Text = '서버는 안전하게 꺼졌어요. (자동 백업은 실패했어요)' }
    }
}
# A server that stays up for days with 20 people on it would otherwise have no backup newer than its last stop.
# Every few hours (only if someone played), saving pauses, the world is zipped, and saving resumes.
$LiveBackupHours = 3
$LiveBackupKeep = 8
$script:liveBk = $null
function Start-LiveZipProc($w, $out) {
    # A running server keeps session.lock locked and its region files open for writing: skip the lock and read the rest
    # with sharing allowed (saving is paused, so nothing changes underneath). Same layout as the stopped-server backups.
    $src = ($w -replace "'", "''").TrimEnd('\'); $dst = $out -replace "'", "''"
    $cmd = @"
`$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
`$src = '$src'
try {
    `$z = [IO.Compression.ZipFile]::Open('$dst', 'Create')
    try {
        foreach (`$f in @(Get-ChildItem -LiteralPath `$src -Recurse -File -Force)) {
            if (`$f.Name -eq 'session.lock') { continue }
            `$in = [IO.File]::Open(`$f.FullName, 'Open', 'Read', 'ReadWrite, Delete')
            try { `$es = `$z.CreateEntry(`$f.FullName.Substring(`$src.Length + 1).Replace('\', '/')).Open(); try { `$in.CopyTo(`$es) } finally { `$es.Dispose() } }
            finally { `$in.Dispose() }
        }
    }
    finally { `$z.Dispose() }
}
catch { exit 1 }
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    return New-Object McProc('powershell.exe', "-NoProfile -NonInteractive -EncodedCommand $enc", (Split-Path $out -Parent), [Text.Encoding]::Default.CodePage)
}
function Start-LiveBackup {
    $s = $script:srv
    if (-not $s -or -not $s.done -or $s.stopping -or $script:liveBk -or $script:autoBk) { return $false }
    $w = Get-LevelDir $s.dir
    if (-not (Test-Path -LiteralPath (Join-Path $w 'level.dat'))) { return $false }
    $s.bkSw = [Diagnostics.Stopwatch]::StartNew(); $s.playedSinceBk = [bool]$s.players.Count
    if (-not (Test-BackupSpace $s.dir $w)) {
        $txtConsole.AppendText("[관리 프로그램] 디스크 공간이 모자라서 켜진 채로 하는 백업을 건너뛰었어요. 오래된 백업이나 servers_old 폴더를 지우면 공간이 생겨요.`r`n")
        return $false
    }
    $bk = Join-Path $s.dir 'backups'; New-Item -ItemType Directory -Force $bk | Out-Null
    $script:liveBk = [pscustomobject]@{ dir = $s.dir; zip = (Join-Path $bk ('live_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.zip')); proc = $null; sw = [Diagnostics.Stopwatch]::StartNew() }
    # The zip starts when the server reports "Saved the game" (Read-ServerOutput)
    $s.proc.Send('save-off'); $s.proc.Send('save-all flush')
    $txtConsole.AppendText("[관리 프로그램] 서버를 켠 채로 월드를 백업해요. 잠깐 렉이 있을 수 있어요.`r`n")
    return $true
}
function Start-LiveBackupZip {
    $b = $script:liveBk
    $b.proc = Start-LiveZipProc (Get-LevelDir $b.dir) "$($b.zip).part"
    $b.sw = [Diagnostics.Stopwatch]::StartNew()
}
function Stop-LiveBackup([string]$why) {
    $b = $script:liveBk; if (-not $b) { return }
    $script:liveBk = $null
    if ($b.proc) { $b.proc.Kill(); try { [void]$b.proc.P.WaitForExit(5000) } catch { } }
    Remove-Item -LiteralPath "$($b.zip).part" -Force -ErrorAction SilentlyContinue
    $s = $script:srv; if ($s -and $s.dir -eq $b.dir -and $s.proc.Running) { $s.proc.Send('save-on') }
    if ($why) { $txtConsole.AppendText("[관리 프로그램] $why`r`n") }
}
function Update-LiveBackup {
    # Called by the window timer
    $b = $script:liveBk; $s = $script:srv
    if (-not $b) {
        if ($s -and $s.done -and -not $s.stopping -and $s.bkSw -and $s.bkSw.Elapsed.TotalHours -ge $LiveBackupHours) {
            # Nobody played since the last one: the world hasn't changed, so don't fill the disk with copies
            if ($s.playedSinceBk -or $s.players.Count) { [void](Start-LiveBackup) } else { $s.bkSw = [Diagnostics.Stopwatch]::StartNew() }
        }
        return
    }
    if (-not $b.proc) {
        if ($b.sw.Elapsed.TotalSeconds -gt 180) { Stop-LiveBackup '월드 저장이 3분 넘게 안 끝나서 이번 백업은 건너뛰었어요. 다음 차례에 다시 해요.' }
        return
    }
    if ($b.proc.Running) {
        if ($b.sw.Elapsed.TotalMinutes -gt 30) { Stop-LiveBackup '백업이 30분 넘게 걸려서 멈췄어요. 서버를 끌 때 자동으로 다시 백업해요.' }
        return
    }
    $script:liveBk = $null
    if ($s -and $s.dir -eq $b.dir -and $s.proc.Running) { $s.proc.Send('save-on') }
    $part = "$($b.zip).part"
    if ($b.proc.Code -eq 0 -and (Test-Path -LiteralPath $part) -and (Get-Item -LiteralPath $part).Length -gt 0) {
        Move-Item -LiteralPath $part -Destination $b.zip
        Get-ChildItem -LiteralPath (Split-Path $b.zip -Parent) -Filter 'live_*.zip' | Sort-Object Name -Descending | Select-Object -Skip $LiveBackupKeep |
            Remove-Item -Force -ErrorAction SilentlyContinue
        $txtConsole.AppendText("[관리 프로그램] 켜진 채로 월드를 백업했어요: $(Split-Path $b.zip -Leaf) (live_ 백업은 최근 $($LiveBackupKeep)개만 남겨요)`r`n")
        Copy-BackupOut $b.dir $b.zip
    }
    else {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        $txtConsole.AppendText("[관리 프로그램] 켜진 채로 하는 백업을 만들지 못했어요. 서버를 끌 때 자동으로 다시 백업해요.`r`n")
    }
}

# ---------------- a copy of every backup outside this PC's disk (OneDrive folder, USB drive) ----------------
# A dead disk or ransomware takes the world and the backups beside it together; the copy is what survives.
$BackupCopyKeep = 10
$script:copyJobs = New-Object System.Collections.Generic.List[object]
function Get-BackupCopyDir($d) {
    $i = Read-Json (Join-Path $d 'server-info.json')
    if ($i -and $i.PSObject.Properties['backupCopy'] -and "$($i.backupCopy)") { return "$($i.backupCopy)" }
    return ''
}
function Copy-BackupOut($d, [string]$zip) {
    $to = Get-BackupCopyDir $d; if (-not $to -or -not $zip -or -not (Test-Path -LiteralPath $zip)) { return }
    if (-not (Test-Path -LiteralPath $to)) {
        $txtConsole.AppendText("[관리 프로그램] 백업 복사 폴더($to)를 찾지 못했어요. USB를 꽂았는지 확인해 주세요. (이 PC 안의 백업은 그대로 있어요)`r`n"); return
    }
    $dest = Join-Path $to "모드팩서버 백업\$(Split-Path $d -Leaf)"
    $q = { param($s) $s -replace "'", "''" }
    $cmd = @"
`$ErrorActionPreference = 'Stop'
try {
    New-Item -ItemType Directory -Force '$(& $q $dest)' | Out-Null
    `$t = Join-Path '$(& $q $dest)' '$(& $q (Split-Path $zip -Leaf))'
    Copy-Item -LiteralPath '$(& $q $zip)' -Destination "`$t.part" -Force
    Move-Item -LiteralPath "`$t.part" -Destination `$t -Force
    Get-ChildItem -LiteralPath '$(& $q $dest)' -Filter '*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip $BackupCopyKeep | Remove-Item -Force
}
catch { exit 1 }
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $p = New-Object McProc('powershell.exe', "-NoProfile -NonInteractive -EncodedCommand $enc", $d, [Text.Encoding]::Default.CodePage)
    $script:copyJobs.Add([pscustomobject]@{ proc = $p; name = (Split-Path $zip -Leaf); to = $dest })
}
function Update-BackupCopies {
    # Called by the window timer
    foreach ($j in $script:copyJobs.ToArray()) {   # @() of an empty generic List throws in Windows PowerShell 5.1
        if ($j.proc.Running) { continue }
        [void]$script:copyJobs.Remove($j)
        if ($j.proc.Code -eq 0) { $txtConsole.AppendText("[관리 프로그램] 백업을 PC 밖에도 복사했어요: $($j.name) → $($j.to) (최근 $($BackupCopyKeep)개)`r`n") }
        else { $txtConsole.AppendText("[관리 프로그램] 백업을 PC 밖으로 복사하지 못했어요 ($($j.name)). 복사할 곳의 남은 공간을 확인해 주세요.`r`n") }
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
    $f.Text = "백업 / 월드 관리 - $($lstSrv.SelectedItem)"; $f.Size = New-Object Drawing.Size(760, 610); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.Font = $font
    $l1 = New-Ctl Label 15 12 720 40 "서버를 끌 때마다(auto_, 최근 $($AutoBackupKeep)개), 켜 둔 동안에는 $($LiveBackupHours)시간마다(live_, 최근 $($LiveBackupKeep)개) 자동으로 백업해요.`n[지금 백업하기] 말고는 서버를 끈 상태에서만 돼요. 되돌리기 전에 지금 월드도 한 번 더 백업해요."
    $lv = New-Object Windows.Forms.ListView; $lv.Location = New-Object Drawing.Point(15, 58); $lv.Size = New-Object Drawing.Size(715, 280); $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.Font = $font
    [void]$lv.Columns.Add('백업', 360); [void]$lv.Columns.Add('만든 때', 190); [void]$lv.Columns.Add('크기', 140)
    $bNow = New-Ctl Button 15 348 230 38 '지금 백업하기'
    $bRestore = New-Ctl Button 255 348 230 38 '선택한 백업으로 되돌리기'
    $bOpen = New-Ctl Button 495 348 235 38 '백업 폴더 열기'
    $bReset = New-Ctl Button 15 400 300 38 '월드 새로 만들기 (처음부터)'
    $bReset.ForeColor = [Drawing.Color]::Firebrick
    $lst = New-Ctl Label 330 395 400 75 ''; $lst.ForeColor = [Drawing.Color]::DarkGreen
    $lCopy = New-Ctl Label 15 482 455 64 ''
    $bCopy = New-Ctl Button 480 482 160 36 '복사할 곳 고르기'
    $bCopyOff = New-Ctl Button 650 482 80 36 '끄기'
    $f.Controls.AddRange(@($l1, $lv, $bNow, $bRestore, $bOpen, $bReset, $lst, $lCopy, $bCopy, $bCopyOff))
    $showCopy = {
        $c = Get-BackupCopyDir $d
        if ($c) { $lCopy.ForeColor = [Drawing.Color]::DarkGreen; $lCopy.Text = "PC 밖에도 복사: 켜짐 (새 백업마다, 최근 $($BackupCopyKeep)개)`n$c" }
        else { $lCopy.ForeColor = [Drawing.Color]::DarkOrange; $lCopy.Text = "PC 밖에도 복사: 꺼짐`n디스크가 고장 나면 월드와 백업이 같이 사라져요. OneDrive 폴더나 USB를 골라 두세요." }
        $bCopyOff.Enabled = [bool]$c
    }
    & $showCopy
    $bCopy.Add_Click({
            $fb = New-Object Windows.Forms.FolderBrowserDialog
            $fb.Description = '백업을 복사해 둘 곳을 고르세요. (OneDrive 폴더나 USB가 좋아요)'
            if ($env:OneDrive -and (Test-Path -LiteralPath $env:OneDrive)) { $fb.SelectedPath = $env:OneDrive }
            if ($fb.ShowDialog($f) -ne 'OK') { return }
            $to = $fb.SelectedPath
            $full = [IO.Path]::GetFullPath($to).TrimEnd('\') + '\'
            if ($full.StartsWith(([IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { Show-Msg '이 프로그램 폴더 안은 고를 수 없어요. 다른 디스크, USB, OneDrive 폴더를 골라 주세요.'; return }
            $cloud = $env:OneDrive -and $full.StartsWith(([IO.Path]::GetFullPath($env:OneDrive).TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)
            if (-not $cloud -and [IO.Path]::GetPathRoot($full) -ieq [IO.Path]::GetPathRoot($d)) {
                if (-not (Ask-YesNo "이 폴더는 서버와 같은 디스크($([IO.Path]::GetPathRoot($full)))에 있어요. 디스크가 고장 나면 같이 사라져요.`n가능하면 다른 디스크, USB, OneDrive 폴더를 골라 주세요.`n`n그래도 여기로 할까요?")) { return }
            }
            Set-InfoField $d 'backupCopy' $to; & $showCopy
            $last = $script:bkFiles | Select-Object -First 1
            if ($last) { Copy-BackupOut $d $last.FullName; $lst.Text = "가장 최근 백업($($last.Name))을 지금 복사하고 있어요.`n끝나면 콘솔에 나와요." }
        })
    $bCopyOff.Add_Click({ Set-InfoField $d 'backupCopy' ''; & $showCopy })
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
            if ($script:srv -and $script:srv.dir -eq $d -and $script:srv.done -and -not $script:srv.stopping) {
                if ($script:liveBk) { $lst.Text = '이미 백업하고 있어요. 끝나면 아래 목록과 콘솔에 나와요.'; return }
                if (Start-LiveBackup) { $lst.Text = "서버를 켠 채로 백업을 시작했어요.`n끝나면 콘솔에 나오고, 이 창을 다시 열면 목록에 보여요." }
                else { $lst.Text = '지금은 백업을 시작할 수 없어요. 콘솔 안내를 확인해 주세요.' }
                return
            }
            if (-not (Assert-ServerOff $d)) { return }
            $lst.Text = '백업하는 중... (월드가 크면 몇 분 걸려요)'; $f.Cursor = 'WaitCursor'
            $z = New-WorldBackup $d 'backup'
            $f.Cursor = 'Default'
            if ($z) { $lst.Text = "백업했어요: $(Split-Path $z -Leaf)"; Copy-BackupOut $d $z } else { $lst.Text = '백업할 월드가 없어요. (서버를 한 번도 안 켰다면 월드가 아직 없어요)' }
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
function Get-PackProps($packId) {
    # Same rule as install.ps1 for a new server: packs.json defaultProps, then a built-in pack's own props
    $doc = Get-Content (Join-Path $Prog 'packs.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $keys = @('allow-flight', 'spawn-protection', 'max-tick-time', 'difficulty', 'view-distance', 'simulation-distance', 'spawn-monsters', 'pvp', 'max-players')
    $out = [ordered]@{}
    $srcs = @($doc.defaultProps) + @($doc.packs | ForEach-Object { $_ } | Where-Object { $_.id -eq $packId } | ForEach-Object { $_.props })
    foreach ($src in $srcs) {
        if (-not $src) { continue }
        foreach ($pp in $src.PSObject.Properties) { if ($pp.Name -in $keys -and "$($pp.Value)" -match '^[A-Za-z0-9._-]{1,16}$') { $out[$pp.Name] = "$($pp.Value)" } }
    }
    return $out
}
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
    function Row($label) { $l = New-Ctl Label 15 ($script:rowY + 3) 255 24 $label; $f.Controls.Add($l) }
    $script:rowY = $y
    function Add-Combo($key, $label, $opts, $def) {
        Row $label
        $c = New-Ctl ComboBox 275 $script:rowY 305 28; $c.DropDownStyle = 'DropDownList'
        foreach ($o in $opts) { [void]$c.Items.Add($o[1]) }
        $cur = $pr[$key]; if (-not $cur) { $cur = $def }
        $idx = 0; for ($i = 0; $i -lt $opts.Count; $i++) { if ($opts[$i][0] -eq $cur) { $idx = $i } }
        $c.SelectedIndex = $idx; $f.Controls.Add($c); $ctl[$key] = @{ kind = 'combo'; c = $c; opts = $opts }; $script:rowY += 36
    }
    function Add-Num($key, $label, $min, $max, $def) {
        Row $label
        $n = New-Ctl NumericUpDown 275 $script:rowY 90 28; $n.Minimum = $min; $n.Maximum = $max
        $v = $def; if ($pr[$key] -match '^\d+$') { $v = [int]$pr[$key] }; $n.Value = [Math]::Min($max, [Math]::Max($min, $v))
        $f.Controls.Add($n); $ctl[$key] = @{ kind = 'num'; c = $n }; $script:rowY += 36
    }
    function Add-Check($key, $label, $def) {
        $c = New-Ctl CheckBox 15 $script:rowY 565 26 $label
        $v = $pr[$key]; if (-not $v) { $v = $def }; $c.Checked = $v -eq 'true'
        $f.Controls.Add($c); $ctl[$key] = @{ kind = 'check'; c = $c }; $script:rowY += 32
    }
    Row '서버 설명 (목록에 보이는 글)'
    $motd = New-Ctl TextBox 275 $script:rowY 305 28; $motd.Text = Get-UserMotd ([string]$pr['motd']); $f.Controls.Add($motd); $script:rowY += 36
    Add-Combo 'difficulty' '난이도' @(@('peaceful', '평화로움 (몬스터 없음)'), @('easy', '쉬움'), @('normal', '보통'), @('hard', '어려움')) 'normal'
    Add-Combo 'gamemode' '처음 들어온 사람의 게임 모드' @(@('survival', '서바이벌'), @('creative', '크리에이티브'), @('adventure', '모험'), @('spectator', '관전')) 'survival'
    Add-Num 'max-players' '최대 인원' 1 100 20
    Add-Num 'view-distance' '시야 거리 (낮추면 렉이 줄어요)' 3 32 10
    Add-Num 'simulation-distance' '움직이는 거리 (낮추면 렉이 줄어요)' 3 32 10
    Add-Num 'spawn-protection' '스폰 보호 범위 (블록)' 0 64 16
    Add-Check 'pvp' '플레이어끼리 공격 가능 (PvP)' 'true'
    Add-Check 'hardcore' '하드코어 (죽으면 관전 모드)' 'false'
    Add-Check 'allow-flight' '비행 허용 (모드팩은 켜 두는 게 좋아요. 끄면 날개나 탈것을 쓸 때 쫓겨날 수 있어요)' 'true'
    Add-Check 'allow-nether' '지옥(네더) 허용' 'true'
    Add-Check 'spawn-monsters' '몬스터 나오기' 'true'
    Add-Check 'enable-command-block' '명령 블록 허용' 'false'
    # The values a new server of this pack starts with (packs.json): for servers made before, or after trying other values
    $bPack = New-Ctl Button 15 ($script:rowY + 6) 565 34 '이 모드팩에 맞는 추천값 넣기 (비행 허용, 스폰 보호 최대, 시야 8 등)'
    $bPack.Enabled = -not $running
    $script:rowY += 42
    # Many players on a home PC: fewer chunks per player matters more than anything else
    $bMany = New-Ctl Button 15 ($script:rowY + 6) 565 34 '여럿이 할 때 추천값 넣기 (20명 기준: 최대 25명, 시야 8, 움직이는 거리 6)'
    $bMany.Enabled = -not $running
    $script:rowY += 44
    $script:packExtra = @{}
    $bPack.Add_Click({
            $i = Read-Json (Join-Path $d 'server-info.json')
            $want = Get-PackProps $i.pack
            $script:packExtra = @{}
            foreach ($k in $want.Keys) {
                $e = $ctl[$k]
                if (-not $e) { $script:packExtra[$k] = $want[$k]; continue }   # not shown in this window (max-tick-time)
                switch ($e.kind) {
                    'combo' { for ($j = 0; $j -lt $e.opts.Count; $j++) { if ($e.opts[$j][0] -eq $want[$k]) { $e.c.SelectedIndex = $j } } }
                    'num' { if ($want[$k] -match '^\d+$') { $e.c.Value = [Math]::Min($e.c.Maximum, [Math]::Max($e.c.Minimum, [int]$want[$k])) } }
                    'check' { $e.c.Checked = $want[$k] -eq 'true' }
                }
            }
            Show-Msg ("이 모드팩에 맞는 추천값을 넣었어요. [저장]을 눌러야 적용돼요.`n`n" +
                " - 비행 허용: 제트팩이나 날아다니는 탈것을 써도 쫓겨나지 않아요`n" +
                " - 스폰 보호 최대(64블록): 스폰 근처는 방장(관리자)만 고칠 수 있어서 장난이나 실수로 망가지지 않아요`n" +
                " - 시야 거리와 움직이는 거리: 모드가 많아도 버틸 만큼으로 맞췄어요`n" +
                " - 난이도: 모드팩에 맞게 (보통, 좀비 모드팩은 어려움)`n" +
                " - 첫 월드를 만들 때 서버가 오래 걸려도 멈춘 걸로 보고 꺼 버리지 않게 했어요")
        })
    $bs = New-Ctl Button 15 ($script:rowY + 10) 270 40 '저장'; $bs.Font = $bold
    $bc = New-Ctl Button 300 ($script:rowY + 10) 140 40 '닫기'
    $bs.Enabled = -not $running
    $f.Controls.AddRange(@($bPack, $bMany, $bs, $bc))
    $bMany.Add_Click({
            $ctl['max-players'].c.Value = [Math]::Max(25, [int]$ctl['max-players'].c.Value)
            $ctl['view-distance'].c.Value = [Math]::Min(8, [int]$ctl['view-distance'].c.Value)
            $ctl['simulation-distance'].c.Value = [Math]::Min(6, [int]$ctl['simulation-distance'].c.Value)
            $i = Read-Json (Join-Path $d 'server-info.json')
            $p = $packs | Where-Object { $i -and $_.id -eq $i.pack } | Select-Object -First 1
            $base = 6; if ($p -and $p.ramGB) { $base = [int]$p.ramGB }
            $want = $base + 4; $now = Get-ServerRam $d
            $ram = "서버 램: 지금 $($now)GB. 20명이면 $($want)GB 정도를 권해요 (모드팩 권장 $($base)GB + 인원 몫 4GB)."
            if ($want -gt $totalRam - 4) { $ram += "`n이 컴퓨터 램은 $($totalRam)GB라서 빠듯해요. 이 PC에서 게임까지 하면 렉이 생기기 쉬워요. 서버만 돌리는 PC를 따로 두거나, 가벼운 모드팩(Cobblemon, Better MC)을 고르는 게 좋아요." }
            Show-Msg "추천값을 넣었어요. [저장]을 눌러야 적용돼요.`n`n$ram`n(서버 램은 메인 화면 오른쪽 위 [서버 램]에서 바꿔요)"
        })
    $f.ClientSize = New-Object Drawing.Size(600, ($script:rowY + 65))
    $bc.Add_Click({ $f.Close() })
    $bs.Add_Click({
            if (-not (Assert-ServerOff $d)) { return }
            $ch = @{ 'motd' = ($motd.Text -replace '[\r\n]', ' ') }
            foreach ($k in $script:packExtra.Keys) { $ch[$k] = $script:packExtra[$k] }
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
    # The tunnel may have been made (or remade) since: ask Playit before the guide and its join code are written
    if (Get-PlayitKey) { [void](Sync-PlayitAddress) }
    Update-FriendGuide $d
    $g = Join-Path $d '친구접속안내.txt'
    $text = ''; if (Test-Path -LiteralPath $g) { $text = [IO.File]::ReadAllText($g, $Cp949) }
    $f = New-Object Windows.Forms.Form
    $f.Text = "친구 접속 안내 - $($lstSrv.SelectedItem)"; $f.Size = New-Object Drawing.Size(760, 590); $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.Font = $font
    $l = New-Ctl Label 15 10 720 24 '아래 글을 복사해서 카톡이나 디스코드로 친구에게 보내 주세요.'
    $tb = New-Ctl TextBox 15 38 715 400; $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'; $tb.Text = ($text -replace "`r?`n", "`r`n"); $tb.BackColor = [Drawing.Color]::White
    $bi = New-Ctl Button 15 448 230 40 '초대 링크만 복사 (짧게)'; $bi.Font = $bold
    $bc = New-Ctl Button 255 448 210 40 '글 전체 복사'
    $done = New-Ctl Label 15 494 715 44 ''; $done.ForeColor = [Drawing.Color]::DarkGreen
    $bi.Add_Click({ $f.Cursor = 'WaitCursor'; try { $done.Text = Copy-Invite $d } finally { $f.Cursor = 'Default' } })
    $bc.Add_Click({ [Windows.Forms.Clipboard]::SetText($tb.Text); $done.Text = '복사했어요!' })
    $f.Controls.AddRange(@($l, $tb, $bi, $bc, $done))
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
$script:igpu = $null
function Test-IntegratedGpu {
    # Integrated graphics borrow system RAM, so the game has less to work with
    if ($null -eq $script:igpu) {
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
        $script:igpu = -not (@($gpus | Where-Object { $_ -match 'GeForce|RTX|GTX|Quadro|Radeon RX|Radeon Pro|Arc A|Arc B' }).Count)
    }
    return $script:igpu
}
function Get-GameRam([int]$serverRam = 0) {
    # What is left after Windows (about 3GB), integrated graphics (about 1GB) and a server on the same PC, between 4 and 8GB
    $gpu = 0; if (Test-IntegratedGpu) { $gpu = 1 }
    return [int][Math]::Max(4, [Math]::Min(8, $totalRam - $serverRam - 3 - $gpu))
}
function Get-KnownNick {
    # The game writes "Setting user: <name>" at every start; the newest such log on this PC names the player
    $logs = @(Get-ChildItem -LiteralPath $GameRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'logs\latest.log' }) + (Join-Path (Get-McDirPath) 'logs\latest.log')
    $best = ''; $when = [datetime]::MinValue
    foreach ($l in $logs) {
        if (-not (Test-Path -LiteralPath $l)) { continue }
        $t = (Get-Item -LiteralPath $l).LastWriteTime; if ($t -le $when) { continue }
        try { $m = Select-String -LiteralPath $l -Pattern 'Setting user: ([A-Za-z0-9_]{3,16})\b' -List -ErrorAction Stop } catch { continue }
        if ($m) { $best = $m.Matches[0].Groups[1].Value; $when = $t }
    }
    return $best
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
        $known = Get-KnownNick
        $hint = ''; if ($known) { $hint = "`n`n(이 PC에서 마인크래프트를 켰던 기록에서 찾은 이름을 넣어 뒀어요. 맞으면 [확인])" }
        $nick = ("" + (Ask-Text "내 마인크래프트 닉네임(자바 에디션 계정 이름)을 입력하세요.`n내 서버에 들어가려면 화이트리스트에 내 이름이 있어야 해요.$hint" $known)).Trim()
        if ($nick -match '^[A-Za-z0-9_]{3,16}$') { [void](Add-Whitelist $d $nick); Set-InfoField $d 'host' $nick }
        elseif ($nick) { Show-Msg '마인크래프트 닉네임은 영어, 숫자, _ 로 3~16글자예요. 나중에 [친구 추가]로 넣어 주세요.' }
    }
    if (-not (Close-McLauncher)) { return }
    $sr = 0; if ($totalRam -lt 24) { $sr = Get-ServerRam $d }
    # Server and game share this PC's memory; a modpack game wants about 6GB, Windows about 3GB
    # A server many friends play on runs out of memory at 4GB: then the game has to make do, not the server
    $online = 0; if ($script:srv -and $script:srv.dir -eq $d) { $online = $script:srv.players.Count }
    $crowd = $online -ge 3 -or @($wl | Where-Object { $_ }).Count -ge 6
    if ($sr -and ($totalRam - $sr - 3) -lt 6 -and $sr -gt 4 -and $crowd) {
        if (-not (Ask-YesNo "이 컴퓨터의 램은 약 $($totalRam)GB예요. 서버($($sr)GB)와 게임을 같이 켜면 램이 빠듯해서 게임이 느리거나 멈출 수 있어요.`n`n친구가 많은 서버라 서버 램은 줄이지 않을게요. (줄이면 여럿이 놀다가 서버가 꺼질 수 있어요)`n그래도 이 PC에서 게임을 켤까요?")) { return }
    }
    elseif ($sr -and ($totalRam - $sr - 3) -lt 6 -and $sr -gt 4) {
        if (Ask-YesNo "이 컴퓨터의 램은 약 $($totalRam)GB예요. 서버($($sr)GB)와 게임을 같이 켜면 램이 모자라서 게임이 멈출 수 있어요.`n`n서버 램을 4GB로 줄이고 게임에 더 줄까요? (혼자나 2~3명이 할 때 권장, 서버를 다음에 켤 때부터 적용돼요)") {
            Set-ServerRam $d 4; $sr = 4; Show-SrvInfo
            if ($script:srv) { Show-Msg "서버 램을 4GB로 바꿨어요. 지금 켜진 서버에는 [■ 서버 끄기] → 다시 켜기를 해야 적용돼요." }
        }
    }
    $script:gameJob = @{ gameDir = $gd }
    Start-InstallJob "-Client -PackId $($i.pack) -VersionKey `"$($i.version)`" -Name `"$name`" -FromServer `"$d`" -GameDir `"$gd`" -Address 127.0.0.1 -GameRamGB $(Get-GameRam $sr)" 'game'
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
    $gd = $script:gameJob.gameDir
    if ($kind -eq 'join') {
        $links = @(Read-JsonList (Join-Path $gd 'mod-links.json') | Where-Object { (Test-ModUrl $_.u) })
        # Links as they were before this install, when there was one: what the host added or removed since
        $prevF = Join-Path $gd 'mod-links.prev.json'; $ch = $null
        if (Test-Path -LiteralPath $prevF) { $ch = Get-JoinChanges @() @(Read-JsonList $prevF) ([pscustomobject]@{ m = @(); l = $links }) }
        $have = @(Get-ChildItem -LiteralPath (Join-Path $gd $ManualModsDir) -Filter '*.jar' -File -ErrorAction SilentlyContinue).Count
        if (($links.Count -and $have -lt $links.Count) -or ($ch -and $ch.any)) {
            $mm = Read-Json (Join-Path $gd 'mcsm-game.json')
            [void](Show-JoinGuide ([pscustomobject]@{ n = $mm.name; k = $mm.version; l = $links; m = @() }) $null '' $gd $ch)
        }
        Remove-Item -LiteralPath $prevF -Force -ErrorAction SilentlyContinue
        $n = Sync-ManualMods $gd; if ($n) { $txtJoinLog.AppendText("직접 받은 모드 $($n)개를 넣었어요.`r`n") }
    }
    # The game runs these mods on this PC too: same check as the server's before the launcher opens
    if (-not (Confirm-ModsSafe $gd (Join-Path $gd 'mods') (Join-Path $gd 'mod-scan.json'))) {
        if ($kind -eq 'join') { $lblJoinWork.ForeColor = [Drawing.Color]::Firebrick; $lblJoinWork.Text = '위험한 모드 파일이 있어서 게임을 켜지 않았어요.' }
        else { $lblStage.Text = '위험한 모드 파일이 있어서 게임을 켜지 않았어요.' }
        return
    }
    $m = Read-Json (Join-Path $gd 'mcsm-game.json')
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
function ConvertTo-B64UrlBytes([byte[]]$b) { return [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function ConvertFrom-B64UrlBytes([string]$s) {
    $s = $s.Replace('-', '+').Replace('_', '/'); while ($s.Length % 4) { $s += '=' }
    return , [Convert]::FromBase64String($s)
}
function ConvertFrom-B64Url([string]$s) { return [Text.Encoding]::UTF8.GetString((ConvertFrom-B64UrlBytes $s)) }

# Invite codes (MCSM2) are compressed, then encrypted, so a pasted link stays short and tells someone reading the chat nothing:
# not the address, not the modpack. The key ships with the program and the invite page, so this hides the code from onlookers;
# it is not a password. The whitelist and online-mode are what keep strangers out.
# The invite page (join.html) does the same steps in JavaScript: AES-256-CBC, key = SHA-256 of the text below, raw deflate.
$InviteKey = [Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes('mcsm-invite-v2'))
function Protect-InviteText([string]$s) {
    $ms = New-Object IO.MemoryStream
    $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Compress)
    $b = [Text.Encoding]::UTF8.GetBytes($s); $ds.Write($b, 0, $b.Length); $ds.Close()
    $packed = $ms.ToArray()
    $aes = [Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = $InviteKey; $aes.GenerateIV(); $iv = $aes.IV
        $ct = $aes.CreateEncryptor().TransformFinalBlock($packed, 0, $packed.Length)
    }
    finally { $aes.Dispose() }
    return ConvertTo-B64UrlBytes ([byte[]]($iv + $ct))
}
function Unprotect-InviteText([string]$s) {
    $raw = ConvertFrom-B64UrlBytes $s
    if ($raw.Length -lt 32 -or $raw.Length % 16) { throw '초대 코드가 잘렸어요.' }
    $aes = [Security.Cryptography.Aes]::Create()
    try { $aes.Key = $InviteKey; $aes.IV = [byte[]]$raw[0..15]; $packed = $aes.CreateDecryptor().TransformFinalBlock($raw, 16, $raw.Length - 16) }
    finally { $aes.Dispose() }
    $ds = New-Object IO.Compression.DeflateStream((New-Object IO.MemoryStream(, $packed)), [IO.Compression.CompressionMode]::Decompress)
    $out = New-Object IO.MemoryStream; $buf = New-Object byte[] 4096
    try {
        # A real code unpacks to a few hundred bytes; a doctored one must not fill the memory
        while (($n = $ds.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n); if ($out.Length -gt 65536) { throw '초대 코드가 이상해요.' } }
    }
    finally { $ds.Dispose() }
    return [Text.Encoding]::UTF8.GetString($out.ToArray())
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
    # Jars added from disk that turned out to be Modrinth files travel under their Modrinth file name
    $mods = @(Get-AddedMods $d | Where-Object { $_.forClient -and $_.projectId } | ForEach-Object {
            $fn = $_.file; if ($_.PSObject.Properties['mrFile'] -and $_.mrFile) { $fn = $_.mrFile }
            [ordered]@{ p = $_.projectId; f = $fn }
        })
    # Jars that are not on Modrinth are never sent along (that would be redistributing someone's mod): friends get the
    # official page the host gave for each, and download it there themselves
    $links = @(Get-AddedMods $d | Where-Object { $_.forClient -and -not $_.projectId -and $_.PSObject.Properties['sourceUrl'] -and (Test-ModUrl $_.sourceUrl) } |
        ForEach-Object { [ordered]@{ t = ([string]$_.title).Substring(0, [Math]::Min(80, ([string]$_.title).Length)); u = [string]$_.sourceUrl } })
    $o = [ordered]@{ v = 1; p = $i.pack; k = (Get-VersionKey $d $i); n = (Split-Path $d -Leaf); a = (Get-PlayitAddress); m = $mods; l = $links }
    # A pack the host added by hand is unknown to the friend's copy: the code carries it (CurseForge: just this version)
    $cp = Get-CustomPacks | Where-Object { $_.id -eq $i.pack } | Select-Object -First 1
    if ($cp) {
        $rec = ConvertTo-PackRecord $cp
        if ($rec.Contains('versions')) { $rec['versions'] = @($rec['versions'] | Where-Object { $_.label -eq $i.version }) }
        $rec.Remove('desc'); $rec.Remove('refreshed')
        $o['d'] = $rec
    }
    $code = 'MCSM2-' + (Protect-InviteText ($o | ConvertTo-Json -Compress -Depth 4))
    $script:myCodes[$code] = $true   # so this PC doesn't take its own invitation on the clipboard for a friend's
    return $code
}
$script:myCodes = @{}
function Read-JoinCode([string]$text) {
    # MCSM2: compressed and encrypted (current). MCSM1: plain base64 from versions up to 1.0.10, still accepted.
    $m = [regex]::Match($text, 'MCSM([12])-([A-Za-z0-9_-]{8,})'); if (-not $m.Success) { return $null }
    try {
        if ($m.Groups[1].Value -eq '2') { $json = Unprotect-InviteText $m.Groups[2].Value } else { $json = ConvertFrom-B64Url $m.Groups[2].Value }
        $c = $json | ConvertFrom-Json
    }
    catch { return $null }
    if (-not $c.p -or -not $c.k -or "$($c.n)" -notmatch '^[A-Za-z0-9]([A-Za-z0-9 ._-]{0,58}[A-Za-z0-9_-])?$') { return $null }
    # Links to mods' own pages: only plain https addresses, shown with their site so nobody is sent somewhere unexpected
    $okLinks = @(@($c.l) | Where-Object { $_ -and (Test-ModUrl $_.u) -and "$($_.t)".Length -le 80 } | ForEach-Object { [pscustomobject]@{ t = "$($_.t)"; u = "$($_.u)" } })
    $c | Add-Member -NotePropertyName l -NotePropertyValue $okLinks -Force
    return $c
}
function Test-ModUrl($u) { return "$u".Length -le 300 -and "$u" -match '^https://[A-Za-z0-9.-]+\.[A-Za-z]{2,}(:\d{1,5})?(/[^\s"<>`]*)?$' }
function Get-UrlSite([string]$u) { try { return ([uri]$u).Host } catch { return '' } }

# ---------------- invite link: one short line to paste, the page explains the rest ----------------
# The page is a static file in the release repo served by GitHub Pages. The code sits after '#', which browsers never send
# to any server, so not even GitHub sees what is in it.
$InvitePage = 'https://epaldks10-ship-it.github.io/mc-modpack-server-manager-release/join.html'
$script:invitePageOk = $null; $script:invitePageAt = [datetime]::MinValue
function Test-InvitePage {
    # Only a page that is really there gets handed out; until then friends get the full guide text instead
    if ($script:invitePageOk) { return $true }
    if ($null -ne $script:invitePageOk -and ((Get-Date) - $script:invitePageAt).TotalMinutes -lt 10) { return $false }
    $script:invitePageAt = Get-Date
    try { $b = Get-WebBytes $InvitePage 4000; $script:invitePageOk = [Text.Encoding]::UTF8.GetString($b) -match 'mcsm-invite' } catch { $script:invitePageOk = $false }
    return $script:invitePageOk
}
function Copy-Invite($d) {
    # Copies the invitation for server $d and returns a line saying what was copied
    if (-not $d) { return '왼쪽 목록에서 서버를 고르세요.' }
    if (Get-PlayitKey) { [void](Sync-PlayitAddress) }
    Update-FriendGuide $d
    $code = Get-JoinCode $d
    $left = @(Get-AddedMods $d | Where-Object { $_.forClient -and -not $_.projectId -and -not ($_.PSObject.Properties['sourceUrl'] -and (Test-ModUrl $_.sourceUrl)) })
    $note = ''
    if ($code -and (Test-InvitePage)) {
        # Nothing about the server is spelled out: the name and modpack only show once the link is opened
        $text = "[마인크래프트 서버 초대]`r`nPC에서 아래 링크를 열고 안내대로 하면 모드팩과 추가 모드까지 자동으로 깔려요.`r`n$InvitePage#$code"
        $note = '초대 링크를 복사했어요. 카톡이나 디스코드에 붙여 넣어 보내 주세요.'
        if (-not (Get-PlayitAddress)) { $note += ' (Playit 주소가 아직 없어서 친구가 주소를 따로 물어봐야 해요)' }
    }
    else {
        $g = Join-Path $d '친구접속안내.txt'
        $text = ''; if (Test-Path -LiteralPath $g) { $text = [IO.File]::ReadAllText($g, $Cp949) -replace "`r?`n", "`r`n" }
        if (-not $text) { return '이 서버의 접속 안내를 만들지 못했어요. [친구 접속 안내]를 열어 확인해 주세요.' }
        $note = '초대 페이지에 연결이 안 돼서 대신 안내 글 전체를 복사했어요. 그대로 붙여 넣어 보내 주세요.'
    }
    if ($left.Count) {
        # Their files must not be sent along; without a source page friends can't get them at all
        $note += " 받는 곳(원본 주소)이 없는 모드 $($left.Count)개가 있어요: [모드 추가 / 관리] → [선택한 모드의 원본 주소 넣기]로 넣어 주세요."
    }
    try { [Windows.Forms.Clipboard]::SetText($text) } catch { return '클립보드에 복사하지 못했어요. 잠시 뒤 다시 눌러 주세요.' }
    return $note
}
$script:clipSeen = ''
function Find-ClipboardCode {
    # A friend copies the invite link (or the page's code) and opens the program: pick it up so there is nothing to paste
    if ($script:installProc) { return }
    try { if (-not [Windows.Forms.Clipboard]::ContainsText()) { return }; $t = [Windows.Forms.Clipboard]::GetText() } catch { return }
    if ($t.Length -gt 20000) { return }
    $m = [regex]::Match($t, 'MCSM[12]-[A-Za-z0-9_-]{8,}')
    if (-not $m.Success -or $m.Value -eq $script:clipSeen) { return }
    $script:clipSeen = $m.Value
    if ($script:myCodes.ContainsKey($m.Value) -or $txtCode.Text.Contains($m.Value)) { return }
    $c = Read-JoinCode $m.Value; if (-not $c) { return }
    # The host's own invitation, copied in an earlier session: one of this PC's servers at this PC's address
    if ((Test-Path -LiteralPath (Join-Path $ServersDir $c.n)) -and (-not $c.a -or $c.a -eq (Get-PlayitAddress))) { return }
    $tabs.SelectedTab = $tabJoin
    $txtCode.Text = $m.Value
    if ($script:joinCode) {
        $lblJoinWork.ForeColor = [Drawing.Color]::DarkGreen
        $lblJoinWork.Text = "복사해 둔 초대 코드를 찾아서 넣었어요.`n[▶ 설치하고 게임 켜기]를 누르세요."
    }
}

# =====================================================================================
# Tab: join a friend's server
# =====================================================================================
$lblJ1 = New-Ctl Label 10 10 940 44 "방장이 보내 준 초대 링크의 [초대 코드 복사]를 누르고 이 프로그램을 켜면 코드가 저절로 들어가요. (안내 글은 통째로 붙여 넣어도 돼요)`nModrinth 모드팩은 알아서 설치하고, CurseForge 모드팩은 CurseForge 앱으로 설치하는 순서를 알려 줘요."
$txtCode = New-Ctl TextBox 10 58 940 84; $txtCode.Multiline = $true; $txtCode.ScrollBars = 'Vertical'
$lblJInfo = New-Ctl Label 10 148 940 60 '(아직 붙여 넣지 않았어요)'; $lblJInfo.ForeColor = [Drawing.Color]::DimGray
$lblJAddr = New-Ctl Label 10 216 100 24 '서버 주소'
$txtJAddr = New-Ctl TextBox 110 213 360 28
$lblJRam = New-Ctl Label 500 216 110 24 '게임 램(GB)'
$numJRam = New-Ctl NumericUpDown 610 213 60 28; $numJRam.Minimum = 2; $numJRam.Maximum = [Math]::Max(2, $totalRam - 2); $numJRam.Value = [Math]::Min($numJRam.Maximum, (Get-GameRam 0))
$btnJoin = New-Ctl Button 10 252 300 48 '▶ 설치하고 게임 켜기'; $btnJoin.Font = $bold; $btnJoin.BackColor = [Drawing.Color]::FromArgb(214, 240, 214)
$lblJoinWork = New-Ctl Label 320 252 630 48 ''; $lblJoinWork.ForeColor = [Drawing.Color]::DarkGreen
$lblJList = New-Ctl Label 10 312 400 22 '설치해 둔 친구 서버 (다음부터는 여기서 바로 켜요)'
$lstJoined = New-Ctl ListBox 10 336 400 196; $lstJoined.HorizontalScrollbar = $true
$btnJoinAgain = New-Ctl Button 10 538 195 38 '▶ 게임 켜기'; $btnJoinAgain.Font = $bold
$btnJoinDel = New-Ctl Button 215 538 195 38 '지우기'
$txtJoinLog = New-Ctl TextBox 420 312 530 304; $txtJoinLog.Multiline = $true; $txtJoinLog.ReadOnly = $true; $txtJoinLog.ScrollBars = 'Vertical'; $txtJoinLog.Font = $mono; $txtJoinLog.BackColor = [Drawing.Color]::White
$tabJoin.Controls.AddRange(@($lblJ1, $txtCode, $lblJInfo, $lblJAddr, $txtJAddr, $lblJRam, $numJRam, $btnJoin, $lblJoinWork, $lblJList, $lstJoined, $btnJoinAgain, $btnJoinDel, $txtJoinLog))

$script:joinCode = $null
$txtCode.Add_TextChanged({
        $c = Read-JoinCode $txtCode.Text
        $script:joinCode = $c
        if (-not $c) {
            $lblJInfo.ForeColor = [Drawing.Color]::Firebrick
            $lblJInfo.Text = '초대 코드(MCSM으로 시작)를 찾지 못했어요. 방장에게 [친구 초대 링크 복사]로 링크를 다시 받아 주세요.'
            if (-not $txtCode.Text.Trim()) { $lblJInfo.ForeColor = [Drawing.Color]::DimGray; $lblJInfo.Text = '(아직 붙여 넣지 않았어요)' }
            return
        }
        $p = $packs | Where-Object { $_.id -eq $c.p } | Select-Object -First 1
        $ver = $c.k; if ($p -and $p.source -eq 'curseforge' -and -not ($p.versions | Where-Object label -eq $c.k)) { $p = $null }
        $extra = ''
        if (-not $p -and (Test-PackDef $c)) { $p = $c.d; $extra = '   (방장이 직접 추가한 모드팩이라, 설치할 때 이 PC 목록에도 넣어요)' }
        if (-not $p) { $lblJInfo.ForeColor = [Drawing.Color]::Firebrick; $lblJInfo.Text = '이 프로그램이 모르는 모드팩이나 버전이에요. 프로그램을 껐다가 다시 켜서 최신 버전으로 업데이트한 다음 다시 붙여 넣어 주세요.'; $script:joinCode = $null; return }
        $lblJInfo.ForeColor = [Drawing.Color]::DarkGreen
        $nl = @($c.l).Count; $lk = ''; if ($nl) { $lk = " (+ 원본 링크로 받는 모드 $($nl)개)" }
        $how = '아래 [▶ 설치하고 게임 켜기]를 누르세요.'; if ($p.source -eq 'curseforge') { $how = '아래 [▶ 설치하고 게임 켜기]를 누르면 CurseForge 앱으로 설치하는 순서를 알려 줘요.' }
        $lblJInfo.Text = "서버: $($c.n)   |   모드팩: $($p.name)   |   방장이 추가한 모드: $(@($c.m).Count)개$lk$extra`n$how"
        if ($c.a) { $txtJAddr.Text = $c.a; $lblJoinWork.Text = '' }
        else { $txtJAddr.Text = ''; $lblJoinWork.ForeColor = [Drawing.Color]::DarkOrange; $lblJoinWork.Text = "방장이 아직 Playit을 연결하지 않아서 주소가 비어 있어요.`n방장에게 [Playit 연결 설정]을 해 달라고 하거나, 주소를 물어봐서 위 칸에 넣어 주세요." }
    })
function Test-PackDef($c) {
    # A pack definition carried in a join code: only Modrinth slugs and CurseForge's own file server are accepted
    $d = $c.d
    if (-not $d -or $d.id -ne $c.p -or "$($d.name)" -eq '') { return $false }
    if ($d.source -eq 'modrinth') { return ($d.id -eq "mr-$($d.slug)") -and ("$($d.slug)" -match '^[A-Za-z0-9_-]{2,64}$') }
    if ($d.source -eq 'curseforge') {
        $v = @($d.versions | Where-Object { $_.label -eq $c.k })
        return ($v.Count -eq 1) -and (Test-ServerPackUrl $v[0].url) -and ([long]$v[0].size -gt 0) -and ("$($d.loader)" -in 'forge', 'neoforge', 'fabric')
    }
    return $false
}
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
    if ($addr -match '^\s*(127.0.0.1|127\.0\.0\.1)\s*$') { $addr = '127.0.0.1' } else { $addr = ConvertTo-PlayitAddress $addr }
    if (-not $addr) { Show-Msg "서버 주소를 넣어 주세요.`n방장에게 '어쩌구.joinmc.link' 같은 주소를 물어봐서 [서버 주소] 칸에 넣으면 돼요."; return }
    # CurseForge modpacks are installed with CurseForge's own app: this program does not fetch their files for a friend
    $jp = $packs | Where-Object { $_.id -eq $c.p } | Select-Object -First 1
    if (-not $jp -and (Test-PackDef $c)) { $jp = $c.d }
    if ($jp -and $jp.source -eq 'curseforge') { [void](Show-JoinGuide $c $jp $addr ''); return }
    if (-not (Test-McLauncher)) { return }
    if (-not ($packs | Where-Object { $_.id -eq $c.p }) -or (($packs | Where-Object { $_.id -eq $c.p }).source -eq 'curseforge' -and -not (($packs | Where-Object { $_.id -eq $c.p }).versions | Where-Object label -eq $c.k))) {
        if (Test-PackDef $c) { Add-CustomPack $c.d -NoSelect }
    }
    $gd = Join-Path $GameRoot "join-$($c.n)"
    if (-not (Stop-GameIfRunning $gd)) { return }
    if (-not (Close-McLauncher)) { return }
    $mods = $modsB64; if ($null -eq $mods) { $mods = ConvertTo-ModsB64 $c.m }
    # Mods only reachable by link: kept beside the game, so [▶ 게임 켜기] next time still knows them
    New-Item -ItemType Directory -Force (Join-Path $gd $ManualModsDir) | Out-Null
    if ($c.PSObject.Properties['l']) {
        $lf = Join-Path $gd 'mod-links.json'
        if (Test-Path -LiteralPath $lf) { Copy-Item -LiteralPath $lf -Destination (Join-Path $gd 'mod-links.prev.json') -Force }
        [IO.File]::WriteAllText($lf, (ConvertTo-Json -InputObject @($c.l) -Depth 3), $Utf8)
    }
    $script:gameJob = @{ gameDir = $gd }
    $tabs.SelectedTab = $tabJoin
    Start-InstallJob "-Client -PackId $($c.p) -VersionKey `"$($c.k)`" -Name `"$($c.n)`" -GameDir `"$gd`" -Address `"$addr`" -AddedMods `"$mods`" -GameRamGB $ram" 'join'
}
# ---------------- what a friend downloads and puts in by hand (never files passed on by the host) ----------------
$ManualModsDir = '직접_받은_모드'
function Save-ModrinthMods($list, [string]$dir, $log) {
    # Mods the host added from Modrinth, fetched from Modrinth itself (its public API allows this) with their hash checked
    New-Item -ItemType Directory -Force $dir | Out-Null; $n = 0
    foreach ($m in @($list)) {
        $pid0 = "$($m.p)"; $file = "$($m.f)"
        if ($pid0 -notmatch '^[A-Za-z0-9]{4,16}$' -or $file -notmatch '^[A-Za-z0-9 ._+()\[\]-]+\.jar$') { continue }
        try {
            $hit = $null
            foreach ($v in @(Invoke-Api "https://api.modrinth.com/v2/project/$pid0/version" 30)) { $hit = $v.files | Where-Object { $_.filename -eq $file } | Select-Object -First 1; if ($hit) { break } }
            if (-not $hit -or "$($hit.url)" -notmatch '^https://cdn\.modrinth\.com/') { & $log "Modrinth에서 못 찾았어요: $file"; continue }
            $b = Get-WebBytes $hit.url 60000
            $sha = -join ([Security.Cryptography.SHA1]::Create().ComputeHash($b) | ForEach-Object { $_.ToString('x2') })
            if ($sha -ne "$($hit.hashes.sha1)") { & $log "파일이 손상돼서 건너뛰었어요: $file"; continue }
            [IO.File]::WriteAllBytes((Join-Path $dir $file), $b); $n++; & $log "넣었어요: $file"
        }
        catch { & $log "받지 못했어요: $file ($($_.Exception.Message))" }
    }
    return $n
}
function Show-JoinGuide($c, $p, [string]$addr, [string]$gd, $changes = $null) {
    # $gd empty: a CurseForge modpack, installed with the CurseForge app. Otherwise this program's game folder,
    # where only the link-only mods are left to do. Returns $true when the game may start.
    $cf = -not $gd
    $script:gLinks = @(); if ($c.PSObject.Properties['l']) { $script:gLinks = @($c.l | Where-Object { $_ }) }
    $script:gAuto = @(); if ($c.PSObject.Properties['m']) { $script:gAuto = @($c.m | Where-Object { $_ }) }
    $script:gAddr = $addr; $script:gPack = $p; $script:gCode = $c
    if ($changes -and $changes.any) {
        # Only what the host changed since last time
        $script:gAuto = @($changes.addMods)
        if (@($changes.addLinks).Count) { $script:gLinks = @($changes.addLinks) } elseif ($cf) { $script:gLinks = @() }
    }
    $f = New-Object Windows.Forms.Form
    $f.StartPosition = 'CenterParent'; $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.Font = $font
    $y = 12
    if ($cf) {
        $f.Text = "CurseForge 앱으로 설치하기 - $($c.n)"
        $g0 = New-Ctl Label 15 $y 740 44 "'$($p.name)'은(는) CurseForge 모드팩이라 CurseForge 공식 앱으로 설치해요.`n(모드팩 파일을 이 프로그램이 대신 받아 오지 않아요. 순서대로 하면 돼요)"; $y += 52
        $g1 = New-Ctl Label 15 $y 740 24 '① [CurseForge 앱 받기] → 설치하고 켜요. 게임 목록에서 Minecraft를 골라요.'; $y += 28
        $gb1 = New-Ctl Button 15 $y 260 34 'CurseForge 앱 받기'; $y += 44
        $g2 = New-Ctl Label 15 $y 740 44 "② 앱에서 모드팩 '$($p.name)'을(를) 검색해서 버전 '$($c.k)'(으)로 설치해요.`n    (버전이 다르면 접속이 안 돼요. 공식 페이지에서 이름과 버전을 확인할 수 있어요)"; $y += 50
        $gb2 = New-Ctl Button 15 $y 260 34 '모드팩 공식 페이지 열기'; $gb2.Enabled = Test-ModUrl "$($p.page)"; $y += 44
        $g3 = New-Ctl Label 15 $y 740 24 '③ 앱 설정에서 게임 메모리(RAM)를 6~8GB로 올려요.'; $y += 32
        $f.Controls.AddRange(@($g0, $g1, $gb1, $g2, $gb2, $g3))
        $gb1.Add_Click({ Open-Url 'https://www.curseforge.com/download/app' })
        $gb2.Add_Click({ Open-Url "$($script:gPack.page)" })
    }
    else {
        $f.Text = "추가 모드 직접 받기 - $($c.n)"
        $g0 = New-Ctl Label 15 $y 740 44 "모드팩과 [자동] 모드는 준비됐어요. 아래 모드는 방장이 Modrinth 밖에서 받은 거라,`n원본 페이지에서 직접 받아서 넣어야 해요. (파일을 대신 받아 오면 재배포라 문제가 될 수 있어요)"; $y += 52
        $f.Controls.Add($g0)
    }
    $gt = New-Ctl Label 15 $y 740 24 '받아서 넣을 모드'; if ($cf) { $gt.Text = '④ 방장이 추가한 모드 (꼭 넣어야 접속돼요)' }
    if ($changes -and $changes.any) {
        $gt.Text = '방장이 새로 넣은 모드'
        $gone = @(@($changes.delMods | ForEach-Object { "$($_.f)" }) + @($changes.delLinks | ForEach-Object { "$($_.t)" }))
        if ($gone.Count) {
            $gx = New-Ctl Label 15 $y 740 44 ("방장이 뺀 모드 (mods 폴더에서 지워 주세요): " + ($gone -join ', ')); $gx.ForeColor = [Drawing.Color]::Firebrick
            if ($cf) { $gx.Text = "방장이 뺀 모드: " + ($gone -join ', ') + "`n([자동] 모드 넣기를 누르면 [자동] 모드는 알아서 지워요. 나머지는 mods 폴더에서 지워 주세요)" }
            elseif (@($changes.delLinks).Count) { $gx.Text = "방장이 뺀 모드: " + ($gone -join ', ') + "`n[넣을 폴더 열기]로 열리는 폴더에서 그 파일을 지워 주세요." }
            $f.Controls.Add($gx); $y += 48
        }
    }
    $y += 26
    $lb = New-Ctl ListBox 15 $y 740 120; $lb.HorizontalScrollbar = $true; $y += 126
    foreach ($m in $script:gAuto) { [void]$lb.Items.Add("[자동] $($m.f)   ([자동] 모드 넣기를 누르면 Modrinth에서 받아요)") }
    foreach ($l in $script:gLinks) { [void]$lb.Items.Add("[링크] $($l.t)   →  $(Get-UrlSite $l.u)") }
    if (-not $lb.Items.Count) { [void]$lb.Items.Add('(추가 모드 없음)') }
    $bOpen = New-Ctl Button 15 $y 240 34 '선택한 모드 페이지 열기'
    $bDir = New-Ctl Button 265 $y 240 34 '넣을 폴더 열기'
    $bAuto = New-Ctl Button 515 $y 240 34 '[자동] 모드 넣기'; $bAuto.Enabled = [bool]$script:gAuto.Count; $bAuto.Visible = $cf; $y += 42
    $note = New-Ctl Label 15 $y 740 64 ''; $note.ForeColor = [Drawing.Color]::DarkGreen; $y += 70
    if ($cf) { $note.Text = "[링크] 모드는 페이지에서 이 마인크래프트 버전에 맞는 파일을 받아서 모드팩의 mods 폴더에 넣어요.`n(앱: 모드팩 오른쪽 위 점 3개 → Open Folder → mods)  [넣을 폴더 열기]로 한 번 고르면 [자동] 모드도 거기 넣어요." }
    else { $note.Text = "[선택한 모드 페이지 열기] → 이 마인크래프트 버전에 맞는 .jar 파일을 받아서 [넣을 폴더 열기]로 열린 폴더에 넣어요.`n게임을 켤 때마다 이 폴더의 모드를 알아서 넣어 줘요. (게임을 다시 설치해도 안 지워져요)" }
    $f.Controls.AddRange(@($gt, $lb, $bOpen, $bDir, $bAuto, $note))
    $script:guideDir = $null; if (-not $cf) { $script:guideDir = Join-Path $gd $ManualModsDir }
    $script:gChanges = $changes
    # A CurseForge game this program guided: its mods folder, once chosen, is remembered for next time
    $cfRec = $null
    if ($cf) { $cfRec = Read-Json (Join-Path $GameRoot "cf-$($c.n)\mcsm-cf.json"); if ($cfRec -and $cfRec.modsDir -and (Test-Path -LiteralPath "$($cfRec.modsDir)")) { $script:guideDir = "$($cfRec.modsDir)" } }
    $script:gLb = $lb; $script:gNote = $note; $script:gForm = $f
    $bOpen.Add_Click({
            $k = $script:gLb.SelectedIndex; $na = $script:gAuto.Count
            if ($k -ge 0 -and $k -lt $na) { Open-Url "https://modrinth.com/project/$($script:gAuto[$k].p)"; return }
            if ($k -ge $na -and $k -lt $na + $script:gLinks.Count) { Open-Url $script:gLinks[$k - $na].u; return }
            Show-Msg '목록에서 모드를 고르세요.'
        })
    $bDir.Add_Click({
            if (-not $script:guideDir) { $script:guideDir = Select-CurseForgeModsDir $script:gForm $script:gPack.name; if (-not $script:guideDir) { return } }
            New-Item -ItemType Directory -Force $script:guideDir | Out-Null; Start-Process explorer.exe "`"$($script:guideDir)`""
        })
    $bAuto.Add_Click({
            if (-not $script:guideDir) { $script:guideDir = Select-CurseForgeModsDir $script:gForm $script:gPack.name; if (-not $script:guideDir) { return } }
            $script:gForm.Cursor = 'WaitCursor'
            $n = Save-ModrinthMods $script:gAuto $script:guideDir { param($t) $script:gNote.Text = $t; [Windows.Forms.Application]::DoEvents() }
            if ($script:gChanges) { foreach ($x in @($script:gChanges.delMods)) { if ("$($x.f)" -match '^[A-Za-z0-9 ._+()\[\]-]+\.jar$') { Remove-Item -LiteralPath (Join-Path $script:guideDir "$($x.f)") -Force -ErrorAction SilentlyContinue } } }
            [void](Confirm-ModsSafe $script:guideDir $script:guideDir (Join-Path $script:guideDir 'mod-scan.json'))
            $script:gForm.Cursor = 'Default'
            $script:gNote.Text = "[자동] 모드 $($n)개를 넣었어요: $($script:guideDir)"
        })
    if ($cf) {
        $g5 = New-Ctl Label 15 $y 740 24 "⑤ 앱에서 [Play] → 마인크래프트가 켜지면 멀티플레이 → 서버 추가 → 주소: $addr"; $y += 30
        $bAddr = New-Ctl Button 15 $y 240 34 '서버 주소 복사'
        $bClose = New-Ctl Button 515 $y 240 34 '닫기'; $y += 46
        $f.Controls.AddRange(@($g5, $bAddr, $bClose))
        $bAddr.Add_Click({ [Windows.Forms.Clipboard]::SetText($script:gAddr); $script:gNote.Text = "주소를 복사했어요: $($script:gAddr)" })
        $bClose.Add_Click({ $script:gForm.Close() })
    }
    else {
        $bGo = New-Ctl Button 15 $y 360 40 '다 넣었어요. 게임 켜기'; $bGo.Font = $bold
        $bLater = New-Ctl Button 395 $y 360 40 '나중에 넣을게요 (지금은 그냥 켜기)'; $y += 52
        $f.Controls.AddRange(@($bGo, $bLater))
        $bGo.Add_Click({ $script:gForm.Tag = 'go'; $script:gForm.Close() })
        $bLater.Add_Click({ $script:gForm.Tag = 'go'; $script:gForm.Close() })
    }
    $f.ClientSize = New-Object Drawing.Size(770, ($y + 8))
    [void]$f.ShowDialog($form)
    if ($cf) {
        # Listed under 설치해 둔 친구 서버, so [▶ 게임 켜기] can check later what the host changed
        $rd = Join-Path $GameRoot "cf-$($c.n)"; New-Item -ItemType Directory -Force $rd | Out-Null
        $rec = [ordered]@{ kind = 'curseforge'; name = $c.n; pack = $c.p; packName = $p.name; version = $c.k; versionKey = $c.k; address = $addr
            addedMods = (ConvertTo-ModsB64 @($script:gCode.m)); links = @($script:gCode.l); modsDir = "$($script:guideDir)" }
        [IO.File]::WriteAllText((Join-Path $rd 'mcsm-cf.json'), (ConvertTo-Json -InputObject $rec -Depth 4), $Utf8)
        Update-JoinedList
    }
    return ($f.Tag -eq 'go')
}
function Select-CurseForgeModsDir($owner, [string]$packName) {
    # The CurseForge app keeps each modpack in its own folder under Instances; the friend points at its mods folder once
    $fb = New-Object Windows.Forms.FolderBrowserDialog
    $fb.Description = "CurseForge 앱에 설치한 '$packName' 모드팩의 mods 폴더를 고르세요. (앱: 모드팩 오른쪽 위 점 3개 → Open Folder)"
    $inst = Join-Path $env:USERPROFILE 'curseforge\minecraft\Instances'
    $guess = @(Get-ChildItem -LiteralPath $inst -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($guess.Count) { $fb.SelectedPath = Join-Path $guess[0].FullName 'mods' } elseif (Test-Path -LiteralPath $inst) { $fb.SelectedPath = $inst }
    if ($fb.ShowDialog($owner) -ne 'OK') { return $null }
    return $fb.SelectedPath
}
function Sync-ManualMods([string]$gd) {
    # Jars the friend downloaded by link go into the game's mods every time it starts (a rebuild empties mods)
    $src = Join-Path $gd $ManualModsDir; $dst = Join-Path $gd 'mods'
    if (-not (Test-Path -LiteralPath $src) -or -not (Test-Path -LiteralPath $dst)) { return 0 }
    $n = 0
    foreach ($j in @(Get-ChildItem -LiteralPath $src -Filter '*.jar' -File -ErrorAction SilentlyContinue)) { Copy-Item -LiteralPath $j.FullName -Destination $dst -Force; $n++ }
    return $n
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
        [void]$lstJoined.Items.Add("$($m.name)  ($($m.version))")
    }
    foreach ($g in @(Get-ChildItem -LiteralPath $GameRoot -Directory -Filter 'cf-*' -ErrorAction SilentlyContinue)) {
        $m = Read-Json (Join-Path $g.FullName 'mcsm-cf.json'); if (-not $m) { continue }
        $script:joined += , @($g.FullName, $m)
        [void]$lstJoined.Items.Add("$($m.name)  ($($m.version), CurseForge 앱)")
    }
    if ($lstJoined.Items.Count) { $lstJoined.SelectedIndex = 0 }
}
$btnJoinAgain.Add_Click({
        if ($lstJoined.SelectedIndex -lt 0) { Show-Msg '목록에서 친구 서버를 고르세요.'; return }
        $gdir = $script:joined[$lstJoined.SelectedIndex][0]; $m = $script:joined[$lstJoined.SelectedIndex][1]
        # Ask the host's server what it runs now: changed mods are caught up here, without a new link
        $txtJoinLog.AppendText("방장 서버에 바뀐 모드가 있는지 확인하는 중... ($($m.address))`r`n"); $form.Cursor = 'WaitCursor'; Pump 50
        $new = Find-HostCode "$($m.address)" "$($m.name)"; $form.Cursor = 'Default'
        $addr = "$($m.address)"; if ($new -and $new.a) { $addr = "$($new.a)" }
        if ($m.kind -eq 'curseforge') {
            $p = $packs | Where-Object { $_.id -eq $m.pack } | Select-Object -First 1; if (-not $p) { $p = [pscustomobject]@{ name = $m.packName; page = '' } }
            if (-not $new) { [Windows.Forms.Clipboard]::SetText($addr); Show-Msg "방장 서버가 꺼져 있거나 확인할 수 없었어요. (모드가 바뀌었는지 모르는 채로 해요)`n`nCurseForge 앱에서 '$($m.packName)'을(를) Play → 멀티플레이 → 서버 접속.`n주소를 복사해 뒀어요: $addr"; return }
            if ($new.p -ne $m.pack -or $new.k -ne $m.versionKey) { Show-Msg "방장이 모드팩을 바꿨어요 ('$($new.k)'). 새 버전을 CurseForge 앱으로 설치하는 순서를 다시 보여 줄게요."; [void](Show-JoinGuide $new ($packs | Where-Object { $_.id -eq $new.p } | Select-Object -First 1) $addr ''); return }
            $ch = Get-JoinChanges (ConvertFrom-ModsB64 ([string]$m.addedMods)) @($m.links) $new
            if (-not $ch.any) { [Windows.Forms.Clipboard]::SetText($addr); Show-Msg "방장 서버와 모드가 같아요.`n`nCurseForge 앱에서 '$($m.packName)'을(를) Play → 멀티플레이 → 서버 접속.`n주소를 복사해 뒀어요: $addr"; return }
            $txtJoinLog.AppendText("방장이 모드를 바꿨어요: 새 모드 $($ch.addMods.Count + $ch.addLinks.Count)개, 뺀 모드 $($ch.delMods.Count + $ch.delLinks.Count)개`r`n")
            [void](Show-JoinGuide $new $p $addr '' $ch); return
        }
        if ($new) {
            $newB64 = ConvertTo-ModsB64 $new.m
            $oldLinks = @(Read-JsonList (Join-Path $gdir 'mod-links.json'))
            $ch = Get-JoinChanges @() $oldLinks ([pscustomobject]@{ m = @(); l = @($new.l) })
            if ($new.p -ne $m.pack -or $new.k -ne $m.versionKey -or $newB64 -ne [string]$m.addedMods -or $ch.any) {
                $txtJoinLog.AppendText("방장이 모드(또는 모드팩 버전)를 바꿨어요. 알아서 맞출게요.`r`n")
                Start-JoinGame $new $addr ([int]$m.ramGB); return
            }
            $txtJoinLog.AppendText("방장 서버와 모드가 같아요.`r`n")
        }
        else { $txtJoinLog.AppendText("방장 서버가 꺼져 있거나 확인할 수 없어서 지난번 그대로 켜요.`r`n") }
        # The same added-mods value as last time, untouched, so an unchanged game is recognised and left alone
        $c = [pscustomobject]@{ p = $m.pack; k = $m.versionKey; n = $m.name }
        Start-JoinGame $c $addr ([int]$m.ramGB) ([string]$m.addedMods)
    })
$btnJoinDel.Add_Click({
        if ($lstJoined.SelectedIndex -lt 0) { return }
        $g = $script:joined[$lstJoined.SelectedIndex]
        if ($g[1].kind -eq 'curseforge') {
            if (Ask-YesNo "'$($g[1].name)' 을(를) 목록에서 뺄까요?`n(CurseForge 앱의 모드팩은 그대로예요. 앱에서 지우면 돼요)") { Remove-Item -LiteralPath $g[0] -Recurse -Force -ErrorAction SilentlyContinue; Update-JoinedList }
            return
        }
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
        Update-LiveBackup
        Update-BackupCopies
        Resume-Playit
        $script:tick++
        if ($script:tick % 12 -eq 0) { Update-PlayitLabel }
        # Every 10 minutes; every 30 seconds while there is no address yet (the tunnel is often made after the key is saved)
        if (($script:tick -eq 8 -or $script:tick % 2400 -eq 0 -or ($script:tick % 120 -eq 0 -and -not (Get-PlayitAddress))) -and (Get-PlayitKey)) { [void](Sync-PlayitAddress) }
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
        if (Test-PcInfected) {
            Show-Msg ("⚠ 이 PC에서 악성코드(fractureiser)가 남기는 폴더를 찾았어요:`n$(Join-Path $env:LOCALAPPDATA 'Microsoft Edge')`n" +
                "(진짜 Edge 폴더 이름은 'MicrosoftEdge'나 'Microsoft\Edge'예요. 띄어쓰기가 있는 이 폴더는 가짜예요)`n`n" +
                "1. 켜져 있는 마인크래프트와 서버를 모두 끄세요.`n2. 이 폴더를 통째로 지우세요.`n3. Windows 보안 → 바이러스 및 위협 방지 → [전체 검사]를 하세요.`n" +
                "4. 다른 PC에서 마이크로소프트·디스코드·브라우저 비밀번호를 바꾸세요.") 'Warning'
        }
        $notice = Join-Path $Prog 'updated-notice.txt'
        if (Test-Path -LiteralPath $notice) {
            Show-Msg ("프로그램을 새 버전으로 업데이트했어요.`n`n" + [IO.File]::ReadAllText($notice))
            Remove-Item -LiteralPath $notice -ErrorAction SilentlyContinue
        }
        if ($script:retiredBat) {
            Show-Msg "이제부터는 폴더의 '모드팩서버관리.exe'로 프로그램을 켜 주세요.`n검은 창 없이 바로 열려요. (예전 모드팩서버관리.bat 은 정리했어요)"
        }
    })

$form.Add_Activated({ Find-ClipboardCode })

Update-Servers
Update-PlayitLabel
if (-not (Get-PlayitAddress)) { $btnCopyAddr.Text = '친구에게 줄 주소 넣기' }
if ($lstSrv.Items.Count) { $tabs.SelectedTab = $tabMy } else { $tabs.SelectedTab = $tabNew }
$uiTimer.Start()
[void]$form.ShowDialog()
