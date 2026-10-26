<#
airport-nav 每周链接体检

用法：
  ./scripts/check_links.ps1                          # 本地预检：无响应不判死，只标记 unknown
  ./scripts/check_links.ps1 -Runner github-actions   # CI 环境：无响应才判 dead
  ./scripts/check_links.ps1 -KeepProxy               # 保留系统代理环境变量（默认清空，防失效代理误判）
  ./scripts/check_links.ps1 -DataPath ../x.json      # 指定数据文件（默认 data/airports.json）

行为：
  1. 逐个请求每个机场的 entry_url 和 backup_domains（HEAD 优先，不支持 HEAD 时退回 GET）；
  2. 入口无响应时自动尝试备用域名；备用域名可用则自动升级为入口，旧入口降级为备用域名保留（最多 -MaxBackup 个）；
  3. 结果（status / http_code / final_url / last_checked / checked_from）写回数据文件；
  4. 只要服务器有任何 HTTP 响应（含 301/302/403 人机验证）即视为入口存活；
  5. 单个站点连续探测整轮失败时再重试一轮（-Retry），仍失败才继续判定流程。

判死规则（两振出局 + 异地复核）：
  CI 环境下单次无响应不会直接判死 —— 上轮 ok 的降为 unknown，上轮已是 unknown/dead 的才判 dead。
  这样一次网络抖动不会再让活站顶着「❌失效」牌子过一周。
  加 -SecondOpinion 时，在「准备判 dead」那一刻再换两个不同网络位置问一遍
  （r.jina.ai 抓取服务 → check-host.net 多国节点）：只要有一个地方能拿到 HTTP 响应，
  本轮仍记 unknown。避免「只有 GitHub 美国 runner 访问不到」的误杀。
  两个探针都说看不到或都不可用时，按原规则判死 —— 复核只用来免死，不用来放过真死站。

注意：函数必须定义在顶层。把 function 嵌进 foreach 块会造成脚本解析失败（Missing closing brace）。
#>
[CmdletBinding()]
param(
    [ValidateSet('local', 'github-actions')]
    [string]$Runner = 'local',
    [int]$TimeoutSec = 10,
    [int]$Retry = 2,
    [int]$MaxBackup = 5,
    [switch]$KeepProxy,
    [switch]$SecondOpinion,
    [int]$OpinionNodes = 3,
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

# 确定性 JSON 序列化（见 lib-json.ps1）。PS 5.1 与 PS 7 的 ConvertTo-Json 格式不同，本地与 CI 必须用同一套写法，
# 否则每次本地预检都会把整个 data/airports.json 重排一遍。
. (Join-Path $PSScriptRoot 'lib-json.ps1')

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

function Get-RemoteFetchVerdict {
    # 探针 1：r.jina.ai，它是另一个网络位置上的抓取服务（Cloudflare 侧），单次 GET 就有结论。
    # 返回 $true = 抓到了内容；$false = 对方明确抓不到；$null = 服务本身不可用/超时（无意见）
    param([string]$Url, [int]$TimeoutSec = 25)

    $client = $null
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $UserAgent)
        $resp = $client.GetAsync('https://r.jina.ai/' + $Url).GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        $resp.Dispose()
        if ($code -ge 200 -and $code -lt 400) { return $true }
        if ($code -ge 400 -and $code -lt 500) { return $false }
        return $null
    }
    catch {
        Write-Host ("  · r.jina.ai 不可用：{0}" -f $_.Exception.Message.Split([char]10)[0])
        return $null
    }
    finally {
        if ($client) { $client.Dispose() }
    }
}

function Get-NodeCheckVerdict {
    # 探针 2：check-host.net 的多个境外节点（异步提交 + 轮询）。
    # 返回 $true = 有节点能看到；$false = 所有节点都失败；$null = 服务本身不可用/没等到结果（无意见）
    param([string]$Url, [int]$Nodes = 3, [int]$PollTimes = 6, [int]$PollSeconds = 4)

    $apiBase = 'https://check-host.net'
    $submitUrl = '{0}/check-http?host={1}&max_nodes={2}' -f $apiBase, [uri]::EscapeDataString($Url), $Nodes

    $client = $null
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds(15)
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'application/json')

        $submit = ($client.GetStringAsync($submitUrl).GetAwaiter().GetResult()) | ConvertFrom-Json
        if (-not $submit.request_id) {
            Write-Host "  · check-host.net 拒绝了请求（没有 request_id）"
            return $null
        }

        for ($i = 1; $i -le $PollTimes; $i++) {
            Start-Sleep -Seconds $PollSeconds
            $poll = ($client.GetStringAsync(('{0}/check-result/{1}' -f $apiBase, $submit.request_id)).GetAwaiter().GetResult()) | ConvertFrom-Json
            $pending = 0
            $answered = 0
            foreach ($p in $poll.PSObject.Properties) {
                if ($null -eq $p.Value) { $pending++; continue }
                foreach ($item in @($p.Value)) {
                    if ($null -eq $item) { continue }
                    $answered++
                    if ([int]$item[0] -eq 1) { return $true }
                }
            }
            if ($answered -gt 0 -and $pending -eq 0) { return $false }
        }
        Write-Host ("  · check-host.net 超时未出结果（仍等待 {0} 个节点）" -f $pending)
        return $null
    }
    catch {
        Write-Host ("  · check-host.net 不可用：{0}" -f $_.Exception.Message.Split([char]10)[0])
        return $null
    }
    finally {
        if ($client) { $client.Dispose() }
    }
}

function Get-SecondOpinion {
    # 只在「准备判 dead」时调用。单一 GitHub runner（美国机房）访问不到 ≠ 站点已死：
    # 可能是该地区线路问题，或站点只对某些地区放行。换两个不同网络位置再问一遍。
    # 只有「某个地方能看到」才有意义（$true）；都说看不到或都没意见，就按原规则判死，不放过死站。
    param([string]$Url, [int]$Nodes = 3)

    $v1 = Get-RemoteFetchVerdict -Url $Url
    if ($v1 -eq $true) { return $true }

    $v2 = Get-NodeCheckVerdict -Url $Url -Nodes $Nodes
    if ($v2 -eq $true) { return $true }

    return $false
}

# ---------------- 主流程 ----------------

# 先落到变量再套 @()：PS 5.1 的 ConvertFrom-Json 不展开顶层数组，写成 @(管道) 会得到「数组套数组」的一层壳，
# 那样 foreach 拿到的 $a 是整个数组，字段全变成数组，写回时会把数据文件写坏。PS 7 默认展开，两者行为不同。
$rawData  = Get-Content -LiteralPath $DataPath -Raw -Encoding UTF8 | ConvertFrom-Json
$airports = @($rawData)
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
            $oldEntry = [string]$a.entry_url
            $a.status = 'ok'
            $a.http_code = $best.Code
            $a.final_url = $best.Final
            if ($best.Url -ne $oldEntry) {
                # 旧入口不丢弃：降级成备用域名排在最前。否则主入口只要临时抖一轮，就会被永久从数据里抹掉，
                # 下次想换回来时连原来的地址都找不到了。
                $kept = @(@($a.backup_domains) | Where-Object { $_ -and $_ -ne $best.Url -and $_ -ne $oldEntry })
                if ($oldEntry -match '^https?://') { $kept = @($oldEntry) + $kept }
                if ($kept.Count -gt $MaxBackup) { $kept = @($kept[0..($MaxBackup - 1)]) }
                $a.backup_domains = [object[]]$kept
                Write-Host ("{0}: 入口切换 {1} -> {2}（旧入口已降级为备用）" -f $a.name, $oldEntry, $best.Url)
                $a.entry_url = $best.Url
            }
        }
        else {
            $a.http_code = 0
            $a.final_url = $null
            if ($Runner -eq 'github-actions') {
                # 两振出局：上轮还活着的先降为 unknown，连续两轮都无响应才判 dead
                if ($prevStatus -eq 'ok') { $a.status = 'unknown' }
                elseif ($prevStatus -in @('unknown', 'dead')) {
                    $verdict = 'dead'
                    if ($SecondOpinion) {
                        Write-Host ("{0}: 本机两轮都没响应，换两个境外位置复核……" -f $a.name)
                        $seen = Get-SecondOpinion -Url ([string]$a.entry_url) -Nodes $OpinionNodes
                        if ($seen) {
                            $verdict = 'unknown'
                            Write-Host ("{0}: 别处能看到 {1}，本轮记 unknown，暂不判死" -f $a.name, $a.entry_url)
                        }
                    }
                    $a.status = $verdict
                }
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

$utf8 = New-Object System.Text.UTF8Encoding($false)
# data/*.json 沿用 4 空格缩进，与人手编辑时的习惯一致
[System.IO.File]::WriteAllText($DataPath, (ConvertTo-StableJson -Value $airports -Indent 4), $utf8)

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
