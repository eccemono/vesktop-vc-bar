export const MAX_SAVED_VCS = 3;

export function parseSavedVcs(value: string): string[] {
    return [...new Set(value.split(/[\s,]+/).filter(id => /^\d{1,20}$/.test(id)))].slice(0, MAX_SAVED_VCS);
}

export function setSavedVc(value: string, channelId: string, saved?: boolean): { value: string; saved: boolean; error?: string } {
    if (!/^\d{1,20}$/.test(channelId)) return { value, saved: false, error: "Invalid voice channel ID" };
    const ids = parseSavedVcs(value);
    const wasSaved = ids.includes(channelId);
    const want = typeof saved === "boolean" ? saved : !wasSaved;
    if (want && !wasSaved && ids.length >= MAX_SAVED_VCS)
        return { value, saved: wasSaved, error: `You can save ${MAX_SAVED_VCS} voice channels` };
    const next = want ? (wasSaved ? ids : [...ids, channelId]) : ids.filter(id => id !== channelId);
    return { value: next.join(", "), saved: want };
}
