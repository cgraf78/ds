# Example Configs

These files are sample `ds` configuration snippets. They demonstrate real
plugin wiring without requiring local machine-specific paths or private hosts.
The test suite loads the checked-in files directly so parser and plugin changes
cannot silently leave the examples behind.

When adding an example, keep comments focused on the setting being demonstrated
and make sure the referenced plugin exists under `lib/plugins/`.

- `profile.conf` is the compact form for a single command.
- `profile-workspace.sh` shows the function form for a multi-window layout.
- `connect.conf` uses reserved example hostnames.
- `share-upterm.conf` enables only Upterm's public service and default lifetime;
  deployment-specific trust and authorization values remain commented.
