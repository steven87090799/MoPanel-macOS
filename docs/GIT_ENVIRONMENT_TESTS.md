# Git child-environment isolation acceptance

Date: 2026-10-24. This evidence covers the shared process layer for the new Git worktree adapter; it is not a worktree-removal or macOS UI acceptance result.

The adapter needs to opt into five fixed protection values: `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_SYSTEM=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_TERMINAL_PROMPT=0`, and `GIT_ATTR_NOSYSTEM=1`. Other tools do not implicitly receive these overrides. Arbitrary `GIT_*` repository paths, executable hooks, editor/credential helpers, config injection and tracing remain excluded.

An isolated Swift package copied the actual `MoPanelProcess` source and guardian plus the three new `GitEnvironmentTests`. It was used to avoid compiling another agent’s unfinished Core module. The package used the real compiled C guardian and a harmless shell child that printed only the named test variables; it did not run Git, inspect an existing repository, or modify user data. Source hashes are in `GIT_ENVIRONMENT_SOURCE_HASHES.json`.

| Execution | Actual result |
|---|---|
| Before, process source at `6b2e8a7b1b0b9c3dd47c7733128a11cdcfd94e35` | 3 tests ran; 11 failed assertions. The requested fixed protections were absent from the child, as expected before this new integration existed. This does not imply an earlier Mole feature used an unsafe Git adapter. |
| After, same tests against the updated process source | 3/3 passed, 0 failures, 0 skips; XCTest execution 0.013 s on Linux x86_64. |
| macOS / complete worktree flow | Pending the next real Mac build and the dedicated Git adapter tests. |

The tests verify explicit opt-in, rejection of alternative protection values, rejection of Git path/config/interpreter injection, and the exact values observed by an actual managed child. Raw logs are `GIT_ENVIRONMENT_BEFORE.txt` and `GIT_ENVIRONMENT_AFTER.txt`. The Linux result is not counted as an additional macOS test pass.
