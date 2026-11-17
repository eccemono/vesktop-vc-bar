import assert from "node:assert/strict";
import test from "node:test";

import { MAX_SAVED_VCS, parseSavedVcs, setSavedVc } from "../vencord-plugin/savedVcs";

test("saved VCs are capped at three and deduplicated", () => {
    assert.equal(MAX_SAVED_VCS, 3);
    assert.deepEqual(parseSavedVcs("1, 2 3\n2 4"), ["1", "2", "3"]);
    assert.deepEqual(parseSavedVcs(""), []);
    assert.deepEqual(parseSavedVcs("abc, -1, 0"), ["0"]);

    let value = "";
    for (const id of ["11", "22", "33"]) {
        const result = setSavedVc(value, id, true);
        assert.equal(result.error, undefined);
        value = result.value;
    }
    const full = setSavedVc(value, "44", true);
    assert.match(full.error!, /3 voice channels/);
    assert.equal(full.value, value);

    const removed = setSavedVc(value, "22", false);
    assert.equal(removed.error, undefined);
    assert.deepEqual(parseSavedVcs(removed.value), ["11", "33"]);
    assert.equal(setSavedVc(removed.value, "44", true).error, undefined);
});

test("star toggles when no explicit state is passed", () => {
    const added = setSavedVc("", "123");
    assert.equal(added.saved, true);
    assert.equal(added.value, "123");
    const removed = setSavedVc(added.value, "123");
    assert.equal(removed.saved, false);
    assert.equal(removed.value, "");
    assert.equal(setSavedVc("123", "123", true).value, "123", "Starring twice is idempotent");
    assert.equal(setSavedVc("123", "456", false).value, "123", "Unstarring an unsaved VC keeps the list");
});

test("invalid channel ids are rejected without touching the list", () => {
    for (const id of ["", "null", "123abc", "1,2", "all"]) {
        const result = setSavedVc("123", id, true);
        assert.ok(result.error);
        assert.equal(result.value, "123");
    }
});
