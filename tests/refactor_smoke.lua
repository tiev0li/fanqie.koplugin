-- Load the real plugin and every action module with KOReader boundaries stubbed.
-- Run from the repository root with: luajit tests/refactor_smoke.lua .
local root = (arg and arg[1]) or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local modules = {}
local function module(name, value)
    value = value or {}
    modules[name] = value
    package.preload[name] = function() return value end
    return value
end

local Widget = {}
Widget.__index = Widget
function Widget:extend(fields)
    local child = fields or {}
    child.__index = child
    return setmetatable(child, { __index = self })
end
function Widget:new(fields)
    local object = setmetatable(fields or {}, { __index = self })
    if object.init then object:init() end
    return object
end
local function widget(name)
    return module(name, setmetatable({}, { __index = Widget }))
end

module("ui/widget/container/widgetcontainer", Widget)
for _, name in ipairs({
    "ui/widget/infomessage", "ui/widget/confirmbox", "ui/widget/inputdialog",
    "ui/widget/multiinputdialog", "ui/widget/menu", "ui/widget/textviewer",
    "ui/widget/imageviewer", "ui/widget/pathchooser",
}) do widget(name) end
module("ui/uimanager", {
    _window_stack = {},
    show = function() end, close = function() end, forceRePaint = function() end,
    scheduleIn = function() end, nextTick = function() end, setDirty = function() end,
})
module("libs/libkoreader-lfs", { attributes = function() return nil end })
module("dispatcher", { registerAction = function() end })
module("datastorage", { getFullDataDir = function() return "/tmp/fanqie-test" end })
module("ffi/util", {
    template = function(text, ...)
        local values = { ... }
        return (text:gsub("%%(%d+)", function(index) return tostring(values[tonumber(index)]) end))
    end,
    gettime = function() return 1 end,
})
module("util", { makePath = function() end })
module("device", { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } })
module("gettext", function(text) return text end)
module("logger", { err = function() end, info = function() end })
module("socket", { gettime = function() return 12.5 end })
module("ui/event", { new = function(_, name) return { name = name } end })
module("ui/gesturerange", {})
module("json", { encode = function() return "{}" end, decode = function() return {} end })
-- These optional KOReader integrations are not exercised by this structural test.
-- Stub them so safe_require cannot silently hide a missing action dependency.
module("fanqie.settings", { new = function() return {} end })
module("fanqie.comment_view", Widget)
module("fanqie.client", {})
module("fanqie.store_ui", {})
module("fanqie.updater_ui", {})
module("fanqie.download_progress", {})

local failures = 0
local function check(condition, message)
    if not condition then
        failures = failures + 1
        io.stderr:write("FAIL: ", message, "\n")
    end
end

local ok, Plugin = pcall(require, "main")
check(ok, "main.lua loads: " .. tostring(Plugin))
if not ok then os.exit(1) end

local expected = {}
for name in io.lines(root .. "/tests/expected_methods.txt") do
    if name ~= "" then expected[#expected + 1] = name end
end
for _, name in ipairs(expected) do
    check(type(Plugin[name]) == "function", "missing plugin method " .. name)
end
check(type(Plugin.PROGRESS_UPLOAD_PRESETS) == "table", "progress presets remain on plugin class")

local Runtime = require("fanqie.runtime")
check(Plugin.getPluginPath and Plugin.getPluginPath({}) == root, "plugin root survives extraction")
check(Runtime.now_seconds() == 12.5, "wall clock helper")
check(Runtime.getCurrentChapterIndex() == 0, "missing chapter index keeps zero sentinel")
check(#Runtime.log_error(string.rep("x", 600)) == 503, "log errors remain truncated")
check(Runtime.display_error({ auth_expired = true }):find("登录已过期", 1, true) ~= nil,
    "authentication error display remains specific")
local book = { book_id = "123" }
check(#Runtime.getCachedChapters({ settings = { cache_dir = "/tmp/fanqie-test" } }, book) == 0, "empty cache remains usable")

for name in pairs(package.loaded) do
    if name:match("^fanqie%..*_actions$") then
        check(type(package.loaded[name]) == "table", name .. " returns a module")
    end
end

if failures > 0 then
    io.stderr:write(tostring(failures), " smoke checks failed\n")
    os.exit(1)
end
print("Refactor smoke: OK (" .. tostring(#expected) .. " original methods mounted)")
