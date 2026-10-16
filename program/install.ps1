param(
    [Parameter(Mandatory = $true)][string]$PackId,
    [Parameter(Mandatory = $true)][string]$VersionKey,   # CurseForge: version label, Modrinth: version id
    [Parameter(Mandatory = $true)][string]$Name,         # server folder name
    [int]$RamGB = 6,
    [switch]$AcceptEula,
    [string]$ServersDir = '',
    [string]$StatusFile = '',  # written with ok/fail when done (read by manager.ps1)
    [switch]$NoPause,
    [switch]$Update            # $Name is an existing server: install the new version beside it, carry the world over, swap
)
# Installs one modpack server into <root>\servers\<Name>.
# Shared runtimes live in <root>\_program (java\<major>, playit, cache).
# With -Update the old server folder is kept in <root>\servers_old.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
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
    Invoke-Curl -L --fail --retry 3 -# -o $tmp $Url
    if ($LASTEXITCODE -ne 0) { throw "다운로드 실패: $Url" }
    Move-Item -Force -LiteralPath $tmp -Destination $OutFile
    if (-not (Test-Ok)) { throw "받은 파일이 손상됐어요 (크기/해시 불일치): $(Split-Path $OutFile -Leaf)" }
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
try {
    $packs = (Get-Content (Join-Path $Prog 'packs.json') -Raw -Encoding UTF8 | ConvertFrom-Json).packs
    $pack = $packs | Where-Object id -eq $PackId
    if (-not $pack) { throw "목록에 없는 모드팩이에요: $PackId" }

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
    if ((Test-Path -LiteralPath $dir) -and (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1)) { throw "'$Name' 폴더가 이미 있어요. 다른 서버 이름을 써 주세요." }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $createdDir = $dir   # removed again if the install fails, so the same name can be retried
    if ($Update) {
        $host.UI.RawUI.WindowTitle = "모드팩 업데이트 중: $finalName"
        Write-Host "모드팩 업데이트: $($pack.name)  $($oldInfo.version) -> 새 버전" -ForegroundColor Yellow
        Write-Host "서버: $oldDir" -ForegroundColor Yellow
    }
    else {
        $host.UI.RawUI.WindowTitle = "서버 만드는 중: $Name"
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
        Get-Download $ver.url $zip -Size $ver.size

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
        Invoke-Curl -g -L --fail --retry 3 --create-dirs --parallel --parallel-max 8 -s -S -K $cfgFile
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
    $major = Get-JavaMajor $li.mc
    $java = Get-Java $major
    $launch = Install-Loader $dir $li $java

    Step '서버 설정 정리 중'
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
echo   (모드팩서버관리.bat 으로 켜면 진행 상황이 보이고 더 편해요)
echo.
set "PLAYIT_KEY="
if exist "%PROG%\playit\secret-key.txt" set /p PLAYIT_KEY=<"%PROG%\playit\secret-key.txt"
if not exist "%PROG%\playit\playit.exe" goto noplayit
if "%PLAYIT_KEY%"=="" goto nokey
tasklist /FI "IMAGENAME eq playit.exe" | find /I "playit.exe" >nul
if errorlevel 1 start "playit - 이 창도 닫지 마세요" /min "%PROG%\playit\playit.exe" --secret %PLAYIT_KEY% --socket-path \\.\pipe\playitd-mcserver -l "%PROG%\playit\playit.log"
goto run
:nokey
echo [주의] Playit 연결 설정이 안 돼 있어요. 모드팩서버관리.bat 의 [Playit 연결 설정]을 먼저 해 주세요.
echo        지금은 이 컴퓨터에서 localhost 로만 들어갈 수 있어요.
echo.
goto run
:noplayit
echo [주의] _program\playit\playit.exe 파일이 없어서 Playit을 켜지 못했어요.
echo        친구들은 접속할 수 없고, 이 컴퓨터에서는 localhost 로 들어갈 수 있어요.
echo.
:run
"%PROG%\java\$major\bin\java.exe" $launch
echo.
echo 서버가 꺼졌습니다. 아무 키나 누르면 이 창이 닫혀요.
pause >nul
"@

    Write-Cp949 (Join-Path $dir '월드백업.bat') @"
@echo off
title 월드 백업
cd /d "%~dp0"
echo 서버가 꺼져 있을 때만 실행하세요.
echo 월드를 backups 폴더에 압축해서 저장합니다...
powershell -NoProfile -ExecutionPolicy Bypass -Command "`$t=Get-Date -Format 'yyyyMMdd_HHmm'; New-Item -ItemType Directory -Force backups | Out-Null; Compress-Archive -Path world -DestinationPath ('backups\world_' + `$t + '.zip'); Write-Host ('Saved: backups\world_' + `$t + '.zip')"
echo.
echo 끝났어요. 아무 키나 누르면 창이 닫혀요.
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
        pack = $pack.id; packName = $pack.name; version = $verLabel; mc = $li.mc
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
        Write-Host ''
        Write-Host '==================================================' -ForegroundColor Green
        Write-Host "  완료! '$Name' 서버가 준비됐어요." -ForegroundColor Green
        Write-Host "  마인크래프트 $($li.mc) / $($li.loader) $($li.version) / Java $major" -ForegroundColor Green
        Write-Host '  관리 프로그램의 [내 서버] 탭에서 [▶ 친구랑 하기] 또는 [▶ 혼자 하기]를 누르세요.' -ForegroundColor Green
        if (-not $AcceptEula) { Write-Host '  (EULA는 서버를 처음 켤 때 다시 물어봐요)' -ForegroundColor Yellow }
        Write-Host '==================================================' -ForegroundColor Green
        $result = 'ok'
    }
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
