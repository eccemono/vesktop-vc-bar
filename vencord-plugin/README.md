# VesktopVCBridge (Vencord userplugin)

Streams the current voice channel to the local `vc-bridge` daemon over a
WebSocket and accepts control commands back.

- Sends a full snapshot (channel, members with name/avatar/mute/deafen/streaming
  flags, speaking flags) on connect, on any voice-state/speaking/stream change,
  and every 5 s as a heartbeat.
- Receives `toggle_mute`, `toggle_deafen`, `start_stream`, `stop_stream`.
- `debug_eval` (optional `debug` setting) evaluates JS in the renderer for
  troubleshooting through `vcb eval "<js>"`.

## Build

This is a userplugin: it is only part of a build made from the Vencord source
tree, not of the stock Vencord bundle.

```sh
cd ~/src/vencord
pnpm install --frozen-lockfile
pnpm build            # writes dist/vencordDesktop*.js
```

The `dist/` directory is what Vesktop loads (`~/.config/vesktop/state.json` →
`vencordDir`). `dist/package.json` must exist or Vesktop treats the directory
as invalid and replaces it with the stock build.

Enable **VesktopVCBridge** under Vesktop → Vencord → Plugins, then restart
Vesktop. The plugin connects to `ws://127.0.0.1:6475/plugin`; the port is a
plugin setting and must match the daemon (`vc-bridge.service --port`).
