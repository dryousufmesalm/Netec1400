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
    return $key -cin @('GET /api/discovery','GET /api/accounts','POST /api/setup')
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

function Get-MoneyMachineWizardAccounts {
    param([Parameter(Mandatory)][string]$ConfigPath)
    if(-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return @() }
    return @(
        Import-Csv -LiteralPath $ConfigPath | ForEach-Object {
            $accountNumber = [string]$_.ExpectedMT4Login
            $oneDriveRoot = [string]$_.OneDriveRoot
            $destination = Join-Path $oneDriveRoot (Join-Path 'AmarTrading' (Join-Path ("Account_{0}" -f $accountNumber) 'Baskets.csv'))
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
        Write-Host "Money Machine Sync Wizard is running at $prefix"
        if(-not $NoBrowser) { Start-Process $prefix }
        while($listener.IsListening) {
            $context = $listener.GetContext()
            $request = $context.Request
            $response = $context.Response
            try {
                $path = $request.Url.AbsolutePath
                if($path.StartsWith('/api/',[StringComparison]::OrdinalIgnoreCase)) {
                    if(-not (Test-MoneyMachineWizardRoute -Method $request.HttpMethod -Path $path)) {
                        Write-MoneyMachineWizardResponse -Response $response -StatusCode 404 -Body (ConvertTo-MoneyMachineWizardJsonBytes @{ ok=$false; code='RouteNotFound'; message='API route was not found.' })
                        continue
                    }
                    Test-MoneyMachineWizardRequestSecurity -HostHeader $request.Headers['Host'] -Origin $request.Headers['Origin'] -ExpectedAuthority $authority -CookieHeader $request.Headers['Cookie'] -SessionToken $sessionToken
                    if($path -ceq '/api/discovery') {
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
                    $status = if($_.Exception.Message -match 'Host|Origin|session') { 403 } elseif($_.Exception.Message -match '64 KiB|application/json') { 400 } else { 422 }
                    Write-MoneyMachineWizardResponse -Response $response -StatusCode $status -Body (ConvertTo-MoneyMachineWizardJsonBytes @{ ok=$false; code='RequestFailed'; message=$_.Exception.Message })
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
