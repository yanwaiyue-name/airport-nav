<#
airport-nav 渲染脚本：data/*.json -> README.md + docs/data.js

用法：
  ./scripts/render.ps1

说明：
  README.md 由本脚本生成，人工不要直接编辑 README，改 data/*.json 后重跑本脚本。
#>
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$utf8 = New-Object System.Text.UTF8Encoding($false)

$airports = Get-Content -LiteralPath (Join-Path $root 'data\airports.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$tools    = Get-Content -LiteralPath (Join-Path $root 'data\tools.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$order = @{ ok = 0; unknown = 1; dead = 2 }
$sorted = @($airports | Sort-Object { $order[[string]$_.status] })
$today = if ($sorted.Count -gt 0 -and $sorted[0].last_checked) { [string]$sorted[0].last_checked } else { '未知' }
$okCount = @($sorted | Where-Object { $_.status -eq 'ok' }).Count

function Badge([string]$s, $code) {
    if ($s -eq 'ok') { if ($code) { "✅存活($code)" } else { "✅存活" } }
    elseif ($s -eq 'dead') { "❌失效" }
    else { "❓未验证" }
}

function Clean([string]$s) {
    if (-not $s) { return '—' }
    return ($s -replace '\|', '／')
}

$apRows = foreach ($a in $sorted) {
    $bk = @($a.backup_domains | Where-Object { $_ })
    $bkTxt = if ($bk.Count -gt 0) { "[备用×$($bk.Count)]($($bk[0]))" } else { '—' }
    $st = Badge ([string]$a.status) $a.http_code
    $chk = "{0}({1})" -f $a.last_checked, $a.checked_from
    "| [{0}]({1}) | {2} | {3} | {4} | {5} | {6} | {7} | {8} |" -f `
        $a.name, $a.entry_url, (Clean $a.line), (Clean $a.price), (Clean $a.traffic), $st, $bkTxt, $chk, (Clean $a.notes)
}
$apTable = $apRows -join "`n"

$toolRows = foreach ($t in $tools) {
    "| [{0}]({1}) | {2} | {3} |" -f $t.name, $t.url, $t.platform, (Clean $t.notes)
}
$toolTable = $toolRows -join "`n"

$template = @'
# airport-nav · 机场导航

> 低价机场 / 客户端速查 / 新手避坑，一站式导航。**每周自动体检，只列"现在还能打开"的入口。**

共收录 **{COUNT}** 家低价机场，最近一次体检 **{OKCOUNT}** 家存活（{TODAY}）。可搜索的网页版见：https://yanwaiyue-name.github.io/airport-nav/

## 怎么用（3 步）

1. 看下面表格的「状态」列，优先选 ✅ 存活的；
2. 点「名称」进官网，**先买最小周期**（试用/月付）验证速度和稳定性，满意再考虑长周期；
3. 担心域名被封？点「备用」列——多数机场有官方地址发布页或备用域名。

## 低价机场速查表

| 名称 | 线路 | 价格 | 流量 | 状态 | 备用 | 最后验证 | 备注 |
|---|---|---|---|---|---|---|---|
{APTABLE}

> **状态说明**：✅存活 = 最近一次检测服务器有响应；❓未验证 = 本次检测环境无法判定（DNS 污染/被墙），不一定是死链；❌失效 = GitHub Actions 检测无响应。检测只代表**入口可达**，不代表速度与实际可用性。`最后验证` 列标注检测日期与来源：`github-actions` = 境外 CI 检测，`local` = 本地预检。
>
> **数据来源**：公开评测仓库（[kamibababa/cheapairport](https://github.com/kamibababa/cheapairport)、[KaWaIDeSuNe/dijiajichang](https://github.com/KaWaIDeSuNe/dijiajichang) 等）与机场官方发布页。来源链接中的邀请码已全部去除，本项目与所列机场无利益关系。

## 客户端速查

| 客户端 | 平台 | 说明 |
|---|---|---|
{TOOLTABLE}

> 各客户端的**官方下载直链**（按电脑架构自动选版本，43 款 AI 与网络工具每周体检）见姊妹项目 **[agent-download](https://github.com/yanwaiyue-name/agent-download)**。

## 新手避坑指南

1. **先看状态列再点链接**：❌ 失效的别浪费时间；❓ 未验证不一定是死链，去「来源」仓库找最新入口。
2. **域名被封 ≠ 跑路**：先去机场的官方地址发布页 / GitHub 仓库 / 官方群找新域名，多数机场会公布备用入口。
3. **先月付，再年付**：低价机场跑路风险普遍高于大机场，月付验证一个月稳定性后再考虑年付。
4. **3 元/年这类超低价当"备用玩具"**：适合当第二备用或尝鲜，不要把重要流量全押在上面。
5. **跑路前兆**：长期不发公告、官方群解散或禁言、支付通道频繁更换、突然大幅清仓促销——占两条以上就该准备备用方案。
6. **多方评测交叉验证**：很多推荐仓库带邀请返利，单一来源的好评可信度要打折。
7. **支付方式**：支持支付宝/微信、有工单系统的相对靠谱；只收虚拟币的要多留心眼。
8. **特殊时期入口更易被封**：提前备好至少两个机场，别把鸡蛋放一个篮子。
9. **隐私常识**：机场能看到你的连接元数据，敏感账号的登录尽量不要走小机场节点。
10. **本页数据每周六自动更新**：看到「最后验证」是很久以前的，谨慎对待。

## 自动体检是怎么做的

- 每周六 11:00（北京时间）GitHub Actions 自动运行 [check_links.ps1](scripts/check_links.ps1)，逐个请求各机场入口；
- 入口打不开时自动尝试备用域名，备用域名可用则自动升级为新入口；全部无响应才标记失效（仅 CI 环境判死，本地预检不判死）；
- 结果自动写回 [data/airports.json](data/airports.json)，并重新生成本 README 和 [导航网页](https://yanwaiyue-name.github.io/airport-nav/)。

## 参与贡献

1. Fork 后修改 [data/airports.json](data/airports.json)（新增/修正机场信息），提交 PR；
2. 合并后每周六自动体检，也可在 Actions → weekly-check → Run workflow 手动触发；
3. 字段说明：`name` 名称；`entry_url` 官网入口；`backup_domains` 备用入口（地址发布页也算）；`price` 价格档位；`traffic` 流量；`line` 线路类型（直连/中转）；`protocols` 协议；`notes` 备注（写明来源与风险）；`source` 信息来源仓库；`status`/`http_code`/`last_checked`/`checked_from`/`final_url` 由体检脚本维护，人工不用填。

## 免责声明

- 本项目仅汇总公开渠道信息，供个人选择参考；不托管、不代理、不销售任何服务；
- 收录 ≠ 推荐，低价机场跑路风险普遍偏高，请自行判断并小周期试用；
- 请遵守你所在地区的法律法规。
'@

$md = $template.Replace('{COUNT}', "$($sorted.Count)").Replace('{OKCOUNT}', "$okCount").Replace('{TODAY}', $today).Replace('{APTABLE}', $apTable).Replace('{TOOLTABLE}', $toolTable)
[System.IO.File]::WriteAllText((Join-Path $root 'README.md'), $md, $utf8)

$nav = @{ generated = $today; airports = $sorted; tools = $tools }
[System.IO.File]::WriteAllText((Join-Path $root 'docs\data.js'), ('window.NAV_DATA = ' + ($nav | ConvertTo-Json -Depth 10) + ';'), $utf8)
Write-Host ("README.md 与 docs/data.js 已生成：{0} 家机场，{1} 家存活（{2}）" -f $sorted.Count, $okCount, $today)
