# 输入输出路径
$inputCsv = "group.csv"
$outputCsv = "group_with_sid.csv"

# 正确读取中文编码的 CSV（GB2312 编码示例）
$groups = Import-Csv -Path $inputCsv -Encoding Default  # 对于 GB2312/GBK

# 创建结果列表
$results = foreach ($entry in $groups) {
    $groupName = $entry.Group
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($groupName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        [PSCustomObject]@{
            Group = $groupName
            SID   = $sid
        }
    } catch {
        [PSCustomObject]@{
            Group = $groupName
            SID   = "ERROR: $_"
        }
    }
}

# 导出为 UTF-8 带 BOM，确保兼容中文显示
$Utf8BomEncoding = New-Object System.Text.UTF8Encoding($true)
$results | Export-Csv -Path $outputCsv -NoTypeInformation -Encoding $Utf8BomEncoding

Write-Output "处理完成，输出文件：$outputCsv"
