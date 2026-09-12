# Anleitung: Intune / Entra ID Health Check Sensor fuer PRTG

Vollstaendige Einrichtung des Sensors `Intune-EntraID-PRTG.ps1` --
von der App Registration bis zum fertigen Sensor in PRTG.

---

## Inhalt

1. [Was der Sensor macht](#1-was-der-sensor-macht)
2. [Voraussetzungen](#2-voraussetzungen)
3. [Schritt 1: App Registration in Entra ID](#3-schritt-1-app-registration-in-entra-id)
4. [Schritt 2: Skript auf der Probe ablegen](#4-schritt-2-skript-auf-der-probe-ablegen)
5. [Schritt 3: Manuell testen](#5-schritt-3-manuell-testen)
6. [Schritt 4: Sensor in PRTG anlegen](#6-schritt-4-sensor-in-prtg-anlegen)
7. [Parameter-Referenz](#7-parameter-referenz)
8. [Kanal-Referenz](#8-kanal-referenz)
9. [Grenzwerte anpassen](#9-grenzwerte-anpassen)
10. [Stolperfallen](#10-stolperfallen)
11. [Troubleshooting](#11-troubleshooting)
12. [Sicherheitshinweise](#12-sicherheitshinweise)
13. [Performance und Skalierung](#13-performance-und-skalierung)

---

## 1. Was der Sensor macht

Das Skript holt sich per **OAuth2 Client Credentials** ein Graph-Token und fragt
zwei Endpunkte ab:

| Endpunkt | Wofuer |
|---|---|
| `/v1.0/deviceManagement/managedDevices` | Alle Intune-Geraete (mit Paging ueber `@odata.nextLink`) |
| `/v1.0/organization` | `onPremisesSyncEnabled` und `onPremisesLastSyncDateTime` fuer Entra Connect |

Daraus werden Zaehlkanaele gebildet. Es werden **keine Geraetedaten gespeichert oder
ausgegeben** -- nur aggregierte Zahlen. Die XML-Ausgabe bleibt dadurch auch bei
5.000 Geraeten bei rund 2 KB.

Ausgegeben wird eine einzige Zeile reines PRTG-XML auf stdout, ohne XML-Prolog:

```xml
<prtg><result><channel>Devices Total</channel><value>6</value><unit>Count</unit></result>...<text>6 Geraete, 1 non-compliant, 2 stale</text></prtg>
```

---

## 2. Voraussetzungen

| | |
|---|---|
| **PRTG** | Beliebige aktuelle Version mit Sensortyp *EXE/Script Advanced* |
| **Probe** | Windows mit Windows PowerShell 5.1 (Standard) oder PowerShell 7 |
| **Netzwerk** | Ausgehend HTTPS (443) von der Probe zu `login.microsoftonline.com` und `graph.microsoft.com` |
| **Lizenz** | Intune-Lizenzierung im Tenant; fuer den Sync-Teil ein konfigurierter Entra Connect (optional) |
| **Module** | Keine. Das Skript nutzt nur Bordmittel (`Invoke-RestMethod`). |

Das Skript erzwingt selbst **TLS 1.2**, damit es auch auf Server 2012 R2 / 2016
gegen `login.microsoftonline.com` funktioniert.

---

## 3. Schritt 1: App Registration in Entra ID

1. [Entra Admin Center](https://entra.microsoft.com) oeffnen
   -> **Identity** -> **Applications** -> **App registrations** -> **New registration**
2. Name vergeben, z. B. `PRTG-Intune-HealthCheck`.
   *Supported account types*: **Single tenant**. Keine Redirect URI noetig.
3. Auf der Uebersichtsseite notieren:
   - **Application (client) ID** -> spaeter `-AppId`
   - **Directory (tenant) ID** -> spaeter `-TenantId`
4. **Certificates & secrets** -> **New client secret** -> Laufzeit waehlen ->
   **Value** sofort kopieren (er wird danach nie wieder angezeigt) -> spaeter `-ClientSecret`.
   > Ablaufdatum notieren und eine Wiedervorlage setzen. Laeuft das Secret ab,
   > geht der Sensor mit `AADSTS7000215` auf Fehler.
5. **API permissions** -> **Add a permission** -> **Microsoft Graph** ->
   **Application permissions** (nicht *Delegated*!) -> folgende setzen:

   | Permission | Wofuer | Pflicht |
   |---|---|---|
   | `DeviceManagementManagedDevices.Read.All` | Intune-Geraete | ja |
   | `Organization.Read.All` | Entra-Connect-Sync-Status | optional |

6. **Wichtig:** auf **Grant admin consent for \<Tenant\>** klicken.
   Ohne Admin Consent liefert Graph `403 Forbidden`.

> `Directory.Read.All` funktioniert alternativ zu `Organization.Read.All`,
> ist aber deutlich weitreichender. Nimm die kleinere Berechtigung.

Fehlt `Organization.Read.All`, laeuft der Geraeteteil trotzdem sauber durch --
der Sensor bleibt gruen und schreibt den Grund in die Sensor-Meldung
(`Sync-Status nicht lesbar: ...`).

---

## 4. Schritt 2: Skript auf der Probe ablegen

Das Skript gehoert auf **jede Probe**, die den Sensor ausfuehren soll, in:

```
C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\
```

Der Dateiname `Intune-EntraID-PRTG.ps1` taucht danach im Sensor-Dropdown auf.

### ExecutionPolicy

Das ist die haeufigste Fehlerquelle. PRTG startet das Skript ueber `powershell.exe`,
und je nach Probe-Architektur ist das der 64-Bit- **oder** der 32-Bit-Host.
Setze die Policy daher in **beiden**:

```powershell
# 64-Bit
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine

# 32-Bit (aus einer 64-Bit-Konsole heraus starten)
& "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" `
    -Command "Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope LocalMachine"
```

Kam die Datei per Download oder E-Mail, hat sie eventuell die
Mark-of-the-Web-Markierung und wird trotz `RemoteSigned` blockiert:

```powershell
Unblock-File 'C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\Intune-EntraID-PRTG.ps1'
```

---

## 5. Schritt 3: Manuell testen

**Immer zuerst von Hand auf der Probe testen**, bevor du den Sensor anlegst.
Das spart die Fehlersuche im PRTG-Log.

```powershell
cd 'C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML'
.\Intune-EntraID-PRTG.ps1 -AppId '<client-id>' -TenantId '<tenant-id>' -ClientSecret '<secret>'
```

**Gut** sieht so aus -- eine einzige Zeile, beginnend mit `<prtg>`:

```xml
<prtg><result><channel>Devices Total</channel><value>6</value><unit>Count</unit></result>...</prtg>
```

**Schlecht** ist alles andere, insbesondere:

```xml
<prtg><error>1</error><text>Token-Abruf fehlgeschlagen: ...</text></prtg>
```

Das ist kein Absturz, sondern die geordnete Fehlermeldung des Skripts.
Der Text nennt den Grund -- siehe [Troubleshooting](#11-troubleshooting).

Zum Gegenpruefen, ob die Ausgabe wirklich wohlgeformtes XML ist:

```powershell
$o = .\Intune-EntraID-PRTG.ps1 -AppId '<id>' -TenantId '<tid>' -ClientSecret '<secret>'
[xml]$x = $o
$x.prtg.result | Format-Table channel, value -AutoSize
```

---

## 6. Schritt 4: Sensor in PRTG anlegen

1. Geraet waehlen (sinnvoll: ein Geraet `Microsoft 365` / `Cloud`, nicht die Probe selbst)
2. **Add Sensor** -> nach `EXE/Script Advanced` suchen
3. Einstellungen:

   | Feld | Wert |
   |---|---|
   | **EXE/Script** | `Intune-EntraID-PRTG.ps1` |
   | **Parameters** | `-AppId "%appid%" -TenantId "%tenantid%" -ClientSecret "%secret%"` (siehe unten) |
   | **Environment** | *Default* |
   | **Security Context** | *Use security context of probe service* |
   | **Mutex Name** | z. B. `GraphApi` -- serialisiert mehrere Graph-Sensoren |
   | **Timeout (Sec.)** | `120` (Default 60 reicht bei grossen Tenants nicht) |
   | **Scanning Interval** | `15 Minuten` oder groesser |

4. Die Parameter konkret -- **Werte in Anfuehrungszeichen** setzen, das Secret
   enthaelt haeufig Sonderzeichen:

   ```
   -AppId "11111111-2222-3333-4444-555555555555" -TenantId "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" -ClientSecret "abc~1DEF..."
   ```

   Optional zusaetzlich:

   ```
   -StaleDeviceDays 30 -StaleDeviceWarnCount 10 -MaxSyncLagHours 3
   ```

> **Intervall:** Die Daten aendern sich langsam, und jeder Lauf zieht **alle**
> Geraete durch Graph. Unter 15 Minuten bringt keinen Mehrwert, kostet aber
> Laufzeit und Graph-Requests. 30 oder 60 Minuten sind bei grossen Tenants
> die bessere Wahl.

---

## 7. Parameter-Referenz

| Parameter | Pflicht | Default | Bedeutung |
|---|---|---|---|
| `-AppId` | ja | -- | Application (Client) ID der App Registration |
| `-TenantId` | ja | -- | Directory (Tenant) ID |
| `-ClientSecret` | ja | -- | Client Secret **Value** (nicht die Secret-ID!) |
| `-StaleDeviceDays` | nein | `30` | Ab wie vielen Tagen ohne Check-in ein Geraet als *stale* gilt |
| `-StaleDeviceWarnCount` | nein | `10` | Ab wie vielen stale Devices der Kanal auf Warnung geht |
| `-MaxSyncLagHours` | nein | `3` | Ab welchem Alter des letzten Entra-Connect-Sync gewarnt wird |
| `-GraphBaseUri` | nein | `https://graph.microsoft.com` | Nur fuer Sondertenants (US Gov, China) anzupassen |

---

## 8. Kanal-Referenz

| Kanal | Bedeutung | Default-Grenzwert |
|---|---|---|
| `Devices Total` | Alle Intune managed devices | -- |
| `Devices Windows` / `macOS` / `iOS` / `Android` / `Other OS` | Aufschluesselung nach `operatingSystem` | -- |
| `Compliant` | `complianceState = compliant` | -- |
| `Non-Compliant` | `complianceState = noncompliant` | **Warnung ab > 0** |
| `In Grace Period` | Noch in der Compliance-Karenzzeit | -- |
| `Compliance Error` | `error` oder `conflict` | **Warnung ab > 0** |
| `Compliance Unknown` | `unknown` -- meist Geraete, die sich nie gemeldet haben | -- |
| `Encrypted` | `isEncrypted = true` | -- |
| `Not Encrypted` | `isEncrypted = false` | **Warnung ab > 0** |
| `Stale (>N d no check-in)` | `lastSyncDateTime` aelter als N Tage **oder** nie gesetzt | Warnung ab `StaleDeviceWarnCount` |
| `Management State managed` | Sauber verwaltete Geraete | -- |
| `Management State stuck` | `retirePending`, `retireFailed`, `wipePending`, `wipeFailed`, `unhealthy`, `deletePending`, `retireIssued`, `wipeIssued` | **Warnung ab > 0** |
| `Entra Connect Enabled` | `1` = Hybrid-Tenant, `0` = Cloud-only oder nicht lesbar | -- |
| `Entra Connect Sync Age` | Alter des letzten Sync **in Minuten** | Warnung ab `MaxSyncLagHours * 60` |

Hinweise zur Interpretation:

- **`Stale` zaehlt `lastSyncDateTime`, nicht das Enrollment-Datum.** Ein vor zwei
  Jahren eingerolltes, aber taeglich eincheckendes Geraet ist gesund und zaehlt nicht.
- **`Encrypted` + `Not Encrypted` ergibt nicht zwangslaeufig `Devices Total`.**
  Bei Geraeten, fuer die Intune kein `isEncrypted` liefert (haeufig bei iOS/Android),
  ist der Wert `null` und wird in keinem der beiden Kanaele gezaehlt. Das ist
  erwartetes Verhalten, kein Zaehlfehler.
- **`Other OS`** ist die Restmenge (`Total` minus die vier bekannten Gruppen) und
  enthaelt z. B. Linux, ChromeOS oder Geraete ohne gesetztes `operatingSystem`.

---

## 9. Grenzwerte anpassen

Das Skript setzt nur sinnvolle Startwerte. **Aendere Limits nach dem ersten Lauf
direkt in PRTG** (Kanal -> *Edit* -> *Limits*), nicht im Skript -- so bleiben sie
bei einem Skript-Update erhalten.

Typische Anpassung: `Non-Compliant` mit Warnung ab `> 0` ist in groesseren
Umgebungen zu streng. Realistischer ist ein Schwellwert relativ zur Flottengroesse,
z. B. Warnung ab 5 % der Geraete.

---

## 10. Stolperfallen

### `Stale`-Kanalname enthaelt den Parameterwert

Der Kanal heisst `Stale (>30 d no check-in)`. Aenderst du spaeter
`-StaleDeviceDays` auf z. B. 14, heisst der Kanal `Stale (>14 d no check-in)` --
und **PRTG legt einen neuen Kanal an**. Der alte bleibt mit seiner Historie
bestehen, bekommt aber keine Daten mehr.

Willst du den Wert aendern und die Historie behalten, ist das nicht moeglich;
entscheide dich moeglichst vor dem Produktivstart fuer einen Wert.

### `Entra Connect Sync Age` erscheint nur bedingt

Der Kanal wird nur ausgegeben, wenn `onPremisesSyncEnabled = true` **und** ein
Zeitstempel geliefert wird. PRTG legt Kanaele beim **ersten** Scan an.

- Ist der Tenant beim ersten Scan Cloud-only, fehlt der Kanal dauerhaft. Kommt
  spaeter ein Entra Connect dazu, erscheint er beim naechsten Scan automatisch.
- Faellt der Sync-Status spaeter weg (z. B. Rechte entzogen), zeigt PRTG den
  Kanal weiter an, aber ohne neue Werte.

`Entra Connect Enabled` ist deshalb der verlaessliche Kanal, um zu sehen,
ob ueberhaupt ein Hybrid-Sync erkannt wird.

### Kanalnamen sind bewusst ohne Umlaute

Die Konsolen-Codepage beim Aufruf durch die Probe kann sonst kaputte Zeichen
erzeugen. Das Skript ist reines ASCII -- bitte beim Bearbeiten so lassen.

---

## 11. Troubleshooting

Der Sensor faellt fast nie mit "premature end of data" aus: bei Fehlern gibt das
Skript bewusst gueltiges Fehler-XML aus und beendet sich mit Exit-Code 0, damit
**PRTG die Klartext-Meldung anzeigt**. Die Meldung steht im Sensor unter
*Last Message*.

| Meldung / Symptom | Ursache | Loesung |
|---|---|---|
| `Token-Abruf fehlgeschlagen: ... AADSTS7000215` | Client Secret falsch oder abgelaufen | Neues Secret erzeugen, Sensor-Parameter aktualisieren |
| `Token-Abruf fehlgeschlagen: ... AADSTS700016` | `AppId` falsch oder App im falschen Tenant | Client-ID und Tenant-ID pruefen |
| `Token-Abruf fehlgeschlagen: ... AADSTS90002` | `TenantId` existiert nicht | Directory (Tenant) ID pruefen |
| `Graph-Abfrage fehlgeschlagen (403)` auf `managedDevices` | `DeviceManagementManagedDevices.Read.All` fehlt oder kein Admin Consent | Permission als **Application permission** setzen + Admin Consent |
| `Sync-Status nicht lesbar: ... (403)` | `Organization.Read.All` fehlt | Permission ergaenzen -- oder ignorieren, der Rest funktioniert |
| `Kein Entra Connect (Cloud-only Tenant).` | Kein Fehler | Tenant hat keinen Hybrid-Sync; Meldung ist rein informativ |
| Sensor: *Script not found* | Skript liegt nicht im EXEXML-Ordner der **ausfuehrenden** Probe | Datei auf die richtige Probe kopieren |
| Sensor: *... is not digitally signed* / *cannot be loaded* | ExecutionPolicy oder Mark-of-the-Web | `Set-ExecutionPolicy RemoteSigned` in 64- **und** 32-Bit, `Unblock-File` |
| Sensor: *Premature end of data* / *XML parse error* | Meist doch ein Fehler ausserhalb des Skripts (Profil-Skript schreibt nach stdout) | Skript manuell auf der Probe testen; `-NoProfile` verwenden |
| Sensor: *Timeout* | Grosser Tenant, Lauf dauert laenger als der Timeout | Timeout auf 120-300 s erhoehen, Intervall vergroessern |
| `Paging-Abbruch nach 200 Seiten` | Mehr als 200 Graph-Seiten | Sollte bei `$top=1000` erst jenseits 200.000 Geraeten auftreten -- dann Support kontaktieren |

Bei `429`/`503` (Graph-Throttling) wiederholt das Skript die Abfrage
automatisch bis zu dreimal mit steigender Wartezeit. Haeufen sich Timeouts,
ist meist das Scan-Intervall zu kurz.

---

## 12. Sicherheitshinweise

- **Das Client Secret wird als Kommandozeilen-Parameter uebergeben.** Es ist damit
  waehrend der Laufzeit in der Prozessliste der Probe sichtbar und liegt in der
  PRTG-Konfiguration. Behandle die PRTG-Installation entsprechend als
  schuetzenswert und beschraenke den Zugriff auf die Sensor-Einstellungen.
- Nutze **nur die beiden Read-Berechtigungen** oben. Die App braucht keinerlei
  Schreibrechte -- weder auf Geraete noch auf das Verzeichnis.
- Lege fuer den Sensor eine **eigene App Registration** an, statt eine bestehende
  mitzubenutzen. So laesst sich der Zugang isoliert widerrufen.
- Setze eine **Wiedervorlage vor dem Ablauf des Secrets**. Alternativ laesst sich
  die App auf Zertifikats-Authentifizierung umstellen; das Skript unterstuetzt
  aktuell nur Client Secrets.
- Der Sensor liest ausschliesslich und gibt **keine Geraete-, Benutzer- oder
  Standortdaten** aus -- nur aggregierte Zahlen.

---

## 13. Performance und Skalierung

Das Skript ist auf grosse Tenants ausgelegt:

- **`$select`** holt nur die acht tatsaechlich benoetigten Felder statt des vollen
  Geraeteobjekts -- das reduziert die Payload erheblich.
- **`$top=1000`** haelt die Seitenzahl klein.
- **Paging** ueber `@odata.nextLink` ist implementiert; ohne das fehlten ab
  dem 1001. Geraet schlicht alle weiteren.
- **Retry** bei `429`/`503` mit steigender Wartezeit (2 s, 4 s, 6 s).

Gemessen mit gemockter Graph-API (also ohne Netzwerk-Latenz), PowerShell 7.4:

| Geraete | Graph-Seiten | Reine Verarbeitungszeit | XML-Ausgabe |
|---|---|---|---|
| 6 | 2 | < 0,1 s | ~2,2 KB |
| 5.000 | 5 | ~2,3 s | ~2,0 KB |

Die reale Laufzeit wird von der Graph-Latenz dominiert, nicht von der
Verarbeitung. Rechne pro 1.000 Geraeten grob mit einem zusaetzlichen
Graph-Roundtrip. Bei mehr als ca. 5.000 Geraeten den Sensor-Timeout auf
120-300 Sekunden setzen und das Intervall auf 30-60 Minuten.

Die XML-Ausgabe waechst **nicht** mit der Geraetezahl, da nur aggregiert wird.

---

## Anhang: getestete Szenarien

Der Sensor wurde gegen eine gemockte Graph-API in folgenden Faellen geprueft --
in allen Faellen war die Ausgabe wohlgeformtes XML mit Exit-Code 0:

| Szenario | Ergebnis |
|---|---|
| Normalfall, gemischte Flotte ueber 2 Seiten | 18 Kanaele, Zaehlungen korrekt |
| Paging ueber 5 Seiten / 5.000 Geraete | `Devices Total = 5000` |
| Tenant ohne Geraete | Alle Kanaele `0`, kein Fehler |
| Cloud-only Tenant | `Entra Connect Enabled = 0`, Sync-Age-Kanal entfaellt, Hinweistext gesetzt |
| `Organization.Read.All` fehlt (403) | Geraeteteil vollstaendig, Sync-Fehler nur als Text |
| Ungueltiges Secret (401) | Sauberes `<error>1</error>` mit Klartextmeldung |
| Geraet ohne `lastSyncDateTime` (`0001-01-01`) | Korrekt als *stale* gezaehlt |
| Abweichende Parameterwerte | Kanalname und Limits uebernehmen die Werte |
