[CmdletBinding()]
param(
    [string]$EntryPoint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if([string]::IsNullOrWhiteSpace($EntryPoint)) {
    $EntryPoint = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\Invoke-AmmarTradingDesktopOperation.ps1'
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("AmmarTradingDesktopOperationTest_" + [guid]::NewGuid().ToString('N'))
$runtimeRoot = Join-Path $testRoot 'runtime'
$requestRoot = Join-Path $runtimeRoot 'requests'
$fixturePath = Join-Path $PSScriptRoot 'fixtures\AGOLD___Baskets_v3.csv'
$testOneDriveAccountKey = 'HKCU:\Software\Microsoft\OneDrive\Accounts\AmmarTradingTest_' + [guid]::NewGuid().ToString('N')
$previousOneDrive = $env:OneDrive
$powerShell = if(Test-Path -LiteralPath (Join-Path $PSHOME 'pwsh.exe')) {
    Join-Path $PSHOME 'pwsh.exe'
} else {
    Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function Assert-True {
    param([bool]$Condition,[string]$Message)
    if(-not $Condition) { throw $Message }
}

function Remove-VerifiedSyntheticOneDriveAccountKey {
    param([Parameter(Mandatory)][string]$LiteralPath)
    $cleanupFailure = $null
    try {
        if(Test-Path -LiteralPath $LiteralPath) { Remove-Item -LiteralPath $LiteralPath -Recurse -Force -ErrorAction Stop }
    } catch { $cleanupFailure = $_ }
    $stillExists = $true
    try { $stillExists = Test-Path -LiteralPath $LiteralPath } catch { if($null -eq $cleanupFailure) { $cleanupFailure = $_ } }
    if($null -ne $cleanupFailure -or $stillExists) { throw "Synthetic OneDrive account registry cleanup failed for '$LiteralPath'." }
}

function Invoke-DesktopOperation {
    param(
        [Parameter(Mandatory)][ValidateSet('SystemStatus','Discover','OneDriveRoots','Validate','Apply','Status','SyncNow')][string]$Operation,
        [Parameter(Mandatory)][object]$Request
    )

    if(-not (Test-Path -LiteralPath $requestRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $requestRoot -Force | Out-Null
    }
    $requestPath = Join-Path $requestRoot ("request.$([guid]::NewGuid().ToString('N')).json")
    $stderrPath = Join-Path $testRoot ("stderr.$([guid]::NewGuid().ToString('N')).txt")
    try {
        [IO.File]::WriteAllText($requestPath, ($Request | ConvertTo-Json -Depth 12 -Compress), (New-Object Text.UTF8Encoding($false)))
        $lines = @(& $powerShell -NoProfile -NonInteractive -File $EntryPoint -Operation $Operation -RequestPath $requestPath -RuntimeRoot $runtimeRoot 2>$stderrPath)
        $exitCode = $LASTEXITCODE
        $stdout = $lines -join [Environment]::NewLine
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($stdout)) -Message "$Operation must emit a JSON response."
        $parsed = $stdout | ConvertFrom-Json -ErrorAction Stop
        Assert-True -Condition ($stdout.Trim().StartsWith('{') -and $stdout.Trim().EndsWith('}')) -Message "$Operation must emit exactly one JSON object."
        if($exitCode -ne 0) {
            $stderr = if(Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { '' }
            throw "$Operation failed with exit code $exitCode. JSON=$stdout STDERR=$stderr"
        }
        return $parsed
    } finally {
        if(Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath -Force }
        if(Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force }
    }
}

try {
    Assert-True -Condition (Test-Path -LiteralPath $EntryPoint -PathType Leaf) -Message "Desktop operation entry point was not found: $EntryPoint"
    New-Item -ItemType Directory -Path $requestRoot -Force | Out-Null

    $manualDirectory = Join-Path $testRoot 'manual'
    $manualCsv = Join-Path $manualDirectory 'AGOLD___Baskets.csv'
    New-Item -ItemType Directory -Path $manualDirectory -Force | Out-Null
    Copy-Item -LiteralPath $fixturePath -Destination $manualCsv

    $oneDriveRoot = Join-Path $testRoot 'OneDrive'
    New-Item -ItemType Directory -Path $oneDriveRoot -Force | Out-Null
    $env:OneDrive = $oneDriveRoot
    New-Item -Path $testOneDriveAccountKey -Force | Out-Null
    New-ItemProperty -LiteralPath $testOneDriveAccountKey -Name 'UserFolder' -Value $oneDriveRoot -PropertyType String -Force | Out-Null
    try {
        $system = Invoke-DesktopOperation -Operation SystemStatus -Request ([pscustomobject]@{})
        Assert-True -Condition ($null -ne $system.Ready) -Message 'SystemStatus must include a Ready result.'
        Assert-True -Condition (@($system.Checks).Count -gt 0) -Message 'SystemStatus must include bounded compatibility checks.'

        $roots = Invoke-DesktopOperation -Operation OneDriveRoots -Request ([pscustomobject]@{})
        Assert-True -Condition (@($roots.Roots | Where-Object Path -eq (Resolve-Path -LiteralPath $oneDriveRoot).Path).Count -eq 1) -Message 'OneDriveRoots must include the current signed-in local root.'

        $discovery = Invoke-DesktopOperation -Operation Discover -Request ([pscustomobject]@{ manualCsv=@($manualCsv) })
        $manual = @($discovery.Accounts | Where-Object SourceCsv -eq (Resolve-Path -LiteralPath $manualCsv).Path)
        Assert-True -Condition ($manual.Count -eq 1) -Message 'Discover must validate the manually selected CSV through the shared discovery function.'
        Assert-True -Condition ($manual[0].Eligibility -ceq 'Ready') -Message 'The schema-v3 manual fixture must be ready.'

        $selection = [pscustomobject]@{
            vpsName = 'Desktop test VPS'
            oneDriveRoot = $oneDriveRoot
            accounts = @([pscustomobject]@{
                discoveryId = $manual[0].DiscoveryId
                expectedMT4Login = $manual[0].AccountNumber
                sourceCsv = $manual[0].SourceCsv
            })
        }
        $validation = Invoke-DesktopOperation -Operation Validate -Request $selection
        Assert-True -Condition (@($validation.Stages | Where-Object Code -eq 'Validated').Count -eq 1) -Message 'Validate must return the stable validation stage.'

        @([pscustomobject][ordered]@{
            Enabled='true'
            VpsName='Desktop test VPS'
            ExpectedMT4Login=$manual[0].AccountNumber
            SourceCsv=$manual[0].SourceCsv
            OneDriveRoot=$oneDriveRoot
        }) | Export-Csv -LiteralPath (Join-Path $runtimeRoot 'accounts.csv') -NoTypeInformation -Encoding utf8

        $sync = Invoke-DesktopOperation -Operation SyncNow -Request ([pscustomobject]@{ accountNumbers=@($manual[0].AccountNumber) })
        Assert-True -Condition (@($sync.Results | Where-Object Status -eq 'Success').Count -eq 1) -Message 'SyncNow must publish the configured test account.'

        $status = Invoke-DesktopOperation -Operation Status -Request ([pscustomobject]@{})
        $configured = @($status.Accounts | Where-Object AccountNumber -eq $manual[0].AccountNumber)
        Assert-True -Condition ($configured.Count -eq 1) -Message 'Status must return the configured account.'
        Assert-True -Condition ([bool]$configured[0].LocalPublished) -Message 'Status must report the local publication.'
        Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$configured[0].StatusCode)) -Message 'Status must include a stable status code.'
        Assert-True -Condition ($null -ne $configured[0].TaskResultCode) -Message 'Status must include task result evidence.'
    } finally {
        $env:OneDrive = $previousOneDrive
    }

    Write-Host 'AmmarTrading desktop operation entry-point tests passed.'
}
finally {
    $env:OneDrive = $previousOneDrive
    try { Remove-VerifiedSyntheticOneDriveAccountKey -LiteralPath $testOneDriveAccountKey }
    finally {
        if(Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    }
}
