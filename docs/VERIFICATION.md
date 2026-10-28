# Verification scope

The automated suite uses Windows PowerShell 5.1, real local files and native
WinForms controls. All fixtures are disposable; no configured production root
should be scanned or mutated by a test. Run:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
```

The runner parses every PowerShell source and executes each suite in a fresh
STA process. Timeouts and failed assertions fail the run. CI uses the same
command on Windows Server 2022. There is no browser application in this repo;
following the user's clarification, native GUI tests cover the application.

Version 0.9.0 verification on 2026-10-28 under Windows PowerShell 5.1 covers
12 suites and 647 assertions: core (41), lifecycle (90), main GUI (87), CLI (81),
adapters (52), environment API (68)/GUI (65), audit API (38)/GUI (32), details
API (43)/GUI (29), and cross-feature navigation (21). These describe local
fixtures and stubbed adapters, not distinct production integrations. Syntax
validation and a relocated portable-bundle STA smoke launch are also checked.
The final aggregate run passed all 647 assertions. Missing Private/ and UI/
dependencies were also checked to produce explicit startup errors.

## Advertised-feature coverage

| Feature | Automated evidence | Limit |
| --- | --- | --- |
| Saved environments and last-selection startup restore | Real JSON, concurrent writers, near-limit saves, ACL denial, corrupt schemas, actual Save/Apply/Delete controls and fresh child processes | Explicit Save only; no credentials or live-operation settings |
| Per-identity details and explicit availability refresh | Real local files/locks, replica expansion, native tabs/controls, full paths and read-only byte comparisons | AD/health/signatures are scan metadata; real remote sessions remain unverified |
| Searchable audit history | Multi-month UTF8 CSVs, literal and UTC-date filters, sorting, full records, malformed/locked files, Dark theme and unchanged source hashes | Synchronous reads can take time; malformed files fail the entire query |
| Feature navigation and restore/history identity links | Actual environment Apply, main Details button/double-click, nested history dialog, and real multi-user retire/restore audit queries | Legacy rows without SID use exact path fallback in details only |
| Standard folder orders, flat names, container classes | Core and lifecycle suites scan synthetic directory layouts | Custom FSLogix naming policies need lab validation |
| Sidecar/retired/superseded exclusions, zero/one/many users | Core, lifecycle, CLI and GUI suites inspect real local fixtures | UNC permissions and partial network outages need a file server |
| Multi-root discovery and logical replica plans | Lifecycle suite mutates every recorded replica; CLI scans independent roots | No real Cloud Cache cache/resync traffic is generated |
| Incomplete scans and missing roots | GUI preserves rows but disables reset; CLI child processes test real ACL-denied enumeration | Network outages still need a file server |
| User, age, AD-age and issues filters | Core/lifecycle tests and actual GUI/CLI inputs | AD timestamps in local tests are synthetic |
| Grid columns, sorting/reordering and CSV | Actual WinForms grid, filters and CSV export in GUI suite | Full SID export is checked; visual usability still needs human review |
| Light/Dark, health/size colors, long logs | Actual controls and appearance state in GUI suite | No screenshot-based visual baseline |
| Background discovery, cancel and cleanup | Real runspace, timer/message loop and GUI controls | Does not reproduce large estate network latency |
| Simulation, scopes, reasons, explicit selection | Child CLI processes and native GUI controls; files checked before/after | Diagnostic log writes are allowed in simulation |
| Live move/in-place retirement and restore metadata | Lifecycle/CLI tests mutate fixtures and verify resulting files | No FSRM/ACL configuration is performed |
| Lock detection and per-user batch atomicity | Actual exclusive file handles, preflight and injected failures | SMB handles/leases and Cloud Cache sessions require a lab |
| Restore, displacement and rollback | Lifecycle tests compare real file content and preserve live siblings | Basic signature fixtures are not mountable VHD images |
| Retired age/report, purge, last-copy/undated guards | Lifecycle tests revalidate stale/spoofed report input | Concurrent remote changes cannot be made transactional |
| Audit intent/completion/failure/rollback | Real CSV output and deliberately unavailable audit roots | Append-only ACL enforcement is outside this application |
| Preview/confirmation, default Cancel, typed count | Native GUI suite creates actual dialog controls | Human/operator procedures are not automated |
| Horizon login/session/logoff adapter | Stubbed Invoke-RestMethod requests, token/header/ID checks, callback cleanup | No Connection Server login or build compatibility verified |
| Horizon gate fail-closed behavior | Local lifecycle fixtures plus controlled query results | Session payload pagination/API versions still need validation |
| VHD/VHDX signature and size health flags | Real byte fixtures; Get-VHD success/failure adapter stubs | Hyper-V and filesystem corruption diagnostics not validated |
| AD unavailable state / LDAP escaping | Local disabled-state and escaping checks | SID binds, trusted domains and COM timestamps need a domain |
| CLI safety/exit statuses/parameters | Real noninteractive child processes with captured output and timeouts | Live production confirmation remains an operator responsibility |

Suite responsibilities:

- `Test-FSLogixProfileCore.ps1`: original pure-logic/discovery regression suite.
- `Test-FSLogixLifecycle.ps1`: real retirement, restoration, purge and failure paths.
- `Test-FSLogixResetProfile.ps1`: CLI process and filesystem end-to-end workflows.
- `Test-FSLogixProfileGUI.ps1`: native WinForms controls, dialogs and background scan.
- `Test-FSLogixIntegrations.ps1`: local lock/signature checks and stubbed service adapters.
- `Test-FSLogixEnvironments.ps1` / `Test-FSLogixEnvironmentGUI.ps1`: persistence,
  validation, file access, safe application, and startup restore/override.
- `Test-FSLogixAuditHistory.ps1` / `Test-FSLogixAuditHistoryGUI.ps1`: strict
  read-only CSV search and native filters/sorting/error states.
- `Test-FSLogixProfileDetails.ps1` / `Test-FSLogixProfileDetailsGUI.ps1`: identity
  correlation, snapshot/refresh semantics, and actual native detail views.
- `Test-FSLogixFeatureIntegration.ps1`: saved configuration to scan to selected
  user details to audit search, including same-name SID separation.
- `Assert-PortableBundle.ps1 -BundlePath <folder>`: additional CI smoke launch
  of the relocated artifact, outside the numbered regression assertions.

## Required infrastructure validation before operational rollout

Use disposable test users and backed-up containers in a dedicated lab share.
First run WhatIf, review the plan, and then repeat live with a ticket and an
operator-controlled audit directory. Confirm container bytes are recoverable
through a retire/restore cycle and inspect audit intent and completion rows.

Repeat with an actively mounted container and with a disconnected Horizon
session. Both should prevent retirement when the relevant checks are enabled.
Make the session API/audit destination unavailable and confirm required checks
fail closed. Test from the same operator account and host used operationally.

For Cloud Cache, test every provider, provider outages during mutation,
resynchronization after logon, and incomplete rollback recovery. Do not infer
this behavior from same-machine replica fixtures. For AD, verify real SID-first
lookup, disabled/renamed/trusted accounts, and replicated timestamp conversion.
For Hyper-V/registry integration, use real session-host policy and mountable
VHD/VHDX images. Validate the Horizon REST paths and response shapes on the
installed version, including large/paginated session inventories.

## CI and distribution

`.github/workflows/windows-tests.yml` runs on pushes, pull requests, and manual
dispatch. Only a passing test job packages the three scripts, required Private/
and UI/ sources, docs and license as a commit-labelled portable artifact with
build-info.json. CI smoke-launches that relocated bundle before upload. No credentials,
profile data or operator logs are packaged. Artifact creation is not deployment.
The user explicitly requested no redeployment for this task.
