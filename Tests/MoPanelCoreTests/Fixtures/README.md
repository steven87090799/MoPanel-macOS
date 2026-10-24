# Fixture provenance

`status.json`, `analyze.json`, and `apps.json` are synthetic parser fixtures based on the public fields in official Mole tag V1.62.0, commit `91a7bf44f96995361b10b5a0e9efae36a1490bf9`. They deliberately contain fake host/app names and boundary values. They are not hardware measurements, performance evidence, or live product data.

`history.json` is produced by executing V1.62.0 `bin/history.sh --json --limit 200` against isolated synthetic operation/deletion log files on Linux. The corresponding input logs are stored here. No cleanup command ran. Paths identify fictional fixtures only.

`help-contract.json` contains V1.62.0's actual help text: the isolated echo-only help functions were rendered with Bash and the static Go/shell usage strings were extracted verbatim from their source. This tests the adapter against upstream contracts, not a second hand-maintained copy of its own flag list. It does not claim that full macOS commands were executed.

The app does not load this test target's fixtures during ordinary use. Explicit CI smoke mode may use a separate controlled mock process and must label its data.
