param(
    [Parameter(Mandatory = $true)][string]$PackId,
    [Parameter(Mandatory = $true)][string]$VersionKey,   # CurseForge: version label, Modrinth: version id
    [Parameter(Mandatory = $true)][string]$Name,         # server folder name
    [int]$RamGB = 6,
    [switch]$AcceptEula,
    [string]$ServersDir = '',
    [string]$StatusFile = '',  # written with ok/fail when done (read by manager.ps1)
    [switch]$NoPause,
    [switch]$Update,           # $Name is an existing server: install the new version beside it, carry the world over, swap
    # -Client: set up the GAME side instead of a server (same modpack in the official Minecraft Launcher)
    [switch]$Client,
    [string]$GameDir = '',     # where the game files go (<root>\game\<name>)
    [string]$FromServer = '',  # host on the same PC: take the files from this server folder instead of downloading
    [string]$Address = '127.0.0.1',
    [string]$AddedMods = '',   # friend: base64 JSON [{p: modrinthProjectId, f: fileName}, ...] the host added by hand
    [int]$GameRamGB = 6
)
# Installs one modpack server into <root>\servers\<Name>.
# Shared runtimes live in <root>\_program (java\<major>, playit, cache).
# With -Update the old server folder is kept in <root>\servers_old.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Every API call gets a time limit; a stalled connection fails with a message instead of hanging forever
$PSDefaultParameterValues['Invoke-RestMethod:TimeoutSec'] = 30
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Prog = $PSScriptRoot
$Root = Split-Path $Prog -Parent
if (-not $ServersDir) { $ServersDir = Join-Path $Root 'servers' }
$Cache = Join-Path $Prog 'cache'
$Cp949 = [Text.Encoding]::GetEncoding(949)
New-Item -ItemType Directory -Force $Cache, $ServersDir | Out-Null

function Step($msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" }

function Invoke-Curl {
    # curl writes progress to stderr; keep that from being treated as a terminating error
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & curl.exe @args } finally { $ErrorActionPreference = $old }
}

function Get-Download([string]$Url, [string]$OutFile, [long]$Size = 0, [string]$Sha1 = '', [string]$Sha512 = '', [string]$Sha256 = '') {
    function Test-Ok {
        if (-not (Test-Path -LiteralPath $OutFile)) { return $false }
        if ($Size -gt 0 -and (Get-Item -LiteralPath $OutFile).Length -ne $Size) { return $false }
        if ($Sha1 -and (Get-FileHash -LiteralPath $OutFile -Algorithm SHA1).Hash -ne $Sha1.ToUpper()) { return $false }
        if ($Sha512 -and (Get-FileHash -LiteralPath $OutFile -Algorithm SHA512).Hash -ne $Sha512.ToUpper()) { return $false }
        if ($Sha256 -and (Get-FileHash -LiteralPath $OutFile -Algorithm SHA256).Hash -ne $Sha256.ToUpper()) { return $false }
        return $true
    }
    if (Test-Ok) { Info "이미 받아 둔 파일을 사용해요: $(Split-Path $OutFile -Leaf)"; return }
    $tmp = "$OutFile.part"
    # Progress as plain lines, so the manager window can show it (a curl progress bar only works in a console)
    $errFile = "$tmp.err"
    $p = Start-Process curl.exe -ArgumentList @('-L', '--fail', '--retry', '3', '-s', '-S', '-o', "`"$tmp`"", "`"$Url`"") -NoNewWindow -PassThru -RedirectStandardError $errFile
    # Windows PowerShell 5.1 loses ExitCode for Start-Process -PassThru unless the handle is opened right away
    $null = $p.Handle
    $last = -1
    while (-not $p.HasExited) {
        Start-Sleep -Milliseconds 1500
        if ($Size -gt 0 -and (Test-Path -LiteralPath $tmp)) {
            $got = (Get-Item -LiteralPath $tmp).Length
            $pct = [int](100 * $got / $Size)
            if ($pct -ne $last) { $last = $pct; Info ("다운로드 중... {0}%  ({1:N0}MB / {2:N0}MB)" -f $pct, ($got / 1MB), ($Size / 1MB)) }
        }
    }
    $p.WaitForExit()
    $err = ''; if (Test-Path -LiteralPath $errFile) { $err = (Get-Content -LiteralPath $errFile -Raw); Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue }
    if ($p.ExitCode -ne 0) { throw "다운로드 실패: $Url $err" }
    Move-Item -Force -LiteralPath $tmp -Destination $OutFile
    if (-not (Test-Ok)) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        throw "받은 파일이 손상됐거나 바뀌었어요 (크기/해시 불일치): $(Split-Path $OutFile -Leaf)`n잠시 뒤에 다시 해 보고, 계속 이러면 프로그램을 업데이트해 주세요."
    }
}

function Assert-FreeSpace([long]$needBytes) {
    # Fail early with a clear message instead of a cryptic write error halfway through a big pack
    $drive = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Root))
    if ($drive.AvailableFreeSpace -lt $needBytes) {
        throw ("디스크 공간이 모자라요. {0} 드라이브에 {1:N1}GB가 더 필요해요. (지금 남은 공간 {2:N1}GB)" -f $drive.Name, (($needBytes - $drive.AvailableFreeSpace) / 1GB), ($drive.AvailableFreeSpace / 1GB))
    }
}

function Get-JavaMajor([string]$mc) {
    $p = $mc.Split('.')
    if ($p[0] -eq '1') {
        $minor = [int]$p[1]; $patch = 0; if ($p.Count -gt 2) { $patch = [int]$p[2] }
        if ($minor -le 16) { throw "마인크래프트 $mc 는 지원하지 않아요 (1.17 이상만 가능)." }
        if ($minor -lt 20 -or ($minor -eq 20 -and $patch -le 4)) { return 17 }
        return 21
    }
    return 25
}

function Get-Java([int]$major) {
    $dir = Join-Path $Prog "java\$major"
    $exe = Join-Path $dir 'bin\java.exe'
    if (Test-Path $exe) { Info "Java $major 준비됨"; return $exe }
    Step "Java $major 받는 중"
    $a = Invoke-RestMethod "https://api.adoptium.net/v3/assets/latest/$major/hotspot?architecture=x64&image_type=jre&os=windows&vendor=eclipse"
    $pkg = $a[0].binary.package
    $zip = Join-Path $Cache $pkg.name
    Get-Download $pkg.link $zip -Size $pkg.size -Sha256 $pkg.checksum
    $tmp = Join-Path $Cache "java$major-extract"
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
    New-Item -ItemType Directory -Force (Split-Path $dir -Parent) | Out-Null
    # A half-finished earlier attempt would make Move-Item nest the new folder inside the old one
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Move-Item (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName $dir
    Remove-Item -Recurse -Force $tmp
    return $exe
}

function Get-NeoForgeMc([string]$v) {
    # NeoForge 21.1.x -> MC 1.21.1, 20.4.x -> 1.20.4, 21.0.x -> 1.21
    $p = $v.Split('.')
    if ([int]$p[0] -ge 26) { return "$($p[0]).$($p[1])" }
    if ($p[1] -eq '0') { return "1.$($p[0])" }
    return "1.$($p[0]).$($p[1])"
}

function Find-Loader([string]$dir, $pack) {
    $vars = Join-Path $dir 'variables.txt'
    if (Test-Path $vars) {
        $kv = @{}
        Get-Content $vars | Where-Object { $_ -match '^\s*([A-Z_]+)=(.*)$' } | ForEach-Object { $kv[$Matches[1]] = $Matches[2].Trim('"', ' ') }
        if ($kv['MODLOADER'] -and $kv['MODLOADER_VERSION']) {
            return @{ loader = $kv['MODLOADER'].ToLower(); version = $kv['MODLOADER_VERSION']; mc = $kv['MINECRAFT_VERSION'] }
        }
    }
    foreach ($j in Get-ChildItem $dir -Filter '*installer*.jar' -File) {
        if ($j.Name -match '^forge-(?<mc>[\d.]+)-(?<v>[\d.]+)-installer\.jar$') { return @{ loader = 'forge'; version = $Matches.v; mc = $Matches.mc; installer = $j.FullName } }
        if ($j.Name -match '^neoforge-(?<v>[\d.]+(-beta)?)-installer\.jar$') { return @{ loader = 'neoforge'; version = $Matches.v; mc = (Get-NeoForgeMc $Matches.v); installer = $j.FullName } }
    }
    $man = Join-Path $dir 'manifest.json'
    if (Test-Path $man) {
        $m = Get-Content $man -Raw -Encoding UTF8 | ConvertFrom-Json
        $ml = $m.minecraft.modLoaders | Where-Object { $_.primary } | Select-Object -First 1
        if (-not $ml) { $ml = $m.minecraft.modLoaders | Select-Object -First 1 }
        if ($ml -and $ml.id -match '^(?<l>forge|neoforge|fabric)-(?<v>.+)$') { return @{ loader = $Matches.l; version = $Matches.v; mc = $m.minecraft.version } }
    }
    # Fallback: newest loader build for the pack's Minecraft version
    $mc = $pack.mc
    switch ($pack.loader) {
        'forge' {
            $pr = (Invoke-RestMethod 'https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json').promos
            $v = $pr."$mc-recommended"; if (-not $v) { $v = $pr."$mc-latest" }
            return @{ loader = 'forge'; version = $v; mc = $mc }
        }
        'neoforge' {
            $all = (Invoke-RestMethod 'https://maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge').versions
            $v = $all | Where-Object { (Get-NeoForgeMc $_) -eq $mc -and $_ -notmatch 'beta' } | Select-Object -Last 1
            return @{ loader = 'neoforge'; version = $v; mc = $mc }
        }
        'fabric' {
            $v = ((Invoke-RestMethod 'https://meta.fabricmc.net/v2/versions/loader') | Where-Object stable | Select-Object -First 1).version
            return @{ loader = 'fabric'; version = $v; mc = $mc }
        }
    }
    throw '모드 로더(Forge/NeoForge/Fabric) 버전을 알아내지 못했어요.'
}

function Invoke-Installer([string]$java, [string]$inst, [string]$dir) {
    # Start-Process keeps installer stderr from tripping $ErrorActionPreference
    $log = Join-Path $dir 'install-log.txt'
    $p = Start-Process -FilePath $java -ArgumentList @('-jar', "`"$inst`"", '--installServer', "`"$dir`"") -WorkingDirectory $dir `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    if ($p.ExitCode -ne 0) { throw "모드 로더 설치 실패. $log 파일을 확인하세요." }
    Remove-Item -Force "$log.err" -ErrorAction SilentlyContinue
    if ((Split-Path $inst -Parent) -eq $dir) { Remove-Item -Force $inst }
}

function Install-Loader([string]$dir, $li, [string]$java) {
    Step "$($li.loader) $($li.version) 설치 중 (마인크래프트 $($li.mc))"
    switch ($li.loader) {
        'forge' {
            $inst = $li.installer
            if (-not $inst) {
                $fv = "$($li.mc)-$($li.version)"
                $inst = Join-Path $Cache "forge-$fv-installer.jar"
                $base = "https://maven.minecraftforge.net/net/minecraftforge/forge/$fv/forge-$fv-installer.jar"
                $sha1 = (Invoke-Curl -s -L --fail "$base.sha1")
                Get-Download $base $inst -Sha1 "$sha1".Trim()
            }
            Invoke-Installer $java $inst $dir
            $wa = "libraries/net/minecraftforge/forge/$($li.mc)-$($li.version)/win_args.txt"
            if (-not (Test-Path (Join-Path $dir $wa))) { throw "이 Forge 버전은 지원하지 않아요 (1.17 이상만 가능)." }
            return "@user_jvm_args.txt @$wa nogui"
        }
        'neoforge' {
            $inst = $li.installer
            if (-not $inst) {
                $v = $li.version
                $inst = Join-Path $Cache "neoforge-$v-installer.jar"
                $base = "https://maven.neoforged.net/releases/net/neoforged/neoforge/$v/neoforge-$v-installer.jar"
                $sha1 = (Invoke-Curl -s -L --fail "$base.sha1")
                Get-Download $base $inst -Sha1 "$sha1".Trim()
            }
            Invoke-Installer $java $inst $dir
            $wa = "libraries/net/neoforged/neoforge/$($li.version)/win_args.txt"
            if (-not (Test-Path (Join-Path $dir $wa))) { throw "NeoForge 실행 정보를 찾지 못했어요." }
            return "@user_jvm_args.txt @$wa nogui"
        }
        'fabric' {
            $iv = ((Invoke-RestMethod 'https://meta.fabricmc.net/v2/versions/installer') | Where-Object stable | Select-Object -First 1).version
            $jar = Join-Path $dir 'fabric-server-launch.jar'
            Invoke-Curl -L --fail -s -S -o $jar "https://meta.fabricmc.net/v2/versions/loader/$($li.mc)/$($li.version)/$iv/server/jar"
            if ($LASTEXITCODE -ne 0) { throw 'Fabric 서버 파일을 받지 못했어요.' }
            return "@user_jvm_args.txt -jar fabric-server-launch.jar nogui"
        }
        default { throw "$($li.loader) 로더는 아직 지원하지 않아요." }
    }
}

function Write-Cp949([string]$path, [string]$text) {
    [IO.File]::WriteAllText($path, ($text -replace "`r?`n", "`r`n"), $Cp949)
}

# server.properties keys packs.json may set (anything security-related stays with install.ps1 and the manager)
$PackPropKeys = @('allow-flight', 'spawn-protection', 'max-tick-time', 'difficulty', 'view-distance', 'simulation-distance', 'spawn-monsters', 'pvp', 'max-players')
function Set-Prop([string[]]$lines, [string]$key, [string]$value) {
    $found = $false
    $out = foreach ($l in $lines) { if ($l -match "^$([regex]::Escape($key))=") { $found = $true; "$key=$value" } else { $l } }
    if (-not $found) { $out = @($out) + "$key=$value" }
    return , @($out)
}

function Merge-FromOldServer {
    # Carries the world and everything the players set up from $oldDir into the freshly installed $dir
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $level = 'world'
    $op = Join-Path $oldDir 'server.properties'
    if (Test-Path -LiteralPath $op) { $lv = [IO.File]::ReadAllLines($op, $latin1) | Where-Object { $_ -match '^level-name=(.+)$' } | Select-Object -First 1; if ($lv) { $level = ($lv -split '=', 2)[1].Trim() } }
    $oldWorld = Join-Path $oldDir $level
    $newWorld = Join-Path $dir $level

    if (Test-Path -LiteralPath $oldWorld) {
        Step '혹시 몰라 지금 월드를 백업하는 중'
        $bk = Join-Path $oldDir 'backups'; New-Item -ItemType Directory -Force $bk | Out-Null
        $zip = Join-Path $bk ("before-update_" + ($oldInfo.version -replace '[^A-Za-z0-9._-]', '-') + '_' + (Get-Date -Format 'yyyyMMdd_HHmm') + '.zip')
        [IO.Compression.ZipFile]::CreateFromDirectory($oldWorld, $zip)
        Info "백업: $zip"
    }

    Step '월드와 설정 옮기는 중'
    if (Test-Path -LiteralPath $oldWorld) {
        # The new pack's datapacks win over the old ones of the same name
        $ndp = Join-Path $newWorld 'datapacks'
        if (Test-Path -LiteralPath $ndp) {
            $odp = Join-Path $oldWorld 'datapacks'; New-Item -ItemType Directory -Force $odp | Out-Null
            Get-ChildItem -LiteralPath $ndp -Force | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $odp -Recurse -Force }
        }
        if (Test-Path -LiteralPath $newWorld) { Remove-Item -LiteralPath $newWorld -Recurse -Force }
        $script:worldMovedFrom = $oldWorld; $script:worldMovedTo = $newWorld
        Move-Item -LiteralPath $oldWorld -Destination $newWorld
        Info "월드 옮김: $level"
    }
    foreach ($f in 'server.properties', 'whitelist.json', 'ops.json', 'banned-players.json', 'banned-ips.json', 'usercache.json', 'whitelist-pending.txt') {
        $src = Join-Path $oldDir $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dir -Force }
    }
    $obk = Join-Path $oldDir 'backups'
    if (Test-Path -LiteralPath $obk) { Copy-Item -LiteralPath $obk -Destination $dir -Recurse -Force }

    # Mods the host added by hand come along, unless the new pack version already ships them
    $added = @()
    $aj = Join-Path $oldDir 'added-mods.json'
    if (Test-Path -LiteralPath $aj) { $added = @(Get-Content -LiteralPath $aj -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ }) }
    if ($added.Count) {
        $inPack = @{}
        try {
            $hashes = @(Get-ChildItem -LiteralPath (Join-Path $dir 'mods') -Filter '*.jar' | ForEach-Object { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA1).Hash.ToLower() })
            $res = Invoke-RestMethod -Method Post -Uri 'https://api.modrinth.com/v2/version_files' -ContentType 'application/json' -Body (@{ hashes = $hashes; algorithm = 'sha1' } | ConvertTo-Json)
            foreach ($p in $res.PSObject.Properties) { $inPack[$p.Value.project_id] = $true }
        }
        catch { Info '(모드팩에 이미 든 모드인지 확인하지 못했어요. 직접 추가한 모드를 그대로 옮겨요)' }
        $keep = @()
        $friendNew = Join-Path $dir '친구용_추가모드'
        foreach ($m in $added) {
            if ($m.projectId -and $inPack.ContainsKey($m.projectId)) { Info "새 모드팩에 이미 들어 있어서 뺐어요: $($m.title)"; continue }
            $om = Join-Path $oldDir "mods\$($m.file)"
            if ($m.onServer -and (Test-Path -LiteralPath $om)) { Copy-Item -LiteralPath $om -Destination (Join-Path $dir 'mods') -Force }
            $of = Join-Path $oldDir "친구용_추가모드\$($m.file)"
            if ($m.forClient -and (Test-Path -LiteralPath $of)) { New-Item -ItemType Directory -Force $friendNew | Out-Null; Copy-Item -LiteralPath $of -Destination $friendNew -Force }
            $keep += $m
            Info "직접 추가한 모드 옮김: $($m.title)"
        }
        [IO.File]::WriteAllText((Join-Path $dir 'added-mods.json'), (ConvertTo-Json -InputObject @($keep) -Depth 4), (New-Object Text.UTF8Encoding($false)))
        $client = @($keep | Where-Object { $_.forClient })
        if ($client.Count) {
            $g = Join-Path $dir '친구접속안내.txt'
            $text = [IO.File]::ReadAllText($g, $Cp949).TrimEnd()
            $text += "`r`n`r`n[ 추가 모드 ]  방장이 따로 넣은 모드예요. 꼭 같이 넣어야 접속돼요!`r`n"
            $text += "  방장이 보내 준 '친구용_추가모드' 폴더의 파일을 모두 내 모드팩의 mods 폴더에 넣으세요.`r`n"
            $text += "  (CurseForge/Modrinth 앱에서 모드팩 오른쪽 위 점 3개 -> Open Folder -> mods)`r`n"
            foreach ($m in $client) { $text += "  - $($m.title)  ($($m.file))`r`n" }
            [IO.File]::WriteAllText($g, $text, $Cp949)
        }
    }
    # The old folder's batch files and info would point at the temporary name; rewrite the title line
    $bat = Join-Path $dir '서버켜기.bat'
    [IO.File]::WriteAllText($bat, ([IO.File]::ReadAllText($bat, $Cp949) -replace [regex]::Escape($Name), $finalName), $Cp949)
    $g = Join-Path $dir '친구접속안내.txt'
    [IO.File]::WriteAllText($g, ([IO.File]::ReadAllText($g, $Cp949) -replace [regex]::Escape($Name), $finalName), $Cp949)
}

# ---------------------------------------------------------------------------
# Game side (-Client): the same modpack the server runs, as an installation in the official Minecraft Launcher.
# Logging in stays with the launcher and the player's own Microsoft account; nothing here ever sees a password.
$ClientDirs = @('config', 'defaultconfigs', 'kubejs', 'resourcepacks', 'shaderpacks', 'patchouli_books', 'global_packs', 'configureddefaults', 'openloader')

function Add-NbtHelper {
    if ('McsmNbt' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
// Just enough NBT to add one entry to servers.dat (the in-game server list) and keep everything else in it as it was
public static class McsmNbt {
    class Tag { public byte Type; public string Name; public object Value; }
    class ListVal { public byte ElemType; public List<object> Items = new List<object>(); }
    static string ReadStr(BinaryReader r) { int n = (r.ReadByte() << 8) | r.ReadByte(); return Encoding.UTF8.GetString(r.ReadBytes(n)); }
    static void WriteStr(BinaryWriter w, string s) { byte[] b = Encoding.UTF8.GetBytes(s); w.Write((byte)(b.Length >> 8)); w.Write((byte)b.Length); w.Write(b); }
    static byte[] Be(BinaryReader r, int n) { byte[] b = r.ReadBytes(n); Array.Reverse(b); return b; }
    static void WBe(BinaryWriter w, byte[] b) { Array.Reverse(b); w.Write(b); }
    static object ReadPayload(BinaryReader r, byte t) {
        switch (t) {
            case 1: return r.ReadByte();
            case 2: return BitConverter.ToInt16(Be(r, 2), 0);
            case 3: return BitConverter.ToInt32(Be(r, 4), 0);
            case 4: return BitConverter.ToInt64(Be(r, 8), 0);
            case 5: return BitConverter.ToSingle(Be(r, 4), 0);
            case 6: return BitConverter.ToDouble(Be(r, 8), 0);
            case 7: { int n = BitConverter.ToInt32(Be(r, 4), 0); return r.ReadBytes(n); }
            case 8: return ReadStr(r);
            case 9: { var l = new ListVal(); l.ElemType = r.ReadByte(); int n = BitConverter.ToInt32(Be(r, 4), 0); for (int i = 0; i < n; i++) l.Items.Add(ReadPayload(r, l.ElemType)); return l; }
            case 10: { var c = new List<Tag>(); while (true) { byte tt = r.ReadByte(); if (tt == 0) break; var tag = new Tag(); tag.Type = tt; tag.Name = ReadStr(r); tag.Value = ReadPayload(r, tt); c.Add(tag); } return c; }
            case 11: { int n = BitConverter.ToInt32(Be(r, 4), 0); var a = new int[n]; for (int i = 0; i < n; i++) a[i] = BitConverter.ToInt32(Be(r, 4), 0); return a; }
            case 12: { int n = BitConverter.ToInt32(Be(r, 4), 0); var a = new long[n]; for (int i = 0; i < n; i++) a[i] = BitConverter.ToInt64(Be(r, 8), 0); return a; }
        }
        throw new InvalidDataException("unknown NBT tag " + t);
    }
    static void WritePayload(BinaryWriter w, byte t, object v) {
        switch (t) {
            case 1: w.Write((byte)v); break;
            case 2: WBe(w, BitConverter.GetBytes((short)v)); break;
            case 3: WBe(w, BitConverter.GetBytes((int)v)); break;
            case 4: WBe(w, BitConverter.GetBytes((long)v)); break;
            case 5: WBe(w, BitConverter.GetBytes((float)v)); break;
            case 6: WBe(w, BitConverter.GetBytes((double)v)); break;
            case 7: { var b = (byte[])v; WBe(w, BitConverter.GetBytes(b.Length)); w.Write(b); break; }
            case 8: WriteStr(w, (string)v); break;
            case 9: { var l = (ListVal)v; w.Write(l.ElemType); WBe(w, BitConverter.GetBytes(l.Items.Count)); foreach (var o in l.Items) WritePayload(w, l.ElemType, o); break; }
            case 10: { foreach (var tag in (List<Tag>)v) { w.Write(tag.Type); WriteStr(w, tag.Name); WritePayload(w, tag.Type, tag.Value); } w.Write((byte)0); break; }
            case 11: { var a = (int[])v; WBe(w, BitConverter.GetBytes(a.Length)); foreach (var x in a) WBe(w, BitConverter.GetBytes(x)); break; }
            case 12: { var a = (long[])v; WBe(w, BitConverter.GetBytes(a.Length)); foreach (var x in a) WBe(w, BitConverter.GetBytes(x)); break; }
        }
    }
    static Tag Find(List<Tag> c, string name) { foreach (var t in c) if (t.Name == name) return t; return null; }
    static List<Tag> Load(string path) {
        if (!File.Exists(path)) return new List<Tag>();
        using (var r = new BinaryReader(File.OpenRead(path))) {
            if (r.ReadByte() != 10) return new List<Tag>();
            ReadStr(r); return (List<Tag>)ReadPayload(r, 10);
        }
    }
    // Puts {name, ip} first in the list, replacing an older entry of the same name
    public static void UpsertServer(string path, string name, string ip) {
        List<Tag> root;
        try { root = Load(path); } catch { root = new List<Tag>(); }
        Tag servers = Find(root, "servers");
        if (servers == null || servers.Type != 9 || (((ListVal)servers.Value).Items.Count > 0 && ((ListVal)servers.Value).ElemType != 10)) {
            root.RemoveAll(x => x.Name == "servers");
            servers = new Tag(); servers.Type = 9; servers.Name = "servers"; var lv = new ListVal(); lv.ElemType = 10; servers.Value = lv;
            root.Add(servers);
        }
        var list = (ListVal)servers.Value; list.ElemType = 10;
        list.Items.RemoveAll(o => { var n = Find((List<Tag>)o, "name"); return n != null && n.Value as string == name; });
        var entry = new List<Tag>();
        var ipTag = new Tag(); ipTag.Type = 8; ipTag.Name = "ip"; ipTag.Value = ip; entry.Add(ipTag);
        var nameTag = new Tag(); nameTag.Type = 8; nameTag.Name = "name"; nameTag.Value = name; entry.Add(nameTag);
        list.Items.Insert(0, entry);
        string tmp = path + ".tmp";
        using (var w = new BinaryWriter(File.Create(tmp))) { w.Write((byte)10); WriteStr(w, ""); WritePayload(w, 10, root); }
        if (File.Exists(path)) File.Copy(path, path + "_old", true);
        File.Copy(tmp, path, true); File.Delete(tmp);
    }
    public static string[] ListServers(string path) {
        var res = new List<string>();
        Tag servers = Find(Load(path), "servers");
        if (servers != null && servers.Type == 9)
            foreach (var o in ((ListVal)servers.Value).Items) {
                var c = o as List<Tag>; if (c == null) continue;
                var n = Find(c, "name"); var i = Find(c, "ip");
                res.Add((n == null ? "" : (string)n.Value) + "|" + (i == null ? "" : (string)i.Value));
            }
        return res.ToArray();
    }
}
'@
}

function Get-McDir {
    $mc = Join-Path $env:APPDATA '.minecraft'
    if ($env:MCSM_MCDIR) { $mc = $env:MCSM_MCDIR }   # the simulator points this at a throwaway folder
    if (-not (Test-Path -LiteralPath (Join-Path $mc 'launcher_profiles.json'))) {
        throw '공식 마인크래프트 런처를 찾지 못했어요. https://www.minecraft.net/download 에서 런처를 설치하고, 한 번 켜서 로그인한 다음 다시 해 주세요.'
    }
    return $mc
}

function Copy-Tree([string]$from, [string]$to) {
    # robocopy copes with paths past the 260-character limit; exit codes below 8 mean success
    & robocopy.exe $from $to /E /NFL /NDL /NJH /NJS /NP /R:2 /W:1 | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "파일을 복사하지 못했어요: $from" }
}

function Get-LoaderInstaller($li) {
    # Same cached installer the server install uses; the game install only needs it once per loader version
    $fv = "$($li.mc)-$($li.version)"
    if ($li.loader -eq 'forge') {
        $inst = Join-Path $Cache "forge-$fv-installer.jar"
        $base = "https://maven.minecraftforge.net/net/minecraftforge/forge/$fv/forge-$fv-installer.jar"
    }
    else {
        $inst = Join-Path $Cache "neoforge-$($li.version)-installer.jar"
        $base = "https://maven.neoforged.net/releases/net/neoforged/neoforge/$($li.version)/neoforge-$($li.version)-installer.jar"
    }
    $sha1 = (Invoke-Curl -s -L --fail "$base.sha1")
    Get-Download $base $inst -Sha1 "$sha1".Trim()
    return $inst
}

function Read-LauncherProfiles([string]$mcDir) { return Get-Content -LiteralPath (Join-Path $mcDir 'launcher_profiles.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
function Save-LauncherProfiles([string]$mcDir, $j) {
    [IO.File]::WriteAllText((Join-Path $mcDir 'launcher_profiles.json'), ($j | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
}

function Install-ClientLoader($li, [string]$mcDir) {
    $mc = $li.mc; $v = $li.version
    switch ($li.loader) {
        'forge' { $vid = "$mc-forge-$v"; $theirs = 'forge' }
        'neoforge' { $vid = "neoforge-$v"; $theirs = 'NeoForge' }
        'fabric' { $vid = "fabric-loader-$v-$mc"; $theirs = '' }
        default { throw "$($li.loader) 로더는 아직 지원하지 않아요." }
    }
    $vjson = Join-Path $mcDir "versions\$vid\$vid.json"
    if (Test-Path -LiteralPath $vjson) { Info "$vid 은(는) 이미 설치돼 있어요."; return $vid }
    Step "$($li.loader) $v 게임용으로 설치 중 (마인크래프트 $mc)"
    if ($li.loader -eq 'fabric') {
        # The launcher downloads Fabric's libraries itself from the URLs in this file
        New-Item -ItemType Directory -Force (Split-Path $vjson -Parent) | Out-Null
        $json = (Invoke-WebRequest -UseBasicParsing "https://meta.fabricmc.net/v2/versions/loader/$mc/$v/profile/json" -TimeoutSec 30).Content
        [IO.File]::WriteAllText($vjson, $json, (New-Object Text.UTF8Encoding($false)))
        return $vid
    }
    $had = @((Read-LauncherProfiles $mcDir).profiles.PSObject.Properties.Name) -contains $theirs
    $inst = Get-LoaderInstaller $li
    $java = Get-Java (Get-JavaMajor $mc)
    $log = Join-Path $Cache "game-install-$vid.log"
    $p = Start-Process -FilePath $java -ArgumentList @('-jar', "`"$inst`"", '--installClient', "`"$mcDir`"") -WorkingDirectory $Cache `
        -NoNewWindow -Wait -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
    if ($p.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $vjson)) { throw "게임용 $($li.loader) 설치에 실패했어요. 인터넷을 확인하고 다시 해 주세요. (기록: $log)" }
    Remove-Item -LiteralPath "$log.err" -ErrorAction SilentlyContinue
    # The installer adds its own bare "forge"/"NeoForge" entry; ours is the one to pick, so a beginner sees one clear choice
    if (-not $had) {
        $j = Read-LauncherProfiles $mcDir
        if ($j.profiles.PSObject.Properties[$theirs]) { $j.profiles.PSObject.Properties.Remove($theirs); Save-LauncherProfiles $mcDir $j }
    }
    return $vid
}

function Set-LauncherProfile([string]$mcDir, [string]$key, [string]$label, [string]$vid, [string]$gameDir, [int]$ramGB) {
    $j = Read-LauncherProfiles $mcDir
    if (-not $j.profiles) { $j | Add-Member -NotePropertyName profiles -NotePropertyValue ([pscustomobject]@{}) -Force }
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    $created = $now; $old = $j.profiles.PSObject.Properties[$key]; if ($old -and $old.Value.created) { $created = $old.Value.created }
    # "lastUsed = now" puts it at the top of the launcher's installation list
    $prof = [pscustomobject][ordered]@{
        name = $label; type = 'custom'; created = $created; lastUsed = $now; lastVersionId = $vid; gameDir = $gameDir; icon = 'Crafting_Table'
        javaArgs = "-Xmx${ramGB}G -XX:+UnlockExperimentalVMOptions -XX:+UseG1GC -XX:G1NewSizePercent=20 -XX:G1ReservePercent=20 -XX:MaxGCPauseMillis=50 -XX:G1HeapRegionSize=32M"
    }
    $j.profiles | Add-Member -NotePropertyName $key -NotePropertyValue $prof -Force
    Save-LauncherProfiles $mcDir $j
}

function Get-ModrinthVersion($pack, [string]$key) {
    # A version id, or (servers made before 1.0.5 kept only the label) the version number
    if ($key -match '^[A-Za-z0-9]{8}$') { try { return Invoke-RestMethod "https://api.modrinth.com/v2/version/$key" } catch { } }
    $vs = @(Invoke-RestMethod "https://api.modrinth.com/v2/project/$($pack.slug)/version" | ForEach-Object { $_ })
    $v = $vs | Where-Object { $_.version_number -eq $key } | Select-Object -First 1
    if (-not $v) { throw "모드팩 버전을 찾지 못했어요: $key" }
    return $v
}

function Get-ModrinthClient($ver, [string]$stage) {
    $f = $ver.files | Where-Object primary | Select-Object -First 1
    if (-not $f) { $f = $ver.files[0] }
    $mr = Join-Path $Cache $f.filename
    Step "모드팩 파일 받는 중 ($([math]::Round($f.size / 1MB)) MB)"
    Get-Download $f.url $mr -Sha512 $f.hashes.sha512
    $x = Join-Path $stage '_mrpack'
    [IO.Compression.ZipFile]::ExtractToDirectory($mr, $x)
    $idx = Get-Content (Join-Path $x 'modrinth.index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $deps = $idx.dependencies; $mc = $deps.minecraft
    if ($deps.forge) { $li = @{ loader = 'forge'; version = $deps.forge; mc = $mc } }
    elseif ($deps.neoforge) { $li = @{ loader = 'neoforge'; version = $deps.neoforge; mc = $mc } }
    elseif ($deps.'fabric-loader') { $li = @{ loader = 'fabric'; version = $deps.'fabric-loader'; mc = $mc } }
    else { throw '이 모드팩의 로더는 지원하지 않아요 (Forge/NeoForge/Fabric만 가능).' }
    # The game gets everything except what the pack marks as server-only
    $files = @($idx.files | Where-Object { -not $_.env -or $_.env.client -ne 'unsupported' })
    $sum = [long]0; foreach ($m in $files) { $sum += [long]$m.fileSize }
    Assert-FreeSpace ([long]($sum * 2.2) + 700MB)
    Step "게임용 모드 $($files.Count)개 받는 중"
    $cfg = New-Object System.Text.StringBuilder
    foreach ($m in $files) {
        if ($m.path -match '(^[\\/])|(\.\.)|(:)') { throw "잘못된 파일 경로가 들어 있어요: $($m.path)" }
        [void]$cfg.AppendLine("url = `"$($m.downloads[0])`"")
        [void]$cfg.AppendLine("output = `"$((Join-Path $stage $m.path) -replace '\\', '/')`"")
    }
    $cfgFile = Join-Path $x 'curl-list.txt'
    [IO.File]::WriteAllText($cfgFile, $cfg.ToString(), (New-Object Text.UTF8Encoding($false)))
    $cp = Start-Process curl.exe -ArgumentList @('-g', '-L', '--fail', '--retry', '3', '--create-dirs', '--parallel', '--parallel-max', '8', '-s', '-S', '-K', "`"$cfgFile`"") `
        -NoNewWindow -PassThru -RedirectStandardError (Join-Path $x 'curl-err.txt')
    $lastN = -1
    while (-not $cp.HasExited) {
        Start-Sleep -Seconds 2
        $n = @($files | Where-Object { Test-Path -LiteralPath (Join-Path $stage $_.path) }).Count
        if ($n -ne $lastN) { $lastN = $n; Info "모드 받는 중... $n / $($files.Count)" }
    }
    $bad = @($files | Where-Object { $o = Join-Path $stage $_.path; -not (Test-Path -LiteralPath $o) -or (Get-FileHash -LiteralPath $o -Algorithm SHA1).Hash -ne $_.hashes.sha1.ToUpper() } | ForEach-Object { $_.path })
    if ($bad.Count) { throw "모드 $($bad.Count)개를 제대로 받지 못했어요: $($bad[0..([Math]::Min(4, $bad.Count - 1))] -join ', ')" }
    foreach ($o in 'overrides', 'client-overrides') { $od = Join-Path $x $o; if (Test-Path -LiteralPath $od) { Copy-Tree $od $stage } }
    Remove-Item -LiteralPath $x -Recurse -Force
    return $li
}

function Get-ServerClient([string]$srv, [string]$stage) {
    # The host's own server already has every file: mods it runs, client-only mods it set aside, and the extra mods for friends
    $i = Get-Content -LiteralPath (Join-Path $srv 'server-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $mods = Join-Path $stage 'mods'; New-Item -ItemType Directory -Force $mods | Out-Null
    $serverOnly = @{}
    $aj = Join-Path $srv 'added-mods.json'
    if (Test-Path -LiteralPath $aj) { Get-Content -LiteralPath $aj -Raw -Encoding UTF8 | ConvertFrom-Json | ForEach-Object { $_ } | Where-Object { -not $_.forClient } | ForEach-Object { $serverOnly[$_.file] = $true } }
    Get-ChildItem -LiteralPath (Join-Path $srv 'mods') -Filter '*.jar' -File -ErrorAction SilentlyContinue | Where-Object { -not $serverOnly.ContainsKey($_.Name) } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $mods }
    Copy-FriendMods $srv $mods
    foreach ($d in $ClientDirs) { $p = Join-Path $srv $d; if (Test-Path -LiteralPath $p) { Copy-Tree $p (Join-Path $stage $d) } }
    return @{ loader = $i.loader; version = $i.loaderVersion; mc = $i.mc }
}
function Copy-FriendMods([string]$srv, [string]$mods) {
    foreach ($d in '_client_only_mods', '친구용_추가모드') {
        Get-ChildItem -LiteralPath (Join-Path $srv $d) -Filter '*.jar' -File -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $mods -Force }
    }
}

function Get-AddedClientMods([string]$b64, [string]$mods) {
    # Mods the host added by hand, named by Modrinth project and file so the friend gets the very same file
    if (-not $b64) { return }
    $parsed = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json
    New-Item -ItemType Directory -Force $mods | Out-Null
    foreach ($m in @($parsed)) {
        $projId = [string]$m.p; $file = [string]$m.f
        if ($projId -notmatch '^[A-Za-z0-9]{4,16}$' -or $file -notmatch '^[A-Za-z0-9 ._+()\[\]-]+\.jar$') { Info "이상한 추가 모드 정보는 건너뛰었어요: $file"; continue }
        $hit = $null
        foreach ($v in @(Invoke-RestMethod "https://api.modrinth.com/v2/project/$projId/version" | ForEach-Object { $_ })) {
            $hit = $v.files | Where-Object { $_.filename -eq $file } | Select-Object -First 1
            if ($hit) { break }
        }
        if (-not $hit) { Info "방장이 추가한 모드를 찾지 못했어요: $file (방장에게 그 파일을 받아서 mods 폴더에 넣어 주세요)"; continue }
        Get-Download $hit.url (Join-Path $mods $file) -Sha1 $hit.hashes.sha1
        Info "방장이 추가한 모드: $file"
    }
}

function Get-JarModInfo($zip, [string]$loader = 'forge') {
    # Mod ids a jar provides (nested jar-in-jar ones too) and the ones it needs on the game side
    # Multi-loader jars carry both mods.toml and fabric.mod.json; on Forge only mods.toml counts,
    # the Fabric list (fabric-only libraries) applies only to pure Fabric jars run through Connector
    $ids = New-Object System.Collections.Generic.List[string]; $deps = New-Object System.Collections.Generic.List[string]
    $fabricDeps = New-Object System.Collections.Generic.List[string]; $hasToml = $false
    $nested = New-Object System.Collections.Generic.List[string]   # jar-in-jar libraries: satisfy needs, but are shared, not duplicates
    foreach ($e in @($zip.Entries)) {
        $n = $e.FullName
        # Forge reads only mods.toml; NeoForge prefers neoforge.mods.toml, where a dependency without a type is required
        $tomlName = 'META-INF/mods.toml'; if ($loader -eq 'neoforge' -and $zip.GetEntry('META-INF/neoforge.mods.toml')) { $tomlName = 'META-INF/neoforge.mods.toml' }
        if ($n -eq $tomlName) {
            $hasToml = $true
            $sr = New-Object IO.StreamReader($e.Open()); $toml = $sr.ReadToEnd(); $sr.Dispose()
            $sect = ''; $dep = $null
            foreach ($ln in ($toml -split "`n")) {
                $l = $ln.Trim()
                if ($l -match '^\[\[\s*mods\s*\]\]') { $sect = 'mods'; continue }
                if ($l -match '^\[\[\s*dependencies\.') { if ($dep) { $deps.AddRange([string[]]@(Resolve-TomlDep $dep $tomlName)) }; $sect = 'dep'; $dep = @{}; continue }
                if ($l -match '^\[') { if ($dep) { $deps.AddRange([string[]]@(Resolve-TomlDep $dep $tomlName)) }; $dep = $null; $sect = ''; continue }
                if ($sect -eq 'mods' -and $l -match '^modId\s*=\s*"([^"]+)"') { $ids.Add($Matches[1]) }
                if ($sect -eq 'dep' -and $l -match '^(modId|mandatory|type|side)\s*=\s*"?([^"#\s]+)"?') { $dep[$Matches[1]] = $Matches[2] }
            }
            if ($dep) { $deps.AddRange([string[]]@(Resolve-TomlDep $dep $tomlName)) }
        }
        elseif ($n -eq 'fabric.mod.json') {
            $sr = New-Object IO.StreamReader($e.Open()); $fj = $sr.ReadToEnd(); $sr.Dispose()
            try {
                $o = $fj | ConvertFrom-Json
                if ($o.id) { $ids.Add([string]$o.id) }
                foreach ($pv in @($o.provides)) { if ($pv) { $ids.Add([string]$pv) } }
                if ($o.depends -and "$($o.environment)" -ne 'server') { foreach ($p in $o.depends.PSObject.Properties) { $fabricDeps.Add($p.Name) } }
            }
            catch { }
        }
        elseif ($n -match '^META-INF/(jarjar|jars)/[^/]+\.jar$') {
            $ms = New-Object IO.MemoryStream; $s = $e.Open(); $s.CopyTo($ms); $s.Dispose()
            try { $inner = New-Object IO.Compression.ZipArchive($ms); $r = Get-JarModInfo $inner $loader; $nested.AddRange([string[]]@($r.ids)); $nested.AddRange([string[]]@($r.nested)); $inner.Dispose() } catch { }
        }
    }
    if (-not $hasToml) { $deps.AddRange($fabricDeps) }
    return @{ ids = @($ids); deps = @($deps); nested = @($nested) }
}
function Resolve-TomlDep($dep, [string]$tomlName) {
    # Forge writes mandatory=true, NeoForge type="required" (or no type at all); server-only needs don't matter to the game
    $need = ($dep['mandatory'] -eq 'true') -or ($dep['type'] -eq 'required') -or ($tomlName -like '*neoforge*' -and -not $dep['type'])
    if ($need -and $dep['modId'] -and "$($dep['side'])" -ne 'SERVER') { return $dep['modId'] }
    return @()
}

function Remove-ServerOnlyMods([string]$mods) {
    # Server packs carry server-only mods (servercore and the like) that have no business in a game; Modrinth knows which they are
    $jars = @(Get-ChildItem -LiteralPath $mods -Filter '*.jar' -File)
    if (-not $jars.Count) { return }
    $byHash = @{}; foreach ($j in $jars) { $byHash[(Get-FileHash -LiteralPath $j.FullName -Algorithm SHA1).Hash.ToLower()] = $j }
    try { $vers = Invoke-RestMethod -Method Post -Uri 'https://api.modrinth.com/v2/version_files' -ContentType 'application/json' -Body (@{ hashes = @($byHash.Keys); algorithm = 'sha1' } | ConvertTo-Json) -TimeoutSec 60 }
    catch { return }
    $projOf = @{}; foreach ($p in $vers.PSObject.Properties) { $projOf[$p.Name] = $p.Value.project_id }
    $ids = @($projOf.Values | Sort-Object -Unique)
    $serverOnly = @{}
    for ($i = 0; $i -lt $ids.Count; $i += 100) {
        $chunk = $ids[$i..([Math]::Min($i + 99, $ids.Count - 1))]
        try { $res = Invoke-RestMethod ("https://api.modrinth.com/v2/projects?ids=" + [uri]::EscapeDataString('["' + ($chunk -join '","') + '"]')) } catch { continue }
        foreach ($pr in $res) { if ($pr.client_side -eq 'unsupported') { $serverOnly[$pr.id] = $pr.title } }
    }
    if (-not $serverOnly.Count) { return }
    $park = Join-Path (Split-Path $mods -Parent) '_server_only_mods'
    New-Item -ItemType Directory -Force $park | Out-Null
    # Modrinth's flag alone is not enough (FarmersStructures is "server only" there, yet Forge refuses a game without it):
    # a jar also has to declare itself optional for the game with displayTest IGNORE_SERVER_VERSION / IGNORE_ALL_VERSION
    $moved = @()
    foreach ($h in $projOf.Keys) {
        if (-not $serverOnly.ContainsKey($projOf[$h])) { continue }
        $jar = $byHash[$h]; $z = $null; $optional = $false
        try {
            $z = [IO.Compression.ZipFile]::OpenRead($jar.FullName)
            foreach ($tn in 'META-INF/mods.toml', 'META-INF/neoforge.mods.toml') {
                $e = $z.GetEntry($tn); if (-not $e) { continue }
                $sr = New-Object IO.StreamReader($e.Open()); $toml = $sr.ReadToEnd(); $sr.Dispose()
                if ($toml -match '(?m)^\s*displayTest\s*=\s*"IGNORE_(SERVER|ALL)_VERSION"') { $optional = $true }
            }
        }
        catch { }
        finally { if ($z) { $z.Dispose() } }
        if ($optional) { Move-Item -LiteralPath $jar.FullName -Destination $park -Force; $moved += $serverOnly[$projOf[$h]] }
    }
    if ($moved.Count) { Info "서버 전용 모드 $($moved.Count)개는 게임에 필요 없어서 뺐어요: $(@($moved | Select-Object -First 5) -join ', ')" }
}

function Add-MissingClientDeps([string]$mods, $li) {
    # A server pack lacks client-only mods, yet some of its mods still require one on the game side
    # (immersivelanterns -> sodiumdynamiclights). The requiring mod's Modrinth page names its dependencies;
    # a candidate is kept only if its jar really provides the missing id.
    $addedVersions = New-Object System.Collections.Generic.List[object]; $provided = @{}; $top = @{}
    $builtin = @{}; foreach ($b in 'minecraft', 'forge', 'neoforge', 'java', 'fabricloader', 'fabric', 'fabric-api', 'fabric-api-base', 'connectormod', 'mixinextras', 'fml', 'javafml') { $builtin[$b] = $true }
    for ($round = 1; $round -le 5; $round++) {
        $provided = @{}; $top = @{}; $needs = @{}
        foreach ($jar in @(Get-ChildItem -LiteralPath $mods -Filter '*.jar' -File)) {
            $z = $null
            try {
                $z = [IO.Compression.ZipFile]::OpenRead($jar.FullName)
                $r = Get-JarModInfo $z $li.loader
                foreach ($i in $r.ids) { $provided[$i] = $true; $top[$i] = $true }
                foreach ($i in $r.nested) { $provided[$i] = $true }
                foreach ($d in $r.deps) { if (-not $needs.ContainsKey($d)) { $needs[$d] = New-Object System.Collections.Generic.List[string] }; $needs[$d].Add($jar.FullName) }
            }
            catch { }
            finally { if ($z) { $z.Dispose() } }
        }
        $missing = @($needs.Keys | Where-Object { -not $provided.ContainsKey($_) -and -not $builtin.ContainsKey($_) -and $_ -notlike 'fabric-*' })
        if (-not $missing.Count) { break }
        # Something set aside as server-only turns out to be needed after all: put it back rather than download another copy
        $park = Join-Path (Split-Path $mods -Parent) '_server_only_mods'
        $back = 0
        foreach ($pj in @(Get-ChildItem -LiteralPath $park -Filter '*.jar' -File -ErrorAction SilentlyContinue)) {
            $z = $null; $gives = @()
            try { $z = [IO.Compression.ZipFile]::OpenRead($pj.FullName); $gives = @((Get-JarModInfo $z $li.loader).ids) } catch { } finally { if ($z) { $z.Dispose() } }
            if (@($missing | Where-Object { $_ -in $gives }).Count) { Move-Item -LiteralPath $pj.FullName -Destination $mods -Force; $back++ }
        }
        if ($back) { Info "다른 모드가 꼭 필요로 해서 $($back)개는 다시 넣었어요."; continue }
        Step "빠진 필수 모드 찾는 중: $($missing -join ', ')"
        $askers = @($missing | ForEach-Object { $needs[$_] } | Sort-Object -Unique)
        $hashes = @($askers | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA1).Hash.ToLower() })
        $found = 0
        try { $vers = Invoke-RestMethod -Method Post -Uri 'https://api.modrinth.com/v2/version_files' -ContentType 'application/json' -Body (@{ hashes = $hashes; algorithm = 'sha1' } | ConvertTo-Json) }
        catch { Info '(Modrinth에 물어보지 못했어요)'; return }
        $projects = @(foreach ($p in $vers.PSObject.Properties) { foreach ($d in @($p.Value.dependencies)) { if ($d.dependency_type -eq 'required' -and $d.project_id) { $d.project_id } } }) | Sort-Object -Unique
        $loaders = @($li.loader); if ($provided.ContainsKey('connectormod')) { $loaders += 'fabric' }
        foreach ($proj in $projects) {
            if (-not @($missing | Where-Object { -not $provided.ContainsKey($_) }).Count) { break }
            $q = '?loaders=' + [uri]::EscapeDataString((ConvertTo-Json -InputObject @($loaders) -Compress)) + '&game_versions=' + [uri]::EscapeDataString("[`"$($li.mc)`"]")
            try { $v = @(Invoke-RestMethod "https://api.modrinth.com/v2/project/$proj/version$q" | ForEach-Object { $_ }) | Select-Object -First 1 } catch { continue }
            if (-not $v) { continue }
            $f = $v.files | Where-Object primary | Select-Object -First 1; if (-not $f) { $f = $v.files[0] }
            if ($f.filename -notmatch '^[A-Za-z0-9 ._+()\[\]-]+\.jar$' -or (Test-Path -LiteralPath (Join-Path $mods $f.filename))) { continue }
            $tmpJar = Join-Path $mods "$($f.filename).check"
            try { Get-Download $f.url $tmpJar -Sha1 $f.hashes.sha1 } catch { continue }
            $z = $null; $gives = @()
            try { $z = [IO.Compression.ZipFile]::OpenRead($tmpJar); $gives = @((Get-JarModInfo $z $li.loader).ids) } catch { } finally { if ($z) { $z.Dispose() } }
            $hit = @($missing | Where-Object { $_ -in $gives })
            if ($hit.Count) {
                Move-Item -LiteralPath $tmpJar -Destination (Join-Path $mods $f.filename) -Force
                foreach ($g in $gives) { $provided[$g] = $true; $top[$g] = $true }
                Info "빠져 있던 필수 모드를 넣었어요: $($f.filename) ($($hit -join ', '))"
                $addedVersions.Add($v); $found++
            }
            else { Remove-Item -LiteralPath $tmpJar -Force -ErrorAction SilentlyContinue }
        }
        if (-not $found) {
            Info "필수 모드를 찾지 못했어요: $($missing -join ', ') (게임이 안 켜지면 이 이름을 도와줄 사람에게 알려 주세요)"
            break
        }
    }
    # What was added may itself need mods no mods.toml names (sodium-options-api -> embeddium): follow Modrinth's
    # own "required" list. A candidate whose mod id is already here is dropped, so nothing gets loaded twice.
    $queue = New-Object System.Collections.Generic.Queue[string]; $seen = @{}
    foreach ($av in $addedVersions) { foreach ($d in @($av.dependencies)) { if ($d.dependency_type -eq 'required' -and $d.project_id) { $queue.Enqueue($d.project_id) } } }
    $loaders = @($li.loader); if ($provided.ContainsKey('connectormod')) { $loaders += 'fabric' }
    $q = '?loaders=' + [uri]::EscapeDataString((ConvertTo-Json -InputObject @($loaders) -Compress)) + '&game_versions=' + [uri]::EscapeDataString("[`"$($li.mc)`"]")
    while ($queue.Count -and $seen.Count -lt 20) {
        $proj = $queue.Dequeue(); if ($seen.ContainsKey($proj)) { continue }; $seen[$proj] = $true
        try { $v = @(Invoke-RestMethod "https://api.modrinth.com/v2/project/$proj/version$q" | ForEach-Object { $_ }) | Select-Object -First 1 } catch { continue }
        if (-not $v) { continue }
        $f = $v.files | Where-Object primary | Select-Object -First 1; if (-not $f) { $f = $v.files[0] }
        if ($f.filename -notmatch '^[A-Za-z0-9 ._+()\[\]-]+\.jar$' -or (Test-Path -LiteralPath (Join-Path $mods $f.filename))) { continue }
        $tmpJar = Join-Path $mods "$($f.filename).check"
        try { Get-Download $f.url $tmpJar -Sha1 $f.hashes.sha1 } catch { continue }
        $z = $null; $gives = @()
        try { $z = [IO.Compression.ZipFile]::OpenRead($tmpJar); $gives = @((Get-JarModInfo $z $li.loader).ids) } catch { } finally { if ($z) { $z.Dispose() } }
        if (-not $gives.Count -or @($gives | Where-Object { $top.ContainsKey($_) }).Count) { Remove-Item -LiteralPath $tmpJar -Force -ErrorAction SilentlyContinue; continue }
        Move-Item -LiteralPath $tmpJar -Destination (Join-Path $mods $f.filename) -Force
        foreach ($g in $gives) { $provided[$g] = $true; $top[$g] = $true }
        Info "같이 필요한 모드도 넣었어요: $($f.filename)"
        foreach ($d in @($v.dependencies)) { if ($d.dependency_type -eq 'required' -and $d.project_id) { $queue.Enqueue($d.project_id) } }
    }
}

function Test-WeakPc {
    # Integrated graphics (the GPU borrows system RAM and is slow) or 16GB or less: a big modpack needs lighter settings
    $ram = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
    $discrete = @($gpus | Where-Object { $_ -match 'GeForce|RTX|GTX|Quadro|Radeon RX|Radeon Pro|Arc A|Arc B' }).Count -gt 0
    return ($ram -le 16.5) -or (-not $discrete)
}
function Set-LightOptions([string]$opt) {
    # Only the heavy switches; the player's keys, sound, language and the rest stay as they are
    $light = [ordered]@{ renderDistance = '8'; simulationDistance = '6'; graphicsMode = '0'; particles = '1'; entityShadows = 'false'; biomeBlendRadius = '0'
        renderClouds = '"false"'; mipmapLevels = '2'; enableVsync = 'false'; maxFps = '60'; entityDistanceScaling = '0.75'; ao = 'false' }
    $lines = @(); if (Test-Path -LiteralPath $opt) { $lines = @([IO.File]::ReadAllLines($opt)) }
    $seen = @{}
    $out = foreach ($l in $lines) { if ($l -match '^([A-Za-z]+):' -and $light.Contains($Matches[1])) { $seen[$Matches[1]] = $true; "$($Matches[1]):$($light[$Matches[1]])" } else { $l } }
    $out = @($out) + @($light.Keys | Where-Object { -not $seen.ContainsKey($_) } | ForEach-Object { "$($_):$($light[$_])" })
    if (-not ($out | Where-Object { $_ -match '^lang:' })) { $out += 'lang:ko_kr' }
    if (Test-Path -LiteralPath $opt) { Copy-Item -LiteralPath $opt -Destination "$opt.before-light" -Force }
    [IO.File]::WriteAllLines($opt, [string[]]$out, (New-Object Text.UTF8Encoding($false)))
}
function Add-PerformanceMods([string]$mods, $li) {
    # A game built from a server pack misses the pack's client-side frame-rate mods; EntityCulling is the big, safe one
    $have = @{}
    foreach ($jar in @(Get-ChildItem -LiteralPath $mods -Filter '*.jar' -File)) {
        $z = $null; try { $z = [IO.Compression.ZipFile]::OpenRead($jar.FullName); foreach ($i in (Get-JarModInfo $z $li.loader).ids) { $have[$i] = $true } } catch { } finally { if ($z) { $z.Dispose() } }
    }
    foreach ($w in @(@{ slug = 'entityculling'; id = 'entityculling' })) {
        if ($have.ContainsKey($w.id)) { continue }
        $q = '?loaders=' + [uri]::EscapeDataString("[`"$($li.loader)`"]") + '&game_versions=' + [uri]::EscapeDataString("[`"$($li.mc)`"]")
        try { $v = @(Invoke-RestMethod "https://api.modrinth.com/v2/project/$($w.slug)/version$q" | ForEach-Object { $_ }) | Where-Object { $_.version_type -eq 'release' } | Select-Object -First 1 } catch { continue }
        if (-not $v) { continue }
        $f = $v.files | Where-Object primary | Select-Object -First 1; if (-not $f) { $f = $v.files[0] }
        try { Get-Download $f.url (Join-Path $mods $f.filename) -Sha1 $f.hashes.sha1; Info "프레임을 올려 주는 모드를 넣었어요: $($f.filename)" } catch { }
    }
}

function Install-Client($pack) {
    if ($Name -notmatch '^[A-Za-z0-9]([A-Za-z0-9 ._-]{0,58}[A-Za-z0-9_-])?$') { throw "이름으로 쓸 수 없어요: '$Name'" }
    if ($Address -notmatch '^[A-Za-z0-9.-]+(:\d{1,5})?$') { throw "서버 주소가 이상해요: '$Address'" }
    $gameRoot = Join-Path $Root 'game'
    $gd = $GameDir; if (-not $gd) { $gd = Join-Path $gameRoot $Name }
    $gd = [IO.Path]::GetFullPath($gd)
    if (-not $gd.StartsWith($gameRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "게임 폴더 위치가 이상해요: $gd" }
    $mcDir = Get-McDir
    $host_ = [bool]$FromServer
    Write-Host "게임 준비: $($pack.name)  ($Name)" -ForegroundColor Yellow
    # One copy of the launcher's own list, from before this program ever touched it
    $pf = Join-Path $mcDir 'launcher_profiles.json'
    if (-not (Test-Path -LiteralPath "$pf.mcsm-backup")) { Copy-Item -LiteralPath $pf -Destination "$pf.mcsm-backup" }
    New-Item -ItemType Directory -Force $gd | Out-Null
    $markerFile = Join-Path $gd 'mcsm-game.json'
    $old = $null; if (Test-Path -LiteralPath $markerFile) { try { $old = Get-Content -LiteralPath $markerFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }

    # Unchanged pack, version and mods: skip straight to the launcher
    if ($host_) {
        $info = Get-Content -LiteralPath (Join-Path $FromServer 'server-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $verLabel = $info.version
        $jars = foreach ($d in 'mods', '_client_only_mods', '친구용_추가모드') { Get-ChildItem -LiteralPath (Join-Path $FromServer $d) -Filter '*.jar' -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name):$($_.Length)" } }
        $sigSrc = "$($pack.id)|$verLabel|" + ((@($jars) | Sort-Object) -join ',')
    }
    else { $verLabel = $VersionKey; $sigSrc = "$($pack.id)|$VersionKey|$AddedMods" }
    # Bumped whenever the way the game folder is built changes, so existing game folders get rebuilt once
    $sigSrc = "build4|$sigSrc"
    $sha = [Security.Cryptography.SHA256]::Create()
    $sig = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sigSrc)) | ForEach-Object { $_.ToString('x2') })

    if ($old -and $old.sig -eq $sig -and $old.versionId -and (Test-Path -LiteralPath (Join-Path $gd 'mods')) -and (Test-Path -LiteralPath (Join-Path $mcDir "versions\$($old.versionId)\$($old.versionId).json"))) {
        Info '게임 파일은 이미 서버와 똑같아요.'
        $vid = $old.versionId; $li = @{ loader = $old.loader; version = $old.loaderVersion; mc = $old.mc }; $verLabel = $old.version
    }
    else {
        $script:tmp = Join-Path $Cache ('g' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Force $script:tmp | Out-Null
        if ($host_ -and $pack.source -eq 'modrinth') {
            $key = $info.version; if ($info.PSObject.Properties['versionKey'] -and $info.versionKey) { $key = $info.versionKey }
            $li = Get-ModrinthClient (Get-ModrinthVersion $pack $key) $script:tmp
            Copy-FriendMods $FromServer (Join-Path $script:tmp 'mods')
        }
        elseif ($host_) { $li = Get-ServerClient $FromServer $script:tmp }
        # A friend installs CurseForge modpacks with CurseForge's own app (the manager shows how); files are not fetched for them here
        elseif ($pack.source -eq 'curseforge') { throw 'CurseForge 모드팩은 CurseForge 앱으로 설치해요. [친구 서버 들어가기] 탭에서 [▶ 설치하고 게임 켜기]를 누르면 순서를 알려 줘요.' }
        else { $ver = Get-ModrinthVersion $pack $VersionKey; $verLabel = $ver.version_number; $li = Get-ModrinthClient $ver $script:tmp }
        if ($li.version -notmatch '^[A-Za-z0-9._+-]+$' -or "$($li.mc)" -notmatch '^[0-9][0-9.]*$') { throw "모드팩 안의 버전 정보가 이상해요 (마인크래프트 '$($li.mc)', 로더 '$($li.version)')." }
        Get-AddedClientMods $AddedMods (Join-Path $script:tmp 'mods')
        New-Item -ItemType Directory -Force (Join-Path $script:tmp 'mods') | Out-Null
        Step '게임에 맞게 모드 정리하는 중'
        Remove-ServerOnlyMods (Join-Path $script:tmp 'mods')
        Add-MissingClientDeps (Join-Path $script:tmp 'mods') $li
        if ($pack.source -ne 'modrinth') { Add-PerformanceMods (Join-Path $script:tmp 'mods') $li }

        Step '게임 폴더에 넣는 중'
        # mods is replaced as a whole (old versions must go); configs are laid over; worlds, screenshots and settings stay
        $gm = Join-Path $gd 'mods'
        if (Test-Path -LiteralPath $gm) { Remove-Item -LiteralPath $gm -Recurse -Force }
        if (Test-Path -LiteralPath (Join-Path $script:tmp 'mods')) { Move-Item -LiteralPath (Join-Path $script:tmp 'mods') -Destination $gm } else { New-Item -ItemType Directory -Force $gm | Out-Null }
        Get-ChildItem -LiteralPath $script:tmp -Directory | ForEach-Object { Copy-Tree $_.FullName (Join-Path $gd $_.Name) }
        # A pack's own options.txt / servers.dat only seed a new folder; they never replace the player's
        Get-ChildItem -LiteralPath $script:tmp -File | Where-Object { -not ($_.Name -in 'options.txt', 'servers.dat' -and (Test-Path -LiteralPath (Join-Path $gd $_.Name))) } |
            ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $gd -Force }
        Remove-Item -LiteralPath $script:tmp -Recurse -Force; $script:tmp = $null
        Info "모드 $(@(Get-ChildItem -LiteralPath $gm -Filter '*.jar').Count)개 준비 완료"
        $vid = Install-ClientLoader $li $mcDir
    }

    Step '마인크래프트 런처에 등록하는 중'
    $profKey = 'mcsm-' + (((Split-Path $gd -Leaf).ToLower() -replace '[^a-z0-9]+', '-').Trim('-'))
    $label = "모드팩: $($pack.name) ($Name)"
    Set-LauncherProfile $mcDir $profKey $label $vid $gd $GameRamGB
    Add-NbtHelper
    $entry = "$Name (친구 서버)"; if ($host_) { $entry = "$Name (내 서버)" }
    [McsmNbt]::UpsertServer((Join-Path $gd 'servers.dat'), $entry, $Address)
    # A fresh game folder starts in Korean; afterwards the player's own settings are left alone
    $opt = Join-Path $gd 'options.txt'
    if (-not (Test-Path -LiteralPath $opt)) { [IO.File]::WriteAllText($opt, "lang:ko_kr`r`n", (New-Object Text.UTF8Encoding($false))) }
    # Weaker PCs get lighter graphics once (a backup is kept); later changes in the game's own settings are left alone
    $light = $old -and $old.PSObject.Properties['light'] -and $old.light
    if (-not $light -and (Test-WeakPc)) {
        Set-LightOptions $opt; $light = $true
        Info '이 컴퓨터(내장 그래픽 또는 램 16GB 이하)에 맞게 게임 그래픽을 가볍게 바꿨어요. 게임 안 [설정]에서 언제든 바꿀 수 있어요.'
    }
    [ordered]@{
        kind = $(if ($host_) { 'host' } else { 'friend' }); name = $Name; pack = $pack.id; packName = $pack.name; version = $verLabel; versionKey = $VersionKey
        versionId = $vid; loader = $li.loader; loaderVersion = $li.version; mc = $li.mc; address = $Address; addedMods = $AddedMods
        profile = $profKey; profileName = $label; serverEntry = $entry; sig = $sig; light = [bool]$light; ramGB = $GameRamGB; installed = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    } | ConvertTo-Json | Set-Content -LiteralPath $markerFile -Encoding UTF8
    Write-Host ''
    Write-Host '==================================================' -ForegroundColor Green
    Write-Host "  게임 준비 완료! 런처에서 '$label' 을(를) 고르고 [플레이]" -ForegroundColor Green
    Write-Host "  → 멀티플레이 → '$entry' 접속" -ForegroundColor Green
    Write-Host '==================================================' -ForegroundColor Green
}

try {
    $packsDoc = Get-Content (Join-Path $Prog 'packs.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $packs = @($packsDoc.packs | ForEach-Object { $_ })
    $pack = $packs | Where-Object id -eq $PackId
    $builtIn = [bool]$pack
    $customFile = Join-Path $Prog 'custom-packs.json'
    if (-not $pack -and (Test-Path -LiteralPath $customFile)) {
        # Packs the user added; their CurseForge server packs may only come from CurseForge's own file server
        $pack = (Get-Content -LiteralPath $customFile -Raw -Encoding UTF8 | ConvertFrom-Json).packs | ForEach-Object { $_ } | Where-Object id -eq $PackId | Select-Object -First 1
        if ($pack -and $pack.source -eq 'curseforge' -and @($pack.versions | Where-Object { $_.url -notmatch '^https://(mediafilez|edge)\.forgecdn\.net/files/\d+/\d+/[^/?#]+$' }).Count) { throw '직접 추가한 모드팩의 다운로드 주소가 CurseForge가 아니에요.' }
        if ($pack -and $pack.source -eq 'modrinth' -and "$($pack.slug)" -notmatch '^[A-Za-z0-9_-]{2,64}$') { throw '직접 추가한 모드팩 정보가 이상해요.' }
    }
    if (-not $pack) { throw "목록에 없는 모드팩이에요: $PackId" }
    if ($Client) {
        Install-Client $pack
        $result = 'ok'
    }
    else {
    # ----- server install (the rest of this block) -----

    if ($Name -notmatch '^[A-Za-z0-9]([A-Za-z0-9 ._-]{0,58}[A-Za-z0-9_-])?$' -or ($Name -split '\.')[0].Trim() -match '^(?i)(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])$') {
        throw "서버 이름으로 쓸 수 없어요: '$Name'"
    }
    $finalName = $Name
    if ($Update) {
        $oldDir = Join-Path $ServersDir $Name
        if (-not (Test-Path -LiteralPath (Join-Path $oldDir '서버켜기.bat'))) { throw "업데이트할 서버를 찾지 못했어요: $Name" }
        $oldInfo = Get-Content -LiteralPath (Join-Path $oldDir 'server-info.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        # The new version goes into a side folder first; the old server stays untouched until everything worked
        $Name = 'upd-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    }
    $dir = Join-Path $ServersDir $Name
    # ".installing" marks a folder whose install never finished (window closed, PC turned off)
    if (Test-Path -LiteralPath (Join-Path $dir '.installing')) {
        Info '지난번에 끝나지 못한 설치를 정리하고 다시 시작해요.'
        Remove-Item -LiteralPath $dir -Recurse -Force
    }
    if ((Test-Path -LiteralPath $dir) -and (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) { throw "'$Name' 폴더가 이미 있어요. 다른 서버 이름을 써 주세요." }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $createdDir = $dir   # removed again if the install fails, so the same name can be retried
    $upOf = ''; if ($Update) { $upOf = $finalName }
    Set-Content -LiteralPath (Join-Path $dir '.installing') -Value "update-of=$upOf" -Encoding UTF8
    if ($Update) {
        try { $host.UI.RawUI.WindowTitle = "모드팩 업데이트 중: $finalName" } catch { }
        Write-Host "모드팩 업데이트: $($pack.name)  $($oldInfo.version) -> 새 버전" -ForegroundColor Yellow
        Write-Host "서버: $oldDir" -ForegroundColor Yellow
    }
    else {
        try { $host.UI.RawUI.WindowTitle = "서버 만드는 중: $Name" } catch { }
        Write-Host "모드팩: $($pack.name)" -ForegroundColor Yellow
        Write-Host "설치 위치: $dir" -ForegroundColor Yellow
    }

    # Short scratch path: some packs nest files deep enough to hit the 260-character path limit
    $tmp = Join-Path $Cache ('x' + [guid]::NewGuid().ToString('N').Substring(0, 6))
    $verLabel = $VersionKey
    $li = $null

    if ($pack.source -eq 'curseforge') {
        $ver = $pack.versions | Where-Object label -eq $VersionKey
        if (-not $ver) { throw "버전을 찾지 못했어요: $VersionKey" }
        Step "서버팩 받는 중 ($([math]::Round($ver.size / 1GB, 2)) GB, 몇 분 걸려요)"
        $zip = Join-Path $Cache ([uri]::UnescapeDataString(($ver.url -split '/')[-1]))
        # Room for the zip (unless already cached), the unpacked server, and Java/loader files on top
        $need = [long]($ver.size * 1.6) + 700MB
        if (-not ((Test-Path -LiteralPath $zip) -and (Get-Item -LiteralPath $zip).Length -eq $ver.size)) { $need += $ver.size }
        Assert-FreeSpace $need
        # sha256 is recorded for versions whose server pack was downloaded and checked once; the rest rely on size and HTTPS
        $sha = ''; if ($ver.PSObject.Properties['sha256']) { $sha = [string]$ver.sha256 }
        Get-Download $ver.url $zip -Size $ver.size -Sha256 $sha

        Step '압축 푸는 중'
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        $src = $tmp
        $top = @(Get-ChildItem $tmp -Force)
        if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $src = $top[0].FullName }
        Get-ChildItem -LiteralPath $src -Force | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $dir }
        Remove-Item -Recurse -Force $tmp

        # Keep the pack's own launch scripts out of the way so only 서버켜기.bat is visible
        $orig = Join-Path $dir '_pack_original_files'
        $own = Get-ChildItem $dir -File | Where-Object { $_.Name -match '^(start|run|startserver|install_java).*\.(bat|sh|ps1|command)$' -or $_.Name -in 'variables.txt', 'HOW-TO-RUN.md' }
        $li = Find-Loader $dir $pack
        if ($own) { New-Item -ItemType Directory -Force $orig | Out-Null; $own | Move-Item -Destination $orig }
    }
    else {
        Step 'Modrinth에서 버전 정보 확인 중'
        $ver = Invoke-RestMethod "https://api.modrinth.com/v2/version/$VersionKey"
        $verLabel = $ver.version_number
        $f = $ver.files | Where-Object primary | Select-Object -First 1
        if (-not $f) { $f = $ver.files[0] }
        $mr = Join-Path $Cache $f.filename
        Step "모드팩 파일 받는 중 ($([math]::Round($f.size / 1MB)) MB)"
        Get-Download $f.url $mr -Sha512 $f.hashes.sha512

        [IO.Compression.ZipFile]::ExtractToDirectory($mr, $tmp)
        $idx = Get-Content (Join-Path $tmp 'modrinth.index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $deps = $idx.dependencies
        $mc = $deps.minecraft
        if ($deps.forge) { $li = @{ loader = 'forge'; version = $deps.forge; mc = $mc } }
        elseif ($deps.neoforge) { $li = @{ loader = 'neoforge'; version = $deps.neoforge; mc = $mc } }
        elseif ($deps.'fabric-loader') { $li = @{ loader = 'fabric'; version = $deps.'fabric-loader'; mc = $mc } }
        else { throw '이 모드팩의 로더는 지원하지 않아요 (Forge/NeoForge/Fabric만 가능).' }

        $files = @($idx.files | Where-Object { -not $_.env -or $_.env.server -ne 'unsupported' })

        # Pack authors often mark client-only mods as server-required; ask Modrinth what each project really supports
        $pids = @($files | ForEach-Object { if ($_.downloads[0] -match 'cdn\.modrinth\.com/data/([A-Za-z0-9]+)/') { $Matches[1] } } | Sort-Object -Unique)
        $clientOnly = @{}
        for ($i = 0; $i -lt $pids.Count; $i += 100) {
            $chunk = $pids[$i..([Math]::Min($i + 99, $pids.Count - 1))]
            $q = [uri]::EscapeDataString('["' + ($chunk -join '","') + '"]')
            # Assign first: PS 5.1 emits a JSON array as one pipeline object
            $res = Invoke-RestMethod "https://api.modrinth.com/v2/projects?ids=$q"
            foreach ($pr in $res) {
                if ($pr.server_side -eq 'unsupported') { $clientOnly[$pr.id] = $pr.title }
            }
        }
        $files = @($files | Where-Object {
                if ($_.downloads[0] -match 'cdn\.modrinth\.com/data/([A-Za-z0-9]+)/' -and $clientOnly.ContainsKey($Matches[1])) { $false } else { $true } })
        if ($clientOnly.Count) { Info "화면 전용 모드 $($clientOnly.Count)개는 서버에 필요 없어서 뺐어요: $(($clientOnly.Values | Select-Object -First 6) -join ', ')..." }

        $sum = [long]0; foreach ($m in $files) { $sum += [long]$m.fileSize }
        Assert-FreeSpace ([long]($sum * 1.3) + 700MB)
        Step "서버용 모드 $($files.Count)개 받는 중"
        $cfg = New-Object System.Text.StringBuilder
        foreach ($m in $files) {
            if ($m.path -match '(^[\\/])|(\.\.)|(:)') { throw "잘못된 파일 경로가 들어 있어요: $($m.path)" }
            $out = Join-Path $dir $m.path
            [void]$cfg.AppendLine("url = `"$($m.downloads[0])`"")
            [void]$cfg.AppendLine("output = `"$($out -replace '\\', '/')`"")
        }
        $cfgFile = Join-Path $tmp 'curl-list.txt'
        [IO.File]::WriteAllText($cfgFile, $cfg.ToString(), (New-Object Text.UTF8Encoding($false)))
        # Parallel download in the background, with a progress line every few seconds for the manager window
        $cp = Start-Process curl.exe -ArgumentList @('-g', '-L', '--fail', '--retry', '3', '--create-dirs', '--parallel', '--parallel-max', '8', '-s', '-S', '-K', "`"$cfgFile`"") `
            -NoNewWindow -PassThru -RedirectStandardError (Join-Path $tmp 'curl-err.txt')
        $lastN = -1
        while (-not $cp.HasExited) {
            Start-Sleep -Seconds 2
            $n = @($files | Where-Object { Test-Path -LiteralPath (Join-Path $dir $_.path) }).Count
            if ($n -ne $lastN) { $lastN = $n; Info "모드 받는 중... $n / $($files.Count)" }
        }
        $bad = @()
        foreach ($m in $files) {
            $out = Join-Path $dir $m.path
            if (-not (Test-Path -LiteralPath $out) -or (Get-FileHash -LiteralPath $out -Algorithm SHA1).Hash -ne $m.hashes.sha1.ToUpper()) { $bad += $m.path }
        }
        if ($bad.Count) { throw "모드 $($bad.Count)개를 제대로 받지 못했어요: $($bad[0..([Math]::Min(4, $bad.Count - 1))] -join ', ')" }
        Info "모드 $($files.Count)개 확인 완료"

        foreach ($o in 'overrides', 'server-overrides') {
            $od = Join-Path $tmp $o
            if (Test-Path $od) {
                # robocopy copes with paths past the 260-character limit; exit codes below 8 mean success
                & robocopy.exe $od $dir /E /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "모드팩 설정 파일을 복사하지 못했어요 ($o)." }
            }
        }
        Remove-Item -Recurse -Force $tmp

        # Second pass over every jar (overrides can carry jars Modrinth knows nothing about):
        # a Fabric jar that declares environment=client, or a mod ID on client-only-mods.txt, is parked.
        # Forge/NeoForge packs can carry Fabric jars too (via Sinytra Connector), so this runs for every loader.
        $denyIds = @{}
        Get-Content (Join-Path $Prog 'client-only-mods.txt') | Where-Object { $_ -match '^\s*[a-z0-9_\-]+\s*$' } | ForEach-Object { $denyIds[$_.Trim()] = $true }
        $park = Join-Path $dir '_client_only_mods'
        foreach ($jar in Get-ChildItem -LiteralPath (Join-Path $dir 'mods') -Filter '*.jar' -File -ErrorAction SilentlyContinue) {
            $z = $null; $clientOnly = $false
            try {
                $z = [IO.Compression.ZipFile]::OpenRead($jar.FullName)
                $ids = @()
                $e = $z.GetEntry('fabric.mod.json')
                if ($e) {
                    $json = (New-Object IO.StreamReader($e.Open())).ReadToEnd()
                    if ($json -match '"environment"\s*:\s*"client"') { $clientOnly = $true }
                    if ($json -match '"id"\s*:\s*"([^"]+)"') { $ids += $Matches[1] }
                }
                foreach ($tomlName in 'META-INF/mods.toml', 'META-INF/neoforge.mods.toml') {
                    $t = $z.GetEntry($tomlName)
                    if (-not $t) { continue }
                    # Only modIds inside [[mods]] tables; [[dependencies.x]] tables name other mods
                    $inMods = $false
                    foreach ($ln in ((New-Object IO.StreamReader($t.Open())).ReadToEnd() -split "`n")) {
                        if ($ln -match '^\s*\[') { $inMods = $ln -match '^\s*\[\[\s*mods\s*\]\]' }
                        elseif ($inMods -and $ln -match '^\s*modId\s*=\s*"([^"]+)"') { $ids += $Matches[1] }
                    }
                }
                if ($ids | Where-Object { $denyIds.ContainsKey($_) }) { $clientOnly = $true }
            }
            catch { }
            finally { if ($z) { $z.Dispose() } }
            if ($clientOnly) { New-Item -ItemType Directory -Force $park | Out-Null; Move-Item -LiteralPath $jar.FullName -Destination $park }
        }
        if (Test-Path $park) { Info "화면 전용 모드 $(@(Get-ChildItem $park).Count)개를 더 찾아서 _client_only_mods 폴더로 옮겼어요." }
    }

    if (-not $li.version) { throw '모드 로더 버전을 알아내지 못했어요.' }
    # These values come from the pack's own files and end up in download URLs and 서버켜기.bat
    if ($li.version -notmatch '^[A-Za-z0-9._+-]+$' -or "$($li.mc)" -notmatch '^[0-9][0-9.]*$') {
        throw "모드팩 안의 버전 정보가 이상해요 (마인크래프트 '$($li.mc)', 로더 '$($li.version)'). 다른 버전을 골라 주세요."
    }
    $major = Get-JavaMajor $li.mc
    $java = Get-Java $major
    $launch = Install-Loader $dir $li $java

    Step '서버 설정 정리 중'
    # A pack can ship its author's admin list and whitelist; only the host decides who gets in and who is admin.
    # (An update brings the host's own lists over from the old server afterwards.)
    foreach ($f in 'ops.json', 'whitelist.json') {
        $fp = Join-Path $dir $f
        if (Test-Path -LiteralPath $fp) { Remove-Item -LiteralPath $fp -Force; Info "모드팩에 들어 있던 $f 는 지웠어요 (모드팩 제작자 쪽 목록이라서요)" }
    }
    # Datapacks shipped at the top level belong inside the world folder
    $dp = Join-Path $dir 'datapacks'
    if ((Test-Path $dp) -and -not (Test-Path (Join-Path $dir 'world'))) {
        New-Item -ItemType Directory -Force (Join-Path $dir 'world') | Out-Null
        Move-Item $dp (Join-Path $dir 'world\datapacks')
    }
    foreach ($junk in 'run.bat', 'run.sh') { $jp = Join-Path $dir $junk; if (Test-Path $jp) { Remove-Item -Force $jp } }
    Get-ChildItem $dir -Filter '*installer.jar.log' -File | Remove-Item -Force

    # Latin-1 round-trips any byte, so existing non-ASCII content survives the rewrite
    $latin1 = [Text.Encoding]::GetEncoding(28591)
    $jvm = Join-Path $dir 'user_jvm_args.txt'
    $keep = @()
    if (Test-Path $jvm) { $keep = @([IO.File]::ReadAllLines($jvm, $latin1) | Where-Object { $_ -notmatch '^\s*-Xm[sx]' }) }
    $xms = [Math]::Min(4, $RamGB)
    [IO.File]::WriteAllLines($jvm, [string[]](@($keep) + '# Server memory (RAM). Raise the -Xmx number if the server lags.' + "-Xms${xms}G" + "-Xmx${RamGB}G"), $latin1)

    if ($AcceptEula) { [IO.File]::WriteAllText((Join-Path $dir 'eula.txt'), "eula=true`r`n", $latin1) }

    $propFile = Join-Path $dir 'server.properties'
    $props = @()
    if (Test-Path $propFile) { $props = @([IO.File]::ReadAllLines($propFile, $latin1)) }
    # Modded defaults instead of vanilla ones (flying gear and mounts, friends building near spawn, slow world generation).
    # A pack the user added has no props of its own; an update brings the old server.properties back afterwards.
    $packProps = @($packsDoc.defaultProps); if ($builtIn) { $packProps += @($pack.props) }
    foreach ($src in $packProps) {
        if (-not $src) { continue }
        foreach ($pp in $src.PSObject.Properties) {
            if ($pp.Name -notin $PackPropKeys -or "$($pp.Value)" -notmatch '^[A-Za-z0-9._-]{1,16}$') { continue }
            $props = Set-Prop $props $pp.Name "$($pp.Value)"
        }
    }
    $props = Set-Prop $props 'white-list' 'true'
    $props = Set-Prop $props 'enforce-whitelist' 'true'
    $props = Set-Prop $props 'server-port' '25565'
    $props = Set-Prop $props 'server-ip' '127.0.0.1'   # Playit connects locally; nothing on the LAN needs direct access
    if (-not ($props | Where-Object { $_ -match '^motd=' })) { $props = Set-Prop $props 'motd' $pack.name }
    [IO.File]::WriteAllLines($propFile, [string[]]$props, $latin1)

    Write-Cp949 (Join-Path $dir '서버켜기.bat') @"
@echo off
title $Name 서버 (이 창을 닫지 마세요)
cd /d "%~dp0"
set "PROG=%~dp0..\..\_program"
netstat -an | find ":25565 " | find "LISTENING" >nul
if not errorlevel 1 (
  echo 다른 서버가 이미 켜져 있어요. 그 서버를 먼저 끈 다음 다시 실행하세요.
  pause
  exit /b
)
echo ==================================================
echo   $Name 서버를 켜는 중입니다.
echo   "Done" 이라는 글자가 나오면 접속할 수 있어요.
echo.
echo   서버를 끌 때: 이 창에 stop 입력 후 Enter
echo   (X 버튼으로 끄면 월드가 망가질 수 있어요!)
echo ==================================================
echo.
echo   (이 창은 예비용이에요. 모드팩서버관리.exe 로 켜면 진행 상황이 보이고 더 편해요)
echo.
set "PLAYIT_KEY="
if exist "%PROG%\playit\secret-key.dpapi" for /f "usebackq delims=" %%k in (``powershell -NoProfile -Command "Add-Type -AssemblyName System.Security; try { [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([IO.File]::ReadAllText('%PROG%\playit\secret-key.dpapi').Trim()), [Text.Encoding]::UTF8.GetBytes('mcsm-playit'), 'CurrentUser')) } catch { }"``) do set "PLAYIT_KEY=%%k"
if not exist "%PROG%\playit\playit.exe" goto noplayit
if "%PLAYIT_KEY%"=="" goto nokey
tasklist /FI "IMAGENAME eq playit.exe" | find /I "playit.exe" >nul
if errorlevel 1 start "playit - 이 창도 닫지 마세요" /min "%PROG%\playit\playit.exe" --secret %PLAYIT_KEY% --socket-path \\.\pipe\playitd-mcserver -l "%PROG%\playit\playit.log"
goto run
:nokey
echo [주의] Playit 키가 없거나 이 PC에서 풀 수 없어요. 모드팩서버관리.exe 의 [Playit 연결 설정]에서 키를 넣어 주세요.
echo        지금은 이 컴퓨터에서 127.0.0.1 로만 들어갈 수 있어요.
echo.
goto run
:noplayit
echo [주의] _program\playit\playit.exe 파일이 없어서 Playit을 켜지 못했어요.
echo        친구들은 접속할 수 없고, 이 컴퓨터에서는 127.0.0.1 로 들어갈 수 있어요.
echo.
:run
"%PROG%\java\$major\bin\java.exe" $launch
echo.
echo 서버가 꺼졌습니다. 아무 키나 누르면 이 창이 닫혀요.
pause >nul
"@

    Write-Cp949 (Join-Path $dir '친구접속안내.txt') @"
[ $Name 서버 접속 방법 ]

1. 모드팩 설치: $($pack.clientHow)
   - 모드팩: $($pack.name)
   - 버전: $verLabel   <- 반드시 같은 버전!
   - 모드팩 페이지: $($pack.page)
2. 런처 설정에서 메모리(램)를 6~8GB 정도로 올려 주세요.
3. 게임 실행 -> 멀티플레이 -> 서버 추가 -> 방장이 알려준 주소 입력
4. 방장에게 내 마인크래프트 닉네임을 알려 주세요 (화이트리스트에 추가해야 들어올 수 있어요).

* 방장이 모드를 따로 추가했다면 그 모드 파일도 받아서 mods 폴더에 넣어야 해요.
"@

    [ordered]@{
        pack = $pack.id; packName = $pack.name; version = $verLabel; versionKey = $VersionKey; mc = $li.mc
        loader = $li.loader; loaderVersion = $li.version; java = $major; ramGB = $RamGB
        page = $pack.page; installed = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    } | ConvertTo-Json | Set-Content (Join-Path $dir 'server-info.json') -Encoding UTF8

    if ($Update) {
        Merge-FromOldServer
        # Swap: keep the old server in servers_old, give the new one the familiar name
        $oldStore = Join-Path $Root 'servers_old'
        New-Item -ItemType Directory -Force $oldStore | Out-Null
        $oldKeep = Join-Path $oldStore ("$finalName" + '_' + ($oldInfo.version -replace '[^A-Za-z0-9._-]', '-') + '_' + (Get-Date -Format 'yyyyMMdd_HHmm'))
        Move-Item -LiteralPath $oldDir -Destination $oldKeep
        try { Rename-Item -LiteralPath $dir -NewName $finalName }
        catch { Move-Item -LiteralPath $oldKeep -Destination $oldDir; throw "새 버전 폴더 이름을 바꾸지 못했어요: $($_.Exception.Message)" }
        $script:worldMovedTo = $null; $createdDir = $null
        Remove-Item -LiteralPath (Join-Path (Join-Path $ServersDir $finalName) '.installing') -Force
        Write-Host ''
        Write-Host '==================================================' -ForegroundColor Green
        Write-Host "  업데이트 완료! '$finalName' 서버가 $verLabel 이(가) 됐어요." -ForegroundColor Green
        Write-Host '  월드, 화이트리스트, 직접 추가한 모드는 그대로 옮겼어요.' -ForegroundColor Green
        Write-Host "  친구들도 모드팩을 $verLabel 로 업데이트해야 들어올 수 있어요!" -ForegroundColor Yellow
        Write-Host "  예전 서버는 servers_old 폴더에 보관했어요. 문제가 없으면 나중에 지워도 돼요." -ForegroundColor Green
        Write-Host '==================================================' -ForegroundColor Green
        $result = 'ok'
    }
    else {
        Remove-Item -LiteralPath (Join-Path $dir '.installing') -Force
        $createdDir = $null
        Write-Host ''
        Write-Host '==================================================' -ForegroundColor Green
        Write-Host "  완료! '$Name' 서버가 준비됐어요." -ForegroundColor Green
        Write-Host "  마인크래프트 $($li.mc) / $($li.loader) $($li.version) / Java $major" -ForegroundColor Green
        Write-Host '  [내 서버] 탭에서 [▶ 친구랑 하기] 또는 [▶ 혼자 하기]를 누르세요.' -ForegroundColor Green
        if (-not $AcceptEula) { Write-Host '  (EULA는 서버를 처음 켤 때 다시 물어봐요)' -ForegroundColor Yellow }
        Write-Host '==================================================' -ForegroundColor Green
        $result = 'ok'
    }
    }   # end of server install
}
catch {
    Write-Host ''
    Write-Host '==================================================' -ForegroundColor Red
    Write-Host "  설치 실패: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  (위치: install.ps1 $($_.InvocationInfo.ScriptLineNumber)번째 줄)" -ForegroundColor DarkGray
    Write-Host '  인터넷 연결을 확인하고 다시 시도해 보세요.' -ForegroundColor Red
    Write-Host '==================================================' -ForegroundColor Red
    $result = 'fail'
    # An update that already carried the world over puts it back before the side folder is dropped
    if ($script:worldMovedTo -and (Test-Path -LiteralPath $script:worldMovedTo)) {
        try { Move-Item -LiteralPath $script:worldMovedTo -Destination $script:worldMovedFrom; Write-Host '  월드는 원래 서버로 되돌려 놨어요.' -ForegroundColor Yellow }
        catch { Write-Host "  [중요] 월드를 되돌리지 못했어요. 이 폴더에 있어요: $script:worldMovedTo" -ForegroundColor Red; $createdDir = $null }
    }
    # Scratch extraction lives in the shared cache; don't leave it behind
    if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    if ($createdDir -and (Test-Path -LiteralPath $createdDir)) {
        # Keep the loader log for troubleshooting, then drop the half-made server folder
        $logDir = Join-Path $Prog 'logs'
        New-Item -ItemType Directory -Force $logDir | Out-Null
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        Set-Content (Join-Path $logDir "install-fail_$stamp.txt") -Encoding UTF8 -Value @("server: $Name", "pack: $PackId $VersionKey", "error: $($_.Exception.Message)")
        $ilog = Join-Path $createdDir 'install-log.txt'
        if (Test-Path -LiteralPath $ilog) { Copy-Item -LiteralPath $ilog (Join-Path $logDir "install-fail_${stamp}_loader.txt") }
        Remove-Item -LiteralPath $createdDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  만들다 만 '$Name' 폴더는 지웠어요. 같은 이름으로 다시 시도해도 돼요." -ForegroundColor Yellow
        Write-Host "  (오류 기록: _program\logs 폴더)" -ForegroundColor DarkGray
    }
}
if ($StatusFile) { Set-Content $StatusFile $result }
if (-not $NoPause) { Write-Host ''; [void](Read-Host '창을 닫으려면 Enter를 누르세요') }
if ($result -eq 'ok') { exit 0 } else { exit 1 }
