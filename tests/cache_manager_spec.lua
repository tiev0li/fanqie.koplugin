-- 缓存管理：清单、当前章保护、部分删除、索引同步、离线模式。
local root = (arg and arg[1]) or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

-- 内存文件系统
local FS = {}
local function mkfile(path, size) FS[path] = { size = size or 100, mode = "file" } end
local function mkdir(path) FS[path] = { mode = "directory" } end
local function rm(path) FS[path] = nil end
local real_remove = os.remove
os.remove = function(path) if FS[path] then FS[path] = nil; return true end return real_remove(path) end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, key)
            local e = FS[path]
            if not e then return nil end
            if key == "size" then return e.size end
            if key == "mode" then return e.mode end
            if key == "modification" then return 1000 end
            return e
        end,
        dir = function(path)
            if not FS[path] or FS[path].mode ~= "directory" then error("no dir") end
            local entries = {}
            for p in pairs(FS) do
                local parent, name = p:match("^(.*)/([^/]+)$")
                if parent == path and name then entries[#entries + 1] = name end
            end
            local i = 0
            return function() i = i + 1; return entries[i] end
        end,
        rmdir = function(path) if FS[path] then FS[path] = nil end end,
    }
end
package.preload.util = function() return { makePath = function() end } end
package.preload.datastorage = function() return { getFullDataDir = function() return "/data" end } end
package.preload["ffi/util"] = function() return { template = function(f) return f end } end
package.preload.gettext = function() return function(t) return t end end
package.preload.json = function() return dofile(root .. "/tests/json_stub.lua") end
package.preload["fanqie.logger"] = function() return {} end
package.preload["fanqie.content"] = function()
    return {
        book_cache_dir = function(_, book_id) return "/cache/" .. book_id end,
        load_cache_index = function() return {} end,
        save_cache_index = function() end,
        load_catalog_cache = function() return {} end,
    }
end

local H = require("fanqie.helper")
H.make_dir = function() return true end
H.dir_exists = function(p) return FS[p] ~= nil and FS[p].mode == "directory" end
H.file_exists = function(p) return FS[p] ~= nil and FS[p].mode == "file" end
H.delete_dir = function(p) FS[p] = nil; return true end
H.join_path = function(a, b) return a .. "/" .. b end

-- 当前章保护：正在读 chapter_a.html
local State = { is_downloading = false, current_document_path = "/cache/111/chapter_a.html" }
package.preload["fanqie.runtime"] = function() return { state = State, } end
-- book_id_from_path 需要
State.book_id_from_path = function(p) return p:match("/cache/([^/]+)/") end
local CacheManager = require("fanqie.cache_manager")
local failures = 0
local function check(v, m) if not v then failures = failures + 1; io.stderr:write("FAIL: ", m, "\n") end end

-- 搭建：两本书，各 2 章 html + 图片
mkdir("/cache"); mkdir("/cache/111"); mkdir("/cache/222")
mkfile("/cache/111/chapter_a.html", 1000); mkfile("/cache/111/chapter_b.html", 2000)
mkfile("/cache/111/img1.jpg", 500); mkfile("/cache/111/cache_index.lua", 50)
mkfile("/cache/222/chapter_c.html", 300)
-- covers 等非书目录
mkdir("/cache/covers"); mkfile("/cache/covers/x.jpg", 10)

local settings = { get_download_dir = function() return "/cache" end }
local inv = CacheManager.inventory(settings)
check(#inv == 2, "inventory finds 2 books, skips covers")
local b111
for _, e in ipairs(inv) do if e.book_id == "111" then b111 = e end end
check(b111 and b111.chapters == 2, "chapter count correct")
check(b111 and b111.bytes == 3550, "bytes include html+images+index")
check(b111 and b111.images == 1, "non-html non-lua counted as image")

local plugin = { settings = settings, library = nil }
local ok, files = CacheManager.clear_book(plugin, "111", "all")
check(ok, "clear all succeeds")
check(FS["/cache/111/chapter_a.html"] ~= nil, "current chapter protected from delete")
check(FS["/cache/111/chapter_b.html"] == nil, "other chapter deleted")
check(FS["/cache/111/img1.jpg"] == nil, "images deleted")

-- 下载中拒绝
State.is_downloading = true
local ok2, _, _, err = CacheManager.clear_book(plugin, "222", "all")
check(ok2 == false and err ~= nil, "downloading blocks clear")
State.is_downloading = false

-- images 模式保留 html 与 lua
mkdir("/cache/333"); mkfile("/cache/333/chapter_z.html", 100); mkfile("/cache/333/pic.png", 900); mkfile("/cache/333/catalog_cache.lua", 20)
CacheManager.clear_book(plugin, "333", "images")
check(FS["/cache/333/chapter_z.html"] ~= nil, "images mode keeps html")
check(FS["/cache/333/catalog_cache.lua"] ~= nil, "images mode keeps lua")
check(FS["/cache/333/pic.png"] == nil, "images mode removes image")

-- read 模式：无已读章时报错
local lib_stub = { get = function() return { position = { chapter_index = 1 } } end,
    cache_observation = function() end }
plugin.library = lib_stub
local ok3, _, _, err3 = CacheManager.clear_book(plugin, "333", "read")
check(ok3 == false and err3 ~= nil, "read mode with no read chapters errors")

if failures > 0 then os.exit(1) end
print("Cache manager: OK")
