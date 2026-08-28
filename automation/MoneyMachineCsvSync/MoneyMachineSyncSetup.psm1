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

function Save-MoneyMachineAccountConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][psobject]$Account
    )

    $fullConfigPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    $configDirectory = Split-Path -Parent $fullConfigPath
    if(-not (Test-Path -LiteralPath $configDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
    }

    $newLogin = ([string]$Account.ExpectedMT4Login).Trim()
    if($newLogin -notmatch '^\d{4,20}$') { throw 'Account configuration requires a valid MT4 account number.' }

    $rows = [System.Collections.Generic.List[object]]::new()
    $replaced = $false
    if(Test-Path -LiteralPath $fullConfigPath -PathType Leaf) {
        foreach($existing in @(Import-Csv -LiteralPath $fullConfigPath -ErrorAction Stop)) {
            $existingLogin = ([string]$existing.ExpectedMT4Login).Trim()
            if($existingLogin -ceq $newLogin) {
                $rows.Add([pscustomobject][ordered]@{
                    Enabled = 'true'
                    VpsName = ([string]$Account.VpsName).Trim()
                    ExpectedMT4Login = $newLogin
                    SourceCsv = [string]$Account.SourceCsv
                    OneDriveRoot = [string]$Account.OneDriveRoot
                })
                $replaced = $true
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
    if(-not $replaced) {
        $rows.Add([pscustomobject][ordered]@{
            Enabled = 'true'
            VpsName = ([string]$Account.VpsName).Trim()
            ExpectedMT4Login = $newLogin
            SourceCsv = [string]$Account.SourceCsv
            OneDriveRoot = [string]$Account.OneDriveRoot
        })
    }

    $lines = @($rows | ConvertTo-Csv -NoTypeInformation)
    $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    $temporary = Join-Path $configDirectory ("accounts.$([guid]::NewGuid().ToString('N')).tmp")
    $backupPath = $null
    try {
        [IO.File]::WriteAllText($temporary, $content, (New-Object Text.UTF8Encoding($false)))
        if(Test-Path -LiteralPath $fullConfigPath -PathType Leaf) {
            $currentHash = (Get-FileHash -LiteralPath $fullConfigPath -Algorithm SHA256).Hash
            $nextHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
            if($currentHash -ceq $nextHash) {
                return [pscustomobject]@{ ConfigPath=$fullConfigPath; BackupPath=$null; Changed=$false }
            }
            $backupPath = "$fullConfigPath.$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')).bak"
            [IO.File]::Replace($temporary, $fullConfigPath, $backupPath, $true)
        } else {
            [IO.File]::Move($temporary, $fullConfigPath)
        }
    } finally {
        if(Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }

    return [pscustomobject]@{ ConfigPath=$fullConfigPath; BackupPath=$backupPath; Changed=$true }
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

    $stages = [System.Collections.Generic.List[object]]::new()
    $normalized = Test-MoneyMachineSetupRequest -VpsName ([string]$Request.VpsName) -ExpectedMT4Login ([string]$Request.ExpectedMT4Login) -SourceCsv ([string]$Request.SourceCsv) -OneDriveRoot ([string]$Request.OneDriveRoot)
    $stages.Add([pscustomobject]@{ Code='Validated'; Status='Success'; Message='VPS, CSV, and OneDrive paths are valid.' })

    $fullConfigPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($ConfigPath))
    $configExisted = Test-Path -LiteralPath $fullConfigPath -PathType Leaf
    $saved = $null
    $localPublished = $false
    try {
        $saved = Save-MoneyMachineAccountConfig -ConfigPath $fullConfigPath -Account $normalized
        $stages.Add([pscustomobject]@{ Code='Configured'; Status='Success'; Message='Account configuration was saved atomically.' })

        $syncScript = Join-Path $PSScriptRoot 'Sync-BasketsToOneDrive.ps1'
        if(-not (Test-Path -LiteralPath $syncScript -PathType Leaf)) { throw "Sync script was not found: $syncScript" }
        . $syncScript -AsLibrary
        $syncResults = @(Invoke-MoneyMachineCsvSync -ConfigPath $fullConfigPath -StableCheckSeconds $StableCheckSeconds -MaxRetries 1 -MutexWaitMilliseconds $MutexWaitMilliseconds -RuntimeRoot $RuntimeRoot)
        $failed = @($syncResults | Where-Object Status -eq 'Error')
        if($failed.Count -gt 0) { throw (($failed | ForEach-Object { "Account $($_.AccountNumber): $($_.Message)" }) -join '; ') }
        $expectedResult = @($syncResults | Where-Object AccountNumber -eq $normalized.ExpectedMT4Login | Select-Object -First 1)
        if($expectedResult.Count -ne 1 -or $expectedResult[0].Status -ne 'Success') { throw 'The configured account did not complete its first local publication.' }

        $localPublished = $true
        $destination = Get-AmmarTradingDestinationPath -OneDriveRoot $normalized.OneDriveRoot -AccountNumber $normalized.ExpectedMT4Login
        $stages.Add([pscustomobject]@{ Code='LocalPublished'; Status='Success'; Message='The first CSV snapshot was published to the local OneDrive folder.' })

        if($SkipTaskRegistration) {
            $stages.Add([pscustomobject]@{ Code='TaskRegistrationSkipped'; Status='Success'; Message='Scheduled-task registration was skipped for staging acceptance.' })
        } else {
            $installer = Join-Path $PSScriptRoot 'Install-BasketsSyncTask.ps1'
            if(-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw "Scheduled-task installer was not found: $installer" }
            & $installer -ConfigPath $fullConfigPath
            $stages.Add([pscustomobject]@{ Code='Automated'; Status='Success'; Message='Daily and logon catch-up synchronization tasks are active.' })
        }

        return [pscustomobject]@{
            Status = 'Success'
            Account = $normalized
            Destination = $destination
            CloudDeliveryVerified = $false
            Stages = @($stages)
        }
    } catch {
        if(-not $localPublished -and $null -ne $saved -and $saved.Changed) {
            if($configExisted -and -not [string]::IsNullOrWhiteSpace([string]$saved.BackupPath) -and (Test-Path -LiteralPath $saved.BackupPath -PathType Leaf)) {
                Copy-Item -LiteralPath $saved.BackupPath -Destination $fullConfigPath -Force
            } elseif(-not $configExisted -and (Test-Path -LiteralPath $fullConfigPath -PathType Leaf)) {
                Remove-Item -LiteralPath $fullConfigPath -Force
            }
        }
        throw
    }
}

Export-ModuleMember -Function Get-AmmarTradingMt4Accounts,Get-MoneyMachineSetupDiscovery,Test-MoneyMachineSetupRequest,Save-MoneyMachineAccountConfig,Invoke-MoneyMachineSetup
