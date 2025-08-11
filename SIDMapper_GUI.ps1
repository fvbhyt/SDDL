Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 创建窗体
$form = New-Object System.Windows.Forms.Form
$form.Text = "SID 映射工具"
$form.Size = New-Object System.Drawing.Size(540, 300)
$form.StartPosition = "CenterScreen"

# 输入路径控件
$inputLabel = New-Object System.Windows.Forms.Label
$inputLabel.Text = "输入 CSV 文件："
$inputLabel.Location = New-Object System.Drawing.Point(10, 20)
$inputLabel.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($inputLabel)

$inputBox = New-Object System.Windows.Forms.TextBox
$inputBox.Location = New-Object System.Drawing.Point(120, 20)
$inputBox.Size = New-Object System.Drawing.Size(300, 20)
$form.Controls.Add($inputBox)

$inputBrowse = New-Object System.Windows.Forms.Button
$inputBrowse.Text = "浏览"
$inputBrowse.Location = New-Object System.Drawing.Point(430, 20)
$inputBrowse.Size = New-Object System.Drawing.Size(80, 20)
$inputBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "CSV 文件 (*.csv)|*.csv"
    if ($dialog.ShowDialog() -eq "OK") {
        $inputBox.Text = $dialog.FileName
    }
})
$form.Controls.Add($inputBrowse)

# 输出路径控件
$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = "输出 CSV 文件："
$outputLabel.Location = New-Object System.Drawing.Point(10, 60)
$outputLabel.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($outputLabel)

$outputBox = New-Object System.Windows.Forms.TextBox
$outputBox.Location = New-Object System.Drawing.Point(120, 60)
$outputBox.Size = New-Object System.Drawing.Size(300, 20)
$form.Controls.Add($outputBox)

$outputBrowse = New-Object System.Windows.Forms.Button
$outputBrowse.Text = "浏览"
$outputBrowse.Location = New-Object System.Drawing.Point(430, 60)
$outputBrowse.Size = New-Object System.Drawing.Size(80, 20)
$outputBrowse.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = "CSV 文件 (*.csv)|*.csv"
    if ($dialog.ShowDialog() -eq "OK") {
        $outputBox.Text = $dialog.FileName
    }
})
$form.Controls.Add($outputBrowse)

# 模式选择控件
$modeLabel = New-Object System.Windows.Forms.Label
$modeLabel.Text = "查询模式："
$modeLabel.Location = New-Object System.Drawing.Point(10, 100)
$modeLabel.Size = New-Object System.Drawing.Size(100, 20)
$form.Controls.Add($modeLabel)

$modeBox = New-Object System.Windows.Forms.ComboBox
$modeBox.Location = New-Object System.Drawing.Point(120, 100)
$modeBox.Size = New-Object System.Drawing.Size(120, 20)
$modeBox.DropDownStyle = 'DropDownList'
$modeBox.Items.AddRange(@("Olduser", "Newuser", "all"))
$modeBox.SelectedIndex = 2
$form.Controls.Add($modeBox)

# 执行按钮
$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "开始映射"
$runButton.Location = New-Object System.Drawing.Point(260, 140)
$runButton.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($runButton)

# 状态提示框
$statusBox = New-Object System.Windows.Forms.Label
$statusBox.Text = ""
$statusBox.Location = New-Object System.Drawing.Point(10, 190)
$statusBox.Size = New-Object System.Drawing.Size(500, 40)
$statusBox.ForeColor = 'DarkGreen'
$form.Controls.Add($statusBox)

# SID 映射处理函数
function Process-SIDMapping {
    param (
        [string]$InputPath,
        [string]$OutputPath,
        [string]$Mode
    )

    try {
        $csv = Import-Csv -Path $InputPath

        foreach ($row in $csv) {
            foreach ($col in @("OldSID", "NewSID")) {
                if (-not $row.PSObject.Properties.Match($col)) {
                    $row | Add-Member -NotePropertyName $col -NotePropertyValue ""
                }
            }

            if ($Mode -eq "Olduser" -or $Mode -eq "all") {
                if (![string]::IsNullOrWhiteSpace($row.Olduser)) {
                    try {
                        $row.OldSID = (New-Object System.Security.Principal.NTAccount($row.Olduser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
                    } catch {
                        $row.OldSID = "SID Not Found"
                    }
                } else {
                    $row.OldSID = "空值"
                }
            }

            if ($Mode -eq "Newuser" -or $Mode -eq "all") {
                if (![string]::IsNullOrWhiteSpace($row.Newuser)) {
                    try {
                        $row.NewSID = (New-Object System.Security.Principal.NTAccount($row.Newuser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
                    } catch {
                        $row.NewSID = "SID Not Found"
                    }
                } else {
                    $row.NewSID = "空值"
                }
            }
        }

        $encoding = New-Object System.Text.UTF8Encoding($true)
        $writer = New-Object System.IO.StreamWriter($OutputPath, $false, $encoding)
        $csv | ConvertTo-Csv -NoTypeInformation | ForEach-Object { $writer.WriteLine($_) }
        $writer.Close()

        return "✅ 映射完成（模式：$Mode），结果已保存到：$OutputPath"
    } catch {
        return "❌ 错误：$_"
    }
}

# 执行按钮事件
$runButton.Add_Click({
    $statusBox.Text = "⏳ 正在处理..."
    $form.Refresh()
    $result = Process-SIDMapping -InputPath $inputBox.Text -OutputPath $outputBox.Text -Mode $modeBox.SelectedItem
    $statusBox.Text = $result
})

$form.Topmost = $true
$form.ShowDialog()
