# Vesktop VC bar

A [noctalia](https://noctalia.dev) bar widget for Vesktop/Discord voice channels:
who is in the call, who is speaking, mute/deafen badges, and one-click mute /
deafen / screen-share — plus per-person volume and "mute for me" in the panel.

Also fixes the duplicate hyprland screen-share picker Vesktop shows on Wayland.

```
Vesktop (Vencord userplugin "VesktopVCBridge")
        │  ws://127.0.0.1:6475/plugin
        ▼
vc-bridge daemon (Python, systemd user service)
        │  ~/.cache/vc-bridge/state.json (+ local HTTP API)
        ▼
noctalia plugin "eccemono/vesktop-vc" (Luau widget + panel)
```

## Features

- **Bar bubbles** — avatars for everyone in the channel, a ring around whoever
  is talking, and the mute/deafen/streaming badges composited onto the pfp
  (white-grey for self-mute, red for server-mute).
- **Up to 5 people always shown** in Discord's order (the order never changes
  while someone speaks). With 6+ it shows the speakers plus `+N`.
- **Self controls** in the bar: mic, deafen, screen share (also stops a live
  stream). Hidden automatically when you're not in a call.
- **Panel** (click the widget): full member list in Discord's order, live
  speaking rings, a **mini audio waveform** per member (real per-user WebRTC
  `audioLevel`, with an animated fallback), and per-person
  **volume (0–200 %)** and **“mute for me”**.
- **Screen-share picker fix**: Vesktop asks xdg-desktop-portal-hyprland for a
  capture source more than once per “Go Live”; the wrapper remembers your pick
  and answers the duplicates, so the picker appears once.

## Requirements

- Hyprland + [noctalia v5](https://noctalia.dev) (noctalia 5.4.x tested)
- [Vesktop](https://github.com/Vencord/Vesktop) with Vencord
- Python 3.10+ (for the daemon; it installs its own venv with `aiohttp` and
  `pillow`)
- Node + pnpm to build Vencord with the userplugin

## Install

### 1. Vencord userplugin (required)

The plugin only exists in a Vencord build made from source, so build one:

```sh
git clone https://github.com/Vencord/Vencord ~/src/vencord
cd ~/src/vencord
pnpm install --frozen-lockfile

cp -r /path/to/this/repo/vencord-plugin ~/src/vencord/src/userplugins/vesktopVcBridge
pnpm build
```

Then point Vesktop at that build. The directory is `vencordDir` in
`~/.config/vesktop/state.json` (Vesktop → Settings → Vesktop → Developer
Options → *Change Vencord Location* does the same):

```json
{
    "vencordDir": "/home/you/src/vencord/dist"
}
```

`dist/package.json` must exist or Vesktop considers the directory an invalid
Vencord install and downloads the stock build over it. Create it once with:

```sh
echo '{"name":"vencord","version":"1.15.17","private":true}' > ~/src/vencord/dist/package.json
```

Restart Vesktop, then enable **VesktopVCBridge** in Vesktop → Vencord → Plugins.
Vencord updates are manual from then on (`git pull && pnpm install && pnpm build`).

### 2. Daemon + noctalia plugin

```sh
./install.sh
systemctl --user enable --now vc-bridge.service
noctalia msg plugins enable eccemono/vesktop-vc
```

Add the widget to your bar (Noctalia → Settings → Bar, or edit the config):

```toml
[bar.default]
end = [ "media", "spacer_1", "vesktop-vc", "tray", "notifications", "network", "volume", "session" ]

[widget.vesktop-vc]
type = "eccemono/vesktop-vc:vc"
capsule = true
capsule_fill = "surface_container"
capsule_opacity = 0.35
capsule_border = "outline_variant"
capsule_border_width = 1.5
capsule_radius = 8.0
capsule_padding = 6
```

`./install.sh` can also do the Vencord copy/build for you if `VENCORD_DIR` and
`BUILD_VENCORD=1` are set; see the script.

### 3. Optional: single screen-share picker

The wrapper is an xdph `custom_picker_binary`. Install it (already done by
`install.sh`), then in `~/.config/hypr/xdph.conf`:

```ini
screencopy {
    allow_token_by_default = true
    custom_picker_binary = /home/you/.local/bin/hyprland-share-picker-filter
}
```

Reload the portal: `systemctl --user restart xdg-desktop-portal-hyprland
xdg-desktop-portal`.

The wrapper remembers your last pick in `~/.cache/hyprland-share-picker/` and
auto-answers duplicate requests for the same share (60 s window, or while a
Discord stream is live). Log: `~/.local/state/hyprland-share-picker/wrapper.log`.
`SHARE_PICKER_FORGET=1` clears the remembered pick. The optional dashboard
filter (hides one output) is configured with `SHARE_PICKER_MONITORS_FILE` /
`SHARE_PICKER_HIDE_OUTPUT`.

## CLI

```sh
vcb status                      # human readable
vcb status --json               # raw state
vcb mute                        # toggle your mic
vcb deafen                      # toggle your deafen
vcb share                       # open Discord's Go Live / share flow
vcb unshare                     # stop your stream
vcb local-mute <userId> [on|off]# mute someone for you
vcb local-volume <userId> <0-200> # someone's volume for you
```

State lives in `~/.cache/vc-bridge/state.json`; logs in
`~/.local/state/vc-bridge/bridge.log` and `journalctl --user -u vc-bridge`.

## How it works

The Vencord plugin subscribes to `VOICE_STATE_UPDATES` and `SPEAKING` flux
events, pushes a snapshot (members, mute/deafen flags, speaking, streaming) over
a localhost WebSocket every 5 s and on every change, and executes commands
(`MediaEngineActions` for mute/deafen/volume, `STREAM_STOP`, Discord's own
“Share Your Screen” button for going live). The daemon keeps the state, caches
and composites avatars (Pillow, badges drawn in the bottom-right corner), and
the noctalia plugin polls the state twice a second.

## Notes

- “Mute for me” and volume are **local** (client-side) — they change what you
  hear, not what others hear. Server mute/deafen is shown (in red) but not
  triggered.
- Voice state is read from Vesktop's Vencord; if you switch to another client
  the widget stops updating.
- Port `6475` (plugin setting + `vc-bridge.service`).

## License

MIT — see [LICENSE](LICENSE).
