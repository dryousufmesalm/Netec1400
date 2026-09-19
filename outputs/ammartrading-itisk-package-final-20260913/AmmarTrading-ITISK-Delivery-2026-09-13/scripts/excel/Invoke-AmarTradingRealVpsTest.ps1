$ErrorActionPreference='Stop'
Start-Transcript -Path 'C:\CodexWorker\amartrading-real-vps-20260904\visible-transcript.txt' -Append
try {
 Write-Output "Interactive Excel test started at $([DateTime]::UtcNow.ToString('o'))"
 & 'C:\CodexWorker\amartrading-real-vps-20260904\test-real.ps1'
} catch {
 Write-Output $_.Exception.ToString()
 Write-Output $_.ScriptStackTrace
 throw
} finally {Stop-Transcript}
