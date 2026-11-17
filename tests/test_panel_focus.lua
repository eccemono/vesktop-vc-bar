-- Exercise the installed panel's callbacks without opening or operating the desktop.
local snapshot = {
    connected = true,
    self = { userId = "456", name = "Self" },
    channel = { id = "123", name = "Study" },
    members = {},
    focus = { enabled = false, channelId = "123" },
}
local tree
local calls = {}
local completion

noctalia = {
    expandPath = function(p) return p end,
    fileExists = function() return true end,
    readFile = function() return "state" end,
    json = { decode = function() return snapshot end },
    tr = function(key) return key end,
    nowMs = function() return 1000 end,
    runAsync = function(args, callback)
        calls[#calls + 1] = args
        completion = callback
    end,
}
ui = setmetatable({}, { __index = function(_, kind)
    return function(props, children) return { kind = kind, props = props, children = children or {} } end
end })
panel = {
    render = function(value) tree = value end,
    setWantsSecondTicks = function() end,
    setNeedsFrameTick = function() end,
}

local function find(key, node)
    node = node or tree
    if node.props.key == key then return node end
    for _, child in ipairs(node.children) do
        local match = find(key, child)
        if match then return match end
    end
end

local function find_row_containing(key, node)
    node = node or tree
    if node.kind == "row" then
        for _, child in ipairs(node.children) do
            if child.props and child.props.key == key then return node end
        end
    end
    for _, child in ipairs(node.children or {}) do
        local match = find_row_containing(key, child)
        if match then return match end
    end
end

local function button_order(key)
    local names = {}
    for _, child in ipairs(find_row_containing(key).children) do
        if child.props and child.props.key then names[#names + 1] = child.props.key end
    end
    return table.concat(names, ",")
end

assert(loadfile(arg[1] or "noctalia-plugin/panel.luau"))()
onOpen()
assert(find("panel-focus").kind == "row", "Focus is a compact icon chip")
assert(find("panel-focus").props.border == "#ed4245", "Focus off is red")
assert(find("panel-focus").props.tooltip == "panel.focus")
assert(button_order("panel-focus") == "panel-mic,panel-deaf,panel-focus,panel-share",
    "Focus sits between Deafen and Share screen")
local disconnect = find("panel-disconnect")
assert(disconnect.props.text == nil and disconnect.props.glyph == "phone-off" and disconnect.props.variant == "destructive")
assert(find_row_containing("panel-disconnect") ~= find_row_containing("panel-focus"),
    "Disconnect lives in the channel header, not the controls row")
assert(disconnect.props.onClick == "onDisconnect")
onDisconnect()
assert(calls[1][2] == "disconnect", "Disconnect uses the CLI")

onToggleFocus()
assert(calls[2][2] == "focus" and calls[2][3] == "on" and calls[2][4] == "123")
assert(find("panel-focus").props.onClick == nil and find("panel-focus").props.opacity < 1)
onToggleFocus()
assert(#calls == 2, "Double clicks must not send duplicate commands")

snapshot.focus.enabled = true
completion({ exitCode = 0 })
assert(find("panel-focus").props.tooltip == "panel.focus_on")
assert(find("panel-focus").props.border == "#3ba55d", "Focus on is green")
assert(find("panel-focus").props.onClick == "onToggleFocus")

onToggleFocus()
assert(calls[3][3] == "off" and calls[3][4] == "123")
completion({ exitCode = 1 })
assert(find("panel-focus").props.tooltip == "panel.focus_on", "Failed toggle must not fake success")
local error_label
for _, child in ipairs(tree.children) do
    if child.kind == "label" and child.props.color == "error" then error_label = child end
end
assert(error_label and error_label.props.text == "panel.focus_failed", "Failure is shown without breaking the row")

snapshot.connected = false
onOpen()
local count = #calls
onToggleFocus()
assert(#calls == count, "Focus cannot be toggled outside a call")
print("PASS: icon-only Focus between Deafen and Share, on/off, persistence, double-click guard, errors and disconnected state")
