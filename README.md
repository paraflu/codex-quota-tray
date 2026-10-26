# Codex Quota Tray

**Version:** v1.0

Codex Quota Tray is a lightweight Windows notification-area app for monitoring Codex quota from local session logs, with no API key or network connection required. Below is a screenshot of the tray icon.<br>
<img src="Codex%20Quota%20Tray.png" alt="Codex Quota Tray showing six days remaining" width="96">

For the macOS version, see [PlutaB/codex-quota-menubar](https://github.com/PlutaB/codex-quota-menubar).


## Run

Double-click `CodexQuotaTray.exe`. A compact indicator appears in the lower-right notification area (it may initially be in the `^` overflow menu). Hover or right-click it for quota details, refresh, session-log folder access, startup toggle, and quit.

### PowerShell UI

Run `Run-CodexQuotaTray.cmd` (or the command below without `-Once`) to use the redesigned PowerShell version: rounded quota bars, readable percentage/reset cards, and a compact color-coded tray icon. Left-click or right-click the icon to open the menu. The prebuilt `.exe` is unchanged.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexQuotaTray.ps1
```

UI smoke check (Windows, no real session logs required):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-QuotaTray.ps1
```

The indicator shows the first two quota windows in ascending duration (normally 5-hour and 7-day). Green means at least 40% remaining, amber means 20–39%, and red means below 20%.


## Command-line check

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CodexQuotaTray.ps1 -Once
```


## Startup

Right-click the tray icon and choose **Start at login**. This creates/removes a per-user Run registry entry, pointing to this script. Keep the folder in a permanent location if enabling this option.


## Author

[**PlutaB**](https://github.com/PlutaB)  

Adapted from [BowenZZZZZZZ/codex-quota-menubar](https://github.com/BowenZZZZZZZ/codex-quota-menubar)


## License

Copyright © 2026 PlutaB.  

Licensed under the MIT License. See [LICENSE](LICENSE).
