# Hide Developer Options

Root module that makes Developer options and USB debugging read as **off** while selected apps are launching or in the foreground, then restores your real settings. It only writes system settings: no hooks, no injection, nothing touches the app's process.

Works with Magisk, KernelSU and APatch.

## Install

1. Flash `hide_developer_options.zip` in your root manager and reboot.
2. Add package names, one per line, to `/data/adb/hide_developer_options/packages.txt`. Changes apply immediately.

## How it works

- While a listed app starts or is top-app, `development_settings_enabled`, `adb_enabled` and `adb_wifi_enabled` are set to `0`.
- Original values are saved first and restored shortly after you leave the app, on stop, and after a crash or reboot.
- Detection: events log for an early trigger, `dumpsys` polling as fallback.
- Writes: `cmd settings`, then `settings`, then the content provider, each verified.

## Config

Optional `/data/adb/hide_developer_options/config.sh`:

| Variable | Default | Purpose |
|---|---|---|
| `POLL` | `1` | Seconds between top-app checks |
| `RESTORE_DELAY` | `3` | Seconds before restoring after the app leaves |
| `LAUNCH_GRACE` | `10` | Minimum spoof time after a launch |
| `HOLD_WHILE_RUNNING` | `0` | `1` = stay spoofed while the app process is alive |
| `KEYS` | dev options, adb, wireless adb | `namespace:key` list to force to `0` |

Logs: `/data/adb/hide_developer_options/log.txt`

## Limitations

- Turning `adb_enabled` off drops active adb sessions.
- Apps that observe settings changes can see the write.
