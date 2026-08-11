# Tests

`tests/ds-test` covers the local behavior of the `ds` command and plugins.
`tests/ds-ci` is the CI entrypoint and should stay safe on minimal runners where
optional remote/session tools may be absent.

Installer coverage verifies the persistent-checkout contract: exact command
and manpage link targets, idempotent retargeting, custom `BIN_DIR`/`MAN_DIR`,
complete source and destination preflight, and checkout-owned bundled plugins.

Use `tests/test-helpers.sh` for shared fixture setup. Keep tests deterministic by
using temporary homes, explicit config files, and fake helper commands instead
of depending on the developer's active tmux or SSH environment.
