Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AmmarTradingDriveTypeResolver = {
    param([Parameter(Mandatory)][string]$VolumeRoot)
    return (New-Object IO.DriveInfo($VolumeRoot)).DriveType
}

function Test-AmmarTradingUncPath {
    param([Parameter(Mandatory)][string]$Path)
    return $Path -match '^(?:[^:]+::)?[\\/]{2}'
}

function Resolve-AmmarTradingLocalPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Leaf','Container')][string]$PathType,
        [Parameter(Mandatory)][string]$Description
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if([string]::IsNullOrWhiteSpace($expanded)) { throw "$Description is required." }
    if(Test-AmmarTradingUncPath -Path $expanded) { throw "$Description must use a local filesystem path; UNC paths are not allowed." }
    if(-not (Test-Path -LiteralPath $expanded -PathType $PathType)) { throw "$Description was not found: $expanded" }

    $resolved = Resolve-Path -LiteralPath $expanded -ErrorAction Stop
    if($resolved.Provider.Name -cne 'FileSystem') { throw "$Description must use a local filesystem path." }
    $providerPath = [string]$resolved.ProviderPath
    if(Test-AmmarTradingUncPath -Path $providerPath) { throw "$Description must use a local filesystem path; UNC paths are not allowed." }

    $drive = $resolved.Drive
    if($null -eq $drive) { throw "$Description must use a local filesystem volume." }
    $displayRoot = if($drive.PSObject.Properties['DisplayRoot']) { [string]$drive.DisplayRoot } else { '' }
    if(-not [string]::IsNullOrWhiteSpace($displayRoot) -and (Test-AmmarTradingUncPath -Path $displayRoot)) {
        throw "$Description must use a local filesystem volume; mapped network drives are not allowed."
    }

    $volumeRoot = [IO.Path]::GetPathRoot($providerPath)
    if([string]::IsNullOrWhiteSpace($volumeRoot)) { throw "$Description must use a local filesystem volume." }
    try {
        $driveType = & $script:AmmarTradingDriveTypeResolver $volumeRoot
    } catch {
        throw "$Description local filesystem volume could not be verified."
    }
    if([IO.DriveType]$driveType -eq [IO.DriveType]::Network) {
        throw "$Description must use a local filesystem volume; mapped network drives are not allowed."
    }

    return [IO.Path]::GetFullPath($providerPath)
}

function Get-AmmarTradingDestinationPath {
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$AccountNumber
    )

    Join-Path $OneDriveRoot (Join-Path 'AmmarTrading' (Join-Path ("Account_{0}" -f $AccountNumber) 'Baskets.csv'))
}

function Get-AmmarTradingDiscoveryHash {
    param([Parameter(Mandatory)][string]$Fingerprint)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Fingerprint)
        $hash = $sha256.ComputeHash($bytes)
        return [BitConverter]::ToString($hash).Replace('-', '')
    } finally {
        $sha256.Dispose()
    }
}

function Get-AmmarTradingMt4Accounts {
    [CmdletBinding()]
    param(
        [string]$TerminalDataRoot,
        [AllowEmptyCollection()][string[]]$ManualCsv
    )

    if([string]::IsNullOrWhiteSpace($TerminalDataRoot)) {
        $TerminalDataRoot = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
    }

    $schemaModule = Join-Path $PSScriptRoot 'MoneyMachineCsvSchemaV3.psm1'
    if(-not (Test-Path -LiteralPath $schemaModule -PathType Leaf)) { throw "Schema validator was not found: $schemaModule" }
    Import-Module -Name $schemaModule -ErrorAction Stop

    $candidates = [System.Collections.Generic.List[object]]::new()
    $seenPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    $resolvedTerminalRoot = $null
    if(-not [string]::IsNullOrWhiteSpace($TerminalDataRoot)) {
        try { $resolvedTerminalRoot = Resolve-AmmarTradingLocalPath -Path $TerminalDataRoot -PathType Container -Description 'MT4 terminal data root' } catch { $resolvedTerminalRoot = $null }
    }
    if($null -ne $resolvedTerminalRoot) {
        foreach($terminal in @(Get-ChildItem -LiteralPath $resolvedTerminalRoot -Directory -ErrorAction SilentlyContinue | Sort-Object FullName)) {
            $csv = Join-Path $terminal.FullName 'MQL4\Files\AGOLD___Baskets.csv'
            try { $resolvedCsv = Resolve-AmmarTradingLocalPath -Path $csv -PathType Leaf -Description 'MT4 source CSV' } catch { continue }

            $terminalName = $terminal.Name
            $origin = Join-Path $terminal.FullName 'origin.txt'
            if(Test-Path -LiteralPath $origin -PathType Leaf) {
                try {
                    $originValue = ([string](Get-Content -LiteralPath $origin -Raw -ErrorAction Stop)).Trim()
                    if(-not [string]::IsNullOrWhiteSpace($originValue)) { $terminalName = $originValue }
                } catch {
                    $terminalName = $terminal.Name
                }
            }

            if($seenPaths.Add($resolvedCsv)) {
                $candidates.Add([pscustomobject]@{
                    SourceCsv = $resolvedCsv
                    TerminalId = $terminal.Name
                    TerminalName = $terminalName
                })
            }
        }
    }

    foreach($manualPath in @($ManualCsv)) {
        if([string]::IsNullOrWhiteSpace([string]$manualPath)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables(([string]$manualPath).Trim())
        if([IO.Path]::GetExtension($expanded) -ine '.csv') { continue }
        try { $resolvedCsv = Resolve-AmmarTradingLocalPath -Path $expanded -PathType Leaf -Description 'Manual source CSV' } catch { continue }
        if($seenPaths.Add($resolvedCsv)) {
            $candidates.Add([pscustomobject]@{
                SourceCsv = $resolvedCsv
                TerminalId = 'Manual'
                TerminalName = 'Manual CSV'
            })
        }
    }

    $results = [System.Collections.Generic.List[object]]::new()
    foreach($candidate in @($candidates | Sort-Object SourceCsv)) {
        $file = Get-Item -LiteralPath $candidate.SourceCsv -ErrorAction Stop
        $identity = Get-AmmarTradingCsvIdentity -Path $file.FullName
        $fingerprint = '{0}|{1}|{2}|{3}' -f $file.FullName,$identity.AccountNumber,$file.Length,$file.LastWriteTimeUtc.Ticks
        $discoveryId = Get-AmmarTradingDiscoveryHash -Fingerprint $fingerprint

        $freshness = 'Unknown'
        if($file.LastWriteTimeUtc -ne [DateTime]::MinValue) {
            $age = [DateTime]::UtcNow - $file.LastWriteTimeUtc
            $freshness = if($age.TotalMinutes -le 15) { 'Fresh' } else { 'Stale' }
        }

        $eligibility = if($identity.Status -ceq 'Ready') { 'Ready' } else { 'Blocked' }
        $results.Add([pscustomobject][ordered]@{
            DiscoveryId = $discoveryId
            AccountNumber = $identity.AccountNumber
            BrokerName = $identity.BrokerName
            TerminalId = $candidate.TerminalId
            TerminalName = $candidate.TerminalName
            SourceCsv = $file.FullName
            SchemaVersion = $identity.SchemaVersion
            LastWriteUtc = $file.LastWriteTimeUtc.ToString('o')
            Freshness = $freshness
            Eligibility = $eligibility
            ReasonCode = $identity.Status
        })
    }

    foreach($duplicateGroup in @($results | Where-Object Eligibility -eq 'Ready' | Group-Object AccountNumber | Where-Object Count -gt 1)) {
        foreach($duplicate in @($duplicateGroup.Group)) {
            $duplicate.Eligibility = 'Blocked'
            $duplicate.ReasonCode = 'DuplicateAccount'
        }
    }

    return @($results)
}

function Get-MoneyMachineSetupDiscovery {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$OneDriveCandidates,
        [string]$TerminalDataRoot
    )

    if($null -eq $OneDriveCandidates) {
        $OneDriveCandidates = @($env:OneDrive,$env:OneDriveCommercial,$env:OneDriveConsumer)
    }
    if([string]::IsNullOrWhiteSpace($TerminalDataRoot)) {
        $TerminalDataRoot = Join-Path $env:APPDATA 'MetaQuotes\Terminal'
    }

    $seenRoots = @{}
    $roots = [System.Collections.Generic.List[object]]::new()
    foreach($candidate in @($OneDriveCandidates)) {
        if([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        $expanded = [Environment]::ExpandEnvironmentVariables(([string]$candidate).Trim())
        if(-not (Test-Path -LiteralPath $expanded -PathType Container)) { continue }
        $resolved = (Resolve-Path -LiteralPath $expanded).Path
        $key = $resolved.ToLowerInvariant()
        if($seenRoots.ContainsKey($key)) { continue }
        $seenRoots[$key] = $true
        $roots.Add([pscustomobject]@{
            Path = $resolved
            Name = Split-Path -Leaf $resolved
        })
    }

    $sources = [System.Collections.Generic.List[object]]::new()
    $resolvedTerminalRoot = $null
    if(-not [string]::IsNullOrWhiteSpace($TerminalDataRoot)) {
        try { $resolvedTerminalRoot = Resolve-AmmarTradingLocalPath -Path $TerminalDataRoot -PathType Container -Description 'MT4 terminal data root' } catch { $resolvedTerminalRoot = $null }
    }
    if($null -ne $resolvedTerminalRoot) {
        foreach($terminalDirectory in @(Get-ChildItem -LiteralPath $resolvedTerminalRoot -Directory -ErrorAction SilentlyContinue)) {
            $sourcePath = Join-Path $terminalDirectory.FullName 'MQL4\Files\AGOLD___Baskets.csv'
            try { $resolvedSourcePath = Resolve-AmmarTradingLocalPath -Path $sourcePath -PathType Leaf -Description 'MT4 source CSV' } catch { continue }
            $file = Get-Item -LiteralPath $resolvedSourcePath -ErrorAction Stop
            $sources.Add([pscustomobject]@{
                Path = $file.FullName
                TerminalId = $terminalDirectory.Name
                LastWriteUtc = $file.LastWriteTimeUtc.ToString('o')
            })
        }
    }

    return [pscustomobject]@{
        OneDriveRoots = @($roots)
        Sources = @($sources | Sort-Object LastWriteUtc -Descending)
    }
}

function Test-MoneyMachineSetupRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$VpsName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedMT4Login,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SourceCsv,
        [Parameter(Mandatory)][AllowEmptyString()][string]$OneDriveRoot
    )

    $normalizedName = $VpsName.Trim()
    if([string]::IsNullOrWhiteSpace($normalizedName)) { throw 'VPS name is required.' }
    if($normalizedName.Length -gt 100) { throw 'VPS name must be 100 characters or fewer.' }

    $normalizedLogin = $ExpectedMT4Login.Trim()
    if($normalizedLogin -notmatch '^\d{4,20}$') { throw 'MT4 account number must contain 4 to 20 digits.' }

    $expandedSource = [Environment]::ExpandEnvironmentVariables($SourceCsv.Trim())
    if([IO.Path]::GetExtension($expandedSource) -ine '.csv') { throw 'Source file must use the .csv extension.' }
    $resolvedSource = Resolve-AmmarTradingLocalPath -Path $expandedSource -PathType Leaf -Description 'Source CSV'

    $expandedOneDrive = [Environment]::ExpandEnvironmentVariables($OneDriveRoot.Trim())
    if(-not (Test-Path -LiteralPath $expandedOneDrive -PathType Container)) { throw "OneDrive root was not found: $expandedOneDrive" }
    $resolvedOneDrive = (Resolve-Path -LiteralPath $expandedOneDrive).Path

    $schemaModule = Join-Path $PSScriptRoot 'MoneyMachineCsvSchemaV3.psm1'
    if(-not (Test-Path -LiteralPath $schemaModule -PathType Leaf)) { throw "Schema validator was not found: $schemaModule" }
    Import-Module -Name $schemaModule -Force -ErrorAction Stop
    $validation = Read-MoneyMachineBasketsCsv -Path $resolvedSource -ExpectedLogin $normalizedLogin

    return [pscustomobject]@{
        VpsName = $normalizedName
        ExpectedMT4Login = $normalizedLogin
        SourceCsv = $resolvedSource
        OneDriveRoot = $resolvedOneDrive
        RowCount = [int]$validation.RowCount
    }
}

function Save-AmmarTradingAccountBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][object[]]$Accounts
    )

    $fullConfigPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    if(@($Accounts).Count -eq 0) { throw 'At least one account configuration is required.' }

    $selectedByLogin = @{}
    $selectedOrder = [System.Collections.Generic.List[string]]::new()
    foreach($account in @($Accounts)) {
        $newLogin = ([string]$account.ExpectedMT4Login).Trim()
        if($newLogin -notmatch '^\d{4,20}$') { throw 'Account configuration requires a valid MT4 account number.' }
        if($selectedByLogin.ContainsKey($newLogin)) { throw "Account configuration contains duplicate MT4 account '$newLogin'." }
        $selectedByLogin[$newLogin] = [pscustomobject][ordered]@{
            Enabled = 'true'
            VpsName = ([string]$account.VpsName).Trim()
            ExpectedMT4Login = $newLogin
            SourceCsv = [string]$account.SourceCsv
            OneDriveRoot = [string]$account.OneDriveRoot
        }
        $selectedOrder.Add($newLogin)
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $emitted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    if(Test-Path -LiteralPath $fullConfigPath -PathType Leaf) {
        foreach($existing in @(Import-Csv -LiteralPath $fullConfigPath -ErrorAction Stop)) {
            $existingLogin = ([string]$existing.ExpectedMT4Login).Trim()
            if($selectedByLogin.ContainsKey($existingLogin)) {
                if($emitted.Add($existingLogin)) { $rows.Add($selectedByLogin[$existingLogin]) }
            } else {
                $existingName = if($existing.PSObject.Properties['VpsName']) { [string]$existing.VpsName } else { '' }
                $rows.Add([pscustomobject][ordered]@{
                    Enabled = [string]$existing.Enabled
                    VpsName = $existingName
                    ExpectedMT4Login = $existingLogin
                    SourceCsv = [string]$existing.SourceCsv
                    OneDriveRoot = [string]$existing.OneDriveRoot
                })
            }
        }
    }
    foreach($newLogin in $selectedOrder) {
        if($emitted.Add($newLogin)) { $rows.Add($selectedByLogin[$newLogin]) }
    }

    $configDirectory = Split-Path -Parent $fullConfigPath
    if(-not (Test-Path -LiteralPath $configDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    }
    $lines = @($rows | ConvertTo-Csv -NoTypeInformation)
    $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    $temporary = Join-Path $configDirectory ("accounts.$([guid]::NewGuid().ToString('N')).tmp")
    $backupPath = $null
    $configExisted = Test-Path -LiteralPath $fullConfigPath -PathType Leaf
    try {
        [IO.File]::WriteAllText($temporary, $content, (New-Object Text.UTF8Encoding($false)))
        if($configExisted) {
            $currentHash = (Get-FileHash -LiteralPath $fullConfigPath -Algorithm SHA256).Hash
            $nextHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
            if($currentHash -ceq $nextHash) {
                return [pscustomobject]@{ ConfigPath=$fullConfigPath; BackupPath=$null; Changed=$false; ConfigExisted=$true }
            }
            $backupPath = "$fullConfigPath.$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')).bak"
            [IO.File]::Replace($temporary, $fullConfigPath, $backupPath, $true)
        } else {
            [IO.File]::Move($temporary, $fullConfigPath)
        }
    } finally {
        if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }

    return [pscustomobject]@{ ConfigPath=$fullConfigPath; BackupPath=$backupPath; Changed=$true; ConfigExisted=$configExisted }
}

function Save-MoneyMachineAccountConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][psobject]$Account
    )

    return (Save-AmmarTradingAccountBatch -ConfigPath $ConfigPath -Accounts @($Account))
}

function Test-AmmarTradingReparsePoint {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
}

function Assert-AmmarTradingMigrationPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description
    )

    if(Test-AmmarTradingReparsePoint -Path $Path) { throw "$Description contains a reparse point: $Path" }
}

function Copy-AmmarTradingLegacyData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string[]]$AccountNumbers
    )

    $resolvedRoot = (Resolve-Path -LiteralPath ([Environment]::ExpandEnvironmentVariables($OneDriveRoot.Trim())) -ErrorAction Stop).Path
    Assert-AmmarTradingMigrationPath -Path $resolvedRoot -Description 'OneDrive migration root'

    $accounts = [System.Collections.Generic.List[string]]::new()
    $seenAccounts = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach($accountNumberValue in @($AccountNumbers)) {
        $accountNumber = ([string]$accountNumberValue).Trim()
        if($accountNumber -notmatch '^\d{4,20}$') { throw 'Legacy migration requires valid MT4 account numbers.' }
        if($seenAccounts.Add($accountNumber)) { $accounts.Add($accountNumber) }
    }

    $canonicalRoot = Join-Path $resolvedRoot 'AmmarTrading'
    if(Test-Path -LiteralPath $canonicalRoot) { Assert-AmmarTradingMigrationPath -Path $canonicalRoot -Description 'Canonical migration root' }

    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach($legacyName in @('Money Machine','AmarTrading')) {
        $legacyRoot = Join-Path $resolvedRoot $legacyName
        if(-not (Test-Path -LiteralPath $legacyRoot -PathType Container)) { continue }
        Assert-AmmarTradingMigrationPath -Path $legacyRoot -Description "Legacy '$legacyName' root"
        foreach($accountNumber in $accounts) {
            $sourceAccount = Join-Path $legacyRoot ("Account_{0}" -f $accountNumber)
            if(-not (Test-Path -LiteralPath $sourceAccount -PathType Container)) { continue }
            Assert-AmmarTradingMigrationPath -Path $sourceAccount -Description "Legacy account '$accountNumber' folder"
            $sourcePrefix = $sourceAccount.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            $items = @(Get-ChildItem -LiteralPath $sourceAccount -Recurse -Force -ErrorAction Stop)
            foreach($item in $items) {
                if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "Legacy account '$accountNumber' data contains a reparse point: $($item.FullName)"
                }
                if($item.PSIsContainer) { continue }
                if(-not $item.FullName.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Legacy migration candidate escaped account folder '$sourceAccount'."
                }
                $relativePath = $item.FullName.Substring($sourcePrefix.Length)
                $destination = Join-Path (Join-Path $canonicalRoot ("Account_{0}" -f $accountNumber)) $relativePath
                $candidates.Add([pscustomobject]@{ Source=$item.FullName; Destination=$destination })
            }
        }
    }

    $copied = 0
    $alreadyPresent = 0
    $conflict = 0
    foreach($candidate in $candidates) {
        $destinationDirectory = Split-Path -Parent $candidate.Destination
        $rootPrefix = $resolvedRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if(-not $destinationDirectory.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Legacy migration destination escaped OneDrive root '$resolvedRoot'."
        }

        $relativeDirectory = $destinationDirectory.Substring($rootPrefix.Length)
        $currentDirectory = $resolvedRoot
        foreach($part in @($relativeDirectory -split '[\\/]')) {
            if([string]::IsNullOrWhiteSpace($part)) { continue }
            $currentDirectory = Join-Path $currentDirectory $part
            if(Test-Path -LiteralPath $currentDirectory) {
                Assert-AmmarTradingMigrationPath -Path $currentDirectory -Description 'Legacy migration destination'
            } else {
                New-Item -ItemType Directory -Path $currentDirectory -Force | Out-Null
                Assert-AmmarTradingMigrationPath -Path $currentDirectory -Description 'Legacy migration destination'
            }
        }

        $sourceItem = Get-Item -LiteralPath $candidate.Source -Force -ErrorAction Stop
        $sourceHash = (Get-FileHash -LiteralPath $candidate.Source -Algorithm SHA256).Hash
        if(Test-Path -LiteralPath $candidate.Destination) {
            Assert-AmmarTradingMigrationPath -Path $candidate.Destination -Description 'Legacy migration destination file'
            $destinationItem = Get-Item -LiteralPath $candidate.Destination -Force -ErrorAction Stop
            $destinationHash = (Get-FileHash -LiteralPath $candidate.Destination -Algorithm SHA256).Hash
            if($sourceItem.Length -eq $destinationItem.Length -and $sourceHash -ceq $destinationHash) { $alreadyPresent++ } else { $conflict++ }
            continue
        }

        $temporary = Join-Path $destinationDirectory ("$([IO.Path]::GetFileName($candidate.Destination)).$([guid]::NewGuid().ToString('N')).migration.tmp")
        try {
            [IO.File]::Copy($candidate.Source, $temporary, $false)
            $temporaryItem = Get-Item -LiteralPath $temporary -Force -ErrorAction Stop
            $temporaryHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
            if($temporaryItem.Length -ne $sourceItem.Length -or $temporaryHash -cne $sourceHash) { throw "Legacy migration verification failed for '$($candidate.Source)'." }
            try {
                [IO.File]::Move($temporary, $candidate.Destination)
            } catch [IO.IOException] {
                if(-not (Test-Path -LiteralPath $candidate.Destination -PathType Leaf)) { throw }
                $destinationItem = Get-Item -LiteralPath $candidate.Destination -Force -ErrorAction Stop
                $destinationHash = (Get-FileHash -LiteralPath $candidate.Destination -Algorithm SHA256).Hash
                if($sourceItem.Length -eq $destinationItem.Length -and $sourceHash -ceq $destinationHash) { $alreadyPresent++ } else { $conflict++ }
                continue
            }
            $destinationItem = Get-Item -LiteralPath $candidate.Destination -Force -ErrorAction Stop
            $destinationHash = (Get-FileHash -LiteralPath $candidate.Destination -Algorithm SHA256).Hash
            if($destinationItem.Length -ne $sourceItem.Length -or $destinationHash -cne $sourceHash) { throw "Legacy migration destination verification failed for '$($candidate.Destination)'." }
            $copied++
        } finally {
            if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        }
    }

    return [pscustomobject][ordered]@{ Copied=$copied; AlreadyPresent=$alreadyPresent; Conflict=$conflict }
}

function Invoke-AmmarTradingBatchSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Request,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$RuntimeRoot = $PSScriptRoot,
        [switch]$SkipTaskRegistration,
        [int]$StableCheckSeconds = 2,
        [int]$MutexWaitMilliseconds = 30000
    )

    $stages = [System.Collections.Generic.List[object]]::new()
    $vpsName = ([string]$Request.VpsName).Trim()
    if([string]::IsNullOrWhiteSpace($vpsName)) { throw 'VPS name is required.' }
    if($vpsName.Length -gt 100) { throw 'VPS name must be 100 characters or fewer.' }
    $oneDriveValue = [Environment]::ExpandEnvironmentVariables(([string]$Request.OneDriveRoot).Trim())
    if(-not (Test-Path -LiteralPath $oneDriveValue -PathType Container)) { throw "OneDrive root was not found: $oneDriveValue" }
    $oneDriveRoot = (Resolve-Path -LiteralPath $oneDriveValue -ErrorAction Stop).Path
    $requestedAccounts = @($Request.Accounts)
    if($requestedAccounts.Count -eq 0) { throw 'At least one MT4 account must be selected.' }

    $schemaModule = Join-Path $PSScriptRoot 'MoneyMachineCsvSchemaV3.psm1'
    if(-not (Test-Path -LiteralPath $schemaModule -PathType Leaf)) { throw "Schema validator was not found: $schemaModule" }
    Import-Module -Name $schemaModule -Force -ErrorAction Stop

    $seenLogins = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenDiscoveries = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $seenSources = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $normalizedAccounts = [System.Collections.Generic.List[object]]::new()
    foreach($requested in $requestedAccounts) {
        $expectedLogin = ([string]$requested.ExpectedMT4Login).Trim()
        if($expectedLogin -notmatch '^\d{4,20}$') { throw 'MT4 account number must contain 4 to 20 digits.' }
        $discoveryId = ([string]$requested.DiscoveryId).Trim()
        if($discoveryId -cnotmatch '^[A-F0-9]{64}$') { throw "Account '$expectedLogin' requires a valid discovery identity." }
        if(-not $seenLogins.Add($expectedLogin)) { throw "The batch request contains duplicate MT4 account '$expectedLogin'." }
        if(-not $seenDiscoveries.Add($discoveryId)) { throw "The batch request contains duplicate discovery identity '$discoveryId'." }

        $sourceValue = [Environment]::ExpandEnvironmentVariables(([string]$requested.SourceCsv).Trim())
        if([IO.Path]::GetExtension($sourceValue) -ine '.csv') { throw 'Source file must use the .csv extension.' }
        $sourceCsv = Resolve-AmmarTradingLocalPath -Path $sourceValue -PathType Leaf -Description 'Source CSV'
        if(-not $seenSources.Add($sourceCsv)) { throw "The batch request contains duplicate source CSV '$sourceCsv'." }

        $validation = Read-MoneyMachineBasketsCsv -Path $sourceCsv -ExpectedLogin $expectedLogin
        $identity = Get-AmmarTradingCsvIdentity -Path $sourceCsv
        if($identity.Status -cne 'Ready' -or $identity.AccountNumber -cne $expectedLogin) { throw "Account '$expectedLogin' source is not a ready schema-v3 CSV." }
        $file = Get-Item -LiteralPath $sourceCsv -Force -ErrorAction Stop
        $fingerprint = '{0}|{1}|{2}|{3}' -f $file.FullName,$expectedLogin,$file.Length,$file.LastWriteTimeUtc.Ticks
        $currentDiscoveryId = Get-AmmarTradingDiscoveryHash -Fingerprint $fingerprint
        if($currentDiscoveryId -cne $discoveryId) { throw "Account '$expectedLogin' discovery identity is stale; refresh account discovery before setup." }

        $normalizedAccounts.Add([pscustomobject]@{
            VpsName = $vpsName
            ExpectedMT4Login = $expectedLogin
            SourceCsv = $file.FullName
            OneDriveRoot = $oneDriveRoot
            RowCount = [int]$validation.RowCount
            BrokerName = [string]$identity.BrokerName
            DiscoveryId = $discoveryId
        })
    }
    $stages.Add([pscustomobject]@{ Code='Validated'; Status='Success'; Message="Validated $($normalizedAccounts.Count) selected MT4 account source(s) before writing setup data." })

    $migration = Copy-AmmarTradingLegacyData -OneDriveRoot $oneDriveRoot -AccountNumbers @($normalizedAccounts | ForEach-Object ExpectedMT4Login)
    if($migration.Conflict -gt 0) { throw "Legacy data migration found $($migration.Conflict) conflicting destination file(s); no configuration was changed." }
    $stages.Add([pscustomobject]@{ Code='LegacyMigrated'; Status='Success'; Message="Legacy migration copied $($migration.Copied) file(s); $($migration.AlreadyPresent) were already present." })

    $fullConfigPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    $saved = $null
    $allPublished = $false
    $restored = $false
    try {
        $saved = Save-AmmarTradingAccountBatch -ConfigPath $fullConfigPath -Accounts @($normalizedAccounts)
        $stages.Add([pscustomobject]@{ Code='Configured'; Status='Success'; Message='Selected account configurations were saved in one atomic batch.' })

        $syncScript = Join-Path $PSScriptRoot 'Sync-BasketsToOneDrive.ps1'
        if(-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) { throw "Sync script was not found: $syncScript" }
        . $syncScript -AsLibrary
        $selectedLogins = @($normalizedAccounts | ForEach-Object ExpectedMT4Login)
        $syncResults = @(Invoke-MoneyMachineCsvSync -ConfigPath $fullConfigPath -AccountNumbers $selectedLogins -StableCheckSeconds $StableCheckSeconds -MaxRetries 1 -MutexWaitMilliseconds $MutexWaitMilliseconds -RuntimeRoot $RuntimeRoot)
        $failed = @($syncResults | Where-Object Status -eq 'Error')
        if($failed.Count -gt 0) { throw (($failed | ForEach-Object { "Account $($_.AccountNumber): $($_.Message)" }) -join '; ') }
        foreach($account in $normalizedAccounts) {
            $expectedResult = @($syncResults | Where-Object AccountNumber -eq $account.ExpectedMT4Login | Select-Object -First 1)
            if($expectedResult.Count -ne 1 -or $expectedResult[0].Status -ne 'Success') { throw "Account '$($account.ExpectedMT4Login)' did not complete its first local publication." }
        }

        $allPublished = $true
        $stages.Add([pscustomobject]@{ Code='LocalPublished'; Status='Success'; Message="Published the first local CSV snapshot for $($normalizedAccounts.Count) selected account(s)." })

        if($SkipTaskRegistration) {
            $stages.Add([pscustomobject]@{ Code='TaskRegistrationSkipped'; Status='Success'; Message='Scheduled-task registration was skipped for staging acceptance.' })
            $taskState = 'RegistrationSkipped'
        } else {
            $installer = Join-Path $PSScriptRoot 'Install-BasketsSyncTask.ps1'
            if(-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Scheduled-task installer was not found: $installer" }
            & $installer -ConfigPath $fullConfigPath
            $stages.Add([pscustomobject]@{ Code='Automated'; Status='Success'; Message='Daily and logon catch-up synchronization tasks are active.' })
            $taskState = 'Registered'
        }

        $accountResults = [System.Collections.Generic.List[object]]::new()
        foreach($account in $normalizedAccounts) {
            $accountResults.Add([pscustomobject][ordered]@{
                AccountNumber = $account.ExpectedMT4Login
                BrokerName = $account.BrokerName
                Destination = Get-AmmarTradingDestinationPath -OneDriveRoot $account.OneDriveRoot -AccountNumber $account.ExpectedMT4Login
                LocalPublished = $true
                TaskState = $taskState
            })
        }
        return [pscustomobject]@{
            Status = 'Success'
            Accounts = @($accountResults)
            Stages = @($stages)
            CloudDeliveryVerified = $false
        }
    } catch {
        if(-not $allPublished -and -not $restored -and $null -ne $saved -and $saved.Changed) {
            $restored = $true
            if($saved.ConfigExisted -and -not [string]::IsNullOrWhiteSpace([string]$saved.BackupPath) -and (Test-Path -LiteralPath $saved.BackupPath -PathType Leaf)) {
                Copy-Item -LiteralPath $saved.BackupPath -Destination $fullConfigPath -Force
            } elseif(-not $saved.ConfigExisted -and (Test-Path -LiteralPath $fullConfigPath -PathType Leaf)) {
                Remove-Item -LiteralPath $fullConfigPath -Force
            }
        }
        throw
    }
}

function Invoke-MoneyMachineSetup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][psobject]$Request,
        [Parameter(Mandatory)][string]$ConfigPath,
        [string]$RuntimeRoot = $PSScriptRoot,
        [switch]$SkipTaskRegistration,
        [int]$StableCheckSeconds = 2,
        [int]$MutexWaitMilliseconds = 30000
    )

    $normalized = Test-MoneyMachineSetupRequest -VpsName ([string]$Request.VpsName) -ExpectedMT4Login ([string]$Request.ExpectedMT4Login) -SourceCsv ([string]$Request.SourceCsv) -OneDriveRoot ([string]$Request.OneDriveRoot)
    $file = Get-Item -LiteralPath $normalized.SourceCsv -Force -ErrorAction Stop
    $fingerprint = '{0}|{1}|{2}|{3}' -f $file.FullName,$normalized.ExpectedMT4Login,$file.Length,$file.LastWriteTimeUtc.Ticks
    $batchRequest = [pscustomobject]@{
        VpsName = $normalized.VpsName
        OneDriveRoot = $normalized.OneDriveRoot
        Accounts = @([pscustomobject]@{
            DiscoveryId = Get-AmmarTradingDiscoveryHash -Fingerprint $fingerprint
            ExpectedMT4Login = $normalized.ExpectedMT4Login
            SourceCsv = $normalized.SourceCsv
        })
    }
    $batchResult = Invoke-AmmarTradingBatchSetup -Request $batchRequest -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot -SkipTaskRegistration:$SkipTaskRegistration -StableCheckSeconds $StableCheckSeconds -MutexWaitMilliseconds $MutexWaitMilliseconds
    return [pscustomobject]@{
        Status = $batchResult.Status
        Account = $normalized
        Destination = $batchResult.Accounts[0].Destination
        CloudDeliveryVerified = $batchResult.CloudDeliveryVerified
        Stages = @($batchResult.Stages)
    }
}

Export-ModuleMember -Function Get-AmmarTradingMt4Accounts,Get-MoneyMachineSetupDiscovery,Test-MoneyMachineSetupRequest,Save-MoneyMachineAccountConfig,Save-AmmarTradingAccountBatch,Copy-AmmarTradingLegacyData,Invoke-AmmarTradingBatchSetup,Invoke-MoneyMachineSetup
