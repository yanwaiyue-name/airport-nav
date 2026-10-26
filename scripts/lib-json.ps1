#Requires -Version 5.1
<#
airport-nav 共用的确定性 JSON 序列化

为什么不用 ConvertTo-Json：
  Windows PowerShell 5.1 与 PowerShell 7 的 ConvertTo-Json 输出格式不同 ——
  5.1 输出 '":  "'（冒号后两个空格）、嵌套缩进步长是 2/8/10 这种混乱值；
  7 输出 '": "'（一个空格）、缩进步长稳定为 2。
  只靠正则去改缩进无法把两者对齐，结果是本地预检生成的文件与 CI 生成的差几千行，
  每周提交都会产生假 diff。这里自己序列化，保证两边逐字节一致。

约定：
  缩进默认 2 空格（data.js 用），可用 -Indent 指定（data/*.json 用 4）；
  键值分隔固定 '": "'；键序沿用对象属性顺序；非 ASCII 字符原样输出（UTF-8 写入，不加 BOM）。
  空数组输出 []，空对象输出 {}，null 输出 null，布尔输出 true/false，数字用 InvariantCulture。
#>

$script:JsonNL = [string][char]10

function ConvertTo-StableJsonString {
    param([string]$Value)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Value.ToCharArray()) {
        if ($ch -eq '"') { [void]$sb.Append('\"') }
        elseif ($ch -eq '\') { [void]$sb.Append('\\') }
        elseif ($ch -eq "`b") { [void]$sb.Append('\b') }
        elseif ($ch -eq "`f") { [void]$sb.Append('\f') }
        elseif ($ch -eq "`n") { [void]$sb.Append('\n') }
        elseif ($ch -eq "`r") { [void]$sb.Append('\r') }
        elseif ($ch -eq "`t") { [void]$sb.Append('\t') }
        elseif ([int]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$ch)) }
        else { [void]$sb.Append($ch) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-StableJson {
    param($Value, [int]$Level = 0, [int]$Indent = 2)

    $NL   = $script:JsonNL
    $pad  = ' ' * ($Level * $Indent)
    $pad2 = ' ' * (($Level + 1) * $Indent)
    $inv  = [System.Globalization.CultureInfo]::InvariantCulture

    if ($null -eq $Value) { return 'null' }

    if ($Value -is [string]) { return (ConvertTo-StableJsonString -Value $Value) }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return ([string]::Format($inv, '{0}', $Value))
    }

    # 有序字典与普通哈希表都按 IDictionary 处理；PSCustomObject 按其属性顺序输出
    $pairs = New-Object System.Collections.ArrayList
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($k in $Value.Keys) { [void]$pairs.Add(@([string]$k, $Value[$k])) }
    }
    elseif ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Value.PSObject.Properties) { [void]$pairs.Add(@($p.Name, $p.Value)) }
    }
    elseif ($Value -is [System.Collections.IEnumerable]) {
        $parts = New-Object System.Collections.ArrayList
        foreach ($e in $Value) {
            [void]$parts.Add($pad2 + (ConvertTo-StableJson -Value $e -Level ($Level + 1) -Indent $Indent))
        }
        if ($parts.Count -eq 0) { return '[]' }
        return ('[' + $NL + ($parts -join (',' + $NL)) + $NL + $pad + ']')
    }
    else { return (ConvertTo-StableJsonString -Value ([string]$Value)) }

    if ($pairs.Count -eq 0) { return '{}' }
    $lines = New-Object System.Collections.ArrayList
    foreach ($it in $pairs) {
        [void]$lines.Add($pad2 + (ConvertTo-StableJsonString -Value $it[0]) + ': ' + (ConvertTo-StableJson -Value $it[1] -Level ($Level + 1) -Indent $Indent))
    }
    return ('{' + $NL + ($lines -join (',' + $NL)) + $NL + $pad + '}')
}
