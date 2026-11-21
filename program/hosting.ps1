# Moves a server between this PC and a hosting service. Started hidden by manager.ps1 (one job at a time);
# progress goes to stdout ("P <done> <total> <text>" lines), the result to -StatusFile ("OK" or "FAIL <reason>").
#   Pack        : zip of everything the hosted server needs (any hosting: the user uploads it on the hosting's page)
#   ExUpload    : the whole server to an exaroton server (its world is replaced)
#   ExSync      : mods + server.properties only (after mods or settings changed while hosted)
#   ExDownload  : world and player lists back from exaroton into <Dir>\_from_hosting
#   PtUpload / PtSync / PtDownload : the same three for Wicked (teamwicked.me), whose panel is Pterodactyl
# The API keys are read here from the DPAPI files, never passed on the command line.
param(
    [Parameter(Mandatory = $true)][ValidateSet('Pack', 'ExUpload', 'ExSync', 'ExDownload', 'PtUpload', 'PtSync', 'PtDownload')][string]$Action,
    [Parameter(Mandatory = $true)][string]$Dir,
    [string]$Out = '',
    [string]$ServerId = '',
    [string]$StatusFile = '',
    [int]$Port = 0          # Pack: the port the hosting gave this server (Pterodactyl hostings like Wicked), 0 = leave as is
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
[Net.ServicePointManager]::DefaultConnectionLimit = 8
Add-Type -AssemblyName System.Security, System.IO.Compression, System.IO.Compression.FileSystem
$Utf8 = New-Object Text.UTF8Encoding($false)
$ExApi = 'https://api.exaroton.com/v1'; if ($env:MCSM_EXAROTON_API) { $ExApi = $env:MCSM_EXAROTON_API.TrimEnd('/') }
$KeyFile = Join-Path $PSScriptRoot 'exaroton\api-key.dpapi'
$PtApi = 'https://panel.teamwicked.me'; if ($env:MCSM_WICKED_API) { $PtApi = $env:MCSM_WICKED_API.TrimEnd('/') }
$PtKeyFile = Join-Path $PSScriptRoot 'wicked\api-key.dpapi'

function Set-Result([string]$text) { if ($StatusFile) { [IO.File]::WriteAllText($StatusFile, $text, $Utf8) } }
function Say([int]$done, [int]$total, [string]$text) { [Console]::Out.WriteLine("P $done $total $text"); [Console]::Out.Flush() }

# ---------------- what goes to the hosting ----------------
# Only this program's own files and what the hosting sets up itself (Java, Forge libraries, start scripts) stay behind
$SkipTop = @('_client_only_mods', '_pack_original_files', '_removed_mods', '_removed_packs', '_resourcepacks', '_from_hosting', '.installing',
    '격리된_위험한_모드', '친구용_추가모드', '서버켜기.bat', '친구접속안내.txt', 'added-mods.json', 'added-packs.json', 'backups', 'crash-reports', 'logs',
    'libraries', 'install-log.txt', 'mod-scan.json', 'players-seen.json', 'security-log.txt', 'server-info.json', 'whitelist-pending.txt',
    'hosting.json', 'user_jvm_args.txt', 'run.bat', 'run.sh', 'variables.txt', 'debug', 'local')
function New-HostedProps([string]$root) {
    # On this PC the server only listens to 127.0.0.1 (Playit comes from inside the PC). At a hosting that would shut
    # everyone out, so the copy that goes up listens everywhere; the hosting sets its own port.
    $p = Join-Path $root 'server.properties'; if (-not (Test-Path -LiteralPath $p)) { return $null }
    $enc = [Text.Encoding]::GetEncoding(28591)
    $lines = @([IO.File]::ReadAllLines($p, $enc) | ForEach-Object {
            if ($_ -match '^\s*server-ip\s*=') { 'server-ip=' }
            elseif ($Port -gt 0 -and $_ -match '^\s*server-port\s*=') { "server-port=$Port" }
            else { $_ } })
    # A hosting that hands out one port per server only lets that one through
    if ($Port -gt 0 -and -not ($lines -match '^\s*server-port\s*=')) { $lines += "server-port=$Port" }
    $tmp = Join-Path $env:TEMP "mcsm-hosting-$PID.properties"
    [IO.File]::WriteAllLines($tmp, [string[]]$lines, $enc)
    return Get-Item -LiteralPath $tmp
}
function Get-UploadFiles([string]$root) {
    # Relative paths with '/' separators; the server's own jar files at the top level are the hosting's business
    $root = (Resolve-Path -LiteralPath $root).ProviderPath.TrimEnd('\')
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($e in Get-ChildItem -LiteralPath $root -Force) {
        if ($e.Name -in $SkipTop) { continue }
        if (-not $e.PSIsContainer) {
            if ($e.Extension -in '.jar', '.bat', '.sh', '.zip', '.log', '.part') { continue }
            $rel = $e.Name
            if ($rel -eq 'server.properties') { $e = New-HostedProps $root }
            $list.Add([pscustomobject]@{ rel = $rel; full = $e.FullName; size = $e.Length }); continue
        }
        foreach ($f in Get-ChildItem -LiteralPath $e.FullName -Recurse -File -Force -ErrorAction SilentlyContinue) {
            if ($f.Name -eq 'session.lock') { continue }
            $list.Add([pscustomobject]@{ rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/'); full = $f.FullName; size = $f.Length })
        }
    }
    return $list.ToArray()
}

# ---------------- exaroton ----------------
function Get-ExKey {
    if (-not (Test-Path -LiteralPath $KeyFile)) { throw 'exaroton API 키가 없어요. [서버 위치 바꾸기]에서 키를 저장해 주세요.' }
    $raw = [Convert]::FromBase64String(([IO.File]::ReadAllText($KeyFile)).Trim())
    return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($raw, [Text.Encoding]::UTF8.GetBytes('mcsm-exaroton'), 'CurrentUser'))
}
function ConvertTo-UrlPath([string]$rel) { return (($rel -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/' }
function Invoke-Ex([string]$method, [string]$path, [byte[]]$body = $null, [string]$type = 'application/json', [string]$file = '', [string]$saveTo = '') {
    # One request with three tries; a 4xx answer is final (wrong key, no such server or file)
    $last = $null
    for ($try = 1; $try -le 3; $try++) {
        $req = [Net.HttpWebRequest]::Create("$ExApi/$path"); $req.Method = $method
        $req.Headers['Authorization'] = "Bearer $script:key"; $req.UserAgent = 'mcsm-hosting'
        $req.Timeout = 60000; $req.ReadWriteTimeout = 600000; $req.AllowWriteStreamBuffering = $false
        try {
            if ($file) {
                $req.ContentType = 'application/octet-stream'; $fs = [IO.File]::OpenRead($file)
                try { $req.ContentLength = $fs.Length; $rs = $req.GetRequestStream(); $fs.CopyTo($rs, 1MB); $rs.Close() } finally { $fs.Close() }
            }
            elseif ($null -ne $body) { $req.ContentType = $type; $req.ContentLength = $body.Length; $rs = $req.GetRequestStream(); $rs.Write($body, 0, $body.Length); $rs.Close() }
            elseif ($method -in 'PUT', 'POST') { $req.ContentType = $type; $req.ContentLength = 0 }
            $resp = $req.GetResponse()
            try {
                if ($saveTo) { $o = [IO.File]::Create("$saveTo.part"); try { $resp.GetResponseStream().CopyTo($o, 1MB) } finally { $o.Close() }; Move-Item -LiteralPath "$saveTo.part" -Destination $saveTo -Force; return $null }
                $sr = New-Object IO.StreamReader($resp.GetResponseStream(), $Utf8); $text = $sr.ReadToEnd()
            }
            finally { $resp.Close() }
            if (-not $text) { return $null }
            $j = $text | ConvertFrom-Json
            if ($j.PSObject.Properties['success'] -and -not $j.success) { throw "exaroton: $($j.error)" }
            return $j.data
        }
        catch [Net.WebException] {
            $last = $_.Exception
            $code = 0; if ($last.Response) { $code = [int]$last.Response.StatusCode }
            if ($code -eq 401 -or $code -eq 403) { throw 'exaroton이 API 키를 받아 주지 않아요. 키를 다시 만들어 저장해 주세요.' }
            if ($code -ge 400 -and $code -lt 500) { throw (New-Object Net.WebException("HTTP $code", $last.Status)) }
            Start-Sleep -Seconds (2 * $try)
        }
    }
    throw "exaroton에 연결하지 못했어요: $($last.Message)"
}
function Get-ExChildren([string]$rel) {
    # Entries of a remote folder ('' = server root); $null when it doesn't exist
    $p = 'files/info/'; if ($rel) { $p += (ConvertTo-UrlPath $rel) + '/' }
    try { $i = Invoke-Ex 'GET' "servers/$ServerId/$p" } catch [Net.WebException] { return $null }
    if (-not $i -or -not $i.isDirectory) { return $null }
    return @($i.children | Where-Object { $_ })
}
function Get-ExEntries([string]$rel) { return @(Get-ExChildren $rel | Where-Object { $_ }) }   # missing folder = no entries
function Remove-ExTree([string]$rel) {
    # The folder itself, contents first (a folder delete may refuse when it isn't empty)
    $kids = Get-ExChildren $rel
    foreach ($k in @($kids | Where-Object { $_ })) {
        $r = "$rel/$($k.name)"
        if ($k.isDirectory) { Remove-ExTree $r } else { try { [void](Invoke-Ex 'DELETE' "servers/$ServerId/files/data/$(ConvertTo-UrlPath $r)/") } catch [Net.WebException] { } }
    }
    if ($null -ne $kids) { try { [void](Invoke-Ex 'DELETE' "servers/$ServerId/files/data/$(ConvertTo-UrlPath $rel)/") } catch [Net.WebException] { } }
}
function Send-ExFiles($files) {
    # Folders first (each once), then the files, biggest share of the time being the world's region files
    $made = @{}
    $total = $files.Count; $n = 0; [long]$bytes = 0; [long]$all = ($files | Measure-Object size -Sum).Sum
    foreach ($f in $files) {
        $parts = $f.rel -split '/'
        for ($i = 1; $i -lt $parts.Count; $i++) {
            $dirRel = ($parts[0..($i - 1)]) -join '/'
            if ($made.ContainsKey($dirRel)) { continue }
            try { [void](Invoke-Ex 'PUT' "servers/$ServerId/files/data/$(ConvertTo-UrlPath $dirRel)/" -type 'inode/directory') } catch [Net.WebException] { }   # already there
            $made[$dirRel] = $true
        }
        $n++; $bytes += $f.size
        Say $n $total ("올리는 중 {0} ({1:N0}MB / {2:N0}MB)" -f $f.rel, ($bytes / 1MB), ($all / 1MB))
        [void](Invoke-Ex 'PUT' "servers/$ServerId/files/data/$(ConvertTo-UrlPath $f.rel)/" -file $f.full)
    }
}
function Get-LevelName([string]$root) {
    $p = Join-Path $root 'server.properties'; $lv = 'world'
    if (Test-Path -LiteralPath $p) { foreach ($l in [IO.File]::ReadAllLines($p)) { if ($l -match '^\s*level-name\s*=\s*(.+?)\s*$') { $lv = $Matches[1] } } }
    if ($lv -notmatch '^[A-Za-z0-9 ._-]{1,64}$') { $lv = 'world' }
    return $lv
}
function Assert-ExOffline {
    $s = Invoke-Ex 'GET' "servers/$ServerId"
    if ([int]$s.status -ne 0 -and [int]$s.status -ne 7) { throw 'exaroton 서버가 아직 켜져 있어요. 끈 다음 다시 해 주세요.' }
}

# ---------------- Wicked (Pterodactyl client API) ----------------
# Files go up as zips the panel unpacks itself (one request per few dozen MB instead of one per file), and come back
# as the tar.gz the panel packs. The upload size a node accepts isn't published, so the parts shrink when it says "too big".
function Get-PtKey {
    if (-not (Test-Path -LiteralPath $PtKeyFile)) { throw '위키드 API 키가 없어요. [서버 위치 바꾸기]에서 키를 저장해 주세요.' }
    $raw = [Convert]::FromBase64String(([IO.File]::ReadAllText($PtKeyFile)).Trim())
    return [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($raw, [Text.Encoding]::UTF8.GetBytes('mcsm-wicked'), 'CurrentUser'))
}
function Invoke-Pt([string]$method, [string]$path, $body = $null) {
    # $path after /api/client/servers/<id>/ ; JSON in, JSON out. 4xx is final, the rest is tried three times
    $last = $null
    for ($try = 1; $try -le 3; $try++) {
        $req = [Net.HttpWebRequest]::Create("$PtApi/api/client/servers/$ServerId/$path"); $req.Method = $method
        $req.Headers['Authorization'] = "Bearer $script:key"; $req.Accept = 'application/json'; $req.UserAgent = 'mcsm-hosting'
        $req.Timeout = 300000; $req.ReadWriteTimeout = 600000
        try {
            if ($null -ne $body) {
                $b = $(if ($body -is [byte[]]) { $req.ContentType = 'text/plain'; $body } else { $req.ContentType = 'application/json'; [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 5)) })
                $req.ContentLength = $b.Length; $rs = $req.GetRequestStream(); $rs.Write($b, 0, $b.Length); $rs.Close()
            }
            elseif ($method -eq 'POST') { $req.ContentLength = 0 }
            $resp = $req.GetResponse()
            try { $text = (New-Object IO.StreamReader($resp.GetResponseStream(), $Utf8)).ReadToEnd() } finally { $resp.Close() }
            if (-not $text) { return $null }
            return ($text | ConvertFrom-Json)
        }
        catch [Net.WebException] {
            $last = $_.Exception
            $code = 0; if ($last.Response) { $code = [int]$last.Response.StatusCode }
            if ($code -eq 401 -or $code -eq 403) { throw '위키드가 API 키를 받아 주지 않아요. 위키드 패널의 계정 → API에서 키를 다시 만들어 저장해 주세요.' }
            if ($code -ge 400 -and $code -lt 500) { throw (New-Object Net.WebException("HTTP $code", $last.Status)) }
            Start-Sleep -Seconds (2 * $try)
        }
    }
    throw "위키드에 연결하지 못했어요: $($last.Message)"
}
function Get-PtEntries([string]$dir) {
    # Names in a remote folder ('/' = server root); a missing folder has none
    try { $r = Invoke-Pt 'GET' "files/list?directory=$([Uri]::EscapeDataString($dir))" } catch [Net.WebException] { return @() }
    return @($r.data | Where-Object { $_ } | ForEach-Object { $_.attributes })
}
function Remove-PtFiles([string]$root, [string[]]$names) {
    if (-not $names -or -not $names.Count) { return }
    [void](Invoke-Pt 'POST' 'files/delete' @{ root = $root; files = @($names) })
}
function Assert-PtOffline {
    $s = Invoke-Pt 'GET' 'resources'
    if ("$($s.attributes.current_state)" -ne 'offline') { throw '위키드 서버가 아직 켜져 있어요. 끈 다음 다시 해 주세요.' }
}
function Send-PtMultipart([string]$url, [string]$file, [string]$name) {
    # The panel's signed upload address takes a form post with a 'files' field; returns the HTTP code (200 = arrived)
    $bd = '----mcsm' + [guid]::NewGuid().ToString('N')
    $head = [Text.Encoding]::UTF8.GetBytes("--$bd`r`nContent-Disposition: form-data; name=`"files`"; filename=`"$name`"`r`nContent-Type: application/zip`r`n`r`n")
    $tail = [Text.Encoding]::UTF8.GetBytes("`r`n--$bd--`r`n")
    $fs = [IO.File]::OpenRead($file)
    try {
        $req = [Net.HttpWebRequest]::Create($url); $req.Method = 'POST'; $req.UserAgent = 'mcsm-hosting'
        $req.ContentType = "multipart/form-data; boundary=$bd"; $req.AllowWriteStreamBuffering = $false
        $req.Timeout = 300000; $req.ReadWriteTimeout = 900000
        $req.ContentLength = $head.Length + $fs.Length + $tail.Length
        try {
            $rs = $req.GetRequestStream(); $rs.Write($head, 0, $head.Length); $fs.CopyTo($rs, 1MB); $rs.Write($tail, 0, $tail.Length); $rs.Close()
            $resp = $req.GetResponse(); $code = [int]$resp.StatusCode; $resp.Close(); return $code
        }
        catch [Net.WebException] {
            if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode }
            # A node that refuses a too-big body often just drops the connection
            return -1
        }
    }
    finally { $fs.Close() }
}
function Send-PtFiles($files) {
    # Parts of up to $limit bytes: zip → upload to the root → the panel unpacks it over what is there → zip deleted there
    $tmpDir = Join-Path $env:TEMP "mcsm-wicked-$PID"; New-Item -ItemType Directory -Force $tmpDir | Out-Null
    try {
        $queue = New-Object System.Collections.Generic.List[object]; $queue.AddRange([object[]]@($files))
        [long]$limit = 90MB; [long]$all = ($files | Measure-Object size -Sum).Sum; [long]$sent = 0; $part = 0
        while ($queue.Count) {
            $take = New-Object System.Collections.Generic.List[object]; [long]$sum = 0
            while ($queue.Count -and ($take.Count -eq 0 -or $sum + $queue[0].size -le $limit)) { $take.Add($queue[0]); $sum += $queue[0].size; $queue.RemoveAt(0) }
            $part++; $pname = "mcsm-upload-$PID-$part.zip"; $pzip = Join-Path $tmpDir $pname
            Say ([int]($sent / 1MB)) ([int]($all / 1MB)) ("묶는 중 {0}번째 ({1:N0}MB / {2:N0}MB)" -f $part, ($sent / 1MB), ($all / 1MB))
            if (Test-Path -LiteralPath $pzip) { Remove-Item -LiteralPath $pzip -Force }
            $z = [IO.Compression.ZipFile]::Open($pzip, [IO.Compression.ZipArchiveMode]::Create)
            try { foreach ($f in $take) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $f.full, $f.rel, [IO.Compression.CompressionLevel]::Fastest) } } finally { $z.Dispose() }
            Say ([int]($sent / 1MB)) ([int]($all / 1MB)) ("올리는 중 {0}번째 ({1:N0}MB / {2:N0}MB)" -f $part, ($sent / 1MB), ($all / 1MB))
            $code = 0
            for ($try = 1; $try -le 3; $try++) {
                $u = (Invoke-Pt 'GET' 'files/upload').attributes.url   # signed, one use each
                $sep = '?'; if ($u.Contains('?')) { $sep = '&' }
                $code = Send-PtMultipart "$u$($sep)directory=%2F" $pzip $pname
                if ($code -ge 200 -and $code -lt 300) { break }
                if ($code -in 400, 413) { break }   # a dropped connection (-1) may be the network: tried again first
                Start-Sleep -Seconds (2 * $try)
            }
            if ($code -in 400, 413, -1) {
                # Too big for this node (the node says 400 or 413, a proxy in front may just hang up): smaller parts, same files again.
                # Halving stops at 256KB; below that one file per part, and a single file it still refuses can't go this way
                Remove-Item -LiteralPath $pzip -Force
                if ($take.Count -eq 1) { throw "'$($take[0].rel)' 파일을 위키드가 받아 주지 않아요. (HTTP $code) 위키드 패널의 파일 → [대용량 업로드]로 직접 올려 주세요." }
                if ($limit -gt 256KB) { $limit = [long][Math]::Max(256KB, $limit / 2) } else { $limit = 1 }   # 1 = one file per part
                $queue.InsertRange(0, $take); $part--
                continue
            }
            if ($code -lt 200 -or $code -ge 300) { throw "위키드에 파일을 올리지 못했어요. (HTTP $code)" }
            Remove-Item -LiteralPath $pzip -Force
            Say ([int]($sent / 1MB)) ([int]($all / 1MB)) ("위키드에서 푸는 중 {0}번째" -f $part)
            [void](Invoke-Pt 'POST' 'files/decompress' @{ root = '/'; file = $pname })
            try { Remove-PtFiles '/' @($pname) } catch { }
            $sent += $sum
        }
    }
    finally { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
}
function Expand-TarGz([string]$file, [string]$dest, [string[]]$skipNames) {
    # The panel packs downloads as tar.gz (Go archive/tar: ustar, GNU long names, PAX headers). Nothing lands outside $dest.
    $root = [IO.Path]::GetFullPath($dest).TrimEnd('\') + '\'
    $fs = [IO.File]::OpenRead($file); $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Decompress)
    $hdr = New-Object byte[] 512; $buf = New-Object byte[] 1MB
    function Read-Full($s, [byte[]]$b, [int]$n) { $o = 0; while ($o -lt $n) { $k = $s.Read($b, $o, $n - $o); if ($k -le 0) { return $o }; $o += $k }; return $o }
    function Skip-Bytes($s, [long]$n) { while ($n -gt 0) { $k = $s.Read($buf, 0, [int][Math]::Min($n, $buf.Length)); if ($k -le 0) { return }; $n -= $k } }
    function Read-Text($s, [long]$n) { $b = New-Object byte[] $n; [void](Read-Full $s $b ([int]$n)); return [Text.Encoding]::UTF8.GetString($b) }
    $count = 0
    try {
        $longName = $null
        while ($true) {
            if ((Read-Full $gz $hdr 512) -lt 512) { break }
            if ($hdr[0] -eq 0) { break }   # end blocks (a real header always starts with its name)
            $name = [Text.Encoding]::UTF8.GetString($hdr, 0, 100).Split([char]0)[0]
            $sizeTxt = [Text.Encoding]::ASCII.GetString($hdr, 124, 12).Trim([char]0, ' ')
            [long]$size = 0; if ($sizeTxt) { $size = [Convert]::ToInt64($sizeTxt, 8) }
            $type = [char]$hdr[156]
            $prefix = [Text.Encoding]::UTF8.GetString($hdr, 345, 155).Split([char]0)[0]
            if ([Text.Encoding]::ASCII.GetString($hdr, 257, 5) -eq 'ustar' -and $prefix) { $name = "$prefix/$name" }
            $pad = (512 - ($size % 512)) % 512
            if ($type -eq 'L') { $longName = (Read-Text $gz $size).TrimEnd([char]0); Skip-Bytes $gz $pad; continue }
            if ($type -eq 'x') {
                $pax = Read-Text $gz $size; Skip-Bytes $gz $pad
                foreach ($m in [regex]::Matches($pax, '(?m)^\d+ path=(.*)$')) { $longName = $m.Groups[1].Value }
                continue
            }
            if ($type -eq 'g') { Skip-Bytes $gz ($size + $pad); continue }
            if ($longName) { $name = $longName; $longName = $null }
            $rel = ($name -replace '^\./', '').TrimStart('/')
            $isFile = ($type -eq '0' -or $type -eq [char]0 -or $type -eq '7')
            $leaf = ($rel -split '/')[-1]
            if (-not $isFile -or -not $rel -or $rel -match '(^|/)\.\.(/|$)' -or $leaf -in $skipNames) { Skip-Bytes $gz ($size + $pad); continue }
            $target = [IO.Path]::GetFullPath((Join-Path $dest $rel.Replace('/', '\')))
            if (-not $target.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { Skip-Bytes $gz ($size + $pad); continue }
            New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
            $o = [IO.File]::Create($target)
            try { $left = $size; while ($left -gt 0) { $k = $gz.Read($buf, 0, [int][Math]::Min($left, $buf.Length)); if ($k -le 0) { throw '받은 파일이 중간에 끊겼어요.' }; $o.Write($buf, 0, $k); $left -= $k } }
            finally { $o.Close() }
            Skip-Bytes $gz $pad
            $count++; if ($count % 200 -eq 0) { Say $count 0 "푸는 중 $rel" }
        }
    }
    finally { $gz.Close(); $fs.Close() }
    return $count
}
function Get-PtDownload([string]$remote, [string]$saveTo) {
    $u = (Invoke-Pt 'GET' "files/download?file=$([Uri]::EscapeDataString($remote))").attributes.url
    $req = [Net.HttpWebRequest]::Create($u); $req.UserAgent = 'mcsm-hosting'; $req.Timeout = 300000; $req.ReadWriteTimeout = 900000
    $resp = $req.GetResponse()
    try {
        $total = $resp.ContentLength; $in = $resp.GetResponseStream(); $o = [IO.File]::Create("$saveTo.part")
        try {
            $buf = New-Object byte[] 1MB; [long]$got = 0; $tick = 0
            while (($k = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $o.Write($buf, 0, $k); $got += $k
                if ((++$tick) % 16 -eq 0) { Say ([int]($got / 1MB)) ([int]([Math]::Max($total, 0) / 1MB)) ("받는 중 {0:N0}MB" -f ($got / 1MB)) }
            }
        }
        finally { $o.Close() }
    }
    finally { $resp.Close() }
    Move-Item -LiteralPath "$saveTo.part" -Destination $saveTo -Force
}

try {
    if (-not (Test-Path -LiteralPath $Dir)) { throw "서버 폴더가 없어요: $Dir" }
    switch ($Action) {
        'Pack' {
            $files = @(Get-UploadFiles $Dir)
            if (-not $Out) { throw '-Out 이 필요해요.' }
            New-Item -ItemType Directory -Force (Split-Path $Out -Parent) | Out-Null
            $tmp = "$Out.part"; if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
            $zs = [IO.File]::Create($tmp)
            try {
                $zip = New-Object IO.Compression.ZipArchive($zs, [IO.Compression.ZipArchiveMode]::Create)
                $n = 0
                foreach ($f in $files) {
                    $n++; if ($n % 20 -eq 1 -or $n -eq $files.Count) { Say $n $files.Count "압축하는 중 $($f.rel)" }
                    [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f.full, $f.rel, [IO.Compression.CompressionLevel]::Fastest)
                }
                $zip.Dispose()
            }
            finally { $zs.Close() }
            Move-Item -LiteralPath $tmp -Destination $Out -Force
            Set-Result "OK $($files.Count)"
        }
        'ExUpload' {
            $script:key = Get-ExKey
            Assert-ExOffline
            $files = @(Get-UploadFiles $Dir)
            $lv = Get-LevelName $Dir
            # A world the hosting made at its first start would mix its chunks into ours: it goes first, and so do
            # mods the hosting's pack had that this server doesn't
            Say 0 $files.Count '호스팅에 있던 월드를 지우는 중...'
            Remove-ExTree $lv
            $have = @{}; foreach ($f in $files) { if ($f.rel -like 'mods/*') { $have[$f.rel.Substring(5)] = $true } }
            foreach ($k in (Get-ExEntries 'mods')) { if (-not $k.isDirectory -and -not $have.ContainsKey($k.name)) { Say 0 $files.Count "안 쓰는 모드 지우는 중 $($k.name)"; [void](Invoke-Ex 'DELETE' "servers/$ServerId/files/data/mods/$([Uri]::EscapeDataString($k.name))/") } }
            Send-ExFiles $files
            Set-Result "OK $($files.Count)"
        }
        'ExSync' {
            $script:key = Get-ExKey
            $local = @{}; foreach ($j in @(Get-ChildItem -LiteralPath (Join-Path $Dir 'mods') -Filter '*.jar' -File -ErrorAction SilentlyContinue)) { $local[$j.Name] = $j }
            $remote = @{}; foreach ($k in (Get-ExEntries 'mods')) { if (-not $k.isDirectory) { $remote[$k.name] = $k } }
            $send = @(foreach ($n in $local.Keys) { if (-not $remote.ContainsKey($n) -or [long]$remote[$n].size -ne $local[$n].Length) { [pscustomobject]@{ rel = "mods/$n"; full = $local[$n].FullName; size = $local[$n].Length } } })
            foreach ($n in @($remote.Keys)) { if (-not $local.ContainsKey($n)) { Say 0 0 "뺀 모드 지우는 중 $n"; [void](Invoke-Ex 'DELETE' "servers/$ServerId/files/data/mods/$([Uri]::EscapeDataString($n))/") } }
            $props = New-HostedProps $Dir
            if ($props) { $send += [pscustomobject]@{ rel = 'server.properties'; full = $props.FullName; size = $props.Length } }
            Send-ExFiles $send
            Set-Result "OK $($send.Count)"
        }
        'ExDownload' {
            $script:key = Get-ExKey
            Assert-ExOffline
            $lv = Get-LevelName $Dir
            $dst = Join-Path $Dir '_from_hosting'
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
            New-Item -ItemType Directory -Force $dst | Out-Null
            # Every file of the world, found folder by folder
            $todo = New-Object System.Collections.Generic.List[object]
            $q = New-Object System.Collections.Queue; $q.Enqueue($lv)
            $top = Get-ExChildren $lv; if ($null -eq $top) { throw "호스팅에 월드 폴더($lv)가 없어요." }
            while ($q.Count) {
                $r = $q.Dequeue()
                foreach ($k in (Get-ExEntries $r)) {
                    if ($k.isDirectory) { $q.Enqueue("$r/$($k.name)") } elseif ($k.name -ne 'session.lock') { $todo.Add([pscustomobject]@{ rel = "$r/$($k.name)"; size = [long]$k.size }) }
                }
            }
            foreach ($n in 'whitelist.json', 'ops.json', 'banned-players.json', 'banned-ips.json', 'usercache.json') { $todo.Add([pscustomobject]@{ rel = $n; size = 0; optional = $true }) }
            $n = 0
            foreach ($t in $todo) {
                $n++; Say $n $todo.Count "받는 중 $($t.rel)"
                $local = Join-Path $dst ($t.rel.Replace('/', '\'))
                New-Item -ItemType Directory -Force (Split-Path $local -Parent) | Out-Null
                try { [void](Invoke-Ex 'GET' "servers/$ServerId/files/data/$(ConvertTo-UrlPath $t.rel)/" -saveTo $local) }
                catch [Net.WebException] { if (-not $t.PSObject.Properties['optional']) { throw } }
            }
            if (-not (Test-Path -LiteralPath (Join-Path $dst "$lv\level.dat"))) { throw '받은 월드에 level.dat 이 없어요. 호스팅의 월드가 망가졌을 수 있어요.' }
            Set-Result "OK $($todo.Count)"
        }
        'PtUpload' {
            $script:key = Get-PtKey
            Assert-PtOffline
            $files = @(Get-UploadFiles $Dir)
            $lv = Get-LevelName $Dir
            # Same as exaroton: a world the hosting made at its first start and mods we don't have go first.
            # Its Forge (libraries, server.jar, start files) stays.
            $top = @(Get-PtEntries '/' | ForEach-Object { $_.name })
            if ($lv -in $top) { Say 0 0 '위키드에 있던 월드를 지우는 중...'; Remove-PtFiles '/' @($lv) }
            $have = @{}; foreach ($f in $files) { if ($f.rel -like 'mods/*' -and $f.rel -notlike 'mods/*/*') { $have[$f.rel.Substring(5)] = $true } }
            $stray = @(Get-PtEntries '/mods' | Where-Object { $_.is_file -and -not $have.ContainsKey($_.name) } | ForEach-Object { $_.name })
            if ($stray.Count) { Say 0 0 "안 쓰는 모드 $($stray.Count)개 지우는 중..."; Remove-PtFiles '/mods' $stray }
            Send-PtFiles $files
            Set-Result "OK $($files.Count)"
        }
        'PtSync' {
            $script:key = Get-PtKey
            $local = @{}; foreach ($j in @(Get-ChildItem -LiteralPath (Join-Path $Dir 'mods') -Filter '*.jar' -File -ErrorAction SilentlyContinue)) { $local[$j.Name] = $j }
            $remote = @{}; foreach ($k in (Get-PtEntries '/mods')) { if ($k.is_file -and $k.name -like '*.jar') { $remote[$k.name] = $k } }
            $send = @(foreach ($n in $local.Keys) { if (-not $remote.ContainsKey($n) -or [long]$remote[$n].size -ne $local[$n].Length) { [pscustomobject]@{ rel = "mods/$n"; full = $local[$n].FullName; size = $local[$n].Length } } })
            $gone = @($remote.Keys | Where-Object { -not $local.ContainsKey($_) })
            if ($gone.Count) { Say 0 0 "뺀 모드 $($gone.Count)개 지우는 중..."; Remove-PtFiles '/mods' $gone }
            $props = New-HostedProps $Dir
            if ($props) { $send += [pscustomobject]@{ rel = 'server.properties'; full = $props.FullName; size = $props.Length } }
            Send-PtFiles $send
            Set-Result "OK $($send.Count)"
        }
        'PtDownload' {
            $script:key = Get-PtKey
            Assert-PtOffline
            $lv = Get-LevelName $Dir
            $top = @(Get-PtEntries '/' | ForEach-Object { $_.name })
            if ($lv -notin $top) { throw "위키드에 월드 폴더($lv)가 없어요." }
            $pick = @($lv) + @('whitelist.json', 'ops.json', 'banned-players.json', 'banned-ips.json', 'usercache.json' | Where-Object { $_ -in $top })
            Say 0 0 '위키드에서 월드를 묶는 중... (월드가 크면 몇 분 걸려요)'
            $arc = Invoke-Pt 'POST' 'files/compress' @{ root = '/'; files = $pick }
            $an = "$($arc.attributes.name)"; if (-not $an) { throw '위키드가 월드를 묶지 못했어요.' }
            $dst = Join-Path $Dir '_from_hosting'
            if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
            New-Item -ItemType Directory -Force $dst | Out-Null
            $tgz = Join-Path $dst 'from-wicked.tar.gz'
            try { Get-PtDownload "/$an" $tgz } finally { try { Remove-PtFiles '/' @($an) } catch { } }
            Say 0 0 '받은 월드를 푸는 중...'
            $n = Expand-TarGz $tgz $dst @('session.lock')
            Remove-Item -LiteralPath $tgz -Force
            if (-not (Test-Path -LiteralPath (Join-Path $dst "$lv\level.dat"))) { throw '받은 월드에 level.dat 이 없어요. 호스팅의 월드가 망가졌을 수 있어요.' }
            Set-Result "OK $n"
        }
    }
    exit 0
}
catch {
    $msg = $_.Exception.Message -replace "[`r`n]+", ' '
    [Console]::Out.WriteLine("ERR $msg")
    Set-Result "FAIL $msg"
    exit 1
}
