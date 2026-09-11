# omarchy-android-sms

Text from your Linux desktop through (almost) any Android phone: an Omarchy
bar widget with contacts + photos, a 10-second reply popup with snooze, and
auto-connect when the phone tethers.

Built against KDE Connect, so it works with Pixel, Samsung, Motorola, OnePlus
— anything the KDE Connect Android app supports. No per-phone hacks: the
device is resolved at runtime (first reachable phone-type device, or
`$ANDROID_SMS_DEVICE` to pin one).

## What you get

- **󰍦 SMS bar widget** — search contacts (photos included), pick a number,
  compose with Enter-to-send, char/part counter, one-click contact re-sync.
- **Reply popups** — incoming texts raise a 10s top-right toast. Left-click
  opens Dismiss / Snooze-15m / Snooze-1h / Mute. Right-click or timeout
  dismisses. (`sms-snooze 15m|1h|off|clear|status`)
- **Auto-connect** — plugging in USB tethering (any `cdc_ncm` / `cdc_ether` /
  `rndis` interface, not one USB ID) syncs contacts and toasts. Also notices
  phones reachable over WiFi/LAN.
- **CLI** — `android-sms-send 5551234567 hello` or
  `android-sms-send --contact "Ada" hello`.

## Requirements

- Omarchy (quickshell shell) for the widget + toasts
- `kdeconnect-cli` + `kdeconnectd` on the desktop
- KDE Connect Android app, paired, with **SMS** and **Contacts** permissions
- USB tethering for the auto-connect path (WiFi pairing works too)

## Install

```bash
git clone https://github.com/Slurm-Classic/omarchy-android-sms
cd omarchy-android-sms
./install.sh --bar
```

`--bar` inserts the widget into the Omarchy bar; omit it to place it manually
(`{"id": "android.sms"}` in the `right` section of
`~/.config/omarchy/shell.json`).

## How it works

| Piece | Does |
|---|---|
| `bin/android-sms-device` | resolves the phone's KDE Connect ID |
| `bin/android-sms-contacts` | parses synced vCards → `~/.cache/android-sms/contacts.json` + JPEG avatars |
| `bin/android-sms-send` | sends via `kdeconnect-cli --send-sms` |
| `bin/android-sms-tether-watch` | user-space watcher (USB tether iface + reachability) |
| `bin/sms-reply-watch` | D-Bus watch for incoming SMS → toast |
| `bin/sms-toast`, `sms-snooze`, `sms-snooze-menu` | 10s toast + snooze state |
| `plugins/android.sms` | the bar widget (`Panel.qml`) |

Contacts arrive through KDE Connect's contact sync (`kpeoplevcard`), so names,
numbers, and photos stay exactly what the phone has. Nothing is uploaded
anywhere; the cache lives under `~/.cache/android-sms/`.

## Multi-phone / pinning

With several paired phones reachable, the first phone-type device wins.
Pin one with:

```bash
export ANDROID_SMS_DEVICE="<kde-connect-id>"
```

(`kdeconnect-cli -a --id-only` lists IDs.)

## Uninstall

```bash
systemctl --user disable --now android-sms-tether-watch.service sms-reply-watch.service
rm -rf ~/.config/omarchy/plugins/android.sms ~/.cache/android-sms
# remove the {"id": "android.sms"} entry from ~/.config/omarchy/shell.json
```

## License

MIT — see `LICENSE`.
