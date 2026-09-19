$ErrorActionPreference='Stop'
$dir='C:\CodexWorker\amartrading-real-vps-20260904'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AmarShow {
 [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr a,int x,int y,int w,int ht,uint f);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int n);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out RECT r);
 [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h,IntPtr dc,uint flags);
 public struct RECT {public int Left,Top,Right,Bottom;}
}
'@
Add-Type -AssemblyName System.Drawing
[void][AmarShow]::SetProcessDPIAware()
$excel=[Runtime.InteropServices.Marshal]::GetActiveObject('Excel.Application')
$book=$excel.Workbooks.Item('AmarTrading_REAL_VPS.xlsx')
$excel.Visible=$true
$book.Activate()
$book.Worksheets.Item('VPS Verification').Activate()
if(Test-Path (Join-Path $dir 'analytics-verification.json')) {
 $analytics=Get-Content (Join-Path $dir 'analytics-verification.json') -Raw | ConvertFrom-Json
 if($analytics.Passed){$book.Worksheets.Item('VPS Verification').Range('A15').Value2='PASS: Account Analysis and Data Quality also match the real CSV data.'}
}
$excel.ActiveWindow.Zoom=60
$book.Save()
$hwnd=[IntPtr]$excel.Hwnd
[void][AmarShow]::ShowWindow($hwnd,9)
[void][AmarShow]::SetWindowPos($hwnd,[IntPtr](-1),50,50,1280,820,0x0040)
[void][AmarShow]::SetForegroundWindow($hwnd)
Start-Sleep -Seconds 3
$r=New-Object AmarShow+RECT
[void][AmarShow]::GetWindowRect($hwnd,[ref]$r)
$b=New-Object Drawing.Bitmap ($r.Right-$r.Left),($r.Bottom-$r.Top)
$g=[Drawing.Graphics]::FromImage($b)
try {
 $dc=$g.GetHdc()
 try { $printed=[AmarShow]::PrintWindow($hwnd,$dc,2) } finally {$g.ReleaseHdc($dc)}
 if(-not $printed){throw 'PrintWindow could not capture Excel.'}
 $b.Save((Join-Path $dir '06-excel-window.png'))
} finally {
 $g.Dispose();$b.Dispose()
 [void][AmarShow]::SetWindowPos($hwnd,[IntPtr](-2),0,0,0,0,0x0013)
}
@{Book=$book.FullName;Sheet=$excel.ActiveSheet.Name;Visible=$excel.Visible;Utc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content (Join-Path $dir 'visible-readback.json')
