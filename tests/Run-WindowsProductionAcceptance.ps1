[CmdletBinding()]
param(
    [string]$StagingRoot,
    [string]$MetaEditorPath,
    [string]$WorkbookPath,
    [string]$OutputPath,
    [switch]$RequireMetaEditor,
    [switch]$RequireExcel,
    [switch]$AsLibrary,
    [ValidateSet('Staging','Vps','ReportingPc')][string]$AcceptanceRole = 'Staging',
    [switch]$StagingOnly,
    [string]$VpsName,
    [string[]]$ExpectedAccountNumber,
    [string]$OneDriveRoot,
    [string]$ConfigPath,
    [string]$EvidenceOutputPath,
    [string]$VpsEvidencePath
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

function Assert-AmmarTradingExpectedAccounts {
    param([Parameter(Mandatory)][string[]]$ExpectedAccountNumber)
    $accounts = @($ExpectedAccountNumber | ForEach-Object { ([string]$_).Trim() })
    if($accounts.Count -lt 2) { throw 'End-to-end acceptance requires at least two expected account numbers.' }
    foreach($account in $accounts) {
        if($account -notmatch '^\d{4,20}$') { throw 'Expected account numbers must contain 4 to 20 digits.' }
    }
    if(@($accounts | Select-Object -Unique).Count -ne $accounts.Count) { throw 'Expected account numbers must be unique.' }
    return $accounts
}

function Get-AmmarTradingScheduledTaskEvidence {
    $taskNames = @('MoneyMachine-Baskets-To-OneDrive-Daily','MoneyMachine-Baskets-To-OneDrive-StartupCatchup')
    $tasks = [Collections.Generic.List[object]]::new()
    foreach($taskName in $taskNames) {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if($null -eq $task) { throw "Required synchronization task is missing: $taskName" }
        $info = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
        $state = [string]$task.State
        $result = [int64]$info.LastTaskResult
        if($state -cne 'Ready') { throw "Synchronization task is not ready: $taskName" }
        if($result -ne 0) { throw "Synchronization task has not completed successfully: $taskName" }
        $tasks.Add([pscustomobject]@{ Name=$taskName; State=$state; LastTaskResult=$result })
    }
    return [pscustomobject]@{ TaskState='Ready'; LastTaskResult=0; Tasks=@($tasks) }
}

function Get-AmmarTradingVpsAcceptanceEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VpsName,
        [Parameter(Mandatory)][string[]]$ExpectedAccountNumber,
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$ConfigPath,
        [scriptblock]$TaskEvidenceProvider = ${function:Get-AmmarTradingScheduledTaskEvidence}
    )
    if([string]::IsNullOrWhiteSpace($VpsName)) { throw 'VPS name is required.' }
    $accounts = @(Assert-AmmarTradingExpectedAccounts -ExpectedAccountNumber $ExpectedAccountNumber)
    if(-not (Test-Path -LiteralPath $OneDriveRoot -PathType Container)) { throw 'The supplied OneDrive root is unavailable.' }
    if(-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw 'The account mapping file is unavailable.' }
    $canonicalRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $OneDriveRoot).Path).TrimEnd('\')
    $mappings = @(Import-Csv -LiteralPath $ConfigPath -ErrorAction Stop)
    $taskEvidence = & $TaskEvidenceProvider
    if([string]$taskEvidence.TaskState -cne 'Ready' -or [int64]$taskEvidence.LastTaskResult -ne 0) {
        throw 'Synchronization automation is not in the required Ready state.'
    }
    $results = [Collections.Generic.List[object]]::new()
    foreach($account in $accounts) {
        $matches = @($mappings | Where-Object { ([string]$_.ExpectedMT4Login).Trim() -ceq $account })
        if($matches.Count -ne 1) { throw "Expected exactly one mapping for account $account." }
        $mapping = $matches[0]
        if(([string]$mapping.Enabled).Trim() -notmatch '^(?i:true|1|yes)$') { throw "The mapping for account $account is not enabled." }
        if(([string]$mapping.VpsName).Trim() -cne $VpsName.Trim()) { throw "The mapping for account $account belongs to a different VPS." }
        $mappingRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(([string]$mapping.OneDriveRoot).Trim())).TrimEnd('\')
        if($mappingRoot -ine $canonicalRoot) { throw "The mapping for account $account uses a different OneDrive root." }
        $source = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables(([string]$mapping.SourceCsv).Trim()))
        $destination = Join-Path $canonicalRoot "AmmarTrading\Account_$account\Baskets.csv"
        if(-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "The source publication for account $account is missing." }
        if(-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw "The local OneDrive publication for account $account is missing." }
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if($sourceHash -cne $destinationHash) { throw "Source and destination hashes differ for account $account." }
        $heartbeatPath = Join-Path (Split-Path -Parent $destination) 'SyncStatus.json'
        if(-not (Test-Path -LiteralPath $heartbeatPath -PathType Leaf)) { throw "Sync status is missing for account $account." }
        $heartbeat = Get-Content -LiteralPath $heartbeatPath -Raw | ConvertFrom-Json
        if([string]$heartbeat.AccountNumber -cne $account -or [string]$heartbeat.Status -cne 'Success') { throw "Sync status is invalid for account $account." }
        if([bool]$heartbeat.CloudDeliveryVerified) { throw 'VPS publication evidence must not claim cloud delivery.' }
        if([string]$heartbeat.SourceHash -cne $sourceHash -or [string]$heartbeat.DestinationHash -cne $destinationHash) { throw "Sync status hashes differ for account $account." }
        $results.Add([pscustomobject][ordered]@{
            AccountNumber=$account
            SourceHash=$sourceHash
            DestinationHash=$destinationHash
            TaskState='Ready'
            CloudDeliveryVerified=$false
        })
    }
    return [pscustomobject][ordered]@{
        SchemaVersion=1
        EvidenceRole='Vps'
        VpsName=$VpsName.Trim()
        CapturedUtc=[DateTime]::UtcNow.ToString('o')
        Accounts=@($results.ToArray())
        CloudDeliveryVerified=$false
        OverallStatus='Pass'
    }
}

function Get-AmmarTradingReportingAcceptanceEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VpsName,
        [Parameter(Mandatory)][string[]]$ExpectedAccountNumber,
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$VpsEvidencePath
    )
    $accounts = @(Assert-AmmarTradingExpectedAccounts -ExpectedAccountNumber $ExpectedAccountNumber)
    if(-not (Test-Path -LiteralPath $OneDriveRoot -PathType Container)) { throw 'The reporting-PC OneDrive root is unavailable.' }
    if(-not (Test-Path -LiteralPath $VpsEvidencePath -PathType Leaf)) { throw 'The separate VPS evidence file is unavailable.' }
    $vpsEvidence = Get-Content -LiteralPath $VpsEvidencePath -Raw | ConvertFrom-Json
    if([string]$vpsEvidence.EvidenceRole -cne 'Vps' -or [bool]$vpsEvidence.CloudDeliveryVerified -or [string]$vpsEvidence.OverallStatus -cne 'Pass') {
        throw 'The supplied evidence is not valid VPS-local acceptance evidence.'
    }
    if([string]$vpsEvidence.VpsName -cne $VpsName.Trim()) { throw 'The VPS evidence belongs to a different named VPS.' }
    $canonicalRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $OneDriveRoot).Path).TrimEnd('\')
    $results = [Collections.Generic.List[object]]::new()
    foreach($account in $accounts) {
        $matches = @($vpsEvidence.Accounts | Where-Object { [string]$_.AccountNumber -ceq $account })
        if($matches.Count -ne 1) { throw "VPS evidence does not contain exactly one result for account $account." }
        $destination = Join-Path $canonicalRoot "AmmarTrading\Account_$account\Baskets.csv"
        if(-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw "The reporting PC has not physically received account $account." }
        $reportingHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if($reportingHash -cne [string]$matches[0].DestinationHash) { throw "The reporting-PC hash differs from VPS evidence for account $account." }
        $results.Add([pscustomobject][ordered]@{
            AccountNumber=$account
            VpsPublishedHash=[string]$matches[0].DestinationHash
            ReportingPcHash=$reportingHash
            CloudDeliveryVerified=$true
        })
    }
    return [pscustomobject][ordered]@{
        SchemaVersion=1
        EvidenceRole='ReportingPc'
        VpsName=$VpsName.Trim()
        CapturedUtc=[DateTime]::UtcNow.ToString('o')
        Accounts=@($results.ToArray())
        CloudDeliveryVerified=$true
        OverallStatus='Pass'
    }
}

if($AsLibrary) { return }

if($StagingOnly) { $AcceptanceRole = 'Staging' }
if($AcceptanceRole -in @('Vps','ReportingPc')) {
    if([string]::IsNullOrWhiteSpace($VpsName) -or $null -eq $ExpectedAccountNumber -or
       [string]::IsNullOrWhiteSpace($OneDriveRoot) -or [string]::IsNullOrWhiteSpace($EvidenceOutputPath)) {
        throw 'VPS name, expected account numbers, OneDrive root, and evidence output path are required for end-to-end acceptance.'
    }
    $evidence = if($AcceptanceRole -ceq 'Vps') {
        if([string]::IsNullOrWhiteSpace($ConfigPath)) { throw 'The mapping configuration path is required for VPS acceptance.' }
        Get-AmmarTradingVpsAcceptanceEvidence -VpsName $VpsName -ExpectedAccountNumber $ExpectedAccountNumber -OneDriveRoot $OneDriveRoot -ConfigPath $ConfigPath
    } else {
        if([string]::IsNullOrWhiteSpace($VpsEvidencePath)) { throw 'The separate VPS evidence path is required for reporting-PC acceptance.' }
        Get-AmmarTradingReportingAcceptanceEvidence -VpsName $VpsName -ExpectedAccountNumber $ExpectedAccountNumber -OneDriveRoot $OneDriveRoot -VpsEvidencePath $VpsEvidencePath
    }
    $sensitive = @($OneDriveRoot,$ConfigPath,$EvidenceOutputPath,$VpsEvidencePath)
    Write-AtomicAcceptanceReport -Path $EvidenceOutputPath -Json (ConvertTo-RedactedAcceptanceJson -Report $evidence -SensitiveValues $sensitive)
    Write-Host "AmmarTrading $AcceptanceRole end-to-end acceptance: Pass"
    exit 0
}

if([string]::IsNullOrWhiteSpace($StagingRoot)) {
    $StagingRoot = Join-Path ([IO.Path]::GetTempPath()) ("AmmarTrading-StagingAcceptance-" + [guid]::NewGuid().ToString('N'))
}

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
$publishedCsv = Join-Path $publicationOneDrive 'AmmarTrading\Account_892522910\Baskets.csv'
$publishedHeartbeat = Join-Path $publicationOneDrive 'AmmarTrading\Account_892522910\SyncStatus.json'
$publishedState = Join-Path $publicationRuntime 'state\last-run.json'
Invoke-AcceptanceCheck -Checks $checks -Name 'isolated-atomic-publication' -PassMessage 'An isolated direct-process publication produced hash-consistent CSV, heartbeat, and state artifacts.' -Action {
    $previousOneDrive = $env:OneDrive
    try {
        $env:OneDrive = $publicationOneDrive
        $run = Invoke-AcceptancePowerShell -WindowsPowerShell $windowsPowerShell -ScriptPath (Join-Path $automationRoot 'Sync-BasketsToOneDrive.ps1') -Parameters ([ordered]@{
            ConfigPath=$publicationConfig; StableCheckSeconds='0'; MaxRetries='1'; RuntimeRoot=$publicationRuntime; MutexWaitMilliseconds='5000'
        }) -LogRoot $logRoot -LogName 'isolated-atomic-publication'
    } finally {
        $env:OneDrive = $previousOneDrive
    }
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
