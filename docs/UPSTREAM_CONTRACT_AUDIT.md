# Official CLI contract audit

## Evidence and scope

The implementation baseline is the latest stable macOS release returned by GitHub on 2026-10-24: **V1.62.0**, commit `91a7bf44f96995361b10b5a0e9efae36a1490bf9`, released 2026-10-21. The repository's then-current `main` was `db704956981f7c1c6d2b4b51ad13eafd9fef3b79`; `main` is not a stable release. Public status/analyze/history/uninstall schema files showed no changes in the inspected stable-to-main diff. That comparison does not validate every newer implementation change.

Reviewed source includes the top-level router, shared command/help catalog, every command entry script, update/remove/version helpers, status metric structs and watch scheduler, analyze JSON and scan states, history parser/renderer, uninstall inventory/name matching, optimize task catalog, purge artifact metadata and project safety checks, and slim copy/signature/replace behavior. Latest README_TW, llms.txt and security documentation were reviewed separately by the integration owner.

## Contract findings that materially affect design

### 1. JSON surfaces are narrower than the feature list

Official structured surfaces are `status --json`, `status --watch` (NDJSON), `analyze --json`, `history --json`, and **`uninstall --list` with piped stdout**. The latter auto-switches to JSON; it does not accept a `--json` flag.

Clean, Optimize, Purge, Installer and Slim must keep official output and interactive controls. Their text is not a stable item-level deletion API. Clean explicitly rejects selector/category/exclusion flags. Reconstructing a deletion engine from those lines would violate the requested separation and could delete different objects after a rescan.

### 2. App selection is by name, not filesystem identity

The list includes `name`, `bundle_id`, `source`, `uninstall_name`, `path`, and human `size`. Name matching can use the first exact display/bundle-directory match or multiple fuzzy matches. A Cask alias is not necessarily an exact display-name match. Native selections therefore need an additional uniqueness/binding guard, an inventory refresh, and official final confirmation. Ambiguity returns the user to the original selector. Paths are shown for inspection and icon retrieval; they are never passed to a private deletion routine.

Default uninstall mode uses Trash. Personal-data preselection requires `--with-data`; it is not enabled by an inherited environment variable. `--permanent` is a distinct opt-in. V1.62.0 requires a foreground interactive terminal for real uninstall confirmation; dry-run with explicit names may safely end after its plan without a terminal.

### 3. Monitoring should preserve a warm collector

`status --watch --interval 2s` emits one full JSON object per line from one collector. Disk rates use **MB/s** (`read_rate`, `write_rate`); network rates use **MB/s** (`rx_rate_mbs`, `tx_rate_mbs`). The first fast sample can precede full enrichment. Nullable arrays are normal. `per_core_estimated`, `process_collected_at`, and `process_stale` carry important qualifications. Nonpositive thermal/power values generally represent unavailable readings in upstream presentation. No missing hardware data should become a fake zero-value gauge.

The watch reader uses bounded streaming framing, preserves split UTF-8 bytes, rejects truncated/oversize records, and stops on schema failure. A view does not repeatedly create one-shot collectors to simulate watch mode.

### 4. Analyze coverage is not a binary success flag

`scan_status` is `complete`, `partial`, or `unavailable`, both at the root and per entry. Partial size is a measured lower bound, unavailable size is unknown, and a genuinely complete zero-size item is distinct. Sizes remain 64-bit integers, avoiding JavaScript's 53-bit integer boundary. Unknown scan-state values are rejected until their semantics are understood.

Native `--json` analysis is read-only. The original interactive analyzer exposes file operations, so merely opening that TUI is classified as destructive-capable and requires confirmation. No native trash implementation bypasses Mole's protection logic.

### 5. History is a reconstruction of logs

History returns `logs`, `limit`, `sessions`, and `deletions`. Sessions carry `run_id` and `attribution` values (`run`, `command`, `ambiguous`), start/end strings, optional item totals, size text, operation/failed-task counts, and separate action counters. Deletion entries can have `size_kb: null`. Not every deletion can be safely joined to one session. An empty end time is unfinished, not successful. The GUI must preserve those distinctions and show raw official results for detail.

### 6. Configuration commands are operations

`clean --whitelist`, `optimize --whitelist`, `purge --paths`, bare `completion`, Touch ID enable/disable, update, and remove change configuration or installed files. They are not silently run during discovery. `completion bash/zsh/fish` only emits source text, which the GUI displays without evaluation. `purge --paths` opens an editor rather than accepting a path argument. Bare `mo` can reach destructive features and is not classified as a read-only probe.

### 7. Version text alone does not establish a stable build

Official Nightly/HEAD builds can retain the numeric release version. Full `--version` output contains `Channel: Nightly` or Homebrew `HEAD` identity. The compatibility layer checks these markers, the major/minor floor, per-command help tokens, and actual JSON decoding. It does not claim a future implementation is audited just because known flags still exist. Original confirmations remain active.

The official script updater explicitly checks `nightly`/`dev` receipts, sets `switch_to_stable_channel=true`, resolves a published stable version, and runs the installer with that stable tag. Therefore the compatibility layer permits a narrow recovery exception: verified official-script source/resources, recognized same-major numeric version at or above the audited floor, complete update help contract, and `mo update` without `--nightly` (optional `--force`/`--debug`). All other mutations remain blocked, and the installed engine is re-probed afterward. A `dev` receipt is inspected directly because upstream `show_version` does not print a Channel line for it. The exception excludes unknown sources, malformed/changed help, older/new-major versions, and Homebrew HEAD.

For Homebrew, Mole's `update_via_homebrew` only executes `brew update` then `brew upgrade mole`. Homebrew documents that upgrades retain the original installation options, so this is not a HEAD-to-stable switch. Stable Homebrew upgrades remain supported; HEAD is not granted a misleading recovery exception. Sources: [Mole stable updater](https://github.com/tw93/Mole/blob/V1.62.0/lib/manage/update.sh), [Mole Homebrew implementation](https://github.com/tw93/Mole/blob/V1.62.0/lib/core/common.sh), [Homebrew upgrade documentation](https://docs.brew.sh/Manpage#upgrade-options-installed_formula--installed_cask-).

### 8. Updates remain separate

The GUI calls the installed executable and leaves core resources in their official installation location. `mo update` respects installation source; nightly availability is restricted. No official source is rewritten or copied into a permanent GUI-owned engine. Runtime identity is rechecked before launch and rediscovered after update/removal.

`MoleExecutableLayout` resolves the selected symlink, the official `mo` alias's adjacent `mole` launcher, and the launcher's actual resource tree. Official installer `SCRIPT_DIR` literals are decoded without sourcing/evaluating shell text, including escaped spaces and ANSI-C octal UTF-8. A custom path never silently falls back to another installation. A pinned but missing resource tree never borrows an unrelated adjacent/default receipt. Mutations are blocked when a real launcher's resources cannot be identified. The engine fingerprint includes launcher and shell-resource contents plus resource-file metadata; a changed installation requires fresh detection. The full version output is inspected for nightly/HEAD channels, even when its numeric version is stable. Release checking ignores the repository's separate `-windows` releases.

The service retains ownership of a cancelling status watcher until the guardian has reaped it and drained both pipes. Scans, mutation sessions, and Homebrew installation reserve the operation slot and await that completion before launch; the engine is revalidated after the wait. Cancelled capture output is not accepted as a scan result. Main-menu access is disabled if any command contract or observed JSON schema is incompatible, and re-detecting unchanged engine bytes does not erase a schema failure. Test launch modes fail before CLI detection if the bundled mock is missing; they never fall back to a real installation.

The discovery/layout and adapter/model tests run on the Linux Swift runtime; see `DISCOVERY_CORE_TEST_OUTPUT.txt` for the current counts. This proves the pure Foundation contracts and fixtures, not native macOS UI integration or real-engine cleanup. The AppModel/CLIProbe lifecycle changes have been syntax-parsed; Apple SDK typechecking and app smoke execution still require a macOS builder.

## Validation performed for these contracts

The pure Swift module compiled with Swift 6.4.1 on Linux. XCTest exercises schema decoding and error paths, special filenames, 25,000 analysis entries, 64-bit size preservation, exact app binding, command option validation, safe argv, default data retention, capability drift, nightly/new-major blocking, and NDJSON boundaries. An additional test compares required flags against actual V1.62.0 help text instead of a synthetic mirror of the adapter.

The history fixture was generated by actually executing V1.62.0's read-only `bin/history.sh --json --limit 200` against two synthetic logs in an isolated directory. Other metric/inventory fixtures are explicitly synthetic because this environment is not macOS. No real cleanup, uninstall, optimization, installer removal or slimming was performed. Passing these tests does not validate AppKit/SwiftUI, signing, Apple Silicon execution, Instruments measurements, or real administrator authorization; those are separately reported in `TEST_REPORT.md`.
