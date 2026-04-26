#requires -Version 5.1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------
# MRM Provision MVP - Created by Ali Malik
# ---------------------------------------------------------------------

$script:MRM = [ordered]@{
    ScriptName = 'Meeting Room Manager'
    Version = 'Version 2.3'
    Defaults = [ordered]@{
        RoomSheetName = 'Add New Meeting Rooms'
        TimeZone = 'Cen. Australia Standard Time'
        WorkingHoursTimeZone = 'Cen. Australia Standard Time'
        BookingWindowInDays = 365
        MaximumDurationInMinutes = 1440
        AddOrganizerToSubject = $true
        DeleteComments = $false
        DeleteSubject = $false
        DefaultCalendarPermission = 'LimitedDetails'
        UnlistedRoomListLiteral = 'unlisted'
    }
    Paths = [ordered]@{
        Root = $null
        Logs = $null
        State = $null
        Preview = $null
        Reports = $null
        Results = $null
        Transcript = $null
        MainLog = $null
    }
    Runtime = [ordered]@{
        TranscriptStarted = $false
        ExchangeConnected = $false
        LastCheckResults = @()
    }
}

function Test-MrmIsNullOrWhiteSpace {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    return [string]::IsNullOrWhiteSpace($Value)
}

function Get-MrmTimestamp {
    [CmdletBinding()]
    param()

    return (Get-Date).ToString('yyyyMMdd-HHmmss')
}

function Write-MrmConsole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Gray', 'Green', 'Yellow', 'Red', 'Cyan', 'White')]
        [string]$Colour = 'Gray'
    )

    Write-Host $Message -ForegroundColor $Colour
}

function New-MrmDirectoryIfMissing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        $null = New-Item -Path $Path -ItemType Directory -Force
    }
}

function Initialize-MrmPaths {
    [CmdletBinding()]
    param()

    $root = if (-not (Test-MrmIsNullOrWhiteSpace -Value $PSScriptRoot)) {
        $PSScriptRoot
    }
    else {
        (Get-Location).Path
    }

    $script:MRM.Paths.Root = $root
    $script:MRM.Paths.Logs = Join-Path -Path $root -ChildPath 'logs'
    $script:MRM.Paths.State = Join-Path -Path $root -ChildPath 'state'
    $script:MRM.Paths.Preview = Join-Path -Path $root -ChildPath 'preview'
    $script:MRM.Paths.Reports = Join-Path -Path $root -ChildPath 'reports'
    $script:MRM.Paths.Results = Join-Path -Path $root -ChildPath 'results'
    $script:MRM.Paths.Transcript = Join-Path -Path $script:MRM.Paths.Logs -ChildPath ('Transcript-{0}.log' -f (Get-MrmTimestamp))
    $script:MRM.Paths.MainLog = Join-Path -Path $script:MRM.Paths.Logs -ChildPath 'MRM.log'

    New-MrmDirectoryIfMissing -Path $script:MRM.Paths.Logs
    New-MrmDirectoryIfMissing -Path $script:MRM.Paths.State
    New-MrmDirectoryIfMissing -Path $script:MRM.Paths.Preview
    New-MrmDirectoryIfMissing -Path $script:MRM.Paths.Reports
    New-MrmDirectoryIfMissing -Path $script:MRM.Paths.Results
}

function Start-MrmTranscriptSafe {
    [CmdletBinding()]
    param()

    if (-not $script:MRM.Runtime.TranscriptStarted) {
        Start-Transcript -Path $script:MRM.Paths.Transcript -Append | Out-Null
        $script:MRM.Runtime.TranscriptStarted = $true
    }
}

function Stop-MrmTranscriptSafe {
    [CmdletBinding()]
    param()

    if ($script:MRM.Runtime.TranscriptStarted) {
        try {
            Stop-Transcript | Out-Null
        }
        catch {
            # Ignore transcript stop failures.
        }
        finally {
            $script:MRM.Runtime.TranscriptStarted = $false
        }
    }
}

function Write-MrmLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message

    if (-not (Test-MrmIsNullOrWhiteSpace -Value $script:MRM.Paths.MainLog)) {
        Add-Content -LiteralPath $script:MRM.Paths.MainLog -Value $line -Encoding UTF8
    }

    switch ($Level) {
        'INFO'  { Write-MrmConsole -Message $Message -Colour 'Gray' }
        'WARN'  { Write-MrmConsole -Message $Message -Colour 'Yellow' }
        'ERROR' { Write-MrmConsole -Message $Message -Colour 'Red' }
        'DEBUG' { Write-MrmConsole -Message $Message -Colour 'Cyan' }
    }
}

function Assert-MrmStaMode {
    [CmdletBinding()]
    param()

    $state = [System.Threading.Thread]::CurrentThread.ApartmentState
    if ($state -ne [System.Threading.ApartmentState]::STA) {
        throw 'This script must run in STA mode. Launch with: powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\MRM-Provision.ps1'
    }
}

function Assert-MrmPowerShell51 {
    [CmdletBinding()]
    param()

    if ($PSVersionTable.PSVersion.Major -ne 5) {
        throw 'This script must run in Windows PowerShell 5.1.'
    }
}

function Ensure-MrmExchangeOnlineModule {
    [CmdletBinding()]
    param()

    $moduleName = 'ExchangeOnlineManagement'

    $installed = Get-Module -ListAvailable -Name $moduleName |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $installed) {
        Write-MrmLog -Message "Installing module: $moduleName" -Level 'INFO'
        Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber
    }

    $loaded = Get-Module -Name $moduleName
    if (-not $loaded) {
        Import-Module $moduleName -Force
    }

    Write-MrmLog -Message "Module ready: $moduleName" -Level 'INFO'
}

function Connect-MrmExchangeOnline {
    [CmdletBinding()]
    param()

    if ($script:MRM.Runtime.ExchangeConnected) {
        Write-MrmLog -Message 'Exchange Online already connected.' -Level 'DEBUG'
        return
    }

    Ensure-MrmExchangeOnlineModule

    Write-MrmLog -Message 'Connecting to Exchange Online...' -Level 'INFO'
    Connect-ExchangeOnline -ShowBanner:$false | Out-Null
    $script:MRM.Runtime.ExchangeConnected = $true
    Write-MrmLog -Message 'Connected to Exchange Online.' -Level 'INFO'
}

function Disconnect-MrmExchangeOnlineSafe {
    [CmdletBinding()]
    param()

    if ($script:MRM.Runtime.ExchangeConnected) {
        try {
            Disconnect-ExchangeOnline -Confirm:$false | Out-Null
        }
        catch {
            Write-MrmLog -Message ('Disconnect-ExchangeOnline failed: {0}' -f $_.Exception.Message) -Level 'WARN'
        }
        finally {
            $script:MRM.Runtime.ExchangeConnected = $false
        }
    }
}

function Show-MrmBanner {
    [CmdletBinding()]
    param()

    Clear-Host
    Write-MrmConsole -Message '============================================================' -Colour 'Cyan'
    Write-MrmConsole -Message ('{0} {1}' -f $script:MRM.ScriptName, $script:MRM.Version) -Colour 'Cyan'
    Write-MrmConsole -Message 'Create / Modify / Delete / Check' -Colour 'Cyan'
    Write-MrmConsole -Message 'Exchange Online / workbook-driven provisioning' -Colour 'Cyan'
    Write-MrmConsole -Message '------------------------------------------------------------' -Colour 'Cyan'
    Write-MrmConsole -Message 'Pre-requisites:' -Colour 'Yellow'
    Write-MrmConsole -Message '- Exchange Administrator JIT must be active' -Colour 'Yellow'
    Write-MrmConsole -Message '- Modify (Option 2): Read and Manage admin DL must already exist' -Colour 'Yellow'
    Write-MrmConsole -Message '- Uploaded workbook must meet the required worksheet and column schema' -Colour 'Yellow'
    Write-MrmConsole -Message '============================================================' -Colour 'Cyan'
    Write-Host ''
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Select-MrmWorkbookPath {
    [CmdletBinding()]
    param()

    Assert-MrmStaMode

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Select meeting room workbook'
    $dialog.Filter = 'Excel Workbook (*.xlsx)|*.xlsx|Excel 97-2003 Workbook (*.xls)|*.xls|All Files (*.*)|*.*'
    $dialog.Multiselect = $false
    $dialog.CheckFileExists = $true
    $dialog.CheckPathExists = $true
    $dialog.RestoreDirectory = $true

    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    return $dialog.FileName
}

function Test-MrmChunk1SelfTest {
    [CmdletBinding()]
    param()

    Assert-MrmPowerShell51
    Assert-MrmStaMode
    Initialize-MrmPaths

    if (-not (Test-Path -LiteralPath $script:MRM.Paths.Logs)) {
        throw 'Logs folder was not created.'
    }
    if (-not (Test-Path -LiteralPath $script:MRM.Paths.State)) {
        throw 'State folder was not created.'
    }
    if (-not (Test-Path -LiteralPath $script:MRM.Paths.Preview)) {
        throw 'Preview folder was not created.'
    }
    if (-not (Test-Path -LiteralPath $script:MRM.Paths.Reports)) {
        throw 'Reports folder was not created.'
    }

    Write-MrmLog -Message 'Chunk 1 self-test passed.' -Level 'INFO'
    return $true
}

# ---------------------------------------------------------------------
# MRM Provision MVP - Chunk 2
# Excel COM import, sheet read, schema validation, workbook smoke test
# ---------------------------------------------------------------------

function ConvertFrom-MrmExcelCellValue {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [System.DBNull]) {
        return ''
    }

    $stringValue = [string]$Value
    if ($null -eq $stringValue) {
        return ''
    }

    # Normalise workbook text:
    # - replace CR/LF/TAB with spaces
    # - replace non-breaking space with normal space
    # - remove zero-width / BOM characters
    # - collapse repeated whitespace
    # - trim ends
    $stringValue = $stringValue -replace '[\r\n\t]+', ' '
    $stringValue = $stringValue -replace ([string][char]0x00A0), ' '
    $stringValue = $stringValue -replace '[\u200B\u200C\u200D\uFEFF]', ''
    $stringValue = $stringValue -replace '\s{2,}', ' '

    return $stringValue.Trim()
}

function Release-MrmComObject {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ComObject
    )

    if ($null -ne $ComObject) {
        try {
            [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($ComObject)
        }
        catch {
            # Ignore COM release failures.
        }
    }
}

function Get-MrmWorksheetData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorkbookPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$WorksheetName
    )

    if (-not (Test-Path -LiteralPath $WorkbookPath)) {
        throw "Workbook not found: $WorkbookPath"
    }

    Assert-MrmStaMode

    $excel = $null
    $workbook = $null
    $worksheet = $null
    $usedRange = $null

    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false

        $workbook = $excel.Workbooks.Open($WorkbookPath, $null, $true)
        $worksheet = $null

        foreach ($sheet in $workbook.Worksheets) {
            if ([string]$sheet.Name -eq $WorksheetName) {
                $worksheet = $sheet
                break
            }
            Release-MrmComObject -ComObject $sheet
        }

        if ($null -eq $worksheet) {
            throw "Worksheet not found: $WorksheetName"
        }

        $usedRange = $worksheet.UsedRange
        $rowCount = [int]$usedRange.Rows.Count
        $columnCount = [int]$usedRange.Columns.Count

        if ($rowCount -lt 2) {
            return @()
        }

        $headers = New-Object 'System.Collections.Generic.List[string]'
        for ($col = 1; $col -le $columnCount; $col++) {
            $headerValue = ConvertFrom-MrmExcelCellValue -Value ($usedRange.Cells.Item(1, $col).Text)
            if (Test-MrmIsNullOrWhiteSpace -Value $headerValue) {
                $headerValue = "Column$col"
            }
            $headers.Add($headerValue)
        }

        $rows = New-Object 'System.Collections.Generic.List[object]'

        for ($row = 2; $row -le $rowCount; $row++) {
            $obj = [ordered]@{
                __RowNumber = $row
            }

            $hasAnyValue = $false

            for ($col = 1; $col -le $columnCount; $col++) {
                $header = $headers[$col - 1]
                $cellText = ConvertFrom-MrmExcelCellValue -Value ($usedRange.Cells.Item($row, $col).Text)
                $obj[$header] = $cellText

                if (-not (Test-MrmIsNullOrWhiteSpace -Value $cellText)) {
                    $hasAnyValue = $true
                }
            }

            if ($hasAnyValue) {
                $rows.Add([pscustomobject]$obj)
            }
        }

        return $rows.ToArray()
    }
    finally {
        if ($null -ne $workbook) {
            try {
                $workbook.Close($false) | Out-Null
            }
            catch {
                # Ignore workbook close failures.
            }
        }

        if ($null -ne $excel) {
            try {
                $excel.Quit() | Out-Null
            }
            catch {
                # Ignore Excel quit failures.
            }
        }

        Release-MrmComObject -ComObject $usedRange
        Release-MrmComObject -ComObject $worksheet
        Release-MrmComObject -ComObject $workbook
        Release-MrmComObject -ComObject $excel

        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Get-MrmWorkbookColumnNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows
    )

    $rowArray = @($Rows)

    if ($rowArray.Count -eq 0) {
        return @()
    }

    return @(
        $rowArray[0].PSObject.Properties.Name |
            Where-Object { $_ -ne '__RowNumber' }
    )
}

function Get-MrmRequiredColumns {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation
    )

    switch ($Operation) {
        'Create' {
            # Thin create only needs enough data to create a room mailbox
            # and identify non-room rows that should be ignored.
            return @(
                'Meeting Room Name'
                'Room/Vehicle'
                'Resource Email Address'
            )
        }

        'Modify' {
            # Modify is the finalise / enrich stage and therefore requires
            # the full room workbook schema.
            return @(
                'Meeting Room Name'
                'Room/Vehicle'
                'Resource Email Address'
                'Street'
                'City'
                'Postal Code'
                'Building'
                'Floor'
                'Floor Label'
                'Capacity'
                'Tag1'
                'Tag2'
                'Tag3'
                'Tag4'
                'Tag5'
                'Read and Manage Group'
                'Requires Approval'
                'Room List'
                'Booking Delegate Group'
                'Response'
                'Mail Tip'
            )
        }

        'Delete' {
            return @(
                'Resource Email Address'
            )
        }
    }
}

function Test-MrmWorkbookSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation
    )

    $rowArray = @($Rows)
    $present = @(Get-MrmWorkbookColumnNames -Rows $rowArray)
    $required = @(Get-MrmRequiredColumns -Operation $Operation)

    $missing = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $required) {
        if ($present -notcontains $name) {
            $missing.Add($name)
        }
    }

    return [pscustomobject]@{
        IsValid         = ($missing.Count -eq 0)
        PresentColumns  = $present
        MissingColumns  = $missing.ToArray()
        RequiredColumns = $required
        RowCount        = $rowArray.Count
    }
}

function Import-MrmWorkbookRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkbookPath,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation
    )

    Initialize-MrmPaths

    $rows = @(Get-MrmWorksheetData -WorkbookPath $WorkbookPath -WorksheetName $script:MRM.Defaults.RoomSheetName)
    $schema = Test-MrmWorkbookSchema -Rows $rows -Operation $Operation

    if (-not $schema.IsValid) {
        $missing = ($schema.MissingColumns -join ', ')
        throw "Workbook schema validation failed. Missing columns: $missing"
    }

    Write-MrmLog -Message ("Workbook loaded. Worksheet '{0}' rows: {1}" -f $script:MRM.Defaults.RoomSheetName, @($rows).Count) -Level 'INFO'
    return @($rows)
}

function Show-MrmWorkbookSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows
    )

    $rowArray = @($Rows)
    $columns = @(Get-MrmWorkbookColumnNames -Rows $rowArray)

    Write-Host ''
    Write-MrmConsole -Message 'Workbook summary' -Colour 'Cyan'
    Write-MrmConsole -Message ('Sheet          : {0}' -f $script:MRM.Defaults.RoomSheetName) -Colour 'White'
    Write-MrmConsole -Message ('Data row count : {0}' -f $rowArray.Count) -Colour 'White'
    Write-MrmConsole -Message ('Column count   : {0}' -f $columns.Count) -Colour 'White'
    Write-Host ''

    $preview = $rowArray | Select-Object -First 5
    if ($preview.Count -gt 0) {
        $preview | Format-Table -AutoSize
    }
    else {
        Write-MrmConsole -Message 'No data rows found.' -Colour 'Yellow'
    }

    Write-Host ''
}

function Read-MrmNonEmptyString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [switch]$AllowBack
    )

    while ($true) {
        $fullPrompt = if ($AllowBack) {
            '{0} (or X to go back)' -f $Prompt
        }
        else {
            $Prompt
        }

        $value = Read-Host $fullPrompt

        if ($AllowBack -and -not [string]::IsNullOrWhiteSpace($value)) {
            if ($value.Trim().ToUpperInvariant() -eq 'X') {
                return $null
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }

        Write-MrmConsole -Message 'Value cannot be empty.' -Colour 'Yellow'
    }
}

function New-MrmManualDeleteWorksheetRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PrimarySmtp
    )

    return [pscustomobject]@{
        __RowNumber              = 2
        'Meeting Room Name'      = ''
        'Room/Vehicle'           = ''
        'Resource Email Address' = $PrimarySmtp
        'Street'                 = ''
        'City'                   = ''
        'Postal Code'            = ''
        'Building'               = ''
        'Floor'                  = ''
        'Floor Label'            = ''
        'Capacity'               = ''
        'Tag1'                   = ''
        'Tag2'                   = ''
        'Tag3'                   = ''
        'Tag4'                   = ''
        'Tag5'                   = ''
        'Read and Manage Group'  = ''
        'Requires Approval'      = ''
        'Room List'              = ''
        'Booking Delegate Group' = ''
        'Response'               = ''
        'Mail Tip'               = ''
    }
}

function Get-MrmInputRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation,

        [AllowNull()]
        [string]$WorkbookPath
    )

    if (-not (Test-MrmIsNullOrWhiteSpace -Value $WorkbookPath)) {
        return (Import-MrmWorkbookRows -WorkbookPath $WorkbookPath -Operation $Operation)
    }

    if ($Operation -ne 'Delete') {
        return $null
    }

    Write-Host ''
    Write-MrmConsole -Message 'No workbook selected.' -Colour 'Yellow'
    Write-MrmConsole -Message 'Delete mode can continue with a manual resource email address.' -Colour 'Yellow'
    Write-MrmConsole -Message 'Enter X to go back to the main menu.' -Colour 'Yellow'
    Write-Host ''

    $primarySmtp = Read-MrmNonEmptyString -Prompt 'Enter resource email address' -AllowBack
    if ($null -eq $primarySmtp) {
        return $null
    }

    if (-not (Test-MrmValidSmtp -Value $primarySmtp)) {
        throw "Invalid email address: $primarySmtp"
    }

    return @(
        New-MrmManualDeleteWorksheetRow -PrimarySmtp $primarySmtp
    )
}

function Test-MrmChunk2SelfTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkbookPath,

        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation = 'Create'
    )

    Assert-MrmPowerShell51
    Assert-MrmStaMode
    Initialize-MrmPaths

    $rows = Import-MrmWorkbookRows -WorkbookPath $WorkbookPath -Operation $Operation
    if (@($rows).Count -lt 1) {
        throw 'Workbook loaded, but no data rows were found.'
    }

    $schema = Test-MrmWorkbookSchema -Rows $rows -Operation $Operation
    if (-not $schema.IsValid) {
        throw ('Workbook schema validation failed: {0}' -f ($schema.MissingColumns -join ', '))
    }

    Show-MrmWorkbookSummary -Rows $rows
    Write-MrmLog -Message ('Chunk 2 self-test passed for operation {0}.' -f $Operation) -Level 'INFO'
    return $true
}

# ---------------------------------------------------------------------
# MRM Provision MVP - Chunk 3
# Row normalisation, SMTP extraction, boolean/int parsing, basic validation
# ---------------------------------------------------------------------

function Get-MrmSmtpMatches {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$InputText
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $InputText) {
        return @()
    }

    $pattern = '(?<![A-Za-z0-9._%+\-])([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})(?![A-Za-z0-9._%+\-])'
    $rawMatches = [regex]::Matches($InputText, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

    $results = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($match in $rawMatches) {
        $value = [string]$match.Groups[1].Value
        if (Test-MrmIsNullOrWhiteSpace -Value $value) {
            continue
        }

        $trimmed = $value.Trim()
        if (Test-MrmIsNullOrWhiteSpace -Value $trimmed) {
            continue
        }

        if ($seen.Add($trimmed)) {
            # Preserve the original casing from the workbook / input text.
            $results.Add($trimmed)
        }
    }

    return @($results.ToArray())
}

function Get-MrmSingleSmtpFromCell {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$InputText
    )

    $matches = @(Get-MrmSmtpMatches -InputText $InputText)
    if ($matches.Count -eq 1) {
        return $matches[0]
    }

    return $null
}

function Test-MrmValidSmtp {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $Value) {
        return $false
    }

    $pattern = '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$'
    return ($Value -match $pattern)
}

function ConvertTo-MrmBooleanFromYesNo {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $Value) {
        return $null
    }

    switch -Regex ($Value.Trim()) {
        '^(?i)(yes|y|true|1)$'  { return $true }
        '^(?i)(no|n|false|0)$'  { return $false }
        default                 { return $null }
    }
}

function ConvertTo-MrmNullableInt {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $Value) {
        return $null
    }

    $temp = 0
    if ([int]::TryParse($Value.Trim(), [ref]$temp)) {
        return $temp
    }

    return $null
}

function Get-MrmAliasFromSmtp {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PrimarySmtp
    )

    if (-not (Test-MrmValidSmtp -Value $PrimarySmtp)) {
        return $null
    }

    return ($PrimarySmtp.Split('@')[0])
}

function Get-MrmNormalisedTags {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string[]]$Values
    )

    $list = New-Object 'System.Collections.Generic.List[string]'

    foreach ($value in $Values) {
        if (Test-MrmIsNullOrWhiteSpace -Value $value) {
            continue
        }

        $clean = ConvertFrom-MrmExcelCellValue -Value $value
        if (-not (Test-MrmIsNullOrWhiteSpace -Value $clean)) {
            $list.Add($clean)
        }
    }

    return @($list.ToArray() | Select-Object -Unique)
}

function Test-MrmTagConflict {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string[]]$Tags
    )

    if ($null -eq $Tags -or $Tags.Count -eq 0) {
        return $false
    }

    $normalised = @(
        $Tags |
            Where-Object { -not (Test-MrmIsNullOrWhiteSpace -Value $_) } |
            ForEach-Object { $_.Trim().ToLowerInvariant() }
    )

    if ($normalised.Count -eq 0) {
        return $false
    }

    return (($normalised -contains 'av') -and ($normalised -contains 'no av'))
}

function New-MrmParsedRowObject {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Row
    )

    return [pscustomobject]@{
        RowNumber               = [int]$Row.__RowNumber

        RawMeetingRoomName      = ConvertFrom-MrmExcelCellValue -Value $Row.'Meeting Room Name'
        RawRoomOrVehicle        = ConvertFrom-MrmExcelCellValue -Value $Row.'Room/Vehicle'
        RawResourceEmailAddress = ConvertFrom-MrmExcelCellValue -Value $Row.'Resource Email Address'
        RawStreet               = ConvertFrom-MrmExcelCellValue -Value $Row.'Street'
        RawCity                 = ConvertFrom-MrmExcelCellValue -Value $Row.'City'
        RawPostalCode           = ConvertFrom-MrmExcelCellValue -Value $Row.'Postal Code'
        RawBuilding             = ConvertFrom-MrmExcelCellValue -Value $Row.'Building'
        RawFloor                = ConvertFrom-MrmExcelCellValue -Value $Row.'Floor'
        RawFloorLabel           = ConvertFrom-MrmExcelCellValue -Value $Row.'Floor Label'
        RawCapacity             = ConvertFrom-MrmExcelCellValue -Value $Row.'Capacity'
        RawTag1                 = ConvertFrom-MrmExcelCellValue -Value $Row.'Tag1'
        RawTag2                 = ConvertFrom-MrmExcelCellValue -Value $Row.'Tag2'
        RawTag3                 = ConvertFrom-MrmExcelCellValue -Value $Row.'Tag3'
        RawTag4                 = ConvertFrom-MrmExcelCellValue -Value $Row.'Tag4'
        RawTag5                 = ConvertFrom-MrmExcelCellValue -Value $Row.'Tag5'
        RawReadAndManageGroup   = ConvertFrom-MrmExcelCellValue -Value $Row.'Read and Manage Group'
        RawRequiresApproval     = ConvertFrom-MrmExcelCellValue -Value $Row.'Requires Approval'
        RawRoomList             = ConvertFrom-MrmExcelCellValue -Value $Row.'Room List'
        RawBookingDelegateGroup = ConvertFrom-MrmExcelCellValue -Value $Row.'Booking Delegate Group'
        RawResponse             = ConvertFrom-MrmExcelCellValue -Value $Row.'Response'
        RawMailTip              = ConvertFrom-MrmExcelCellValue -Value $Row.'Mail Tip'

        DisplayName             = $null
        PrimarySmtp             = $null
        Alias                   = $null
        IsRoom                  = $false
        RequiresApproval        = $null
        RoomListName            = $null
        IsUnlisted              = $false
        Building                = $null
        Floor                   = $null
        FloorLabel              = $null
        Capacity                = $null
        Street                  = $null
        City                    = $null
        PostalCode              = $null
        Tags                    = @()
        AdminDl                 = $null
        DelegateDl              = $null
        Response                = $null
        MailTip                 = $null

        Errors                  = @()
        Warnings                = @()
    }
}

function Add-MrmParsedRowError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ParsedRow,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($existing in @($ParsedRow.Errors)) {
        if (-not (Test-MrmIsNullOrWhiteSpace -Value $existing)) {
            $list.Add([string]$existing)
        }
    }
    $list.Add($Message)
    $ParsedRow.Errors = @($list.ToArray() | Select-Object -Unique)
}

function Add-MrmParsedRowWarning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ParsedRow,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($existing in @($ParsedRow.Warnings)) {
        if (-not (Test-MrmIsNullOrWhiteSpace -Value $existing)) {
            $list.Add([string]$existing)
        }
    }
    $list.Add($Message)
    $ParsedRow.Warnings = @($list.ToArray() | Select-Object -Unique)
}

function ConvertTo-MrmParsedRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Row,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation
    )

    $item = New-MrmParsedRowObject -Row $Row

    $item.DisplayName = $item.RawMeetingRoomName
    $item.PrimarySmtp = Get-MrmSingleSmtpFromCell -InputText $item.RawResourceEmailAddress
    $item.Alias = Get-MrmAliasFromSmtp -PrimarySmtp $item.PrimarySmtp

    if ($Operation -eq 'Delete') {
        $item.IsRoom = $true
    }
    else {
        $item.IsRoom = ($item.RawRoomOrVehicle -match '^(?i)\s*Room\s*$')
    }

    $item.RequiresApproval = ConvertTo-MrmBooleanFromYesNo -Value $item.RawRequiresApproval
    $item.RoomListName = if (Test-MrmIsNullOrWhiteSpace -Value $item.RawRoomList) { $null } else { $item.RawRoomList.Trim() }
    $item.IsUnlisted = $false
    if (-not (Test-MrmIsNullOrWhiteSpace -Value $item.RoomListName)) {
        $item.IsUnlisted = ($item.RoomListName.Trim().ToLowerInvariant() -eq $script:MRM.Defaults.UnlistedRoomListLiteral.ToLowerInvariant())
    }

    $item.Building = $item.RawBuilding
    $item.Floor = ConvertTo-MrmNullableInt -Value $item.RawFloor
    $item.FloorLabel = $item.RawFloorLabel
    $item.Capacity = ConvertTo-MrmNullableInt -Value $item.RawCapacity
    $item.Street = $item.RawStreet
    $item.City = $item.RawCity
    $item.PostalCode = $item.RawPostalCode
    $item.Tags = @(Get-MrmNormalisedTags -Values @($item.RawTag1, $item.RawTag2, $item.RawTag3, $item.RawTag4, $item.RawTag5))
    $item.AdminDl = if (Test-MrmIsNullOrWhiteSpace -Value $item.RawReadAndManageGroup) { $null } else { $item.RawReadAndManageGroup.Trim() }
    $item.DelegateDl = if (Test-MrmIsNullOrWhiteSpace -Value $item.RawBookingDelegateGroup) { $null } else { $item.RawBookingDelegateGroup.Trim() }
    $item.Response = $item.RawResponse
    $item.MailTip = $item.RawMailTip

    # -----------------------------------------------------------------
    # Validation common to all operations
    # -----------------------------------------------------------------
    if (Test-MrmIsNullOrWhiteSpace -Value $item.RawResourceEmailAddress) {
        Add-MrmParsedRowError -ParsedRow $item -Message 'Resource Email Address is blank.'
    }

    $smtpMatches = @(Get-MrmSmtpMatches -InputText $item.RawResourceEmailAddress)
    if ($smtpMatches.Count -eq 0) {
        Add-MrmParsedRowError -ParsedRow $item -Message 'Could not extract a single SMTP address from Resource Email Address.'
    }
    elseif ($smtpMatches.Count -gt 1) {
        Add-MrmParsedRowError -ParsedRow $item -Message 'Multiple SMTP addresses detected in Resource Email Address.'
    }
    elseif (-not (Test-MrmValidSmtp -Value $item.PrimarySmtp)) {
        Add-MrmParsedRowError -ParsedRow $item -Message 'Extracted SMTP address is invalid.'
    }

    # -----------------------------------------------------------------
    # Delete validation
    # -----------------------------------------------------------------
    if ($Operation -eq 'Delete') {
        if (Test-MrmIsNullOrWhiteSpace -Value $item.DisplayName) {
            $item.DisplayName = $item.PrimarySmtp
        }

        if ($null -eq $item.RequiresApproval) {
            $item.RequiresApproval = $false
        }

        return $item
    }

    # -----------------------------------------------------------------
    # Create validation (thin create only)
    # -----------------------------------------------------------------
    if ($Operation -eq 'Create') {
        if (Test-MrmIsNullOrWhiteSpace -Value $item.RawMeetingRoomName) {
            Add-MrmParsedRowError -ParsedRow $item -Message 'Meeting Room Name is blank.'
        }

        if (-not $item.IsRoom) {
            Add-MrmParsedRowWarning -ParsedRow $item -Message 'Row is not a Room and will be ignored later.'
        }

        return $item
    }

    # -----------------------------------------------------------------
    # Modify validation (finalise / enrich)
    # -----------------------------------------------------------------
    if (Test-MrmIsNullOrWhiteSpace -Value $item.RawMeetingRoomName) {
        Add-MrmParsedRowError -ParsedRow $item -Message 'Meeting Room Name is blank.'
    }

    if (-not $item.IsRoom) {
        Add-MrmParsedRowWarning -ParsedRow $item -Message 'Row is not a Room and will be ignored later.'
    }

    if ($null -eq $item.RequiresApproval) {
        Add-MrmParsedRowError -ParsedRow $item -Message 'Requires Approval must be Yes or No.'
    }

    if ((-not (Test-MrmIsNullOrWhiteSpace -Value $item.RawFloor)) -and ($null -eq $item.Floor)) {
        Add-MrmParsedRowError -ParsedRow $item -Message 'Floor is not a valid integer.'
    }

    if ((-not (Test-MrmIsNullOrWhiteSpace -Value $item.RawCapacity)) -and ($null -eq $item.Capacity)) {
        Add-MrmParsedRowError -ParsedRow $item -Message 'Capacity is not a valid integer.'
    }

    if (($null -ne $item.Capacity) -and ($item.Capacity -lt 1)) {
        Add-MrmParsedRowError -ParsedRow $item -Message 'Capacity must be greater than or equal to 1.'
    }

    if (Test-MrmIsNullOrWhiteSpace -Value $item.AdminDl) {
        Add-MrmParsedRowError -ParsedRow $item -Message 'Read and Manage Group is blank.'
    }

    if ($item.RequiresApproval -eq $true -and (Test-MrmIsNullOrWhiteSpace -Value $item.DelegateDl)) {
        Add-MrmParsedRowError -ParsedRow $item -Message 'Requires Approval is Yes but Booking Delegate Group is blank.'
    }

    if (-not (Test-MrmIsNullOrWhiteSpace -Value $item.MailTip)) {
        if ($item.MailTip.Length -gt 175) {
            Add-MrmParsedRowError -ParsedRow $item -Message 'Mail Tip exceeds 175 characters.'
        }
    }

    if (Test-MrmTagConflict -Tags $item.Tags) {
        Add-MrmParsedRowWarning -ParsedRow $item -Message 'Tags contain both AV and no AV.'
    }

    if ($item.IsUnlisted) {
        Add-MrmParsedRowWarning -ParsedRow $item -Message 'Room List is unlisted; Room Finder membership will be skipped later.'
    }

    return $item
}

function ConvertTo-MrmParsedRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Rows,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation
    )

    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $Rows) {
        $results.Add((ConvertTo-MrmParsedRow -Row $row -Operation $Operation))
    }

    return $results.ToArray()
}

function Show-MrmParsedRowsSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$ParsedRows
    )

    $loaded  = $ParsedRows.Count
    $rooms   = 0
    $ignored = 0
    $warning = 0
    $blocked = 0

    foreach ($row in $ParsedRows) {
        if ($row.IsRoom) {
            $rooms++
        }
        else {
            $ignored++
        }

        if ($row.Warnings.Count -gt 0) {
            $warning++
        }

        if ($row.Errors.Count -gt 0) {
            $blocked++
        }
    }

    Write-Host ''
    Write-MrmConsole -Message 'Parsed row summary' -Colour 'Cyan'
    Write-MrmConsole -Message ('Loaded rows : {0}' -f $loaded) -Colour 'White'
    Write-MrmConsole -Message ('Room rows   : {0}' -f $rooms) -Colour 'White'
    Write-MrmConsole -Message ('Ignored     : {0}' -f $ignored) -Colour 'White'
    Write-MrmConsole -Message ('Warnings    : {0}' -f $warning) -Colour 'Yellow'
    Write-MrmConsole -Message ('Blocked     : {0}' -f $blocked) -Colour 'Red'
    Write-Host ''

    $preview = $ParsedRows | Select-Object RowNumber, DisplayName, PrimarySmtp, IsRoom, RequiresApproval, RoomListName,
        @{Name='Warnings';Expression={$_.Warnings.Count}},
        @{Name='Errors';Expression={$_.Errors.Count}}

    $preview | Format-Table -AutoSize
    Write-Host ''
}

function Test-MrmChunk3SelfTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkbookPath,

        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation = 'Create'
    )

    Assert-MrmPowerShell51
    Assert-MrmStaMode
    Initialize-MrmPaths

    $rows = Import-MrmWorkbookRows -WorkbookPath $WorkbookPath -Operation $Operation
    if (@($rows).Count -lt 1) {
        throw 'Workbook loaded, but no data rows were found.'
    }

    $parsedRows = ConvertTo-MrmParsedRows -Rows $rows -Operation $Operation
    if (@($parsedRows).Count -lt 1) {
        throw 'Parsed row collection is empty.'
    }

    Show-MrmParsedRowsSummary -ParsedRows $parsedRows
    Write-MrmLog -Message ('Chunk 3 self-test passed for operation {0}.' -f $Operation) -Level 'INFO'
    return $true
}

# ---------------------------------------------------------------------
# MRM Provision MVP - Chunk 4
# Operation menu, EXO discovery, basic planning, preview summary
# ---------------------------------------------------------------------

function Show-MrmOperationMenu {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-MrmConsole -Message 'Select operation:' -Colour 'Cyan'
    Write-MrmConsole -Message '1. Create meeting room(s)' -Colour 'White'
    Write-MrmConsole -Message '2. Modify meeting room(s)' -Colour 'White'
    Write-MrmConsole -Message '3. Delete meeting room(s)' -Colour 'White'
    Write-MrmConsole -Message '4. Check meeting room(s)' -Colour 'White'
    Write-MrmConsole -Message 'X. Cancel' -Colour 'White'
    Write-Host ''

    while ($true) {
        $choice = (Read-Host 'Choice').Trim().ToUpperInvariant()
        switch ($choice) {
            '1' { return 'Create' }
            '2' { return 'Modify' }
            '3' { return 'Delete' }
            '4' { return 'Check' }
            'X' { return $null }
            default {
                Write-MrmConsole -Message 'Invalid choice.' -Colour 'Yellow'
            }
        }
    }
}

function Get-MrmMailboxSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Identity
    )

    try {
        if (Get-Command -Name Get-EXOMailbox -ErrorAction SilentlyContinue) {
            return (Get-EXOMailbox -Identity $Identity -Properties DisplayName,Alias,PrimarySmtpAddress,RecipientTypeDetails -ErrorAction Stop)
        }

        return (Get-Mailbox -Identity $Identity -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Get-MrmDistributionGroupSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Identity
    )

    try {
        return (Get-DistributionGroup -Identity $Identity -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Copy-MrmParsedRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ParsedRow
    )

    $copy = [pscustomobject]@{
        RowNumber        = $ParsedRow.RowNumber
        DisplayName      = $ParsedRow.DisplayName
        PrimarySmtp      = $ParsedRow.PrimarySmtp
        Alias            = $ParsedRow.Alias
        IsRoom           = $ParsedRow.IsRoom
        RequiresApproval = $ParsedRow.RequiresApproval
        RoomListName     = $ParsedRow.RoomListName
        IsUnlisted       = $ParsedRow.IsUnlisted
        Building         = $ParsedRow.Building
        Floor            = $ParsedRow.Floor
        FloorLabel       = $ParsedRow.FloorLabel
        Capacity         = $ParsedRow.Capacity
        Street           = $ParsedRow.Street
        City             = $ParsedRow.City
        PostalCode       = $ParsedRow.PostalCode
        Tags             = @($ParsedRow.Tags)
        AdminDl          = $ParsedRow.AdminDl
        DelegateDl       = $ParsedRow.DelegateDl
        Response         = $ParsedRow.Response
        MailTip          = $ParsedRow.MailTip
        Errors           = @($ParsedRow.Errors)
        Warnings         = @($ParsedRow.Warnings)

        ExistsInExo      = $null
        CurrentDisplayName = $null
        RoomListExists   = $null
        Action           = $null
        Risk             = 'Low'
        BlockingReasons  = @()
    }

    return $copy
}

function Add-MrmPlanBlockReason {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($existing in @($PlannedRow.BlockingReasons)) {
        if (-not (Test-MrmIsNullOrWhiteSpace -Value $existing)) {
            $list.Add([string]$existing)
        }
    }
    $list.Add($Message)
    $PlannedRow.BlockingReasons = @($list.ToArray() | Select-Object -Unique)
}

function Update-MrmDiscoveryForRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $PlannedRow.PrimarySmtp) {
        $PlannedRow.ExistsInExo = $false
        return $PlannedRow
    }

    $mailbox = Get-MrmMailboxSafe -Identity $PlannedRow.PrimarySmtp
    if ($null -eq $mailbox) {
        $PlannedRow.ExistsInExo = $false
    }
    else {
        $PlannedRow.ExistsInExo = $true
        if ($mailbox.PSObject.Properties.Name -contains 'DisplayName' -and $null -ne $mailbox.DisplayName) {
            $PlannedRow.CurrentDisplayName = [string]$mailbox.DisplayName
        }
    }

    if (-not (Test-MrmIsNullOrWhiteSpace -Value $PlannedRow.RoomListName) -and (-not $PlannedRow.IsUnlisted)) {
        $group = Get-MrmDistributionGroupSafe -Identity $PlannedRow.RoomListName
        $PlannedRow.RoomListExists = ($null -ne $group)
    }

    return $PlannedRow
}

function ConvertTo-MrmPlannedRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$ParsedRows,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation
    )

    $results = New-Object 'System.Collections.Generic.List[object]'

    foreach ($row in $ParsedRows) {
        $item = Copy-MrmParsedRow -ParsedRow $row
        $item = Update-MrmDiscoveryForRow -PlannedRow $item

        if (-not $item.IsRoom) {
            $item.Action = 'Skip'
            $results.Add($item)
            continue
        }

        if ($item.Errors.Count -gt 0) {
            $item.Action = 'Blocked'
            Add-MrmPlanBlockReason -PlannedRow $item -Message 'Validation failed.'
            $results.Add($item)
            continue
        }

        switch ($Operation) {
            'Create' {
                if ($item.ExistsInExo -eq $true) {
                    $item.Action = 'Skip'
                    $item.Risk = 'Low'
                }
                else {
                    $item.Action = 'Create'
                    if ($item.RoomListExists -eq $false -and -not $item.IsUnlisted) {
                        $item.Risk = 'Medium'
                    }
                }
            }

            'Modify' {
                if ($item.ExistsInExo -eq $true) {
                    $item.Action = 'Modify'
                    $item.Risk = 'Medium'
                }
                else {
                    $item.Action = 'Blocked'
                    Add-MrmPlanBlockReason -PlannedRow $item -Message 'Modify mode does not create missing rooms.'
                }
            }

            'Delete' {
                if ($item.ExistsInExo -eq $true) {
                    $item.Action = 'Delete'
                    $item.Risk = 'High'
                }
                else {
                    $item.Action = 'Skip'
                }
            }
        }

        $results.Add($item)
    }

    return $results.ToArray()
}

function Show-MrmPlannedRowsSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$PlannedRows,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation
    )

    $create = 0
    $modify = 0
    $delete = 0
    $skip   = 0
    $block  = 0

    foreach ($row in $PlannedRows) {
        switch ([string]$row.Action) {
            'Create'  { $create++ }
            'Modify'  { $modify++ }
            'Delete'  { $delete++ }
            'Skip'    { $skip++ }
            'Blocked' { $block++ }
            default   { }
        }
    }

    Write-Host ''
    Write-MrmConsole -Message ('Planned action summary [{0}]' -f $Operation) -Colour 'Cyan'
    Write-MrmConsole -Message ('Create  : {0}' -f $create) -Colour 'White'
    Write-MrmConsole -Message ('Modify  : {0}' -f $modify) -Colour 'White'
    Write-MrmConsole -Message ('Delete  : {0}' -f $delete) -Colour 'White'
    Write-MrmConsole -Message ('Skip    : {0}' -f $skip) -Colour 'Yellow'
    Write-MrmConsole -Message ('Blocked : {0}' -f $block) -Colour 'Red'
    Write-Host ''

    $PlannedRows |
        Select-Object RowNumber, DisplayName, PrimarySmtp, ExistsInExo, RoomListExists, Action, Risk,
            @{Name='Warnings';Expression={$_.Warnings.Count}},
            @{Name='Errors';Expression={$_.Errors.Count}} |
        Format-Table -AutoSize

    Write-Host ''
}

function Get-MrmMailboxDetailsSafe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Identity
    )

    try {
        if (Get-Command -Name Get-EXOMailbox -ErrorAction SilentlyContinue) {
            return (Get-EXOMailbox -Identity $Identity -Properties DisplayName,Alias,PrimarySmtpAddress,RecipientTypeDetails,MailTip -ErrorAction Stop)
        }

        return (Get-Mailbox -Identity $Identity -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Get-MrmMailboxByDisplayNameExact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    try {
        if (Get-Command -Name Get-EXOMailbox -ErrorAction SilentlyContinue) {
            return @(
                Get-EXOMailbox -ResultSize Unlimited -RecipientTypeDetails RoomMailbox,EquipmentMailbox -Properties DisplayName,Alias,PrimarySmtpAddress,RecipientTypeDetails,MailTip -ErrorAction Stop |
                    Where-Object { $_.DisplayName -eq $DisplayName }
            )
        }

        return @(
            Get-Mailbox -ResultSize Unlimited -RecipientTypeDetails RoomMailbox,EquipmentMailbox -ErrorAction Stop |
                Where-Object { $_.DisplayName -eq $DisplayName }
        )
    }
    catch {
        return @()
    }
}

function ConvertTo-MrmFriendlyResourceType {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$RecipientTypeDetails
    )

    switch ([string]$RecipientTypeDetails) {
        'RoomMailbox'      { return 'Room' }
        'EquipmentMailbox' { return 'Vehicle' }
        default            { return [string]$RecipientTypeDetails }
    }
}

function Resolve-MrmRecipientToPrimarySmtpSafe {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Identity
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $Identity) {
        return $null
    }

    $candidate = $Identity.Trim()

    if (Test-MrmValidSmtp -Value $candidate) {
        return $candidate
    }

    try {
        if (Get-Command -Name Get-EXORecipient -ErrorAction SilentlyContinue) {
            $recipient = Get-EXORecipient -Identity $candidate -Properties PrimarySmtpAddress,WindowsEmailAddress,Alias,DisplayName -ErrorAction Stop
        }
        else {
            $recipient = Get-Recipient -Identity $candidate -ErrorAction Stop
        }

        if ($null -ne $recipient) {
            if ($recipient.PSObject.Properties.Name -contains 'PrimarySmtpAddress' -and $null -ne $recipient.PrimarySmtpAddress) {
                $smtp = [string]$recipient.PrimarySmtpAddress
                if (-not (Test-MrmIsNullOrWhiteSpace -Value $smtp)) {
                    return $smtp
                }
            }

            if ($recipient.PSObject.Properties.Name -contains 'WindowsEmailAddress' -and $null -ne $recipient.WindowsEmailAddress) {
                $smtp = [string]$recipient.WindowsEmailAddress
                if (-not (Test-MrmIsNullOrWhiteSpace -Value $smtp)) {
                    return $smtp
                }
            }

            if ($recipient.PSObject.Properties.Name -contains 'Alias' -and $null -ne $recipient.Alias) {
                $alias = [string]$recipient.Alias
                if (Test-MrmValidSmtp -Value $alias) {
                    return $alias
                }
            }
        }
    }
    catch {
        # Ignore resolution failure and fall through.
    }

    return $candidate
}

function Get-MrmDirectFullAccessAssignees {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Identity
    )

    try {
        $rows = @()
        if (Get-Command -Name Get-EXOMailboxPermission -ErrorAction SilentlyContinue) {
            $rows = @(Get-EXOMailboxPermission -Identity $Identity -ResultSize Unlimited -ErrorAction Stop)
        }
        else {
            $rows = @(Get-MailboxPermission -Identity $Identity -ErrorAction Stop)
        }

        $results = New-Object 'System.Collections.Generic.List[string]'

        foreach ($row in $rows) {
            $user = $null
            if ($row.PSObject.Properties.Name -contains 'User' -and $null -ne $row.User) {
                $user = [string]$row.User
            }

            if (Test-MrmIsNullOrWhiteSpace -Value $user) {
                continue
            }

            $hasFullAccess = $false
            foreach ($right in @($row.AccessRights)) {
                if ([string]$right -eq 'FullAccess') {
                    $hasFullAccess = $true
                    break
                }
            }

            if (-not $hasFullAccess) {
                continue
            }

            if ($row.PSObject.Properties.Name -contains 'Deny' -and $row.Deny -eq $true) {
                continue
            }

            if ($row.PSObject.Properties.Name -contains 'IsInherited' -and $row.IsInherited -eq $true) {
                continue
            }

            if ($user -match '^(?i)(NT AUTHORITY\\|S-1-5-|DiscoverySearchMailbox|HealthMailbox|SystemMailbox|Microsoft Exchange|Exchange Servers|Organization Management|Administrators|Domain Admins|Enterprise Admins)') {
                continue
            }

            $resolved = Resolve-MrmRecipientToPrimarySmtpSafe -Identity $user
            if (-not (Test-MrmIsNullOrWhiteSpace -Value $resolved)) {
                $results.Add($resolved)
            }
        }

        return @(
            $results.ToArray() |
            Select-Object -Unique |
            Sort-Object
        )
    }
    catch {
        return @()
    }
}

function Get-MrmCalendarDefaultPermissionValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PrimarySmtp
    )

    $calendarIdentity = '{0}:\Calendar' -f $PrimarySmtp

    try {
        $perm = Get-MailboxFolderPermission -Identity $calendarIdentity -User Default -ErrorAction Stop
        if ($null -eq $perm) {
            return $null
        }

        return ((@($perm.AccessRights) | ForEach-Object { [string]$_ }) -join ', ')
    }
    catch {
        return $null
    }
}

function Get-MrmRoomListMembershipNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PrimarySmtp
    )

    try {
        $groups = @(
            Get-DistributionGroup -ResultSize Unlimited -WarningAction SilentlyContinue -ErrorAction Stop |
            Where-Object { $_.RecipientTypeDetails -eq 'RoomList' }
        )

        $results = New-Object 'System.Collections.Generic.List[string]'

        foreach ($group in $groups) {
            $identity = $null

            if ($group.PSObject.Properties.Name -contains 'Identity' -and $null -ne $group.Identity) {
                $identity = [string]$group.Identity
            }
            elseif ($group.PSObject.Properties.Name -contains 'Name' -and $null -ne $group.Name) {
                $identity = [string]$group.Name
            }

            if (Test-MrmIsNullOrWhiteSpace -Value $identity) {
                continue
            }

            if (Test-MrmRoomListMembership -GroupIdentity $identity -MemberIdentity $PrimarySmtp) {
                if ($group.PSObject.Properties.Name -contains 'DisplayName' -and -not (Test-MrmIsNullOrWhiteSpace -Value ([string]$group.DisplayName))) {
                    $results.Add([string]$group.DisplayName)
                }
                else {
                    $results.Add($identity)
                }
            }
        }

        return @(
            $results.ToArray() |
            Select-Object -Unique |
            Sort-Object
        )
    }
    catch {
        return @()
    }
}

function Import-MrmCheckWorkbookRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkbookPath
    )

    Initialize-MrmPaths

    $rows = @(Get-MrmWorksheetData -WorkbookPath $WorkbookPath -WorksheetName $script:MRM.Defaults.RoomSheetName)
    $columns = @(Get-MrmWorkbookColumnNames -Rows $rows)

    $hasDisplayNameColumn = ($columns -contains 'Meeting Room Name')
    $hasSmtpColumn = ($columns -contains 'Resource Email Address')

    if (-not $hasDisplayNameColumn -and -not $hasSmtpColumn) {
        throw "Check mode workbook requires at least one of these columns: 'Meeting Room Name' or 'Resource Email Address'."
    }

    Write-MrmLog -Message ("Check workbook loaded. Worksheet '{0}' rows: {1}" -f $script:MRM.Defaults.RoomSheetName, @($rows).Count) -Level 'INFO'
    return @($rows)
}

function New-MrmManualCheckLookupRow {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$DisplayName,

        [AllowNull()]
        [string]$PrimarySmtp
    )

    return [pscustomobject]@{
        __RowNumber              = 2
        'Meeting Room Name'      = if ($null -eq $DisplayName) { '' } else { $DisplayName }
        'Resource Email Address' = if ($null -eq $PrimarySmtp) { '' } else { $PrimarySmtp }
        '__Source'               = 'Manual'
    }
}

function Get-MrmCheckInputRows {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$WorkbookPath
    )

    if (-not (Test-MrmIsNullOrWhiteSpace -Value $WorkbookPath)) {
        return @(Import-MrmCheckWorkbookRows -WorkbookPath $WorkbookPath)
    }

    Write-Host ''
    Write-MrmConsole -Message 'No workbook selected.' -Colour 'Yellow'
    Write-MrmConsole -Message 'Check mode can continue with manual lookup.' -Colour 'Yellow'
    Write-Host ''

    Write-MrmConsole -Message 'Select lookup type:' -Colour 'Cyan'
    Write-MrmConsole -Message '1. Resource email address / SMTP' -Colour 'White'
    Write-MrmConsole -Message '2. Display name' -Colour 'White'
    Write-MrmConsole -Message 'X. Back to main menu' -Colour 'White'
    Write-Host ''

    while ($true) {
        $choice = (Read-Host 'Choice').Trim().ToUpperInvariant()

        switch ($choice) {
            '1' {
                $smtp = Read-MrmNonEmptyString -Prompt 'Enter resource email address / SMTP' -AllowBack
                if ($null -eq $smtp) {
                    return $null
                }

                if (-not (Test-MrmValidSmtp -Value $smtp)) {
                    throw "Invalid email address: $smtp"
                }

                return @(
                    New-MrmManualCheckLookupRow -DisplayName $null -PrimarySmtp $smtp
                )
            }

            '2' {
                $displayName = Read-MrmNonEmptyString -Prompt 'Enter display name' -AllowBack
                if ($null -eq $displayName) {
                    return $null
                }

                return @(
                    New-MrmManualCheckLookupRow -DisplayName $displayName -PrimarySmtp $null
                )
            }

            'X' {
                return $null
            }

            default {
                Write-MrmConsole -Message 'Invalid choice.' -Colour 'Yellow'
            }
        }
    }
}

function ConvertTo-MrmComparableText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    if ($Value -is [System.Array]) {
        $items = @($Value | ForEach-Object { ConvertTo-MrmComparableText -Value $_ } | Where-Object { -not (Test-MrmIsNullOrWhiteSpace -Value $_) } | Sort-Object)
        return ($items -join '; ')
    }

    if ($Value -is [bool]) {
        if ($Value) { return 'True' }
        return 'False'
    }

    return ([string]$Value).Trim()
}

function Test-MrmComparableMatch {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Expected,

        [AllowNull()]
        [object]$Actual
    )

    $expectedText = ConvertTo-MrmComparableText -Value $Expected
    $actualText = ConvertTo-MrmComparableText -Value $Actual

    return ($expectedText.Trim().ToLowerInvariant() -eq $actualText.Trim().ToLowerInvariant())
}

function Write-MrmCheckExpectedActualLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [AllowNull()]
        [object]$Expected,

        [AllowNull()]
        [object]$Actual
    )

    $expectedText = ConvertTo-MrmComparableText -Value $Expected
    $actualText = ConvertTo-MrmComparableText -Value $Actual

    if (Test-MrmIsNullOrWhiteSpace -Value $expectedText) {
        $expectedText = '<not supplied>'
    }

    if (Test-MrmIsNullOrWhiteSpace -Value $actualText) {
        $actualText = '<blank>'
    }

    $match = Test-MrmComparableMatch -Expected $Expected -Actual $Actual
    $colour = if ($match) { 'Green' } else { 'Yellow' }

    Write-MrmConsole -Message ('{0} :: Expected = {1} :: Actual = {2}' -f $Label, $expectedText, $actualText) -Colour $colour
}

function Write-MrmCheckActualLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [AllowNull()]
        [object]$Actual
    )

    $actualText = ConvertTo-MrmComparableText -Value $Actual
    if (Test-MrmIsNullOrWhiteSpace -Value $actualText) {
        $actualText = '<blank>'
    }

    Write-MrmConsole -Message ('{0} :: {1}' -f $Label, $actualText) -Colour 'White'
}

function Get-MrmCheckResultExportSmtp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    if (-not (Test-MrmIsNullOrWhiteSpace -Value $Result.ActualPrimarySmtp)) {
        return [string]$Result.ActualPrimarySmtp
    }

    if (-not (Test-MrmIsNullOrWhiteSpace -Value $Result.ExpectedPrimarySmtp)) {
        return [string]$Result.ExpectedPrimarySmtp
    }

    return ('Row{0}' -f $Result.RowNumber)
}

function ConvertTo-MrmSafeFileNamePart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $escaped = [regex]::Escape((-join $invalidChars))
    $safe = [regex]::Replace($Value, "[{0}]" -f $escaped, '_')

    if (Test-MrmIsNullOrWhiteSpace -Value $safe) {
        return 'unknown'
    }

    return $safe
}

function Get-MrmCheckResultActualOnlyLines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Result
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'

    $lines.Add('============================================================')
    $lines.Add('MEETING ROOM CHECK RESULTS')
    $lines.Add('============================================================')
    $lines.Add(('Generated: {0}' -f (Get-Date).ToString('dd/MM/yyyy HH:mm:ss')))
    $lines.Add(('Source = {0}' -f $Result.Source))
    $lines.Add(('Row Number = {0}' -f $Result.RowNumber))
    $lines.Add('')

    if ($Result.Ambiguous) {
        $lines.Add('Lookup Result = Ambiguous display name match')
        foreach ($match in @($Result.AmbiguousMatches)) {
            $lines.Add(('Candidate = {0} | {1}' -f $match.DisplayName, $match.PrimarySmtp))
        }
        return @($lines.ToArray())
    }

    if (-not $Result.Found) {
        $lines.Add('Lookup Result = Not found in Exchange Online')
        if (-not (Test-MrmIsNullOrWhiteSpace -Value $Result.ExpectedPrimarySmtp)) {
            $lines.Add(('Lookup SMTP = {0}' -f $Result.ExpectedPrimarySmtp))
        }
        if (-not (Test-MrmIsNullOrWhiteSpace -Value $Result.ExpectedDisplayName)) {
            $lines.Add(('Lookup Display Name = {0}' -f $Result.ExpectedDisplayName))
        }
        return @($lines.ToArray())
    }

    $lines.Add(('Lookup Result = Found'))
    $lines.Add('')

    $lines.Add('Business View')
    $lines.Add('-------------')
    $lines.Add(('Name = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualDisplayName)))
    $lines.Add(('Primary SMTP = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualPrimarySmtp)))
    $lines.Add(('Type = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualType)))
    $lines.Add(('Street = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualStreet)))
    $lines.Add(('City = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualCity)))
    $lines.Add(('Postal Code = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualPostalCode)))
    $lines.Add(('Building = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualBuilding)))
    $lines.Add(('Floor = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualFloor)))
    $lines.Add(('Floor Label = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualFloorLabel)))
    $lines.Add(('Capacity = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualCapacity)))
    $lines.Add(('Tags = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualTags)))
    $lines.Add(('Read and Manage Group = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualReadManageGroups)))
    $lines.Add(('Booking Delegate Group = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualBookingDelegateGroups)))
    $lines.Add(('Requires Approval = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualRequiresApproval)))
    $lines.Add(('Room Lists Found = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualRoomLists)))
    $lines.Add(('Response = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualResponse)))
    $lines.Add(('Mail Tip = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualMailTip)))
    $lines.Add('')

    $lines.Add('Booking Delegate Settings')
    $lines.Add('-------------------------')
    $lines.Add(('Mailbox TimeZone = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualMailboxTimeZone)))
    $lines.Add(('WorkingHoursTimeZone = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualWorkingHoursTimeZone)))
    $lines.Add(('BookingWindowInDays = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualBookingWindowInDays)))
    $lines.Add(('Maximum duration (hours) = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualMaximumDurationInHours)))
    $lines.Add(('AddOrganizerToSubject = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualAddOrganizerToSubject)))
    $lines.Add(('DeleteComments = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualDeleteComments)))
    $lines.Add(('DeleteSubject = {0}' -f (ConvertTo-MrmComparableText -Value $Result.ActualDeleteSubject)))

    return @($lines.ToArray())
}

function Export-MrmCheckResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Results
    )

    Initialize-MrmPaths

    $exportedFiles = New-Object 'System.Collections.Generic.List[string]'

    foreach ($result in @($Results)) {
        $smtpBase = Get-MrmCheckResultExportSmtp -Result $result
        $safeBase = ConvertTo-MrmSafeFileNamePart -Value $smtpBase
        $fileName = '{0}_results.txt' -f $safeBase
        $fullPath = Join-Path -Path $script:MRM.Paths.Results -ChildPath $fileName

        $lines = @(Get-MrmCheckResultActualOnlyLines -Result $result)

        Set-Content -LiteralPath $fullPath -Value $lines -Encoding UTF8
        $exportedFiles.Add($fullPath)
    }

    return @($exportedFiles.ToArray())
}

function Wait-MrmCheckReturnToMainMenu {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-MrmConsole -Message 'Press Y to export results, or any other key to return to the main menu...' -Colour 'Cyan'
    $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

    if ($null -ne $key -and $key.Character.ToString().ToUpperInvariant() -eq 'Y') {
        $results = @($script:MRM.Runtime.LastCheckResults)

        if ($results.Count -eq 0) {
            Write-Host ''
            Write-MrmConsole -Message 'No check results are available to export.' -Colour 'Yellow'
            Write-MrmConsole -Message 'Press any key to return to the main menu...' -Colour 'Cyan'
            $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            return
        }

        $files = @(Export-MrmCheckResults -Results $results)

        Write-Host ''
        Write-MrmConsole -Message ('Result file(s) successfully generated: {0}' -f $files.Count) -Colour 'Green'
        foreach ($file in $files) {
            Write-MrmConsole -Message $file -Colour 'White'
        }

        Write-Host ''
        Write-MrmConsole -Message 'Press any key to return to the main menu...' -Colour 'Cyan'
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        return
    }
}

function Resolve-MrmCheckRoomResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Row
    )

    $expectedDisplayName = ConvertFrom-MrmExcelCellValue -Value $Row.'Meeting Room Name'
    $expectedPrimarySmtp = ConvertFrom-MrmExcelCellValue -Value $Row.'Resource Email Address'
    $expectedStreet = if ($Row.PSObject.Properties.Name -contains 'Street') { ConvertFrom-MrmExcelCellValue -Value $Row.'Street' } else { '' }
    $expectedCity = if ($Row.PSObject.Properties.Name -contains 'City') { ConvertFrom-MrmExcelCellValue -Value $Row.'City' } else { '' }
    $expectedPostalCode = if ($Row.PSObject.Properties.Name -contains 'Postal Code') { ConvertFrom-MrmExcelCellValue -Value $Row.'Postal Code' } else { '' }
    $expectedBuilding = if ($Row.PSObject.Properties.Name -contains 'Building') { ConvertFrom-MrmExcelCellValue -Value $Row.'Building' } else { '' }
    $expectedFloor = if ($Row.PSObject.Properties.Name -contains 'Floor') { ConvertFrom-MrmExcelCellValue -Value $Row.'Floor' } else { '' }
    $expectedFloorLabel = if ($Row.PSObject.Properties.Name -contains 'Floor Label') { ConvertFrom-MrmExcelCellValue -Value $Row.'Floor Label' } else { '' }
    $expectedCapacity = if ($Row.PSObject.Properties.Name -contains 'Capacity') { ConvertFrom-MrmExcelCellValue -Value $Row.'Capacity' } else { '' }
    $expectedReadManageGroup = if ($Row.PSObject.Properties.Name -contains 'Read and Manage Group') { ConvertFrom-MrmExcelCellValue -Value $Row.'Read and Manage Group' } else { '' }
    $expectedRequiresApprovalRaw = if ($Row.PSObject.Properties.Name -contains 'Requires Approval') { ConvertFrom-MrmExcelCellValue -Value $Row.'Requires Approval' } else { '' }
    $expectedRoomList = if ($Row.PSObject.Properties.Name -contains 'Room List') { ConvertFrom-MrmExcelCellValue -Value $Row.'Room List' } else { '' }
    $expectedBookingDelegateGroup = if ($Row.PSObject.Properties.Name -contains 'Booking Delegate Group') { ConvertFrom-MrmExcelCellValue -Value $Row.'Booking Delegate Group' } else { '' }
    $expectedResponse = if ($Row.PSObject.Properties.Name -contains 'Response') { ConvertFrom-MrmExcelCellValue -Value $Row.'Response' } else { '' }
    $expectedMailTip = if ($Row.PSObject.Properties.Name -contains 'Mail Tip') { ConvertFrom-MrmExcelCellValue -Value $Row.'Mail Tip' } else { '' }
    $expectedRoomOrVehicle = if ($Row.PSObject.Properties.Name -contains 'Room/Vehicle') { ConvertFrom-MrmExcelCellValue -Value $Row.'Room/Vehicle' } else { '' }

    $expectedTags = @()
    $tagColumns = @('Tag1', 'Tag2', 'Tag3', 'Tag4', 'Tag5')
    $tagValues = New-Object 'System.Collections.Generic.List[string]'
    foreach ($tagColumn in $tagColumns) {
        if ($Row.PSObject.Properties.Name -contains $tagColumn) {
            $tagValues.Add((ConvertFrom-MrmExcelCellValue -Value $Row.$tagColumn))
        }
    }
    $expectedTags = @(Get-MrmNormalisedTags -Values @($tagValues.ToArray()))

    $expectedRequiresApproval = ''
    $expectedRequiresApprovalBool = ConvertTo-MrmBooleanFromYesNo -Value $expectedRequiresApprovalRaw
    if ($null -eq $expectedRequiresApprovalBool) {
        $expectedRequiresApproval = ''
    }
    elseif ($expectedRequiresApprovalBool) {
        $expectedRequiresApproval = 'Yes'
    }
    else {
        $expectedRequiresApproval = 'No'
    }

    $source = if ($Row.PSObject.Properties.Name -contains '__Source' -and -not (Test-MrmIsNullOrWhiteSpace -Value ([string]$Row.__Source))) {
        [string]$Row.__Source
    }
    else {
        'Workbook'
    }

    $mailbox = $null
    $ambiguousMatches = @()
    $found = $false
    $ambiguous = $false

    if (-not (Test-MrmIsNullOrWhiteSpace -Value $expectedPrimarySmtp)) {
        $mailbox = Get-MrmMailboxDetailsSafe -Identity $expectedPrimarySmtp
    }
    elseif (-not (Test-MrmIsNullOrWhiteSpace -Value $expectedDisplayName)) {
        $matches = @(Get-MrmMailboxByDisplayNameExact -DisplayName $expectedDisplayName)
        if ($matches.Count -eq 1) {
            $mailbox = $matches[0]
        }
        elseif ($matches.Count -gt 1) {
            $ambiguous = $true
            foreach ($match in $matches) {
                $ambiguousMatches += [pscustomobject]@{
                    DisplayName = if ($match.PSObject.Properties.Name -contains 'DisplayName') { [string]$match.DisplayName } else { '' }
                    PrimarySmtp = if ($match.PSObject.Properties.Name -contains 'PrimarySmtpAddress' -and $null -ne $match.PrimarySmtpAddress) { [string]$match.PrimarySmtpAddress } else { '' }
                }
            }
        }
    }

    if ($null -ne $mailbox) {
        $found = $true
    }

    $place = $null
    $calendarProcessing = $null
    $regional = $null
    $calendarConfig = $null
    $fullAccessAssignees = @()
    $calendarDefaultPermission = $null
    $roomLists = @()
    $actualBookingDelegates = @()
    $actualResponse = ''
    $actualMailTip = ''

    if ($found) {
        $identityForLookups = if ($mailbox.PSObject.Properties.Name -contains 'PrimarySmtpAddress' -and $null -ne $mailbox.PrimarySmtpAddress) {
            [string]$mailbox.PrimarySmtpAddress
        }
        else {
            [string]$mailbox.Identity
        }

        try {
            $place = Get-Place -Identity $identityForLookups -ErrorAction Stop
        }
        catch {
            $place = $null
        }

        try {
            $calendarProcessing = Get-CalendarProcessing -Identity $identityForLookups -ErrorAction Stop
        }
        catch {
            $calendarProcessing = $null
        }

        try {
            $regional = Get-MailboxRegionalConfiguration -Identity $identityForLookups -ErrorAction Stop
        }
        catch {
            $regional = $null
        }

        try {
            $calendarConfig = Get-MailboxCalendarConfiguration -Identity $identityForLookups -ErrorAction Stop -WarningAction SilentlyContinue
        }
        catch {
            $calendarConfig = $null
        }

        $fullAccessAssignees = @(Get-MrmDirectFullAccessAssignees -Identity $identityForLookups)
        $calendarDefaultPermission = Get-MrmCalendarDefaultPermissionValue -PrimarySmtp $identityForLookups
        $roomLists = @(Get-MrmRoomListMembershipNames -PrimarySmtp $identityForLookups)

        if ($null -ne $calendarProcessing) {
            $actualBookingDelegates = @(
                $calendarProcessing.ResourceDelegates |
                ForEach-Object { Resolve-MrmRecipientToPrimarySmtpSafe -Identity ([string]$_) } |
                Where-Object { -not (Test-MrmIsNullOrWhiteSpace -Value $_) } |
                Select-Object -Unique
            )

            if ($calendarProcessing.AddAdditionalResponse -eq $true -and -not (Test-MrmIsNullOrWhiteSpace -Value ([string]$calendarProcessing.AdditionalResponse))) {
                $actualResponse = [string]$calendarProcessing.AdditionalResponse
            }
        }

        if ($mailbox.PSObject.Properties.Name -contains 'MailTip' -and $null -ne $mailbox.MailTip) {
            $actualMailTip = [string]$mailbox.MailTip
        }
    }

    $actualType = if ($found) {
        if ($mailbox.PSObject.Properties.Name -contains 'RecipientTypeDetails' -and $null -ne $mailbox.RecipientTypeDetails) {
            ConvertTo-MrmFriendlyResourceType -RecipientTypeDetails ([string]$mailbox.RecipientTypeDetails)
        }
        else {
            ''
        }
    }
    else {
        ''
    }

    $actualRequiresApproval = ''
    if ($null -ne $calendarProcessing) {
        $requiresApproval = $false
        if (@($calendarProcessing.ResourceDelegates).Count -gt 0) { $requiresApproval = $true }
        if ($calendarProcessing.AllRequestInPolicy -eq $true) { $requiresApproval = $true }
        if ($calendarProcessing.ForwardRequestsToDelegates -eq $true) { $requiresApproval = $true }
        if ($requiresApproval) {
            $actualRequiresApproval = 'Yes'
        }
        else {
            $actualRequiresApproval = 'No'
        }
    }

    $actualMaximumDurationInMinutes = ''
    $actualMaximumDurationInHours = ''

    if ($null -ne $calendarProcessing -and
        $calendarProcessing.PSObject.Properties.Name -contains 'MaximumDurationInMinutes' -and
        $null -ne $calendarProcessing.MaximumDurationInMinutes) {

        $actualMaximumDurationInMinutes = [int]$calendarProcessing.MaximumDurationInMinutes
        $actualMaximumDurationInHours = [math]::Round(([double]$actualMaximumDurationInMinutes / 60), 2)
    }

    return [pscustomobject]@{
        RowNumber = [int]$Row.__RowNumber
        Source = $source

        ExpectedDisplayName = $expectedDisplayName
        ExpectedPrimarySmtp = $expectedPrimarySmtp
        ExpectedType = $expectedRoomOrVehicle
        ExpectedStreet = $expectedStreet
        ExpectedCity = $expectedCity
        ExpectedPostalCode = $expectedPostalCode
        ExpectedBuilding = $expectedBuilding
        ExpectedFloor = $expectedFloor
        ExpectedFloorLabel = $expectedFloorLabel
        ExpectedCapacity = $expectedCapacity
        ExpectedTags = @($expectedTags)
        ExpectedReadManageGroup = $expectedReadManageGroup
        ExpectedBookingDelegateGroup = $expectedBookingDelegateGroup
        ExpectedRequiresApproval = $expectedRequiresApproval
        ExpectedRoomList = $expectedRoomList
        ExpectedResponse = $expectedResponse
        ExpectedMailTip = $expectedMailTip
        ExpectedMailboxTimeZone = [string]$script:MRM.Defaults.TimeZone
        ExpectedWorkingHoursTimeZone = [string]$script:MRM.Defaults.WorkingHoursTimeZone
        ExpectedBookingWindowInDays = [int]$script:MRM.Defaults.BookingWindowInDays
        ExpectedMaximumDurationInHours = [math]::Round(([double]$script:MRM.Defaults.MaximumDurationInMinutes / 60), 2)
        ExpectedAddOrganizerToSubject = [bool]$script:MRM.Defaults.AddOrganizerToSubject
        ExpectedDeleteComments = [bool]$script:MRM.Defaults.DeleteComments
        ExpectedDeleteSubject = [bool]$script:MRM.Defaults.DeleteSubject

        Found = $found
        Ambiguous = $ambiguous
        AmbiguousMatches = @($ambiguousMatches)

        ActualDisplayName = if ($found -and $mailbox.PSObject.Properties.Name -contains 'DisplayName') { [string]$mailbox.DisplayName } else { '' }
        ActualPrimarySmtp = if ($found -and $mailbox.PSObject.Properties.Name -contains 'PrimarySmtpAddress' -and $null -ne $mailbox.PrimarySmtpAddress) { [string]$mailbox.PrimarySmtpAddress } else { '' }
        ActualType = $actualType
        ActualStreet = if ($null -ne $place -and $place.PSObject.Properties.Name -contains 'Street') { [string]$place.Street } else { '' }
        ActualCity = if ($null -ne $place -and $place.PSObject.Properties.Name -contains 'City') { [string]$place.City } else { '' }
        ActualPostalCode = if ($null -ne $place -and $place.PSObject.Properties.Name -contains 'PostalCode') { [string]$place.PostalCode } else { '' }
        ActualBuilding = if ($null -ne $place -and $place.PSObject.Properties.Name -contains 'Building') { [string]$place.Building } else { '' }
        ActualFloor = if ($null -ne $place -and $place.PSObject.Properties.Name -contains 'Floor' -and $null -ne $place.Floor) { [string]$place.Floor } else { '' }
        ActualFloorLabel = if ($null -ne $place -and $place.PSObject.Properties.Name -contains 'FloorLabel') { [string]$place.FloorLabel } else { '' }
        ActualCapacity = if ($null -ne $place -and $place.PSObject.Properties.Name -contains 'Capacity' -and $null -ne $place.Capacity) { [string]$place.Capacity } else { '' }
        ActualTags = if ($null -ne $place -and $place.PSObject.Properties.Name -contains 'Tags') {
            @(
                $place.Tags |
                ForEach-Object { [string]$_ }
            )
        }
        else {
            @()
        }
        ActualReadManageGroups = @($fullAccessAssignees)
        ActualBookingDelegateGroups = @($actualBookingDelegates)
        ActualRequiresApproval = $actualRequiresApproval
        ActualRoomLists = @($roomLists)
        ActualResponse = $actualResponse
        ActualMailTip = $actualMailTip
        ActualMailboxTimeZone = if ($null -ne $regional -and $regional.PSObject.Properties.Name -contains 'TimeZone') { [string]$regional.TimeZone } else { '' }
        ActualWorkingHoursTimeZone = if ($null -ne $calendarConfig -and $calendarConfig.PSObject.Properties.Name -contains 'WorkingHoursTimeZone') { [string]$calendarConfig.WorkingHoursTimeZone } else { '' }
        ActualBookingWindowInDays = if ($null -ne $calendarProcessing -and $calendarProcessing.PSObject.Properties.Name -contains 'BookingWindowInDays' -and $null -ne $calendarProcessing.BookingWindowInDays) { [string]$calendarProcessing.BookingWindowInDays } else { '' }
        ActualMaximumDurationInMinutes = $actualMaximumDurationInMinutes
        ActualMaximumDurationInHours = $actualMaximumDurationInHours
        ActualAddOrganizerToSubject = if ($null -ne $calendarProcessing -and $calendarProcessing.PSObject.Properties.Name -contains 'AddOrganizerToSubject') { [bool]$calendarProcessing.AddOrganizerToSubject } else { $null }
        ActualDeleteComments = if ($null -ne $calendarProcessing -and $calendarProcessing.PSObject.Properties.Name -contains 'DeleteComments') { [bool]$calendarProcessing.DeleteComments } else { $null }
        ActualDeleteSubject = if ($null -ne $calendarProcessing -and $calendarProcessing.PSObject.Properties.Name -contains 'DeleteSubject') { [bool]$calendarProcessing.DeleteSubject } else { $null }

        RawRecipientTypeDetails = if ($found -and $mailbox.PSObject.Properties.Name -contains 'RecipientTypeDetails') { [string]$mailbox.RecipientTypeDetails } else { '' }
        RawAutomateProcessing = if ($null -ne $calendarProcessing -and $calendarProcessing.PSObject.Properties.Name -contains 'AutomateProcessing') { [string]$calendarProcessing.AutomateProcessing } else { '' }
        RawAllBookInPolicy = if ($null -ne $calendarProcessing -and $calendarProcessing.PSObject.Properties.Name -contains 'AllBookInPolicy') { [bool]$calendarProcessing.AllBookInPolicy } else { $null }
        RawAllRequestInPolicy = if ($null -ne $calendarProcessing -and $calendarProcessing.PSObject.Properties.Name -contains 'AllRequestInPolicy') { [bool]$calendarProcessing.AllRequestInPolicy } else { $null }
        RawForwardRequestsToDelegates = if ($null -ne $calendarProcessing -and $calendarProcessing.PSObject.Properties.Name -contains 'ForwardRequestsToDelegates') { [bool]$calendarProcessing.ForwardRequestsToDelegates } else { $null }
        RawResourceDelegates = if ($null -ne $calendarProcessing -and $calendarProcessing.PSObject.Properties.Name -contains 'ResourceDelegates') {
            @(
                $calendarProcessing.ResourceDelegates |
                ForEach-Object { Resolve-MrmRecipientToPrimarySmtpSafe -Identity ([string]$_) } |
                Where-Object { -not (Test-MrmIsNullOrWhiteSpace -Value $_) } |
                Select-Object -Unique
            )
        }
        else {
            @()
        }
        RawMaximumDurationInMinutes = if ($null -ne $calendarProcessing -and $calendarProcessing.PSObject.Properties.Name -contains 'MaximumDurationInMinutes' -and $null -ne $calendarProcessing.MaximumDurationInMinutes) { [int]$calendarProcessing.MaximumDurationInMinutes } else { $null }
        RawAddAdditionalResponse = if ($null -ne $calendarProcessing -and $calendarProcessing.PSObject.Properties.Name -contains 'AddAdditionalResponse') { [bool]$calendarProcessing.AddAdditionalResponse } else { $null }
        RawCalendarDefaultPermission = $calendarDefaultPermission
    }
}

function Show-MrmCheckResults {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Results
    )

    Write-Host ''
    Write-MrmConsole -Message 'Check meeting room(s) results' -Colour 'Cyan'
    Write-MrmConsole -Message ('Rows checked : {0}' -f @($Results).Count) -Colour 'White'
    Write-Host ''

    foreach ($result in @($Results)) {
        Write-MrmConsole -Message ('------------------------------------------------------------') -Colour 'Cyan'
        Write-MrmConsole -Message ('Row {0} [{1}]' -f $result.RowNumber, $result.Source) -Colour 'Cyan'

        if ($result.Ambiguous) {
            Write-MrmConsole -Message 'Lookup result : Ambiguous display name match' -Colour 'Red'
            foreach ($match in @($result.AmbiguousMatches)) {
                Write-MrmConsole -Message ('Candidate :: {0} :: {1}' -f $match.DisplayName, $match.PrimarySmtp) -Colour 'Yellow'
            }
            Write-Host ''
            continue
        }

        if (-not $result.Found) {
            Write-MrmConsole -Message 'Lookup result : Not found in Exchange Online' -Colour 'Red'
            if (-not (Test-MrmIsNullOrWhiteSpace -Value $result.ExpectedPrimarySmtp)) {
                Write-MrmConsole -Message ('Lookup SMTP : {0}' -f $result.ExpectedPrimarySmtp) -Colour 'White'
            }
            if (-not (Test-MrmIsNullOrWhiteSpace -Value $result.ExpectedDisplayName)) {
                Write-MrmConsole -Message ('Lookup display name : {0}' -f $result.ExpectedDisplayName) -Colour 'White'
            }
            Write-Host ''
            continue
        }

        Write-MrmConsole -Message ('Lookup result : Found :: {0}' -f $result.ActualPrimarySmtp) -Colour 'Green'
        Write-Host ''

        if ($result.Source -eq 'Workbook') {
            Write-MrmConsole -Message 'Business view [Expected vs Actual]' -Colour 'Cyan'
            Write-MrmCheckExpectedActualLine -Label 'Name' -Expected $result.ExpectedDisplayName -Actual $result.ActualDisplayName
            Write-MrmCheckExpectedActualLine -Label 'Primary SMTP' -Expected $result.ExpectedPrimarySmtp -Actual $result.ActualPrimarySmtp
            Write-MrmCheckExpectedActualLine -Label 'Type' -Expected $result.ExpectedType -Actual $result.ActualType
            Write-MrmCheckExpectedActualLine -Label 'Street' -Expected $result.ExpectedStreet -Actual $result.ActualStreet
            Write-MrmCheckExpectedActualLine -Label 'City' -Expected $result.ExpectedCity -Actual $result.ActualCity
            Write-MrmCheckExpectedActualLine -Label 'Postal Code' -Expected $result.ExpectedPostalCode -Actual $result.ActualPostalCode
            Write-MrmCheckExpectedActualLine -Label 'Building' -Expected $result.ExpectedBuilding -Actual $result.ActualBuilding
            Write-MrmCheckExpectedActualLine -Label 'Floor' -Expected $result.ExpectedFloor -Actual $result.ActualFloor
            Write-MrmCheckExpectedActualLine -Label 'Floor Label' -Expected $result.ExpectedFloorLabel -Actual $result.ActualFloorLabel
            Write-MrmCheckExpectedActualLine -Label 'Capacity' -Expected $result.ExpectedCapacity -Actual $result.ActualCapacity
            Write-MrmCheckExpectedActualLine -Label 'Tags' -Expected $result.ExpectedTags -Actual $result.ActualTags
            Write-MrmCheckExpectedActualLine -Label 'Read and Manage Group' -Expected $result.ExpectedReadManageGroup -Actual $result.ActualReadManageGroups
            Write-MrmCheckExpectedActualLine -Label 'Booking Delegate Group' -Expected $result.ExpectedBookingDelegateGroup -Actual $result.ActualBookingDelegateGroups
            Write-MrmCheckExpectedActualLine -Label 'Requires Approval' -Expected $result.ExpectedRequiresApproval -Actual $result.ActualRequiresApproval
            Write-MrmCheckExpectedActualLine -Label 'Expected Room List' -Expected $result.ExpectedRoomList -Actual $result.ActualRoomLists
            Write-MrmCheckExpectedActualLine -Label 'Response' -Expected $result.ExpectedResponse -Actual $result.ActualResponse
            Write-MrmCheckExpectedActualLine -Label 'Mail Tip' -Expected $result.ExpectedMailTip -Actual $result.ActualMailTip

            Write-MrmConsole -Message 'Booking delegate settings [Expected vs Actual]' -Colour 'Cyan'
            Write-MrmCheckExpectedActualLine -Label 'Mailbox TimeZone' -Expected $result.ExpectedMailboxTimeZone -Actual $result.ActualMailboxTimeZone
            Write-MrmCheckExpectedActualLine -Label 'WorkingHoursTimeZone' -Expected $result.ExpectedWorkingHoursTimeZone -Actual $result.ActualWorkingHoursTimeZone
            Write-MrmCheckExpectedActualLine -Label 'BookingWindowInDays' -Expected $result.ExpectedBookingWindowInDays -Actual $result.ActualBookingWindowInDays
            Write-MrmCheckExpectedActualLine -Label 'Maximum duration (hours)' -Expected $result.ExpectedMaximumDurationInHours -Actual $result.ActualMaximumDurationInHours
            Write-MrmCheckExpectedActualLine -Label 'AddOrganizerToSubject' -Expected $result.ExpectedAddOrganizerToSubject -Actual $result.ActualAddOrganizerToSubject
            Write-MrmCheckExpectedActualLine -Label 'DeleteComments' -Expected $result.ExpectedDeleteComments -Actual $result.ActualDeleteComments
            Write-MrmCheckExpectedActualLine -Label 'DeleteSubject' -Expected $result.ExpectedDeleteSubject -Actual $result.ActualDeleteSubject
        }
        else {
            Write-MrmConsole -Message 'Business view [Actual only]' -Colour 'Cyan'
            Write-MrmCheckActualLine -Label 'Name' -Actual $result.ActualDisplayName
            Write-MrmCheckActualLine -Label 'Primary SMTP' -Actual $result.ActualPrimarySmtp
            Write-MrmCheckActualLine -Label 'Type' -Actual $result.ActualType
            Write-MrmCheckActualLine -Label 'Street' -Actual $result.ActualStreet
            Write-MrmCheckActualLine -Label 'City' -Actual $result.ActualCity
            Write-MrmCheckActualLine -Label 'Postal Code' -Actual $result.ActualPostalCode
            Write-MrmCheckActualLine -Label 'Building' -Actual $result.ActualBuilding
            Write-MrmCheckActualLine -Label 'Floor' -Actual $result.ActualFloor
            Write-MrmCheckActualLine -Label 'Floor Label' -Actual $result.ActualFloorLabel
            Write-MrmCheckActualLine -Label 'Capacity' -Actual $result.ActualCapacity
            Write-MrmCheckActualLine -Label 'Tags' -Actual $result.ActualTags
            Write-MrmCheckActualLine -Label 'Read and Manage Group' -Actual $result.ActualReadManageGroups
            Write-MrmCheckActualLine -Label 'Booking Delegate Group' -Actual $result.ActualBookingDelegateGroups
            Write-MrmCheckActualLine -Label 'Requires Approval' -Actual $result.ActualRequiresApproval
            Write-MrmCheckActualLine -Label 'Room Lists Found' -Actual $result.ActualRoomLists
            Write-MrmCheckActualLine -Label 'Response' -Actual $result.ActualResponse
            Write-MrmCheckActualLine -Label 'Mail Tip' -Actual $result.ActualMailTip

            Write-MrmConsole -Message 'Booking delegate settings [Actual only]' -Colour 'Cyan'
            Write-MrmCheckActualLine -Label 'Mailbox TimeZone' -Actual $result.ActualMailboxTimeZone
            Write-MrmCheckActualLine -Label 'WorkingHoursTimeZone' -Actual $result.ActualWorkingHoursTimeZone
            Write-MrmCheckActualLine -Label 'BookingWindowInDays' -Actual $result.ActualBookingWindowInDays
            Write-MrmCheckActualLine -Label 'Maximum duration (hours)' -Actual $result.ActualMaximumDurationInHours
            Write-MrmCheckActualLine -Label 'AddOrganizerToSubject' -Actual $result.ActualAddOrganizerToSubject
            Write-MrmCheckActualLine -Label 'DeleteComments' -Actual $result.ActualDeleteComments
            Write-MrmCheckActualLine -Label 'DeleteSubject' -Actual $result.ActualDeleteSubject
        }

        Write-Host ''
        Write-MrmConsole -Message 'Optional technical detail' -Colour 'Cyan'
        Write-MrmCheckActualLine -Label 'RecipientTypeDetails' -Actual $result.RawRecipientTypeDetails
        Write-MrmCheckActualLine -Label 'AutomateProcessing' -Actual $result.RawAutomateProcessing
        Write-MrmCheckActualLine -Label 'AllBookInPolicy' -Actual $result.RawAllBookInPolicy
        Write-MrmCheckActualLine -Label 'AllRequestInPolicy' -Actual $result.RawAllRequestInPolicy
        Write-MrmCheckActualLine -Label 'ForwardRequestsToDelegates' -Actual $result.RawForwardRequestsToDelegates
        Write-MrmCheckActualLine -Label 'ResourceDelegates' -Actual $result.RawResourceDelegates
        Write-MrmCheckActualLine -Label 'MaximumDurationInMinutes' -Actual $result.RawMaximumDurationInMinutes
        Write-MrmCheckActualLine -Label 'AddAdditionalResponse' -Actual $result.RawAddAdditionalResponse
        Write-MrmCheckActualLine -Label 'Calendar Default Permission' -Actual $result.RawCalendarDefaultPermission
        Write-Host ''
    }
}

function Invoke-MrmCheckRooms {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WorkbookPath
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $WorkbookPath) {
        $WorkbookPath = $null
    }

    Assert-MrmPowerShell51
    Assert-MrmStaMode
    Initialize-MrmPaths
    Connect-MrmExchangeOnline

    $script:MRM.Runtime.LastCheckResults = @()

    $rows = Get-MrmCheckInputRows -WorkbookPath $WorkbookPath
    if ($null -eq $rows) {
        return 'Back'
    }

    $rows = @($rows)
    if ($rows.Count -eq 0) {
        Write-MrmConsole -Message 'No rows to check.' -Colour 'Yellow'
        return 'Cancelled'
    }

    $results = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $rows) {
        $results.Add((Resolve-MrmCheckRoomResult -Row $row))
    }

    $script:MRM.Runtime.LastCheckResults = @($results.ToArray())

    Show-MrmCheckResults -Results $script:MRM.Runtime.LastCheckResults
    return 'Success'
}

function Invoke-MrmPreviewPlanning {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WorkbookPath,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $WorkbookPath) {
        $WorkbookPath = $null
    }

    Assert-MrmPowerShell51
    Assert-MrmStaMode
    Initialize-MrmPaths
    Connect-MrmExchangeOnline

    try {
        $rows = Get-MrmInputRows -Operation $Operation -WorkbookPath $WorkbookPath
        $parsedRows = ConvertTo-MrmParsedRows -Rows $rows -Operation $Operation
        $plannedRows = ConvertTo-MrmPlannedRows -ParsedRows $parsedRows -Operation $Operation

        Show-MrmParsedRowsSummary -ParsedRows $parsedRows
        Show-MrmPlannedRowsSummary -PlannedRows $plannedRows -Operation $Operation

        return $plannedRows
    }
    finally {
        Disconnect-MrmExchangeOnlineSafe
    }
}

function Test-MrmChunk4SelfTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkbookPath,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation
    )

    $plannedRows = Invoke-MrmPreviewPlanning -WorkbookPath $WorkbookPath -Operation $Operation

    if ($plannedRows.Count -lt 1) {
        throw 'No planned rows were returned.'
    }

    Write-MrmLog -Message ('Chunk 4 self-test passed for operation {0}.' -f $Operation) -Level 'INFO'
    return $true
}

# ---------------------------------------------------------------------
# MRM Provision MVP - Chunk 5
# Create / modify execution helpers and dry-run execution self-test
# ---------------------------------------------------------------------

function Write-MrmWhatIf {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-MrmLog -Message ("WHATIF: {0}" -f $Message) -Level 'INFO'
}

function Wait-MrmMailboxVisible {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Identity,

        [int]$TimeoutSeconds = 180,

        [int]$PollSeconds = 5
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $mbx = Get-MrmMailboxSafe -Identity $Identity
        if ($null -ne $mbx) {
            return $true
        }

        Start-Sleep -Seconds $PollSeconds
    }

    return $false
}

function Test-MrmRoomListMembership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$GroupIdentity,

        [Parameter(Mandatory)]
        [string]$MemberIdentity
    )

    try {
        $members = Get-DistributionGroupMember -Identity $GroupIdentity -ResultSize Unlimited -ErrorAction Stop

        foreach ($member in $members) {
            $candidate = $null

            if ($member.PSObject.Properties.Name -contains 'PrimarySmtpAddress' -and $null -ne $member.PrimarySmtpAddress) {
                $candidate = [string]$member.PrimarySmtpAddress
            }
            elseif ($member.PSObject.Properties.Name -contains 'WindowsEmailAddress' -and $null -ne $member.WindowsEmailAddress) {
                $candidate = [string]$member.WindowsEmailAddress
            }
            elseif ($member.PSObject.Properties.Name -contains 'Name' -and $null -ne $member.Name) {
                $candidate = [string]$member.Name
            }

            if (-not (Test-MrmIsNullOrWhiteSpace -Value $candidate)) {
                if ($candidate.Trim().ToLowerInvariant() -eq $MemberIdentity.Trim().ToLowerInvariant()) {
                    return $true
                }
            }
        }

        return $false
    }
    catch {
        return $false
    }
}

function Ensure-MrmRoomList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RoomListName,

        [switch]$WhatIfMode
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $RoomListName) {
        return
    }

    $existing = Get-MrmDistributionGroupSafe -Identity $RoomListName
    if ($null -ne $existing) {
        return
    }

    if ($WhatIfMode) {
        Write-MrmWhatIf -Message ("Create Room List: {0}" -f $RoomListName)
        return
    }

    Write-MrmLog -Message ("Creating Room List: {0}" -f $RoomListName) -Level 'INFO'
    New-DistributionGroup -Name $RoomListName -RoomList | Out-Null
}

function Ensure-MrmRoomListMembership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RoomListName,

        [Parameter(Mandatory)]
        [string]$PrimarySmtp,

        [switch]$WhatIfMode
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $RoomListName) {
        return
    }

    if (Test-MrmRoomListMembership -GroupIdentity $RoomListName -MemberIdentity $PrimarySmtp) {
        return
    }

    if ($WhatIfMode) {
        Write-MrmWhatIf -Message ("Add room to Room List: {0} -> {1}" -f $PrimarySmtp, $RoomListName)
        return
    }

    Write-MrmLog -Message ("Adding room to Room List: {0} -> {1}" -f $PrimarySmtp, $RoomListName) -Level 'INFO'
    Add-DistributionGroupMember -Identity $RoomListName -Member $PrimarySmtp | Out-Null
}

function New-MrmRoomMailbox {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [switch]$WhatIfMode
    )

    if ($WhatIfMode) {
        Write-MrmWhatIf -Message ("Create room mailbox: {0}" -f $PlannedRow.PrimarySmtp)
        return
    }

    Write-MrmLog -Message ("Creating room mailbox: {0}" -f $PlannedRow.PrimarySmtp) -Level 'INFO'

    New-Mailbox -Name $PlannedRow.DisplayName `
        -DisplayName $PlannedRow.DisplayName `
        -Room `
        -Alias $PlannedRow.Alias `
        -PrimarySmtpAddress $PlannedRow.PrimarySmtp | Out-Null

    $visible = Wait-MrmMailboxVisible -Identity $PlannedRow.PrimarySmtp -TimeoutSeconds 240 -PollSeconds 5
    if (-not $visible) {
        throw "Mailbox not visible after create: $($PlannedRow.PrimarySmtp)"
    }
}

function Set-MrmRoomDisplayName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [switch]$WhatIfMode
    )

    if ($WhatIfMode) {
        Write-MrmWhatIf -Message ("Set mailbox display name: {0} -> {1}" -f $PlannedRow.PrimarySmtp, $PlannedRow.DisplayName)
        return
    }

    Set-Mailbox -Identity $PlannedRow.PrimarySmtp -DisplayName $PlannedRow.DisplayName | Out-Null
}

function Set-MrmPlaceMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [switch]$WhatIfMode
    )

    function Invoke-MrmSetPlaceAction {
        param(
            [Parameter(Mandatory)]
            [string]$PhaseName,

            [Parameter(Mandatory)]
            [scriptblock]$Action
        )

        if ($WhatIfMode) {
            Write-MrmWhatIf -Message ("Set-Place [{0}] for: {1}" -f $PhaseName, $PlannedRow.PrimarySmtp)
            return
        }

        $maxAttempts = 5
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                Write-MrmLog -Message ("Set-Place [{0}] attempt {1}/{2} for {3}" -f $PhaseName, $attempt, $maxAttempts, $PlannedRow.PrimarySmtp) -Level 'INFO'
                & $Action
                return
            }
            catch {
                $msg = $_.Exception.Message

                if ($attempt -lt $maxAttempts) {
                    $sleepSeconds = 5 * $attempt
                    Write-MrmLog -Message ("Set-Place [{0}] failed for {1}: {2}. Retrying in {3}s." -f $PhaseName, $PlannedRow.PrimarySmtp, $msg, $sleepSeconds) -Level 'WARN'
                    Start-Sleep -Seconds $sleepSeconds
                }
                else {
                    Write-MrmLog -Message ("Set-Place [{0}] failed permanently for {1}: {2}" -f $PhaseName, $PlannedRow.PrimarySmtp, $msg) -Level 'ERROR'
                    throw
                }
            }
        }
    }

    $identity = $PlannedRow.PrimarySmtp

    $normalisedStreet = ConvertFrom-MrmExcelCellValue -Value $PlannedRow.Street
    if (-not (Test-MrmIsNullOrWhiteSpace -Value $normalisedStreet)) {
        $normalisedStreet = $normalisedStreet.TrimEnd('.')
    }

    $normalisedCity = ConvertFrom-MrmExcelCellValue -Value $PlannedRow.City
    $normalisedPostalCode = ConvertFrom-MrmExcelCellValue -Value $PlannedRow.PostalCode
    $normalisedBuilding = ConvertFrom-MrmExcelCellValue -Value $PlannedRow.Building
    $normalisedFloorLabel = ConvertFrom-MrmExcelCellValue -Value $PlannedRow.FloorLabel
    $normalisedTags = @(Get-MrmNormalisedTags -Values @($PlannedRow.Tags))

    if (-not (Test-MrmIsNullOrWhiteSpace -Value $normalisedStreet)) {
        Invoke-MrmSetPlaceAction -PhaseName 'Street' -Action {
            Set-Place -Identity $identity -Street $normalisedStreet -ErrorAction Stop | Out-Null
        }
    }

    if (-not (Test-MrmIsNullOrWhiteSpace -Value $normalisedCity)) {
        Invoke-MrmSetPlaceAction -PhaseName 'City' -Action {
            Set-Place -Identity $identity -City $normalisedCity -ErrorAction Stop | Out-Null
        }
    }

    if (-not (Test-MrmIsNullOrWhiteSpace -Value $normalisedPostalCode)) {
        Invoke-MrmSetPlaceAction -PhaseName 'PostalCode' -Action {
            Set-Place -Identity $identity -PostalCode $normalisedPostalCode -ErrorAction Stop | Out-Null
        }
    }

    Invoke-MrmSetPlaceAction -PhaseName 'Region' -Action {
        Set-Place -Identity $identity -CountryOrRegion 'Australia' -State 'SA' -ErrorAction Stop | Out-Null
    }

    $hasLocationData = $false
    if (-not (Test-MrmIsNullOrWhiteSpace -Value $normalisedBuilding)) { $hasLocationData = $true }
    if ($null -ne $PlannedRow.Floor) { $hasLocationData = $true }
    if (-not (Test-MrmIsNullOrWhiteSpace -Value $normalisedFloorLabel)) { $hasLocationData = $true }
    if ($null -ne $PlannedRow.Capacity) { $hasLocationData = $true }

    if ($hasLocationData) {
        Invoke-MrmSetPlaceAction -PhaseName 'Location' -Action {
            $locationParams = @{
                Identity    = $identity
                ErrorAction = 'Stop'
            }

            if (-not (Test-MrmIsNullOrWhiteSpace -Value $normalisedBuilding)) {
                $locationParams['Building'] = $normalisedBuilding
            }
            if ($null -ne $PlannedRow.Floor) {
                $locationParams['Floor'] = $PlannedRow.Floor
            }
            if (-not (Test-MrmIsNullOrWhiteSpace -Value $normalisedFloorLabel)) {
                $locationParams['FloorLabel'] = $normalisedFloorLabel
            }
            if ($null -ne $PlannedRow.Capacity) {
                $locationParams['Capacity'] = $PlannedRow.Capacity
            }

            Set-Place @locationParams | Out-Null
        }
    }

    if (@($normalisedTags).Count -gt 0) {
        Invoke-MrmSetPlaceAction -PhaseName 'Tags' -Action {
            Set-Place -Identity $identity -Tags $normalisedTags -ErrorAction Stop | Out-Null
        }
    }
}

function Set-MrmCalendarProcessingDesired {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,
        [switch]$WhatIfMode
    )

    $identity = $PlannedRow.PrimarySmtp

    if ($PlannedRow.RequiresApproval -eq $true) {
        $params = @{
            Identity = $identity
            AutomateProcessing = 'AutoAccept'
            AddOrganizerToSubject = [bool]$script:MRM.Defaults.AddOrganizerToSubject
            DeleteComments = [bool]$script:MRM.Defaults.DeleteComments
            DeleteSubject = [bool]$script:MRM.Defaults.DeleteSubject
            BookingWindowInDays = [int]$script:MRM.Defaults.BookingWindowInDays
            MaximumDurationInMinutes = [int]$script:MRM.Defaults.MaximumDurationInMinutes
            AllBookInPolicy = $false
            AllRequestInPolicy = $true
            ResourceDelegates = @($PlannedRow.DelegateDl)
            ForwardRequestsToDelegates = $true
            TentativePendingApproval = $true
            Confirm = $false
        }
    }
    else {
        $params = @{
            Identity = $identity
            AutomateProcessing = 'AutoAccept'
            AddOrganizerToSubject = [bool]$script:MRM.Defaults.AddOrganizerToSubject
            DeleteComments = [bool]$script:MRM.Defaults.DeleteComments
            DeleteSubject = [bool]$script:MRM.Defaults.DeleteSubject
            BookingWindowInDays = [int]$script:MRM.Defaults.BookingWindowInDays
            MaximumDurationInMinutes = [int]$script:MRM.Defaults.MaximumDurationInMinutes
            AllBookInPolicy = $true
            AllRequestInPolicy = $false
            ResourceDelegates = @()
            ForwardRequestsToDelegates = $false
            TentativePendingApproval = $false
            Confirm = $false
        }
    }

    if ($WhatIfMode) {
        Write-MrmWhatIf -Message ("Set-CalendarProcessing for: {0}" -f $identity)
        return
    }

    Set-CalendarProcessing @params |
        Out-Null

    if (-not (Test-MrmIsNullOrWhiteSpace -Value $PlannedRow.Response)) {
        Set-CalendarProcessing -Identity $identity -AddAdditionalResponse $true -AdditionalResponse $PlannedRow.Response -Confirm:$false |
            Out-Null
    }
    else {
        Set-CalendarProcessing -Identity $identity -AddAdditionalResponse $false -Confirm:$false |
            Out-Null
    }
}

function Set-MrmRegionalConfigurationDesired {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [switch]$WhatIfMode
    )

    if ($WhatIfMode) {
        Write-MrmWhatIf -Message ("Set-MailboxRegionalConfiguration for: {0}" -f $PlannedRow.PrimarySmtp)
        return
    }

    Set-MailboxRegionalConfiguration -Identity $PlannedRow.PrimarySmtp -TimeZone $script:MRM.Defaults.TimeZone | Out-Null
}

function Set-MrmCalendarConfigurationDesired {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [switch]$WhatIfMode
    )

    if ($WhatIfMode) {
        Write-MrmWhatIf -Message ("Set-MailboxCalendarConfiguration for: {0}" -f $PlannedRow.PrimarySmtp)
        return
    }

    Set-MailboxCalendarConfiguration -Identity $PlannedRow.PrimarySmtp -WorkingHoursTimeZone $script:MRM.Defaults.WorkingHoursTimeZone | Out-Null
}

function Set-MrmMailTipDesired {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [switch]$WhatIfMode
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $PlannedRow.MailTip) {
        return
    }

    if ($WhatIfMode) {
        Write-MrmWhatIf -Message ("Set MailTip for: {0}" -f $PlannedRow.PrimarySmtp)
        return
    }

    Set-Mailbox -Identity $PlannedRow.PrimarySmtp -MailTip $PlannedRow.MailTip | Out-Null
}

function Set-MrmCalendarDefaultPermissionDesired {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [switch]$WhatIfMode
    )

    $calendarPath = '{0}:\Calendar' -f $PlannedRow.PrimarySmtp
    $targetPermission = $script:MRM.Defaults.DefaultCalendarPermission

    if ($WhatIfMode) {
        Write-MrmWhatIf -Message ("Set calendar default permission for: {0}" -f $calendarPath)
        return
    }

    try {
        Set-MailboxFolderPermission -Identity $calendarPath -User Default -AccessRights $targetPermission | Out-Null
    }
    catch {
        Add-MailboxFolderPermission -Identity $calendarPath -User Default -AccessRights $targetPermission | Out-Null
    }
}

function Ensure-MrmFullAccessPermissions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [switch]$WhatIfMode
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $PlannedRow.AdminDl) {
        return
    }

    if ($WhatIfMode) {
        Write-MrmWhatIf -Message ("Grant FullAccess: {0} -> {1}" -f $PlannedRow.AdminDl, $PlannedRow.PrimarySmtp)
        return
    }

    try {
        $existing = Get-MailboxPermission -Identity $PlannedRow.PrimarySmtp -User $PlannedRow.AdminDl -ErrorAction Stop
        foreach ($perm in $existing) {
            foreach ($right in @($perm.AccessRights)) {
                if ([string]$right -eq 'FullAccess') {
                    return
                }
            }
        }
    }
    catch {
        # Ignore missing permission lookup.
    }

    Add-MailboxPermission -Identity $PlannedRow.PrimarySmtp -User $PlannedRow.AdminDl -AccessRights FullAccess -InheritanceType All -AutoMapping:$false | Out-Null
}

function Invoke-MrmCreatePlannedRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [switch]$WhatIfMode
    )

    switch ($PlannedRow.Action) {
        'Skip' {
            Write-MrmLog -Message ("Create skipped: {0}" -f $PlannedRow.PrimarySmtp) -Level 'WARN'
            return
        }

        'Blocked' {
            Write-MrmLog -Message ("Create blocked: {0} :: {1}" -f $PlannedRow.PrimarySmtp, ($PlannedRow.BlockingReasons -join '; ')) -Level 'ERROR'
            return
        }

        'Create' {
            # Thin create only:
            # - create the room mailbox
            # - wait until it is visible
            # - stop here
            New-MrmRoomMailbox -PlannedRow $PlannedRow -WhatIfMode:$WhatIfMode

            Write-MrmLog -Message ("Create completed (mailbox only): {0}" -f $PlannedRow.PrimarySmtp) -Level 'INFO'
        }

        default {
            throw "Unexpected create action: $($PlannedRow.Action)"
        }
    }
}

function Invoke-MrmModifyPlannedRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [switch]$WhatIfMode
    )

    switch ($PlannedRow.Action) {
        'Skip' {
            Write-MrmLog -Message ("Modify skipped: {0}" -f $PlannedRow.PrimarySmtp) -Level 'WARN'
            return
        }

        'Blocked' {
            Write-MrmLog -Message ("Modify blocked: {0} :: {1}" -f $PlannedRow.PrimarySmtp, ($PlannedRow.BlockingReasons -join '; ')) -Level 'ERROR'
            return
        }

        'Modify' {
            # Finalise / enrich the room mailbox
            Set-MrmRoomDisplayName -PlannedRow $PlannedRow -WhatIfMode:$WhatIfMode

            if (-not $PlannedRow.IsUnlisted -and -not (Test-MrmIsNullOrWhiteSpace -Value $PlannedRow.RoomListName)) {
                Ensure-MrmRoomList -RoomListName $PlannedRow.RoomListName -WhatIfMode:$WhatIfMode
                Ensure-MrmRoomListMembership -RoomListName $PlannedRow.RoomListName -PrimarySmtp $PlannedRow.PrimarySmtp -WhatIfMode:$WhatIfMode
            }

            Set-MrmPlaceMetadata -PlannedRow $PlannedRow -WhatIfMode:$WhatIfMode
            Set-MrmCalendarProcessingDesired -PlannedRow $PlannedRow -WhatIfMode:$WhatIfMode
            Set-MrmRegionalConfigurationDesired -PlannedRow $PlannedRow -WhatIfMode:$WhatIfMode
            Set-MrmCalendarConfigurationDesired -PlannedRow $PlannedRow -WhatIfMode:$WhatIfMode
            Set-MrmMailTipDesired -PlannedRow $PlannedRow -WhatIfMode:$WhatIfMode
            Set-MrmCalendarDefaultPermissionDesired -PlannedRow $PlannedRow -WhatIfMode:$WhatIfMode
            Ensure-MrmFullAccessPermissions -PlannedRow $PlannedRow -WhatIfMode:$WhatIfMode

            Write-MrmLog -Message ("Modify completed (finalised): {0}" -f $PlannedRow.PrimarySmtp) -Level 'INFO'
        }

        default {
            throw "Unexpected modify action: $($PlannedRow.Action)"
        }
    }
}

function Invoke-MrmExecutionDryRun {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WorkbookPath,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify')]
        [string]$Operation
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $WorkbookPath) {
        $WorkbookPath = $null
    }

    Assert-MrmPowerShell51
    Assert-MrmStaMode
    Initialize-MrmPaths
    Connect-MrmExchangeOnline

    try {
        $rows = Get-MrmInputRows -Operation $Operation -WorkbookPath $WorkbookPath
        $parsedRows = ConvertTo-MrmParsedRows -Rows $rows -Operation $Operation
        $plannedRows = ConvertTo-MrmPlannedRows -ParsedRows $parsedRows -Operation $Operation

        Show-MrmParsedRowsSummary -ParsedRows $parsedRows
        Show-MrmPlannedRowsSummary -PlannedRows $plannedRows -Operation $Operation

        foreach ($row in $plannedRows) {
            switch ($Operation) {
                'Create' { Invoke-MrmCreatePlannedRow -PlannedRow $row -WhatIfMode }
                'Modify' { Invoke-MrmModifyPlannedRow -PlannedRow $row -WhatIfMode }
            }
        }

        return $plannedRows
    }
    finally {
        Disconnect-MrmExchangeOnlineSafe
    }
}

function Test-MrmChunk5SelfTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkbookPath,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify')]
        [string]$Operation
    )

    $plannedRows = Invoke-MrmExecutionDryRun -WorkbookPath $WorkbookPath -Operation $Operation
    if ($plannedRows.Count -lt 1) {
        throw 'No planned rows were returned.'
    }

    Write-MrmLog -Message ('Chunk 5 self-test passed for operation {0}.' -f $Operation) -Level 'INFO'
    return $true
}

# ---------------------------------------------------------------------
# MRM Provision MVP - Chunk 6
# Delete execution, confirmations, live execution flow, final entrypoint
# ---------------------------------------------------------------------

function Remove-MrmRoomMailboxSoft {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [switch]$WhatIfMode
    )

    if ($WhatIfMode) {
        Write-MrmWhatIf -Message ("Remove mailbox: {0}" -f $PlannedRow.PrimarySmtp)
        return
    }

    Write-MrmLog -Message ("Removing mailbox: {0}" -f $PlannedRow.PrimarySmtp) -Level 'INFO'
    Remove-Mailbox -Identity $PlannedRow.PrimarySmtp -Confirm:$false | Out-Null
}

function Invoke-MrmDeletePlannedRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$PlannedRow,

        [switch]$WhatIfMode
    )

    switch ($PlannedRow.Action) {
        'Skip' {
            Write-MrmLog -Message ("Delete skipped: {0}" -f $PlannedRow.PrimarySmtp) -Level 'WARN'
            return
        }
        'Blocked' {
            Write-MrmLog -Message ("Delete blocked: {0} :: {1}" -f $PlannedRow.PrimarySmtp, ($PlannedRow.BlockingReasons -join '; ')) -Level 'ERROR'
            return
        }
        'Delete' {
            Remove-MrmRoomMailboxSoft -PlannedRow $PlannedRow -WhatIfMode:$WhatIfMode
            Write-MrmLog -Message ("Delete completed: {0}" -f $PlannedRow.PrimarySmtp) -Level 'INFO'
        }
        default {
            throw "Unexpected delete action: $($PlannedRow.Action)"
        }
    }
}

function Confirm-MrmOperationTyped {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify')]
        [string]$Operation
    )

    $expected = $Operation.ToUpperInvariant()

    Write-Host ''
    Write-MrmConsole -Message 'Rows are planned and ready.' -Colour 'Cyan'
    Write-MrmConsole -Message ("Type {0} to continue, or X to go back to the main menu:" -f $expected) -Colour 'Yellow'

    $typed = Read-Host 'Confirm'
    if ([string]::IsNullOrWhiteSpace($typed)) {
        return 'Cancelled'
    }

    $typed = $typed.Trim().ToUpperInvariant()

    if ($typed -ceq 'X') {
        return 'Back'
    }

    if ($typed -ceq $expected) {
        return 'Confirmed'
    }

    return 'Cancelled'
}

function Confirm-MrmDeleteRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$PlannedRows
    )

    $targets = @(
        $PlannedRows |
        Where-Object { $_.Action -eq 'Delete' -and $_.ExistsInExo -eq $true }
    )

    if ($targets.Count -eq 0) {
        return 'Confirmed'
    }

    Write-Host ''
    Write-MrmConsole -Message 'Delete preview complete.' -Colour 'Yellow'
    Write-MrmConsole -Message ('Delete targets: {0}' -f $targets.Count) -Colour 'Yellow'
    Write-MrmConsole -Message 'Type DELETE to continue, or X to go back to the main menu:' -Colour 'Yellow'

    $batchTyped = Read-Host 'Confirm'
    if ([string]::IsNullOrWhiteSpace($batchTyped)) {
        return 'Cancelled'
    }

    $batchTyped = $batchTyped.Trim().ToUpperInvariant()

    if ($batchTyped -ceq 'X') {
        return 'Back'
    }

    if ($batchTyped -cne 'DELETE') {
        return 'Cancelled'
    }

    foreach ($row in $targets) {
        Write-Host ''

        if ($row.RowNumber -eq 2 -and (Test-MrmIsNullOrWhiteSpace -Value $row.RoomListName) -and (Test-MrmIsNullOrWhiteSpace -Value $row.AdminDl)) {
            Write-MrmConsole -Message ('Confirm delete for manually entered mailbox: {0}' -f $row.PrimarySmtp) -Colour 'Yellow'
        }
        else {
            Write-MrmConsole -Message ('Confirm delete for row {0}: {1}' -f $row.RowNumber, $row.PrimarySmtp) -Colour 'Yellow'
        }

        Write-MrmConsole -Message 'Type the exact SMTP address to confirm, or X to go back to the main menu:' -Colour 'Yellow'

        $typed = Read-Host 'SMTP'
        if ([string]::IsNullOrWhiteSpace($typed)) {
            return 'Cancelled'
        }

        $typed = $typed.Trim()

        if ($typed.ToUpperInvariant() -ceq 'X') {
            return 'Back'
        }

        if ($typed.ToLowerInvariant() -cne $row.PrimarySmtp.Trim().ToLowerInvariant()) {
            Write-MrmConsole -Message ('Delete confirmation failed for {0}' -f $row.PrimarySmtp) -Colour 'Red'
            return 'Cancelled'
        }
    }

    return 'Confirmed'
}

function Show-MrmLiveExecutionSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$PlannedRows,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation
    )

    $completed = 0
    $skipped = 0
    $blocked = 0

    foreach ($row in $PlannedRows) {
        switch ([string]$row.Action) {
            'Skip'    { $skipped++ }
            'Blocked' { $blocked++ }
            default   { $completed++ }
        }
    }

    Write-Host ''
    Write-MrmConsole -Message ('Execution complete [{0}]' -f $Operation) -Colour 'Cyan'
    Write-MrmConsole -Message ('Completed actions : {0}' -f $completed) -Colour 'Green'
    Write-MrmConsole -Message ('Skipped           : {0}' -f $skipped) -Colour 'Yellow'
    Write-MrmConsole -Message ('Blocked           : {0}' -f $blocked) -Colour 'Red'
    Write-Host ''
}

function Invoke-MrmExecuteLive {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$WorkbookPath,

        [Parameter(Mandatory)]
        [ValidateSet('Create', 'Modify', 'Delete')]
        [string]$Operation
    )

    if (Test-MrmIsNullOrWhiteSpace -Value $WorkbookPath) {
        $WorkbookPath = $null
    }

    Assert-MrmPowerShell51
    Assert-MrmStaMode
    Initialize-MrmPaths
    Start-MrmTranscriptSafe
    Connect-MrmExchangeOnline

    try {
        $rows = Get-MrmInputRows -Operation $Operation -WorkbookPath $WorkbookPath
        if ($null -eq $rows) {
            return 'Back'
        }

        $rows = @($rows)
        if ($rows.Count -eq 0) {
            Write-MrmLog -Message 'No input rows were returned.' -Level 'WARN'
            return 'Cancelled'
        }

        $parsedRows = ConvertTo-MrmParsedRows -Rows $rows -Operation $Operation
        $plannedRows = ConvertTo-MrmPlannedRows -ParsedRows $parsedRows -Operation $Operation

        Show-MrmParsedRowsSummary -ParsedRows $parsedRows
        Show-MrmPlannedRowsSummary -PlannedRows $plannedRows -Operation $Operation

        $confirmationResult = switch ($Operation) {
            'Create' { Confirm-MrmOperationTyped -Operation 'Create' }
            'Modify' { Confirm-MrmOperationTyped -Operation 'Modify' }
            'Delete' { Confirm-MrmDeleteRows -PlannedRows $plannedRows }
        }

        switch ($confirmationResult) {
            'Back' {
                Write-MrmLog -Message 'Execution returned to the main menu by operator.' -Level 'INFO'
                return 'Back'
            }

            'Confirmed' {
                # Continue
            }

            default {
                Write-MrmLog -Message 'Execution cancelled by operator.' -Level 'WARN'
                return 'Cancelled'
            }
        }

        $rowFailures = 0

        foreach ($row in $plannedRows) {
            try {
                switch ($Operation) {
                    'Create' { Invoke-MrmCreatePlannedRow -PlannedRow $row }
                    'Modify' { Invoke-MrmModifyPlannedRow -PlannedRow $row }
                    'Delete' { Invoke-MrmDeletePlannedRow -PlannedRow $row }
                }
            }
            catch {
                $rowFailures++
                Write-MrmLog -Message ("Row failed [{0}] {1}: {2}" -f $Operation, $row.PrimarySmtp, $_.Exception.Message) -Level 'ERROR'
                continue
            }
        }

        Show-MrmLiveExecutionSummary -PlannedRows $plannedRows -Operation $Operation

        if ($rowFailures -gt 0) {
            Write-MrmLog -Message ("Execution completed with {0} row failure(s)." -f $rowFailures) -Level 'WARN'
            return 'CompletedWithErrors'
        }

        return 'Success'
    }
    finally {
        Stop-MrmTranscriptSafe
    }
}

function Test-MrmChunk6SelfTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$WorkbookPath
    )

    Assert-MrmPowerShell51
    Assert-MrmStaMode
    Initialize-MrmPaths
    Connect-MrmExchangeOnline

    try {
        $rows = Get-MrmInputRows -Operation Delete -WorkbookPath $WorkbookPath
        $parsedRows = ConvertTo-MrmParsedRows -Rows $rows -Operation Delete
        $plannedRows = ConvertTo-MrmPlannedRows -ParsedRows $parsedRows -Operation Delete

        Show-MrmParsedRowsSummary -ParsedRows $parsedRows
        Show-MrmPlannedRowsSummary -PlannedRows $plannedRows -Operation Delete

        foreach ($row in $plannedRows) {
            Invoke-MrmDeletePlannedRow -PlannedRow $row -WhatIfMode
        }

        Write-MrmLog -Message 'Chunk 6 self-test passed.' -Level 'INFO'
        return $true
    }
    finally {
        Disconnect-MrmExchangeOnlineSafe
    }
}

function Wait-MrmReturnToMainMenu {
    [CmdletBinding()]
    param()

    Write-Host ''
    Write-MrmConsole -Message 'Press any key to return to the main menu...' -Colour 'Cyan'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}

function Invoke-MrmMain {
    [CmdletBinding()]
    param()

    Assert-MrmPowerShell51
    Assert-MrmStaMode
    Initialize-MrmPaths
    Ensure-MrmExchangeOnlineModule
    Connect-MrmExchangeOnline

    try {
        while ($true) {
            Show-MrmBanner
            $operation = Show-MrmOperationMenu

            if ($null -eq $operation) {
                Write-MrmConsole -Message 'Exiting.' -Colour 'Yellow'
                return
            }

            $workbookPath = Select-MrmWorkbookPath

            if (@('Create', 'Modify') -contains $operation -and (Test-MrmIsNullOrWhiteSpace -Value $workbookPath)) {
                Write-MrmConsole -Message 'Workbook selection cancelled. Returning to the main menu.' -Colour 'Yellow'
                continue
            }

            if ($operation -eq 'Check') {
                $checkResult = Invoke-MrmCheckRooms -WorkbookPath $workbookPath

                if ($checkResult -eq 'Back') {
                    continue
                }

                if ($checkResult -eq 'Success') {
                    Write-MrmConsole -Message 'Done.' -Colour 'Green'
                    Wait-MrmCheckReturnToMainMenu
                    continue
                }

                Write-MrmConsole -Message 'No results returned.' -Colour 'Yellow'
                Wait-MrmReturnToMainMenu
                continue
            }

            $executionResult = Invoke-MrmExecuteLive -WorkbookPath $workbookPath -Operation $operation

            if ($executionResult -eq 'Back') {
                continue
            }

            if ($executionResult -eq 'Success') {
                Write-MrmConsole -Message 'Done.' -Colour 'Green'
                Wait-MrmReturnToMainMenu
                continue
            }

            if ($executionResult -eq 'CompletedWithErrors') {
                Write-MrmConsole -Message 'Completed with one or more row failure(s).' -Colour 'Yellow'
                Wait-MrmReturnToMainMenu
                continue
            }

            Write-MrmConsole -Message 'No changes were made.' -Colour 'Yellow'
            Wait-MrmReturnToMainMenu
            continue
        }
    }
    finally {
        Disconnect-MrmExchangeOnlineSafe
    }
}

# Only auto-run when executed normally, not when dot-sourced for testing.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-MrmMain
        exit 0
    }
    catch {
        Initialize-MrmPaths

        $fatalPath = Join-Path -Path $script:MRM.Paths.Logs -ChildPath ('Fatal-{0}.log' -f (Get-MrmTimestamp))
        $fatalLines = @(
            ('Timestamp         : {0}' -f (Get-Date).ToString('o'))
            ('Exception Type    : {0}' -f $_.Exception.GetType().FullName)
            ('Exception Message : {0}' -f $_.Exception.Message)
            ''
            'ScriptStackTrace:'
            ($_.ScriptStackTrace)
            ''
            'InvocationInfo:'
            ($_.InvocationInfo | Format-List * -Force | Out-String)
            ''
            'ErrorRecord:'
            ($_ | Format-List * -Force | Out-String)
        )

        Set-Content -LiteralPath $fatalPath -Value $fatalLines -Encoding UTF8

        Write-Host ''
        Write-Host 'FATAL: script terminated with an unhandled error.' -ForegroundColor Red
        Write-Host ('Message: {0}' -f $_.Exception.Message) -ForegroundColor Red
        Write-Host ('Log    : {0}' -f $fatalPath) -ForegroundColor Yellow
        Write-Host ''

        try {
            Disconnect-MrmExchangeOnlineSafe
        }
        catch {
            # Ignore disconnect failures.
        }

        try {
            Stop-MrmTranscriptSafe
        }
        catch {
            # Ignore transcript stop failures.
        }

        exit 1
    }
}
