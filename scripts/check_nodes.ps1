#Requires -Version 5.1
<#
.SYNOPSIS
  节点实测：从本地 Clash 订阅里取出节点，逐个做 TCP 握手探测，输出存活率与延迟。

.DESCRIPTION
  为什么需要这个：
    入口体检只能回答「机场官网能不能打开」，回答不了「买了能不能用」。
    实测三毛机场：官网 200，但 45 个节点里只有一部分能握手 ——
    这两个结论差别极大，而用户真正关心的是后者。

  工作方式：
    1. 从 Clash Verge 的 profiles 目录读当前订阅 yaml（只读，不修改）
    2. 解析出 name / server / port / type
    3. 逐个 TCP 握手（不建隧道、不测速、不消耗流量），统计延迟
    4. 按地区归类，输出 md 报告

  隐私说明：
    报告只输出节点名、地区、延迟、协议类型。
    server 地址与任何凭据一律不落盘、不回显。

  局限：
    TCP 通 ≠ 能上网。握手成功只说明端口可达，不代表协议正确、不被中间人干扰、
    也不代表线路质量。要更准需要用 mihomo 的 URL 测速接口，那会真实消耗流量。

.EXAMPLE
  ./scripts/check_nodes.ps1
  ./scripts/check_nodes.ps1 -SubFile "C:\path\sub.yaml" -TimeoutMs 4000
#>
[CmdletBinding()]
param(
    [string]$SubFile,
    [int]$TimeoutMs = 5000,
    [string]$OutFile,
    # 把结果按机场写回 data/nodes.json，让 README 的「节点实测」列能显示出来。
    # CI 上没有订阅，所以这个文件只由本地手动跑产生；CI 只读、不覆盖。
    [switch]$WriteData,
    # 结果记到哪个机场名下（按 sources 里的机场 key 或名称匹配 data/airports.json）
    [string]$Airport
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $OutFile) { $OutFile = Join-Path $root 'node-report.md' }

# 自动定位 Clash Verge 当前订阅
if (-not $SubFile) {
    $cfgRoot = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
    $profilesYml = Join-Path $cfgRoot 'profiles.yaml'
    if (Test-Path -LiteralPath $profilesYml) {
        $py = Get-Content -LiteralPath $profilesYml -Raw -Encoding UTF8
        # 取 current 指向的 uid，再找到对应的 remote 条目
        $cur = [regex]::Match($py, 'current:\s*([A-Za-z0-9]+)')
        if ($cur.Success) {
            $uid = $cur.Groups[1].Value
            $blk = [regex]::Match($py, ('(?s)- uid: ' + [regex]::Escape($uid) + '.*?file:\s*([^\r\n]+)'))
            if ($blk.Success) {
                $SubFile = Join-Path (Join-Path $cfgRoot 'profiles') ($blk.Groups[1].Value.Trim())
            }
        }
    }
}

if (-not $SubFile -or -not (Test-Path -LiteralPath $SubFile)) {
    Write-Host '没有找到当前订阅文件，跳过节点实测（不影响入口体检结果）'
    exit 0
}

function Get-GroupVal($m) {
    # 三选一的分组里，返回第一个非空的
    if (-not $m.Success) { return '' }
    foreach ($i in 1..3) {
        if ($m.Groups[$i].Success -and $m.Groups[$i].Value.Trim() -ne '') { return $m.Groups[$i].Value.Trim() }
    }
    return ''
}

$raw = Get-Content -LiteralPath $SubFile -Raw -Encoding UTF8

# 逐条节点块：name / server / port 相对顺序不固定，用块内匹配
$blocks = [regex]::Matches($raw, '(?s)-\s*\{[^{}]*?\}')
$nodes = New-Object System.Collections.ArrayList

foreach ($b in $blocks) {
    $txt = $b.Value
    # YAML 里字符串可能用双引号、单引号或裸值，三种都要认
    $q = '(?:''([^'']+)''|"([^"]+)"|([^,\r\n]+))'
    $nm = [regex]::Match($txt, 'name:\s*' + $q)
    $sv = [regex]::Match($txt, 'server:\s*' + $q)
    $pt = [regex]::Match($txt, 'port:\s*(\d+)')
    $ty = [regex]::Match($txt, 'type:\s*' + $q)
    if (-not ($nm.Success -and $sv.Success -and $pt.Success)) { continue }

    $name = Get-GroupVal $nm
    if (-not $name) { continue }
    # 过滤订阅里的信息占位行（剩余流量、到期时间等），它们不是真节点
    # 订阅里常混入提示文字（剩余流量、到期时间、"建议每天更新订阅"），这些不是节点
    if ($name -match '剩余|到期|重置|套餐|流量|建议|更新|官网|请|通知|公告') { continue }

    [void]$nodes.Add([pscustomobject]@{
        Name   = $name
        Server = (Get-GroupVal $sv)
        Port   = [int]$pt.Groups[1].Value
        Type   = $(if ($ty.Success) { (Get-GroupVal $ty) } else { 'unknown' })
    })
}

if ($nodes.Count -eq 0) {
    Write-Host '订阅里没有解析到节点，跳过（订阅格式可能不兼容）'
    exit 0
}

function Get-Region([string]$Name) {
    if ($Name -match '日本|JP|Japan|东京|大阪') { return '日本' }
    if ($Name -match '美国|US|United|洛杉矶|凤凰城|堪萨斯|圣何塞|西雅图|纽约|达拉斯') { return '美国' }
    if ($Name -match '新加坡|SG|狮城') { return '新加坡' }
    if ($Name -match '香港|HK|Hong') { return '香港' }
    if ($Name -match '台湾|TW|Taiwan|台北') { return '台湾' }
    if ($Name -match '韩国|KR|Korea|首尔') { return '韩国' }
    if ($Name -match '英国|UK|London|伦敦') { return '英国' }
    if ($Name -match '德国|DE|Germany|法兰克福') { return '德国' }
    return '其他'
}

function Test-NodePort([string]$Server, [int]$Port, [int]$TimeoutMs) {
    # ConnectAsync(string, int) 在部分 .NET 运行时会优先尝试 IPv6，
    # 而机场节点绝大多数只监听 IPv4 —— 那样每个节点都要白等一整个超时，
    # 看起来像「全都不通」。这里先解析成 IPv4 再连。
    $addresses = @()
    try {
        # 用 TryParse 判断是不是 IP，避免正则里再套转义（之前用字符串拼 \\d 拼错，导致全部节点被误判）
        $parsed = $null
        $ipObj = [System.Net.IPAddress]::Any
        $isIp = [System.Net.IPAddress]::TryParse($Server, [ref]$ipObj)
        if ($isIp) {
            $addresses = @($Server)
        }
        else {
            $resolved = [System.Net.Dns]::GetHostAddresses($Server) |
                        Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork }
            $addresses = @($resolved | ForEach-Object { $_.IPAddressToString })
        }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Ms = -1 }
    }
    if ($addresses.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Ms = -1 } }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($ip in $addresses) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync($ip, $Port)
            $w = $task.Wait($TimeoutMs)
            if ($w -and $client.Connected) {
                $sw.Stop()
                return [pscustomobject]@{ Ok = $true; Ms = [int]$sw.ElapsedMilliseconds }
            }
        }
        catch { }
        finally { $client.Close() }

        if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { break }
    }
    $sw.Stop()
    return [pscustomobject]@{ Ok = $false; Ms = -1 }
}
# TCP 握手只能验证「监听 TCP 端口的节点」。
# hysteria2 / QUIC 类节点走 UDP，TCP 探测必然失败 —— 这是探测方式的局限，不是节点坏了。
# IPv6-only 节点也一样：多数家庭宽带没有可用 IPv6 出口。
function Get-ProbeApplicable([string]$Type, [string]$Name) {
    if ($Type -match 'hysteria|quic|tuic') { return 'none' }
    if ($Name -match 'IPv6') { return 'none' }
    return 'tcp'
}

$results = New-Object System.Collections.ArrayList
foreach ($n in $nodes) {
    # 注意：Task.Wait(int) 的参数单位是毫秒，不是秒。之前传秒数导致 4 秒实际只等 4 毫秒，
    # 所有节点都被误判成不通。这里统一用毫秒。
    $r = Test-NodePort -Server $n.Server -Port $n.Port -TimeoutMs $TimeoutMs
    $applicable = Get-ProbeApplicable -Type $n.Type -Name $n.Name
    [void]$results.Add([pscustomobject]@{
        Name       = $n.Name
        Region     = (Get-Region $n.Name)
        Type       = $n.Type
        Ok         = $r.Ok
        Ms         = $r.Ms
        Applicable = $applicable
    })
}

# 只统计 TCP 可探测的节点：UDP 协议与 IPv6 节点的失败是探测方式导致的，混进分母会误导
$probeable = @($results | Where-Object { $_.Applicable -eq 'tcp' })
$skipped = @($results | Where-Object { $_.Applicable -ne 'tcp' })
$alive = @($probeable | Where-Object { $_.Ok })
$rate = if ($probeable.Count -gt 0) { [math]::Round($alive.Count * 100 / $probeable.Count, 1) } else { 0 }

$md = New-Object System.Collections.ArrayList
[void]$md.Add('# 节点实测报告')
[void]$md.Add('')
[void]$md.Add(('生成时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm')))
[void]$md.Add(('检测方式：TCP 握手（' + $TimeoutMs + 'ms 超时），不建隧道、不消耗流量'))
[void]$md.Add('')
[void]$md.Add(('**TCP 可探测节点存活 ' + $alive.Count + ' / ' + $probeable.Count + '（' + $rate + '%）**'))
if ($skipped.Count -gt 0) {
    [void]$md.Add('')
    [void]$md.Add(('另有 ' + $skipped.Count + ' 个节点不适用 TCP 探测（UDP 协议如 hysteria2 / QUIC，或 IPv6-only），未计入分母。'))
}
[void]$md.Add('')

[void]$md.Add('## 按地区')
[void]$md.Add('')
[void]$md.Add('| 地区 | 总数 | 存活 | 存活率 | 最快节点 |')
[void]$md.Add('|---|---|---|---|---|')
foreach ($g in ($probeable | Group-Object Region | Sort-Object { @($_.Group | Where-Object { $_.Ok }).Count } -Descending)) {
    $ga = @($g.Group | Where-Object { $_.Ok })
    $fast = if ($ga.Count -gt 0) { ($ga | Sort-Object Ms | Select-Object -First 1) } else { $null }
    $fastTxt = if ($fast) { ($fast.Name + ' (' + $fast.Ms + 'ms)') } else { '—' }
    [void]$md.Add(('| {0} | {1} | {2} | {3}% | {4} |' -f $g.Name, $g.Count, $ga.Count, [math]::Round($ga.Count * 100 / $g.Count, 0), $fastTxt))
}

[void]$md.Add('')
[void]$md.Add('## 按协议')
[void]$md.Add('')
[void]$md.Add('| 协议 | 总数 | 存活 |')
[void]$md.Add('|---|---|---|')
foreach ($g in ($probeable | Group-Object Type | Sort-Object Count -Descending)) {
    $ga = @($g.Group | Where-Object { $_.Ok })
    [void]$md.Add(('| {0} | {1} | {2} |' -f $g.Name, $g.Count, $ga.Count))
}

[void]$md.Add('')
[void]$md.Add('## 明细（按延迟排序，不通的排在最后）')
[void]$md.Add('')
[void]$md.Add('| 节点 | 地区 | 协议 | 延迟 |')
[void]$md.Add('|---|---|---|---|')
foreach ($r in ($results | Sort-Object @{Expression={ if ($_.Applicable -ne 'tcp') { 2 } elseif ($_.Ok) { 0 } else { 1 } } }, @{Expression={ $_.Ms }})) {
    $lat = '不通'
    if ($r.Applicable -ne 'tcp') { $lat = '不适用 TCP' }
    elseif ($r.Ok) { $lat = ('' + $r.Ms + ' ms') }
    [void]$md.Add(('| {0} | {1} | {2} | {3} |' -f $r.Name, $r.Region, $r.Type, $lat))
}

[void]$md.Add('')
[void]$md.Add('> TCP 通 ≠ 能上网：握手只说明端口可达，不代表协议正确、线路稳定。')
[void]$md.Add('> 要更精确的结果，请在 Clash 里用「测试延迟」（走真实 URL 探测）。')

$out = $md -join [string][char]10
Write-Host $out
[System.IO.File]::WriteAllText($OutFile, $out, (New-Object System.Text.UTF8Encoding($false)))

# 把「节点级」结论落进 data/nodes.json：入口可达（check_links）和节点可用（这里）是两件事，
# 用户真正关心的是后者。CI 没有订阅，跑不了这一步，所以文件只由本机手动生成，
# 体检 workflow 只读它、不重写它。
if ($WriteData) {
    $nodesPath = Join-Path $root 'data/nodes.json'
    $store = @{ updated = (Get-Date).ToString('yyyy-MM-dd'); airports = @() }
    if (Test-Path -LiteralPath $nodesPath) {
        try { $store = Get-Content -LiteralPath $nodesPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
    }
    $key = if ($Airport) { $Airport } else { 'default' }
    $entry = [pscustomobject]@{
        airport       = $key
        checked       = (Get-Date).ToString('yyyy-MM-dd')
        method        = ('TCP handshake (' + $TimeoutMs + 'ms)')
        probeable     = $probeable.Count
        alive         = $alive.Count
        alive_percent = $rate
        skipped       = $skipped.Count
    }
    $kept = @(@($store.airports) | Where-Object { $_ -and $_.airport -ne $key })
    $store.airports = [object[]](@($kept) + @($entry))
    $store | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $nodesPath -Encoding UTF8
    Write-Host ('已写入 ' + $nodesPath + '（' + $key + '：' + $alive.Count + '/' + $probeable.Count + '）')
}

if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $out -Encoding utf8
}
