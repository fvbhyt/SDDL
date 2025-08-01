param(
    [Parameter(Mandatory=$true, HelpMessage="����CSV�ļ�·��")]
    [string]$InputFile,

    [Parameter(Mandatory=$true, HelpMessage="���CSV�ļ�·��")]
    [string]$OutputFile,

    [Parameter(HelpMessage="����ָ����ȥ�أ����ŷָ�������")]
    [string]$UniqueColumns
)

# ��¼��ʼʱ��
$startTime = Get-Date
Write-Host "��ʼ����: $startTime" -ForegroundColor Cyan

# ���ر�Ҫ�ĳ���
Add-Type -AssemblyName Microsoft.VisualBasic

# ����CSV������
$parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($InputFile)
$parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
$parser.Delimiters = ","
$parser.HasFieldsEnclosedInQuotes = $true

# ��ȡ������
$header = $parser.ReadFields()
$header | Out-File -FilePath $OutputFile -Encoding UTF8

# ʹ��StreamReader��ȡ׼ȷ�������޸�����
$lineCounter = New-Object System.IO.StreamReader $InputFile
$totalLines = 0
while ($lineCounter.ReadLine() -ne $null) { $totalLines++ }
$lineCounter.Close()
$totalLines--  # ��ȥ������

# ��ʼ������
$seen = @{}
$processed = 0
$uniqueCount = 0
$lastUpdate = [DateTime]::Now

# ���������ʾ
$progressParams = @{
    Activity = "���� $([System.IO.Path]::GetFileName($InputFile))"
    Status = "��ʼ��..."
    PercentComplete = 0
    CurrentOperation = "��ʼ����"
}

# ���д���CSV
while (!$parser.EndOfData) {
    try {
        $row = $parser.ReadFields()
        $processed++
        
        # ÿ1000�л�ÿ5����½���
        $now = [DateTime]::Now
        if ($processed % 1000 -eq 0 -or ($now - $lastUpdate).TotalSeconds -ge 5) {
            $lastUpdate = $now
            $percent = if ($totalLines -gt 0) { [math]::Min(100, [math]::Round(($processed / $totalLines) * 100, 1)) } else { 0 }
            
            $progressParams.Status = "�Ѵ���: {0:N0}/{1:N0} �� | ȥ�غ�: {2:N0}" -f $processed, $totalLines, $uniqueCount
            $progressParams.PercentComplete = $percent
            $progressParams.CurrentOperation = "��ǰ: {0:P0}" -f ($processed / $totalLines)
            Write-Progress @progressParams
        }
        
        # ����Ψһ��
        $key = if ($UniqueColumns) {
            $colIndices = $UniqueColumns.Split(',') | ForEach-Object { 
                $colName = $_.Trim()
                $index = [Array]::IndexOf($header, $colName)
                if ($index -eq -1) {
                    Write-Error "�� '$colName' ������!"
                    exit 1
                }
                $index
            }
            $colIndices | ForEach-Object { $row[$_] } | Join-String -Separator "|"
        } else {
            $row -join "|"
        }
        
        # ����Ƿ�Ψһ
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $uniqueCount++
            $row -join "," | Out-File -FilePath $OutputFile -Encoding UTF8 -Append
        }
    }
    catch {
        Write-Warning "�� $processed �н�������: $_"
    }
}

# ������Դ
$parser.Close()
$parser.Dispose()

# ��ʾ���ս��
$endTime = Get-Date
$timeSpan = $endTime - $startTime
Write-Progress -Activity "���!" -Completed
Write-Host "`n�������!" -ForegroundColor Green
Write-Host "ԭʼ����: $($totalLines.ToString('N0'))" -ForegroundColor Yellow
Write-Host "ȥ�غ�����: $($uniqueCount.ToString('N0'))" -ForegroundColor Green
Write-Host "��������: $(($totalLines - $uniqueCount).ToString('N0'))" -ForegroundColor Cyan
Write-Host "�ܺ�ʱ: $($timeSpan.TotalMinutes.ToString('0.00')) ����" -ForegroundColor Cyan
Write-Host "����ļ�: $OutputFile" -ForegroundColor Cyan