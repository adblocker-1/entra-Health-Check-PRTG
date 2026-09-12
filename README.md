# entra-Health-Check-PRTG

PRTG **EXE/Script Advanced** Sensor fuer Microsoft **Intune** und **Entra ID (Azure AD) Connect Sync**.

Ein einzelnes PowerShell-Skript, keine externen Module. Es fragt die Microsoft Graph API
per OAuth2 Client Credentials ab und liefert 17-18 PRTG-Kanaele:
Geraetezahlen nach Betriebssystem, Compliance-Status, Verschluesselung,
"stale" Geraete ohne Check-in, haengende Management-States und das Alter
des letzten Entra-Connect-Sync.

| Datei | Zweck |
|---|---|
| [`Intune-EntraID-PRTG.ps1`](Intune-EntraID-PRTG.ps1) | Das Sensor-Skript |
| [`ANLEITUNG.md`](ANLEITUNG.md) | Vollstaendige Einrichtung: App Registration, Rechte, Sensor, Troubleshooting |

## Schnellstart

1. App Registration in Entra ID anlegen, Application Permissions
   `DeviceManagementManagedDevices.Read.All` + `Organization.Read.All` erteilen und
   **Admin Consent** geben.
2. `Intune-EntraID-PRTG.ps1` auf der PRTG-Probe ablegen unter:
   `C:\Program Files (x86)\PRTG Network Monitor\Custom Sensors\EXEXML\`
3. Manuell testen:
   ```powershell
   .\Intune-EntraID-PRTG.ps1 -AppId '<client-id>' -TenantId '<tenant-id>' -ClientSecret '<secret>'
   ```
   Erwartet wird eine einzelne Zeile, die mit `<prtg>` beginnt und mit `</prtg>` endet.
4. In PRTG einen Sensor **EXE/Script Advanced** anlegen, das Skript auswaehlen und
   die Parameter setzen.

Details, Kanal-Referenz und die typischen Stolperfallen stehen in der
[**Anleitung**](ANLEITUNG.md).
