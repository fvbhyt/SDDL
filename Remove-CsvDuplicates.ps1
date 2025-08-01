param(
    [Parameter(Mandatory=$true, HelpMessage="输入CSV文件路径")]
    [string]$InputFile,

    [Parameter(Mandatory=$true, HelpMessage="输出CSV文件路径")]
    [string]$OutputFile,

    [Parameter(HelpMessage="根据指定列去重（逗号分隔列名）")]
    [string]$UniqueColumns
)

# 记录开始时间
$startTime = Get-Date
Write-Host "开始处理: $startTime" -ForegroundColor Cyan

# 加载必要的程序集
Add-Type -AssemblyName Microsoft.VisualBasic

# 创建CSV解析器
$parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($InputFile)
$parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
$parser.Delimiters = ","
$parser.HasFieldsEnclosedInQuotes = $true

# 读取标题行
$header = $parser.ReadFields()
$header | Out-File -FilePath $OutputFile -Encoding UTF8

# 使用StreamReader获取准确行数（修复错误）
$lineCounter = New-Object System.IO.StreamReader $InputFile
$totalLines = 0
while ($lineCounter.ReadLine() -ne $null) { $totalLines++ }
$lineCounter.Close()
$totalLines--  # 减去标题行

# 初始化变量
$seen = @{}
$processed = 0
$uniqueCount = 0
$lastUpdate = [DateTime]::Now

# 处理进度显示
$progressParams = @{
    Activity = "处理 $([System.IO.Path]::GetFileName($InputFile))"
    Status = "初始化..."
    PercentComplete = 0
    CurrentOperation = "开始处理"
}

# 逐行处理CSV
while (!$parser.EndOfData) {
    try {
        $row = $parser.ReadFields()
        $processed++
        
        # 每1000行或每5秒更新进度
        $now = [DateTime]::Now
        if ($processed % 1000 -eq 0 -or ($now - $lastUpdate).TotalSeconds -ge 5) {
            $lastUpdate = $now
            $percent = if ($totalLines -gt 0) { [math]::Min(100, [math]::Round(($processed / $totalLines) * 100, 1)) } else { 0 }
            
            $progressParams.Status = "已处理: {0:N0}/{1:N0} 行 | 去重后: {2:N0}" -f $processed, $totalLines, $uniqueCount
            $progressParams.PercentComplete = $percent
            $progressParams.CurrentOperation = "当前: {0:P0}" -f ($processed / $totalLines)
            Write-Progress @progressParams
        }
        
        # 构建唯一键
        $key = if ($UniqueColumns) {
            $colIndices = $UniqueColumns.Split(',') | ForEach-Object { 
                $colName = $_.Trim()
                $index = [Array]::IndexOf($header, $colName)
                if ($index -eq -1) {
                    Write-Error "列 '$colName' 不存在!"
                    exit 1
                }
                $index
            }
            $colIndices | ForEach-Object { $row[$_] } | Join-String -Separator "|"
        } else {
            $row -join "|"
        }
        
        # 检查是否唯一
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $uniqueCount++
            $row -join "," | Out-File -FilePath $OutputFile -Encoding UTF8 -Append
        }
    }
    catch {
        Write-Warning "第 $processed 行解析错误: $_"
    }
}

# 清理资源
$parser.Close()
$parser.Dispose()

# 显示最终结果
$endTime = Get-Date
$timeSpan = $endTime - $startTime
Write-Progress -Activity "完成!" -Completed
Write-Host "`n处理完成!" -ForegroundColor Green
Write-Host "原始行数: $($totalLines.ToString('N0'))" -ForegroundColor Yellow
Write-Host "去重后行数: $($uniqueCount.ToString('N0'))" -ForegroundColor Green
Write-Host "减少行数: $(($totalLines - $uniqueCount).ToString('N0'))" -ForegroundColor Cyan
Write-Host "总耗时: $($timeSpan.TotalMinutes.ToString('0.00')) 分钟" -ForegroundColor Cyan
Write-Host "输出文件: $OutputFile" -ForegroundColor Cyan