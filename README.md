# Lutop

Lutop is a lightweight macOS menu bar resource monitor. It shows a compact terminal-style system dashboard with CPU, memory, disk, power, processes, network, and local Codex / Claude Code quota information.

It is designed to stay small: no Dock icon, no package installer, no background helper daemon, no usage cache, and no telemetry.

## Features

- Menu bar CPU / memory summary.
- Click-to-open compact resource panel.
- Two-column text dashboard inspired by terminal status tools.
- CPU load, hottest cores, load average.
- Memory used/free/swap.
- Startup disk usage and disk read/write rates.
- Battery level, health, cycle count, temperature, and power state.
- Top processes by CPU.
- Network up/down rates and proxy status.
- Codex quota from local `~/.codex/sessions/**/*.jsonl` `rate_limits`.
- Claude Code quota through an optional local status line bridge.
- Optional Start at Login via a per-user LaunchAgent.

## Build And Run

```sh
make run
```

The app hides its Dock icon and stays in the system menu bar. Click the status item to open the panel. Right-click the status item for Start at Login and Claude Code usage connection controls.

## Build App Bundle

```sh
make bundle
open dist/Lutop.app
```

`dist/Lutop.app` is a development build artifact, not the formal install location.

## Install

```sh
make install
```

This builds a release bundle, copies it to `~/Applications/Lutop.app`, ad-hoc signs it, and starts the installed app. Start at Login always points to `~/Applications/Lutop.app`.

## Uninstall

```sh
make uninstall
```

This quits Lutop, restores any Lutop-owned Claude Code status line bridge, removes `~/Applications/Lutop.app`, and removes `~/Library/LaunchAgents/dev.yiminglu.lutop.login.plist`.

Lutop does not create a pkg receipt, cache folder, Application Support folder, preferences file, usage cache, or runtime temp files. Development files such as `.build` and `dist` are managed by `make clean`.

## Debug Snapshot

```sh
make snapshot
```

This prints the same dashboard text used by the popover and exits.

## Codex Quota

Lutop scans recent local Codex session JSONL files under `~/.codex/sessions` and uses the latest real subscription quota bucket:

- `limit_id == "codex"`
- `primary.window_minutes == 300` for `5h`
- `secondary.window_minutes == 10080` for `1w`

The panel displays remaining quota, not total token usage or API cost.

## Claude Code Quota

Claude Code quota is optional. Use the right-click menu item `Connect Claude Usage` to install a local status line bridge into `~/.claude/settings.json`.

The bridge:

- reads Claude Code status line JSON from stdin,
- extracts `rate_limits.five_hour` and `rate_limits.seven_day`,
- sends the data to the running Lutop app through a local distributed notification,
- preserves and restores the user's original Claude Code status line when disconnected.

If `~/.claude` is not present, Lutop does not create it or modify Claude Code configuration.

## Privacy

Lutop reads local system APIs and local quota files only. It does not upload data, does not write usage history, and does not create a cache for quota data.

## Reference Projects

Lutop's compact two-column dashboard style, section text symbols, and terminal-status feel are inspired by [Mole](https://github.com/tw93/mole), especially its `mo status` view.

Mole is licensed under GPL-3.0 and has its own trademark policy. Lutop uses its own name and does not use the Mole name or logo. Lutop is released under GPL-3.0-only to keep this relationship conservative and clear.

Codex and Claude are product names of their respective owners. Lutop uses text-only approximations for the quota card symbols and does not bundle OpenAI, Codex, Anthropic, or Claude logo assets.

## License

GPL-3.0-only. See [LICENSE](LICENSE).
