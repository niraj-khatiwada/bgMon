# Changelog

## 1.2.0 — 2026-11-05

- Allow stopping leftover processes whose executables were deleted during uninstall, using the process owner and start time to protect against reused PIDs.
- Apply the fix to both normal stop and force quit, including app group actions.
- Add regression checks for deleted executables, stale process identities, and changed executable paths.

## 1.1.0 — 2026-11-05

- Ignore resource warnings for individual apps with a button beside their warning icon.
- Manage the saved ignore list in Settings, including apps that are not running.
- Show the app version in Settings.
- Use the native popover corners to fix the doubled corner outline.

## 1.0.0 — 2026-11-05

Initial release of bgMon for macOS.

- Menu bar process monitor with pinnable panel.
- Collapsible app groups with app icons and combined CPU and memory usage.
- Interval CPU sampling and physical memory footprint measurements.
- Subprocesses sorted by CPU, then memory.
- Listening TCP ports for processes and app groups.
- Native search and filters for system processes and high resource usage.
- Configurable, saved warning thresholds; defaults of 75% CPU and 2 GB memory.
- Warning indicators and a red menu bar icon for eligible high-usage groups.
- Manual process and group stop controls, Force Stop, and Show in Finder.
- Right-click menu bar menu to quit.

Known limitations:

- Group attribution uses executable bundle paths and parent relationships. Separately launched XPC services may not be attributed to their originating app.
- Group memory is the sum of available per-process footprints, not a system-wide unique-memory measurement.
- Processes are limited to the current user. Protected or privileged processes may not be inspectable or stoppable.
- Ports currently include listening TCP sockets only.
- This release is locally signed and not notarized.
