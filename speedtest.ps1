<#
  speedtest.ps1 - PowerShell port of speedtest.py (speedtest-cli)

  Original Python version: Copyright 2012 Matt Martz, Apache License 2.0
    https://github.com/sivel/speedtest-cli
  Modified 2026 by Jan Willem Wijnands (live meter, fixes), ported to PowerShell.

  Works in the Windows PowerShell 5.1 that ships with Windows 10/11, and in
  PowerShell 7 on any OS. No modules or installs needed.

  Run without downloading:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/JDOUBLE-U/speedtest/refs/heads/main/speedtest.ps1)))
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/JDOUBLE-U/speedtest/refs/heads/main/speedtest.ps1))) -Simple

  Both PowerShell-style (-NoUpload, -Server 1234) and speedtest-cli-style
  (--no-upload, --server 1234) options are accepted.

    Licensed under the Apache License, Version 2.0 (the "License"); you may
    not use this file except in compliance with the License. You may obtain
    a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [switch]$NoDownload, [switch]$NoUpload, [switch]$Single, [switch]$Bytes,
    [switch]$Simple, [switch]$Plain, [switch]$Csv, [string]$CsvDelimiter = ',',
    [switch]$CsvHeader, [switch]$Json, [switch]$List,
    [int[]]$Server = @(), [int[]]$Exclude = @(),
    [double]$Timeout = 10, [switch]$Version, [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = 'Stop'
$ScriptVersion = '2.1.4b1-ps'
$ConfigUrl = 'http://www.speedtest.net/speedtest-config.php'
if ($env:SPEEDTEST_CONFIG_URL) { $ConfigUrl = $env:SPEEDTEST_CONFIG_URL }
$ServersUrl = 'https://www.speedtest.net/api/embed/vz0azjarf5enop8a/config'
if ($env:SPEEDTEST_SERVERS_URL) { $ServersUrl = $env:SPEEDTEST_SERVERS_URL }

# ---------------------------------------------------------------- arguments
# Accept speedtest-cli style --options as well (they arrive in $Rest)
$Server = @($Server); $Exclude = @($Exclude)
$Rest = @($Rest)
for ($i = 0; $i -lt $Rest.Count; $i++) {
    $a = [string]$Rest[$i]
    $val = $null
    if ($a -match '^(--?[^=]+)=(.*)$') { $a = $Matches[1]; $val = $Matches[2] }
    switch ($a.TrimStart('-').ToLower()) {
        'no-download'   { $NoDownload = [switch]$true }
        'no-upload'     { $NoUpload = [switch]$true }
        'single'        { $Single = [switch]$true }
        'bytes'         { $Bytes = [switch]$true }
        'simple'        { $Simple = [switch]$true }
        'plain'         { $Plain = [switch]$true }
        'csv'           { $Csv = [switch]$true }
        'csv-header'    { $CsvHeader = [switch]$true }
        'json'          { $Json = [switch]$true }
        'list'          { $List = [switch]$true }
        'version'       { $Version = [switch]$true }
        'help'          { $Help = [switch]$true }
        'h'             { $Help = [switch]$true }
        'csv-delimiter' { if ($null -eq $val) { $i++; $val = [string]$Rest[$i] }; $CsvDelimiter = $val }
        'timeout'       { if ($null -eq $val) { $i++; $val = [string]$Rest[$i] }; $Timeout = [double]$val }
        'server'        { if ($null -eq $val) { $i++; $val = [string]$Rest[$i] }
                          if ($val -notmatch '^\d+$') { Write-Host "ERROR: $val is an invalid server type, must be an int"; return }
                          $Server += [int]$val }
        'exclude'       { if ($null -eq $val) { $i++; $val = [string]$Rest[$i] }
                          if ($val -notmatch '^\d+$') { Write-Host "ERROR: $val is an invalid server type, must be an int"; return }
                          $Exclude += [int]$val }
        default         { Write-Host "ERROR: unrecognized argument: $($Rest[$i])"; return }
    }
}

if ($Help) {
@'
usage: speedtest.ps1 [options]

  -NoDownload / --no-download      Do not perform download test
  -NoUpload   / --no-upload        Do not perform upload test
  -Single     / --single           Only use a single connection
  -Bytes      / --bytes            Display values in bytes instead of bits
  -Simple     / --simple           Only show basic information
  -Plain      / --plain            Disable the live progress meter
  -Csv        / --csv              CSV output (speeds in bit/s)
  -CsvDelimiter C / --csv-delimiter C
  -CsvHeader  / --csv-header       Print CSV headers and exit
  -Json       / --json             JSON output (speeds in bit/s)
  -List       / --list             List speedtest.net servers and exit
  -Server ID  / --server ID        Test against this server ID (repeatable)
  -Exclude ID / --exclude ID       Exclude this server ID (repeatable)
  -Timeout S  / --timeout S        HTTP timeout in seconds (default 10)
  -Version    / --version          Show the version and exit
'@
    return
}

if ($Version) {
    Write-Output "speedtest-cli $ScriptVersion"
    Write-Output "PowerShell $($PSVersionTable.PSVersion)"
    return
}

$Inv = [Globalization.CultureInfo]::InvariantCulture
function Fmt([string]$f) { [string]::Format($Inv, $f, [object[]]$args) }
function Num([double]$d) { $d.ToString('R', $Inv) }

function CsvField([string]$s) {
    if ($s.Contains($CsvDelimiter) -or $s.Contains('"') -or $s.Contains("`n")) {
        return '"' + $s.Replace('"', '""') + '"'
    }
    $s
}
function CsvRow { ($args | ForEach-Object { CsvField ([string]$_) }) -join $CsvDelimiter }

if ($NoDownload -and $NoUpload) { Write-Host 'ERROR: Cannot supply both --no-download and --no-upload'; return }
if ($CsvDelimiter.Length -ne 1) { Write-Host 'ERROR: --csv-delimiter must be a single character'; return }
if ($CsvHeader) {
    CsvRow 'Server ID' 'Sponsor' 'Server Name' 'Timestamp' 'Distance' 'Ping' 'Download' 'Upload' 'Share' 'IP Address'
    return
}

$Quiet = [bool]($Simple -or $Csv -or $Json)
$Redirected = $false
try { $Redirected = [Console]::IsOutputRedirected } catch { }
$Fancy = (-not $Quiet) -and (-not $Plain) -and (-not $Redirected)
function Say([string]$s) { if (-not $Quiet) { Write-Host $s } }

$Unit = 'bit'; $UnitDiv = 1.0
if ($Bytes) { $Unit = 'byte'; $UnitDiv = 8.0 }
$TimeoutMs = [int]($Timeout * 1000)

# .NET networking defaults: TLS 1.2, no 2-connections-per-host cap, no 100-continue
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }
[Net.ServicePointManager]::DefaultConnectionLimit = 128
[Net.ServicePointManager]::Expect100Continue = $false

$OsName = 'Windows'
if ($PSVersionTable.PSEdition -eq 'Core') { $OsName = [Runtime.InteropServices.RuntimeInformation]::OSDescription }
$UA = "Mozilla/5.0 ($OsName; U; $([IntPtr]::Size * 8)bit; en-us) PowerShell/$($PSVersionTable.PSVersion) (KHTML, like Gecko) speedtest-cli/$ScriptVersion"

$Freq = [double][Diagnostics.Stopwatch]::Frequency
function Now { [Diagnostics.Stopwatch]::GetTimestamp() / $Freq }
function UnixMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function Bust([string]$url, [string]$bump) {
    $sep = '?'; if ($url.Contains('?')) { $sep = '&' }
    "$url${sep}x=$(UnixMs).$bump"
}

function New-Req([string]$url) {
    $r = [Net.HttpWebRequest]::Create($url)
    $r.UserAgent = $UA
    $r.Timeout = $TimeoutMs
    $r.ReadWriteTimeout = $TimeoutMs
    $r.Headers.Add('Cache-Control', 'no-cache')
    $r.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    $r
}
function Get-Text([string]$url) {
    $resp = (New-Req $url).GetResponse()
    try { (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } finally { $resp.Close() }
}

# ---------------------------------------------------------------- colours / glyphs
$Vt = $false
try { $Vt = [bool]$Host.UI.SupportsVirtualTerminal } catch { }
if ($env:NO_COLOR -or $Redirected) { $UseColor = $false } else { $UseColor = $Vt }
$E = [char]27
function C([string]$code, [string]$text) { if ($UseColor) { "$E[${code}m$text$E[0m" } else { $text } }

$Uni = [bool]($env:WT_SESSION -or $env:TERM_PROGRAM -or
              ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows))
$OldEncoding = $null
if ($Uni -and $Fancy) {
    try { $OldEncoding = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { $Uni = $false }
}
if ($Uni) {
    $G = @{ Sparks = [string[]]@([char]0x2581, [char]0x2582, [char]0x2583, [char]0x2584, [char]0x2585, [char]0x2586, [char]0x2587, [char]0x2588)
            Bar = [string][char]0x2501; Head = [string][char]0x2578; Done = [string][char]0x2714
            Down = [string][char]0x2193; Up = [string][char]0x2191 }
} else {
    $G = @{ Sparks = [string[]]@(' ', '.', ':', '-', '=', '+', '*', '#')
            Bar = '='; Head = '>'; Done = 'OK'; Down = 'D'; Up = 'U' }
}
$BarW = 30

# ---------------------------------------------------------------- live meter
$M = @{}
function Speed([double]$bps) { Fmt '{0,8:F2} M{1}/s' ($bps / 1e6 / $UnitDiv) $Unit }

function Meter-Start([double]$t0, [double]$duration) {
    $M.T0 = $t0; $M.Dur = [math]::Max($duration, 1.0); $M.Last = $t0; $M.Peak = 0.0
    $M.Win = New-Object System.Collections.ArrayList
    [void]$M.Win.Add([double[]]@($t0, 0))
    $M.Rates = New-Object System.Collections.ArrayList
}

function Meter-Sample([double]$total) {
    $t = Now
    [void]$M.Win.Add([double[]]@($t, $total))
    # ~0.75 s of history so the "current" figure doesn't jitter
    while ($M.Win.Count -gt 2 -and ($t - $M.Win[0][0]) -gt 0.75) { $M.Win.RemoveAt(0) }
    $old = $M.Win[0]; $cur = 0.0
    if ($t -gt $old[0]) { $cur = [math]::Max(0, ($total - $old[1]) * 8.0 / ($t - $old[0])) }
    if ($t - $M.Last -ge 0.25) {
        $M.Last = $t
        [void]$M.Rates.Add($cur)
        while ($M.Rates.Count -gt 16) { $M.Rates.RemoveAt(0) }
        if ($cur -gt $M.Peak) { $M.Peak = $cur }
    }
    $M.Elapsed = $t - $M.T0; $M.Cur = $cur
}

function Sparkline {
    if ($M.Rates.Count -eq 0) { return '' }
    $top = 0.0; foreach ($r in $M.Rates) { if ($r -gt $top) { $top = $r } }
    if ($top -le 0) { $top = 1.0 }
    $steps = $G.Sparks.Count - 1
    -join ($M.Rates | ForEach-Object { $G.Sparks[[int][math]::Round($_ / $top * $steps)] })
}

function Write-Line([string]$line, [switch]$Final) {
    if ($Vt) { $line = "`r$line$E[K" }
    else { $line = "`r" + $line.PadRight([math]::Max(0, [Console]::WindowWidth - 1)) }
    if ($Final) { $line += "`n" }
    [Console]::Write($line)
}

function Meter-Render([string]$label, [string]$icon, [string]$color) {
    $frac = [math]::Min($M.Elapsed / $M.Dur, 1.0)
    $filled = [int][math]::Floor($frac * $BarW)
    if ($filled -ge $BarW) { $bar = C $color ($G.Bar * $BarW) }
    else { $bar = (C $color (($G.Bar * $filled) + $G.Head)) + (C '2' ($G.Bar * ($BarW - $filled - 1))) }
    Write-Line (Fmt '  {0} {1,-8} {2} {3,5:F1}s  {4} {5}' (C $color $icon) $label $bar $M.Elapsed `
                    (C $color (Sparkline).PadRight(16)) (C '1' (Speed $M.Cur)))
}

function Meter-Stop([string]$label, [string]$color, [double]$final) {
    $peak = [math]::Max($M.Peak, $final)
    Write-Line -Final (Fmt '  {0} {1,-8} {2}   {3}   {4}' (C '32' $G.Done) $label (C '1' (Speed $final)) `
                           (C '2' ('peak ' + (Speed $peak).Trim())) (C $color (Sparkline)))
}

# ---------------------------------------------------------------- workers (run in runspaces)
$DownloadWorker = {
    param([string[]]$Urls, [double]$Start, [double]$Length, $Shared, [string]$Key, [string]$UA, [int]$TimeoutMs)
    $freq = [double][Diagnostics.Stopwatch]::Frequency
    $buf = New-Object byte[] 65536
    [long]$total = 0; $n = 0
    foreach ($u in $Urls) {
        if ($Shared.Stop) { break }
        if (([Diagnostics.Stopwatch]::GetTimestamp() / $freq) - $Start -gt $Length) { break }
        $n++
        $resp = $null
        try {
            $req = [Net.HttpWebRequest]::Create($u + '?x=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + ".$Key$n")
            $req.UserAgent = $UA; $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
            $req.Headers.Add('Cache-Control', 'no-cache')
            $resp = $req.GetResponse()
            $stream = $resp.GetResponseStream()
            while ($true) {
                if ($Shared.Stop -or (([Diagnostics.Stopwatch]::GetTimestamp() / $freq) - $Start) -gt $Length) {
                    $req.Abort(); break
                }
                $read = $stream.Read($buf, 0, $buf.Length)
                if ($read -le 0) { break }
                $total += $read
                $Shared[$Key] = $total
            }
        } catch { } finally { if ($resp) { try { $resp.Close() } catch { } } }
    }
    $Shared[$Key] = $total
}

$UploadWorker = {
    param([int[]]$Sizes, [double]$Start, [double]$Length, $Shared, [string]$Key, [string]$Url,
          $Payloads, [string]$UA, [int]$TimeoutMs)
    $freq = [double][Diagnostics.Stopwatch]::Frequency
    [long]$total = 0; $n = 0
    foreach ($size in $Sizes) {
        if ($Shared.Stop) { break }
        if (([Diagnostics.Stopwatch]::GetTimestamp() / $freq) - $Start -gt $Length) { break }
        $n++
        $data = $Payloads["$size"]
        $resp = $null
        try {
            $req = [Net.HttpWebRequest]::Create($Url + '?x=' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + ".$Key$n")
            $req.Method = 'POST'; $req.ContentType = 'application/x-www-form-urlencoded'
            $req.ContentLength = $data.Length
            $req.AllowWriteStreamBuffering = $false; $req.SendChunked = $false
            $req.UserAgent = $UA; $req.Timeout = $TimeoutMs; $req.ReadWriteTimeout = $TimeoutMs
            $rs = $req.GetRequestStream()
            $off = 0
            while ($off -lt $data.Length) {
                if ($Shared.Stop -or (([Diagnostics.Stopwatch]::GetTimestamp() / $freq) - $Start) -gt $Length) {
                    $req.Abort(); throw 'time is up'
                }
                $chunk = [math]::Min(65536, $data.Length - $off)
                $rs.Write($data, $off, $chunk)
                $off += $chunk; $total += $chunk
                $Shared[$Key] = $total
            }
            $rs.Close()
            $resp = $req.GetResponse()
        } catch { } finally { if ($resp) { try { $resp.Close() } catch { } } }
    }
    $Shared[$Key] = $total
}

function Invoke-Phase($worker, [object[]]$perWorkerArgs, [string]$prefix, [double]$duration,
                      [string]$label, [string]$icon, [string]$color) {
    # $perWorkerArgs: one object[] of arguments per worker; the shared table and key are appended
    $shared = [hashtable]::Synchronized(@{ Stop = $false })
    $count = $perWorkerArgs.Count
    for ($i = 0; $i -lt $count; $i++) { $shared["$prefix$i"] = [long]0 }
    $pool = [runspacefactory]::CreateRunspacePool(1, $count)
    $pool.Open()
    $jobs = New-Object System.Collections.ArrayList
    $start = Now
    try {
        for ($i = 0; $i -lt $count; $i++) {
            $a = $perWorkerArgs[$i]
            $ps = [powershell]::Create(); $ps.RunspacePool = $pool
            [void]$ps.AddScript($worker).AddArgument($a[0]).AddArgument($start).AddArgument($duration).AddArgument($shared).AddArgument("$prefix$i")
            for ($k = 1; $k -lt $a.Count; $k++) { [void]$ps.AddArgument($a[$k]) }
            [void]$jobs.Add(@{ PS = $ps; H = $ps.BeginInvoke() })
        }
        $getTotal = { $s = 0.0; for ($i = 0; $i -lt $count; $i++) { $s += [double]$shared["$prefix$i"] }; $s }
        if ($Fancy) { Meter-Start $start $duration }
        elseif (-not $Quiet) { Write-Host "Testing $($label.ToLower()) speed" -NoNewline }
        $running = { foreach ($j in $jobs) { if (-not $j.H.IsCompleted) { return $true } }; $false }
        while (& $running) {
            if ($Fancy) {
                Start-Sleep -Milliseconds 100
                Meter-Sample (& $getTotal)
                Meter-Render $label $icon $color
            } else {
                Start-Sleep -Milliseconds 500
                if (-not $Quiet) { Write-Host '.' -NoNewline }
            }
        }
        $stop = Now
        foreach ($j in $jobs) { try { [void]$j.PS.EndInvoke($j.H) } catch { } }
        $bytes = & $getTotal
        $bps = $bytes * 8.0 / [math]::Max($stop - $start, 1e-9)
        if ($Fancy) { Meter-Stop $label $color $bps }
        elseif (-not $Quiet) { Write-Host ''; Write-Host (Fmt '{0}: {1:F2} M{2}/s' $label ($bps / 1e6 / $UnitDiv) $Unit) }
        return @{ Bytes = [long]$bytes; Bps = $bps }
    } finally {
        $shared.Stop = $true
        foreach ($j in $jobs) { try { $j.PS.Dispose() } catch { } }
        try { $pool.Close(); $pool.Dispose() } catch { }
    }
}

# ---------------------------------------------------------------- main
try {
    $Timestamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.ffffff'Z'", $Inv)

    Say 'Retrieving speedtest.net configuration...'
    try { [xml]$cfg = Get-Text (Bust $ConfigUrl '0') }
    catch { throw "Cannot retrieve speedtest configuration: $($_.Exception.Message)" }
    $root = $cfg.DocumentElement
    function Attr([string]$tag, [string]$name, $default = '') {
        $node = $root.SelectSingleNode($tag)
        if ($node -and $node.HasAttribute($name)) { return $node.GetAttribute($name) }
        $default
    }
    $Client = [ordered]@{ ip = (Attr client ip); isp = (Attr client isp); lat = (Attr client lat)
                          lon = (Attr client lon); country = (Attr client country) }
    if (-not $Client.lat -or -not $Client.lon) { throw 'Malformed speedtest.net configuration' }
    $IgnoreIds = @((Attr server-config ignoreids) -split ',' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    $DlThreads = [int](Attr server-config threadcount 4) * 2
    $DlLen = [double](Attr download testlength 10); $DlPerUrl = [int](Attr download threadsperurl 4)
    $UpLen = [double](Attr upload testlength 10); $UpRatio = [int](Attr upload ratio 5)
    $UpMax = [int](Attr upload maxchunkcount 50); $UpThreads = [int](Attr upload threads 2)

    # Server list (custom key=value blocks inside braces)
    function Get-Servers {
        try { $text = Get-Text (Bust $ServersUrl '0') }
        catch { throw "Cannot retrieve speedtest server list: $($_.Exception.Message)" }
        if (-not $text) { throw 'Empty server list received' }
        $list = foreach ($m in [regex]::Matches($text, '\{(.*?)\}', 'Singleline')) {
            $kv = @{}
            foreach ($line in ($m.Groups[1].Value -split "`n")) {
                $p = $line.IndexOf('=')
                if ($p -lt 0) { continue }
                $k = $line.Substring(0, $p).Trim(); $v = $line.Substring($p + 1).Trim().Trim('"')
                if ($k -eq 'serverid') { $k = 'id' }
                $kv[$k] = $v
            }
            if (-not $kv.host -or "$($kv.id)" -notmatch '^\d+$') { continue }
            $id = [int]$kv.id
            if ($Server.Count -and $Server -notcontains $id) { continue }
            if ($IgnoreIds -contains $id -or $Exclude -contains $id) { continue }
            [pscustomobject]@{ id = $kv.id; host = $kv.host; sponsor = $kv.sponsor; name = $kv.name
                               country = $kv.country; url = "http://$($kv.host)/speedtest/upload.php"; latency = 0.0 }
        }
        $list = @($list)
        if ($list.Count -eq 0) {
            if ($Server.Count -or $Exclude.Count) { throw "No matched servers: $($Server -join ', ')" }
            throw 'No servers found in speedtest.net server list'
        }
        $list
    }

    if ($List) {
        foreach ($s in (Get-Servers)) { Fmt '{0,5}) {1} ({2}, {3})' $s.id $s.sponsor $s.name $s.country }
        return
    }

    Say "Testing from $($Client.isp) ($($Client.ip))..."
    Say 'Retrieving speedtest.net server list...'
    $Servers = Get-Servers
    if ($Server.Count -eq 1) { Say 'Retrieving information for the selected server...' }
    else { Say 'Selecting best server based on ping...' }

    function Measure-Latency($srv) {
        $base = $srv.url.Substring(0, $srv.url.LastIndexOf('/'))
        $stamp = UnixMs
        $cum = foreach ($i in 0..2) {
            try {
                $req = New-Req "$base/latency.txt?x=$stamp.$i"
                $req.KeepAlive = $false
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $resp = $req.GetResponse()
                $sw.Stop()
                $status = [int]$resp.StatusCode
                $body = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
                $resp.Close()
                if ($status -eq 200 -and $body.StartsWith('test=test')) { $sw.Elapsed.TotalSeconds } else { 3600 }
            } catch { 3600 }
        }
        [math]::Round((($cum | Measure-Object -Sum).Sum / 3) * 1000.0, 3)
    }

    $Best = $null
    foreach ($s in ($Servers | Select-Object -First 5)) {
        $s.latency = Measure-Latency $s
        if ($null -eq $Best -or $s.latency -lt $Best.latency) { $Best = $s }
    }
    if ($Best.latency -ge 3600000) { throw 'Unable to connect to servers to test latency.' }
    $Ping = $Best.latency
    Say (Fmt 'Hosted by {0} ({1}): {2} ms' $Best.sponsor $Best.name $Ping)
    if ($Fancy) { Write-Host '' }

    $Download = 0.0; $Upload = 0.0; $BytesReceived = 0; $BytesSent = 0

    if (-not $NoDownload) {
        $base = $Best.url.Substring(0, $Best.url.LastIndexOf('/'))
        $urls = New-Object System.Collections.ArrayList
        foreach ($size in 350, 500, 750, 1000, 1500, 2000, 2500, 3000, 3500, 4000) {
            for ($j = 0; $j -lt $DlPerUrl; $j++) { [void]$urls.Add("$base/random${size}x$size.jpg") }
        }
        $w = $DlThreads; if ($Single) { $w = 1 }; $w = [math]::Max(1, [math]::Min($w, $urls.Count))
        $argSets = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $w; $i++) {
            $mine = [string[]]@(for ($j = $i; $j -lt $urls.Count; $j += $w) { $urls[$j] })
            [void]$argSets.Add([object[]]@($mine, $UA, $TimeoutMs))
        }
        $r = Invoke-Phase $DownloadWorker $argSets.ToArray() 'dl' $DlLen 'Download' $G.Down '36'
        $Download = $r.Bps; $BytesReceived = $r.Bytes
        if ($Download -gt 100000) { $UpThreads = 8 }
    } else { Say 'Skipping download test' }

    if (-not $NoUpload) {
        $all = 32768, 65536, 131072, 262144, 524288, 1048576, 7340032
        $useSizes = @($all[($UpRatio - 1)..6])
        $upCount = [int][math]::Ceiling($UpMax / $useSizes.Count)
        $chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        $payloads = @{}
        $sizes = New-Object System.Collections.ArrayList
        foreach ($size in $useSizes) {
            $filler = ($chars * [int][math]::Ceiling(($size - 9) / 36.0)).Substring(0, $size - 9)
            $payloads["$size"] = [Text.Encoding]::ASCII.GetBytes('content1=' + $filler)
            for ($j = 0; $j -lt $upCount; $j++) { [void]$sizes.Add($size) }
        }
        $w = $UpThreads; if ($Single) { $w = 1 }; $w = [math]::Max(1, [math]::Min($w, $sizes.Count))
        $argSets = New-Object System.Collections.ArrayList
        for ($i = 0; $i -lt $w; $i++) {
            $mine = [int[]]@(for ($j = $i; $j -lt $sizes.Count; $j += $w) { $sizes[$j] })
            [void]$argSets.Add([object[]]@($mine, $Best.url, $payloads, $UA, $TimeoutMs))
        }
        $r = Invoke-Phase $UploadWorker $argSets.ToArray() 'ul' $UpLen 'Upload' $G.Up '35'
        $Upload = $r.Bps; $BytesSent = $r.Bytes
    } else { Say 'Skipping upload test' }

    if ($Simple) {
        Fmt "Ping: {0} ms`nDownload: {1:F2} M{3}/s`nUpload: {2:F2} M{3}/s" $Ping ($Download / 1e6 / $UnitDiv) ($Upload / 1e6 / $UnitDiv) $Unit
    } elseif ($Csv) {
        CsvRow $Best.id $Best.sponsor $Best.name $Timestamp '' (Num $Ping) (Num $Download) (Num $Upload) '' $Client.ip
    } elseif ($Json) {
        [ordered]@{
            download = $Download; upload = $Upload; ping = $Ping
            server = [ordered]@{ id = $Best.id; host = $Best.host; sponsor = $Best.sponsor; name = $Best.name
                                 country = $Best.country; url = $Best.url; latency = $Best.latency }
            timestamp = $Timestamp; bytes_sent = $BytesSent; bytes_received = $BytesReceived
            share = $null; client = $Client
        } | ConvertTo-Json -Compress -Depth 4
    }
} catch {
    Write-Host ''
    Write-Host "ERROR: $($_.Exception.Message)"
} finally {
    if ($OldEncoding) { try { [Console]::OutputEncoding = $OldEncoding } catch { } }
}
