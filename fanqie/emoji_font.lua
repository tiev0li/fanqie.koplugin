-- 给现有 KOReader 字体追加 emoji 回退，不改变正文字体、字号或仿粗。
-- 字体构造方式参考 seaneasysaid/fanqie.koplugin-fixed 的 review_popup/face_factory.lua；
-- 这里只保留评论视图所需的一小段适配，不替换 KOReader 的默认回退链。

local ok_freetype, Freetype = pcall(require, "ffi/freetype")
local H = require("fanqie.helper")

local M = { path = nil, checked = false, cache = {} }

local function font_path()
    if M.checked then return M.path end
    M.checked = true
    local source = debug.getinfo(1, "S").source
    local this_file = type(source) == "string" and source:match("^@(.*)$")
    local dir = this_file and this_file:match("^(.*)/[^/]+$")
    local candidates = {}
    if dir then candidates[#candidates + 1] = dir .. "/../fonts/NotoEmoji-Regular.ttf" end
    candidates[#candidates + 1] = "plugins/fanqie.koplugin/fonts/NotoEmoji-Regular.ttf"
    if H.get_data_dir then
        candidates[#candidates + 1] = H.get_data_dir():gsub("/fanqie$", "")
            .. "/plugins/fanqie.koplugin/fonts/NotoEmoji-Regular.ttf"
    end
    for _i, path in ipairs(candidates) do
        if H.file_exists(path) then M.path = path break end
    end
    return M.path
end

local function make_face(path, size)
    local ok, ftsize = pcall(Freetype.newFaceSize, path, size)
    if not ok or not ftsize then return nil end
    local face = {
        orig_font = path,
        realname = path,
        size = size,
        orig_size = size,
        ftsize = ftsize,
        hash = path .. "|" .. tostring(size),
        hb_features = { "+kern", "+liga" },
        fallbacks = {},
    }
    face.getFallbackFont = function(num)
        if not num or num == 0 then return face end
        return face.fallbacks[num] or false
    end
    return face
end

--- 返回追加了 emoji 的字体副本；字体或 FreeType 不可用时返回原 face。
function M.with_fallback(face)
    if type(face) ~= "table" or not face.ftsize or not ok_freetype then return face end
    local path = font_path()
    if not path then return face end
    local key = tostring(face.hash or face.orig_font or "") .. "|" .. tostring(face.size)
    if M.cache[key] then return M.cache[key].clone end

    local clone = {}
    for k, v in pairs(face) do clone[k] = v end
    local original_fallback = face.getFallbackFont
    local original_fallbacks = face.fallbacks
    local emoji = make_face(path, face.size)
    if not emoji then return face end
    clone.hash = key .. "|notoemoji"
    clone.fallbacks = {}
    local cache = M.cache[key]
    cache = { clone = clone, emoji = emoji, next_index = 1, done = false }
    M.cache[key] = cache
    clone.getFallbackFont = function(num)
        if not num or num == 0 then return clone end
        if clone.fallbacks[num] ~= nil then return clone.fallbacks[num] end
        if cache.done or num > 15 then
            clone.fallbacks[num] = false
            return false
        end
        local fallback
        if type(original_fallback) == "function" then
            local ok, value = pcall(original_fallback, num)
            if ok then fallback = value end
        elseif type(original_fallbacks) == "table" then
            fallback = original_fallbacks[num]
        end
        if fallback then
            clone.fallbacks[num] = fallback
            return fallback
        end
        -- 原默认链结束后才放 emoji；xtext 最多使用 16 个字体（含主字体）。
        cache.emoji_index = cache.emoji_index or num
        if num == cache.emoji_index then
            clone.fallbacks[num] = emoji
            return emoji
        end
        cache.done = true
        clone.fallbacks[num] = false
        return false
    end
    return clone
end

return M
