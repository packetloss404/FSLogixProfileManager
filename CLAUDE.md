# Guidance for coding agents

## Architecture and runtime

This is a Windows PowerShell 5.1 WinForms application and CLI, not a web app.
FSLogixProfileCore.psm1 owns discovery, naming, filters, health, AD, SMB probes,
Horizon, audit, retirement, restoration, and gated purge. It has no WinForms
dependency. FSLogixProfileGUI.ps1 and FSLogixResetProfile.ps1 are the hosts.
Keep core behavior in the module. Private/*.ps1 contains feature data helpers dot-sourced into that module; UI/*.ps1 contains feature dialogs dot-sourced by the GUI. Add public data functions to Export-ModuleMember. These directories are required runtime files and must ship with the scripts.

Use Windows PowerShell 5.1 to verify compatibility. The GUI requires STA:

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\FSLogixProfileGUI.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
```

The aggregate runner parses sources and invokes each Test-*.ps1 in an isolated
process with a timeout. Native GUI tests exercise actual WinForms controls and
modal dialogs against synthetic local containers. CLI tests execute child
processes. Adapter tests stub REST/Get-VHD and must not be described as live
external-service validation. See docs/VERIFICATION.md.

Some restricted Windows app sandboxes redirect TEMP into a package container
where .NET File.Move can be denied even after PowerShell creates a file. Use a
normal authorized Windows test process to distinguish that host restriction
from a product failure. Never weaken filesystem safety to satisfy the sandbox.

## Safety contracts

- GUI defaults to WhatIf. CLI does not: it uses SupportsShouldProcess with High
  confirmation impact, requires explicit selection, and requires a reason live.
- Never delete containers except in Remove-FSLogixRetiredContainer. Keep the
  retention floor, live-sibling/last-copy guard, undated opt-in, and revalidation.
- Check availability immediately before live mutation. A free-file result is a
  weak signal, especially with Cloud Cache. Do not promise absolute detection.
- Retirement and restore must preserve displaced files and attempt rollback on
  failures. Report incomplete rollback honestly. Preserve .restore.json sidecars
  and validate their relative paths before using them.
- An explicitly configured audit root is critical. Write intent before changes;
  fail closed on audit failure and report intent/completion/rollback separately.
  The default local audit root remains best-effort. ACLs are operator-managed.
- Unknown metadata, AD state, or session-query failure must not become healthy,
  unused, or no-session results. A required Horizon check must fail closed.
- The GUI supplies its own confirmations and passes -Confirm:$false to module
  actions. Its preview defaults to Cancel; native tests pin these controls.
- All-or-nothing preflight/rollback is per identity, not a transaction over the
  whole selected estate. The CLI provides an explicit partial-batch opt-out.

## PowerShell conventions

Collection-returning module functions use `return ,@($items)` to preserve empty
and one-item arrays. Callers must assign them directly: `$rows = Get-FSLogixProfiles`.
Wrapping these calls in `@(...)` creates a nested collection and breaks counts,
filtering, plans, and action execution. Add zero/one/many tests at boundaries.

Use -LiteralPath for existing operator paths; do not reuse automatic variables
such as $profile or $HOME. Use parameter validation for destructive selection.
Release streams, forms, timers, runspaces, and certificate callbacks in finally.
Keep logging out of success-stream return values. GUI state must be restored
after cancellation and exceptions; avoid tests that only regex-match source.

## Current product limits

Grouping uses SID when present, otherwise parsed username; equal usernames
with different SIDs remain separate rows. Normal GUI/CLI discovery does not
request VHD metadata or apply registry policy. CloudCacheMode and registry/VHD
metadata APIs exist in the module but are not selectable in entry points.
Horizon endpoint/build compatibility and real AD/SMB/Hyper-V/Cloud Cache behavior
need infrastructure validation. No installer or automated redeploy is configured.

README.md is the current operator guide, BACKLOG.md records remaining work,
and CHANGELOG.md records implementation changes. Keep them consistent with
executed evidence; old handoff claims are not current acceptance criteria.

## Saved environments, details and history

Environment storage is schema-versioned per-user JSON, overridden with GUI
-EnvironmentStorePath in tests. Always isolate this path in native tests.
Capture only whitelisted preferences, never credentials/tokens/tickets/TLS
bypass or live-operation choices. Apply must clear rows, invalidate the scan,
disconnect Horizon and restore safe defaults. Normal launch restores last
selection; an explicit -DefaultProfileRoot skips that startup restoration.

Audit search is strictly read-only, uses inclusive UTC dates and literal text
filters, and fails visibly on malformed/unreadable source files. Details prefer
exact SID and only use exact path fallback for old rows without SID. Never
combine different known SIDs because usernames happen to match. Detail opening
does not probe SMB locks/Horizon until Refresh availability is requested.

Restore audit rows must carry per-file identity in multi-user batches. Logging
callbacks must never emit host return values into the core success stream.
Keep feature data free of WinForms. Extend native and cross-feature tests when
changing dialogs, startup precedence, safety state or identity correlation.
CI smoke-launches the relocated portable artifact, including Private/ and UI/.
