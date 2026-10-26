<#
airport-nav 每周链接体检

用法：
  ./scripts/check_links.ps1                          # 本地预检：无响应不判死，只标记 unknown
  ./scripts/check_links.ps1 -Runner github-actions   # CI 环境：无响应才判 dead
  ./scripts/check_links.ps1 -KeepProxy               # 保留系统代理环境变量（默认清空，防失效代理误判）

行为：
  1. 逐个请求每个机场的 entry_url 和 backup_domains；
  2. 入口无响应时自动尝试备用域名；备用域名可用则自动升级为入口；
  3. 结果（status / http_code / final_url / last_checked / checked_from）写回 data/airports.json。
  4. 只要服务器有任何 HTTP 响应（含 301/302/403 人机验证）即视为入口存活。
#>
param(
    [string]$Runner = "local",
    [int]$TimeoutSec = 12,
    [switch]$KeepProxy
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$dataPath = Join-Path $root 'data/airports.json'
$today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')

# 本机默认清空代理环境变量：本机代理可能失效，会把活站全部误判成无响应
if (-not $KeepProxy) {
    foreach ($v in @('HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy')) {
        Remove-Item "env:$v" -ErrorAction SilentlyContinue
    }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$utf8 = New-Object System.Text.UTF8Encoding($false)
$airports = Get-Content -LiteralPath $dataPath -Raw -Encoding UTF8 | ConvertFrom-Json

function Ensure-Property($obj, $name, $default) {
    if (-not ($obj.PSObject.Properties.Name -contains $name)) {
        $obj | Add-Member -NotePropertyName $name -NotePropertyValue $default
    }
}

foreach ($a in $airports) {
    Ensure-Property $a 'status'      'unknown'
    Ensure-Property $a 'http_code'   0
    Ensure-Property $a 'final_url'   $null
    Ensure-Property $a 'last_checked' $today
    Ensure-Property $a 'checked_from' $Runner

function Get-FinalUri($resp) {
    if ($null -eq $resp) { return $null }
    if ($null -ne $resp.RequestMessage -and $null -ne $resp.RequestMessage.RequestUri) {
        return $resp.RequestMessage.RequestUri.AbsoluteUri
    }
    if ($null -ne $resp.ResponseUri) {
        return $resp.ResponseUri.AbsoluteUri
    }
    return $null
}

function Test-Url([string]$url, [int]$timeout) {
    try {
        $r = Invoke-WebRequest -Uri $url -Method Head -TimeoutSec $timeout -MaximumRedirection 5 -UseBasicParsing -ErrorAction Stop
        return @{ Code = [int]$r.StatusCode; Final = (Get-FinalUri $r.BaseResponse) }
    } catch {
        $resp = $_.Exception.Response
        if ($resp) {
            return @{ Code = [int]$resp.StatusCode; Final = (Get-FinalUri $resp) }
        }
        return @{ Code = 0; Final = $null }
    }
}

foreach ($a in $airports) {
    $targets = @($a.entry_url) + @($a.backup_domains)
    $best = $null
    foreach ($u in $targets) {
        if (-not $u -or $u -notmatch '^https?://') { continue }
        $res = Test-Url $u $TimeoutSec
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
    } else {
        $a.http_code = 0
        $a.final_url = $null
        if ($Runner -eq 'github-actions') {
            $a.status = 'dead'
        } elseif ($a.status -ne 'dead') {
            $a.status = 'unknown'
        }
    }

    $a.last_checked = $today
    $a.checked_from = $Runner
    Write-Host ("{0,-14} -> {1}" -f $a.name, $a.status)
}

[System.IO.File]::WriteAllText($dataPath, ($airports | ConvertTo-Json -Depth 10), $utf8)
Write-Host "已写回 $dataPath"
