# Plugins

Plugins add optional session behaviors such as remote connection helpers,
sharing, or profile-specific setup.

## Conventions

- Name plugins for the feature they provide, not the machine that first needed
  them.
- Keep host-specific values in user config; plugin scripts should stay reusable.
- Prefer small functions that `bin/ds` can compose instead of monolithic hooks.
- Add example config when a plugin needs non-obvious wiring.

Every plugin change should have either a focused unit case in `tests/ds-test` or
coverage through the CI smoke path when the behavior depends on external tools.
