# SID 替换脚本启动 - 当前版本：v6.7
$startTime = Get-Date
Write-Host "SID 替换脚本启动 - 当前版本：v6.7" -ForegroundColor Cyan

# 初始化路径
$scriptDir   = $MyInvocation.MyCommand.Path | Split-Path -Parent
$mappingCsv  = Join-Path $scriptDir 'sid_mapping.csv'
$csvPath     = Join-Path $scriptDir 'acl_changes.csv'
$jsonPath    = Join-Path $scriptDir 'acl_changes.json'
# 新增临时 NDJSON 路径（用于流式写入每条 JSON 行）
$ndjsonPath  = Join-Path $scriptDir 'acl_changes.ndjson'
$reportFile  = Join-Path $scriptDir 'acl_report.txt'
$errorLog    = Join-Path $scriptDir 'acl_error.log'
$snapshotPath = Join-Path $scriptDir 'acl_snapshot_before.csv'
Remove-Item $csvPath, $jsonPath, $ndjsonPath, $reportFile, $errorLog, $snapshotPath -ErrorAction SilentlyContinue

# 加载 SID 映射表
$SidMap = @{ }
Import-Csv $mappingCsv -Encoding UTF8 | ForEach-Object {
    if ($_.OldSID -and $_.NewSID) {
        $SidMap[$_.OldSID.Trim()] = $_.NewSID.Trim()
    }
}
Write-Host "映射规则加载成功：$($SidMap.Count) 条目"

# 收集待处理目录
$shareRoot = Read-Host '请输入共享根目录路径（如 D:\ShareTest）'
$folders = @(Get-Item $shareRoot)
$folders += Get-ChildItem $shareRoot -Directory -Recurse -ErrorAction SilentlyContinue
$folders = $folders | Select-Object -ExpandProperty FullName
$totalFolders = $folders.Count
Write-Host "待处理目录总数：$totalFolders"

# 分批参数（用于快照与结果写入）
$batchSize = 10000

# 开始生成权限快照（已改为分批写入以降低内存占用）
Write-Host "开始生成权限备份..." -ForegroundColor Cyan
$snapshotStart = Get-Date
$snapshotCounter = 0
$snapshotBatchList = New-Object System.Collections.ArrayList
$snapshotWrittenCount = 0

# 写入 snapshot CSV 表头（保持 BOM，与原输出格式一致）
@"
Folder,User,Rights,Inherited
"@ | Out-File -FilePath $snapshotPath -Encoding UTF8BOM

function Flush-Snapshot {
    param(
        [System.Collections.ArrayList]$list
    )
    if ($list.Count -eq 0) { return }

    $csvLines = $list | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1
    # 兼容性：使用 Add-Content 写入（按行追加）
    Add-Content -Path $snapshotPath -Value $csvLines -Encoding UTF8

    $global:snapshotWrittenCount += $list.Count
    $list.Clear() | Out-Null
}

foreach ($folder in $folders) {
    $snapshotCounter++
    if ($snapshotCounter % 1000 -eq 0) {
        $elapsed = [math]::Round(( (Get-Date) - $snapshotStart ).TotalSeconds, 1)
        Write-Host "  备份进度: $snapshotCounter/$totalFolders | 耗时 ${elapsed}s" -ForegroundColor DarkGray
    }

    try {
        $acl = Get-Acl $folder -ErrorAction Stop
        foreach ($rule in $acl.Access) {
            $obj = [PSCustomObject]@{
                Folder    = $folder
                User      = $rule.IdentityReference.Value
                Rights    = $rule.FileSystemRights.ToString()
                Inherited = if ($rule.IsInherited) { "Yes" } else { "No" }
            }
            $null = $snapshotBatchList.Add($obj)
            if ($snapshotBatchList.Count -ge $batchSize) {
                Flush-Snapshot -list $snapshotBatchList
            }
        }
    } catch {
        $msg = "$(Get-Date -Format s) | SNAPSHOT_ERROR | $folder | $($_.Exception.Message)"
        Add-Content -Path $errorLog -Value $msg -Encoding UTF8
    }
}

# 写出剩余快照批次
Flush-Snapshot -list $snapshotBatchList

$snapshotTime = [math]::Round(( (Get-Date) - $snapshotStart ).TotalSeconds, 1)
Write-Host "`n替换前权限快照已保存 ($snapshotWrittenCount 条记录)：" -ForegroundColor Cyan
Write-Host "  耗时 ${snapshotTime}秒 | 路径: $snapshotPath" -ForegroundColor DarkGray

# 初始化 CSV 表头（结果 CSV）
@"
Folder,Identity,Inheritance,UsersBefore,RightsBefore,UsersAfter,RightsAfter,ACL_Changed
"@ | Out-File -FilePath $csvPath -Encoding UTF8BOM

# 分批相关：避免一次性把所有记录保存在内存
$batchList = New-Object System.Collections.ArrayList  # 用 ArrayList 便于 Add/Clear
$writtenCount = 0                                   # 已写入 CSV/JSON 的记录计数
# 新增：分别统计 Changed/Unchanged 的计数
$countChanged = 0
$countUnchanged = 0
$errorBag   = @()

# 清理/创建 NDJSON 文件（如果要保留每行 JSON）
if (Test-Path $ndjsonPath) { Remove-Item $ndjsonPath -ErrorAction SilentlyContinue }

# 翻译缓存：减少重复 Translate 调用（性能关键）
$sidToName = @{ }   # SID -> AccountName
$nameToSid = @{ }   # AccountName -> SID

# 缓存 SidMap 键数组（避免每次访问 Keys 的开销）
$sidKeys = $SidMap.Keys

# Helper: 将当前批次写入 CSV（追加）与 NDJSON（追加），然后清空批次
function Flush-Batch {
    param(
        [System.Collections.ArrayList]$list
    )
    if ($list.Count -eq 0) { return }

    # ConvertTo-Csv 会产生表头，跳过第一行
    $csvLines = $list | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1

    # 兼容性修复：使用 PowerShell 的 Add-Content（带 -Encoding）替代带 Encoding 的 AppendAllLines
    Add-Content -Path $csvPath -Value $csvLines -Encoding UTF8

    # 写入 NDJSON，每行一个压缩 JSON 对象
    $jsonLines = $list | ForEach-Object { $_ | ConvertTo-Json -Compress }
    Add-Content -Path $ndjsonPath -Value $jsonLines -Encoding UTF8

    # 不在这里更新 writtenCount，避免与在添加记录时更新重复计数
    $list.Clear() | Out-Null
}

# 开始处理目录权限（优化：超时控制）
Write-Host "`n开始处理目录权限..." -ForegroundColor Cyan
$processStart = Get-Date
$processCounter = 0
foreach ($folder in $folders) {
    $processCounter++
    $folderStartTime = [System.Diagnostics.Stopwatch]::StartNew()

    if ($processCounter % 1000 -eq 0) {
        $elapsed = [math]::Round(( (Get-Date) - $processStart ).TotalSeconds, 1)
        $percent = [math]::Round(($processCounter / $totalFolders) * 100, 1)
        Write-Host "  处理进度: $processCounter/$totalFolders ($percent%) | 耗时 ${elapsed}s" -ForegroundColor DarkGray
    }

    try {
        if ($folderStartTime.Elapsed.TotalSeconds -gt 30) {
            throw "目录处理超过30秒，跳过处理"
        }

        # 获取原始 ACL
        $aclBefore = Get-Acl $folder -ErrorAction Stop
        $sddlOriginal = $aclBefore.GetSecurityDescriptorSddlForm('All')
        $inheritStatus = if ($aclBefore.AreAccessRulesProtected) { 'NotInherited' } else { 'Inherited' }

        # 构建 preMap（SID -> @{Name,Rights}），同时使用翻译缓存以减少 Translate 调用
        $preMap = @{ }
        foreach ($rule in $aclBefore.Access) {
            $name = $rule.IdentityReference.Value
            if ($nameToSid.ContainsKey($name)) {
                $sid = $nameToSid[$name]
            } else {
                try {
                    $sidObj = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
                    $sid = $sidObj.Value
                    $nameToSid[$name] = $sid
                    if (-not $sidToName.ContainsKey($sid)) {
                        $sidToName[$sid] = $name
                    }
                } catch {
                    # 翻译失败则跳过该规则
                    continue
                }
            }
            $preMap[$sid] = @{
                Name = $name
                Rights = $rule.FileSystemRights.ToString()
            }
        }

        # 如果 SDDL 包含映射表中的旧 SID，但这些旧 SID 未出现在 preMap（可能是继承/摘要），尝试把名字解析出来并估算 Rights
        foreach ($oldSid in $sidKeys) {
            if (-not $preMap.ContainsKey($oldSid) -and $sddlOriginal.Contains($oldSid)) {
                try {
                    if ($sidToName.ContainsKey($oldSid)) {
                        $name = $sidToName[$oldSid]
                    } else {
                        $name = (New-Object System.Security.Principal.SecurityIdentifier($oldSid)).Translate([System.Security.Principal.NTAccount]).Value
                        $sidToName[$oldSid] = $name
                        if (-not $nameToSid.ContainsKey($name)) { $nameToSid[$name] = $oldSid }
                    }
                    $preMap[$oldSid] = @{
                        Name = $name
                        Rights = '(Inherited Estimated)'
                    }
                } catch {
                    # 忽略无法解析的 SID
                }
            }
        }

        # 只在 SDDL 实际变化时才进行 Set-Acl（避免不必要的写入）
        $sddlModified = $sddlOriginal
        foreach ($oldSid in $sidKeys) {
            $newSid = $SidMap[$oldSid]
            $sddlModified = $sddlModified -replace [regex]::Escape($oldSid), $newSid
        }

        $aclAfter = $null
        $postMap = @{ }

        if ($sddlModified -eq $sddlOriginal) {
            # 未发生替换：跳过 Set-Acl/Get-Acl；直接使用 preMap 作为 postMap，避免额外 I/O
            $aclAfter = $aclBefore
            # 简单复制 preMap 到 postMap（避免引用同一哈希表导致意外修改）
            foreach ($k in $preMap.Keys) {
                $postMap[$k] = @{
                    Name = $preMap[$k].Name
                    Rights = $preMap[$k].Rights
                }
            }
        } else {
            # 实际发生替换：构建新 ACL 并写回
            try {
                $newAcl = New-Object System.Security.AccessControl.DirectorySecurity
                $newAcl.SetSecurityDescriptorSddlForm($sddlModified)
                Set-Acl -Path $folder -AclObject $newAcl -ErrorAction Stop

                # 重新读取 ACL 作为比较
                $aclAfter = Get-Acl $folder
                foreach ($rule in $aclAfter.Access) {
                    $name = $rule.IdentityReference.Value
                    if ($nameToSid.ContainsKey($name)) {
                        $sid = $nameToSid[$name]
                    } else {
                        try {
                            $sidObj = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier])
                            $sid = $sidObj.Value
                            $nameToSid[$name] = $sid
                            if (-not $sidToName.ContainsKey($sid)) {
                                $sidToName[$sid] = $name
                            }
                        } catch {
                            continue
                        }
                    }
                    $postMap[$sid] = @{
                        Name = $name
                        Rights = $rule.FileSystemRights.ToString()
                    }
                }
            } catch {
                throw $_
            }
        }

        # 生成记录：针对每个映射条目比较替换前后
        foreach ($oldSid in $sidKeys) {
            $newSid = $SidMap[$oldSid]
            $beforeUser   = $preMap[$oldSid]?.Name ?? ''
            $beforeRights = $preMap[$oldSid]?.Rights ?? ''
            $afterUser    = $postMap[$newSid]?.Name ?? ''
            $afterRights  = $postMap[$newSid]?.Rights ?? ''
            if ($beforeUser -eq '' -and $afterUser -eq '') { continue }

            $aclChanged = if ($beforeRights -ne $afterRights -or $beforeUser -ne $afterUser) { 'Changed' } else { 'Unchanged' }

            # 立即更新计数（确保统计准确，不依赖 Flush）
            if ($aclChanged -eq 'Changed') {
                $countChanged++
            } else {
                $countUnchanged++
            }
            $writtenCount++  # 记录总行数

            $record = [PSCustomObject]@{
                Folder        = $folder
                Identity      = $afterUser
                Inheritance   = $inheritStatus
                UsersBefore   = $beforeUser
                RightsBefore  = $beforeRights
                UsersAfter    = $afterUser
                RightsAfter   = $afterRights
                ACL_Changed   = $aclChanged
            }

            # 由原先每条 Export-Csv 改为加入批次，由 Flush-Batch 统一写入
            $null = $batchList.Add($record)
            if ($batchList.Count -ge $batchSize) {
                Flush-Batch -list $batchList
            }
        }

        # 处理 pre/post 中未映射的其它 SID（保持原逻辑）
        $allSIDs = $preMap.Keys + $postMap.Keys | Where-Object {
            $sidKeys -notcontains $_ -and $SidMap.Values -notcontains $_
        } | Sort-Object -Unique

        foreach ($sid in $allSIDs) {
            $user = $postMap[$sid]?.Name ?? $preMap[$sid]?.Name
            $rightsBefore = $preMap[$sid]?.Rights ?? ''
            $rightsAfter  = $postMap[$sid]?.Rights ?? ''
            $aclChanged = if ($rightsBefore -ne $rightsAfter) { 'Changed' } else { 'Unchanged' }

            # 立即更新计数（确保统计准确）
            if ($aclChanged -eq 'Changed') {
                $countChanged++
            } else {
                $countUnchanged++
            }
            $writtenCount++  # 记录总行数

            $record = [PSCustomObject]@{
                Folder        = $folder
                Identity      = $user
                Inheritance   = $inheritStatus
                UsersBefore   = $user
                RightsBefore  = $rightsBefore
                UsersAfter    = $user
                RightsAfter   = $rightsAfter
                ACL_Changed   = $aclChanged
            }

            $null = $batchList.Add($record)
            if ($batchList.Count -ge $batchSize) {
                Flush-Batch -list $batchList
            }
        }

    } catch {
        $msg = "$(Get-Date -Format s) | TIMEOUT_ERROR | $folder | $($_.Exception.Message)"
        $errorBag += $msg
        Add-Content -Path $errorLog -Value $msg -Encoding UTF8
    }
}

# 写出剩余的批次（如果有）
Flush-Batch -list $batchList

# 将 NDJSON（每行一个 JSON）合成为标准 JSON 数组（流式写入，避免一次性加载）
if (-not (Test-Path $ndjsonPath)) {
    # 如果没有任何 NDJSON 内容，则写空数组
    "[]" | Out-File -FilePath $jsonPath -Encoding UTF8
} else {
    # 打开写入器（覆盖目标 jsonPath）
    $sw = [System.IO.StreamWriter]::new($jsonPath, $false, [System.Text.Encoding]::UTF8)
    try {
        $sw.Write("[")
        $first = $true
        # 使用 Get-Content 分块读取，避免把整个文件读入内存
        Get-Content -Path $ndjsonPath -ReadCount 1000 | ForEach-Object {
            foreach ($line in $_) {
                if (-not $first) {
                    $sw.Write(",")
                } else {
                    $first = $false
                }
                $sw.Write($line)
            }
        }
        $sw.Write("]")
    } finally {
        $sw.Flush()
        $sw.Close()
        $sw.Dispose()
    }
}

# 输出报告（增加 Changed/Unchanged 统计）
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

# 所有输出路径提示
Write-Host "所有输出已生成：" -ForegroundColor Cyan
Write-Host "快照文件 ： $snapshotPath"
Write-Host "结果 CSV ： $csvPath"
Write-Host "NDJSON临时： $ndjsonPath"
Write-Host "JSON 文件： $jsonPath"
Write-Host "报告文件 ： $reportFile"
Write-Host "错误日志 ： $errorLog"
