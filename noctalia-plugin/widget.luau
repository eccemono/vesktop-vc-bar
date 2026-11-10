-- widget.luau — voice channel bubbles for Vesktop, plus self controls.
-- Data comes from the vc-bridge daemon via ~/.cache/vc-bridge/state.json;
-- control buttons shell out to the `vcb` CLI.

--!nonstrict

local STATE_PATH = "~/.cache/vc-bridge/state.json"
local PANEL_ID = "eccemono/vesktop-vc:details"

local state = nil

local function int_cfg(key, default, min, max)
    local n = tonumber(noctalia.getConfig(key))
    if n == nil then n = default end
    if n < min then n = min end
    if n > max then n = max end
    return math.floor(n)
end

local function bool_cfg(key, default)
    local v = noctalia.getConfig(key)
    if v == nil then return default end
    if v == true or v == "true" then return true end
    if v == false or v == "false" then return false end
    return default
end

local function resolve_vcb()
    local p = noctalia.expandPath("~/.local/bin/vcb")
    if noctalia.fileExists(p) then return p end
    return "vcb"
end

local VCB = resolve_vcb()

local function run_vcb(action)
    noctalia.runAsync({ VCB, action })
end

local function read_state()
    local raw = noctalia.readFile(STATE_PATH)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, data = pcall(noctalia.json.decode, raw)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

-- Most recent speakers first; used only when there are more people than
-- bubbles (at 5 or fewer the order stays stable, like Discord's channel).
local function speakers_first(members)
    local decorated = {}
    for index, member in ipairs(members) do
        decorated[#decorated + 1] = { member = member, index = index }
    end
    table.sort(decorated, function(a, b)
        local a_at = tonumber(a.member.speakingAt) or 0
        local b_at = tonumber(b.member.speakingAt) or 0
        if a_at ~= b_at then return a_at > b_at end
        return a.index < b.index
    end)
    local out = {}
    for _, entry in ipairs(decorated) do out[#out + 1] = entry.member end
    return out
end

local function avatar(member, size)
    local radius = math.floor(size / 2)
    local speaking = member.speaking == true
    local border = speaking and "primary" or "surface_container_highest"
    local border_width = speaking and 2 or 1

    if type(member.avatar_path) == "string" and member.avatar_path ~= "" then
        return ui.image({
            path = member.avatar_path,
            width = size,
            height = size,
            radius = radius,
            fit = "cover",
            border = border,
            borderWidth = border_width,
        })
    end

    local initial = string.upper(string.sub(tostring(member.name or "?"), 1, 1))
    return ui.row({
        width = size,
        height = size,
        radius = radius,
        fill = "surface_container_highest",
        border = border,
        borderWidth = border_width,
        align = "center",
        justify = "center",
    }, {
        ui.label({ text = initial, fontSize = math.floor(size * 0.45), fontWeight = "bold" }),
    })
end

local function bubble(member, size)
    -- mute/deafen/screen-share badges are baked into the avatar by vc-bridge,
    -- bottom-aligned over the picture, so the bubble is just the image.
    return ui.row({
        key = tostring(member.userId or member.name or "member"),
        gap = 0,
        align = "center",
    }, { avatar(member, size) })
end

local function controls(self_member)
    local buttons = {}
    local show = bool_cfg("show_controls", true)
    if not show then return buttons end

    buttons[#buttons + 1] = ui.button({
        key = "vc-mic",
        glyph = self_member.mute and "microphone-off" or "microphone",
        glyphSize = 14,
        variant = self_member.mute and "destructive" or "ghost",
        onClick = "onToggleMute",
    })
    buttons[#buttons + 1] = ui.button({
        key = "vc-deaf",
        glyph = self_member.deaf and "headphones-off" or "headphones",
        glyphSize = 14,
        variant = self_member.deaf and "destructive" or "ghost",
        onClick = "onToggleDeafen",
    })
    buttons[#buttons + 1] = ui.button({
        key = "vc-share",
        glyph = self_member.streaming and "screen-share-off" or "screen-share",
        glyphSize = 14,
        variant = self_member.streaming and "primary" or "ghost",
        onClick = "onToggleShare",
    })
    return buttons
end

local function tooltip_rows(st)
    local rows = {}
    local channel = st.channel or {}
    local self_member = st.self or {}
    local heading = channel.name or "Voice"
    if channel.guildName then heading = channel.guildName .. " / " .. heading end
    rows[#rows + 1] = { key = "Voice", value = heading }

    local status = {}
    if self_member.mute then status[#status + 1] = "muted" end
    if self_member.deaf then status[#status + 1] = "deafened" end
    if self_member.streaming then status[#status + 1] = "streaming" end
    rows[#rows + 1] = { key = "You", value = #status > 0 and table.concat(status, ", ") or "connected" }

    for _, member in ipairs(st.members or {}) do
        local flags = {}
        if member.speaking then flags[#flags + 1] = "speaking" end
        if member.serverMute then
            flags[#flags + 1] = "server muted"
        elseif member.mute then
            flags[#flags + 1] = "muted"
        end
        if member.serverDeaf then
            flags[#flags + 1] = "server deafened"
        elseif member.deaf then
            flags[#flags + 1] = "deafened"
        end
        if member.streaming then flags[#flags + 1] = "streaming" end
        rows[#rows + 1] = {
            key = tostring(member.name or member.userId or "?"),
            value = #flags > 0 and table.concat(flags, ", ") or "in call",
        }
    end
    return rows
end

local function render()
    local st = state
    local connected = st ~= nil and st.connected == true and type(st.self) == "table"
    local hide_when_idle = bool_cfg("hide_when_idle", true)

    if not connected then
        barWidget.setVisible(not hide_when_idle)
        if hide_when_idle then
            barWidget.clearTooltip()
            return
        end
        barWidget.render(ui.row({ gap = 6, align = "center" }, {
            ui.glyph({ name = "microphone-off", size = 14 }),
            ui.label({ text = noctalia.tr("widget.idle") }),
        }))
        barWidget.setTooltip({ { key = "Vesktop", value = noctalia.tr("widget.idle") } })
        return
    end

    barWidget.setVisible(true)

    local size = int_cfg("avatar_size", 20, 14, 26)
    local max_bubbles = int_cfg("max_bubbles", 5, 1, 8)
    local members = st.members or {}
    local total = #members

    local shown = {}
    local overflow = 0
    if total <= max_bubbles then
        -- 5 or fewer: show everyone, in a stable order (never reshuffle on speak)
        shown = members
    else
        -- more people than bubbles: prioritise whoever is talking, then +N
        local by_voice = speakers_first(members)
        local loud = {}
        for _, member in ipairs(by_voice) do
            if member.speaking then loud[#loud + 1] = member end
        end
        if #loud > 0 then
            for index = 1, math.min(#loud, max_bubbles) do shown[#shown + 1] = loud[index] end
        else
            for index = 1, math.min(total, math.min(max_bubbles, 2)) do shown[#shown + 1] = members[index] end
        end
        overflow = total - #shown
    end

    local children = {}
    for _, member in ipairs(shown) do
        children[#children + 1] = bubble(member, size)
    end
    if overflow > 0 then
        children[#children + 1] = ui.label({
            key = "vc-overflow",
            text = "+" .. tostring(overflow),
            fontSize = 11,
            color = "on_surface_variant",
        })
    end
    for _, button in ipairs(controls(st.self)) do
        children[#children + 1] = button
    end

    barWidget.render(ui.row({ gap = 5, align = "center" }, children))
    barWidget.setTooltip(tooltip_rows(st))
end

noctalia.setUpdateInterval(math.max(200, math.floor(tonumber(noctalia.getConfig("poll_ms")) or 500)))

function update()
    state = read_state()
    render()
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function onToggleMute()
    run_vcb("mute")
end

function onToggleDeafen()
    run_vcb("deafen")
end

function onToggleShare()
    if state and type(state.self) == "table" and state.self.streaming then
        run_vcb("unshare")
    else
        run_vcb("share")
    end
end

-- initial paint (the host also calls update() on the configured interval)
update()
