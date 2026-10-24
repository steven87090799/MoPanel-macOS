# Startup and Background Items — MoPanel implementation

This module is an independent MoPanel addition. It is not part of the free Mole CLI and does not reuse the closed-source Mole for Mac startup implementation. It provides a bounded native inventory, reviewable control of a narrow class of own-user LaunchAgents, and an explicit handoff to macOS System Settings for other login/background items. It is **not full parity** with every official paid-GUI startup feature.

## User-visible behavior

The Startup screen reads plist metadata only after the user chooses **Read / Refresh**. It shows the label, program, arguments, exact file path, source, errors, and separately verified loaded state and explicit launchctl enable/disable override. Search, source filters, a manageable-only filter, Finder reveal, cancellation, individual state rechecks and confirmation sheets are native SwiftUI controls.

An absent `print-disabled` entry means **no explicit launchctl override**. It does not imply enabled, running or disabled. A plist's `Disabled` field is displayed separately. A loaded job does not necessarily have a currently running process; a PID is shown only when present in verified output. Permission errors, unrecognized output, changed files and incomplete results remain unknown.

## Inventory and ownership boundary

| Source | Read behavior | Native mutation |
|---|---|---|
| `~/Library/LaunchAgents` | Bounded direct-child XML/binary plist metadata | Only validated own-user third-party items |
| `/Library/LaunchAgents` | Bounded metadata, shared source marked read-only | None; System Settings handoff |
| `/Library/LaunchDaemons` | Bounded metadata, daemon source marked read-only | None; System Settings handoff |
| `/System`, private BTM databases, embedded app helper registrations, arbitrary folders | Not inventoried | None |

Limits are 128 KiB per file, an 8 MiB aggregate read reservation (including malformed plists), 512 directory entries per source, and no recursive descent. State queries have a 3-second child timeout, a 20-second refresh query budget, and a 160-row query cap. Remaining rows can be checked individually; there is no background polling or installed service. Queries may exceed the overall refresh deadline by the last in-flight child timeout/cleanup interval.

The reader rejects symlinked plist paths, nonregular or multiply linked files, invalid schemas, custom XML entities, unsafe labels and over-limit data. File identity includes device, inode, owner, mode, size and nanosecond modification/change timestamps. A snapshot also retains the exact bounded plist bytes and parent-directory identity for revalidation. Raw plist contents and launchctl environment dictionaries are never exported or logged.

Native changes require current-user ownership of both plist and direct parent, no group/world write permission, an absolute existing nonsymlink executable path and an unambiguous label. Apple labels/files and known Apple executable locations, Buho-related labels/paths/arguments, privileged user/group/root-directory overrides, duplicate labels and unclear ownership are read-only. These are conservative metadata checks, not a cryptographic assertion that an existing vendor program is trustworthy. The confirmation names the program that launchd may execute.

## Explicit mutation protocol

All commands execute `/bin/launchctl` with an argument array through `ManagedProcess` and `MoPanelGuardian`. There is no shell interpolation, arbitrary command editor, sudo, root GUI, plist rewrite or file deletion.

| Confirmed action | Typed argument steps | Verified result |
|---|---|---|
| Enable own-user agent | `enable gui/<uid>/<label>`, then `bootstrap gui/<uid> <exact-plist-path>` only if not loaded | Enabled override and loaded service with the same plist/program identity |
| Disable own-user agent | `disable gui/<uid>/<label>`, then `bootout gui/<uid>/<label>` only if loaded | Disabled override and verified absence of the loaded service |

Before presenting a plan, MoPanel rereads the original plist and live state. Confirmation repeats inventory/uniqueness checks, rejects incomplete or unreadable applicable inventory, compares exact metadata/bytes, and checks the reviewed state again. Each subsequent mutation step repeats identity validation and verifies the preceding override and service identity. Root/effective-user mismatches are rejected. A synchronous external-operation guard prevents another MoPanel module from starting a conflicting operation.

Enabling may run the vendor's code immediately, at login, or on a later trigger. Disabling can stop background functionality. launchd controls the target job lifecycle; MoPanel does not itself force-kill that job. Cancelling stops the owned launchctl process and further steps, but **does not undo a completed enable/disable/bootstrap/bootout request**. The UI reports the completed step count and possible partial change, invalidates the row and requires a fresh review. It does not silently retry or roll back.

launchctl has no public atomic compare-and-swap operation that combines our plist verification with a service mutation. Fresh checks reduce stale-target risk, but another application or the same user can still alter launchd state between checks. This limitation is not presented as a transactional guarantee. The module uses the public executable rather than unsupported private launchd APIs.

## Compatibility and privacy

`launchctl print` and `print-disabled` use text output, not a documented stable JSON API. The parser accepts only complete recognized forms, validates the target header, and extracts top-level identity fields. Unexpected, truncated or undecodable output disables affected controls. Nonzero exits count as “not loaded” only for the exact known missing-service response and exit code; other errors remain unknown.

The macOS CI platform audit records actual `launchctl help`, `help print-disabled`, `print-disabled gui/<uid>` and a deliberately nonexistent service query. It never enables, disables, bootstraps or removes a real job. These samples establish the tested platform format; they do not establish behavior on every future macOS release. Do not report the runtime contract verified until the corresponding CI artifact has been reviewed.

The artifact from GitHub Actions run **40073252380**, macOS **27.0.1 arm64**, has now been reviewed. Its disabled-map response uses an indented `disabled services` block and `=> disabled`; the deliberately missing service exits 113 with the expected two-line diagnostic. Exact response bytes are preserved in `Tests/MoPanelCoreTests/Fixtures/launchctl-disabled-macos27.txt` and `launchctl-missing-macos27.txt`. A regression decodes both, preserves missing overrides as absent, and rejects an unknown state spelling or a different exit code. This verifies those two read-only response forms; it does not verify a real bootstrap/bootout transition or the complete positive loaded-service output format.

Normal controllers are blocked in any smoke-test or benchmark launch: no real inventory, launchctl, Finder or System Settings action is allowed. Only the private injected fixture runner used by `runSafeSmokeTest()` is exempt. The fixture runner cannot execute a real subprocess.

## System Settings boundary and Apple sources

MoPanel calls the public `SMAppService.openSystemSettingsLoginItems()` API for the manual handoff. Opening the pane is not reported as a completed configuration change. `SMAppService` registration APIs manage helpers belonging to the app's own bundle; MoPanel does not misuse them to register arbitrary third-party files or inspect private background-item databases.

Primary references inspected on 2026-10-24:

- [Apple: SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [Apple: openSystemSettingsLoginItems()](https://developer.apple.com/documentation/servicemanagement/smappservice/opensystemsettingsloginitems())
- [Apple: Updating helper executables from earlier versions of macOS](https://developer.apple.com/documentation/servicemanagement/updating-helper-executables-from-earlier-versions-of-macos)
- [Apple archived guide: Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html) — used for directory/ownership concepts, not as proof of current launchctl output syntax.
- Current macOS runtime help/response samples: `build/reports/platform-contracts.json`, when produced by `scripts/audit_platform.py` in CI.

## Tests and safe smoke contract

On 2026-10-24, Swift 6.4.1 Linux compiled and ran **14 StartupModelsTests, 0 failures** after the directory-URL fix. The exact output is in `docs/STARTUP_TEST_OUTPUT.txt`. Tests cover typed argv with Unicode/quotes/shell-looking filenames, loaded identity matching, unknown and missing responses, duplicate/root rejection, protected Apple/Buho/shared/system cases, symlinks, stale snapshots, malformed schema/entity/oversize input, bounded inventory, malformed-file aggregate budgets, directory URL representations and recorded macOS response forms. The tests use temporary fixtures only and never execute their harmless fixture program or launchctl.

The first macOS run **40073252380** passed nine original Startup tests but failed two inventory tests with four assertions: the expected item counts were 2 and 64, while both inventories returned zero. The folder guard compared URL objects rather than their canonical filesystem paths. A new regression reproduced the same false rejection on Linux with a base-URL representation: the original and standardized absolute strings and resolved path matched, but URL object equality was false. `docs/STARTUP_URL_REGRESSION_BEFORE.txt` preserves this intentional pre-fix failure. The fix compares standardized `.path` values and additionally requires a file URL, while retaining `lstat` directory type, symlink resolution, owner/mode checks and exact file identity. The regression covers directory hints and relative/base URL representations; a separate test proves symbolic directories and traversal paths remain rejected. Inventory assertion messages now include URL representations, warnings and item errors. The **fixed macOS rerun remains pending** until recorded by the main CI report.

Linux syntax parsing passed for `StartupController.swift` and `StartupView.swift`; this is **not macOS compilation or UI validation**. Real macOS compilation and the following smoke contract must be separately recorded in the main test report.

`await StartupController.runSafeSmokeTest()` constructs one temporary plist and drives the native controller with a private in-memory launchctl substitute. It exercises inventory, review/confirm enable, review/confirm disable, cancelling a review and rejecting an unknown format. It reports:

- `inventoryCount` (expected 1).
- `enableVerifiedWithMock`, `disableVerifiedWithMock`, `cancelledReviewDidNotMutate`, `unknownFormatDidNotMutate` (expected true).
- `mutationArguments` (reviewable mock argument arrays).
- `realLaunchctlMutations` and `persistentJobsCreated` (both 0).
- `errors` (expected empty).

No live user job is changed, no persistent override is created, and all temporary fixture files are removed. This is controller integration evidence with a mock, **not a real launchctl mutation test**. Own-user mutation, actual vendor lifecycle behavior, manual System Settings interaction and VoiceOver interaction remain unverified until explicitly tested in an authorized isolated Mac environment.

## Integration locations

- `Sources/MoPanelCore/StartupModels.swift`: bounded metadata reader, identity rules, state parser, typed command plan.
- `Tests/MoPanelCoreTests/StartupModelsTests.swift`: fixture/policy/parser coverage.
- `Sources/MoPanelApp/StartupController.swift`: guarded native workflow, owned children, rechecks, cancellation and safe smoke.
- `Sources/MoPanelApp/StartupView.swift`: bilingual native inventory, filter/search, review/confirm controls and manual handoff.

The application owns `StartupController(language:)`, sets `externalOperationInProgress`, injects `StartupView(controller:language:operationInProgress:)`, and calls `cleanupForQuit()` from its existing shutdown path. The view stops owned work on disappearance. No Login Item, LaunchAgent or daemon is created for MoPanel.
