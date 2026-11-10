#!/usr/bin/env bash
# Installs the vc-bridge daemon, the vcb CLI, the noctalia plugin, the systemd
# unit and (optionally) the share-picker wrapper. It does not edit your configs.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
BIN_DIR="$HOME/.local/bin"

say() { printf '\033[1m%s\033[0m\n' "$*"; }

say "Installing vc-bridge daemon"
install -d "$DATA_DIR/vc-bridge" "$BIN_DIR" "$CONFIG_DIR/systemd/user"
install -m 755 "$here/vc-bridge/vc_bridge.py" "$DATA_DIR/vc-bridge/vc_bridge.py"
install -m 755 "$here/vc-bridge/vcb" "$BIN_DIR/vcb"
if [ ! -d "$DATA_DIR/vc-bridge/venv" ]; then
    python3 -m venv "$DATA_DIR/vc-bridge/venv"
fi
"$DATA_DIR/vc-bridge/venv/bin/pip" install -q -r "$here/vc-bridge/requirements.txt"

say "Installing noctalia plugin"
install -d "$DATA_DIR/noctalia/plugins/vesktop-vc"
cp -r "$here/noctalia-plugin/." "$DATA_DIR/noctalia/plugins/vesktop-vc/"

say "Installing systemd user unit"
install -m 644 "$here/systemd/vc-bridge.service" "$CONFIG_DIR/systemd/user/vc-bridge.service"

say "Installing share-picker wrapper"
install -m 755 "$here/share-picker/hyprland-share-picker-filter" "$BIN_DIR/hyprland-share-picker-filter"

if [ -n "${VENCORD_DIR:-}" ]; then
    say "Installing Vencord userplugin into $VENCORD_DIR"
    install -d "$VENCORD_DIR/src/userplugins"
    rm -rf "$VENCORD_DIR/src/userplugins/vesktopVcBridge"
    cp -r "$here/vencord-plugin" "$VENCORD_DIR/src/userplugins/vesktopVcBridge"

    if [ "${BUILD_VENCORD:-0}" = "1" ]; then
        say "Building Vencord"
        (cd "$VENCORD_DIR" && pnpm install --frozen-lockfile && pnpm build)
        if [ ! -f "$VENCORD_DIR/dist/package.json" ]; then
            printf '{"name":"vencord","private":true}\n' >"$VENCORD_DIR/dist/package.json"
        fi
    fi
fi

systemctl --user daemon-reload

cat <<'EOF'

Done. Remaining steps:

1. Start the daemon:
     systemctl --user enable --now vc-bridge.service

2. Vencord plugin: copy vencord-plugin/ into <Vencord>/src/userplugins/vesktopVcBridge,
   run "pnpm install && pnpm build", point Vesktop at the build's dist
   (~/.config/vesktop/state.json -> "vencordDir"), restart Vesktop and enable
   "VesktopVCBridge" under Vencord -> Plugins.
   Or rerun this script with: VENCORD_DIR=~/src/vencord BUILD_VENCORD=1 ./install.sh

3. noctalia:  noctalia msg plugins enable eccemono/vesktop-vc
   and add "vesktop-vc" to a bar lane (see README).

4. Optional screen-share fix: set screencopy.custom_picker_binary in
   ~/.config/hypr/xdph.conf to ~/.local/bin/hyprland-share-picker-filter
   (see README), then restart the portal services.

EOF
