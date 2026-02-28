# rnl-sync-core-kit

Local-first sync core primitives and queue orchestration.

## Scope

This framework provides CloudKit-free sync primitives that can be reused across apps:

- `SyncOperation` and `SyncOperationType`
- `SyncOperationQueue` with coalescing, persistence, retry/backoff
- `SyncCoordinator` for multi-store full sync orchestration
- `LocalFirstSyncStore` protocol for local-first store implementations
- `UserDefaultsSyncOperationStore` persistence adapter

## Release Automation (No GitHub Actions)

Use the local release script instead:

1. Build in release mode
2. Run tests
3. Auto-bump SemVer tag (`v0.1.0`, `v0.1.1`, ...)
4. Push tag
5. Create GitHub Release notes

Command:

```bash
scripts/release_local.sh
```
