# SID 替换脚本 - 版本 v6.7 (性能优先)
# 主要改动：
# - 使用合并正则一次性替换 SDDL 中的多个 SID，提高替换效率
# - 使用 StreamWriter 批量写入 CSV/NDJSON，减少 PowerShell 层 I/O 开销
# - 快照（acl_snapshot_before.csv）按批写入，减少内存占用
# - batchSize 默认为 50000，可在脚本顶部调整
# - 保留错误日志、报告、JSON 合成等输出

$startTime = Get-Date
Write-Host "SID 替换脚本启动 - 当前版本：v6.7" -ForegroundColor Cyan

# 配置 (可在此调整)
$scriptDir   = $MyInvocation.MyCommand.Path | Split-Path -Parent
$mappingCsv  = Join-Path $scriptDir 'sid_mapping.csv'
$csvPath     = Join-Path $scriptDir 'acl_changes.csv'
$jsonPath    = Join-Path $scriptDir 'acl_changes.json'
$ndjsonPath  = Join-Path $scriptDir 'acl_changes.ndjson'
$reportFile  = Join-Path $scriptDir 'acl_report.txt'
$errorLog    = Join-Path $scriptDir 'acl_error.log'
$snapshotPath = Join-Path $scriptDir 'acl_snapshot_before.csv'

# 性能选项
$batchSize = 50000            # 默认批次大小，内存/性能权衡，按需调整
$useStreamWriter = $true      # true: 使用 StreamWriter 高性能写入；false: 使用 Add-Content 兼容写入

# 清理旧文件
Remove-Item $csvPath, $jsonPath, $ndjsonPath, $reportFile, $errorLog, $snapshotPath -ErrorAction SilentlyContinue

# 加载 SID 映射表
$SidMap = @{ }
Import-Csv $mappingCsv -Encoding UTF8 | ForEach-Object {
    if ($_.OldSID -and $_.NewSID) {
        $SidMap[$_.OldSID.Trim()] = $_.NewSID.Trim()
    }
}
Write-Host "映射规则加载成功：$($SidMap.Count) 条目"

# 预构建合并正则以加速替换（如果映射为空则跳过）
function Build-SidRegex {
    param([string[]]$sids)
    if (-not $sids -or $sids.Count -eq 0) { return $null }
    $ordered = $sids | Sort-Object { -$_.Length }
    $escaped = $ordered | ForEach-Object { [regex]::Escape($_) }
    $pattern = "(?:( " + ($escaped -join "|" ) + "))"
    # note: pattern surrounding handled below; ensure no stray spaces
    $pattern = "(?:" + ($escaped -join "|") + ")"
    return [regex]::new($pattern)
}

function Replace-Sddl-With-Map {
    param([string]$sddl, [regex]$sidRegex, [hashtable]$SidMap)
    if (-not $sidRegex) { return $sddl }
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $val = $m.Value; if ($SidMap.ContainsKey($val)) { return $SidMap[$val] } else { return $val } }
    return $sidRegex.Replace($sddl, $evaluator)
}

# CSV/JSON 辅助：转义函数
function CsvEscape { param([string]$s); if ($null -eq $s) { return "" }; if ($s -match '[,"\r\n]') { $s = $s -replace '"', '""'; return '"' + $s + '"' } else { return $s } }
function JsonEscape { param([string]$s); if ($null -eq $s) { return "" }; $s = $s -replace '\\', '\\\\'; $s = $s -replace '"', '\"'; $s = $s -replace "`r", '\r'; $s = $s -replace "`n", '\n'; $s = $s -replace "`t", '\t'; return $s }

# 高性能批量写入 (StreamWriter) 及兼容写入实现
function Flush-Batch-StreamWriter { param([System.Collections.ArrayList]$list, [string]$csvPath, [string]$ndjsonPath) if ($list.Count -eq 0) { return } $fileMode = [System.IO.FileMode]::Append; $fsCsv = [System.IO.File]::Open($csvPath, $fileMode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read); $swCsv = New-Object System.IO.StreamWriter($fsCsv, [System.Text.Encoding]::UTF8); try { foreach ($rec in $list) { $line = (CsvEscape($rec.Folder) + "," + CsvEscape($rec.Identity) + "," + CsvEscape($rec.Inheritance) + "," + CsvEscape($rec.UsersBefore) + "," + CsvEscape($rec.RightsBefore) + "," + CsvEscape($rec.UsersAfter) + "," + CsvEscape($rec.RightsAfter) + "," + CsvEscape($rec.ACL_Changed)); $swCsv.WriteLine($line) } } finally { $swCsv.Flush(); $swCsv.Dispose(); $fsCsv.Dispose() } $fsJson = [System.IO.File]::Open($ndjsonPath, $fileMode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read); $swJson = New-Object System.IO.StreamWriter($fsJson, [System.Text.Encoding]::UTF8); try { foreach ($rec in $list) { $jsonLine = '{"Folder":"' + (JsonEscape($rec.Folder)) + '","Identity":"' + (JsonEscape($rec.Identity)) + '","Inheritance":"' + (JsonEscape($rec.Inheritance)) + '","UsersBefore":"' + (JsonEscape($rec.UsersBefore)) + '","RightsBefore":"' + (JsonEscape($rec.RightsBefore)) + '","UsersAfter":"' + (JsonEscape($rec.UsersAfter)) + '","RightsAfter":"' + (JsonEscape($rec.RightsAfter)) + '","ACL_Changed":"' + (JsonEscape($rec.ACL_Changed)) + '"}'; $swJson.WriteLine($jsonLine) } } finally { $swJson.Flush(); $swJson.Dispose(); $fsJson.Dispose() } $list.Clear() | Out-Null }

function Flush-Snapshot-StreamWriter { param([System.Collections.ArrayList]$list, [string]$snapshotPath) if ($list.Count -eq 0) { return } $fileMode = [System.IO.FileMode]::Append; $fs = [System.IO.File]::Open($snapshotPath, $fileMode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read); $sw = New-Object System.IO.StreamWriter($fs, [System.Text.Encoding]::UTF8); try { foreach ($obj in $list) { $line = CsvEscape($obj.Folder) + "," + CsvEscape($obj.User) + "," + CsvEscape($obj.Rights) + "," + CsvEscape($obj.Inherited); $sw.WriteLine($line) } } finally { $sw.Flush(); $sw.Dispose(); $fs.Dispose() } $list.Clear() | Out-Null }

# 兼容写入（当 useStreamWriter = $false 时使用）
function Flush-Batch-Compat { param([System.Collections.ArrayList]$list, [string]$csvPath, [string]$ndjsonPath) if ($list.Count -eq 0) { return } $csvLines = $list | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1; Add-Content -Path $csvPath -Value $csvLines -Encoding UTF8; $jsonLines = $list | ForEach-Object { $_ | ConvertTo-Json -Compress }; Add-Content -Path $ndjsonPath -Value $jsonLines -Encoding UTF8; $list.Clear() | Out-Null }
function Flush-Snapshot-Compat { param([System.Collections.ArrayList]$list, [string]$snapshotPath) if ($list.Count -eq 0) { return } $csvLines = $list | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1; Add-Content -Path $snapshotPath -Value $csvLines -Encoding UTF8; $list.Clear() | Out-Null }

# 构建 sidRegex（一次）
$sidRegex = Build-SidRegex -sids ($SidMap.Keys)

# 收集待处理目录
$shareRoot = Read-Host '请输入共享根目录路径（如 D:\ShareTest）'
$folders = @(Get-Item $shareRoot)
$folders += Get-ChildItem $shareRoot -Directory -Recurse -ErrorAction SilentlyContinue
$folders = $folders | Select-Object -ExpandProperty FullName
$totalFolders = $folders.Count
Write-Host "待处理目录总数：$totalFolders"

# 快照：分批写入（使用选定的写入器）
Write-Host "开始生成权限备份..." -ForegroundColor Cyan
$snapshotStart = Get-Date
$snapshotCounter = 0
$snapshotBatchList = New-Object System.Collections.ArrayList
$snapshotWrittenCount = 0
@"
Folder,User,Rights,Inherited
"@ | Out-File -FilePath $snapshotPath -Encoding UTF8
foreach ($folder in $folders) {
    $snapshotCounter++
    if ($snapshotCounter % 1000 -eq 0) { $elapsed = [math]::Round(((Get-Date) - $snapshotStart).TotalSeconds, 1); Write-Host "  备份进度: $snapshotCounter/$totalFolders | 耗时 ${elapsed}s" -ForegroundColor DarkGray }
    try {
        $acl = Get-Acl $folder -ErrorAction Stop
        foreach ($rule in $acl.Access) {
            $obj = [PSCustomObject]@{ Folder = $folder; User = $rule.IdentityReference.Value; Rights = $rule.FileSystemRights.ToString(); Inherited = if ($rule.IsInherited) { 'Yes' } else { 'No' } }
            $null = $snapshotBatchList.Add($obj)
            if ($snapshotBatchList.Count -ge $batchSize) { if ($useStreamWriter) { Flush-Snapshot-StreamWriter -list $snapshotBatchList -snapshotPath $snapshotPath } else { Flush-Snapshot-Compat -list $snapshotBatchList -snapshotPath $snapshotPath } $snapshotWrittenCount += $batchSize }
        }
    } catch { $msg = "$(Get-Date -Format s) | SNAPSHOT_ERROR | $folder | $($_.Exception.Message)"; Add-Content -Path $errorLog -Value $msg -Encoding UTF8 }
}
# 写出剩余快照批次
if ($snapshotBatchList.Count -gt 0) { if ($useStreamWriter) { Flush-Snapshot-StreamWriter -list $snapshotBatchList -snapshotPath $snapshotPath } else { Flush-Snapshot-Compat -list $snapshotBatchList -snapshotPath $snapshotPath } $snapshotWrittenCount += $snapshotBatchList.Count }
$snapshotTime = [math]::Round(((Get-Date) - $snapshotStart).TotalSeconds, 1)
Write-Host "`n替换前权限快照已保存 ($snapshotWrittenCount 条记录) ：" -ForegroundColor Cyan
Write-Host "  耗时 ${snapshotTime}秒 | 路径: $snapshotPath" -ForegroundColor DarkGray

# 初始化结果 CSV 表头
@"
Folder,Identity,Inheritance,UsersBefore,RightsBefore,UsersAfter,RightsAfter,ACL_Changed
"@ | Out-File -FilePath $csvPath -Encoding UTF8BOM

# 准备批次与缓存
$batchList = New-Object System.Collections.ArrayList
$writtenCount = 0; $countChanged = 0; $countUnchanged = 0; $errorBag = @()
$sidToName = @{}; $nameToSid = @{}; $sidKeys = $SidMap.Keys

# 处理目录权限主循环
Write-Host "`n开始处理目录权限..." -ForegroundColor Cyan
$processStart = Get-Date; $processCounter = 0
foreach ($folder in $folders) {
    $processCounter++
    $folderStartTime = [System.Diagnostics.Stopwatch]::StartNew()
    if ($processCounter % 1000 -eq 0) { $elapsed = [math]::Round(((Get-Date) - $processStart).TotalSeconds,1); $percent = [math]::Round(($processCounter / $totalFolders) * 100, 1); Write-Host "  处理进度: $processCounter/$totalFolders ($percent%) | 耗时 ${elapsed}s" -ForegroundColor DarkGray }
    try {
        if ($folderStartTime.Elapsed.TotalSeconds -gt 30) { throw "目录处理超过30秒，跳过处理" }
        $aclBefore = Get-Acl $folder -ErrorAction Stop
        $sddlOriginal = $aclBefore.GetSecurityDescriptorSddlForm('All')
        $inheritStatus = if ($aclBefore.AreAccessRulesProtected) { 'NotInherited' } else { 'Inherited' }
        $preMap = @{}
        foreach ($rule in $aclBefore.Access) {
            $name = $rule.IdentityReference.Value
            if ($nameToSid.ContainsKey($name)) { $sid = $nameToSid[$name] } else { try { $sidObj = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]); $sid = $sidObj.Value; $nameToSid[$name] = $sid; if (-not $sidToName.ContainsKey($sid)) { $sidToName[$sid] = $name } } catch { continue } }
            $preMap[$sid] = @{ Name = $name; Rights = $rule.FileSystemRights.ToString() }
        }
        foreach ($oldSid in $sidKeys) { if (-not $preMap.ContainsKey($oldSid) -and $sddlOriginal.Contains($oldSid)) { try { if ($sidToName.ContainsKey($oldSid)) { $name = $sidToName[$oldSid] } else { $name = (New-Object System.Security.Principal.SecurityIdentifier($oldSid)).Translate([System.Security.Principal.NTAccount]).Value; $sidToName[$oldSid] = $name; if (-not $nameToSid.ContainsKey($name)) { $nameToSid[$name] = $oldSid } } $preMap[$oldSid] = @{ Name = $name; Rights = '(Inherited Estimated)' } } catch {} } }
        # 使用合并正则一次替换 SDDL
        $sddlModified = Replace-Sddl-With-Map -sddl $sddlOriginal -sidRegex $sidRegex -SidMap $SidMap
        $aclAfter = $null; $postMap = @{}
        if ($sddlModified -eq $sddlOriginal) { $aclAfter = $aclBefore; foreach ($k in $preMap.Keys) { $postMap[$k] = @{ Name = $preMap[$k].Name; Rights = $preMap[$k].Rights } } } else { try { $newAcl = New-Object System.Security.AccessControl.DirectorySecurity; $newAcl.SetSecurityDescriptorSddlForm($sddlModified); Set-Acl -Path $folder -AclObject $newAcl -ErrorAction Stop; $aclAfter = Get-Acl $folder; foreach ($rule in $aclAfter.Access) { $name = $rule.IdentityReference.Value; if ($nameToSid.ContainsKey($name)) { $sid = $nameToSid[$name] } else { try { $sidObj = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]); $sid = $sidObj.Value; $nameToSid[$name] = $sid; if (-not $sidToName.ContainsKey($sid)) { $sidToName[$sid] = $name } } catch { continue } } 
            $postMap[$sid] = @{ Name = $name; Rights = $rule.FileSystemRights.ToString() } } } catch { throw $_ } }
        # 生成记录并即时统计
        foreach ($oldSid in $sidKeys) { $newSid = $SidMap[$oldSid]; $beforeUser = $preMap[$oldSid]?.Name ?? ''; $beforeRights = $preMap[$oldSid]?.Rights ?? ''; $afterUser = $postMap[$newSid]?.Name ?? ''; $afterRights = $postMap[$newSid]?.Rights ?? ''; if ($beforeUser -eq '' -and $afterUser -eq '') { continue } $aclChanged = if ($beforeRights -ne $afterRights -or $beforeUser -ne $afterUser) { 'Changed' } else { 'Unchanged' } if ($aclChanged -eq 'Changed') { $countChanged++ } else { $countUnchanged++ } $writtenCount++ $record = [PSCustomObject]@{ Folder = $folder; Identity = $afterUser; Inheritance = $inheritStatus; UsersBefore = $beforeUser; RightsBefore = $beforeRights; UsersAfter = $afterUser; RightsAfter = $afterRights; ACL_Changed = $aclChanged } $null = $batchList.Add($record) if ($batchList.Count -ge $batchSize) { if ($useStreamWriter) { Flush-Batch-StreamWriter -list $batchList -csvPath $csvPath -ndjsonPath $ndjsonPath } else { Flush-Batch-Compat -list $batchList -csvPath $csvPath -ndjsonPath $ndjsonPath } } }
        $allSIDs = $preMap.Keys + $postMap.Keys | Where-Object { $sidKeys -notcontains $_ -and $SidMap.Values -notcontains $_ } | Sort-Object -Unique
        foreach ($sid in $allSIDs) { $user = $postMap[$sid]?.Name ?? $preMap[$sid]?.Name; $rightsBefore = $preMap[$sid]?.Rights ?? ''; $rightsAfter = $postMap[$sid]?.Rights ?? ''; $aclChanged = if ($rightsBefore -ne $rightsAfter) { 'Changed' } else { 'Unchanged' } if ($aclChanged -eq 'Changed') { $countChanged++ } else { $countUnchanged++ } $writtenCount++ $record = [PSCustomObject]@{ Folder = $folder; Identity = $user; Inheritance = $inheritStatus; UsersBefore = $user; RightsBefore = $rightsBefore; UsersAfter = $user; RightsAfter = $rightsAfter; ACL_Changed = $aclChanged } $null = $batchList.Add($record) if ($batchList.Count -ge $batchSize) { if ($useStreamWriter) { Flush-Batch-StreamWriter -list $batchList -csvPath $csvPath -ndjsonPath $ndjsonPath } else { Flush-Batch-Compat -list $batchList -csvPath $csvPath -ndjsonPath $ndjsonPath } } }
    } catch { $msg = "$(Get-Date -Format s) | TIMEOUT_ERROR | $folder | $($_.Exception.Message)"; $errorBag += $msg; Add-Content -Path $errorLog -Value $msg -Encoding UTF8 }
}
# 写出剩余批次
if ($batchList.Count -gt 0) { if ($useStreamWriter) { Flush-Batch-StreamWriter -list $batchList -csvPath $csvPath -ndjsonPath $ndjsonPath } else { Flush-Batch-Compat -list $batchList -csvPath $csvPath -ndjsonPath $ndjsonPath } $writtenCount += $batchList.Count }

# 合并 NDJSON 成标准 JSON 数组
if (-not (Test-Path $ndjsonPath)) { "[]" | Out-File -FilePath $jsonPath -Encoding UTF8 } else { $sw = [System.IO.StreamWriter]::new($jsonPath, $false, [System.Text.Encoding]::UTF8); try { $sw.Write("["); $first = $true; Get-Content -Path $ndjsonPath -ReadCount 1000 | ForEach-Object { foreach ($line in $_) { if (-not $first) { $sw.Write(",") } else { $first = $false } $sw.Write($line) } } $sw.Write("]") } finally { $sw.Flush(); $sw.Close(); $sw.Dispose() } }

# 报告输出
$endTime = Get-Date
$report = @"
ACL SID 替换报告 v6.7
-------------------------------------
总目录数         ： $totalFolders
权限记录行数     ： $writtenCount
  - Changed      ： $countChanged
  - Unchanged    ： $countUnchanged
错误条目数       ： $($errorBag.Count)
开始时间         ： $($startTime.ToString("yyyy-MM-dd HH:mm:ss"))
完成时间         ： $($endTime.ToString("yyyy-MM-dd HH:mm:ss"))
总耗时（秒）     ： $([math]::Round(($endTime - $startTime).TotalSeconds,2))
-------------------------------------
"@
$report | Out-File -FilePath $reportFile -Encoding UTF8
Write-Host "`n$report" -ForegroundColor Yellow

Write-Host "所有输出已生成：" -ForegroundColor Cyan
Write-Host "快照文件 ： $snapshotPath"
Write-Host "结果 CSV ： $csvPath"
Write-Host "NDJSON临时： $ndjsonPath"
Write-Host "JSON 文件： $jsonPath"
Write-Host "报告文件 ： $reportFile"
Write-Host "错误日志 ： $errorLog"
