import assert from "node:assert/strict";
import test from "node:test";

import { focusChannels, hasFocus, isFeedbackSound, setChannelFocus } from "../vencord-plugin/focusPolicy";

test("Focus remembers individual channels without enabling it globally", () => {
    let saved = setChannelFocus("", "123", true);
    saved = setChannelFocus(saved, "456", true);
    assert.equal(hasFocus(saved, "123"), true);
    assert.equal(hasFocus(saved, "456"), true);
    assert.equal(hasFocus(saved, "789"), false);
    assert.equal(hasFocus(saved, null), false);
    assert.equal(hasFocus(saved, undefined), false);
    assert.equal(hasFocus(saved, ""), false);
    assert.equal(hasFocus(saved, "12"), false);

    saved = setChannelFocus(saved, "123", false);
    assert.equal(hasFocus(saved, "123"), false);
    assert.equal(hasFocus(saved, "456"), true);
});

test("Remembered state survives serialization/reload and adding a channel twice", () => {
    const saved = setChannelFocus(setChannelFocus("", "123", true), "123", true);
    const persisted = JSON.parse(JSON.stringify({ focusChannelIds: saved }));
    assert.deepEqual([...focusChannels(persisted.focusChannelIds)], ["123"]);
    assert.equal(hasFocus(persisted.focusChannelIds, "123"), true);
});

test("Invalid IDs are not persisted", () => {
    assert.deepEqual([...focusChannels("123, hello, 456\n123")], ["123", "456"]);
    for (const id of ["", "null", "all", "123abc", "1,2"]) {
        assert.throws(() => setChannelFocus("123", id, true));
    }
});

test("Only self mute/unmute and deafen/undeafen feedback is allowed", () => {
    for (const name of ["mute", "unmute", "deafen", "undeafen"]) assert.equal(isFeedbackSound(name), true);
    for (const name of [
        "user_join", "user_leave", "user_moved", "reconnect", "disconnect",
        "stream_started", "stream_ended", "stream_user_joined", "message1", "message3",
        "call_calling", "call_ringing", "ptt_start", "ptt_stop", "activity_launch",
        "fake_mute", "", undefined, null,
    ]) assert.equal(isFeedbackSound(name), false);
});
