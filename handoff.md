# Repository handoff

The August 2026 handoff that described unconnected entry points is obsolete.
Both entry points use FSLogixProfileCore.psm1. README.md describes current
behavior; docs/VERIFICATION.md records test scope and missing infrastructure
validation; BACKLOG.md tracks remaining work.

Run the complete Windows PowerShell 5.1 native/CLI suite with:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
```

Do not infer production AD/SMB/Horizon/Cloud Cache compatibility from local
fixtures or stubbed adapter tests. Redeployment was explicitly excluded from
the October 2026 verification task.
