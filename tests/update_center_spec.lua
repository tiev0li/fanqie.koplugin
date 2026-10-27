-- 追更中心：基线、尾部新增、空响应保留快照、未读计数、下载队列。
local root = (arg and arg[1]) or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local dir = os.tmpname(); os.remove(dir)
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
        for k, x in pairs(v) do a[#a + 1] = "[" .. serialize(k) .. "]=" .. serialize(x) end
        return "{" .. table.concat(a, ",") .. "}"
    end
    return { encode = serialize, decode = function(s) return assert(loadstring("return " .. s))() end }
end
package.preload["fanqie.content"] = function() return { fetch_catalog = function() return nil end,
    load_catalog_cache = function() return nil end } end
package.preload["fanqie.async"] = function() return { run = function() end } end
package.preload["fanqie.logger"] = function() return {} end
package.preload["fanqie.runtime"] = function() return { state = {} } end
package.preload["ui/uimanager"] = function() return { scheduleIn = function() end } end
package.preload["gettext"] = function() return function(t) return t end end

local H = require("fanqie.helper"); H.make_dir = function() return true end
local Library = require("fanqie.library")
local UpdateCenter = require("fanqie.update_center")
local failures = 0
local function check(v, m) if not v then failures = failures + 1; io.stderr:write("FAIL: ", m, "\n") end end

local lib = Library:new({ data_dir = dir }, { now = function() return 100 end })
local chapters5 = { { itemId = "1" }, { itemId = "2" }, { itemId = "3" }, { itemId = "4" }, { itemId = "5" } }
lib:record_position({ book_id = "10", item_id = "3", chapter_index = 3 })
lib:catalog_observation("10", chapters5)
local state = lib:update_state("10")
check(state.unread_count == 2, "unread = total - read")
check(state.new_count == 0, "first observation is baseline, not all-new")
lib:mark_seen("10")
local chapters6 = { { itemId = "1" }, { itemId = "2" }, { itemId = "3" }, { itemId = "4" }, { itemId = "5" }, { itemId = "6" } }
lib:catalog_observation("10", chapters6)
state = lib:update_state("10")
check(state.new_count == 1, "tail append detected as one new chapter")
check(state.total_chapters == 6, "total chapters updated")
-- 空响应：catalog_observation 拒绝空表，旧快照保留
check(lib:catalog_observation("10", {}) == false, "empty catalog rejected")
check(lib:update_state("10").total_chapters == 6, "old snapshot survives empty response")
-- 目录前缀变化但 seen 仍在新目录里：按「seen 之后的章数」计（可能低估，安全方向）
lib:mark_seen("10")
local reordered = { { itemId = "X" }, { itemId = "1" }, { itemId = "2" }, { itemId = "3" }, { itemId = "4" }, { itemId = "5" }, { itemId = "6" } }
lib:catalog_observation("10", reordered)
check(lib:update_state("10").new_count == 0, "seen still present: count chapters after it")
-- seen 在新目录里找不到（章节全换）：保守地全部算新
lib:record_position({ book_id = "20", item_id = "a", chapter_index = 1 })
lib:catalog_observation("20", { { itemId = "a" }, { itemId = "b" } })
lib:mark_seen("20")
lib:catalog_observation("20", { { itemId = "p" }, { itemId = "q" }, { itemId = "r" } })
check(lib:update_state("20").new_count == 3, "seen missing: all chapters counted new")
-- decorate 只加字段
local books = { { book_id = "20", title = "书" } }
UpdateCenter.decorate(books, lib)
check(books[1].update_new == 3 and books[1].title == "书", "decorate adds fields without clobbering")
-- check_book：fetch_catalog 失败返回 nil，不清快照
local plugin = { client = {}, library = lib, settings = { get = function() return {} end } }
check(UpdateCenter.check_book(plugin, { book_id = "10" }) == nil, "failed fetch returns nil")
check(lib:update_state("10") ~= nil, "snapshot still present after failed fetch")
-- download_updates：无更新时提示
local infos = {}
plugin.showInfo = function(_, t) infos[#infos + 1] = t end
package.preload["fanqie.download"] = function() return { execute = function() end } end
lib:mark_seen("20")
UpdateCenter.download_updates(plugin, books)
check(#infos == 1 and infos[1]:find("没有需要下载的更新", 1, true) ~= nil, "no updates shows info")
-- check_due：节流闸门（last_auto_check_at 与 os.time() 同口径）
local updates_state = { enabled = true, interval_minutes = 60, last_auto_check_at = 0 }
local settings2 = { get = function(_, key) return key == "updates" and updates_state or {} end,
    set = function(_, key, v) updates_state = v end, flush = function() end,
    is_offline_mode = function() return false end }
check(UpdateCenter.check_due(settings2) == true, "never checked: due")
updates_state.last_auto_check_at = os.time() - 30
check(UpdateCenter.check_due(settings2) == false, "checked 30s ago: not due")
updates_state.enabled = false
check(UpdateCenter.check_due(settings2) == false, "disabled: not due")
updates_state.enabled = true
updates_state.interval_minutes = 0
check(UpdateCenter.check_due(settings2) == false, "zero interval: not due")
-- auto_update：离线模式 / 未到间隔 / 断网时静默跳过（不打任何请求）
local requested = 0
package.preload["fanqie.content"] = function()
    return { fetch_catalog = function() requested = requested + 1; return nil end,
        load_catalog_cache = function() return nil end }
end
package.preload["ui/network/manager"] = function()
    return { isOnline = function() return false end }
end
local plugin2 = { library = lib, settings = settings2, client = {} }
updates_state.interval_minutes = 60
updates_state.last_auto_check_at = 0
UpdateCenter.auto_update(plugin2, { { book_id = "10" } })
check(requested == 0, "offline network: auto update silently skipped")
settings2.is_offline_mode = function() return true end
package.preload["ui/network/manager"] = function()
    return { isOnline = function() return true end }
end
UpdateCenter.auto_update(plugin2, { { book_id = "10" } })
check(requested == 0, "offline mode: auto update silently skipped")
-- auto_candidates：按最近阅读优先，限制 auto_limit
local many = {}
for i = 1, 50 do many[i] = { book_id = tostring(100 + i), read_timestamp = i } end
local lib3 = { get = function(_, id) return { position = { updated_at = tonumber(id) - 100 } } end }
local plugin3 = { library = lib3, settings = { get = function(_, key)
    return key == "updates" and { auto_limit = 5 } or {} end } }
local cand = UpdateCenter.auto_candidates(plugin3, many)
check(#cand == 5, "auto candidates limited to auto_limit")
check(cand[1].book_id == "150", "most recently read first")
check(cand[5].book_id == "146", "ordered by recency")
local plugin4 = { library = lib3, settings = { get = function(_, key)
    return key == "updates" and { auto_limit = 0 } or {} end } }
check(#UpdateCenter.auto_candidates(plugin4, many) == 50, "auto_limit 0 means all books")
local plugin5 = { library = lib3, settings = { get = function(_, key)
    return key == "updates" and { auto_limit = 999 } or {} end } }
check(#UpdateCenter.auto_candidates(plugin5, many) == 50, "limit beyond shelf means all")

-- 通知：未开系统通知时不发（返回 false）
check(UpdateCenter.notify(plugin2, "x") == false, "notifications off: not sent")
-- 系统通知能力探测：测试环境没有 KOReader Notification ⇒ false
check(UpdateCenter.notifications_available() == false, "no Notification module: unavailable")
os.execute(("rm -rf %q"):format(dir))
if failures > 0 then os.exit(1) end
print("Update center: OK")
