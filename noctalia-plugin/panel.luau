-- panel.luau — the full voice channel view: everyone in the call with
-- mute/deafen/speaking/streaming badges, plus the self controls.

--!nonstrict

local STATE_PATH = "~/.cache/vc-bridge/state.json"

local state = nil

local function resolve_vcb()
    local p = noctalia.expandPath("~/.local/bin/vcb")
    if noctalia.fileExists(p) then return p end
    return "vcb"
end

local VCB = resolve_vcb()

-- per-user local volume, kept locally while dragging so the 1 s refresh
-- does not fight the slider
local pending_volume = {}
local last_sent = {}

local function send_volume(user_id, value)
    local volume = math.max(0, math.min(200, math.floor(value + 0.5)))
    noctalia.runAsync({ VCB, "local-volume", user_id, tostring(volume) })
end

local function on_volume_change(user_id, value)
    local volume = tonumber(value)
    if volume == nil then return end
    pending_volume[user_id] = volume
    local now = noctalia.nowMs()
    if (last_sent[user_id] or 0) + 250 < now then
        last_sent[user_id] = now
        send_volume(user_id, volume)
    end
end

local function on_volume_end(user_id, value)
    local volume = tonumber(value)
    if volume == nil then return end
    pending_volume[user_id] = volume
    last_sent[user_id] = noctalia.nowMs()
    send_volume(user_id, volume)
end

local function toggle_local_mute(user_id, muted)
    noctalia.runAsync({ VCB, "local-mute", user_id, muted and "on" or "off" })
end

local function read_state()
    local raw = noctalia.readFile(STATE_PATH)
    if type(raw) ~= "string" or raw == "" then return nil end
    local ok, data = pcall(noctalia.json.decode, raw)
    if not ok or type(data) ~= "table" then return nil end
    return data
end

local function run_vcb(action)
    noctalia.runAsync({ VCB, action }, function()
        state = read_state()
        render()
    end)
end

local function ordered(members)
    local decorated = {}
    for index, member in ipairs(members) do
        decorated[#decorated + 1] = { member = member, index = index }
    end
    table.sort(decorated, function(a, b)
        local a_speaking = a.member.speaking and 1 or 0
        local b_speaking = b.member.speaking and 1 or 0
        if a_speaking ~= b_speaking then return a_speaking > b_speaking end
        local a_at = tonumber(a.member.speakingAt) or 0
        local b_at = tonumber(b.member.speakingAt) or 0
        if a_at ~= b_at then return a_at > b_at end
        return a.index < b.index
    end)
    local out = {}
    for _, entry in ipairs(decorated) do out[#out + 1] = entry.member end
    return out
end

local function fallback_avatar(member, size)
    local radius = math.floor(size / 2)
    local speaking = member.speaking == true
    return ui.row({
        width = size,
        height = size,
        radius = radius,
        fill = "surface_container_highest",
        border = speaking and "primary" or "surface_container_highest",
        borderWidth = speaking and 3 or 1,
        align = "center",
        justify = "center",
    }, {
        ui.label({
            text = string.upper(string.sub(tostring(member.name or "?"), 1, 1)),
            fontSize = math.floor(size * 0.45),
            fontWeight = "bold",
        }),
    })
end

local function member_avatar(member, size)
    if type(member.avatar_path) == "string" and member.avatar_path ~= "" then
        local speaking = member.speaking == true
        return ui.image({
            path = member.avatar_path,
            width = size,
            height = size,
            radius = math.floor(size / 2),
            fit = "cover",
            border = speaking and "primary" or "surface_container_highest",
            borderWidth = speaking and 3 or 1,
        })
    end
    return fallback_avatar(member, size)
end

local function status_text(member)
    local flags = {}
    if member.speaking then flags[#flags + 1] = noctalia.tr("panel.speaking") end
    if member.serverMute then
        flags[#flags + 1] = noctalia.tr("panel.server_muted")
    elseif member.mute then
        flags[#flags + 1] = noctalia.tr("panel.muted")
    end
    if member.serverDeaf then
        flags[#flags + 1] = noctalia.tr("panel.server_deafened")
    elseif member.deaf then
        flags[#flags + 1] = noctalia.tr("panel.deafened")
    end
    if member.streaming then flags[#flags + 1] = noctalia.tr("panel.streaming") end
    if member.localMute then flags[#flags + 1] = noctalia.tr("panel.muted_for_you") end
    local text = #flags == 0 and noctalia.tr("panel.in_call") or table.concat(flags, " · ")
    local volume = tonumber(member.localVolume)
    if volume ~= nil and math.abs(volume - 100) >= 1 then
        text = text .. " · " .. tostring(math.floor(volume + 0.5)) .. "%"
    end
    return text
end

local WAVE_BARS = 6

local function waveform(member)
    local history = type(member.levels) == "table" and member.levels or {}
    local speaking = member.speaking == true
    local clock = noctalia.nowMs() / 1000
    local values = {}
    local active = false
    for i = 1, WAVE_BARS do
        local index = #history - WAVE_BARS + i
        local level = 0
        if index >= 1 then level = tonumber(history[index]) or 0 end
        if level <= 0.001 and speaking then
            -- no WebRTC levels available: animate a small pattern while talking
            level = 0.2 + 0.4 * (0.5 + 0.5 * math.sin(clock * 9 + i * 1.1))
        end
        level = math.max(0, math.min(1, level))
        values[i] = level
        if level > 0.02 then active = true end
    end

    local bars = {}
    for i = 1, WAVE_BARS do
        bars[i] = ui.box({
            key = "wave-" .. i,
            width = 2,
            height = math.floor(2 + values[i] * 11),
            radius = 1,
            fill = active and "primary" or "surface_container_highest",
        })
    end
    return ui.row({ gap = 1, align = "center", justify = "center" }, bars)
end

local function member_row(member, is_self)
    local name = tostring(member.name or member.userId or "?")
    if is_self then name = name .. " " .. noctalia.tr("panel.you") end
    local user_id = tostring(member.userId or "")
    local muted = member.localMute == true

    local children = {
        member_avatar(member, 28),
        ui.column({ gap = 1, flexGrow = 1, align = "start" }, {
            ui.label({ text = name, fontWeight = "semibold" }),
            ui.label({ text = status_text(member), fontSize = 11, color = "on_surface_variant" }),
        }),
    }

    if not is_self and user_id ~= "" then
        local volume = pending_volume[user_id] or tonumber(member.localVolume) or 100
        children[#children + 1] = ui.slider({
            key = "vol-" .. user_id,
            min = 0,
            max = 200,
            step = 5,
            value = volume,
            width = 64,
            controlSize = "sm",
            onChange = function(value) on_volume_change(user_id, value) end,
            onDragEnd = function(value) on_volume_end(user_id, value) end,
        })
        children[#children + 1] = ui.button({
            key = "lmute-" .. user_id,
            glyph = muted and "microphone-off" or "microphone",
            glyphSize = 14,
            controlSize = "sm",
            variant = muted and "destructive" or "ghost",
            onClick = function() toggle_local_mute(user_id, not muted) end,
        })
    end

    -- every row ends with the waveform so they line up on the right edge
    children[#children + 1] = waveform(member)

    return ui.row({
        key = user_id ~= "" and user_id or name,
        gap = 10,
        align = "center",
        fill = member.speaking and "primary/0.18" or "surface_container_low",
        radius = 8,
        padding = 8,
    }, children)
end

function render()
    local st = state
    local content = {}

    if not st or st.connected ~= true or type(st.self) ~= "table" then
        content[#content + 1] = ui.column({ gap = 8, align = "center", paddingV = 24 }, {
            ui.glyph({ name = "microphone-off", size = 24, color = "on_surface_variant" }),
            ui.label({ text = noctalia.tr("panel.empty"), color = "on_surface_variant" }),
        })
        panel.render(ui.column({ gap = 12, padding = 16 }, content))
        return
    end

    local channel = st.channel or {}
    local self_member = st.self
    local members = st.members or {}

    local heading = channel.name or "Voice"
    local subtitle = channel.guildName or ""
    content[#content + 1] = ui.row({ align = "center", gap = 10, justify = "space_between" }, {
        ui.column({ gap = 1, align = "start", flexGrow = 1 }, {
            ui.label({ text = heading, fontSize = 15, fontWeight = "bold" }),
            ui.label({
                text = subtitle ~= "" and subtitle or noctalia.tr("panel.voice_channel"),
                fontSize = 11,
                color = "on_surface_variant",
            }),
        }),
        ui.label({ text = tostring(#members), fontSize = 12, color = "on_surface_variant" }),
    })

    local rows = {}
    for _, member in ipairs(members) do
        rows[#rows + 1] = member_row(member, member.userId == self_member.userId)
    end
    content[#content + 1] = ui.scroll({ flexGrow = 1, gap = 6 }, rows)

    content[#content + 1] = ui.separator({})

    content[#content + 1] = ui.row({ gap = 8, align = "center" }, {
        ui.button({
            key = "panel-mic",
            text = self_member.mute and noctalia.tr("panel.unmute") or noctalia.tr("panel.mute"),
            glyph = self_member.mute and "microphone-off" or "microphone",
            variant = self_member.mute and "destructive" or "secondary",
            onClick = "onToggleMute",
        }),
        ui.button({
            key = "panel-deaf",
            text = self_member.deaf and noctalia.tr("panel.undeafen") or noctalia.tr("panel.deafen"),
            glyph = self_member.deaf and "headphones-off" or "headphones",
            variant = self_member.deaf and "destructive" or "secondary",
            onClick = "onToggleDeafen",
        }),
        ui.button({
            key = "panel-share",
            text = self_member.streaming and noctalia.tr("panel.stop_share") or noctalia.tr("panel.share"),
            glyph = self_member.streaming and "screen-share-off" or "screen-share",
            variant = self_member.streaming and "primary" or "secondary",
            onClick = "onToggleShare",
        }),
    })

    panel.render(ui.column({ gap = 12, padding = 16 }, content))
end

local last_frame_ms = 0

function onOpen(_context)
    panel.setWantsSecondTicks(true)
    panel.setNeedsFrameTick(true)
    pending_volume = {}
    last_sent = {}
    state = read_state()
    render()
end

function onFrameTick(_deltaMs)
    -- ~10 fps is enough for the level bars and keeps the panel cheap
    local now = noctalia.nowMs()
    if now - last_frame_ms < 100 then return end
    last_frame_ms = now
    state = read_state()
    render()
end

function update()
    local next_state = read_state()
    state = next_state
    render()
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
