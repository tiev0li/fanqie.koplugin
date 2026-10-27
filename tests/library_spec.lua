local root = (arg and arg[1]) or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local dir = os.tmpname()
os.remove(dir)
assert(os.execute(("mkdir -p %q"):format(dir)) == 0)
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path, key)
        local f = io.open(path, "rb")
        if f then f:close(); return key == "size" and 1 or "file" end
        return nil
    end }
end
package.preload.util = function() return { makePath = function() end } end
package.preload.datastorage = function() return { getFullDataDir = function() return dir end } end

package.preload.json = function()
    local function serialize(v)
        if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
        if type(v) == "string" then return string.format("%q", v) end
        local a = {}
        for k, x in pairs(v) do
            a[#a + 1] = "[" .. serialize(k) .. "]=" .. serialize(x)
        end
        return "{" .. table.concat(a, ",") .. "}"
    end
    return { encode = serialize, decode = function(s)
        local f = assert(loadstring("return " .. s)); return f()
    end }
end
local H = require("fanqie.helper")
H.make_dir = function() return true end
local Library = require("fanqie.library")
local failures = 0
local function check(value, message)
    if not value then failures = failures + 1; io.stderr:write("FAIL: ", message, "\n") end
end

local clock = 100
local settings = { data_dir = dir }
local lib = Library:new(settings, { now = function() return clock end })
check(lib:record_position({ book_id = "1234567890123456789", item_id = "9876543210987654321",
    chapter_index = 4, page = 7, total_pages = 10, chapter_progress = 0.7, title = "测试" }), "record precise ID")
local saved = lib:get("1234567890123456789")
check(saved.position.item_id == "9876543210987654321", "19 digit ID is preserved")
check(#lib:recent() == 1, "recent deduplicates by book")
lib:record_position({ book_id = "1234567890123456789", item_id = "9876543210987654321", page = 3, updated_at = 1 })
check(lib:get("1234567890123456789").position.page == 7, "older callback cannot overwrite page")
check(lib:catalog_observation("1234567890123456789", {
    { itemId = "1" }, { itemId = "2" }, { itemId = "3" }, { itemId = "4" }, { itemId = "5" },
}), "catalog snapshot")
check(lib:update_state("1234567890123456789").unread_count == 1, "unread count")
check(lib:update_state("1234567890123456789").new_count == 0, "first observation is baseline")
lib:mark_seen("1234567890123456789")
lib:catalog_observation("1234567890123456789", {
    { itemId = "1" }, { itemId = "2" }, { itemId = "3" }, { itemId = "4" }, { itemId = "5" }, { itemId = "6" },
})
check(lib:update_state("1234567890123456789").new_count == 1, "tail update detected")
lib:cache_observation("1234567890123456789", 4, 12345)
check(lib:get("1234567890123456789").cache.bytes == 12345, "cache metadata")
assert(lib:flush())
local restored = Library:new(settings, { now = function() return clock end })
check(restored:get("1234567890123456789").position.page == 7, "restart restores position")
restored:migrate({ a = { book_id = "20", item_id = "30", chapter_idx = 8, timestamp = 10 } })
check(restored:get("20").position.chapter_index == 9, "pending migration is one based")
local corrupt = io.open(dir .. "/bad.json", "wb"); corrupt:write("not json"); corrupt:close()
local bad = Library:new(settings, { path = dir .. "/bad.json" })
check(bad:recent()[1] == nil, "corrupt data falls back without deleting content")
check(io.open(dir .. "/bad.json.corrupt", "rb") ~= nil, "corrupt source retained")
os.execute(("rm -rf %q"):format(dir))
if failures > 0 then os.exit(1) end
print("Library: OK")
