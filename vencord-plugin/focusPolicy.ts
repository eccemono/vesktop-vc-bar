export function focusChannels(value: string): Set<string> {
    return new Set(value.split(/[\s,]+/).filter(id => /^\d{1,20}$/.test(id)));
}

export function hasFocus(value: string, channelId: string | null | undefined): boolean {
    return !!channelId && focusChannels(value).has(channelId);
}

export function setChannelFocus(value: string, channelId: string, enabled: boolean): string {
    if (!/^\d{1,20}$/.test(channelId)) throw new Error("Invalid voice channel ID");
    const ids = focusChannels(value);
    if (enabled) ids.add(channelId);
    else ids.delete(channelId);
    return [...ids].join(", ");
}

export function isFeedbackSound(name: unknown): boolean {
    return typeof name === "string" && /^(?:mute|unmute|deafen|undeafen)$/.test(name);
}
