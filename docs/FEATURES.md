# Saved environments, user details and audit history

These features are available in the native GUI in development version 0.9.0.
They share the existing PowerShell core module; they do not add a web service.

## Saved environments

Use **Save / Manage...** in the toolbar to capture the current configuration
under a name such as Production or Test. Replacing a name requires confirmation
(default No). Delete removes only that saved configuration; it does not change
profile containers or the controls currently on screen.

A saved environment includes:

- Profile roots, audit destination and whether auditing was explicitly configured.
- Horizon server name as a reconnect hint.
- Theme, literal user filter, disk/AD age filters, issues-only and Check AD choices.
- Size highlighting, all ten column positions/widths, and sort direction/column.

Passwords, credentials, access tokens, certificate bypass, tickets/reasons,
WhatIf-off state, disabled lock checks and other live-operation choices are not
settings fields and are not captured. Settings are plain JSON, not a credential
vault. User-entered paths and filters are stored as text.

Select a name and click **Apply**. This clears profile rows and selection,
invalidates the scan, clears the reason and AD cache, disconnects Horizon, and
restores WhatIf, lock checking, preview and move-to-retired defaults. You must
load profiles again and explicitly reconnect Horizon. Applying never scans,
connects, logs off, retires or restores anything automatically.

The last saved/applied environment is restored on a normal subsequent launch.
Passing an explicit `-DefaultProfileRoot` skips startup environment restoration.
Changes to controls are saved only when you click Save; there is no autosave on
close. Apply remembers the selected name without recapturing unsaved controls.

The default per-user file is:

```text
%LOCALAPPDATA%\FSLogixProfileManager\environments.json
```

A portable/test host can supply an absolute store path:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\FSLogixProfileGUI.ps1 -EnvironmentStorePath 'D:\Operations\environments.json'
```

The schema is versioned and validated, including field types and column bounds.
Writes use a per-path mutex and atomic replacement. Malformed/newer schemas,
read errors, and saves exceeding the 4 MB limit fail visibly and preserve the
existing file. Back it up before editing it manually. The CLI continues to use
explicit parameters; it does not accept an environment name.

## User details

Select exactly one grid row and click **User details...**, or double-click a
row. Same-name users with different SIDs stay separate.

The resizable read-only dialog contains:

- Identity, SIDs, profile roots, and AD/health data from the last profile scan.
- **Live files:** every known physical container and recorded replica, current
  file size/time, full paths, and availability status.
- **Retired files:** associated retired containers, original live paths, and
  restore eligibility. This view does not perform restores or purges.
- **Audit history:** related intent, completion, displacement and rollback rows.
- **Horizon sessions:** session state and host when returned by the connected API.

Opening details reads file metadata, retired reports and audit CSVs. It does not
query SMB open handles, test exclusive locks, or query Horizon sessions until
**Refresh availability** is clicked. The refresh is read-only and best-effort.
NotChecked, NotConfigured, Unknown and unavailable sources remain explicit.
Large/remote stores can make these synchronous reads take time.
Horizon sessions are matched by username; a successful query does not verify
the session's SID against the selected profile. Review the returned session
username/domain before drawing identity conclusions.

AD state, signatures, health and maximum size remain scan metadata, clearly
labelled. Refresh does not run a new AD or VHD scan. A replica never inherits a
verified signature or maximum size from its primary copy.

Audit correlation prefers exact SID. Older rows missing SID can match exact
known live/retired paths; records carrying another explicit SID are excluded.
**Open audit history** prefilters the full search dialog by SID (or username
when SID is unknown). Legacy rows without SID may therefore require clearing
the SID filter in that search dialog. Old audit files are never rewritten.

## Searchable audit history

Click **Audit history...** to search the currently configured audit directory.
Use **Set...** to choose that directory or apply an environment containing it.
The viewer reads `actions_yyyy-MM.csv` files across months.

Filters combine with AND:

- User, ticket/reason and operator: literal, case-insensitive substrings.
- SID and action: whole-value, case-insensitive matches. All includes every action.
- From/Through: inclusive UTC calendar days, disabled until checked.

Click Apply to search, Clear filters to remove all limits, or Refresh to reread
files after new operations. Click column headers to sort; select a row to see
its complete record, source/destination paths and source CSV/row provenance.
STARTED, OK, FAILED and rollback records retain their original meaning; an intent
row alone is not proof that an operation completed. New restore/displacement/
rollback rows carry each file's own user and SID, including multi-user batches.

No matches and unavailable history are different states. A missing directory,
unreadable CSV, invalid timestamp, malformed quoting or required-column error
fails the entire query visibly, including errors in rows excluded by a filter.
The viewer never creates, repairs, truncates or appends to the audit source.
Retry Refresh after an active writer finishes; investigate persistent malformed
files without relying on a partial result.

## Verification and distribution

The test runner covers persistence, concurrent writes, corrupt/oversized stores,
real access-denied cases, fresh-process startup restoration, native buttons and
modal dialogs, real locks, CSV searches, identity isolation and cross-feature
navigation. Read-only tests compare profile/audit bytes before and after.

The portable CI artifact includes the three entry-point/core scripts plus the
required **Private/** and **UI/** directories. Keep those directories beside the
scripts. CI launches the relocated artifact in STA mode to catch missing runtime
files. No deployment is performed.

See [VERIFICATION.md](VERIFICATION.md) for actual test scope and infrastructure
checks still requiring AD, SMB, Horizon, Hyper-V and Cloud Cache labs.
