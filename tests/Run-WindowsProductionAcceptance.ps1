[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StagingRoot,
    [string]$MetaEditorPath,
    [string]$WorkbookPath,
    [string]$OutputPath,
    [switch]$RequireMetaEditor,
    [switch]$RequireExcel,
    [switch]$AsLibrary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Protect-AcceptanceText {
    param([AllowNull()][string]$Text, [string[]]$SensitiveValues = @())
    if($null -eq $Text) { return $null }
    $protected = $Text
    $automaticSecrets = @([Environment]::MachineName,$env:COMPUTERNAME,$env:USERNAME)
    foreach($secret in @($SensitiveValues + $automaticSecrets)) {
        if(-not [string]::IsNullOrWhiteSpace($secret)) {
            $protected = [regex]::Replace($protected, [regex]::Escape($secret), '[REDACTED]', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }
    $protected = [regex]::Replace($protected, '(?i)[A-Z]:\\Users\\[^\\\r\n";,]+', '[REDACTED_PROFILE]')
    return $protected
}

function Protect-AcceptanceObject {
    param($Value, [string[]]$SensitiveValues = @())
    if($null -eq $Value) { return $null }
    if($Value -is [string]) { return Protect-AcceptanceText -Text $Value -SensitiveValues $SensitiveValues }
    if($Value -is [Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach($key in $Value.Keys) { $copy[$key] = Protect-AcceptanceObject -Value $Value[$key] -SensitiveValues $SensitiveValues }
        return $copy
    }
    if($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = [Collections.Generic.List[object]]::new()
        foreach($item in $Value) { $items.Add((Protect-AcceptanceObject -Value $item -SensitiveValues $SensitiveValues)) }
        return ,$items.ToArray()
    }
    if($Value.PSObject -and @($Value.PSObject.Properties).Count -gt 0 -and
       $Value -isnot [ValueType]) {
        $copy = [ordered]@{}
        foreach($property in $Value.PSObject.Properties) {
            $copy[$property.Name] = Protect-AcceptanceObject -Value $property.Value -SensitiveValues $SensitiveValues
        }
        return $copy
    }
    return $Value
}

function ConvertTo-RedactedAcceptanceJson {
    param([Parameter(Mandatory)]$Report, [string[]]$SensitiveValues = @())
    $protected = Protect-AcceptanceObject -Value $Report -SensitiveValues $SensitiveValues
    return ($protected | ConvertTo-Json -Depth 10)
}

function Write-AtomicAcceptanceReport {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Json)
    $directory = Split-Path -Parent $Path
    if(-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $backup = "$Path.$([guid]::NewGuid().ToString('N')).bak"
    try {
        [IO.File]::WriteAllText($temporary, $Json, (New-Object Text.UTF8Encoding($false)))
        $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json
        if(Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, $backup, $true) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally {
        if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if(Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
}

function New-AcceptanceArtifact {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Path)
    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Acceptance artifact was not produced: $Name" }
    return [ordered]@{
        Name = $Name
        Sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

function New-AcceptanceCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Pass','Fail','NotRun')][string]$Status,
        [Parameter(Mandatory)][string]$StartedUtc,
        [Parameter(Mandatory)][string]$Message,
        [object[]]$Artifacts = @(),
        [bool]$Required = $true
    )
    return [ordered]@{
        Name = $Name
        Status = $Status
        StartedUtc = $StartedUtc
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Message = $Message
        Required = $Required
        Artifacts = @($Artifacts)
    }
}

function ConvertTo-SingleQuotedPowerShellLiteral {
    param([Parameter(Mandatory)][string]$Value)
    return "'$($Value.Replace("'", "''"))'"
}

function Invoke-AcceptancePowerShell {
    param(
        [Parameter(Mandatory)][string]$WindowsPowerShell,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Collections.IDictionary]$Parameters = @{},
        [string[]]$Switches = @(),
        [Parameter(Mandatory)][string]$LogRoot,
        [Parameter(Mandatory)][string]$LogName
    )
    $parts = @('&', (ConvertTo-SingleQuotedPowerShellLiteral -Value $ScriptPath))
    foreach($key in $Parameters.Keys) {
        $parts += "-$key"
        $parts += (ConvertTo-SingleQuotedPowerShellLiteral -Value ([string]$Parameters[$key]))
    }
    foreach($switchName in $Switches) { $parts += "-$switchName" }
    $command = $parts -join ' '
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $stdout = Join-Path $LogRoot "$LogName.stdout.log"
    $stderr = Join-Path $LogRoot "$LogName.stderr.log"
    $process = Start-Process -FilePath $WindowsPowerShell -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -Wait -PassThru
    return [pscustomobject]@{ ExitCode=$process.ExitCode; Stdout=$stdout; Stderr=$stderr }
}

function Invoke-AcceptanceCheck {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Checks,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$PassMessage,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $started = [DateTime]::UtcNow.ToString('o')
    try {
        $artifacts = @(& $Action)
        $Checks.Add((New-AcceptanceCheck -Name $Name -Status Pass -StartedUtc $started -Message $PassMessage -Artifacts $artifacts))
    } catch {
        $Checks.Add((New-AcceptanceCheck -Name $Name -Status Fail -StartedUtc $started -Message ("Check failed: " + $_.Exception.Message)))
    }
}

function Add-NotRunCheck {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Checks,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Message,
        [bool]$Required
    )
    $now = [DateTime]::UtcNow.ToString('o')
    $Checks.Add((New-AcceptanceCheck -Name $Name -Status NotRun -StartedUtc $now -Message $Message -Required $Required))
}

if($AsLibrary) { return }

$acceptanceStarted = [DateTime]::UtcNow.ToString('o')
if(-not (Test-Path -LiteralPath $StagingRoot)) { New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null }
$resolvedStaging = (Resolve-Path -LiteralPath $StagingRoot).Path
if([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $resolvedStaging 'audit\windows-production-acceptance.json' }
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$automationRoot = Join-Path $repositoryRoot 'automation\MoneyMachineCsvSync'
$logRoot = Join-Path $resolvedStaging 'logs'
New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
$windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$checks = [Collections.Generic.List[object]]::new()
$sensitiveValues = [Collections.Generic.List[string]]::new()
foreach($value in @($resolvedStaging,$repositoryRoot,$OutputPath,$MetaEditorPath,$WorkbookPath)) {
    if(-not [string]::IsNullOrWhiteSpace($value)) { $sensitiveValues.Add($value) }
}

Invoke-AcceptanceCheck -Checks $checks -Name 'windows-powershell-5.1' -PassMessage 'Windows PowerShell 5.1 is available.' -Action {
    if($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
        throw 'The acceptance runner requires Windows PowerShell 5.1.'
    }
    if(-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) { throw 'Windows PowerShell executable was not found.' }
}

$componentTests = @(
    [ordered]@{
        Name='schema-v3-sync-and-delivery-contract'
        Script=(Join-Path $repositoryRoot 'tests\Test-MoneyMachineCsvSync.ps1')
        Parameters=[ordered]@{ ScriptPath=(Join-Path $automationRoot 'Sync-BasketsToOneDrive.ps1') }
        Message='Schema, adversarial rows, destination preservation, mutex, atomic state, receiver status, process exits, and task definition passed.'
    },
    [ordered]@{
        Name='mql4-telemetry-contract'
        Script=(Join-Path $repositoryRoot 'tests\Test-V3TelemetryReportingContract.ps1')
        Parameters=[ordered]@{ SourcePath=(Join-Path $repositoryRoot 'AmmarTradingGoldEA - ref reset every bar - V3.mq4') }
        Message='Schema-v3 telemetry and CSV escaping contract passed.'
    },
    [ordered]@{
        Name='scheduled-task-installer-contract'
        Script=(Join-Path $repositoryRoot 'tests\Test-InstallBasketsSyncTask.ps1')
        Parameters=[ordered]@{ ScriptPath=(Join-Path $automationRoot 'Install-BasketsSyncTask.ps1') }
        Message='Scheduled-task identity and installer contract passed.'
    },
    [ordered]@{
        Name='power-query-static-contract'
        Script=(Join-Path $repositoryRoot 'tests\Test-MoneyMachinePowerQueryContract.ps1')
        Parameters=[ordered]@{
            BasketQueryPath=(Join-Path $automationRoot 'PowerQuery\MoneyMachine_Baskets.m')
            StatusQueryPath=(Join-Path $automationRoot 'PowerQuery\MoneyMachine_SyncStatus.m')
        }
        Message='Power Query columns, fingerprint, freshness, and package contract passed.'
    }
)
foreach($component in $componentTests) {
    $captured = $component
    Invoke-AcceptanceCheck -Checks $checks -Name $captured.Name -PassMessage $captured.Message -Action {
        if(-not (Test-Path -LiteralPath $captured.Script -PathType Leaf)) { throw 'Required component test is missing.' }
        $run = Invoke-AcceptancePowerShell -WindowsPowerShell $windowsPowerShell -ScriptPath $captured.Script -Parameters $captured.Parameters -LogRoot $logRoot -LogName $captured.Name
        if($run.ExitCode -ne 0) { throw "Component test exited $($run.ExitCode)." }
    }
}

$publicationRoot = Join-Path $resolvedStaging 'publication'
$publicationSourceRoot = Join-Path $publicationRoot 'source'
$publicationOneDrive = Join-Path $publicationRoot 'receiver'
$publicationRuntime = Join-Path $publicationRoot 'runtime'
New-Item -ItemType Directory -Path $publicationSourceRoot,$publicationOneDrive,$publicationRuntime -Force | Out-Null
$publicationSource = Join-Path $publicationSourceRoot 'AGOLD___Baskets.csv'
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'tests\fixtures\AGOLD___Baskets_v3.csv') -Destination $publicationSource -Force
$publicationConfig = Join-Path $publicationRoot 'accounts.csv'
@([pscustomobject]@{ Enabled='true'; ExpectedMT4Login='892522910'; SourceCsv=$publicationSource; OneDriveRoot=$publicationOneDrive }) |
    Export-Csv -LiteralPath $publicationConfig -NoTypeInformation -Encoding utf8
$sensitiveValues.Add($publicationSource)
$sensitiveValues.Add($publicationOneDrive)
$sensitiveValues.Add($publicationConfig)
$sensitiveValues.Add((Get-Content -LiteralPath $publicationConfig -Raw))
$publishedCsv = Join-Path $publicationOneDrive 'AmarTrading\Account_892522910\Baskets.csv'
$publishedHeartbeat = Join-Path $publicationOneDrive 'AmarTrading\Account_892522910\SyncStatus.json'
$publishedState = Join-Path $publicationRuntime 'state\last-run.json'
Invoke-AcceptanceCheck -Checks $checks -Name 'isolated-atomic-publication' -PassMessage 'An isolated direct-process publication produced hash-consistent CSV, heartbeat, and state artifacts.' -Action {
    $run = Invoke-AcceptancePowerShell -WindowsPowerShell $windowsPowerShell -ScriptPath (Join-Path $automationRoot 'Sync-BasketsToOneDrive.ps1') -Parameters ([ordered]@{
        ConfigPath=$publicationConfig; StableCheckSeconds='0'; MaxRetries='1'; RuntimeRoot=$publicationRuntime; MutexWaitMilliseconds='5000'
    }) -LogRoot $logRoot -LogName 'isolated-atomic-publication'
    if($run.ExitCode -ne 0) { throw "Direct sync process exited $($run.ExitCode)." }
    foreach($path in @($publishedCsv,$publishedHeartbeat,$publishedState)) {
        if(-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'A required publication artifact is missing.' }
    }
    $heartbeat = Get-Content -LiteralPath $publishedHeartbeat -Raw | ConvertFrom-Json
    $state = Get-Content -LiteralPath $publishedState -Raw | ConvertFrom-Json
    $sourceHash = (Get-FileHash -LiteralPath $publicationSource -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $publishedCsv -Algorithm SHA256).Hash
    if($sourceHash -ne $destinationHash -or [string]$heartbeat.SourceHash -ne $sourceHash.ToLowerInvariant() -or [string]$heartbeat.DestinationHash -ne $destinationHash.ToLowerInvariant()) {
        throw 'Publication hashes are inconsistent.'
    }
    if($heartbeat.Status -ne 'Success' -or [bool]$heartbeat.CloudDeliveryVerified) { throw 'Heartbeat status semantics are invalid.' }
    if($state.OverallStatus -ne 'Success') { throw 'Atomic last-run state did not report success.' }
    if(@(Get-ChildItem -LiteralPath $publicationRoot -Recurse -File | Where-Object { $_.Extension -in @('.tmp','.bak') }).Count -ne 0) { throw 'Atomic publication left temporary or backup files.' }
    New-AcceptanceArtifact -Name 'published-csv' -Path $publishedCsv
    New-AcceptanceArtifact -Name 'publisher-heartbeat' -Path $publishedHeartbeat
    New-AcceptanceArtifact -Name 'publisher-state' -Path $publishedState
}

if([string]::IsNullOrWhiteSpace($MetaEditorPath)) {
    Add-NotRunCheck -Checks $checks -Name 'metaeditor-v3-compile' -Message 'MetaEditor path was not supplied.' -Required ([bool]$RequireMetaEditor)
} elseif(-not (Test-Path -LiteralPath $MetaEditorPath -PathType Leaf)) {
    $now = [DateTime]::UtcNow.ToString('o')
    $checks.Add((New-AcceptanceCheck -Name 'metaeditor-v3-compile' -Status Fail -StartedUtc $now -Message 'The supplied MetaEditor executable is unavailable.'))
} else {
    Invoke-AcceptanceCheck -Checks $checks -Name 'metaeditor-v3-compile' -PassMessage 'The isolated V3 MQ4 compilation completed with zero errors and produced an EX4.' -Action {
        $compileRoot = Join-Path $resolvedStaging 'metaeditor'
        New-Item -ItemType Directory -Path $compileRoot -Force | Out-Null
        $compileSource = Join-Path $compileRoot 'AmmarTradingGoldEA-V3.mq4'
        $compileLog = Join-Path $compileRoot 'compile.log'
        $compileOutput = [IO.Path]::ChangeExtension($compileSource, '.ex4')
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'AmmarTradingGoldEA - ref reset every bar - V3.mq4') -Destination $compileSource -Force
        if(Test-Path -LiteralPath $compileLog) { Remove-Item -LiteralPath $compileLog -Force }
        if(Test-Path -LiteralPath $compileOutput) { Remove-Item -LiteralPath $compileOutput -Force }
        $arguments = "/compile:`"$compileSource`" /log:`"$compileLog`""
        $process = Start-Process -FilePath $MetaEditorPath -ArgumentList $arguments -Wait -PassThru
        if(-not (Test-Path -LiteralPath $compileLog -PathType Leaf)) { throw 'MetaEditor did not produce a compile log.' }
        $logText = Get-Content -LiteralPath $compileLog -Raw
        if($logText -notmatch '(?i)\b0 errors?\b' -or $logText -match '(?i)\b[1-9][0-9]* errors?\b') { throw 'MetaEditor compile log did not report zero errors.' }
        if(-not (Test-Path -LiteralPath $compileOutput -PathType Leaf)) { throw 'MetaEditor did not produce the compiled EX4.' }
        New-AcceptanceArtifact -Name 'metaeditor-compile-log' -Path $compileLog
        New-AcceptanceArtifact -Name 'isolated-v3-ex4' -Path $compileOutput
    }
}

$excelAvailable = $null -ne [type]::GetTypeFromProgID('Excel.Application')
if([string]::IsNullOrWhiteSpace($WorkbookPath)) {
    Add-NotRunCheck -Checks $checks -Name 'excel-workbook-refresh' -Message 'Workbook path was not supplied.' -Required ([bool]$RequireExcel)
} elseif(-not $excelAvailable) {
    Add-NotRunCheck -Checks $checks -Name 'excel-workbook-refresh' -Message 'Microsoft Excel is unavailable.' -Required ([bool]$RequireExcel)
} elseif(-not (Test-Path -LiteralPath $WorkbookPath -PathType Leaf)) {
    $now = [DateTime]::UtcNow.ToString('o')
    $checks.Add((New-AcceptanceCheck -Name 'excel-workbook-refresh' -Status Fail -StartedUtc $now -Message 'The supplied workbook is unavailable.'))
} else {
    Invoke-AcceptanceCheck -Checks $checks -Name 'excel-workbook-refresh' -PassMessage 'A workbook copy refreshed against isolated staging and passed query, table, freshness, and package inspection.' -Action {
        $workbookRoot = Join-Path $resolvedStaging 'workbook'
        New-Item -ItemType Directory -Path $workbookRoot -Force | Out-Null
        $stagedWorkbook = Join-Path $workbookRoot 'MoneyMachine_Account_Analysis.xlsx'
        Copy-Item -LiteralPath $WorkbookPath -Destination $stagedWorkbook -Force
        $install = Invoke-AcceptancePowerShell -WindowsPowerShell $windowsPowerShell -ScriptPath (Join-Path $automationRoot 'Install-MoneyMachineWorkbookQueries.ps1') -Parameters ([ordered]@{
            WorkbookPath=$stagedWorkbook; PowerQueryRoot=(Join-Path $automationRoot 'PowerQuery'); OneDriveRoot=$publicationOneDrive
        }) -Switches @('ResetRootToPlaceholder') -LogRoot $logRoot -LogName 'excel-workbook-install'
        if($install.ExitCode -ne 0) { throw "Workbook provisioning exited $($install.ExitCode)." }
        $test = Invoke-AcceptancePowerShell -WindowsPowerShell $windowsPowerShell -ScriptPath (Join-Path $repositoryRoot 'tests\Test-MoneyMachinePowerQueryContract.ps1') -Parameters ([ordered]@{
            BasketQueryPath=(Join-Path $automationRoot 'PowerQuery\MoneyMachine_Baskets.m')
            StatusQueryPath=(Join-Path $automationRoot 'PowerQuery\MoneyMachine_SyncStatus.m')
            WorkbookPath=$stagedWorkbook
        }) -LogRoot $logRoot -LogName 'excel-workbook-contract'
        if($test.ExitCode -ne 0) { throw "Workbook integration test exited $($test.ExitCode)." }
        New-AcceptanceArtifact -Name 'refreshed-workbook-evidence' -Path $stagedWorkbook
    }
}

$requiredFailures = @($checks | Where-Object { $_.Status -eq 'Fail' })
$requiredMissing = @($checks | Where-Object { $_.Status -eq 'NotRun' -and $_.Required })
$overallStatus = if($requiredFailures.Count -gt 0) { 'Fail' } elseif($requiredMissing.Count -gt 0) { 'Incomplete' } else { 'Pass' }
$report = [ordered]@{
    StartedUtc = $acceptanceStarted
    CompletedUtc = [DateTime]::UtcNow.ToString('o')
    Runtime = [ordered]@{
        Platform = 'Windows'
        PowerShellEdition = $PSVersionTable.PSEdition
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    }
    Checks = @($checks)
    OverallStatus = $overallStatus
}
$json = ConvertTo-RedactedAcceptanceJson -Report $report -SensitiveValues @($sensitiveValues)
Write-AtomicAcceptanceReport -Path $OutputPath -Json $json
Write-Host "Windows production acceptance: $overallStatus"
Write-Host "Checks: $($checks.Count); Pass=$(@($checks | Where-Object Status -eq 'Pass').Count); Fail=$($requiredFailures.Count); NotRun=$(@($checks | Where-Object Status -eq 'NotRun').Count)"

if($requiredFailures.Count -gt 0) { exit 1 }
if($requiredMissing.Count -gt 0) { exit 3 }
exit 0
