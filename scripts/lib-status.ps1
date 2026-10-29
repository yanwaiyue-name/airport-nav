# 状态口径的唯一真源。
#
# 为什么单独抽一个文件：
#   同一个"受限"判定原先散在 check_links（写状态）、render（画徽章）、
#   docs/index.html（网页端）三个地方，改一处漏两处就会出现
#   "README 显示 ⚠️受限、网页仍显示 ✅存活" 这种自相矛盾。
#   现在 PowerShell 侧统一读这里，网页侧由 render 把码表注入 NAV_DATA。
#
# 什么是"受限"：
#   服务器有响应，但返回的是 401/403/429/503 这类"我知道你来了，但不给你服务"的码。
#   典型场景是 Cloudflare 防护页、站点已停售只留跳转、或对境外 IP 统一拒绝。
#   它证明不了"这家还能注册、还能付款"，所以不能和 200 的站点并列显示为 ✅存活。

$script:RestrictedHttpCodes = @(401, 402, 403, 405, 407, 429, 451, 503, 521, 522, 523, 524, 525, 526, 530)

# 允许写入 status 的取值。新增 restricted 是为了让数据层自己说清"受限"，
# 而不是只看 ok + http_code 的组合——外部脚本读 JSON 时不会再误判成健康站。
$script:AllowedStatus = @('ok', 'restricted', 'unknown', 'dead')

function Test-RestrictedCode([int]$Code) {
    return ($script:RestrictedHttpCodes -contains $Code)
}

# 把 (status, http_code) 归一成展示用的四态：ok / restricted / unknown / dead
#
# 这里要同时兼容两种历史数据：
#   1. 新数据：status 直接是 restricted
#   2. 旧数据：status 仍是 ok，但 http_code 是 403 —— 不能因为没迁移就当健康站
# 两者都要落到 restricted，否则老数据会被误显示成 ✅存活。
function Get-EffectiveStatus([string]$Status, $HttpCode) {
    if ($Status -eq 'dead') { return 'dead' }
    if ($Status -eq 'restricted') { return 'restricted' }
    if ($Status -ne 'ok') { return 'unknown' }
    $code = 0
    try { $code = [int]$HttpCode } catch { $code = 0 }
    if (Test-RestrictedCode $code) { return 'restricted' }
    return 'ok'
}
