[CmdletBinding()]
param(
    [int]$Port = 8765,
    [switch]$NoBrowser,
    [switch]$SkipTaskRegistration,
    [string]$ConfigPath,
    [string]$RuntimeRoot,
    [string]$WizardAppRoot,
    [string[]]$OneDriveCandidate,
    [string]$TerminalDataRoot,
    [switch]$AsLibrary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ScriptRoot = Split-Path -Parent $PSCommandPath
if([string]::IsNullOrWhiteSpace($ScriptRoot)) { throw 'Could not resolve the wizard host directory.' }

function Get-MoneyMachineWizardPrefix {
    [CmdletBinding()]
    param([int]$Port)
    if($Port -lt 1024 -or $Port -gt 65535) { throw 'Wizard port must be between 1024 and 65535.' }
    return "http://127.0.0.1:$Port/"
}

function Test-MoneyMachineWizardRoute {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Method,[Parameter(Mandatory)][string]$Path)
    $key = "$($Method.ToUpperInvariant()) $Path"
    return $key -cin @('GET /api/discovery','GET /api/accounts','POST /api/setup','POST /api/command')
}

function Write-MoneyMachineWizardCommandResponse {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RequestId,
        [Parameter(Mandatory)][bool]$Ok,
        [Parameter(Mandatory)][string]$Code,
        $Data = $null,
        [string]$Message
    )
    $body = [ordered]@{
        version = 1
        id = $RequestId
        ok = $Ok
        code = $Code
        data = $Data
    }
    if(-not [string]::IsNullOrWhiteSpace($Message)) { $body.message = $Message }
    Write-MoneyMachineWizardResponse -Response $Response -StatusCode $(if($Ok){200}elseif($Code -eq 'Unauthorized'){403}elseif($Code -eq 'UnsupportedCommand'){404}else{422}) -Body (ConvertTo-MoneyMachineWizardJsonBytes $body)
}

function Assert-MoneyMachineWizardBodySize {
    [CmdletBinding()]
    param([long]$ContentLength)
    if($ContentLength -gt 65536) { throw 'Request body exceeds the 64 KiB limit.' }
}

function Test-MoneyMachineWizardRequestSecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$HostHeader,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Origin,
        [Parameter(Mandatory)][string]$ExpectedAuthority,
        [Parameter(Mandatory)][AllowEmptyString()][string]$CookieHeader,
        [Parameter(Mandatory)][string]$SessionToken
    )
    if($HostHeader -ine $ExpectedAuthority) { throw 'Host header is not the active loopback endpoint.' }
    $expectedOrigin = "http://$ExpectedAuthority"
    if(-not [string]::IsNullOrWhiteSpace($Origin) -and $Origin.TrimEnd('/') -ine $expectedOrigin) { throw 'Origin is not the active loopback endpoint.' }
    $sessionValue = $null
    foreach($part in @($CookieHeader -split ';')) {
        $pair = $part.Trim() -split '=',2
        if($pair.Count -eq 2 -and $pair[0] -ceq 'MMWizardSession') { $sessionValue = $pair[1]; break }
    }
    if([string]::IsNullOrWhiteSpace($sessionValue) -or $sessionValue -cne $SessionToken) { throw 'Wizard session cookie is missing or invalid.' }
}

function New-MoneyMachineWizardSessionToken {
    $bytes = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    return ([Convert]::ToBase64String($bytes)).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function ConvertTo-MoneyMachineWizardJsonBytes {
    param([Parameter(Mandatory)][object]$Value)
    $json = $Value | ConvertTo-Json -Depth 10 -Compress
    return (New-Object Text.UTF8Encoding($false)).GetBytes($json)
}

function Write-MoneyMachineWizardResponse {
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][byte[]]$Body,
        [int]$StatusCode = 200,
        [string]$ContentType = 'application/json; charset=utf-8',
        [string]$SetCookie
    )
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentLength64 = $Body.Length
    $Response.Headers['X-Content-Type-Options'] = 'nosniff'
    $Response.Headers['Referrer-Policy'] = 'no-referrer'
    $Response.Headers['Cache-Control'] = 'no-store'
    $Response.Headers['Content-Security-Policy'] = "default-src 'self'; connect-src 'self'; img-src 'self' data:; style-src 'self'; font-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
    if(-not [string]::IsNullOrWhiteSpace($SetCookie)) { $Response.Headers['Set-Cookie'] = $SetCookie }
    try { $Response.OutputStream.Write($Body,0,$Body.Length) } finally { $Response.OutputStream.Close() }
}

function Get-MoneyMachineWizardStaticFile {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$AppRoot)
    $relative = if($Path -ceq '/') { 'index.html' } else { [Uri]::UnescapeDataString($Path.TrimStart('/')).Replace('/',[IO.Path]::DirectorySeparatorChar) }
    if($relative -match '(^|[\\/])\.\.([\\/]|$)') { return $null }
    $resolvedRoot = [IO.Path]::GetFullPath($AppRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $relative))
    if(-not $candidate.StartsWith($resolvedRoot,[StringComparison]::OrdinalIgnoreCase)) { return $null }
    if(-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $null }
    return $candidate
}

function Get-MoneyMachineWizardContentType {
    param([string]$Path)
    switch([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.html' { 'text/html; charset=utf-8' }
        '.js' { 'text/javascript; charset=utf-8' }
        '.css' { 'text/css; charset=utf-8' }
        '.json' { 'application/json; charset=utf-8' }
        '.png' { 'image/png' }
        '.svg' { 'image/svg+xml' }
        '.ico' { 'image/x-icon' }
        default { 'application/octet-stream' }
    }
}

function Get-AmmarTradingDestinationPath {
    param(
        [Parameter(Mandatory)][string]$OneDriveRoot,
        [Parameter(Mandatory)][string]$AccountNumber,
        [string]$DestinationFolder
    )

    $folder = if([string]::IsNullOrWhiteSpace($DestinationFolder)) { Join-Path $OneDriveRoot 'amartrading' } else { [string]$DestinationFolder }
    Join-Path $folder (Join-Path ("Account_{0}" -f $AccountNumber) 'Baskets.csv')
}

function Get-MoneyMachineWizardAccounts {
    param([Parameter(Mandatory)][string]$ConfigPath)
    if(-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return @() }
    return @(
        Import-Csv -LiteralPath $ConfigPath | ForEach-Object {
            $accountNumber = [string]$_.ExpectedMT4Login
            $oneDriveRoot = [string]$_.OneDriveRoot
            $destinationFolder = if($_.PSObject.Properties['DestinationFolder']) { [string]$_.DestinationFolder } else { '' }
            $destination = Get-AmmarTradingDestinationPath -OneDriveRoot $oneDriveRoot -AccountNumber $accountNumber -DestinationFolder $destinationFolder
            $published = Test-Path -LiteralPath $destination -PathType Leaf
            $destinationItem = if($published) { Get-Item -LiteralPath $destination } else { $null }
            [pscustomobject]@{
                enabled = ([string]$_.Enabled).Trim().ToLowerInvariant() -in @('true','1','yes','y')
                vpsName = if($_.PSObject.Properties['VpsName']) { [string]$_.VpsName } else { '' }
                expectedMT4Login = $accountNumber
                sourceCsv = [string]$_.SourceCsv
                oneDriveRoot = $oneDriveRoot
                files = if($published) { 1 } else { 0 }
                localPublished = $published
                lastWriteUtc = if($published) { $destinationItem.LastWriteTimeUtc.ToString('o') } else { $null }
            }
        }
    )
}

function Read-MoneyMachineWizardBody {
    param([Parameter(Mandatory)]$Request)
    Assert-MoneyMachineWizardBodySize -ContentLength $Request.ContentLength64
    $memory = New-Object IO.MemoryStream
    try {
        $buffer = New-Object byte[] 8192
        $total = 0
        while(($read = $Request.InputStream.Read($buffer,0,$buffer.Length)) -gt 0) {
            $total += $read
            Assert-MoneyMachineWizardBodySize -ContentLength $total
            $memory.Write($buffer,0,$read)
        }
        return (New-Object Text.UTF8Encoding($false)).GetString($memory.ToArray())
    } finally { $memory.Dispose() }
}

function Invoke-MoneyMachineWizardDesktopOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('SystemStatus','Discover','OneDriveRoots','Validate','Apply','Status','SyncNow')][string]$Operation,
        [Parameter(Mandatory)][psobject]$Payload,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RuntimeRoot
    )
    $canonicalRuntimeRoot = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($RuntimeRoot.Trim()))
    $requestRoot = Join-Path $canonicalRuntimeRoot 'requests'
    if(-not (Test-Path -LiteralPath $canonicalRuntimeRoot -PathType Container)) { New-Item -ItemType Directory -Path $canonicalRuntimeRoot -Force | Out-Null }
    if(-not (Test-Path -LiteralPath $requestRoot -PathType Container)) { New-Item -ItemType Directory -Path $requestRoot -Force | Out-Null }
    $requestPath = Join-Path $requestRoot ("browser-{0}.json" -f [guid]::NewGuid().ToString('N'))
    $requestJson = $Payload | ConvertTo-Json -Depth 12 -Compress
    [IO.File]::WriteAllText($requestPath, $requestJson, (New-Object Text.UTF8Encoding($false)))
    try {
        $operationScript = Join-Path $ScriptRoot 'Invoke-AmmarTradingDesktopOperation.ps1'
        $rawResult = @(& $operationScript -Operation $Operation -RequestPath $requestPath -RuntimeRoot $canonicalRuntimeRoot -ConfigPath $ConfigPath -SkipTaskRegistration:$SkipTaskRegistration -AsLibrary)
        $result = $rawResult | Select-Object -Last 1
        if($null -eq $result) { throw 'The local setup operation returned no result.' }
        if($result.PSObject.Properties['Ok'] -and -not [bool]$result.Ok) { throw [System.InvalidOperationException]::new([string]$result.Message) }
        return $result
    } finally {
        if(Test-Path -LiteralPath $requestPath -PathType Leaf) { Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue }
    }
}

function Show-MoneyMachineWizardCsvPicker {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $dialog.Title = 'Select the MT4 basket CSV'
        $dialog.Filter = 'MT4 basket CSV (AGOLD___Baskets.csv)|AGOLD___Baskets.csv|CSV files (*.csv)|*.csv'
        $dialog.Multiselect = $false
        if($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { throw [System.OperationCanceledException]::new('No CSV file was selected.') }
        return [string]$dialog.FileName
    } finally { $dialog.Dispose() }
}

function Show-MoneyMachineWizardFolderPicker {
    param([string]$InitialPath)
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description = 'Choose a folder inside the selected OneDrive root'
        $dialog.ShowNewFolderButton = $true
        if(-not [string]::IsNullOrWhiteSpace($InitialPath) -and (Test-Path -LiteralPath $InitialPath -PathType Container)) { $dialog.SelectedPath = $InitialPath }
        if($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { throw [System.OperationCanceledException]::new('No OneDrive folder was selected.') }
        return [string]$dialog.SelectedPath
    } finally { $dialog.Dispose() }
}

function Assert-MoneyMachineWizardPayloadFields {
    param(
        [Parameter(Mandatory)][psobject]$Payload,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Allowed
    )
    foreach($property in $Payload.PSObject.Properties) {
        if($property.Name -cnotin $Allowed) { throw 'The browser command payload contains an unexpected field.' }
    }
}

function Open-MoneyMachineWizardReportingFolder {
    param(
        [Parameter(Mandatory)][psobject]$Payload,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RuntimeRoot
    )
    Assert-MoneyMachineWizardPayloadFields -Payload $Payload -Allowed @('accountNumbers')
    $requested = @()
    if($Payload.PSObject.Properties['accountNumbers']) {
        if($Payload.accountNumbers -isnot [array]) { throw 'The account selection is invalid.' }
        $requested = @($Payload.accountNumbers | ForEach-Object { ([string]$_).Trim() })
        if(@($requested | Where-Object { $_ -notmatch '^\d{4,20}$' }).Count -gt 0 -or @($requested | Select-Object -Unique).Count -ne $requested.Count) { throw 'The account selection is invalid.' }
    }
    $configurations = if(Test-Path -LiteralPath $ConfigPath -PathType Leaf) { @(Import-Csv -LiteralPath $ConfigPath -ErrorAction Stop) } else { @() }
    foreach($configuration in $configurations) {
        $accountNumber = ([string]$configuration.ExpectedMT4Login).Trim()
        if($accountNumber -notmatch '^\d{4,20}$' -or ($requested.Count -gt 0 -and $requested -notcontains $accountNumber)) { continue }
        $root = Resolve-AmmarTradingOneDriveRoot -Path ([string]$configuration.OneDriveRoot)
        $vpsId = if($configuration.PSObject.Properties['VpsId']) { [string]$configuration.VpsId } else { '' }
        $destinationFolder = if($configuration.PSObject.Properties['DestinationFolder']) { [string]$configuration.DestinationFolder } else { '' }
        $destination = Get-AmmarTradingDestinationPath -OneDriveRoot $root -AccountNumber $accountNumber -VpsId $vpsId -DestinationFolder $destinationFolder
        $destination = Assert-AmmarTradingTrustedDestinationPath -OneDriveRoot $root -Path $destination -Description 'Configured reporting file'
        $accountDirectory = Split-Path -Parent $destination
        if(-not (Test-Path -LiteralPath $accountDirectory -PathType Container)) { throw 'The configured reporting folder is not available.' }
        Start-Process explorer.exe -ArgumentList @($accountDirectory) | Out-Null
        return [pscustomobject]@{ Status = 'Opened'; AccountNumber = $accountNumber }
    }
    throw 'No configured reporting folder matched the selected account.'
}

function Export-MoneyMachineWizardSupportReport {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [string]$TerminalDataRoot
    )
    $systemStatus = Invoke-MoneyMachineWizardDesktopOperation -Operation SystemStatus -Payload ([pscustomobject]@{}) -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
    $discovery = Invoke-MoneyMachineWizardDesktopOperation -Operation Discover -Payload ([pscustomobject]@{}) -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
    $configured = Invoke-MoneyMachineWizardDesktopOperation -Operation Status -Payload ([pscustomobject]@{}) -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
    $reportDirectory = Join-Path $RuntimeRoot 'support'
    if(-not (Test-Path -LiteralPath $reportDirectory -PathType Container)) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
    $reportPath = Join-Path $reportDirectory ("AmarTrading-Support-{0:yyyyMMddTHHmmssfffZ}-{1}.json" -f [DateTime]::UtcNow,[guid]::NewGuid().ToString('N'))
    $report = [ordered]@{
        ApplicationVersion = 'PowerShellBrowser-1'
        WindowsVersion = [Environment]::OSVersion.VersionString
        SystemStatus = $systemStatus
        Discovery = $discovery
        ConfiguredAccounts = $configured
    }
    $json = $report | ConvertTo-Json -Depth 12
    $userProfile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if(-not [string]::IsNullOrWhiteSpace($userProfile)) { $json = $json.Replace($userProfile, '%USERPROFILE%') }
    [IO.File]::WriteAllText($reportPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    return [pscustomobject]@{ Path = $reportPath }
}

function Get-MoneyMachineWizardCommandResult {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)]$Payload,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [string]$TerminalDataRoot,
        [switch]$SkipTaskRegistration
    )
    switch($Command) {
        'getSystemStatus' {
            Assert-MoneyMachineWizardPayloadFields -Payload $Payload -Allowed @()
            return Invoke-MoneyMachineWizardDesktopOperation -Operation SystemStatus -Payload $Payload -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
        }
        'discoverMt4Accounts' {
            Assert-MoneyMachineWizardPayloadFields -Payload $Payload -Allowed @()
            return Invoke-MoneyMachineWizardDesktopOperation -Operation Discover -Payload $Payload -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
        }
        'browseForCsv' {
            Assert-MoneyMachineWizardPayloadFields -Payload $Payload -Allowed @()
            $selected = Show-MoneyMachineWizardCsvPicker
            return Invoke-MoneyMachineWizardDesktopOperation -Operation Discover -Payload ([pscustomobject]@{ manualCsv = @($selected) }) -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
        }
        'getOneDriveRoots' {
            Assert-MoneyMachineWizardPayloadFields -Payload $Payload -Allowed @()
            return Invoke-MoneyMachineWizardDesktopOperation -Operation OneDriveRoots -Payload $Payload -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
        }
        'browseForOneDriveFolder' {
            Assert-MoneyMachineWizardPayloadFields -Payload $Payload -Allowed @('initialPath')
            $initialPath = if($Payload.PSObject.Properties['initialPath']) { [string]$Payload.initialPath } else { '' }
            return [pscustomobject]@{ Path = Show-MoneyMachineWizardFolderPicker -InitialPath $initialPath }
        }
        'validateSelection' {
            return Invoke-MoneyMachineWizardDesktopOperation -Operation Validate -Payload $Payload -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
        }
        'applySetup' {
            return Invoke-MoneyMachineWizardDesktopOperation -Operation Apply -Payload $Payload -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
        }
        'getConfiguredAccounts' {
            Assert-MoneyMachineWizardPayloadFields -Payload $Payload -Allowed @()
            return Invoke-MoneyMachineWizardDesktopOperation -Operation Status -Payload $Payload -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
        }
        'runSyncNow' {
            Assert-MoneyMachineWizardPayloadFields -Payload $Payload -Allowed @('accountNumbers')
            return Invoke-MoneyMachineWizardDesktopOperation -Operation SyncNow -Payload $Payload -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
        }
        'openReportingFolder' {
            return Open-MoneyMachineWizardReportingFolder -Payload $Payload -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot
        }
        'exportSupportReport' {
            Assert-MoneyMachineWizardPayloadFields -Payload $Payload -Allowed @()
            return Export-MoneyMachineWizardSupportReport -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot -TerminalDataRoot $TerminalDataRoot
        }
        default { throw [System.Management.Automation.ItemNotFoundException]::new("The browser command '$Command' is not supported yet.") }
    }
}

function Start-MoneyMachineSyncWizard {
    [CmdletBinding()]
    param(
        [int]$Port = 8765,
        [switch]$NoBrowser,
        [switch]$SkipTaskRegistration,
        [string]$ConfigPath = (Join-Path $ScriptRoot 'accounts.csv'),
        [string]$RuntimeRoot = $ScriptRoot,
        [string]$WizardAppRoot = (Join-Path $ScriptRoot 'WizardApp'),
        [string[]]$OneDriveCandidate,
        [string]$TerminalDataRoot
    )

    $prefix = Get-MoneyMachineWizardPrefix -Port $Port
    $authority = "127.0.0.1:$Port"
    if(-not (Test-Path -LiteralPath (Join-Path $WizardAppRoot 'index.html') -PathType Leaf)) { throw "Wizard app was not found: $WizardAppRoot" }
    $setupModule = Join-Path $ScriptRoot 'MoneyMachineSyncSetup.psm1'
    Import-Module -Name $setupModule -Force -ErrorAction Stop
    $sessionToken = New-MoneyMachineWizardSessionToken
    $cookie = "MMWizardSession=$sessionToken; Path=/; HttpOnly; SameSite=Strict"
    $listener = New-Object Net.HttpListener
    $listener.Prefixes.Add($prefix)
    try {
        $listener.Start()
        Write-Host "AmarTrading Sync is running at $prefix"
        if(-not $NoBrowser) { Start-Process $prefix }
        while($listener.IsListening) {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response
            $path = ''
            $commandId = ''
            try {
                $path = $request.Url.AbsolutePath
                if($path.StartsWith('/api/',[StringComparison]::OrdinalIgnoreCase)) {
                    if(-not (Test-MoneyMachineWizardRoute -Method $request.HttpMethod -Path $path)) {
                        Write-MoneyMachineWizardResponse -Response $response -StatusCode 404 -Body (ConvertTo-MoneyMachineWizardJsonBytes @{ ok=$false; code='RouteNotFound'; message='API route was not found.' })
                        continue
                    }
                    Test-MoneyMachineWizardRequestSecurity -HostHeader $request.Headers['Host'] -Origin $request.Headers['Origin'] -ExpectedAuthority $authority -CookieHeader $request.Headers['Cookie'] -SessionToken $sessionToken
                    if($path -ceq '/api/command') {
                        $commandId = ''
                        try {
                            if($request.ContentType -notmatch '^application/json(?:\s*;|$)') { throw 'Command requests must use application/json.' }
                            $envelope = Read-MoneyMachineWizardBody -Request $request | ConvertFrom-Json -ErrorAction Stop
                            if($null -eq $envelope -or $envelope -isnot [pscustomobject]) { throw 'The browser command envelope must be a JSON object.' }
                            $idProperty = $envelope.PSObject.Properties['id']
                            if($null -ne $idProperty -and $idProperty.Value -is [string]) { $commandId = [string]$idProperty.Value }
                            $allowedEnvelopeFields = @('version','id','command','payload')
                            foreach($property in $envelope.PSObject.Properties) {
                                if($property.Name -cnotin $allowedEnvelopeFields) { throw 'The browser command envelope contains an unexpected field.' }
                            }
                            foreach($required in $allowedEnvelopeFields) {
                                if($null -eq $envelope.PSObject.Properties[$required]) { throw "The browser command envelope is missing '$required'." }
                            }
                            $versionValue = $envelope.PSObject.Properties['version'].Value
                            if($versionValue -isnot [byte] -and $versionValue -isnot [int16] -and $versionValue -isnot [int32] -and $versionValue -isnot [int64] -and $versionValue -isnot [single] -and $versionValue -isnot [double] -and $versionValue -isnot [decimal]) { throw 'The browser command version must be numeric.' }
                            if([int]$versionValue -ne 1) { throw 'The browser command version is not supported.' }
                            $idValue = $envelope.PSObject.Properties['id'].Value
                            if($idValue -isnot [string]) { throw 'The browser command ID must be a string.' }
                            $commandId = [string]$idValue
                            if($commandId -notmatch '^[A-Za-z0-9._:-]{1,128}$') { throw 'The browser command ID is invalid.' }
                            $commandValue = $envelope.PSObject.Properties['command'].Value
                            if($commandValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$commandValue)) { throw 'The browser command name must be a non-empty string.' }
                            $command = [string]$commandValue
                            $payload = $envelope.PSObject.Properties['payload'].Value
                            if($null -eq $payload -or $payload -isnot [pscustomobject]) { throw 'The browser command payload must be a JSON object.' }
                            if($command -ceq 'discoverMt4Accounts' -and @($payload.PSObject.Properties).Count -gt 0) { throw 'MT4 discovery does not accept a payload.' }
                            $data = Get-MoneyMachineWizardCommandResult -Command $command -Payload $payload -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot -TerminalDataRoot $TerminalDataRoot -SkipTaskRegistration:$SkipTaskRegistration
                            Write-MoneyMachineWizardCommandResponse -Response $response -RequestId $commandId -Ok $true -Code 'Success' -Data $data
                        } catch {
                            $code = if($_.Exception -is [System.Management.Automation.ItemNotFoundException]) { 'UnsupportedCommand' } elseif($_.Exception -is [System.OperationCanceledException]) { 'Cancelled' } else { 'RequestFailed' }
                            Write-MoneyMachineWizardCommandResponse -Response $response -RequestId $commandId -Ok $false -Code $code -Data $null -Message $_.Exception.Message
                        }
                    } elseif($path -ceq '/api/discovery') {
                        $discovery = Get-MoneyMachineSetupDiscovery -OneDriveCandidates $OneDriveCandidate -TerminalDataRoot $TerminalDataRoot
                        Write-MoneyMachineWizardResponse -Response $response -Body (ConvertTo-MoneyMachineWizardJsonBytes @{ ok=$true; oneDriveRoots=@($discovery.OneDriveRoots); sources=@($discovery.Sources) })
                    } elseif($path -ceq '/api/accounts') {
                        Write-MoneyMachineWizardResponse -Response $response -Body (ConvertTo-MoneyMachineWizardJsonBytes @{ ok=$true; accounts=@(Get-MoneyMachineWizardAccounts -ConfigPath $ConfigPath) })
                    } else {
                        if($request.ContentType -notmatch '^application/json(?:\s*;|$)') { throw 'Setup requests must use application/json.' }
                        $payload = Read-MoneyMachineWizardBody -Request $request | ConvertFrom-Json -ErrorAction Stop
                        $result = Invoke-MoneyMachineSetup -Request ([pscustomobject]@{
                            VpsName = [string]$payload.vpsName
                            ExpectedMT4Login = [string]$payload.expectedMT4Login
                            SourceCsv = [string]$payload.sourceCsv
                            OneDriveRoot = [string]$payload.oneDriveRoot
                            DestinationFolder = [string]$payload.destinationFolder
                        }) -ConfigPath $ConfigPath -RuntimeRoot $RuntimeRoot -SkipTaskRegistration:$SkipTaskRegistration
                        Write-MoneyMachineWizardResponse -Response $response -Body (ConvertTo-MoneyMachineWizardJsonBytes @{ ok=$true; status=$result.Status; stages=@($result.Stages); account=$result.Account; destination=$result.Destination; cloudDeliveryVerified=$result.CloudDeliveryVerified })
                    }
                    continue
                }

                if($request.HttpMethod -cne 'GET') {
                    Write-MoneyMachineWizardResponse -Response $response -StatusCode 405 -Body (ConvertTo-MoneyMachineWizardJsonBytes @{ ok=$false; code='MethodNotAllowed'; message='Only GET is allowed for app files.' })
                    continue
                }
                $file = Get-MoneyMachineWizardStaticFile -Path $path -AppRoot $WizardAppRoot
                if($null -eq $file) {
                    Write-MoneyMachineWizardResponse -Response $response -StatusCode 404 -Body (ConvertTo-MoneyMachineWizardJsonBytes @{ ok=$false; code='NotFound'; message='File was not found.' })
                    continue
                }
                $setCookie = if($path -ceq '/') { $cookie } else { $null }
                Write-MoneyMachineWizardResponse -Response $response -ContentType (Get-MoneyMachineWizardContentType -Path $file) -SetCookie $setCookie -Body ([IO.File]::ReadAllBytes($file))
            } catch {
                if($response.OutputStream.CanWrite) {
                    if($path -ceq '/api/command') {
                        $code = if($_.Exception.Message -match 'Host|Origin|session') { 'Unauthorized' } elseif($_.Exception.Message -match '64 KiB|application/json') { 'InvalidRequest' } else { 'RequestFailed' }
                        Write-MoneyMachineWizardCommandResponse -Response $response -RequestId $commandId -Ok $false -Code $code -Data $null -Message $_.Exception.Message
                    } else {
                        $status = if($_.Exception.Message -match 'Host|Origin|session') { 403 } elseif($_.Exception.Message -match '64 KiB|application/json') { 400 } else { 422 }
                        Write-MoneyMachineWizardResponse -Response $response -StatusCode $status -Body (ConvertTo-MoneyMachineWizardJsonBytes @{ ok=$false; code='RequestFailed'; message=$_.Exception.Message })
                    }
                }
            }
        }
    } finally {
        if($listener.IsListening) { $listener.Stop() }
        $listener.Close()
    }
}

if(-not $AsLibrary) {
    $startParameters = @{
        Port = $Port
        NoBrowser = $NoBrowser
        SkipTaskRegistration = $SkipTaskRegistration
    }
    if(-not [string]::IsNullOrWhiteSpace($ConfigPath)) { $startParameters.ConfigPath = $ConfigPath }
    if(-not [string]::IsNullOrWhiteSpace($RuntimeRoot)) { $startParameters.RuntimeRoot = $RuntimeRoot }
    if(-not [string]::IsNullOrWhiteSpace($WizardAppRoot)) { $startParameters.WizardAppRoot = $WizardAppRoot }
    if($null -ne $OneDriveCandidate) { $startParameters.OneDriveCandidate = $OneDriveCandidate }
    if(-not [string]::IsNullOrWhiteSpace($TerminalDataRoot)) { $startParameters.TerminalDataRoot = $TerminalDataRoot }
    Start-MoneyMachineSyncWizard @startParameters
}
