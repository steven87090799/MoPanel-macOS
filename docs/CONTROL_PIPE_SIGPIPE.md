# Closed control pipe regression

## Observed failure and evidence boundary

Real Mac run `40081612793` completed 171 Swift tests, then the formal app made 16 public legacy AXPress dispatches and verified 15 corresponding UI postconditions. After confirmation Continue was dispatched, the app terminated with SIGPIPE (signal 13), before the final report. The disposable LLDB copy reached the same stage and signal. The four original production-file hashes remained unchanged.

That debugger invocation did not stop on SIGPIPE, so it did **not** capture a usable crash backtrace. The source investigation found that `ManagedProcess.sendFrame` queued `FileHandle.write(contentsOf:)` without SIGPIPE protection; Swift `try?` handles a thrown error, not a fatal POSIX signal. A peer can close its input before the main actor receives the termination callback, so `running == true` cannot eliminate this race.

The controlled reproduction below demonstrates the defect in the actual pre-fix transport. It supports the suspected app crash path; the next real Mac run is still required to establish that the formal UI flow is fixed.

## Fix

`ControlPipeWriter`, inside `ManagedProcess.swift`, owns one private guardian write handle. Writes and all explicit closes run on the same serial queue. Any write error closes the channel and prevents later queued frames from being written. A live guardian interprets closure of its lifeline as its existing cancellation request; a guardian that has already exited retains its real process result. The code does not retry a failed frame or log its contents.

On macOS, initialization sets and reads back `F_SETNOSIGPIPE`/`F_GETNOSIGPIPE` on that descriptor before the child is launched. Failure to establish protection throws `controlChannelUnavailable` and does not launch an unprotected operation. This does not alter the process-wide signal handler or the CLI's signal disposition. Apple explicitly documents these commands for pipes as well as sockets.

Linux has no equivalent pipe descriptor option. The writer temporarily blocks SIGPIPE on its own thread, records whether SIGPIPE was already pending, performs the write, consumes only a newly generated EPIPE signal, and restores the previous thread mask. It never changes a global signal handler. The standalone probe verifies an already-pending signal remains pending and the mask is unchanged.

The writer uses asynchronous queue submissions only; it never synchronously waits on its own queue. Queue closures retain their specific old writer/handle until completion. A subsequent `ManagedProcess.start` creates an independent writer, so an old pending close cannot close the new channel. The writer's final destructor closes its own `FileHandle` without a queue wait. Terminal resize also refuses new messages after cancellation or after the session is no longer running.

## Reproduction and results

The checked-in script compiles `scripts/fixtures/ControlPipeSIGPIPEProbe.swift` together with the **actual** `ManagedProcess.swift`, into a temporary executable. The probe sets SIGPIPE to its default disposition only in that disposable child. Its private fake guardian closes stdin, prints `CLOSED_READY`, stays alive for 0.3 seconds, and exits. No installed Mole, real cleanup target, user repository or other app is involved.

```sh
python3 scripts/test_control_pipe_sigpipe.py --output /tmp/control-pipe-after.json
```

Use `--swiftc /absolute/path/to/swiftc` if the compiler is not on PATH. To reproduce the historical failure, provide a saved pre-fix source file with `--source /tmp/ManagedProcess-before.swift --expect-sigpipe`. The script's historical mode considers the expected signal a successful reproduction, **not a passing product implementation**.

Actual Linux results on 2026-10-24:

| Probe | Pre-fix source | Fixed source |
|---|---|---|
| Resize after peer closed input, session still running | Terminated by SIGPIPE, exit −13 | Survived, exit 0 |
| Input after peer closed input, session still running | Terminated by SIGPIPE, exit −13 | Survived, exit 0 |
| Cancel after peer closed input, session still running | Terminated by SIGPIPE, exit −13 | Survived, exit 0; cancellation remains recorded |
| Preserve an already-pending SIGPIPE and caller's thread mask | Not part of the historical probe | Passed in isolated SIG_DFL process |

`CONTROL_PIPE_SIGPIPE_BEFORE.json` and `CONTROL_PIPE_SIGPIPE_AFTER.json` include the source/probe SHA-256 values, exit status and fixed fixture markers. Both were produced by the checked-in script.

`ControlPipeTests.swift` adds three actual-session peer-closure cases, queued write/close ordering, signal-mask/pending-state verification, and a macOS-only descriptor flag check. The focused Linux Process suite passed **32 tests, zero failures, zero skips**; the full output is `CONTROL_PIPE_PROCESS_TEST_OUTPUT.txt`. This includes the existing cancellation, timeout, streaming, PTY, environment and configuration-editor regressions. The new Darwin-only flag check and the formal 17-action Mac UI sequence are **not** counted as passed by these Linux results.

## macOS preflight and portable fixture correction

Real Mac run `40082574523` successfully compiled the actual `ManagedProcess.swift` and the standalone Swift probe against the macOS SDK. Its isolated pending-signal case passed (`PENDING_SIGNAL_PRESERVED MASK_RESTORED`, exit 0). The resize, send and cancel cases stopped at `ManagedProcessError.executableMissing`, before their peer-closure/write markers: both test fixtures had used `/bin/true`, which is absent on that runner. The preflight gate correctly failed and stopped the job; the planned 177 XCTest cases, formal app UI flow and subsequent build gates did **not** run in that job. This is not evidence that the three Darwin write paths or the full app now pass.

The only source correction was to use `/usr/bin/true` in `ControlPipeSIGPIPEProbe.swift` and `ControlPipeTests.swift`, a location available on both tested platforms. The private fake guardian never executes that requested program; the path is only subject to the normal executable validation. No production validation, signal handling, deadline or success condition was changed.

After this correction, all four isolated Linux probes passed again. The five focused Linux `ControlPipeTests` also passed with zero failures and zero skips in 1.301 seconds; see `CONTROL_PIPE_FIXTURE_PATH_TEST_OUTPUT.txt`. `CONTROL_PIPE_SIGPIPE_AFTER.json` was regenerated using the corrected probe (SHA-256 `f6a84c2c3464181c2526e679bb89bf598d84bf074ad260e4bddc9150bff5eb3d`). The production source SHA-256 remains `c5df31bd15a5f9b0a81d204554160906c7b41749d221ff0456d4ffea1c18affe`. The historical BEFORE evidence retains the earlier probe hash and its original, actually observed Linux results. The corrected three Mac write-path probes and the complete Mac validation remain pending the next CI run.

## Apple primary references

- [fcntl(2) source](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/fcntl.2): `F_SETNOSIGPIPE` prevents SIGPIPE when a write fails because a pipe or socket has no reader; `F_GETNOSIGPIPE` reads the descriptor setting.
- [pipe(2) source](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/pipe.2): explicitly identifies `F_SETNOSIGPIPE` as the suppression mechanism.
- [Public fcntl header](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/fcntl.h): declarations of both commands outside the private API section.

Inspected 2026-10-24. The implementation uses SDK constants rather than hardcoded command numbers. The standalone macOS SDK compilation passed in run `40082574523`; full-app compilation and runtime gates remain separate checks.
