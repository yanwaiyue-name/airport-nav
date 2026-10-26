<#
airport-nav 每周链接体检

用法：
  ./scripts/check_links.ps1                          # 本地预检：无响应不判死，只标记 unknown
  ./scripts/check_links.ps1 -Runner github-actions   # CI 环境：无响应才判 dead
  ./scripts/check_links.ps1 -KeepProxy               # 保留系统代理环境变量（默认清空，防失效代理误判）
  ./scripts/check_links.ps1 -DataPath ../x.json      # 指定数据文件（默认 data/airports.json）

行为：
  1. 逐个请求每个机场的 entry_url 和 backup_domains（HEAD 优先，不支持 HEAD 时退回 GET）；
  2. 入口无响应时自动尝试备用域名；备用域名可用则自动升级为入口；
  3. 结果（status / http_code / final_url / last_checked / checked_from）写回数据文件；
  4. 只要服务器有任何 HTTP 响应（含 301/302/403 人机验证）即视为入口存活；
  5. 单个站点连续探测整轮失败时再重试一轮（-Retry），仍失败才继续判定流程。

判死规则（两振出局）：
  CI 环境下单次无响应不会直接判死 —— 上轮 ok 的降为 unknown，上轮已是 unknown/dead 的才判 dead。
  这样一次网络抖动不会再让活站顶着「❌失效」牌子过一周。

注意：函数必须定义在顶层。把 function 嵌进 foreach 块会造成脚本解析失败（Missing closing brace）。
#>
[CmdletBinding()]
param(
    [ValidateSet('local', 'github-actions')]
    [string]$Runner = 'local',
    [int]$TimeoutSec = 10,
    [int]$Retry = 2,
    [switch]$KeepProxy,
    [string]$DataPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $DataPath) { $DataPath = Join-Path $root 'data/airports.json' }
if (-not (Test-Path -LiteralPath $DataPath)) { throw "找不到数据文件：$DataPath" }

$today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
$NL = [string][char]10
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

# 本机默认清空代理环境变量：残留的失效代理会把活站全部误判成无响应
if (-not $KeepProxy) {
    foreach ($v in @('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy')) {
        Remove-Item -Path "env:$v" -ErrorAction SilentlyContinue
    }
}

# ---------------- 工具函数 ----------------

function Format-JsonIndent {
    # 把任意缩进（PS 5.1 是 4 空格、PS 7 是 2 空格）统一成 4 空格，保证 CI 与本地输出逐字节一致
    param([string]$Json, [int]$Indent = 4)

    $lines = $Json -split '\r?\n'
    $min = 0
    foreach ($l in $lines) {
        if ($l -match '^( +)') {
            $n = $Matches[1].Length
            if ($min -eq 0 -or $n -lt $min) { $min = $n }
        }
    }
    if ($min -le 0 -or $min -eq $Indent) { return ($lines -join $NL) }

    $factor = [double]$Indent / $min
    $out = foreach ($l in $lines) {
        if ($l -match '^( +)(.*)$') {
            (' ' * [int][Math]::Round($Matches[1].Length * $factor)) + $Matches[2]
        }
        else { $l }
    }
    return ($out -join $NL)
}

function New-ProbeClient {
    param([int]$Timeout)

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $h = [System.Net.Http.HttpClientHandler]::new()
    $h.AllowAutoRedirect = $true
    $h.MaxAutomaticRedirections = 5
    $h.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    $c = [System.Net.Http.HttpClient]::new($h)
    $c.Timeout = [TimeSpan]::FromSeconds($Timeout)
    [void]$c.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $UserAgent)
    [void]$c.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8')
    [void]$c.DefaultRequestHeaders.TryAddWithoutValidation('Accept-Language', 'zh-CN,zh;q=0.9,en;q=0.8')
    return $c
}

function Invoke-Probe {
    param($Client, [string]$Url, [string]$Method = 'Head')

    try {
        $verb = [System.Net.Http.HttpMethod]::new($Method.ToUpperInvariant())
        $req = [System.Net.Http.HttpRequestMessage]::new($verb, $Url)
        $resp = $Client.SendAsync($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        $final = $Url
        if ($resp.RequestMessage -and $resp.RequestMessage.RequestUri) {
            $final = $resp.RequestMessage.RequestUri.AbsoluteUri
        }
        $resp.Dispose()
        return @{ Code = $code; Final = $final; Error = $null }
    }
    catch {
        return @{ Code = 0; Final = $null; Error = $_.Exception.Message }
    }
}

function Test-Url {
    param($Client, [string]$Url, [int]$Attempts = 2)

    # 先 HEAD 省流量；不支持 HEAD（400/405/501）或直接连不上时，用 GET 复核，避免把活站误判成死链。
    # 整轮都连不上时再重试一轮：单次 DNS/握手抖动不该让一个活站被判死。
    $last = @{ Code = 0; Final = $null; Error = $null }
    for ($i = 1; $i -le [Math]::Max(1, $Attempts); $i++) {
        $head = Invoke-Probe -Client $Client -Url $Url -Method 'Head'
        if ($head.Code -gt 0 -and @(400, 405, 501) -notcontains $head.Code) { return $head }

        $get = Invoke-Probe -Client $Client -Url $Url -Method 'Get'
        if ($get.Code -gt 0) { return $get }

        $last = $get
        if ($i -lt $Attempts) { Start-Sleep -Seconds 3 }
    }
    return $last
}

# ---------------- 主流程 ----------------

$airports = @(Get-Content -LiteralPath $DataPath -Raw -Encoding UTF8 | ConvertFrom-Json)
$client = New-ProbeClient -Timeout $TimeoutSec

$rows = New-Object System.Collections.Generic.List[string]
$ok = 0; $unknown = 0; $dead = 0

try {
    foreach ($a in $airports) {
        foreach ($p in @('status', 'http_code', 'final_url', 'last_checked', 'checked_from')) {
            if (-not ($a.PSObject.Properties.Name -contains $p)) {
                $a | Add-Member -NotePropertyName $p -NotePropertyValue $null
            }
        }

        $prevStatus = [string]$a.status
        $targets = @($a.entry_url) + @($a.backup_domains)
        $best = $null
        foreach ($u in $targets) {
            if ([string]::IsNullOrWhiteSpace($u) -or $u -notmatch '^https?://') { continue }
            $res = Test-Url -Client $client -Url $u -Attempts $Retry
            if ($res.Code -gt 0) {
                $best = @{ Url = $u; Code = $res.Code; Final = $res.Final }
                break
            }
        }

        if ($best) {
            $a.status = 'ok'
            $a.http_code = $best.Code
            $a.final_url = $best.Final
            if ($best.Url -ne $a.entry_url) {
                Write-Host ("{0}: 入口切换 {1} -> {2}" -f $a.name, $a.entry_url, $best.Url)
                $a.entry_url = $best.Url
            }
        }
        else {
            $a.http_code = 0
            $a.final_url = $null
            if ($Runner -eq 'github-actions') {
                # 两振出局：上轮还活着的先降为 unknown，连续两轮都无响应才判 dead
                if ($prevStatus -eq 'ok') { $a.status = 'unknown' }
                elseif ($prevStatus -in @('unknown', 'dead')) { $a.status = 'dead' }
                else { $a.status = 'unknown' }
            }
            elseif ($a.status -ne 'dead') { $a.status = 'unknown' }
        }

        $a.last_checked = $today
        $a.checked_from = $Runner

        switch ($a.status) {
            'ok' { $ok++ }
            'dead' { $dead++ }
            default { $unknown++ }
        }

        $note = if ($prevStatus -and $prevStatus -ne $a.status) { "（上轮 $prevStatus）" } else { '' }
        Write-Host ("{0,-14} -> {1,-8} {2} {3}" -f $a.name, $a.status, ($a.http_code), $note)
        $rows.Add(("| {0} | {1} | {2} | {3} | {4} |" -f $a.name, $a.tier, $a.status, $a.http_code, $a.entry_url))
    }
}
finally {
    $client.Dispose()
}

$json = Format-JsonIndent -Json ($airports | ConvertTo-Json -Depth 10)
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($DataPath, $json, $utf8)

$line = "体检完成（{0} / {1}）：存活 {2} 家，未验证 {3} 家，失效 {4} 家 -> {5}" -f $today, $Runner, $ok, $unknown, $dead, $DataPath
Write-Host $line

if ($env:GITHUB_STEP_SUMMARY) {
    $md = @()
    $md += "### 机场入口体检（$today / $Runner）"
    $md += ''
    $md += "存活 **$ok** 家 / 未验证 **$unknown** 家 / 失效 **$dead** 家"
    $md += ''
    $md += '| 机场 | 档位 | 状态 | HTTP | 入口 |'
    $md += '|---|---|---|---|---|'
    $md += $rows
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join $NL) -Encoding utf8
}
