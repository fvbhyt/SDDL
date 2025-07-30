# 📦 ACL 权限快照合并工具 v1.3 (优化版)
$changesFile   = ".\acl_changes.csv"
$snapshotFile  = ".\acl_snapshot_before.csv"
$mappingFile   = ".\sid_mapping.csv"
$mergedFile    = ".\acl_changes_merged.csv"

# 文件检查
$missingFiles = @($changesFile, $snapshotFile, $mappingFile) | Where-Object { -not (Test-Path $_) }
if ($missingFiles) {
    Write-Host "❌ 缺少必要文件：" -ForegroundColor Red
    $missingFiles | ForEach-Object { Write-Host "📄 $_" }
    exit
}

# 显示初始化进度
Write-Progress -Activity "正在加载数据" -Status "0/3" -PercentComplete 0

# 读取数据
$changes   = Import-Csv $changesFile -Encoding UTF8
$snapshot  = Import-Csv $snapshotFile -Encoding UTF8
$mapping   = Import-Csv $mappingFile -Encoding UTF8
Write-Progress -Activity "正在加载数据" -Status "1/3" -PercentComplete 33

# 构建缓存结构 (大幅提升查找速度)
$reverseMap = @{}
$snapshotCache = @{}
$sidToNameCache = @{}  # SID->用户名缓存
$nameToSidCache = @{}  # 用户名->SID缓存

# 1. 构建SID映射字典 (NewSID → OldSID)
foreach ($row in $mapping) {
    $oldSid = $row.OldSID.Trim()
    $newSid = $row.NewSID.Trim()
    if ($oldSid -and $newSid) {
        $reverseMap[$newSid] = $oldSid
    }
}

# 2. 构建快照缓存 (复合键: Folder|User)
foreach ($item in $snapshot) {
    $key = "$($item.Folder)|$($item.User)"
    if (-not $snapshotCache.ContainsKey($key)) {
        $snapshotCache[$key] = $item.Rights
    }
}
Write-Progress -Activity "正在加载数据" -Status "2/3" -PercentComplete 66

# 3. 预加载已知SID转换
$mapping | ForEach-Object {
    try {
        # 缓存旧SID->用户名
        $sidObj = [System.Security.Principal.SecurityIdentifier]::new($_.OldSID.Trim())
        $sidToNameCache[$_.OldSID] = $sidObj.Translate([System.Security.Principal.NTAccount]).Value
        
        # 缓存新用户名->SID (预转换)
        $ntAccount = [System.Security.Principal.NTAccount]::new($_.NewUserName)
        $nameToSidCache[$_.NewUserName] = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { 
        # 忽略转换失败项
    }
}
Write-Progress -Activity "正在加载数据" -Status "3/3" -PercentComplete 100
Start-Sleep -Milliseconds 500

# 创建输出文件
@"
Folder,Identity,Inheritance,UsersBefore,RightsBefore,UsersAfter,RightsAfter,ACL_Changed
"@ | Out-File -FilePath $mergedFile -Encoding UTF8BOM

# 处理变更记录 (带进度条)
$totalRecords = $changes.Count
$currentRecord = 0

foreach ($row in $changes) {
    $currentRecord++
    $percentComplete = [math]::Round(($currentRecord / $totalRecords) * 100)
    
    Write-Progress -Activity "合并ACL变更" `
        -Status "处理中: $currentRecord/$totalRecords ($percentComplete%)" `
        -CurrentOperation $row.Folder `
        -PercentComplete $percentComplete

    $folder        = $row.Folder
    $identity      = $row.Identity
    $inheritance   = $row.Inheritance
    $usersBefore   = $row.UsersBefore
    $rightsBefore  = $row.RightsBefore
    $usersAfter    = $row.UsersAfter
    $rightsAfter   = $row.RightsAfter
    $aclChanged    = $row.ACL_Changed

    # 仅处理需要补充历史权限的记录
    if (($usersBefore -eq '' -or $rightsBefore -eq '') -and $usersAfter -ne '') {
        try {
            # 检查用户名->SID缓存
            if (-not $nameToSidCache.ContainsKey($usersAfter)) {
                $sidObj = [System.Security.Principal.NTAccount]::new($usersAfter)
                $nameToSidCache[$usersAfter] = $sidObj.Translate([System.Security.Principal.SecurityIdentifier]).Value
            }
            $newSid = $nameToSidCache[$usersAfter]

            # 反查映射表
            if ($reverseMap.ContainsKey($newSid)) {
                $oldSid = $reverseMap[$newSid]
                
                # 检查SID->用户名缓存
                if (-not $sidToNameCache.ContainsKey($oldSid)) {
                    $sidObj = [System.Security.Principal.SecurityIdentifier]::new($oldSid)
                    $sidToNameCache[$oldSid] = $sidObj.Translate([System.Security.Principal.NTAccount]).Value
                }
                $oldUserName = $sidToNameCache[$oldSid]

                # 从缓存获取历史权限
                $cacheKey = "$folder|$oldUserName"
                if ($snapshotCache.ContainsKey($cacheKey)) {
                    if ($usersBefore -eq '')  { $usersBefore  = $oldUserName }
                    if ($rightsBefore -eq '') { $rightsBefore = $snapshotCache[$cacheKey] }
                }
            }
        } catch {
            Write-Host "无法处理账户: $usersAfter ($($_.Exception.Message))" -ForegroundColor Yellow
        }
    }

    # 输出结果
    [PSCustomObject]@{
        Folder        = $folder
        Identity      = $identity
        Inheritance   = $inheritance
        UsersBefore   = $usersBefore
        RightsBefore  = $rightsBefore
        UsersAfter    = $usersAfter
        RightsAfter   = $rightsAfter
        ACL_Changed   = $aclChanged
    } | Export-Csv -Path $mergedFile -Append -Encoding UTF8BOM -NoTypeInformation
}

Write-Progress -Activity "合并完成" -Completed
Write-Host "ACL合并完成! 处理 $totalRecords 条记录" -ForegroundColor Green
Write-Host "输出文件: $mergedFile" -ForegroundColor Cyan