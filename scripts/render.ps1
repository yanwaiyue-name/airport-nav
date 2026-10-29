<#
airport-nav 渲染脚本：data/*.json -> README.md + docs/data.js

用法：
  ./scripts/render.ps1

说明：
  README.md 由本脚本生成，人工不要直接编辑 README，改 data/*.json 后重跑本脚本。
  机场按 tier 分两张表（低价 / 性价比），工具按 category 汇总，参考资源单独成表。
  docs/index.html 里 <script src="data.js"> 的 ?v= 版本号由本脚本按 data.js 内容哈希自动刷新。
#>
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$NL = [string][char]10
. (Join-Path $PSScriptRoot 'lib-json.ps1')
. (Join-Path $PSScriptRoot 'lib-status.ps1')

function Get-OrdinalKey {
    # 把任意字符串按 UTF-16 码位展开成定长十六进制，得到与区域设置无关的可排序键
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Value.ToCharArray()) { [void]$sb.Append(([int]$ch).ToString('X4')) }
    return $sb.ToString()
}

$airports   = Get-Content -LiteralPath (Join-Path $root 'data/airports.json')   -Raw -Encoding UTF8 | ConvertFrom-Json
$tools      = [object[]](Get-Content -LiteralPath (Join-Path $root 'data/tools.json')      -Raw -Encoding UTF8 | ConvertFrom-Json)
$resources  = [object[]](Get-Content -LiteralPath (Join-Path $root 'data/resources.json')  -Raw -Encoding UTF8 | ConvertFrom-Json)

# 节点实测结果（可选）：由本机手动跑 check_nodes.ps1 -WriteData 生成。
# CI 上没有订阅跑不了这一步，所以文件缺失是正常状态，不能报错。
$nodePath = Join-Path $root 'data/nodes.json'
$nodeMap = @{}
if (Test-Path -LiteralPath $nodePath) {
    try {
        $nodeStore = Get-Content -LiteralPath $nodePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($n in @($nodeStore.airports)) {
            if ($n -and $n.airport) { $nodeMap[[string]$n.airport] = $n }
        }
    } catch {
        Write-Warning ('data/nodes.json 解析失败，节点实测列将留空：' + $_.Exception.Message)
    }
}

function Get-NodeNote($a) {
    # 入口能不能打开 ≠ 买了能不能用。有实测结果就显示，没有就留空 —— 不猜。
    $k = [string]$a.name
    if (-not $nodeMap.ContainsKey($k)) { return '' }
    $n = $nodeMap[$k]
    if (-not $n.probeable) { return '' }
    return ('<br>📶 节点 {0}/{1}' -f $n.alive, $n.probeable)
}

$tierOrder   = @{ '低价' = 0; '性价比' = 1 }
# 排序按"有效状态"：正常的排前面，受限次之，未验证再次，失效最后。
$statusOrder = @{ ok = 0; restricted = 1; unknown = 2; dead = 3 }

$sorted = @($airports | Sort-Object -Property @{Expression={
    # 排序键全部转成 ASCII：Sort-Object 的字符串比较受系统区域设置影响（zh-CN 与 en-US 结果不同），
    # 直接用中文名排序会让 CI 与本地生成出不同的行序，每次重跑都产生假 diff。
    # 用有效状态排序：数据里 status 可能还是 ok，但 403 的实际意义是受限，不能和正常站混排
    $effSort = Get-EffectiveStatus ([string]$_.status) $_.http_code
    '{0}|{1}|{2}' -f $tierOrder[[string]$_.tier], $statusOrder[$effSort], (Get-OrdinalKey ([string]$_.name))
}})
if ($sorted.Count -lt $airports.Count) { throw "排序后条数不一致：$($sorted.Count) / $($airports.Count)" }

$low = @($sorted | Where-Object { $_.tier -eq '低价' })
$mid = @($sorted | Where-Object { $_.tier -eq '性价比' })

$unmatched = @($sorted | Where-Object { $_.tier -ne '低价' -and $_.tier -ne '性价比' })
if ($unmatched.Count -gt 0) {
    Write-Warning ("有 {0} 家机场的 tier 不是 '低价' 或 '性价比'，不会出现在 README 表格中：{1}" -f $unmatched.Count, (($unmatched | ForEach-Object { $_.name }) -join ', '))
}

$today = if ($sorted.Count -gt 0 -and $sorted[0].last_checked) { [string]$sorted[0].last_checked } else { '未知' }
# 口径统一走 scripts/lib-status.ps1，避免"徽章一套、计数另一套"。
$okCount         = @($sorted | Where-Object { (Get-EffectiveStatus ([string]$_.status) $_.http_code) -eq 'ok' }).Count
$restrictedCount = @($sorted | Where-Object { (Get-EffectiveStatus ([string]$_.status) $_.http_code) -eq 'restricted' }).Count

function Badge([string]$s, $code) {
    # 判定逻辑在 lib-status.ps1，这里只负责画。
    # 403/429 这类响应只能证明「有服务器在拦你」，证明不了站点还能注册、还能买；
    # 很多跑路机场会留一个 Cloudflare 防护页，照样返回 403。
    $eff = Get-EffectiveStatus $s $code
    if ($eff -eq 'ok') {
        if ($code) { return "✅存活($code)" }
        return "✅存活"
    }
    if ($eff -eq 'restricted') { return "⚠️受限($code)" }
    if ($eff -eq 'dead') { return "❌失效" }
    return "❓未验证"
}

function Clean([string]$s) {
    if (-not $s) { return '—' }
    return ($s -replace '\|', '／')
}

function Get-JumpNote($a) {
    # 入口实际跳到了别的域名时提示落地域名：能打开 ≠ 打开的是这家。
    # 换牌、转卖、停放页都会表现成跨域跳转，不提示的话用户会以为还在原站点。
    if (-not $a.final_url -or -not $a.entry_url) { return '' }
    try {
        $hFrom = ([uri]$a.entry_url).Host
        $hTo   = ([uri]$a.final_url).Host
    }
    catch { return '' }
    if ($hFrom -eq $hTo) { return '' }
    return ('<br>→ ' + $hTo)
}

function Get-ViaNote($a) {
    # 只标注「仅墙外可达」：墙内直连无响应、走代理才探测到的入口，
    # 说明域名很可能被污染，用户在国内直接点是打不开的，需要先有可用代理。
    if ([string]$a.reachable_via -ne 'proxy') { return '' }
    return '<br>🌐 仅墙外可达'
}

function Make-ApRows($list) {
    $rows = foreach ($a in $list) {
        $bk = @(@($a.backup_domains) | Where-Object { $_ })
        $bkTxt = if ($bk.Count -gt 0) { "[备用×$($bk.Count)]($($bk[0]))" } else { '—' }
        $st = (Badge ([string]$a.status) $a.http_code) + (Get-ViaNote $a) + (Get-JumpNote $a) + (Get-NodeNote $a)
        $chk = "{0}({1})" -f $a.last_checked, $a.checked_from
        "| [{0}]({1}) | {2} | {3} | {4} | {5} | {6} | {7} | {8} |" -f `
            $a.name, $a.entry_url, (Clean $a.line), (Clean $a.price), (Clean $a.traffic), $st, $bkTxt, $chk, (Clean $a.notes)
    }
    return ($rows -join "`n")
}

$lowTable = Make-ApRows $low
$midTable = Make-ApRows $mid

$toolRows = foreach ($t in $tools) {
    "| [{0}]({1}) | {2} | {3} | {4} |" -f $t.name, $t.url, (Clean $t.category), $t.platform, (Clean $t.notes)
}
$toolTable = $toolRows -join "`n"

$resRows = foreach ($r in $resources) {
    "| [{0}]({1}) | {2} | {3} |" -f (Clean $r.name), $r.url, (Clean $r.type), (Clean $r.notes)
}
$resTable = $resRows -join "`n"

$template = @'
# airport-nav · 机场导航

> 📍 **本仓库是 GitHub 的镜像。** 每周体检与页面部署只在 GitHub Actions 运行，
> 因此**下面表格的「最后验证」日期在镜像上不会自动更新**，最新数据请见
> [在线导航](https://yanwaiyue-name.github.io/airport-nav/)。

> 低价机场 / 客户端速查 / 新手避坑，一站式导航。**每周自动体检，优先列出能打开的入口；确认失效的保留 ❌ 标记不删，方便你判断它有没有复活。**

共收录 **{LOWCOUNT}** 家低价机场 + **{MIDCOUNT}** 家性价比机场，最近一次体检 **{OKCOUNT}** 家正常响应、**{RESTRICTEDCOUNT}** 家受限（403/防护页）（{TODAY}）。可搜索的网页版见：https://yanwaiyue-name.github.io/airport-nav/

## 怎么用（3 步）

1. 看下面表格的「状态」列，优先选 ✅ 存活的；⚠️受限的先当"可能已经停售"处理；
2. 点「名称」进官网，**先买最小周期**（试用/月付）验证速度和稳定性，满意再考虑长周期；
3. 担心域名被封？点「备用」列——多数机场有官方地址发布页或备用域名。

> ### ⚠️ 先把这件事想清楚：低价机场能看到什么
>
> 机场是你的出口，理论上能看到你访问的**域名、时间、流量大小**，部分实现还能看到 DNS 请求和设备特征。HTTPS 保护的是内容，不是"你在访问哪个网站"。
>
> 所以：**工作账号、网银、支付、政务、公司内网**这类操作，不要放在低价机场上做。这不是"这家靠不靠谱"的问题，是这个价位模式下本来就不该托付这些事。
>
> 收录 ≠ 推荐，也不构成安全背书。本项目只做两件事：记录入口、记录入口现在还能不能打开。

## 低价机场速查表（月付 ≤10 元）

| 名称 | 线路 | 价格 | 流量 | 状态 | 备用 | 最后验证 | 备注 |
|---|---|---|---|---|---|---|---|
{LOWTABLE}

## 性价比机场（月付 10-25 元，稳定性向）

| 名称 | 线路 | 价格 | 流量 | 状态 | 备用 | 最后验证 | 备注 |
|---|---|---|---|---|---|---|---|
{MIDTABLE}

> **状态说明**：✅存活 = 最近一次检测服务器正常响应（2xx/3xx）；⚠️受限 = 服务器有响应但返回 403/429/503 等，通常是 Cloudflare 防护页或站点已停售，**不代表服务还能用**，这类站点要格外谨慎；❓未验证 = 本次检测环境无法判定（DNS 污染/被墙），不一定是死链；❌失效 = 连续两轮 GitHub Actions 检测都无响应（单轮失败先降为❓，避免一次抖动误判死链）。检测只代表**入口可达**，不代表速度与实际可用性。状态后面的 <code>→ 域名</code> 表示入口实际跳到了别的域名（换牌、转卖、停放页都会这样），不代表是官方换域名，看到就先在站内确认品牌再付款。<code>🌐 仅墙外可达</code> 表示墙内直连打不开、走代理才探测到——域名很可能被污染，**你自己在国内直接点会连不上**，需要先有一个能用的代理。`最后验证` 列标注检测日期与来源：`github-actions` = 境外 CI 检测，`local` = 本地预检。<code>📶 节点 x/y</code> 表示本机用 TCP 握手实测的节点存活数——入口能打开不等于节点能用，这一列才是"买了能不能上"的参考；它需要本机有订阅，所以只有部分条目会有。
>
> **数据来源**：公开评测仓库（[kamibababa/cheapairport](https://github.com/kamibababa/cheapairport)、[KaWaIDeSuNe/dijiajichang](https://github.com/KaWaIDeSuNe/dijiajichang)、[KaWaIDeSuNe/xingjiabijichang](https://github.com/KaWaIDeSuNe/xingjiabijichang) 等）与机场官方发布页。来源链接中的邀请码已全部去除，本项目与所列机场无利益关系。
>
> **关于"口碑"两个字的口径**：表里写"速度口碑不错""解锁好""三网推荐"这类话，**全部转述自上面的公开评测仓库，不是本项目实测**。本项目只实测两件事：入口能不能打开（`check_links.ps1`）、以及本机有订阅时的节点能不能握手（`check_nodes.ps1`，结果见 `📶` 标记）。速度、晚高峰表现、解锁能力、是否超售，本项目**没有测、也无法替你测**——不同地区、不同运营商差异极大，唯一可靠的验证方式是自己买最小周期试。
>
> **关于跳转域名**：入口跳到别的域名，可能是官方迁移、可能是转卖、也可能是停放页。本项目只负责把"跳到了哪里"记下来，**不判断那是不是官方**。付款前请在站内确认品牌名、付款主体和客服渠道是否一致。

## 客户端与工具速查

| 名称 | 类别 | 平台 | 说明 |
|---|---|---|---|
{TOOLTABLE}

> 各客户端的**官方下载直链**（按电脑架构自动选版本，47 款 AI 与网络工具每周体检）见姊妹项目 **[agent-download](https://github.com/yanwaiyue-name/agent-download)**。

## 参考资源与延伸阅读

| 资源 | 类型 | 说明 |
|---|---|---|
{RESTABLE}

> 收录标准：仓库经 GitHub API 核实存在且记录 Star/维护状态，网页经 HTTP 实测可达，验证日期见数据文件。

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

- 每周六 11:00（北京时间）GitHub Actions 自动运行 [check_links.ps1](scripts/check_links.ps1)，逐个请求各机场入口（HEAD 优先，站点不支持 HEAD 时退回 GET，带浏览器 UA）；
- 入口打不开时先重试一轮，仍打不开才尝试备用域名；备用域名可用则自动升级为新入口，**旧入口降级为备用域名保留**（不因为一次临时故障就从项目里消失）；
- 判死采用**两振出局**：单轮无响应只降为❓未验证，连续两轮都无响应才标❌失效（本地预检永不判死）；
- 判死前再换两个境外位置复核（[r.jina.ai](https://r.jina.ai) 抓取服务 + [check-host.net](https://check-host.net) 多国节点）：只要有一个地方能拿到响应，本轮仍记❓未验证——**只有美国 runner 访问不到，不代表站点已死**；两边都说看不到或都不可用时，按原规则判死；
- 结果自动写回 [data/airports.json](data/airports.json)，并重新生成本 README 和 [导航网页](https://yanwaiyue-name.github.io/airport-nav/)；
- 网页数据的引用带内容哈希版本号（`data.js?v=xxxxxxxx`），数据一变 URL 就变，避免 Pages 边缘缓存让你看到旧数据。

## 参与贡献

1. Fork 后修改 [data/airports.json](data/airports.json)（新增/修正机场信息），提交 PR；
2. 提交前先本地预检：Windows 双击仓库根目录的 `preflight.cmd`，或直接跑 `./scripts/validate.ps1`——它会检查必填字段、URL 格式、名称重复、日期格式和脚本语法，有问题直接告诉你是第几条哪个字段；
3. 合并后每周六自动体检，也可在 Actions → weekly-check → Run workflow 手动触发；
4. 字段说明：`tier` 档位（低价/性价比，按月付价格划分）；`name` 名称；`entry_url` 官网入口；`backup_domains` 备用入口（地址发布页也算）；`price` 价格档位；`traffic` 流量；`line` 线路类型（直连/中转/专线）；`protocols` 协议；`notes` 备注（写明来源与风险）；`source` 信息来源仓库；`status`/`http_code`/`last_checked`/`checked_from`/`final_url` 由体检脚本维护，人工不用填。

## 免责声明

- 本项目仅汇总公开渠道信息，供个人选择参考；不托管、不代理、不销售任何服务；
- 收录 ≠ 推荐，低价机场跑路风险普遍偏高，请自行判断并小周期试用；
- 请遵守你所在地区的法律法规。
'@

$md = $template.Replace('{LOWCOUNT}', "$($low.Count)").Replace('{MIDCOUNT}', "$($mid.Count)").Replace('{OKCOUNT}', "$okCount").Replace('{RESTRICTEDCOUNT}', "$restrictedCount").Replace('{TODAY}', $today).Replace('{LOWTABLE}', $lowTable).Replace('{MIDTABLE}', $midTable).Replace('{TOOLTABLE}', $toolTable).Replace('{RESTABLE}', $resTable)

# 输出统一成 LF。
# 拼出来的是「文件中 here-string 模板自带的换行（Windows 签出后是 CRLF）＋ 脚本用 $NL 拼的行（LF）」，
# 不归一化就会写出混行文件。配合 .gitattributes 里 README.md / docs/data.js 的 eol=lf，
# 否则在 core.autocrlf=true 的机器上每次 render 都会留下幻影 diff（git diff 为空，status 却显示 M）。
function ConvertTo-Lf([string]$Text) {
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    return $Text.Replace([string][char]13 + [string][char]10, [string][char]10)
}

[System.IO.File]::WriteAllText((Join-Path $root 'README.md'), (ConvertTo-Lf $md), $utf8)

# 网页端也要按同一套口径判断"受限"，否则会出现 README 显示 ⚠️受限、
# 而网页仍显示 ✅存活 的自相矛盾。把码表和每家机场的有效状态一起注入，
# 前端不再自己猜。
$apForWeb = foreach ($a in $sorted) {
    $eff = Get-EffectiveStatus ([string]$a.status) $a.http_code
    $copy = [ordered]@{}
    foreach ($p in $a.PSObject.Properties) { $copy[$p.Name] = $p.Value }
    $copy['effective_status'] = $eff
    [pscustomobject]$copy
}

$nav = [ordered]@{
    generated        = $today
    airports         = @($apForWeb)
    tools            = $tools
    resources        = $resources
    restricted_codes = $script:RestrictedHttpCodes
}
$navBody = 'window.NAV_DATA = ' + (ConvertTo-StableJson -Value $nav) + ';'
[System.IO.File]::WriteAllText((Join-Path $root 'docs/data.js'), (ConvertTo-Lf $navBody), $utf8)

# 缓存戳：GitHub Pages 的边缘缓存按 URL 缓存静态资源，数据换了但 URL 不变，浏览器和边缘节点可能继续发旧文件。
# 这里用 data.js 内容自身的 SHA256 前 8 位做版本号：数据一变 URL 必变，数据没变则 URL 不变，缓存照常生效。
$sha = [System.Security.Cryptography.SHA256]::Create()
try { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($navBody)) }
finally { $sha.Dispose() }
$ver = -join ($hash[0..3] | ForEach-Object { $_.ToString('x2') })

$indexPath = Join-Path $root 'docs/index.html'
$indexOld = [System.IO.File]::ReadAllText($indexPath, $utf8)
$indexNew = [regex]::Replace($indexOld, '<script src="data\.js(?:\?v=[0-9a-f]*)?"></script>', ('<script src="data.js?v=' + $ver + '"></script>'))
if ($indexNew -ne $indexOld) { [System.IO.File]::WriteAllText($indexPath, $indexNew, $utf8) }
if ($indexNew -notmatch 'data\.js\?v=[0-9a-f]{8}') {
    Write-Warning 'docs/index.html 里没找到 <script src="data.js"></script>，缓存版本号没写进去，请检查该文件。'
}

Write-Host ("README.md 与 docs/data.js 已生成：低价 {0} 家 + 性价比 {1} 家，{2} 家存活（{3}），data.js 版本 {4}" -f $low.Count, $mid.Count, $okCount, $today, $ver)
