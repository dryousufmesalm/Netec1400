param([Parameter(Mandatory)][string]$Package,[Parameter(Mandatory)][string]$WorkDir)
$ErrorActionPreference='Stop'
$root=$env:OneDrive
if(-not $root -or -not (Test-Path -LiteralPath $root)){throw 'Configured local OneDrive root is unavailable.'}
$target=Join-Path $root 'amartrading'
if(Test-Path -LiteralPath $target){throw 'Existing amartrading folder: refusing to overwrite.'}
$stage=Join-Path $WorkDir 'vps-snapshot'
if(Test-Path -LiteralPath $stage){throw 'Snapshot staging directory already exists.'}
Expand-Archive -LiteralPath $Package -DestinationPath $stage
$manifest=Get-Content -LiteralPath (Join-Path $stage 'snapshot-manifest.json') -Raw | ConvertFrom-Json
if($manifest.Host -ne 'fxut8768197' -or $manifest.Files.Count -ne 8){throw 'Unexpected snapshot provenance or file count.'}
foreach($file in $manifest.Files) {
 $local=Join-Path $stage $file.RelativePath
 if((Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash -ne $file.SHA256){throw "Snapshot hash mismatch: $($file.RelativePath)"}
}
Copy-Item -LiteralPath (Join-Path $stage 'amartrading') -Destination $target -Recurse
$verified=@()
foreach($file in $manifest.Files) {
 $local=Join-Path $root $file.RelativePath
 $hash=(Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
 if($hash -ne $file.SHA256){throw "OneDrive local copy hash mismatch: $local"}
 $verified+=@{Path=$local;SHA256=$hash}
}
@{Root=$root;Destination=$target;SourceHost=$manifest.Host;SnapshotUtc=$manifest.SnapshotUtc;Files=$verified;Accounts=$manifest.Accounts;VerifiedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $WorkDir 'import-verification.json') -Encoding UTF8
Write-Output "Verified 8 files copied to $target"
