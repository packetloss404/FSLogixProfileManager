# FSLogix Profile Manager (Horizon IC)

Windows PowerShell scripts for inspecting and retiring FSLogix profile containers:
`FSLogixProfileGUI.ps1` is a WinForms application and `FSLogixResetProfile.ps1` is
a CLI. Both use `FSLogixProfileCore.psm1`. The current development version is 0.8.0.

Retirement preserves containers with a timestamped `-old-yyyyMMdd-HHmmss` name.
Only the explicit retired-container purge operation deletes files.

## Run

Requires Windows and Windows PowerShell 5.1, access to the selected profile
roots, and permission to perform the chosen operation. Start the GUI in STA:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\FSLogixProfileGUI.ps1
```

Set **Profile Root** before loading; the historical default is
`\\fml-fslogix\FSLogixUserProfiles`. Separate roots with semicolons.
The GUI starts in **WhatIf** mode. Select rows deliberately, review the preview,
and supply **Reason / Ticket** before a live reset.

## Discovery and inspection

- Discovers `.vhd` and `.vhdx` files recursively; excludes Cloud Cache sidecars,
  superseded files, and the managed `_retired` tree from active-profile scans.
- Recognizes `SID_username` and `username_SID` directories and standard
  `Profile_username`, `ODFC_username`, and `O365_username` flat filenames.
- Groups by SID when present, otherwise by parsed username. Two SIDs with the
  same username remain separate rows; it does **not** merge extra SIDs into one
  user. Profile and Office containers for the same identity share a row.
- Grid shows user, container count, on-disk size, maximum size when known,
  Office size, last write, health, SIDs, AD last logon, and root folder.
- Supports column sorting, retained sort order across filtering/rescanning,
  column reordering, CSV export with full SID values, literal substring username
  filtering, on-disk age, AD last-logon age, and issues-only filtering.
- Light/Dark themes, health-priority row highlighting, size highlighting, a
  resizable log panel, and cancellable background discovery.

Both entry points refuse incomplete scans. The GUI disables Reset after root
edits, a cancelled scan, or a scan error until a complete scan succeeds.

**Size (GB)** is the container file's size on disk, not used space inside its
filesystem. `EMPTY` means the file is smaller than 0.001 GB. `CORRUPT` is an
administrator-supplied filename marker, not a complete corruption diagnosis.
Signature checks detect basic VHD/VHDX header/footer problems only.

Normal GUI/CLI scans do not request VHD metadata or load registry policy, so
**Max GB is normally blank**, and signature/near-limit checks are not performed
by those scans. Module callers can opt in with `Get-FSLogixProfiles
-ReadVhdMetadata`, `-ConfiguredMaxSizeGB`, and `-ConfiguredOfficeMaxSizeGB`.
`Get-FSLogixSettings` reads local/remote registry policy as a module API; neither
entry point automatically applies it.

**Check AD** uses ADSI without the AD PowerShell module. Unknown/failed AD
lookups must not be interpreted as orphans or stale accounts. The AD age filter
excludes unknown dates. `lastLogonTimestamp` is replicated and approximate.

## Retirement and recovery

- **WhatIf** logs and reports planned actions without moving containers or
  appending audit action rows. It can create per-user diagnostic logs in `%TEMP%`.
- Scope is All, Office (`ODFC`/`O365`), or Profile; unknown filenames are included
  only by All. The GUI's Office and Profile checkboxes are mutually exclusive.
- **Skip in-use** defaults on. SMB open-handle lookup is attempted where possible,
  otherwise a local exclusive-open probe is used. These are best-effort checks:
  a free provider file does not prove a Cloud Cache user is logged off.
- Live GUI runs require a reason, preview/confirmation, and deliberate selection.
  The preview defaults to Cancel; large selections require a typed count.
- **Move to retired** defaults on in both entry points. Files move to
  `<root>\_retired\<user>\<stamp>\` with `.restore.json` sidecars recording the
  original relative paths. Keep those sidecars with the files. The tool does
  **not** configure ACLs or FSRM quotas: protect `_retired` and the audit directory
  with operator-only permissions, and configure quotas yourself.
- Per-identity retirement uses all-or-nothing preflight/rollback in the GUI and
  by default in the CLI. This is best-effort rollback, not a distributed storage
  transaction; a rollback failure requires manual recovery and is reported.
- The **Retired...** dialog reports retired files separately, restores selected
  batches, and offers explicitly confirmed purge. Restore verifies signatures,
  checks locks, and preserves an existing live sibling as `-superseded-<stamp>`.
  Managed files with missing/invalid restore metadata require manual recovery.
- Purge rechecks the file, retirement date and live sibling at execution time.
  The retention floor defaults to 90 days. Last-copy deletion requires
  `-AllowLastCopy`; undated legacy `-old` files require `-IncludeUndated`.
  The dialog requests explicit confirmation for these exceptions.

Audit CSVs are appended monthly under
`%ProgramData%\FSLogixProfileManager\Audit`, or the root selected via **Set...** /
CLI `-AuditRoot`. Explicit audit-root write failure aborts before mutation;
subsequent critical audit failure triggers rollback for retirement/restore.
Audit rows distinguish intent (`STARTED`), completion, failure, and rollback.
CSV append behavior alone does not enforce immutable or tamper-proof storage.
The default local audit root is best-effort and can fail with a warning.

**Horizon...** connects to an optional Connection Server. When connected, GUI
retirement requires the session check; both connected and disconnected sessions
block it, and a failed query aborts. There is no automatic logoff/reset-clone
workflow. Module callers can use `-RequireHorizonCheck` explicitly. The CLI has
no Horizon connection parameters. REST endpoint compatibility with your Horizon
build must be checked in a lab before use. Certificate bypass is a lab option
scoped to requests for that connection.

## CLI

A bare invocation is refused. Specify `-User`, positive `-LastUsedDays`, or
explicit `-All`. CLI `-User` values are PowerShell wildcard patterns (unlike the
GUI's literal substring field). Live mode requires `-Reason` and prompts unless
`-Confirm:$false` is supplied. **CLI does not default to WhatIf.**

```powershell
# Safe plan for one user; writes a diagnostic log, no container changes.
.\FSLogixResetProfile.ps1 -ProfileRoot 'D:\LabProfiles' -User alice -WhatIf

# Inspect wildcard matches without resetting.
.\FSLogixResetProfile.ps1 -ProfileRoot 'D:\LabProfiles' -User 'vdi*' -LastUsedDays 60 -ListOnly

# Live Office retirement, with confirmation and central audit.
.\FSLogixResetProfile.ps1 -ProfileRoot '\\fs1\Profiles' -User alice -Scope Office -Reason 'CHG1234' -AuditRoot '\\fs1\Operations\Audit'

# Multiple roots are scanned as independent shares, with batch preflight/rollback.
.\FSLogixResetProfile.ps1 -ProfileRoots '\\fs1\Profiles','\\fs2\Profiles' -User 'vdi*' -WhatIf
```

`-CheckInUse:$false` disables lock checking. `-Force` permits unresolved
identities; it does not bypass locks or auditing. `-MoveToRetired:$false` uses
in-place timestamped retirement. `-AllOrNothing:$false` permits partial batches.
Failures, missing targets, and aborted batches return a nonzero exit code;
zero matches and an operator-cancelled confirmation return zero.

Multiple roots alone do not enable Cloud Cache de-duplication. That is available
only through `Get-FSLogixProfiles -CloudCacheMode` in the module. The module
retirement plan includes every recorded physical replica. Neither GUI nor CLI
has a Cloud Cache mode selector, and provider/session behavior is not validated
against a live Cloud Cache deployment.

## Tests and verification limits

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
```

This runner parses the PowerShell sources, runs each suite in a separate
Windows PowerShell 5.1 STA process, enforces a per-suite timeout, and fails on
any failed suite. No Pester, browser, AD, Hyper-V, or network share is needed.
The GUI tests instantiate actual WinForms controls, run modal dialogs with a
message loop, and exercise the scan runspace against synthetic local files.
CLI tests launch real child processes and inspect filesystem results.

See [verification coverage and remaining lab checks](docs/VERIFICATION.md).
Local fixtures and stubbed service responses do **not** establish end-to-end
compatibility with production SMB, AD, Horizon, Hyper-V, or Cloud Cache.

GitHub Actions runs the same Windows suite on pushes and pull requests and
uploads a portable script bundle only after tests pass. This is a CI artifact,
not an installer or deployment. No automatic redeployment is configured.

See [CHANGELOG.md](CHANGELOG.md) and [BACKLOG.md](BACKLOG.md).
