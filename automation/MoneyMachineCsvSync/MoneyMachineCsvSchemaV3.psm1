Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName Microsoft.VisualBasic

$script:SchemaV3Columns = @(
    'AccountNumber','BrokerName','BasketID','Symbol','SymbolNormalized','Timeframe','StartTime','EndTime','DurationSeconds',
    'Direction','OrdersCount','TotalLots','FixedLots','MaxOrdersConcurrent','MaxTotalLots','MaxFloatingDrawdownAbs','MaxFloatingProfit',
    'ClosePL','CloseReason','OutcomeClass','SpreadAtEntry','EquityAtEntry','HeadroomAtEntry','MinHeadroom','TimesNearKill',
    'ExposureBlocks','PipsStep','TakeProfit','KillEquityLevel','MaxOrdersInBasket','MaxTotalLotsInBasket','EquityAtExit','BalanceAfter',
    'TradeDate','RunID','RunStartTime','RunStartBalance','EAName','EAVersion','Magic','PointsPerPip','Tral','TralStart','MaxSpread',
    'TimeStart','TimeEnd','OpenTime','NewBasketDelaySeconds','SpeedEA','UseBasketTrailingTP','TrailingStart','TrailingStep',
    'KillSwitchEnable','KillCooldownMinutes','RegimeEnable','RegimeAction','RegimeADXPeriod','RegimeADXLevel','RegimeADXBars',
    'RegimeRangeBars','RegimeRecoveryBars','EnableTradingDaysFilter','TradeMonday','TradeTuesday','TradeWednesday','TradeThursday',
    'TradeFriday','EnableRecoveryStepUp','RecoveryWaitMinutes','RecoveryMaxTotalLotsInBasket','CsvSchemaVersion'
)
$script:SchemaV2Columns = @($script:SchemaV3Columns[0..33]) + @('CsvSchemaVersion')
$script:IdentityColumns = @('AccountNumber','BrokerName','CsvSchemaVersion','EAVersion')

$script:IntegerFields = @(
    'BasketID','Timeframe','DurationSeconds','OrdersCount','MaxOrdersConcurrent','TimesNearKill','ExposureBlocks','PipsStep',
    'MaxOrdersInBasket','Magic','PointsPerPip','Tral','TralStart','MaxSpread','TimeStart','TimeEnd','OpenTime',
    'NewBasketDelaySeconds','SpeedEA','KillCooldownMinutes','RegimeAction','RegimeADXPeriod','RegimeADXBars','RegimeRangeBars',
    'RegimeRecoveryBars','RecoveryWaitMinutes','CsvSchemaVersion'
)
$script:DecimalFields = @(
    'TotalLots','FixedLots','MaxTotalLots','MaxFloatingDrawdownAbs','MaxFloatingProfit','ClosePL','SpreadAtEntry','EquityAtEntry',
    'HeadroomAtEntry','MinHeadroom','TakeProfit','KillEquityLevel','MaxTotalLotsInBasket','EquityAtExit','BalanceAfter',
    'RunStartBalance','TrailingStart','TrailingStep','RegimeADXLevel','RecoveryMaxTotalLotsInBasket'
)
$script:BooleanFields = @(
    'UseBasketTrailingTP','KillSwitchEnable','RegimeEnable','EnableTradingDaysFilter','TradeMonday','TradeTuesday',
    'TradeWednesday','TradeThursday','TradeFriday','EnableRecoveryStepUp'
)
$script:TimestampFields = @('StartTime','EndTime','RunStartTime')
$script:DateFields = @('TradeDate')
$script:TextFields = @(
    'AccountNumber','BrokerName','Symbol','SymbolNormalized','Direction','CloseReason','OutcomeClass','RunID','EAName','EAVersion'
)
$script:ControlledValues = @{
    Direction = @('BUY','SELL')
    CloseReason = @('TP','KILL','OTHER')
    OutcomeClass = @('KILL','NORMAL_PROFIT','RECOVERY_PROFIT','OTHER')
    RegimeAction = @('0','1')
}

$script:Culture = [Globalization.CultureInfo]::InvariantCulture
$script:IntegerStyle = [Globalization.NumberStyles]::AllowLeadingSign
$script:DecimalStyle = [Globalization.NumberStyles]([Globalization.NumberStyles]::AllowLeadingSign -bor [Globalization.NumberStyles]::AllowDecimalPoint)

$classifiedFields = @($script:IntegerFields + $script:DecimalFields + $script:BooleanFields + $script:TimestampFields + $script:DateFields + $script:TextFields)
if($classifiedFields.Count -ne $script:SchemaV3Columns.Count) { throw 'Schema-v3 field classification does not contain exactly 71 entries.' }
if(@($classifiedFields | Group-Object | Where-Object Count -ne 1).Count -gt 0) { throw 'Schema-v3 field classification contains duplicate entries.' }
if(@($script:SchemaV3Columns | Where-Object { $_ -notin $classifiedFields }).Count -gt 0) { throw 'Schema-v3 field classification is incomplete.' }

function Get-MoneyMachineSchemaV3Columns {
    [CmdletBinding()]
    param()
    return @($script:SchemaV3Columns)
}

function Test-ExactCsvHeader {
    param([object[]]$Header,[string[]]$Expected)

    if($Header.Count -ne $Expected.Count) { return $false }
    for($index = 0; $index -lt $Expected.Count; $index++) {
        $actual = ([string]$Header[$index]).TrimStart([char]0xFEFF)
        if($actual -cne $Expected[$index]) { return $false }
    }
    return $true
}

function Get-AmmarTradingImmediateIdentity {
    param([Parameter(Mandatory)][string]$BasketsPath)

    $identityPath = Join-Path ([IO.Path]::GetDirectoryName($BasketsPath)) 'AGOLD___Identity.csv'
    if(-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) { return $null }
    $identityFile = Get-Item -LiteralPath $identityPath -ErrorAction Stop
    if(($identityFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $identityFile.Length -le 0 -or $identityFile.Length -gt 4096) {
        return $null
    }

    $parser = $null
    try {
        $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($identityPath, [Text.Encoding]::UTF8, $true)
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false
        if($parser.EndOfData) { return $null }
        $header = @($parser.ReadFields())
        if(-not (Test-ExactCsvHeader -Header $header -Expected $script:IdentityColumns) -or $parser.EndOfData) { return $null }
        $fields = @($parser.ReadFields())
        if($fields.Count -ne $script:IdentityColumns.Count -or -not $parser.EndOfData) { return $null }
        if([string]$fields[0] -notmatch '^\d+$' -or
           [string]::IsNullOrWhiteSpace([string]$fields[1]) -or
           [string]$fields[2] -cne '3' -or
           [string]$fields[3] -cne '3.00') { return $null }
        return [pscustomobject]@{
            AccountNumber = [string]$fields[0]
            BrokerName = [string]$fields[1]
            SchemaVersion = [string]$fields[2]
        }
    } catch {
        return $null
    } finally {
        if($null -ne $parser) {
            $parser.Close()
            $parser.Dispose()
        }
    }
}

function Get-AmmarTradingCsvIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "CSV file not found: $Path" }

    $accountNumber = $null
    $brokerName = $null
    $schemaVersion = $null
    $status = 'MalformedCsv'
    $parser = $null
    try {
        $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($Path, [Text.Encoding]::UTF8, $true)
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false

        if(-not $parser.EndOfData) {
            $header = @($parser.ReadFields())
            $isSchemaV3Header = Test-ExactCsvHeader -Header $header -Expected $script:SchemaV3Columns
            $isSchemaV2Header = Test-ExactCsvHeader -Header $header -Expected $script:SchemaV2Columns
            if($isSchemaV3Header -or $isSchemaV2Header) {
                $schemaVersion = if($isSchemaV2Header) { '2' } else { '3' }
                if($parser.EndOfData) {
                    $status = if($isSchemaV2Header) { 'SchemaV2' } else { 'HeaderOnly' }
                } else {
                    $fields = @($parser.ReadFields())
                    if($fields.Count -eq $header.Count) {
                        $accountNumber = [string]$fields[0]
                        $brokerName = [string]$fields[1]
                        $schemaVersion = [string]$fields[$fields.Count - 1]
                        if($isSchemaV2Header -or $schemaVersion -ceq '2') {
                            $status = 'SchemaV2'
                        } elseif($schemaVersion -ceq '3' -and
                            $accountNumber -match '^\d+$' -and
                            -not [string]::IsNullOrWhiteSpace($brokerName)) {
                            $status = 'Ready'
                        }
                    }
                }
            }
        }
    } catch {
        $status = 'MalformedCsv'
    } finally {
        if($null -ne $parser) {
            $parser.Close()
            $parser.Dispose()
        }
    }

    if($status -ceq 'HeaderOnly') {
        $immediateIdentity = Get-AmmarTradingImmediateIdentity -BasketsPath $Path
        if($null -ne $immediateIdentity) {
            $accountNumber = $immediateIdentity.AccountNumber
            $brokerName = $immediateIdentity.BrokerName
            $schemaVersion = $immediateIdentity.SchemaVersion
            $status = 'Ready'
        }
    }

    return [pscustomobject][ordered]@{
        AccountNumber = $accountNumber
        BrokerName = $brokerName
        SchemaVersion = $schemaVersion
        Status = $status
    }
}

function Test-InvariantInteger {
    param([string]$Value)
    $parsed = [int64]0
    return [int64]::TryParse($Value, $script:IntegerStyle, $script:Culture, [ref]$parsed)
}

function Test-InvariantDecimal {
    param([string]$Value)
    $parsed = [decimal]0
    return [decimal]::TryParse($Value, $script:DecimalStyle, $script:Culture, [ref]$parsed)
}

function Convert-ExactTimestamp {
    param([string]$Value, [string]$Field, [int]$RowNumber)
    $parsed = [datetime]::MinValue
    if(-not [datetime]::TryParseExact($Value, 'yyyy-MM-dd HH:mm:ss', $script:Culture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        throw "Row $RowNumber field '$Field' must use yyyy-MM-dd HH:mm:ss."
    }
    return $parsed
}

function Convert-ExactDate {
    param([string]$Value, [string]$Field, [int]$RowNumber)
    $parsed = [datetime]::MinValue
    if(-not [datetime]::TryParseExact($Value, 'yyyy-MM-dd', $script:Culture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        throw "Row $RowNumber field '$Field' must use yyyy-MM-dd."
    }
    return $parsed
}

function Read-MoneyMachineBasketsCsv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedLogin
    )

    if(-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "CSV file not found: $Path" }
    if([string]::IsNullOrWhiteSpace($ExpectedLogin)) { throw 'ExpectedLogin is required.' }

    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new($Path, [Text.Encoding]::UTF8, $true)
    $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
    $parser.SetDelimiters(',')
    $parser.HasFieldsEnclosedInQuotes = $true
    $parser.TrimWhiteSpace = $false
    $rows = [System.Collections.Generic.List[object]]::new()
    $keys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    try {
        if($parser.EndOfData) { throw 'CSV header is empty.' }
        $header = @($parser.ReadFields())
        if($header.Count -ne $script:SchemaV3Columns.Count) { throw "CSV header has $($header.Count) columns; expected $($script:SchemaV3Columns.Count)." }
        for($index = 0; $index -lt $script:SchemaV3Columns.Count; $index++) {
            $actual = ([string]$header[$index]).TrimStart([char]0xFEFF)
            if($actual -cne $script:SchemaV3Columns[$index]) { throw "CSV header column $($index + 1) is '$actual'; expected '$($script:SchemaV3Columns[$index])'." }
        }

        $rowNumber = 1
        while(-not $parser.EndOfData) {
            $rowNumber++
            try { $fields = @($parser.ReadFields()) }
            catch [Microsoft.VisualBasic.FileIO.MalformedLineException] { throw "Row $rowNumber is malformed CSV: $($_.Exception.Message)" }
            if($fields.Count -ne $script:SchemaV3Columns.Count) { throw "Row $rowNumber has $($fields.Count) fields; expected $($script:SchemaV3Columns.Count)." }

            $values = [ordered]@{}
            for($index = 0; $index -lt $script:SchemaV3Columns.Count; $index++) { $values[$script:SchemaV3Columns[$index]] = [string]$fields[$index] }
            $row = [pscustomobject]$values

            foreach($field in @('AccountNumber','RunID','BasketID')) {
                if([string]::IsNullOrWhiteSpace([string]$row.$field)) { throw "Row $rowNumber field '$field' is required." }
            }
            if($row.AccountNumber -cne $ExpectedLogin) { throw "Row $rowNumber field 'AccountNumber' value '$($row.AccountNumber)' does not match ExpectedMT4Login '$ExpectedLogin'." }

            foreach($field in $script:IntegerFields) {
                if($field -eq 'MaxOrdersInBasket' -and $row.$field -eq '') { $row.$field = '0' }
                if(-not (Test-InvariantInteger -Value $row.$field)) { throw "Row $rowNumber field '$field' must be an invariant integer." }
            }
            foreach($field in $script:DecimalFields) {
                if(-not (Test-InvariantDecimal -Value $row.$field)) { throw "Row $rowNumber field '$field' must be an invariant decimal." }
            }
            foreach($field in $script:BooleanFields) {
                if($row.$field -cnotin @('0','1')) { throw "Row $rowNumber field '$field' must be 0 or 1." }
            }
            foreach($field in $script:ControlledValues.Keys) {
                if($row.$field -cnotin $script:ControlledValues[$field]) { throw "Row $rowNumber field '$field' has unsupported value '$($row.$field)'." }
            }
            if($row.CsvSchemaVersion -cne '3') { throw "Row $rowNumber field 'CsvSchemaVersion' must be 3." }

            $startTime = Convert-ExactTimestamp -Value $row.StartTime -Field 'StartTime' -RowNumber $rowNumber
            $endTime = Convert-ExactTimestamp -Value $row.EndTime -Field 'EndTime' -RowNumber $rowNumber
            [void](Convert-ExactTimestamp -Value $row.RunStartTime -Field 'RunStartTime' -RowNumber $rowNumber)
            $tradeDate = Convert-ExactDate -Value $row.TradeDate -Field 'TradeDate' -RowNumber $rowNumber
            if($endTime -lt $startTime) { throw "Row $rowNumber field 'EndTime' precedes StartTime." }
            $duration = [int64]$row.DurationSeconds
            if([int64]($endTime - $startTime).TotalSeconds -ne $duration) { throw "Row $rowNumber field 'DurationSeconds' does not match StartTime and EndTime." }
            if($tradeDate -ne $startTime.Date) { throw "Row $rowNumber field 'TradeDate' does not match StartTime." }

            $key = '{0}|{1}|{2}' -f $row.AccountNumber,$row.RunID,$row.BasketID
            if(-not $keys.Add($key)) { throw "Row $rowNumber has duplicate basket key '$key'." }
            $rows.Add($row)
        }
    } finally {
        $parser.Close()
        $parser.Dispose()
    }

    return [pscustomobject]@{ Rows=@($rows); RowCount=$rows.Count; Header=($script:SchemaV3Columns -join ',') }
}

Export-ModuleMember -Function Get-MoneyMachineSchemaV3Columns,Get-AmmarTradingCsvIdentity,Read-MoneyMachineBasketsCsv
