<#
.SYNOPSIS
    PRTG EXE/Script Advanced Sensor fuer Microsoft Intune und Entra ID (Azure AD) Connect Sync.

.DESCRIPTION
    Fragt ueber die Microsoft Graph API ab:
      - Intune managed devices (Gesamt, Aufschluesselung nach operatingSystem)
      - Compliance-Status (compliant / noncompliant / inGracePeriod / error / unknown)
      - Verschluesselungsstatus (isEncrypted)
      - Geraete, die sich seit X Tagen nicht mehr gemeldet haben (lastSyncDateTime)
      - Geraete in einem haengenden Management-State (retirePending, wipeFailed, ...)
      - Entra Connect: onPremisesSyncEnabled und Alter des letzten Sync (/organization)

    Auth: OAuth2 Client Credentials (App Registration / Service Principal).
    Keine externen Module. Eine Datei.

.PARAMETER AppId
    Application (Client) ID der App Registration.

.PARAMETER TenantId
    Directory (Tenant) ID.

.PARAMETER ClientSecret
    Client Secret Value der App Registration.

.PARAMETER StaleDeviceDays
    Ein Geraet gilt als "stale", wenn lastSyncDateTime aelter als X Tage ist. Default 30.

.PARAMETER StaleDeviceWarnCount
    Ab wievielen stale devices der Kanal warnt. Default 10.

.PARAMETER MaxSyncLagHours
    Ab welchem Alter des letzten Entra-Connect-Sync gewarnt wird. Default 3.
    (Entra Connect synchronisiert standardmaessig alle 30 Minuten.)

.PARAMETER GraphBaseUri
    Graph Endpoint. Default https://graph.microsoft.com (fuer Sondertenants anpassbar).

.EXAMPLE
    .\Intune-EntraID-PRTG.ps1 -AppId 'xxx' -TenantId 'yyy' -ClientSecret 'zzz'

.NOTES
    Version : 1.1.0
    Datum   : 2026-09-09

    Benoetigte Graph Application Permissions (mit Admin Consent):
      - DeviceManagementManagedDevices.Read.All   (Intune Geraete)
      - Organization.Read.All                     (Entra Connect Sync Status)
    Directory.Read.All funktioniert alternativ zu Organization.Read.All,
    ist aber deutlich weitreichender.

    Kanalnamen sind bewusst ASCII (keine Umlaute), weil die Konsolen-Codepage
    beim Aufruf durch die PRTG Probe sonst zu kaputten Zeichen fuehren kann.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]  [string] $AppId,
    [Parameter(Mandatory = $true)]  [string] $TenantId,
    [Parameter(Mandatory = $true)]  [string] $ClientSecret,
    [Parameter(Mandatory = $false)] [int]    $StaleDeviceDays      = 30,
    [Parameter(Mandatory = $false)] [int]    $StaleDeviceWarnCount = 10,
    [Parameter(Mandatory = $false)] [int]    $MaxSyncLagHours      = 3,
    [Parameter(Mandatory = $false)] [string] $GraphBaseUri         = 'https://graph.microsoft.com'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# TLS 1.2 erzwingen - auf Server 2012R2/2016 sonst Handshake-Fehler gegen login.microsoftonline.com
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { }

# ---------------------------------------------------------------------------
# Hilfsfunktionen
# ---------------------------------------------------------------------------

function ConvertTo-PrtgText {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text -replace '[\r\n]+', ' '
    $t = [System.Security.SecurityElement]::Escape($t)
    if ($t.Length -gt 250) { $t = $t.Substring(0, 250) }
    return $t
}

function Write-PrtgError {
    param([string] $Message)
    $safe = ConvertTo-PrtgText $Message
    # Kein XML-Prolog: PRTG erwartet reines <prtg>-Fragment auf stdout.
    Write-Output "<prtg><error>1</error><text>$safe</text></prtg>"
    exit 0   # exit 0, damit PRTG die XML-Fehlermeldung anzeigt statt "premature end"
}

function New-PrtgChannel {
    param(
        [string] $Name,
        [double] $Value,
        [Nullable[double]] $WarnMax = $null,
        [Nullable[double]] $ErrMax  = $null,
        [switch] $NoGraph
    )
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<result>')
    [void]$sb.Append('<channel>').Append([System.Security.SecurityElement]::Escape($Name)).Append('</channel>')
    [void]$sb.Append('<value>').Append([string][int]$Value).Append('</value>')
    [void]$sb.Append('<unit>Count</unit>')
    if ($null -ne $WarnMax -or $null -ne $ErrMax) {
        # Ohne LimitMode 1 ignoriert PRTG die Limits komplett.
        [void]$sb.Append('<LimitMode>1</LimitMode>')
        if ($null -ne $WarnMax) { [void]$sb.Append('<LimitMaxWarning>').Append($WarnMax).Append('</LimitMaxWarning>') }
        if ($null -ne $ErrMax)  { [void]$sb.Append('<LimitMaxError>').Append($ErrMax).Append('</LimitMaxError>') }
    }
    if ($NoGraph) { [void]$sb.Append('<showChart>0</showChart>') }
    [void]$sb.Append('</result>')
    return $sb.ToString()
}

function Get-GraphToken {
    param([string] $AppId, [string] $TenantId, [string] $ClientSecret, [string] $BaseUri)

    $uri  = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        grant_type    = 'client_credentials'
        client_id     = $AppId
        client_secret = $ClientSecret
        scope         = "$BaseUri/.default"
    }
    try {
        $resp = Invoke-RestMethod -Method Post -Uri $uri -Body $body -ContentType 'application/x-www-form-urlencoded'
    }
    catch {
        $detail = $_.Exception.Message
        # AADSTS-Code aus der Antwort ziehen, das ist der eigentlich nuetzliche Teil
        if ($_.ErrorDetails.Message) {
            try {
                $j = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($j.error_description) { $detail = ($j.error_description -split "`r?`n")[0] }
            } catch { }
        }
        throw "Token-Abruf fehlgeschlagen: $detail"
    }
    if (-not $resp.access_token) { throw 'Token-Abruf lieferte kein access_token.' }
    return $resp.access_token
}

function Invoke-GraphGet {
    <#
        Holt eine Graph-Collection inklusive Paging (@odata.nextLink).
        Ohne Paging fehlen bei >100 Geraeten schlicht die restlichen Seiten.
    #>
    param([string] $Uri, [string] $Token, [switch] $Single)

    $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/json' }
    $items   = New-Object System.Collections.ArrayList
    $next    = $Uri
    $page    = 0

    while ($next) {
        $page++
        if ($page -gt 200) { throw "Paging-Abbruch nach 200 Seiten ($Uri)." }

        $attempt = 0
        $resp    = $null
        while ($true) {
            $attempt++
            try {
                $resp = Invoke-RestMethod -Method Get -Uri $next -Headers $headers
                break
            }
            catch {
                $code = $null
                if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
                # 429/503 = Throttling, kurz warten und erneut versuchen
                if (($code -eq 429 -or $code -eq 503) -and $attempt -lt 4) {
                    Start-Sleep -Seconds (2 * $attempt)
                    continue
                }
                $detail = $_.Exception.Message
                if ($_.ErrorDetails.Message) {
                    try {
                        $j = $_.ErrorDetails.Message | ConvertFrom-Json
                        if ($j.error.message) { $detail = $j.error.message }
                    } catch { }
                }
                throw "Graph-Abfrage fehlgeschlagen ($code) auf $($next -replace '\?.*$',''): $detail"
            }
        }

        if ($Single) { return $resp }

        if ($null -ne $resp.value) { foreach ($v in $resp.value) { [void]$items.Add($v) } }
        $next = $resp.'@odata.nextLink'
    }
    return $items
}

function ConvertTo-DateTimeUtcOrNull {
    param($Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try {
        $dt = [datetime]::Parse(
            [string]$Value,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
        # Graph liefert vereinzelt 0001-01-01 als "nie"
        if ($dt.Year -le 1601) { return $null }
        return $dt.ToUniversalTime()
    } catch { return $null }
}

function Measure-Where {
    # .Count ist auf $null unzuverlaessig - daher immer ueber @() normalisieren
    param($Collection, [scriptblock] $Filter)
    return @($Collection | Where-Object $Filter).Count
}

# ---------------------------------------------------------------------------
# Hauptteil
# ---------------------------------------------------------------------------

try {
    $token = Get-GraphToken -AppId $AppId -TenantId $TenantId -ClientSecret $ClientSecret -BaseUri $GraphBaseUri

    # --- Intune Geraete -----------------------------------------------------
    # $select spart massiv Payload und damit Laufzeit; $top=1000 reduziert die Seitenzahl.
    $select     = 'id,deviceName,operatingSystem,complianceState,managementState,isEncrypted,lastSyncDateTime,enrolledDateTime'
    $devicesUri = "$GraphBaseUri/v1.0/deviceManagement/managedDevices?`$select=$select&`$top=1000"
    $devices    = @(Invoke-GraphGet -Uri $devicesUri -Token $token)

    $total = $devices.Count

    # OS-Aufschluesselung ueber operatingSystem (Freitext), NICHT ueber deviceType.
    # deviceType liefert Werte wie 'desktop', 'iPhone', 'androidEnterprise' - unbrauchbar zum Gruppieren.
    $win     = Measure-Where $devices { $_.operatingSystem -like 'Windows*' }
    $mac     = Measure-Where $devices { $_.operatingSystem -like 'macOS*' -or $_.operatingSystem -like 'OS X*' -or $_.operatingSystem -eq 'macMDM' }
    $ios     = Measure-Where $devices { $_.operatingSystem -like 'iOS*' -or $_.operatingSystem -like 'iPad*' }
    $android = Measure-Where $devices { $_.operatingSystem -like 'Android*' }
    $otherOs = $total - $win - $mac - $ios - $android
    if ($otherOs -lt 0) { $otherOs = 0 }

    # complianceState-Enum laut Graph: unknown, compliant, noncompliant, conflict,
    # error, inGracePeriod, configManager. -eq ist in PowerShell case-insensitive.
    $compliant    = Measure-Where $devices { $_.complianceState -eq 'compliant' }
    $nonCompliant = Measure-Where $devices { $_.complianceState -eq 'noncompliant' }
    $grace        = Measure-Where $devices { $_.complianceState -eq 'inGracePeriod' }
    $errorState   = Measure-Where $devices { $_.complianceState -eq 'error' -or $_.complianceState -eq 'conflict' }
    $unknownState = Measure-Where $devices { $_.complianceState -eq 'unknown' }

    $encrypted   = Measure-Where $devices { $_.isEncrypted -eq $true }
    $unencrypted = Measure-Where $devices { $_.isEncrypted -eq $false }

    # Stale = hat sich seit X Tagen nicht mehr bei Intune gemeldet.
    # Wichtig: lastSyncDateTime, nicht das Enrollment-Datum - ein vor 2 Jahren
    # eingerolltes, taeglich eincheckendes Geraet ist voellig gesund.
    $staleLimit = (Get-Date).ToUniversalTime().AddDays(-$StaleDeviceDays)
    $stale = 0
    foreach ($d in $devices) {
        $ls = ConvertTo-DateTimeUtcOrNull $d.lastSyncDateTime
        if ($null -eq $ls -or $ls -lt $staleLimit) { $stale++ }
    }

    # managementState-Enum: managed, retirePending, retireFailed, wipePending,
    # wipeFailed, unhealthy, deletePending, retireIssued, wipeIssued,
    # wipeCanceled, retireCanceled, discovered. 'retireNeeded' existiert nicht.
    $managed = Measure-Where $devices { $_.managementState -eq 'managed' }
    $stuck   = Measure-Where $devices {
        $_.managementState -in @('retirePending','retireFailed','wipePending','wipeFailed','unhealthy','deletePending','retireIssued','wipeIssued')
    }

    # --- Entra Connect Sync -------------------------------------------------
    $syncEnabled = 0
    $syncLagMin  = $null
    $syncNote    = ''
    try {
        $orgUri = "$GraphBaseUri/v1.0/organization?`$select=id,displayName,onPremisesSyncEnabled,onPremisesLastSyncDateTime"
        $org    = Invoke-GraphGet -Uri $orgUri -Token $token -Single
        $orgObj = @($org.value)[0]

        if ($orgObj -and $orgObj.onPremisesSyncEnabled -eq $true) {
            $syncEnabled = 1
            $last = ConvertTo-DateTimeUtcOrNull $orgObj.onPremisesLastSyncDateTime
            if ($null -ne $last) {
                $syncLagMin = [int][Math]::Round(((Get-Date).ToUniversalTime() - $last).TotalMinutes)
                if ($syncLagMin -lt 0) { $syncLagMin = 0 }
            } else {
                $syncNote = 'Sync aktiv, aber kein Zeitstempel geliefert.'
            }
        } else {
            $syncNote = 'Kein Entra Connect (Cloud-only Tenant).'
        }
    }
    catch {
        # Fehlt Organization.Read.All, soll der Geraeteteil trotzdem laufen.
        $syncNote = "Sync-Status nicht lesbar: $($_.Exception.Message)"
    }

    # --- Ausgabe ------------------------------------------------------------
    $out = New-Object System.Text.StringBuilder
    [void]$out.Append('<prtg>')

    [void]$out.Append((New-PrtgChannel -Name 'Devices Total'            -Value $total))
    [void]$out.Append((New-PrtgChannel -Name 'Devices Windows'          -Value $win     -NoGraph))
    [void]$out.Append((New-PrtgChannel -Name 'Devices macOS'            -Value $mac     -NoGraph))
    [void]$out.Append((New-PrtgChannel -Name 'Devices iOS'              -Value $ios     -NoGraph))
    [void]$out.Append((New-PrtgChannel -Name 'Devices Android'          -Value $android -NoGraph))
    [void]$out.Append((New-PrtgChannel -Name 'Devices Other OS'         -Value $otherOs -NoGraph))

    [void]$out.Append((New-PrtgChannel -Name 'Compliant'                -Value $compliant))
    [void]$out.Append((New-PrtgChannel -Name 'Non-Compliant'            -Value $nonCompliant -WarnMax 0))
    [void]$out.Append((New-PrtgChannel -Name 'In Grace Period'          -Value $grace))
    [void]$out.Append((New-PrtgChannel -Name 'Compliance Error'         -Value $errorState   -WarnMax 0))
    [void]$out.Append((New-PrtgChannel -Name 'Compliance Unknown'       -Value $unknownState))

    [void]$out.Append((New-PrtgChannel -Name 'Encrypted'                -Value $encrypted))
    [void]$out.Append((New-PrtgChannel -Name 'Not Encrypted'            -Value $unencrypted -WarnMax 0))

    [void]$out.Append((New-PrtgChannel -Name "Stale (>$StaleDeviceDays d no check-in)" -Value $stale -WarnMax $StaleDeviceWarnCount))
    [void]$out.Append((New-PrtgChannel -Name 'Management State managed' -Value $managed -NoGraph))
    [void]$out.Append((New-PrtgChannel -Name 'Management State stuck'   -Value $stuck   -WarnMax 0))

    [void]$out.Append((New-PrtgChannel -Name 'Entra Connect Enabled'    -Value $syncEnabled -NoGraph))
    if ($null -ne $syncLagMin) {
        # Minuten statt Stunden: ein 30-Minuten-Sync ist in Stunden nicht aufloesbar.
        $warnMin = $MaxSyncLagHours * 60
        [void]$out.Append('<result><channel>Entra Connect Sync Age</channel>')
        [void]$out.Append('<value>').Append($syncLagMin).Append('</value>')
        # unit=Custom, sonst ignoriert PRTG die customunit und rechnet in Sekunden.
        [void]$out.Append('<unit>Custom</unit><customunit>min</customunit><float>0</float>')
        [void]$out.Append('<LimitMode>1</LimitMode><LimitMaxWarning>').Append($warnMin).Append('</LimitMaxWarning>')
        [void]$out.Append('</result>')
    }

    $text = "$total Geraete, $nonCompliant non-compliant, $stale stale"
    if ($syncNote) { $text = "$text. $syncNote" }
    [void]$out.Append('<text>').Append((ConvertTo-PrtgText $text)).Append('</text>')

    [void]$out.Append('</prtg>')
    Write-Output $out.ToString()
}
catch {
    Write-PrtgError $_.Exception.Message
}
