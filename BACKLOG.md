# Remaining work

The GUI and CLI both import the shared core module. Older descriptions saying
that migration has not happened are obsolete. The October 2026 test pass fixes
local workflow defects and adds automated native WinForms, CLI, lifecycle, and
adapter tests. See docs/VERIFICATION.md for exactly what is covered.

## Requires an infrastructure lab

- Exercise real SMB admin open-file lookup, UNC permissions, server-local path
  mapping, unavailable roots, concurrent operators, and file-server outages.
- Verify ADSI SID-first lookup, renamed/trusted-domain accounts, disabled users,
  and IADsLargeInteger lastLogonTimestamp against a domain controller.
- Validate Horizon login/session payloads and REST endpoint versions against the
  installed build. Test TLS, pagination, token expiry, and disconnected sessions.
- Validate Get-VHD on real dynamic VHD/VHDX containers and local/remote registry
  policy reads from an FSLogix session host.
- Test Cloud Cache provider resynchronization, mid-operation outages, rollback
  failures, and recovery in a disposable multi-provider setup. Local replica
  fixtures do not establish Cloud Cache operational safety.
- Verify operator-only ACLs and quota exclusions for _retired and audit storage.
  The application does not configure either.

## Product work not currently wired into entry points

- Explicit Cloud Cache mode and provider configuration in GUI/CLI.
- Optional VHD metadata/registry policy loading in GUI/CLI. Normal scans leave
  Max GB unknown and do not validate container signatures.
- Configurable Horizon API versions, pagination, token refresh/logout, and a
  separately reviewed logoff/clone-refresh workflow.
- Recovery UI for superseded containers and pre-manifest managed retirements.
- Persist user settings between application launches.
- Add an installer or an explicitly configured deployment destination if needed.

## Possible future scope

Container compaction, VHD repair, read-only mounting for file recovery,
per-folder ACL validation, JEA authorization, and GUI keyboard shortcuts are
not implemented. Scheduled use can call the CLI with explicit selection,
reason, audit root, and confirmation policy.
