[CmdletBinding()]
param(
    [string]$InstallerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $InstallerPath = Join-Path $PSScriptRoot '..\automation\MoneyMachineCsvSync\Install-MoneyMachineWorkbookQueries.ps1'
}

$source = Get-Content -LiteralPath $InstallerPath -Raw
$removal = [regex]::Match(
    $source,
    'for\s*\(\s*\$index\s*=\s*\$workbook\.Queries\.Count;\s*\$index\s*-ge\s*1;\s*\$index--\s*\)\s*\{(?<Body>.*?)\n\s*\}',
    [Text.RegularExpressions.RegexOptions]::Singleline
)
if(-not $removal.Success) { throw 'Installer must delete existing workbook queries by reverse collection enumeration.' }

$body = $removal.Groups['Body'].Value
if($body -notmatch '\$workbook\.Queries\.Item\(\$index\)') { throw 'Alias cleanup must resolve each existing query by collection index.' }
if($body -notmatch '\.Name\s+-match\s+''\^\(MoneyMachine\|AmarTrading\)_\(Baskets\|SyncStatus\)\$''') {
    throw 'Alias cleanup must use the case-insensitive MoneyMachine/AmarTrading query-name matcher.'
}
if($body -notmatch '\.Delete\(\)') { throw 'Alias cleanup must delete every matching existing query.' }
if($source -match 'Queries\.Item\(\$queryName\)\.Delete\(\)') {
    throw 'Do not use direct name lookup for alias cleanup: Excel query names can preserve case variants.'
}

Write-Host 'Workbook query-alias cleanup source contract passed.'
