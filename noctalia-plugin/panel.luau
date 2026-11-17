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
local focus_pending = false
local focus_error = ""
local saved_error = ""

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

local function truncate(text, limit)
    if #text <= limit then return text end
    return string.sub(text, 1, limit - 1) .. "…"
end

local function saved_list(st)
    return type(st.savedVcs) == "table" and st.savedVcs or {}
end

local function is_starred(st)
    local current = type(st.channel) == "table" and st.channel.id
    if not current then return false end
    for _, vc in ipairs(saved_list(st)) do
        if tostring(vc.id) == tostring(current) then return true end
    end
    return false
end

local function join_saved(channel_id)
    noctalia.runAsync({ VCB, "join-vc", channel_id }, function()
        state = read_state()
        render()
    end)
end

local function remove_saved(channel_id)
    noctalia.runAsync({ VCB, "save-vc", channel_id, "off" }, function()
        state = read_state()
        render()
    end)
end

local function saved_row(st, connected, plugin_connected)
    local chips = {}
    local starred = connected and is_starred(st)
    chips[#chips + 1] = ui.button({
        key = "save-vc",
        glyph = starred and "star-filled" or "star",
        glyphSize = 14,
        controlSize = "sm",
        variant = starred and "primary" or "secondary",
        enabled = connected,
        tooltip = starred and noctalia.tr("panel.saved") or noctalia.tr("panel.save_vc"),
        onClick = "onToggleSaved",
    })
    for _, vc in ipairs(saved_list(st)) do
        local id = tostring(vc.id or "")
        if id ~= "" then
            chips[#chips + 1] = ui.button({
                key = "saved-" .. id,
                text = truncate(tostring(vc.name or "Voice"), 10) .. " " .. tostring(tonumber(vc.count) or 0),
                controlSize = "sm",
                variant = "secondary",
                enabled = plugin_connected,
                tooltip = noctalia.tr("panel.saved_chip"),
                onClick = function() join_saved(id) end,
                onRightClick = function() remove_saved(id) end,
            })
        end
    end
    return ui.row({ gap = 6, align = "center" }, chips)
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
            ui.glyph({ name = "spiral", size = 24, color = "on_surface_variant" }),
            ui.label({ text = noctalia.tr("panel.empty"), color = "on_surface_variant" }),
        })
        if st ~= nil and #saved_list(st) > 0 then
            local plugin_connected = type(st.plugin) == "table" and st.plugin.connected == true
            content[#content + 1] = saved_row(st, false, plugin_connected)
        end
        if saved_error ~= "" then
            content[#content + 1] = ui.label({ text = saved_error, fontSize = 11, color = "error" })
        end
        panel.render(ui.column({ gap = 12, padding = 16 }, content))
        return
    end

    local channel = st.channel or {}
    local self_member = st.self
    local members = st.members or {}
    local focused = type(st.focus) == "table" and st.focus.enabled == true

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
        ui.button({
            key = "panel-disconnect",
            glyph = "phone-off",
            glyphSize = 14,
            controlSize = "sm",
            variant = "destructive",
            tooltip = noctalia.tr("panel.disconnect"),
            onClick = "onDisconnect",
        }),
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
        ui.row({
            key = "panel-focus",
            width = 40,
            height = 38,
            radius = 8,
            fill = focused and "#3ba55d2e" or "#ed42452e",
            border = focused and "#3ba55d" or "#ed4245",
            borderWidth = 1,
            align = "center",
            justify = "center",
            opacity = focus_pending and 0.55 or 1,
            tooltip = focused and noctalia.tr("panel.focus_on") or noctalia.tr("panel.focus"),
            onClick = (not focus_pending) and "onToggleFocus" or nil,
        }, {
            ui.glyph({ name = "focus-2", size = 15, color = focused and "#3ba55d" or "#ed4245" }),
        }),
        ui.button({
            key = "panel-share",
            text = self_member.streaming and noctalia.tr("panel.stop_share") or noctalia.tr("panel.share"),
            glyph = self_member.streaming and "screen-share-off" or "screen-share",
            variant = self_member.streaming and "primary" or "secondary",
            onClick = "onToggleShare",
        }),
    })

    if focus_error ~= "" then
        content[#content + 1] = ui.label({ text = focus_error, fontSize = 11, color = "error" })
    end

    content[#content + 1] = saved_row(st, true, true)

    if saved_error ~= "" then
        content[#content + 1] = ui.label({ text = saved_error, fontSize = 11, color = "error" })
    end

    panel.render(ui.column({ gap = 12, padding = 16 }, content))
end

local last_frame_ms = 0

function onOpen(_context)
    panel.setWantsSecondTicks(true)
    panel.setNeedsFrameTick(true)
    pending_volume = {}
    last_sent = {}
    focus_pending = false
    focus_error = ""
    saved_error = ""
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

function onToggleSaved()
    if not state or state.connected ~= true then return end
    local current = type(state.channel) == "table" and state.channel.id
    if not current then return end
    local starred = is_starred(state)
    saved_error = ""
    noctalia.runAsync({ VCB, "save-vc", tostring(current), starred and "off" or "on" }, function(result)
        if result == nil or result.exitCode ~= 0 then
            local message = noctalia.tr("panel.saved_error")
            if result ~= nil and type(result.stderr) == "string" and result.stderr ~= "" then
                local detail = string.gsub(result.stderr, "^error:%s*", "")
                detail = string.gsub(detail, "%s+$", "")
                if detail ~= "" then message = detail end
            end
            saved_error = message
        end
        state = read_state()
        render()
    end)
end

function onDisconnect()
    run_vcb("disconnect")
end

function onToggleMute()
    run_vcb("mute")
end

function onToggleFocus()
    if focus_pending or not state or state.connected ~= true then return end
    local channel = state.channel or {}
    if not channel.id then return end
    local focused = type(state.focus) == "table" and state.focus.enabled == true
    focus_pending = true
    focus_error = ""
    render()
    noctalia.runAsync({ VCB, "focus", focused and "off" or "on", tostring(channel.id) }, function(result)
        focus_pending = false
        if result == nil or result.exitCode ~= 0 then
            focus_error = noctalia.tr("panel.focus_failed")
        end
        state = read_state()
        render()
    end)
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
