Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    if(-not [string]::IsNullOrWhiteSpace($TerminalDataRoot) -and (Test-Path -LiteralPath $TerminalDataRoot -PathType Container)) {
        foreach($file in @(Get-ChildItem -LiteralPath $TerminalDataRoot -Filter 'AGOLD___Baskets.csv' -File -Recurse -ErrorAction SilentlyContinue)) {
            if((Split-Path -Leaf $file.DirectoryName) -cne 'Files') { continue }
            $mql4Directory = Split-Path -Parent $file.DirectoryName
            if((Split-Path -Leaf $mql4Directory) -cne 'MQL4') { continue }
            $terminalDirectory = Split-Path -Parent $mql4Directory
            $sources.Add([pscustomobject]@{
                Path = $file.FullName
                TerminalId = Split-Path -Leaf $terminalDirectory
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
    if(-not (Test-Path -LiteralPath $expandedSource -PathType Leaf)) { throw "Source CSV was not found: $expandedSource" }
    if([IO.Path]::GetExtension($expandedSource) -ine '.csv') { throw 'Source file must use the .csv extension.' }
    $resolvedSource = (Resolve-Path -LiteralPath $expandedSource).Path

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
        $destination = Join-Path $normalized.OneDriveRoot (Join-Path 'AmarTrading' (Join-Path ("Account_{0}" -f $normalized.ExpectedMT4Login) 'Baskets.csv'))
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

Export-ModuleMember -Function Get-MoneyMachineSetupDiscovery,Test-MoneyMachineSetupRequest,Save-MoneyMachineAccountConfig,Invoke-MoneyMachineSetup
