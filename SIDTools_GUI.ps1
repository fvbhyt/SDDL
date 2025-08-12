Add-Type -AssemblyName System.Windows.Forms

# 导入核心脚本
. "$PSScriptRoot\SIDTools_Core.ps1"

# 创建窗体
$form = New-Object System.Windows.Forms.Form
$form.Text = "文件夹权限替换工具-安乔科技"
$form.Width = 600
$form.Height = 300

# 文件夹选择
$labelFolder = New-Object System.Windows.Forms.Label
$labelFolder.Text = "目标文件夹："
$labelFolder.Top = 20
$labelFolder.Left = 10
$form.Controls.Add($labelFolder)

$textFolder = New-Object System.Windows.Forms.TextBox
$textFolder.Width = 400
$textFolder.Top = 20
$textFolder.Left = 100
$form.Controls.Add($textFolder)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "浏览"
$btnBrowse.Top = 18
$btnBrowse.Left = 510
$btnBrowse.Add_Click({
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($folderDialog.ShowDialog() -eq "OK") {
        $textFolder.Text = $folderDialog.SelectedPath
    }
})
$form.Controls.Add($btnBrowse)

# 替换映射路径
$labelMapping = New-Object System.Windows.Forms.Label
$labelMapping.Text = "SID 映射 CSV："
$labelMapping.Top = 60
$labelMapping.Left = 10
$form.Controls.Add($labelMapping)

$textMapping = New-Object System.Windows.Forms.TextBox
$textMapping.Width = 400
$textMapping.Top = 60
$textMapping.Left = 100
$form.Controls.Add($textMapping)

$btnMapping = New-Object System.Windows.Forms.Button
$btnMapping.Text = "浏览"
$btnMapping.Top = 58
$btnMapping.Left = 510
$btnMapping.Add_Click({
    $openFile = New-Object System.Windows.Forms.OpenFileDialog
    $openFile.Filter = "CSV 文件 (*.csv)|*.csv"
    if ($openFile.ShowDialog() -eq "OK") {
        $textMapping.Text = $openFile.FileName
    }
})
$form.Controls.Add($btnMapping)

# 状态标签
$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = ""
$statusLabel.Top = 180
$statusLabel.Left = 10
$statusLabel.Width = 550
$form.Controls.Add($statusLabel)

# 按钮1：收集权限快照
$btnSnapshot = New-Object System.Windows.Forms.Button
$btnSnapshot.Text = "① 收集权限快照"
$btnSnapshot.Top = 110
$btnSnapshot.Left = 100
$btnSnapshot.Width = 180
$btnSnapshot.Add_Click({
    $shareRoot = $textFolder.Text
    if (-not (Test-Path $shareRoot)) {
        [System.Windows.Forms.MessageBox]::Show("文件夹路径无效")
        return
    }
    $statusLabel.Text = "正在收集权限快照..."
    Capture-ACLSnapshot -shareRoot $shareRoot
    $statusLabel.Text = "快照完成"
})
$form.Controls.Add($btnSnapshot)

# 按钮2：执行 SID 替换
$btnReplace = New-Object System.Windows.Forms.Button
$btnReplace.Text = "② 替换 SID"
$btnReplace.Top = 110
$btnReplace.Left = 320
$btnReplace.Width = 180
$btnReplace.Add_Click({
    $shareRoot = $textFolder.Text
    $csvPath = $textMapping.Text
    if (-not (Test-Path $shareRoot) -or -not (Test-Path $csvPath)) {
        [System.Windows.Forms.MessageBox]::Show("路径无效")
        return
    }
    $statusLabel.Text = "正在执行 SID 替换..."
    Replace-SIDFromMapping -shareRoot $shareRoot -mappingCsv $csvPath
    $statusLabel.Text = "SID 替换完成"
})
$form.Controls.Add($btnReplace)

# 显示窗体
$form.ShowDialog()
