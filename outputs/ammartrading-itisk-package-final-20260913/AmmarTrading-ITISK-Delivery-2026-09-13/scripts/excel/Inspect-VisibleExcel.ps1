$out = 'C:\CodexWorker\amartrading-excel-20260904'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$bounds = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$bitmap = New-Object Drawing.Bitmap $bounds.Width,$bounds.Height
$graphics = [Drawing.Graphics]::FromImage($bitmap)
$graphics.CopyFromScreen($bounds.Location,[Drawing.Point]::Empty,$bounds.Size)
$bitmap.Save((Join-Path $out 'desktop-excel.png'))
$graphics.Dispose()
$bitmap.Dispose()
try {
    $excel = [Runtime.InteropServices.Marshal]::GetActiveObject('Excel.Application')
    @{Visible=$excel.Visible;Books=@($excel.Workbooks | ForEach-Object {$_.FullName});ProtectedViews=$excel.ProtectedViewWindows.Count;Ready=$excel.Ready} | ConvertTo-Json | Set-Content (Join-Path $out 'desktop-excel.json')
} catch { $_.Exception.Message | Set-Content (Join-Path $out 'desktop-excel.json') }
