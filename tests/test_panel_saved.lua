-- Exercise the saved-VC footer of the panel without opening it.
local snapshot = {
    connected = true,
    self = { userId = "1", name = "Self" },
    channel = { id = "123", name = "Study" },
    members = {},
    focus = { enabled = false, channelId = "123" },
    plugin = { connected = true },
    savedVcs = {
        { id = "123", name = "Study", count = 3 },
        { id = "456", name = "Chill", count = 0 },
    },
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

assert(loadfile(arg[1] or "noctalia-plugin/panel.luau"))()
onOpen()

local star = find("save-vc")
assert(star.props.glyph == "star-filled", "Current VC is starred")
assert(star.props.onClick == "onToggleSaved")
local study = find("saved-123")
local chill = find("saved-456")
assert(study.props.text == "Study 3", "Saved chip shows name and member count")
assert(chill.props.text == "Chill 0", "Empty saved VC shows 0")
assert(study.props.onClick ~= nil and study.props.onRightClick ~= nil)

study.props.onClick()
assert(calls[1][2] == "join-vc" and calls[1][3] == "123")
study.props.onRightClick()
assert(calls[2][2] == "save-vc" and calls[2][3] == "123" and calls[2][4] == "off")

onToggleSaved()
assert(calls[3][2] == "save-vc" and calls[3][3] == "123" and calls[3][4] == "off", "Starred VC un-stars")
completion({ exitCode = 1, stderr = "error: You can save 3 voice channels\n" })
local label
for _, child in ipairs(tree.children) do
    if child.kind == "label" and child.props.color == "error" then label = child end
end
assert(label and label.props.text == "You can save 3 voice channels", "Full saved list is reported")

snapshot.connected = false
onOpen()
assert(find("save-vc").props.enabled == false, "Star needs a current VC")
assert(find("saved-123") ~= nil and find("saved-456") ~= nil, "Saved VCs remain joinable when idle")
assert(find("saved-123").props.enabled == true)

snapshot.plugin = { connected = false }
onOpen()
assert(find("saved-123").props.enabled == false, "Saved VCs are disabled while Vesktop is disconnected")

print("PASS: saved VC footer, counts, join, un-star, removal, limit error and idle state")
