#Requires -Version 5.1
<#
airport-nav 数据与脚本预检（零外部依赖，CI 与本地都能跑）

用法：
  ./scripts/validate.ps1

检查内容：
  1. 脚本语法：用 PowerShell 自带的 Parser 解析 scripts/*.ps1，不用装 PSScriptAnalyzer
     （语法错在 CI 里本来也会炸，但这里能提前到渲染之前，并指出具体行号）
  2. 数据完整性：data/*.json 的必填字段、枚举值、URL 格式、名称唯一、日期格式
  3. 一致性：entry_url 不能同时出现在自己的 backup_domains 里

退出码：0 = 全部通过，1 = 有错误（CI 会据此中断，不会把坏数据渲染上线）
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$errs = New-Object System.Collections.Generic.List[string]
$warns = New-Object System.Collections.Generic.List[string]

function Add-Err([string]$Msg) { $script:errs.Add($Msg) }
function Add-Warn([string]$Msg) { $script:warns.Add($Msg) }

function Test-UrlText([string]$Value) {
    return ($Value -match '^https?://[^\s/]+')
}

# ---------------- 1. 脚本语法 ----------------

$scriptFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Filter '*.ps1' -File)
if ($scriptFiles.Count -eq 0) { Add-Err 'scripts/ 下没有找到任何 .ps1' }

foreach ($f in $scriptFiles) {
    $parseErr = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$parseErr)
    foreach ($e in @($parseErr)) {
        Add-Err ("脚本语法 {0}:{1} -> {2}" -f $f.Name, $e.Extent.StartLineNumber, $e.Message)
    }
}

# ---------------- 2. 数据完整性 ----------------

function Import-DataFile([string]$RelPath, [string]$Label) {
    $path = Join-Path $root $RelPath
    if (-not (Test-Path -LiteralPath $path)) {
        Add-Err ("{0}：找不到文件 {1}" -f $Label, $RelPath)
        return @()
    }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Add-Err ("{0}：JSON 解析失败 -> {1}" -f $Label, $_.Exception.Message)
        return @()
    }
    $list = @($raw)
    if ($list.Count -eq 0) { Add-Err ("{0}：数组为空" -f $Label) }
    # 逗号运算符防止单元素数组在 return 时被展开成标量：展开后 5.1 的 .Count 会是空值
    return ,$list
}

function Test-RequiredFields($Item, [string]$Where, [string[]]$Fields) {
    foreach ($f in $Fields) {
        $v = $Item.$f
        if ($null -eq $v -or ([string]$v).Trim() -eq '') {
            Add-Err ("{0}：缺少字段 {1}" -f $Where, $f)
        }
    }
}

# --- 机场 ---

$airports = Import-DataFile 'data/airports.json' 'airports.json'
$seenNames = @{}
$tierAllowed = @('低价', '性价比')
# 引入统一状态库：允许值、受限码表都以 lib-status.ps1 为准
. (Join-Path $PSScriptRoot 'lib-status.ps1')
$statusAllowed = $script:AllowedStatus

$idx = 0
foreach ($a in $airports) {
    $idx++
    $label = if ($a.name) { "airports.json[$idx] $($a.name)" } else { "airports.json[$idx]" }

    Test-RequiredFields $a $label @('tier', 'name', 'entry_url', 'price', 'traffic', 'line', 'notes', 'source')

    if ($a.tier -and ($tierAllowed -notcontains [string]$a.tier)) {
        Add-Err ("{0}：tier 只能是 低价 / 性价比，实际是 '{1}'" -f $label, $a.tier)
    }
    if ($a.name) {
        $key = [string]$a.name
        if ($seenNames.ContainsKey($key)) { Add-Err ("{0}：名称重复（另一条在 [{1}]）" -f $label, $seenNames[$key]) }
        else { $seenNames[$key] = $idx }
    }
    if ($a.entry_url -and -not (Test-UrlText ([string]$a.entry_url))) {
        Add-Err ("{0}：entry_url 不是 http(s) 链接 -> {1}" -f $label, $a.entry_url)
    }
    if ($a.status -and ($statusAllowed -notcontains [string]$a.status)) {
        Add-Err ("{0}：status 只能是 {1}，实际是 '{2}'" -f $label, ($statusAllowed -join ' / '), $a.status)
    }
    # 一致性检查：标了 ok 但 HTTP 码是受限类的，属于数据没跟上口径（旧数据或手改漏了），
    # 展示层仍会按"受限"渲染，但这里要提醒把它归位。
    if ([string]$a.status -eq 'ok' -and $a.http_code -and (Test-RestrictedCode ([int]$a.http_code))) {
        Add-Warn ("{0}：status=ok 但 http_code={1} 属于受限类，建议改成 restricted（展示层已按受限处理）" -f $label, $a.http_code)
    }

    # reachable_via 记录入口是通过哪条通道探测到的。
    # 活着（ok）的条目必须有这个字段，否则页面上分不清「直连可达」和「仅墙外可达」；
    # 死站（dead）允许为空，因为压根没探测成功。
    $viaAllowed = @('direct', 'proxy', '')
    if ($a.PSObject.Properties.Name -contains 'reachable_via') {
        $via = [string]$a.reachable_via
        if ($viaAllowed -notcontains $via) {
            Add-Err ("{0}：reachable_via 只能是 direct / proxy / 空，实际是 '{1}'" -f $label, $via)
        }
        if ($a.status -eq 'ok' -and $via -eq '') {
            Add-Warn ("{0}：状态为 ok 但缺 reachable_via，页面上无法标注是否仅墙外可达" -f $label)
        }
    }
    elseif ($a.status -eq 'ok') {
        Add-Warn ("{0}：状态为 ok 但没有 reachable_via 字段" -f $label)
    }

    $bk = @(@($a.backup_domains) | Where-Object { $_ })
    foreach ($u in $bk) {
        if (-not (Test-UrlText ([string]$u))) { Add-Err ("{0}：backup_domains 里有非 http(s) 链接 -> {1}" -f $label, $u) }
        if ([string]$u -eq [string]$a.entry_url) { Add-Err ("{0}：backup_domains 里重复写了 entry_url -> {1}" -f $label, $u) }
    }
    if ($bk.Count -gt 5) { Add-Warn ("{0}：backup_domains 有 {1} 条，README 只展示第一条，建议精简" -f $label, $bk.Count) }

    $proto = @(@($a.protocols) | Where-Object { $_ })
    if ($proto.Count -eq 0) { Add-Err ("{0}：protocols 不能为空（未知就写 未知）" -f $label) }

    if ($a.last_checked -and ([string]$a.last_checked -notmatch '^\d{4}-\d{2}-\d{2}$')) {
        Add-Err ("{0}：last_checked 应为 YYYY-MM-DD -> {1}" -f $label, $a.last_checked)
    }
    if ($null -ne $a.http_code -and ([string]$a.http_code -notmatch '^\d{1,3}$')) {
        Add-Err ("{0}：http_code 应为数字 -> {1}" -f $label, $a.http_code)
    }
}

# --- 客户端工具 ---

$tools = Import-DataFile 'data/tools.json' 'tools.json'
$toolNames = @{}
$idx = 0
foreach ($t in $tools) {
    $idx++
    $label = if ($t.name) { "tools.json[$idx] $($t.name)" } else { "tools.json[$idx]" }
    Test-RequiredFields $t $label @('name', 'url', 'category', 'platform')
    if ($t.name) {
        if ($toolNames.ContainsKey([string]$t.name)) { Add-Err ("{0}：名称重复" -f $label) }
        else { $toolNames[[string]$t.name] = $idx }
    }
    if ($t.url -and -not (Test-UrlText ([string]$t.url))) {
        Add-Err ("{0}：url 不是 http(s) 链接 -> {1}" -f $label, $t.url)
    }
}

# --- 参考资源 ---

$resources = Import-DataFile 'data/resources.json' 'resources.json'
$resNames = @{}
$idx = 0
foreach ($r in $resources) {
    $idx++
    $label = if ($r.name) { "resources.json[$idx] $($r.name)" } else { "resources.json[$idx]" }
    Test-RequiredFields $r $label @('name', 'url', 'type')
    if ($r.name) {
        if ($resNames.ContainsKey([string]$r.name)) { Add-Err ("{0}：名称重复" -f $label) }
        else { $resNames[[string]$r.name] = $idx }
    }
    if ($r.url -and -not (Test-UrlText ([string]$r.url))) {
        Add-Err ("{0}：url 不是 http(s) 链接 -> {1}" -f $label, $r.url)
    }
}

# ---------------- 3. 输出 ----------------

"预检范围：脚本 {0} 个，机场 {1} 家，客户端 {2} 个，资源 {3} 条" -f $scriptFiles.Count, $airports.Count, $tools.Count, $resources.Count

foreach ($w in $warns) { Write-Warning $w }

if ($errs.Count -gt 0) {
    ""
    "发现 {0} 个问题：" -f $errs.Count
    foreach ($e in $errs) { "  ✗ $e" }
    if ($env:GITHUB_STEP_SUMMARY) {
        $md = @('### 数据预检未通过', '')
        $md += ($errs | ForEach-Object { "- $($_)" })
        Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value ($md -join [string][char]10) -Encoding utf8
    }
    exit 1
}

foreach ($w in $warns) { "  ! $w" }
"预检通过：数据与脚本均无问题。"
exit 0
