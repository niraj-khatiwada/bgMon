# bgMon

A native macOS menu bar app for viewing running processes, related helpers, CPU and memory usage, and listening TCP ports.

Requires macOS 14 or later. The release build targets Apple silicon.

## Use

Open bgMon, then left-click its menu bar icon. Pin the panel to keep it open. Expand an app to inspect its processes. The power icon requests a stop; the three-dot menu offers Force Stop and Show in Finder. Right-click the menu bar icon to quit.

The filter menu controls system-process visibility and high-resource-usage filtering. Settings contains CPU and memory warning thresholds. CPU percentages use one core as 100% and can exceed 100%. CPU warnings require three consecutive samples above the limit. Memory uses physical footprint in decimal MB; group totals sum individual process measurements.

Click the crossed-out bell beside an app's resource warning to ignore warnings for that app and its grouped helpers. Ignored apps remain in the normal process list but do not turn the menu bar icon red or appear in the high-resource-usage filter. The ignore list is saved across launches. Remove an app under **Settings → Ignored Apps** to re-enable its warnings.

Grouping is best effort. Shared or separately launched system services may not be attributed to an app. A process may restart after stopping if supervised by another service.

## Build and package

Install Xcode with Swift 6 support, then run:

```sh
./scripts/release.sh
```

Artifacts are written to `outputs/`. The script creates a locally signed app and DMG. Public distribution with normal Gatekeeper acceptance requires Developer ID signing and Apple notarization; the script does not perform either.

See [CHANGELOG.md](CHANGELOG.md) for release notes.
