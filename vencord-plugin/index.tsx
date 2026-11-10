/*
 * Vesktop VC Bridge — Vencord userplugin
 * Copyright (c) 2026 eccemono
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Streams the current voice channel state (members, mute/deafen, speaking,
 * streaming) to the local `vc-bridge` daemon over WebSocket, and accepts
 * commands back (toggle mute/deafen, start/stop screen share).
 *
 * This is a userplugin: it lives in src/userplugins and is only built into a
 * custom Vencord build. See ~/.config/vesktop-vc/README.md for the workflow.
 */

import { definePluginSettings } from "@api/Settings";
import definePlugin, { OptionType } from "@utils/types";
import { findByProps, findByPropsLazy } from "@webpack";
import {
    ChannelStore,
    FluxDispatcher,
    GuildMemberStore,
    GuildStore,
    MediaEngineStore,
    RelationshipStore,
    showToast,
    UserStore,
    VoiceStateStore
} from "@webpack/common";

const settings = definePluginSettings({
    port: {
        type: OptionType.NUMBER,
        description: "Port of the local vc-bridge daemon (restart Vesktop after changing)",
        default: 6475,
        restartNeeded: true
    },
    debug: {
        type: OptionType.BOOLEAN,
        description: "Allow the local daemon to evaluate JS in the client (vcb eval). Only for debugging.",
        default: false
    }
});

// ---------------------------------------------------------------------------
// websocket plumbing
// ---------------------------------------------------------------------------

let ws: WebSocket | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let heartbeatTimer: ReturnType<typeof setInterval> | null = null;
let snapshotTimer: ReturnType<typeof setTimeout> | null = null;
let stopped = false;

/** userId -> timestamp of the last "speaking: true" event */
const speaking = new Map<string, number>();

function url() {
    return `ws://127.0.0.1:${settings.store.port}/plugin`;
}

function send(payload: any) {
    if (ws?.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify(payload));
    }
}

function scheduleSnapshot() {
    if (snapshotTimer) return;
    snapshotTimer = setTimeout(() => {
        snapshotTimer = null;
        sendState();
    }, 80);
}

function connect() {
    if (stopped) return;
    if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;

    try {
        ws = new WebSocket(url());
    } catch (e) {
        console.debug("[VesktopVCBridge] could not create socket", e);
        scheduleReconnect();
        return;
    }

    ws.onopen = () => {
        console.log("[VesktopVCBridge] connected to vc-bridge");
        send({ type: "hello", plugin: "vesktopVcBridge", version: 1 });
        sendState();
    };

    ws.onmessage = event => {
        let message: any;
        try {
            message = JSON.parse(String(event.data));
        } catch {
            return;
        }
        if (message?.type === "cmd") void handleCommand(message);
    };

    ws.onerror = () => {
        // the close handler retries; keep this quiet so the console is not spammy
    };

    ws.onclose = () => {
        ws = null;
        scheduleReconnect();
    };
}

function scheduleReconnect() {
    if (stopped || reconnectTimer) return;
    reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        connect();
    }, 3000);
}

// ---------------------------------------------------------------------------
// state extraction
// ---------------------------------------------------------------------------

function displayName(guildId: string | null, userId: string): string {
    const user = UserStore.getUser(userId);
    const relationshipName = RelationshipStore.getNickname?.(userId);
    const memberName = guildId ? GuildMemberStore.getNick?.(guildId, userId) : null;
    return (
        memberName ||
        relationshipName ||
        (user as any)?.globalName ||
        (user as any)?.username ||
        userId
    );
}

function avatarUrl(guildId: string | null, userId: string): string | null {
    const user: any = UserStore.getUser(userId);
    if (!user) return null;
    try {
        return typeof user.getAvatarURL === "function"
            ? user.getAvatarURL(guildId ?? null, 128) || null
            : user.avatar
              ? `https://cdn.discordapp.com/avatars/${userId}/${user.avatar}.png?size=64`
              : null;
    } catch {
        return null;
    }
}

function isSpeaking(userId: string): boolean {
    const at = speaking.get(userId) ?? 0;
    return at > 0 && Date.now() - at < 8000;
}

function memberPayload(state: any, guildId: string | null) {
    const userId: string = state.userId;
    return {
        userId,
        name: displayName(guildId, userId),
        avatar: avatarUrl(guildId, userId),
        mute: !!(state.mute || state.selfMute),
        deaf: !!(state.deaf || state.selfDeaf),
        serverMute: !!state.mute,
        serverDeaf: !!state.deaf,
        selfMute: !!state.selfMute,
        selfDeaf: !!state.selfDeaf,
        streaming: !!state.selfStream,
        speaking: isSpeaking(userId),
        speakingAt: speaking.get(userId) ?? 0,
        localMute: readLocalMute(userId),
        localVolume: (() => {
            try {
                const value = Number((MediaEngineStore as any).getLocalVolume?.(userId));
                return Number.isFinite(value) ? value : 100;
            } catch {
                return 100;
            }
        })()
    };
}

function isReallyInVoice(): boolean {
    // VoiceStateStore keeps a stale entry after a client restart until the
    // gateway times the old voice state out, so trust the media engine too.
    try {
        const engine: any = MediaEngineStore.getMediaEngine();
        const connections: any = engine?.connections;
        if (connections && typeof connections.size === "number") return connections.size > 0;
    } catch {
        // fall through to the voice-state check
    }
    return true;
}

function buildState() {
    const me: any = UserStore.getCurrentUser();
    if (!me) return { type: "state", connected: false, members: [], self: null, channel: null };

    const selfId: string = me.id;
    const selfVoice = VoiceStateStore.getVoiceStateForUser(selfId);
    const channelId: string | null = isReallyInVoice() ? (selfVoice?.channelId ?? null) : null;

    const base = {
        type: "state",
        connected: !!channelId,
        self: {
            userId: selfId,
            name: displayName(null, selfId),
            avatar: avatarUrl(null, selfId),
            mute: (() => {
                try {
                    return MediaEngineStore.isSelfMute();
                } catch {
                    return !!selfVoice?.selfMute;
                }
            })(),
            deaf: (() => {
                try {
                    return MediaEngineStore.isSelfDeaf();
                } catch {
                    return !!selfVoice?.selfDeaf;
                }
            })(),
            streaming: !!selfVoice?.selfStream,
            speaking: isSpeaking(selfId)
        },
        channel: null as any,
        members: [] as any[]
    };

    if (!channelId) return base;

    const channel: any = ChannelStore.getChannel(channelId);
    const guildId: string | null = channel?.guild_id ?? null;
    const guild: any = guildId ? GuildStore.getGuild(guildId) : null;

    const channelName =
        channel?.name ||
        channel?.recipients?.map((id: string) => displayName(null, id)).join(", ") ||
        "Voice";

    base.channel = {
        id: channelId,
        name: channelName,
        guildId,
        guildName: guild?.name ?? null
    };

    const states: Record<string, any> = VoiceStateStore.getVoiceStatesForChannel(channelId) ?? {};
    base.members = Object.values(states).map(state => memberPayload(state, guildId));

    return base;
}

function sendState() {
    if (!ws || ws.readyState !== WebSocket.OPEN) return;
    try {
        send(buildState());
    } catch (e) {
        console.debug("[VesktopVCBridge] failed to build state", e);
    }
}

// ---------------------------------------------------------------------------
// commands from the daemon
// ---------------------------------------------------------------------------

function forEachConnection(fn: (connection: any) => boolean): boolean {
    try {
        const engine: any = MediaEngineStore.getMediaEngine();
        const connections: any = engine?.connections;
        if (!connections) return false;
        let handled = false;
        for (const connection of connections.values()) {
            try {
                if (fn(connection)) handled = true;
            } catch {
                // ignore this connection
            }
        }
        return handled;
    } catch {
        return false;
    }
}

function readLocalMute(userId: string): boolean {
    try {
        return !!(MediaEngineStore as any).isLocalMute?.(userId);
    } catch {
        return false;
    }
}

function mediaActions(): any {
    // A non-lazy lookup resolves to the same module Discord's own UI uses
    // (the lazy proxy can pin an earlier, partial match).
    try {
        return findByProps("toggleSelfMute");
    } catch {
        return null;
    }
}

function setLocalMute(userId: string, muted: boolean): boolean {
    if (readLocalMute(userId) === muted) return true;
    try {
        FluxDispatcher.dispatch({
            type: "AUDIO_TOGGLE_LOCAL_MUTE",
            context: "default",
            userId
        } as any);
        return true;
    } catch {
        const actions = mediaActions();
        try {
            actions?.toggleLocalMute?.(userId);
            return true;
        } catch {
            return false;
        }
    }
}

function setLocalVolume(userId: string, volume: number): boolean {
    const value = Math.max(0, Math.min(200, Math.round(volume)));
    const actions = mediaActions();
    if (!actions || typeof actions.setLocalVolume !== "function") return false;
    try {
        actions.setLocalVolume(userId, value);
        return true;
    } catch {
        return false;
    }
}

function stopStream() {
    const me: any = UserStore.getCurrentUser();
    if (!me) return;
    const selfVoice = VoiceStateStore.getVoiceStateForUser(me.id);
    const channelId = selfVoice?.channelId;
    if (!channelId) return;
    const channel: any = ChannelStore.getChannel(channelId);
    const key = channel?.guild_id
        ? `guild:${channel.guild_id}:${channelId}:${me.id}`
        : `call:${channelId}:${me.id}`;

    FluxDispatcher.dispatch({
        type: "STREAM_STOP",
        streamKey: key,
        appContext: "APP"
    } as any);
}

/** MediaEngineActions — the same module Discord's own mute/deafen buttons use */
const MediaEngineActions = findByPropsLazy("toggleSelfMute") as any;

function toggleMute() {
    try {
        MediaEngineActions.toggleSelfMute({ context: "default", syncRemote: true, playSoundEffect: true });
        return;
    } catch (e) {
        console.debug("[VesktopVCBridge] MediaEngineActions.toggleSelfMute failed, falling back", e);
    }
    FluxDispatcher.dispatch({
        type: "AUDIO_TOGGLE_SELF_MUTE",
        syncRemote: true,
        playSoundEffect: true,
        context: "default"
    } as any);
}

function toggleDeafen() {
    try {
        MediaEngineActions.toggleSelfDeaf({ context: "default", syncRemote: true });
        return;
    } catch (e) {
        console.debug("[VesktopVCBridge] MediaEngineActions.toggleSelfDeaf failed, falling back", e);
    }
    FluxDispatcher.dispatch({
        type: "AUDIO_TOGGLE_SELF_DEAF",
        syncRemote: true,
        playSoundEffect: true,
        context: "default"
    } as any);
}

function findGoLiveButton(): HTMLButtonElement | null {
    for (const button of Array.from(document.querySelectorAll<HTMLButtonElement>("button[aria-label]"))) {
        if (button.disabled) continue;
        const label = (button.getAttribute("aria-label") || "").trim().toLowerCase();
        if (label === "go live" || label.includes("share your screen") || label === "screen share") {
            return button;
        }
    }
    return null;
}

function streamBlockedReason(): string | null {
    for (const button of Array.from(document.querySelectorAll<HTMLButtonElement>("button[aria-label]"))) {
        if (!button.disabled) continue;
        const label = (button.getAttribute("aria-label") || "").trim().toLowerCase();
        if (label.includes("can’t stream") || label.includes("can't stream")) {
            return button.getAttribute("aria-label") || "Discord does not allow streaming here";
        }
    }
    return null;
}

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

async function startStream(): Promise<{ ok: boolean; error?: string }> {
    // 1. The share button is on screen already.
    const direct = findGoLiveButton();
    if (direct) {
        direct.click();
        return { ok: true };
    }

    // 2. It is not: open the voice channel view so the call controls render.
    const me: any = UserStore.getCurrentUser();
    const selfVoice = me ? VoiceStateStore.getVoiceStateForUser(me.id) : null;
    if (!selfVoice?.channelId) {
        return { ok: false, error: "You are not in a voice channel" };
    }

    const channel: any = ChannelStore.getChannel(selfVoice.channelId);
    FluxDispatcher.dispatch({
        type: "CHANNEL_SELECT",
        guildId: channel?.guild_id ?? null,
        channelId: selfVoice.channelId
    } as any);
    await sleep(700);

    const button = findGoLiveButton();
    if (button) {
        button.click();
        return { ok: true };
    }

    const blocked = streamBlockedReason();
    if (blocked) {
        return { ok: false, error: blocked };
    }

    return { ok: false, error: "Could not find Discord's screen share button" };
}

async function handleCommand(message: any) {
    switch (message.cmd) {
        case "toggle_mute":
            toggleMute();
            break;
        case "toggle_deafen":
            toggleDeafen();
            break;
        case "start_stream": {
            const result = await startStream();
            if (!result.ok) {
                try {
                    (window as any).VesktopNative?.win?.focus?.();
                } catch {
                    // ignore
                }
                showToast({
                    message: result.error ?? "Could not open the screen share picker",
                    variant: "critical"
                } as any);
            }
            send({ type: "cmd_result", id: message.id, ok: result.ok, cmd: message.cmd, error: result.error });
            break;
        }
        case "stop_stream":
            stopStream();
            send({ type: "cmd_result", id: message.id, ok: true, cmd: message.cmd });
            break;
        case "local_mute": {
            const userId = String(message.userId ?? "");
            if (!userId) {
                send({ type: "cmd_result", id: message.id, ok: false, cmd: message.cmd, error: "missing userId" });
                break;
            }
            let want: boolean;
            if (typeof message.mute === "boolean") {
                want = message.mute;
            } else {
                let current = false;
                try {
                    current = !!(MediaEngineStore as any).isLocalMute?.(userId);
                } catch {
                    // assume unmuted
                }
                want = !current;
            }
            const ok = setLocalMute(userId, want);
            send({ type: "cmd_result", id: message.id, ok, cmd: message.cmd, error: ok ? undefined : "could not set local mute" });
            break;
        }
        case "local_volume": {
            const userId = String(message.userId ?? "");
            if (!userId) {
                send({ type: "cmd_result", id: message.id, ok: false, cmd: message.cmd, error: "missing userId" });
                break;
            }
            const requested = Number(message.volume ?? 100);
            const ok = setLocalVolume(userId, requested);
            let applied = null;
            try {
                applied = Number((MediaEngineStore as any).getLocalVolume?.(userId));
            } catch {
                // ignore
            }
            send({ type: "cmd_result", id: message.id, ok, cmd: message.cmd, result: JSON.stringify({ requested, applied }), error: ok ? undefined : "could not set local volume" });
            break;
        }
        case "debug_eval": {
            if (!settings.store.debug) {
                send({ type: "cmd_result", id: message.id, ok: false, cmd: message.cmd, error: "debug is disabled in the plugin settings" });
                break;
            }
            try {
                // eslint-disable-next-line no-eval
                const value = (0, eval)(String(message.code ?? ""));
                const result =
                    typeof value === "string"
                        ? value
                        : JSON.stringify(value, (_key, v) => (typeof v === "bigint" ? `${v}n` : v)) ?? String(value);
                send({ type: "cmd_result", id: message.id, ok: true, cmd: message.cmd, result });
            } catch (e) {
                send({ type: "cmd_result", id: message.id, ok: false, cmd: message.cmd, error: String(e) });
            }
            break;
        }
        default:
            send({ type: "cmd_result", id: message.id, ok: false, error: `unknown cmd ${message.cmd}` });
    }
    // Reflect the new state quickly.
    setTimeout(sendState, 150);
}

// ---------------------------------------------------------------------------
// plugin
// ---------------------------------------------------------------------------

export default definePlugin({
    name: "VesktopVCBridge",
    description: "Feeds voice-channel state and controls to the local vc-bridge daemon (bar widget)",
    authors: [{ name: "eccemono", id: 0n }],
    settings,

    flux: {
        SPEAKING(event: any) {
            const flags = Number(event?.speakingFlags ?? 0);
            if (flags & 1) speaking.set(event.userId, Date.now());
            else speaking.delete(event.userId);
            scheduleSnapshot();
        },
        VOICE_STATE_UPDATES() {
            scheduleSnapshot();
        },
        STREAM_START() {
            scheduleSnapshot();
        },
        STREAM_STOP() {
            scheduleSnapshot();
        },
        AUDIO_TOGGLE_SELF_MUTE() {
            scheduleSnapshot();
        },
        AUDIO_TOGGLE_SELF_DEAF() {
            scheduleSnapshot();
        }
    },

    start() {
        stopped = false;
        connect();
        heartbeatTimer = setInterval(() => {
            if (!ws || ws.readyState !== WebSocket.OPEN) {
                connect();
                return;
            }
            send({ type: "ping", ts: Date.now() });
            sendState();
        }, 5000);
    },

    stop() {
        stopped = true;
        if (reconnectTimer) clearTimeout(reconnectTimer);
        if (heartbeatTimer) clearInterval(heartbeatTimer);
        if (snapshotTimer) clearTimeout(snapshotTimer);
        reconnectTimer = null;
        heartbeatTimer = null;
        snapshotTimer = null;
        try {
            ws?.close();
        } catch {
            // ignore
        }
        ws = null;
    }
});
