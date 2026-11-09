# xpg-fix - architecture

## Architecture

PowerShell and batch runner scripts providing tray interface and background observer guards for MemoryOS:
- `MemoryOS-Tray.ps1`: System tray management and cascading menus.
- `memoryos-observer-run.ps1` / `memoryos-observer-run.cmd`: Background observer process with single-instance enforcement.
- `apply.ps1`: Installation and deployment script for the fix.
