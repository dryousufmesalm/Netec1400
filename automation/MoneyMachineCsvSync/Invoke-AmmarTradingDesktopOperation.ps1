[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('SystemStatus','Discover','OneDriveRoots','Validate','Apply','Status','SyncNow')]
    [string]$Operation,
    [Parameter(Mandatory)][string]$RequestPath,
    [Parameter(Mandatory)][string]$RuntimeRoot,
    [string]$ConfigPath,
    [string]$TerminalDataRoot,
    [switch]$SkipTaskRegistration,
    [switch]$AsLibrary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$utf8 = New-Object Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function Write-DesktopJson {
    param([Parameter(Mandatory)][object]$Value)
    $json = $Value | ConvertTo-Json -Depth 12 -Compress
    [Console]::Out.WriteLine($json)
}

function Assert-RequestProperties {
    param(
        [Parameter(Mandatory)][psobject]$Request,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Allowed,
        [AllowEmptyCollection()][string[]]$Required = @()
    )

    $allowedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach($name in $Allowed) { [void]$allowedNames.Add($name) }
    foreach($property in $Request.PSObject.Properties) {
        if(-not $allowedNames.Contains($property.Name)) { throw 'The operation request contains an unexpected field.' }
    }
    foreach($name in $Required) {
        if($null -eq $Request.PSObject.Properties[$name]) { throw 'The operation request is missing a required field.' }
    }
}

function Get-LocalOneDriveRoots {
    return @(Get-AmmarTradingWritableOneDriveRoots)
}

function Get-DesktopSystemStatus {
    $oneDriveRoots = @(Get-LocalOneDriveRoots)
    $terminalRoot = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
    $requiredFiles = @(
        'MoneyMachineCsvSchemaV3.psm1',
        'MoneyMachineSyncSetup.psm1',
        'Sync-BasketsToOneDrive.ps1',
        'Install-BasketsSyncTask.ps1',
        'Test-MoneyMachineSyncStatus.ps1'
    )
    $checks = [System.Collections.Generic.List[object]]::new()
    $checks.Add([pscustomobject]@{ Code='Windows'; Name='Windows'; Ready=($env:OS -ceq 'Windows_NT'); Status=if($env:OS -ceq 'Windows_NT'){'Ready'}else{'Unavailable'} })
    $checks.Add([pscustomobject]@{ Code='PowerShell'; Name='Windows PowerShell'; Ready=($PSVersionTable.PSVersion -ge [Version]'5.1'); Status=if($PSVersionTable.PSVersion -ge [Version]'5.1'){'Ready'}else{'Unsupported'} })
    $checks.Add([pscustomobject]@{ Code='OneDrive'; Name='OneDrive'; Ready=(@($oneDriveRoots | Where-Object IsWritable).Count -gt 0); Status=if(@($oneDriveRoots | Where-Object IsWritable).Count -gt 0){'Ready'}else{'Unavailable'} })
    $checks.Add([pscustomobject]@{ Code='Mt4DataRoot'; Name='MT4 data root'; Ready=(Test-Path -LiteralPath $terminalRoot -PathType Container); Status=if(Test-Path -LiteralPath $terminalRoot -PathType Container){'Ready'}else{'NotFound'} })
    $taskCommands = @('Get-ScheduledTask','Get-ScheduledTaskInfo','Register-ScheduledTask')
    $tasksReady = @($taskCommands | Where-Object { -not (Get-Command $_ -ErrorAction SilentlyContinue) }).Count -eq 0
    $checks.Add([pscustomobject]@{ Code='ScheduledTasks'; Name='Windows Scheduled Tasks'; Ready=$tasksReady; Status=if($tasksReady){'Ready'}else{'Unavailable'} })
    $appFilesReady = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $_) -PathType Leaf) }).Count -eq 0
    $checks.Add([pscustomobject]@{ Code='ApplicationFiles'; Name='Application files'; Ready=$appFilesReady; Status=if($appFilesReady){'Ready'}else{'Missing'} })
    return [pscustomobject][ordered]@{
        Ready = @($checks | Where-Object { -not $_.Ready }).Count -eq 0
        ComputerName = $env:COMPUTERNAME
        ApplicationVersion = 'PowerShellBridge-1'
        WindowsVersion = [Environment]::OSVersion.VersionString
        OneDriveRoots = $oneDriveRoots
        Checks = @($checks)
    }
}

function Test-DesktopSelection {
    param([Parameter(Mandatory)][psobject]$Request)

    Assert-RequestProperties -Request $Request -Allowed @('vpsName','oneDriveRoot','destinationFolder','accounts') -Required @('vpsName','oneDriveRoot','accounts')
    $vpsName = ([string]$Request.vpsName).Trim()
    if([string]::IsNullOrWhiteSpace($vpsName) -or $vpsName.Length -gt 100) { throw 'The VPS name is invalid.' }
    $requestedAccounts = @($Request.accounts)
    if($requestedAccounts.Count -eq 0) { throw 'At least one account must be selected.' }

    $seenAccounts = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenDiscoveries = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenSources = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $sources = [System.Collections.Generic.List[string]]::new()
    foreach($account in $requestedAccounts) {
        Assert-RequestProperties -Request $account -Allowed @('discoveryId','expectedMT4Login','sourceCsv') -Required @('discoveryId','expectedMT4Login','sourceCsv')
        $accountNumber = ([string]$account.expectedMT4Login).Trim()
        $discoveryId = ([string]$account.discoveryId).Trim()
        if($accountNumber -notmatch '^\d{4,20}$' -or $discoveryId -cnotmatch '^[A-F0-9]{64}$') { throw 'The selected account identity is invalid.' }
        if(-not $seenAccounts.Add($accountNumber) -or -not $seenDiscoveries.Add($discoveryId)) { throw 'The selection contains duplicate accounts.' }
        $destinationFolder = if($Request.PSObject.Properties['destinationFolder']) { [string]$Request.destinationFolder } else { '' }
        $validated = Test-MoneyMachineSetupRequest -VpsName $vpsName -ExpectedMT4Login $accountNumber -SourceCsv ([string]$account.sourceCsv) -OneDriveRoot ([string]$Request.oneDriveRoot) -DestinationFolder $destinationFolder
        if(-not $seenSources.Add([string]$validated.SourceCsv)) { throw 'The selection contains duplicate source files.' }
        $sources.Add([string]$validated.SourceCsv)
    }

    $missingTerminalRoot = Join-Path $RuntimeRoot 'missing-terminal-root'
    $discoveries = @(Get-AmmarTradingMt4Accounts -TerminalDataRoot $missingTerminalRoot -ManualCsv @($sources))
    foreach($account in $requestedAccounts) {
        $sourcePath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(([string]$account.sourceCsv).Trim()))
        $matches = @($discoveries | Where-Object {
            $_.DiscoveryId -ceq ([string]$account.discoveryId).Trim() -and
            $_.AccountNumber -ceq ([string]$account.expectedMT4Login).Trim() -and
            $_.SourceCsv -ieq $sourcePath -and
            $_.Eligibility -ceq 'Ready'
        })
        if($matches.Count -ne 1) { throw 'A selected discovery is stale or no longer eligible.' }
    }
    return [pscustomobject]@{
        Stages = @([pscustomobject]@{
            Code = 'Validated'
            Status = 'Success'
            Message = "Validated $($requestedAccounts.Count) selected MT4 account source(s)."
        })
    }
}

try {
    $canonicalRuntimeRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($RuntimeRoot.Trim()))
    if(-not (Test-Path -LiteralPath $canonicalRuntimeRoot -PathType Container)) { New-Item -ItemType Directory -Path $canonicalRuntimeRoot -Force | Out-Null }
    if((Get-Item -LiteralPath $canonicalRuntimeRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The runtime root cannot be a reparse point.' }
    $requestRoot = Join-Path $canonicalRuntimeRoot 'requests'
    if(-not (Test-Path -LiteralPath $requestRoot -PathType Container)) { throw 'The request directory is missing.' }
    if((Get-Item -LiteralPath $requestRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The request directory cannot be a reparse point.' }
    $canonicalRequestPath = (Resolve-Path -LiteralPath $RequestPath -ErrorAction Stop).Path
    $requestPrefix = $requestRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if(-not $canonicalRequestPath.StartsWith($requestPrefix, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($canonicalRequestPath) -ine '.json') { throw 'The request path is outside the runtime request directory.' }
    $requestFile = Get-Item -LiteralPath $canonicalRequestPath -Force -ErrorAction Stop
    if($requestFile.Length -gt 65536 -or ($requestFile.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The operation request is not valid.' }
    $requestReadStream = [IO.File]::Open($canonicalRequestPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $requestReader = [IO.StreamReader]::new($requestReadStream, (New-Object Text.UTF8Encoding($false,$true)), $false, 4096, $true)
        try { $requestText = $requestReader.ReadToEnd() } finally { $requestReader.Dispose() }
    } finally {
        $requestReadStream.Dispose()
    }
    $request = if([string]::IsNullOrWhiteSpace($requestText)) { [pscustomobject]@{} } else { $requestText | ConvertFrom-Json -ErrorAction Stop }
    if($request -isnot [pscustomobject]) { throw 'The operation request must be a JSON object.' }

    $setupModule = Join-Path $PSScriptRoot 'MoneyMachineSyncSetup.psm1'
    Import-Module -Name $setupModule -Force -ErrorAction Stop | Out-Null
    $configPath = if([string]::IsNullOrWhiteSpace($ConfigPath)) { Join-Path $canonicalRuntimeRoot 'accounts.csv' } else { [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath.Trim())) }
    [void](Restore-AmmarTradingSetupTransaction -RuntimeRoot $canonicalRuntimeRoot -ConfigPath $configPath)

    $result = switch($Operation) {
        'SystemStatus' {
            Assert-RequestProperties -Request $request -Allowed @()
            Get-DesktopSystemStatus
            break
        }
        'Discover' {
            Assert-RequestProperties -Request $request -Allowed @('manualCsv')
            $manualCsv = if($null -eq $request.PSObject.Properties['manualCsv']) { @() } else { @($request.manualCsv | ForEach-Object { [string]$_ }) }
            [pscustomobject]@{ Accounts=@(Get-AmmarTradingMt4Accounts -TerminalDataRoot $TerminalDataRoot -ManualCsv $manualCsv) }
            break
        }
        'OneDriveRoots' {
            Assert-RequestProperties -Request $request -Allowed @()
            [pscustomobject]@{ Roots=@(Get-LocalOneDriveRoots) }
            break
        }
        'Validate' {
            Test-DesktopSelection -Request $request
            break
        }
        'Apply' {
            Assert-RequestProperties -Request $request -Allowed @('vpsName','oneDriveRoot','destinationFolder','accounts') -Required @('vpsName','oneDriveRoot','accounts')
            Invoke-AmmarTradingBatchSetup -Request $request -ConfigPath $configPath -RuntimeRoot $canonicalRuntimeRoot -SkipTaskRegistration:$SkipTaskRegistration
            break
        }
        'Status' {
            Assert-RequestProperties -Request $request -Allowed @()
            $statusScript = Join-Path $PSScriptRoot 'Test-MoneyMachineSyncStatus.ps1'
            $statusAccounts = @(& {
                param($LibraryPath,$StatusConfigPath,$StatusRuntimeRoot)
                . $LibraryPath -AsLibrary
                Get-AmmarTradingConfiguredSyncStatus -ConfigPath $StatusConfigPath -RuntimeRoot $StatusRuntimeRoot
            } $statusScript $configPath $canonicalRuntimeRoot)
            [pscustomobject]@{ Accounts=$statusAccounts }
            break
        }
        'SyncNow' {
            Assert-RequestProperties -Request $request -Allowed @('accountNumbers')
            if(-not (Test-Path -LiteralPath $configPath -PathType Leaf)) { throw 'No account configuration is available.' }
            $syncScript = Join-Path $PSScriptRoot 'Sync-BasketsToOneDrive.ps1'
            [string[]]$accountNumbers = if($null -eq $request.PSObject.Properties['accountNumbers']) { @() } else { @($request.accountNumbers | ForEach-Object { ([string]$_).Trim() }) }
            if(@($accountNumbers | Where-Object { $_ -notmatch '^\d{4,20}$' }).Count -gt 0 -or @($accountNumbers | Select-Object -Unique).Count -ne @($accountNumbers).Count) { throw 'The account selection is invalid.' }
            $syncInvocation = [pscustomobject]@{
                ConfigPath = $configPath
                RuntimeRoot = $canonicalRuntimeRoot
                AccountNumbers = $accountNumbers
            }
            $results = @(& {
                param($LibraryPath,$Invocation)
                . $LibraryPath -AsLibrary -ConfigPath $Invocation.ConfigPath -RuntimeRoot $Invocation.RuntimeRoot
                $syncParameters = @{ ConfigPath=$Invocation.ConfigPath; StableCheckSeconds=2; MaxRetries=1; RuntimeRoot=$Invocation.RuntimeRoot }
                if(@($Invocation.AccountNumbers).Count -gt 0) { $syncParameters['AccountNumbers'] = @($Invocation.AccountNumbers) }
                Invoke-MoneyMachineCsvSync @syncParameters
            } $syncScript $syncInvocation)
            if(@($results | Where-Object Status -eq 'Error').Count -gt 0) { throw 'One or more configured accounts could not be synchronized.' }
            [pscustomobject]@{ Status='Success'; Results=$results; CloudDeliveryVerified=$false }
            break
        }
    }

    if($AsLibrary) { return $result }
    Write-DesktopJson -Value $result
    exit 0
} catch {
    $rawMessage = [string]$_.Exception.Message
    $safeMessage = if($AsLibrary -or ($rawMessage.Length -ge 1 -and $rawMessage.Length -le 200 -and $rawMessage -notmatch '[\\/:]')) {
        $rawMessage
    } else {
        'The desktop operation could not be completed.'
    }
    $failure = [pscustomobject]@{
        Ok = $false
        Code = 'OperationFailed'
        Message = $safeMessage
    }
    if($AsLibrary) { return $failure }
    Write-DesktopJson -Value $failure
    exit 1
}
