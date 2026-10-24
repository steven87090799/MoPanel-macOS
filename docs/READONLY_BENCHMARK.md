# Official CLI read-only performance workload

The ordinary `--benchmark idle|monitor|scan` launch remains a bundled-fixture test of GUI overhead. `--benchmark-real idle|monitor|scan` is a separate, explicit GitHub CI workload for measuring the official read-only CLI together with the native GUI. Neither workload measures cleanup, uninstall, optimization, or app slimming performance.

## Source and data isolation

`scripts/prepare_mole_fixture.py` prepares an untouched tagged official checkout, verifies the two official Go binaries against the release SHA-256 checksums, and writes `MOPANEL_CI_SOURCE.json`. The real workload accepts only the exact `MOPANEL_AUDIT_CLI` path beneath `RUNNER_TEMP`; launcher/resources must resolve inside that tree. App startup checks the selected launcher against the manifest SHA-256 and checks the detected version against the prepared source tag. A missing fixture, malformed test flag, missing manifest, source mismatch, or invalid corpus stops the test before any default CLI search. There is no fallback to a user's installed engine.

The profiling script creates a private `mopanel-real-benchmark-*` session in `RUNNER_TEMP` containing `home/`, `tmp/`, and `corpus/`. The application validates the manifest and corpus before the measured phase. Only owned CLI children receive the isolated HOME, TMPDIR, and working directory. The GUI and parent shell environment are unchanged. ManagedProcess drops inherited XDG/interpreter hooks, so CLI caches default to the isolated child home.

Every service invocation in this mode is checked against an exact allowlist: help/version probes; monitor-mode status JSON/watch with process alerts disabled and a fixed two-second interval; scan-mode `analyze --json` for the one exact corpus root. Other read-only commands, all dry-run maintenance commands, arbitrary scan roots, interactive PTY commands, installation, update, and mutation commands are rejected. The normal UI does not provide a control to enter this test mode.

## Workloads and interpretation

| Mode | Measured phase |
|---|---|
| `idle` | 12 seconds in Settings after discovery; no watch or scan child |
| `monitor` | 12 seconds of the official status watcher plus Dashboard rendering |
| `scan` | Repeated explicit JSON scans of a new flat corpus for 12 seconds, with Analyze rendering |

The scan corpus contains regular files only, with no subdirectories or symlinks. The default profiler creates 5,000 files of 4,096 bytes each. The explicit root scan enumerates these files on every invocation, avoiding Mole's subdirectory-cache reuse. The operating system filesystem cache is warm on later passes; that limitation is recorded. Corpus creation, source discovery, and the first two seconds of workload warmup are excluded from the sampled window. Scan reports contain actual start/end intervals and decoded result counts so the profiler can select active-scan samples.

Resource measurements are actual `ps` samples of the App and observed descendants. The CPU percentages are `ps` lifetime averages, not instantaneous scheduler counters. Keep `performance.json` (fixture overhead) and `performance-real-cli.json` (official read-only work) separate. The real report identifies the source tag/commit, CLI fingerprint, corpus size/count, actual decoded watch samples and scan results; no hardware values or outcomes are synthesized.

## Regression evidence

The ten `ReadOnlyBenchmarkTests` cover required CI inputs, mixed/malformed flags, exact source selection, provenance shape, path traversal/symlink escapes, strict mode-specific command allowlists, corpus-root replacement, stale manifests, report reuse, and child-only environment isolation. The complete core suite passed 57 tests on the Linux Swift compiler after these changes; see `READONLY_BENCHMARK_CORE_TEST_OUTPUT.txt`. Actual macOS compilation, smoke execution, and resource measurements are determined by the CI evidence generated from the corresponding built revision, not by this source-only test result.
