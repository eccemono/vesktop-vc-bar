import { MediaEngineStore, RTCConnectionStore, SelectedChannelStore } from "@webpack/common";

import { hasFocus, isFeedbackSound, setChannelFocus } from "./focusPolicy";
import settings from "./settings";

type Sound = {
    name: string;
    vcBridgeSoundKey?: string;
    stop(): void;
};

let running = false;
let style: HTMLStyleElement | null = null;
let originalNotification: typeof Notification | null = null;
let guardedNotification: typeof Notification | null = null;
let originalSpeak: SpeechSynthesis["speak"] | null = null;
let guardedSpeak: SpeechSynthesis["speak"] | null = null;
let notificationObserver: MutationObserver | null = null;
let leavingFocusedUntil = 0;
let lastFocused = false;
const sounds = new Set<Sound>();
const soundboards = new Set<{ _stopAndClearSounds(): void }>();

function currentChannelId(): string | null {
    try {
        // Discord can retain the last selected VC after a restart without joining it.
        // RTC_DISCONNECTED is a transient reconnect; DISCONNECTED means we left.
        if (RTCConnectionStore.getState() === "DISCONNECTED") return null;
        return SelectedChannelStore.getVoiceChannelId() ?? null;
    } catch {
        return null;
    }
}

function isActive(): boolean {
    try {
        return running && hasFocus(settings.store.focusChannelIds, currentChannelId());
    } catch {
        return false;
    }
}

function shouldSilenceSound(sound: Sound): boolean {
    const name = sound.vcBridgeSoundKey ?? sound.name;
    // The original sound key is retained before Discord maps seasonal soundpacks.
    if (isFeedbackSound(name)) {
        sounds.add(sound);
        return false;
    }
    if (isActive() || (running && name === "disconnect" && Date.now() < leavingFocusedUntil)) return true;
    sounds.add(sound);
    return false;
}

function forgetSound(sound: Sound): void {
    sounds.delete(sound);
}

function trackSoundboard(manager: { _stopAndClearSounds(): void }): void {
    soundboards.add(manager);
}

function dismissPluginNotifications(): void {
    for (const button of document.querySelectorAll<HTMLButtonElement>("#vc-notification-container .vc-notification-close-btn")) button.click();
}

function sync(): void {
    const active = isActive();
    document.documentElement.classList.toggle("vc-voice-focus", active);
    if (active && !lastFocused) {
        dismissPluginNotifications();
        for (const sound of [...sounds]) {
            if (!isFeedbackSound(sound.vcBridgeSoundKey ?? sound.name)) {
                try { sound.stop(); } catch { /* best effort */ }
                sounds.delete(sound);
            }
        }
        window.speechSynthesis?.cancel();
        for (const manager of soundboards) {
            try { manager._stopAndClearSounds(); } catch { /* best effort */ }
        }
        // Soundboard samples are separate from normal voice audio.
        try {
            const engine = MediaEngineStore.getMediaEngine();
            for (const connection of engine.connections.values()) {
                (connection as any).stopAllSamplesLocalPlayback?.();
            }
        } catch { /* no media engine while connecting */ }
    }
    lastFocused = active;
}

function onVoiceSelect(channelId: string | null): void {
    if (!channelId && (lastFocused || isActive())) leavingFocusedUntil = Date.now() + 1500;
    // SelectedChannelStore finishes its update before this task runs.
    setTimeout(sync, 0);
}

function setFocus(channelId: string, enabled: boolean): void {
    if (!running || channelId !== currentChannelId()) throw new Error("The voice channel changed. Reopen the panel and try again.");
    settings.store.focusChannelIds = setChannelFocus(settings.store.focusChannelIds, channelId, enabled);
    sync();
}

function start(): void {
    running = true;
    style = document.createElement("style");
    style.textContent = ".vc-voice-focus #vc-notification-container { display: none !important; }";
    document.head.append(style);
    notificationObserver = new MutationObserver(records => {
        if (!isActive()) return;
        for (const record of records) {
            for (const node of record.addedNodes) {
                if (node instanceof Element && (node.id === "vc-notification-container" || node.closest("#vc-notification-container"))) {
                    // Drain the queue silently instead of showing old plugin popups when Focus ends.
                    dismissPluginNotifications();
                    return;
                }
            }
        }
    });
    notificationObserver.observe(document.body, { childList: true, subtree: true });

    originalNotification = window.Notification;
    guardedNotification = new Proxy(originalNotification, {
        construct(target, args, newTarget) {
            if (!isActive()) return Reflect.construct(target, args, newTarget);
            // Drop plugin-originated desktop alerts without requesting OS delivery.
            return Object.assign(new EventTarget(), {
                title: String(args[0] ?? ""), body: args[1]?.body ?? "",
                onclick: null, onclose: null, onshow: null, onerror: null,
                close() { }
            });
        }
    });
    window.Notification = guardedNotification;

    if (window.speechSynthesis) {
        originalSpeak = window.speechSynthesis.speak;
        guardedSpeak = function (this: SpeechSynthesis, utterance) {
            if (!isActive()) originalSpeak!.call(this, utterance);
        };
        window.speechSynthesis.speak = guardedSpeak;
    }
    sync();
}

function stop(): void {
    running = false;
    lastFocused = false;
    leavingFocusedUntil = 0;
    sounds.clear();
    soundboards.clear();
    notificationObserver?.disconnect();
    notificationObserver = null;
    document.documentElement.classList.remove("vc-voice-focus");
    style?.remove();
    style = null;
    if (window.Notification === guardedNotification && originalNotification) window.Notification = originalNotification;
    if (window.speechSynthesis?.speak === guardedSpeak && originalSpeak) window.speechSynthesis.speak = originalSpeak;
    guardedNotification = originalNotification = null;
    guardedSpeak = originalSpeak = null;
}

export default { currentChannelId, isActive, shouldSilenceSound, forgetSound, trackSoundboard, sync, onVoiceSelect, setFocus, start, stop };
