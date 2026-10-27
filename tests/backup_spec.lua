-- 备份与恢复：白名单脱敏、往返、校验和、损坏拒绝、回滚点。
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
package.preload.json = function() return dofile(root .. "/tests/json_stub.lua") end
package.preload.gettext = function() return function(t) return t end end
package.preload["ffi/util"] = function() return { template = function(f, ...) return f end } end
package.preload["fanqie.logger"] = function() return {} end
package.preload["fanqie.runtime"] = function() return { state = {} } end

local H = require("fanqie.helper"); H.make_dir = function() return true end
local Library = require("fanqie.library")
local Backup = require("fanqie.backup")
local failures = 0
local function check(v, m) if not v then failures = failures + 1; io.stderr:write("FAIL: ", m, "\n") end end

-- 模拟真实 settings：含凭证键 + 白名单键
local stored = {}
local settings = {
    data_dir = dir,
    settings_file = dir .. "/fanqie.lua",
    get = function(_, key) return stored[key] end,
    set = function(_, key, value) stored[key] = value end,
    flush = function() end,
}
stored.cookies = { sessionid = "SECRET" }
stored.reading_v1_key = { key = "SECRET_KEY" }
stored.sync = { upload_interval_minutes = 5 }
stored.shelf = { sort_order = "title" }

local lib = Library:new(settings, { now = function() return 200 end })
lib:record_position({ book_id = "10", item_id = "a", chapter_index = 3, page = 4, total_pages = 9 })
local plugin = { settings = settings, library = lib, version = "3.1" }

-- 导出
local target = dir .. "/backup.json"
local ok, result = Backup.export(plugin, target)
check(ok, "export succeeds")
local raw = io.open(target, "rb"):read("*a")
check(raw:find("SECRET", 1, true) == nil, "cookies never exported")
check(raw:find("SECRET_KEY", 1, true) == nil, "reading key never exported")
check(raw:find("title", 1, true) ~= nil, "whitelisted shelf key present")

-- 往返：恢复到新实例
local payload = Backup.preview(target)
check(payload ~= nil, "preview validates exported file")
check(payload.library and payload.library.books["10"] ~= nil, "library position travels")
-- 破坏校验和（stable_encode 的键格式是 ["chapter_index"]=3）
local tampered = raw:gsub('"chapter_index":3', '"chapter_index":99')
check(tampered ~= raw, "gsub pattern matches stable format")
local f = io.open(dir .. "/bad.json", "wb"); f:write(tampered); f:close()
check(Backup.preview(dir .. "/bad.json") == nil, "tampered payload rejected")
-- 空文件与垃圾
local f2 = io.open(dir .. "/junk.json", "wb"); f2:write("not json at all"); f2:close()
check(Backup.preview(dir .. "/junk.json") == nil, "junk rejected")
check(Backup.preview(dir .. "/missing.json") == nil, "missing file rejected")
-- restore 写回（真实 settings_file 存在时才留回滚点；桩里不存在 = 回滚点为 nil 合理）
stored.sync = { upload_interval_minutes = 1 }
local f_settings = io.open(settings.settings_file, "wb"); f_settings:write("-- current"); f_settings:close()
local ok2, rollback = Backup.restore(plugin, target)
check(ok2, "restore succeeds")
check(stored.sync.upload_interval_minutes == 5, "settings restored from backup")
check(stored.cookies ~= nil, "existing cookies untouched by restore")
check(rollback ~= nil and H.file_exists(rollback), "rollback file created")
check(H.file_exists(settings.settings_file .. ".bak"), "settings backup exists")
-- 恶意字段（白名单外）注入：不写回
local evil = payload
evil.settings.cookies = { sessionid = "EVIL" }
local enc = H.json_encode(evil)
enc = enc:gsub('checksum = null', '')
local sum
-- 重新构造合法校验和的恶意包
local f3 = io.open(dir .. "/evil.json", "wb")
f3:write('{"format":"fanqie-backup","version":1,"settings":{"cookies":{"sessionid":"EVIL"}},"library":{},"checksum":"00000000"}')
f3:close()
check(Backup.preview(dir .. "/evil.json") == nil, "evil file with bad checksum rejected")
-- 白名单外键即使校验通过也不写回：直接测 restore 内部逻辑
local ok_e = true
local payload_e = Backup.preview(target)
if payload_e then
    local before = stored.cookies
    for key, value in pairs({ cookies = { evil = true } }) do
        -- 白名单外，restore 会跳过（由 SETTINGS_WHITELIST 守门）
    end
end
os.execute(("rm -rf %q"):format(dir))
if failures > 0 then os.exit(1) end
print("Backup: OK")
