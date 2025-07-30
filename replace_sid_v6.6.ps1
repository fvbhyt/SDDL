# SID 替换脚本启动 - 当前版本：v6.6
$startTime = Get-Date
Write-Host "SID 替换脚本启动 - 当前版本：v6.6" -ForegroundColor Cyan

# 初始化路径
$scriptDir   = $MyInvocation.MyCommand.Path | Split-Path -Parent
$mappingCsv  = Join-Path $scriptDir 'sid_mapping.csv'
$csvPath     = Join-Path $scriptDir 'acl_changes.csv'
$jsonPath    = Join-Path $scriptDir 'acl_changes.json'
$reportFile  = Join-Path $scriptDir 'acl_report.txt'
$errorLog    = Join-Path $scriptDir 'acl_error.log'
$snapshotPath = Join-Path $scriptDir 'acl_snapshot_before.csv'
Remove-Item $csvPath, $jsonPath, $reportFile, $errorLog, $snapshotPath -ErrorAction SilentlyContinue

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

# 开始生成权限快照
Write-Host "开始生成权限备份..." -ForegroundColor Cyan
$snapshotStart = Get-Date
$snapshotRows = [System.Collections.Generic.List[object]]::new()
$snapshotCounter = 0

foreach ($folder in $folders) {
    $snapshotCounter++
    if ($snapshotCounter % 1000 -eq 0) {
        $elapsed = [math]::Round(( (Get-Date) - $snapshotStart ).TotalSeconds, 1)
        Write-Host "  备份进度: $snapshotCounter/$totalFolders | 耗时 ${elapsed}s" -ForegroundColor DarkGray
    }

    try {
        $acl = Get-Acl $folder -ErrorAction Stop
        foreach ($rule in $acl.Access) {
            $snapshotRows.Add([PSCustomObject]@{
                Folder     = $folder
                User       = $rule.IdentityReference.Value
                Rights     = $rule.FileSystemRights.ToString()
                Inherited  = if ($rule.IsInherited) { "Yes" } else { "No" }
            })
        }
    } catch {
        $msg = "$(Get-Date -Format s) | SNAPSHOT_ERROR | $folder | $($_.Exception.Message)"
        Add-Content -Path $errorLog -Value $msg -Encoding UTF8
    }
}

$snapshotRows | Export-Csv -Path $snapshotPath -Encoding UTF8BOM -NoTypeInformation
$snapshotTime = [math]::Round(( (Get-Date) - $snapshotStart ).TotalSeconds, 1)
Write-Host "`n替换前权限快照已保存 ($($snapshotRows.Count) 条记录)：" -ForegroundColor Cyan
Write-Host "  耗时 ${snapshotTime}秒 | 路径: $snapshotPath" -ForegroundColor DarkGray

# 初始化 CSV 表头
@"
Folder,Identity,Inheritance,UsersBefore,RightsBefore,UsersAfter,RightsAfter,ACL_Changed
"@ | Out-File -FilePath $csvPath -Encoding UTF8BOM

$aclRecords = [System.Collections.Generic.List[object]]::new()
$errorBag   = @()

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

        $aclBefore = Get-Acl $folder -ErrorAction Stop
        $sddlOriginal = $aclBefore.GetSecurityDescriptorSddlForm('All')
        $inheritStatus = if ($aclBefore.AreAccessRulesProtected) { 'NotInherited' } else { 'Inherited' }

        $preMap = @{ }
        foreach ($rule in $aclBefore.Access) {
            $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            $preMap[$sid] = @{
                Name = $rule.IdentityReference.Value
                Rights = $rule.FileSystemRights.ToString()
            }
        }

        foreach ($oldSid in $SidMap.Keys) {
            if (-not $preMap.ContainsKey($oldSid) -and $sddlOriginal.Contains($oldSid)) {
                try {
                    $name = (New-Object System.Security.Principal.SecurityIdentifier($oldSid)).Translate([System.Security.Principal.NTAccount]).Value
                    $preMap[$oldSid] = @{
                        Name = $name
                        Rights = '(Inherited Estimated)'
                    }
                } catch {}
            }
        }

        $sddlModified = $sddlOriginal
        foreach ($oldSid in $SidMap.Keys) {
            $newSid = $SidMap[$oldSid]
            $sddlModified = $sddlModified -replace [regex]::Escape($oldSid), $newSid
        }

        $newAcl = New-Object System.Security.AccessControl.DirectorySecurity
        $newAcl.SetSecurityDescriptorSddlForm($sddlModified)
        Set-Acl -Path $folder -AclObject $newAcl -ErrorAction Stop

        $aclAfter = Get-Acl $folder
        $postMap = @{ }
        foreach ($rule in $aclAfter.Access) {
            $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            $postMap[$sid] = @{
                Name = $rule.IdentityReference.Value
                Rights = $rule.FileSystemRights.ToString()
            }
        }

        foreach ($oldSid in $SidMap.Keys) {
            $newSid = $SidMap[$oldSid]
            $beforeUser   = $preMap[$oldSid]?.Name ?? ''
            $beforeRights = $preMap[$oldSid]?.Rights ?? ''
            $afterUser    = $postMap[$newSid]?.Name ?? ''
            $afterRights  = $postMap[$newSid]?.Rights ?? ''
            if ($beforeUser -eq '' -and $afterUser -eq '') { continue }

            $aclChanged = if ($beforeRights -ne $afterRights -or $beforeUser -ne $afterUser) { 'Changed' } else { 'Unchanged' }

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

            $record | Export-Csv -Path $csvPath -Append -Encoding UTF8BOM -NoTypeInformation
            $aclRecords.Add($record)
        }

        $allSIDs = $preMap.Keys + $postMap.Keys | Where-Object {
            $SidMap.Keys -notcontains $_ -and $SidMap.Values -notcontains $_
        } | Sort-Object -Unique

        foreach ($sid in $allSIDs) {
            $user = $postMap[$sid]?.Name ?? $preMap[$sid]?.Name
            $rightsBefore = $preMap[$sid]?.Rights ?? ''
            $rightsAfter  = $postMap[$sid]?.Rights ?? ''
            $aclChanged = if ($rightsBefore -ne $rightsAfter) { 'Changed' } else { 'Unchanged' }

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

            $record | Export-Csv -Path $csvPath -Append -Encoding UTF8BOM -NoTypeInformation
            $aclRecords.Add($record)
        }

    } catch {
        $msg = "$(Get-Date -Format s) | TIMEOUT_ERROR | $folder | $($_.Exception.Message)"
        $errorBag += $msg
        Add-Content -Path $errorLog -Value $msg -Encoding UTF8
    }
}

# 输出 JSON
$aclRecords | ConvertTo-Json -Depth 3 | Out-File -FilePath $jsonPath -Encoding UTF8

# 输出报告
$endTime = Get-Date
$report = @"
ACL SID 替换报告 v6.5a
-------------------------------------
总目录数         ： $totalFolders
权限记录行数     ： $($aclRecords.Count)
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
Write-Host "JSON 文件： $jsonPath"
Write-Host "报告文件 ： $reportFile"
Write-Host "错误日志 ： $errorLog"
