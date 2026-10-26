#Requires -Version 5.1
<#
.SYNOPSIS
  入口落地页品牌核对：抓首页标题/关键词，检查是否与机场名称对得上。

.DESCRIPTION
  为什么要做这件事：
    「官网能打开」不等于「打开的是这家机场」。域名被封、换牌、转卖、停放页
    都会让入口 200 但内容完全是另一家 —— 2026-10-26 就实测到
    星河云 -> app.zhizi8.com 落地页品牌是「反质子」。

  本脚本只做取证与提示，不改数据：
    抓 entry_url 的最终落地页，提取 <title> 与正文前 8KB 文本，
    用机场名称里的 2 字以上片段做匹配。匹配不上就标记 brand_ok=false，
    由人工确认后再改 notes/entry_url。

  为什么不做自动改：换牌与「官方换域名」外观一致，机器分不清，
  贸然改数据会把正常的备用域名当成劫持处理。

.EXAMPLE
  ./scripts/check_brand.ps1
  ./scripts/check_brand.ps1 -DataPath ../x.json
#>
[CmdletBinding()]
param(
    [string]$DataPath,
    [int]$TimeoutSec = 20
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
if (-not $DataPath) { $DataPath = Join-Path $root 'data/airports.json' }

$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'

function Get-PageProbe([string]$Url) {
    $client = $null
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $h = [System.Net.Http.HttpClientHandler]::new()
        $h.AllowAutoRedirect = $true
        $h.MaxAutomaticRedirections = 5
        $h.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
        $client = [System.Net.Http.HttpClient]::new($h)
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
        [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $UA)

        $resp = $client.GetAsync($Url).GetAwaiter().GetResult()
        $code = [int]$resp.StatusCode
        $final = $Url
        if ($resp.RequestMessage -and $resp.RequestMessage.RequestUri) { $final = $resp.RequestMessage.RequestUri.AbsoluteUri }

        $body = ''
        try { $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() } catch { }
        $resp.Dispose()

        $title = ''
        $m = [regex]::Match($body, '<title[^>]*>([^<]*)</title>')
        if ($m.Success) { $title = $m.Groups[1].Value.Trim() }

        $text = ''
        if ($body.Length -gt 0) {
            $snippet = $body
            if ($snippet.Length -gt 8000) { $snippet = $snippet.Substring(0, 8000) }
            $text = $snippet
        }

        return [pscustomobject]@{ Code = $code; Final = $final; Title = $title; Body = $text; Error = $null }
    }
    catch {
        return [pscustomobject]@{ Code = 0; Final = $null; Title = ''; Body = ''; Error = $_.Exception.Message }
    }
    finally {
        if ($client) { $client.Dispose() }
    }
}

function Get-NameFragments([string]$Name) {
    # 把「星河云」「飞兔云」这类名字切成可用于匹配的片段：
    # 去掉括号备注，按 2-3 字滑窗切，只保留纯中文片段。
    $clean = $Name
    $p = $clean.IndexOf([char]65288)
    if ($p -gt 0) { $clean = $clean.Substring(0, $p) }
    $clean = $clean.Trim()
    # 通名（机场/云/网络）落地页常写法不同，去掉后再比主干，降低同音字误判
    foreach ($suffix in @('机场', '网络', '云')) {
        if ($clean.EndsWith($suffix) -and $clean.Length -gt ($suffix.Length + 1)) {
            $clean = $clean.Substring(0, $clean.Length - $suffix.Length)
        }
    }

    $frags = New-Object System.Collections.ArrayList
    [void]$frags.Add($clean)

    $chars = $clean.ToCharArray()
    for ($i = 0; $i -le ($chars.Length - 2); $i++) {
        $two = [string]$chars[$i] + [string]$chars[$i + 1]
        if ($two -match '^[\u4e00-\u9fa5]{2}$') { [void]$frags.Add($two) }
    }
    return $frags
}

$data = Get-Content -LiteralPath $DataPath -Raw -Encoding UTF8 | ConvertFrom-Json
$airports = @($data)

$rows = New-Object System.Collections.ArrayList
$suspect = 0
$unknown = 0

foreach ($a in $airports) {
    $url = [string]$a.entry_url
    if ([string]::IsNullOrWhiteSpace($url)) { continue }

    $probe = Get-PageProbe $url
    if ($probe.Code -eq 0) {
        [void]$rows.Add(('| {0} | 无响应 | - | - | ? |' -f $a.name))
        $unknown++
        continue
    }

    $hay = (([string]$probe.Title + ' ' + [string]$probe.Body)).ToLowerInvariant()
    $frags = Get-NameFragments ([string]$a.name)

    $hit = $false
    $hitWord = ''
    foreach ($f in $frags) {
        if ($f.Length -ge 2 -and $hay.Contains($f.ToLowerInvariant())) { $hit = $true; $hitWord = $f; break }
    }

    $sameHost = $false
    try {
        if ($probe.Final -and $url) {
            $sameHost = (([uri]$probe.Final).Host -eq ([uri]$url).Host)
        }
    }
    catch { }

    # 人机验证页 / 跳转中页 / 空壳 200 都读不到真实内容，不能算品牌不对
    $t2 = ([string]$probe.Title).ToLower()
    $isChallenge = ($t2.Contains('just a moment') -or $t2.Contains('attention required') -or $t2.Contains('redirecting') -or $t2.Contains('moved permanently') -or $t2.Contains('安全验证') -or $t2.Contains('cloudflare'))
    $noContent = ([string]$probe.Body).Length -lt 400

    $flag = 'ok'
    if ($isChallenge -or $noContent) { $flag = 'challenge/unreadable'; $unknown++ }
    elseif (-not $hit) { $flag = 'brand-miss'; $suspect++ }
    elseif (-not $sameHost) { $flag = 'redirect-ok' }

    $shortTitle = [string]$probe.Title
    if ($shortTitle.Length -gt 28) { $shortTitle = $shortTitle.Substring(0, 28) + '...' }
    $shortTitle = $shortTitle.Replace('|', '/')

    [void]$rows.Add(('| {0} | {1} | {2} | {3} | {4} |' -f $a.name, $flag, $shortTitle, $probe.Code, $hitWord))
}

$md = New-Object System.Collections.ArrayList
[void]$md.Add('# 入口落地页品牌核对')
[void]$md.Add('')
[void]$md.Add(('生成时间：' + (Get-Date).ToString('yyyy-MM-dd HH:mm')))
[void]$md.Add('')
[void]$md.Add('| 机场 | 判定 | 落地页标题 | HTTP | 命中词 |')
[void]$md.Add('|---|---|---|---|---|')
foreach ($r in $rows) { [void]$md.Add($r) }
[void]$md.Add('')
[void]$md.Add('判定说明：')
[void]$md.Add('- ok：落地页内容里能找到该机场名的片段')
[void]$md.Add('- redirect-ok：发生了跨域跳转，但落地页品牌仍对得上')
[void]$md.Add('- brand-miss：读到了真实页面，但里面找不到机场名字，可能是换牌/转卖/停放页，需人工确认')
[void]$md.Add('- challenge/unreadable：Cloudflare 人机验证、跳转中页或内容过短，读不到真实品牌，不判定')
[void]$md.Add('- 无响应：本次没抓到页面')

$out = $md -join [string][char]10
Write-Host $out
[System.IO.File]::WriteAllText((Join-Path $root 'brand-report.md'), $out, (New-Object System.Text.UTF8Encoding($false)))

if ($env:GITHUB_STEP_SUMMARY) {
    Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $out -Encoding utf8
}

Write-Host ''
Write-Host ('品牌存疑 ' + $suspect + ' 家，验证页/读不到 ' + $unknown + ' 家')
exit 0
