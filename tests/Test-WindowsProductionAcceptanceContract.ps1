[CmdletBinding()]
param(
    [string]$RunnerPath = (Join-Path $PSScriptRoot 'Run-WindowsProductionAcceptance.ps1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if(-not (Test-Path -LiteralPath $RunnerPath -PathType Leaf)) {
    throw "Windows production acceptance runner is missing: $RunnerPath"
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("MoneyMachineAcceptanceContract_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    . $RunnerPath -StagingRoot $tempRoot -AsLibrary

    $sourcePath = 'C:\PrivateSource\AGOLD___Baskets.csv'
    $configurationSecret = 'OneDriveCredential=acceptance-secret'
    $report = [ordered]@{
        StartedUtc = [DateTime]::UtcNow.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Runtime = [ordered]@{
            PowerShell = '5.1'
            Computer = [Environment]::MachineName
            PersonalPath = 'C:\Users\Private Person\OneDrive\MoneyMachine'
        }
        Checks = @([ordered]@{
            Name = 'redaction-contract'
            Status = 'Pass'
            StartedUtc = [DateTime]::UtcNow.ToString('o')
            CompletedUtc = [DateTime]::UtcNow.ToString('o')
            Message = "Validated $sourcePath; $configurationSecret"
            Artifacts = @([ordered]@{ Name='fixture'; Sha256=('a' * 64) })
        })
        OverallStatus = 'Pass'
    }

    $json = ConvertTo-RedactedAcceptanceJson -Report $report -SensitiveValues @($sourcePath,$configurationSecret)
    foreach($forbidden in @('C:\Users\','Private Person',[Environment]::MachineName,$sourcePath,$configurationSecret,'acceptance-secret')) {
        if($json -match [regex]::Escape($forbidden)) { throw "Acceptance JSON leaked forbidden text: $forbidden" }
    }
    $parsed = $json | ConvertFrom-Json
    if($parsed.OverallStatus -ne 'Pass' -or @($parsed.Checks).Count -ne 1) { throw 'Acceptance JSON does not preserve the documented result schema.' }
    if(@($parsed.Checks[0].Artifacts).Count -ne 1) { throw 'Acceptance JSON must preserve Artifacts as an array.' }
    if($parsed.Checks[0].Artifacts[0].Sha256 -ne ('a' * 64)) { throw 'Acceptance JSON did not preserve the artifact hash.' }

    $outputPath = Join-Path $tempRoot 'audit\windows-production-acceptance.json'
    Write-AtomicAcceptanceReport -Path $outputPath -Json $json
    $saved = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
    if($saved.OverallStatus -ne 'Pass') { throw 'Atomically written acceptance JSON could not be parsed.' }
    if(@(Get-ChildItem -LiteralPath (Split-Path -Parent $outputPath) -Filter '*.tmp' -ErrorAction SilentlyContinue).Count -ne 0) {
        throw 'Atomic acceptance output left a temporary file behind.'
    }

    Write-Host 'Windows production acceptance contract passed.'
}
finally {
    if(Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
