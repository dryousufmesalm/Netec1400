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
$script:AmmarTradingAcceptanceLibraryMode = $false
$script:AmmarTradingAcceptanceTestContext = $null
$script:AmmarTradingAcceptanceRepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:AmmarTradingAcceptanceAutomationRoot = Join-Path $script:AmmarTradingAcceptanceRepositoryRoot 'automation\MoneyMachineCsvSync'
Import-Module -Name (Join-Path $script:AmmarTradingAcceptanceAutomationRoot 'MoneyMachineCsvSchemaV3.psm1') -Force -ErrorAction Stop
Import-Module -Name (Join-Path $script:AmmarTradingAcceptanceAutomationRoot 'MoneyMachineSyncSetup.psm1') -Force -ErrorAction Stop

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

function Get-AmmarTradingAcceptanceTextHash {
    param([Parameter(Mandatory)][string]$Domain,[Parameter(Mandatory)][string]$Value)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes("$Domain`0$Value")
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()
    } finally { $sha256.Dispose() }
}

function Set-AmmarTradingAcceptanceTestContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{64}$')][string]$MachineIdentityHash,
        [Parameter(Mandatory)][bool]$OneDriveProcessRunning,
        [Parameter(Mandatory)][uint32]$ReceiptAttributeValue,
        [Parameter(Mandatory)][scriptblock]$TaskEvidenceProvider
    )
    if(-not $script:AmmarTradingAcceptanceLibraryMode) { throw 'Acceptance test seams are available only in library mode.' }
    $script:AmmarTradingAcceptanceTestContext = @{
        MachineIdentityHash=$MachineIdentityHash
        OneDriveProcessRunning=$OneDriveProcessRunning
        ReceiptAttributeValue=$ReceiptAttributeValue
        TaskEvidenceProvider=$TaskEvidenceProvider
    }
}

function Get-AmmarTradingAcceptanceMachineIdentity {
    if($script:AmmarTradingAcceptanceLibraryMode -and $null -ne $script:AmmarTradingAcceptanceTestContext) {
        return [pscustomobject][ordered]@{ Scheme='sha256-domain-separated-machine-guid'; Version=1; Hash=[string]$script:AmmarTradingAcceptanceTestContext.MachineIdentityHash }
    }
    $machine = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Cryptography' -Name MachineGuid -ErrorAction Stop
    $parsedMachineGuid = [guid]::Empty
    if(-not [guid]::TryParse(([string]$machine.MachineGuid).Trim(),[ref]$parsedMachineGuid)) { throw 'Windows machine identity is unavailable.' }
    $machineGuid = $parsedMachineGuid.ToString('D').ToLowerInvariant()
    return [pscustomobject][ordered]@{
        Scheme='sha256-domain-separated-machine-guid'
        Version=1
        Hash=Get-AmmarTradingAcceptanceTextHash -Domain 'AmmarTrading.Sync.Acceptance.MachineIdentity.v1' -Value $machineGuid
    }
}

function Get-AmmarTradingAcceptanceRootIdentity {
    param([Parameter(Mandatory)][string]$CanonicalRoot)
    $normalized = [IO.Path]::GetFullPath($CanonicalRoot).TrimEnd('\').ToUpperInvariant()
    return [pscustomobject][ordered]@{
        Scheme='sha256-domain-separated-canonical-root'
        Version=1
        Hash=Get-AmmarTradingAcceptanceTextHash -Domain 'AmmarTrading.Sync.Acceptance.OneDriveRoot.v1' -Value $normalized
    }
}

function Test-AmmarTradingAcceptanceOneDriveProcess {
    if($script:AmmarTradingAcceptanceLibraryMode -and $null -ne $script:AmmarTradingAcceptanceTestContext) {
        return [bool]$script:AmmarTradingAcceptanceTestContext.OneDriveProcessRunning
    }
    return @(Get-Process -Name OneDrive -ErrorAction SilentlyContinue).Count -gt 0
}

function Get-AmmarTradingAcceptanceReceiptAttributeValue {
    param([Parameter(Mandatory)][string]$Path)
    if($script:AmmarTradingAcceptanceLibraryMode -and $null -ne $script:AmmarTradingAcceptanceTestContext) {
        return [uint32]$script:AmmarTradingAcceptanceTestContext.ReceiptAttributeValue
    }
    return [uint32](Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Attributes.value__
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

function Get-AmmarTradingAcceptanceTaskEvidence {
    if($script:AmmarTradingAcceptanceLibraryMode -and $null -ne $script:AmmarTradingAcceptanceTestContext) {
        return & $script:AmmarTradingAcceptanceTestContext.TaskEvidenceProvider
    }
    return Get-AmmarTradingScheduledTaskEvidence
}

function Test-AmmarTradingPathBelow {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Root)
    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    return $canonicalPath -ieq $canonicalRoot -or $canonicalPath.StartsWith($canonicalRoot + '\',[StringComparison]::OrdinalIgnoreCase)
}

function Assert-AmmarTradingAcceptanceFixedLocalPath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Description)
    $canonical = [IO.Path]::GetFullPath($Path)
    $volumeRoot = [IO.Path]::GetPathRoot($canonical)
    if([string]::IsNullOrWhiteSpace($volumeRoot) -or (New-Object IO.DriveInfo($volumeRoot)).DriveType -ne [IO.DriveType]::Fixed) {
        throw "$Description must use a fixed local filesystem volume."
    }
    return $canonical
}

function Write-NewAmmarTradingAcceptanceEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Json,
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [string[]]$ProtectedPaths=@(),
        [string[]]$InputPaths=@()
    )
    $null = $Json | ConvertFrom-Json -ErrorAction Stop
    if([IO.Path]::GetExtension($Path) -cne '.json') { throw 'Acceptance evidence must use a .json filename.' }
    $target = [IO.Path]::GetFullPath($Path)
    if(Test-Path -LiteralPath $target) { throw 'Acceptance evidence target already exists.' }
    $directory = Resolve-AmmarTradingLocalPath -Path (Split-Path -Parent $target) -PathType Container -Description 'Acceptance evidence directory'
    $directory = Assert-AmmarTradingAcceptanceFixedLocalPath -Path $directory -Description 'Acceptance evidence directory'
    $trustedRoot = Resolve-AmmarTradingOneDriveRoot -Path $OneDriveRoot
    $trustedRoot = Assert-AmmarTradingAcceptanceFixedLocalPath -Path $trustedRoot -Description 'OneDrive root'
    if(Test-AmmarTradingPathBelow -Path $directory -Root $trustedRoot) { throw 'Acceptance evidence must remain outside OneDrive.' }
    foreach($inputPath in @($InputPaths)) {
        if([string]::IsNullOrWhiteSpace($inputPath)) { continue }
        if($target -ieq [IO.Path]::GetFullPath($inputPath)) { throw 'Acceptance evidence cannot overwrite an input evidence file.' }
    }
    foreach($protectedPath in @($ProtectedPaths)) {
        if([string]::IsNullOrWhiteSpace($protectedPath)) { continue }
        $canonicalProtected = [IO.Path]::GetFullPath($protectedPath)
        $protectedDirectory = if(Test-Path -LiteralPath $canonicalProtected -PathType Container) { $canonicalProtected } else { Split-Path -Parent $canonicalProtected }
        if((Test-AmmarTradingPathBelow -Path $directory -Root $protectedDirectory) -or
           (Test-AmmarTradingPathBelow -Path $protectedDirectory -Root $directory)) {
            throw 'Acceptance evidence directory overlaps protected runtime or source data.'
        }
        if($target -ieq $canonicalProtected) { throw 'Acceptance evidence cannot overwrite protected data.' }
    }
    $temporary = Join-Path $directory (".$([IO.Path]::GetFileName($target)).$([guid]::NewGuid().ToString('N')).tmp")
    $stream = $null
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
        $stream = [IO.FileStream]::new($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
        $stream.Dispose(); $stream=$null
        [IO.File]::Move($temporary,$target)
    } finally {
        if($null -ne $stream) { $stream.Dispose() }
        if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-AmmarTradingVpsAcceptanceEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$VpsName,
        [Parameter(Mandatory)][string[]]$ExpectedAccountNumber,
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    if([string]::IsNullOrWhiteSpace($VpsName)) { throw 'VPS name is required.' }
    $accounts = @(Assert-AmmarTradingExpectedAccounts -ExpectedAccountNumber $ExpectedAccountNumber)
    $canonicalRoot = Resolve-AmmarTradingOneDriveRoot -Path $OneDriveRoot -RequireWritable
    $canonicalRoot = Assert-AmmarTradingAcceptanceFixedLocalPath -Path $canonicalRoot -Description 'OneDrive root'
    if(-not (Test-AmmarTradingAcceptanceOneDriveProcess)) { throw 'The signed-in OneDrive process is not running.' }
    $canonicalConfig = Resolve-AmmarTradingLocalPath -Path $ConfigPath -PathType Leaf -Description 'Account mapping file'
    $mappings = @(Import-Csv -LiteralPath $canonicalConfig -ErrorAction Stop)
    $taskEvidence = Get-AmmarTradingAcceptanceTaskEvidence
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
        $mappingRoot = Resolve-AmmarTradingOneDriveRoot -Path ([string]$mapping.OneDriveRoot)
        if($mappingRoot -ine $canonicalRoot) { throw "The mapping for account $account uses a different OneDrive root." }
        $source = Resolve-AmmarTradingLocalPath -Path ([string]$mapping.SourceCsv) -PathType Leaf -Description 'MT4 source CSV'
        $identity = Get-AmmarTradingCsvIdentity -Path $source
        if($identity.Status -cne 'Ready' -or [string]$identity.SchemaVersion -cne '3' -or [string]$identity.AccountNumber -cne $account -or [string]::IsNullOrWhiteSpace([string]$identity.BrokerName)) { throw "The source identity is not valid schema-v3 data for account $account." }
        $validated = Read-MoneyMachineBasketsCsv -Path $source -ExpectedLogin $account
        if([int]$validated.RowCount -lt 1) { throw "The source CSV contains no validated rows for account $account." }
        $destination = Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $canonicalRoot -Path (Join-Path $canonicalRoot "AmmarTrading\Account_$account\Baskets.csv") -Description 'Published account CSV'
        $destination = Resolve-AmmarTradingLocalPath -Path $destination -PathType Leaf -Description 'Published account CSV'
        [void](Read-MoneyMachineBasketsCsv -Path $destination -ExpectedLogin $account)
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        if($sourceHash -cne $destinationHash) { throw "Source and destination hashes differ for account $account." }
        $heartbeatPath = Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $canonicalRoot -Path (Join-Path (Split-Path -Parent $destination) 'SyncStatus.json') -Description 'Published sync status'
        $heartbeatPath = Resolve-AmmarTradingLocalPath -Path $heartbeatPath -PathType Leaf -Description 'Published sync status'
        $heartbeat = Get-Content -LiteralPath $heartbeatPath -Raw | ConvertFrom-Json
        if([string]$heartbeat.AccountNumber -cne $account -or [string]$heartbeat.Status -cne 'Success') { throw "Sync status is invalid for account $account." }
        if([bool]$heartbeat.CloudDeliveryVerified) { throw 'VPS publication evidence must not claim cloud delivery.' }
        if([string]$heartbeat.SourceHash -cne $sourceHash -or [string]$heartbeat.DestinationHash -cne $destinationHash) { throw "Sync status hashes differ for account $account." }
        $results.Add([pscustomobject][ordered]@{
            AccountNumber=$account
            BrokerName=[string]$identity.BrokerName
            SchemaVersion=3
            SourceHash=$sourceHash
            DestinationHash=$destinationHash
            HeartbeatHash=(Get-FileHash -LiteralPath $heartbeatPath -Algorithm SHA256).Hash.ToLowerInvariant()
            TaskState='Ready'
            CloudDeliveryVerified=$false
        })
    }
    return [pscustomobject][ordered]@{
        SchemaVersion=1
        EvidenceRole='Vps'
        MachineIdentity=Get-AmmarTradingAcceptanceMachineIdentity
        VpsName=$VpsName.Trim()
        CapturedUtc=[DateTime]::UtcNow.ToString('o')
        OneDrive=[pscustomobject][ordered]@{
            TrustedSignedInRoot=$true
            ProcessRunning=$true
            RootIdentity=Get-AmmarTradingAcceptanceRootIdentity -CanonicalRoot $canonicalRoot
        }
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
    $canonicalRoot = Resolve-AmmarTradingOneDriveRoot -Path $OneDriveRoot
    $canonicalRoot = Assert-AmmarTradingAcceptanceFixedLocalPath -Path $canonicalRoot -Description 'OneDrive root'
    if(-not (Test-AmmarTradingAcceptanceOneDriveProcess)) { throw 'The signed-in OneDrive process is not running.' }
    $canonicalVpsEvidence = Resolve-AmmarTradingLocalPath -Path $VpsEvidencePath -PathType Leaf -Description 'VPS acceptance evidence'
    $vpsEvidence = Get-Content -LiteralPath $canonicalVpsEvidence -Raw | ConvertFrom-Json
    if([string]$vpsEvidence.EvidenceRole -cne 'Vps' -or [bool]$vpsEvidence.CloudDeliveryVerified -or [string]$vpsEvidence.OverallStatus -cne 'Pass') {
        throw 'The supplied evidence is not valid VPS-local acceptance evidence.'
    }
    if([string]$vpsEvidence.VpsName -cne $VpsName.Trim()) { throw 'The VPS evidence belongs to a different named VPS.' }
    $machineIdentity = Get-AmmarTradingAcceptanceMachineIdentity
    if([string]$vpsEvidence.MachineIdentity.Scheme -cne 'sha256-domain-separated-machine-guid' -or [int]$vpsEvidence.MachineIdentity.Version -ne 1 -or [string]$vpsEvidence.MachineIdentity.Hash -notmatch '^[0-9a-f]{64}$') { throw 'VPS evidence has an invalid privacy-safe machine identity.' }
    if([string]$vpsEvidence.MachineIdentity.Hash -ceq [string]$machineIdentity.Hash) { throw 'Reporting-PC receipt must be observed on a different Windows machine.' }
    if(-not [bool]$vpsEvidence.OneDrive.TrustedSignedInRoot -or -not [bool]$vpsEvidence.OneDrive.ProcessRunning -or
       [string]$vpsEvidence.OneDrive.RootIdentity.Scheme -cne 'sha256-domain-separated-canonical-root' -or
       [int]$vpsEvidence.OneDrive.RootIdentity.Version -ne 1 -or
       [string]$vpsEvidence.OneDrive.RootIdentity.Hash -notmatch '^[0-9a-f]{64}$') { throw 'VPS evidence has an invalid trusted OneDrive root identity.' }
    $rootIdentity = Get-AmmarTradingAcceptanceRootIdentity -CanonicalRoot $canonicalRoot
    if(@($vpsEvidence.Accounts).Count -ne $accounts.Count) { throw 'VPS evidence account set differs from the expected reporting receipt set.' }
    $results = [Collections.Generic.List[object]]::new()
    foreach($account in $accounts) {
        $matches = @($vpsEvidence.Accounts | Where-Object { [string]$_.AccountNumber -ceq $account })
        if($matches.Count -ne 1) { throw "VPS evidence does not contain exactly one result for account $account." }
        $vpsAccount = $matches | Select-Object -First 1
        if([int]$vpsAccount.SchemaVersion -ne 3 -or [string]::IsNullOrWhiteSpace([string]$vpsAccount.BrokerName) -or
           [string]$vpsAccount.TaskState -cne 'Ready' -or [bool]$vpsAccount.CloudDeliveryVerified -or
           [string]$vpsAccount.SourceHash -notmatch '^[0-9a-f]{64}$' -or
           [string]$vpsAccount.DestinationHash -notmatch '^[0-9a-f]{64}$' -or
           [string]$vpsAccount.HeartbeatHash -notmatch '^[0-9a-f]{64}$') { throw "VPS evidence is incomplete for account $account." }
        $destination = Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $canonicalRoot -Path (Join-Path $canonicalRoot "AmmarTrading\Account_$account\Baskets.csv") -Description 'Reporting account CSV'
        $destination = Resolve-AmmarTradingLocalPath -Path $destination -PathType Leaf -Description 'Reporting account CSV'
        $reportingHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
        $postHashAttributes = Get-AmmarTradingAcceptanceReceiptAttributeValue -Path $destination
        if(($postHashAttributes -band [uint32](4096 -bor 262144 -bor 4194304)) -ne 0) { throw "The reporting-PC file remains offline or recall-only for account $account." }
        if($reportingHash -cne [string]$vpsAccount.DestinationHash) { throw "The reporting-PC hash differs from VPS evidence for account $account." }
        [void](Read-MoneyMachineBasketsCsv -Path $destination -ExpectedLogin $account)
        $results.Add([pscustomobject][ordered]@{
            AccountNumber=$account
            VpsPublishedHash=[string]$vpsAccount.DestinationHash
            ReportingPcHash=$reportingHash
            Length=[int64](Get-Item -LiteralPath $destination -Force).Length
            HydrationState='Hydrated'
            ReceiptObservedUtc=[DateTime]::UtcNow.ToString('o')
            PhysicalReceiptObserved=$true
        })
    }
    return [pscustomobject][ordered]@{
        SchemaVersion=1
        EvidenceRole='ReportingPc'
        MachineIdentity=$machineIdentity
        VpsName=$VpsName.Trim()
        CapturedUtc=[DateTime]::UtcNow.ToString('o')
        OneDrive=[pscustomobject][ordered]@{
            TrustedSignedInRoot=$true
            ProcessRunning=$true
            RootIdentity=$rootIdentity
            ProviderAttestation=$false
        }
        Accounts=@($results.ToArray())
        PhysicalReceiptObserved=$true
        OverallStatus='Pass'
    }
}

if($AsLibrary) { $script:AmmarTradingAcceptanceLibraryMode=$true; return }

if($StagingOnly) { $AcceptanceRole = 'Staging' }
if($AcceptanceRole -in @('Vps','ReportingPc')) {
    if([string]::IsNullOrWhiteSpace($VpsName) -or $null -eq $ExpectedAccountNumber -or
       [string]::IsNullOrWhiteSpace($OneDriveRoot) -or [string]::IsNullOrWhiteSpace($EvidenceOutputPath)) {
        throw 'VPS name, expected account numbers, OneDrive root, and evidence output path are required for end-to-end acceptance.'
    }
    $protectedPaths = @()
    $inputPaths = @()
    $evidence = if($AcceptanceRole -ceq 'Vps') {
        if([string]::IsNullOrWhiteSpace($ConfigPath)) { throw 'The mapping configuration path is required for VPS acceptance.' }
        $safeConfigPath = Resolve-AmmarTradingLocalPath -Path $ConfigPath -PathType Leaf -Description 'Account mapping file'
        $protectedPaths = @($safeConfigPath) + @(Import-Csv -LiteralPath $safeConfigPath -ErrorAction Stop | ForEach-Object { [string]$_.SourceCsv })
        Get-AmmarTradingVpsAcceptanceEvidence -VpsName $VpsName -ExpectedAccountNumber $ExpectedAccountNumber -OneDriveRoot $OneDriveRoot -ConfigPath $safeConfigPath
    } else {
        if([string]::IsNullOrWhiteSpace($VpsEvidencePath)) { throw 'The separate VPS evidence path is required for reporting-PC acceptance.' }
        $inputPaths = @($VpsEvidencePath)
        Get-AmmarTradingReportingAcceptanceEvidence -VpsName $VpsName -ExpectedAccountNumber $ExpectedAccountNumber -OneDriveRoot $OneDriveRoot -VpsEvidencePath $VpsEvidencePath
    }
    $sensitive = @($OneDriveRoot,$ConfigPath,$EvidenceOutputPath,$VpsEvidencePath)
    Write-NewAmmarTradingAcceptanceEvidence -Path $EvidenceOutputPath -Json (ConvertTo-RedactedAcceptanceJson -Report $evidence -SensitiveValues $sensitive) -OneDriveRoot $OneDriveRoot -ProtectedPaths $protectedPaths -InputPaths $inputPaths
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
