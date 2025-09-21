<#
.SYNOPSIS
    增强版特殊字符目录权限导出工具（带统计和UTF-8 BOM）

.DESCRIPTION
    此版本增加了详细的统计信息，并确保CSV文件使用带BOM的UTF-8编码

.NOTES
    版本: 4.0
    更新日期: $(Get-Date -Format "yyyy-MM-dd")
#>

# 添加Windows Forms程序集用于文件选择对话框
Add-Type -AssemblyName System.Windows.Forms

# 文件选择函数
function Get-FilePath {
    param (
        [string]$Title,
        [string]$Filter = "CSV文件 (*.csv)|*.csv|所有文件 (*.*)|*.*"
    )
    
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = $Title
    $dialog.Filter = $Filter
    
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
    } else {
        return $null
    }
}

# 日志函数
function Write-Log {
    param (
        [string]$message,
        [string]$level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$level] $message"
    Add-Content -Path $script:logFile -Value $logEntry -Encoding UTF8
    
    switch ($level) {
        "ERROR" { Write-Host $logEntry -ForegroundColor Red }
        "WARN"  { Write-Host $logEntry -ForegroundColor Yellow }
        default { Write-Host $logEntry -ForegroundColor White }
    }
}

# 使用正确的方法安全地获取ACL
function Get-AclSafe {
    param (
        [string]$path
    )
    
    try {
        # 使用Get-Acl命令的-LiteralPath参数处理特殊字符
        return Get-Acl -LiteralPath $path -ErrorAction Stop
    }
    catch {
        Write-Log "无法获取ACL: $path - $_" -Level ERROR
        return $null
    }
}

# 获取身份标识信息
function Get-IdentityInfo {
    param (
        $identityReference
    )
    
    try {
        if ($null -eq $identityReference) {
            return @{
                Name = "UNKNOWN"
                Sid = "NULL_SID"
                Domain = "UNKNOWN"
                FullName = "UNKNOWN"
            }
        }
        
        $sid = try {
            ($identityReference.Translate([System.Security.Principal.SecurityIdentifier])).Value
        } catch {
            "SID_TRANSLATE_ERROR"
        }
        
        $name = $identityReference.Value
        
        return @{
            Name = $name
            Sid = $sid
            Domain = if ($name.Contains("\")) { $name.Split("\")[0] } else { "LOCAL" }
            FullName = $name
        }
    }
    catch {
        Write-Log "获取身份信息失败: $_" -Level ERROR
        return @{
            Name = "ERROR"
            Sid = "ERROR"
            Domain = "ERROR"
            FullName = "ERROR"
        }
    }
}

# 导出带BOM的UTF-8 CSV文件
function Export-CsvWithBom {
    param (
        [object]$Data,
        [string]$Path,
        [bool]$Append = $false
    )
    
    try {
        if ($Append -and (Test-Path $Path)) {
            # 追加模式
            $Data | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Out-File -FilePath $Path -Append -Encoding UTF8
        } else {
            # 新建模式
            $Data | ConvertTo-Csv -NoTypeInformation | Out-File -FilePath $Path -Encoding UTF8
        }
        return $true
    }
    catch {
        Write-Log "导出CSV文件失败: $_" -Level ERROR
        return $false
    }
}

# 导出单个目录的权限
function Export-SingleFolderPermission {
    param (
        [string]$folderPath,
        [string]$exportFile
    )
    
    Write-Log "开始处理目录: $folderPath"
    
    $permissions = @()
    $permissionCount = 0
    
    try {
        # 使用安全方法获取文件夹的ACL
        $acl = Get-AclSafe -path $folderPath
        
        if ($null -eq $acl) {
            Write-Log "  无法获取ACL，跳过此文件夹" -Level WARN
            return @{Success = $false; Count = 0}
        }
        
        # 检查是否继承权限
        $isInherited = $acl.AreAccessRulesProtected
        
        # 处理每个访问规则
        foreach ($accessRule in $acl.GetAccessRules($true, $true, [System.Security.Principal.NTAccount])) {
            $identityInfo = Get-IdentityInfo -identityReference $accessRule.IdentityReference
            
            $permission = [PSCustomObject]@{
                FolderPath      = $folderPath
                Identity        = $identityInfo.FullName
                Sid             = $identityInfo.Sid
                Domain          = $identityInfo.Domain
                AccessType      = $accessRule.AccessControlType.ToString()
                Rights          = $accessRule.FileSystemRights.ToString()
                IsInherited     = $accessRule.IsInherited.ToString()
                Inheritance     = $accessRule.InheritanceFlags.ToString()
                Propagation     = $accessRule.PropagationFlags.ToString()
                FolderInherit   = $isInherited.ToString()
                Timestamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            }
            $permissions += $permission
            $permissionCount++
            Write-Log "  记录权限: $($identityInfo.FullName) (SID: $($identityInfo.Sid)) - $($accessRule.FileSystemRights)"
        }
        
        # 导出到CSV
        if ($permissions.Count -gt 0) {
            $fileExists = Test-Path $exportFile
            if (Export-CsvWithBom -Data $permissions -Path $exportFile -Append $fileExists) {
                Write-Log "成功导出 $($permissions.Count) 条权限记录到 $exportFile" -Level INFO
                return @{Success = $true; Count = $permissions.Count}
            } else {
                Write-Log "导出到CSV文件失败" -Level ERROR
                return @{Success = $false; Count = 0}
            }
        } else {
            Write-Log "未找到任何权限记录" -Level WARN
            return @{Success = $true; Count = 0}
        }
    } catch {
        Write-Log "处理文件夹 $folderPath 时出错: $_" -Level ERROR
        return @{Success = $false; Count = 0}
    }
}

# 主程序
Write-Host "特殊字符目录权限导出工具" -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green

# 选择输入CSV文件
Write-Host "`n1. 选择包含目录列表的CSV文件" -ForegroundColor Yellow
$inputCsv = Get-FilePath -Title "选择包含目录列表的CSV文件"
if (-not $inputCsv) {
    Write-Host "未选择文件，脚本退出。" -ForegroundColor Red
    exit
}

# 自动生成输出文件和日志文件名
$inputDir = Split-Path $inputCsv -Parent
$inputName = Split-Path $inputCsv -LeafBase
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

$outputCsv = Join-Path $inputDir "$inputName`_Permissions_$timestamp.csv"
$logFile = Join-Path $inputDir "$inputName`_Log_$timestamp.log"

# 初始化日志
Write-Log "特殊字符目录权限导出脚本启动"
Write-Log "输入文件: $inputCsv"
Write-Log "输出文件: $outputCsv"
Write-Log "日志文件: $logFile"

# 检查输入文件是否存在
if (-not (Test-Path $inputCsv)) {
    Write-Log "错误: 输入的CSV文件不存在!" -Level ERROR
    exit
}

# 读取CSV文件
try {
    $directories = Import-Csv -Path $inputCsv -ErrorAction Stop
    Write-Log "成功从 $inputCsv 导入 $($directories.Count) 个目录" -Level INFO
} catch {
    Write-Log "导入CSV文件失败: $_" -Level ERROR
    exit
}

# 获取第一列的列名
$firstColumn = ($directories | Get-Member -MemberType NoteProperty | Select-Object -First 1).Name
Write-Log "使用第一列 '$firstColumn' 作为目录路径" -Level INFO

# 处理每个目录
$totalCount = $directories.Count
$successCount = 0
$failCount = 0
$currentCount = 0
$totalPermissionCount = 0
$processedFolders = @()
$failedFolders = @()

foreach ($dir in $directories) {
    $currentCount++
    $folderPath = $dir.$firstColumn
    
    Write-Log "正在处理目录 [$currentCount/$totalCount]: $folderPath"
    
    $result = Export-SingleFolderPermission -folderPath $folderPath -exportFile $outputCsv
    if ($result.Success) {
        $successCount++
        $totalPermissionCount += $result.Count
        $processedFolders += @{
            Path = $folderPath
            PermissionCount = $result.Count
        }
        Write-Log "  成功处理此目录，导出 $($result.Count) 条权限记录" -Level INFO
    } else {
        $failCount++
        $failedFolders += $folderPath
        Write-Log "  处理此目录失败" -Level ERROR
    }
}

# 生成详细统计信息
Write-Log "==============================================" -Level INFO
Write-Log "处理完成统计信息:" -Level INFO
Write-Log "总目录数: $totalCount" -Level INFO
Write-Log "成功处理目录数: $successCount" -Level INFO
Write-Log "失败目录数: $failCount" -Level INFO
Write-Log "总权限记录数: $totalPermissionCount" -Level INFO
Write-Log "平均每个目录权限记录数: $(if ($successCount -gt 0) {[math]::Round($totalPermissionCount/$successCount, 2)} else {0})" -Level INFO

# 输出成功处理的目录详情
if ($processedFolders.Count -gt 0) {
    Write-Log "`n成功处理的目录详情:" -Level INFO
    $processedFolders | Sort-Object -Property PermissionCount -Descending | ForEach-Object {
        Write-Log "  $($_.Path): $($_.PermissionCount) 条权限" -Level INFO
    }
}

# 输出失败的目录列表
if ($failedFolders.Count -gt 0) {
    Write-Log "`n失败的目录列表:" -Level INFO
    $failedFolders | ForEach-Object {
        Write-Log "  $_" -Level INFO
    }
}

Write-Log "权限已导出到: $outputCsv" -Level INFO
Write-Log "详细日志请查看: $logFile" -Level INFO

# 控制台输出总结
Write-Host "`n处理完成!" -ForegroundColor Green
Write-Host "总目录数: $totalCount" -ForegroundColor Green
Write-Host "成功处理目录数: $successCount" -ForegroundColor Green
Write-Host "失败目录数: $failCount" -ForegroundColor Green
Write-Host "总权限记录数: $totalPermissionCount" -ForegroundColor Green
Write-Host "平均每个目录权限记录数: $(if ($successCount -gt 0) {[math]::Round($totalPermissionCount/$successCount, 2)} else {0})" -ForegroundColor Green
Write-Host "权限已导出到: $outputCsv" -ForegroundColor Green
Write-Host "详细日志请查看: $logFile" -ForegroundColor Green

# 额外提示
if ($failCount -gt 0) {
    Write-Host "`n注意: 有 $failCount 个目录处理失败，请查看日志文件了解详情" -ForegroundColor Yellow
}