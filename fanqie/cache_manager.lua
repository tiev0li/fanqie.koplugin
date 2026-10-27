-- 按书缓存清单与保护性清理。清理永远避开当前打开章与活动下载，
-- 删除成功后才同步缓存索引与资料库统计；失败保留旧索引。
local lfs = require("libs/libkoreader-lfs")
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local H = require("fanqie.helper")
local Content = require("fanqie.content")
local Log = require("fanqie.logger")
local Runtime = require("fanqie.runtime")
local _state = Runtime.state

local M = {}

-- 与 settings.get_cache_stats 同口径：缓存根下不算书的子目录
local NON_BOOK_DIRS = { covers = true, store_covers = true, comment_images = true }

--- 逐书统计：字节、章节数（.html）、图片数、最后更新时间。
-- 遍历尽力而为，单项失败跳过不抛错（与 get_cache_stats 的容错口径一致）。
function M.inventory(settings)
    local out = {}
    local dir = settings:get_download_dir()
    local ok, iter, dir_obj = pcall(lfs.dir, dir)
    if not ok or type(iter) ~= "function" then return out end
    pcall(function()
        for entry in iter, dir_obj do
            if entry ~= "." and entry ~= ".." and not NON_BOOK_DIRS[entry] then
                local full = H.join_path(dir, entry)
                if lfs.attributes(full, "mode") == "directory" then
                    local bytes, chapters, images, latest = 0, 0, 0, 0
                    local ok2, it2, dh = pcall(lfs.dir, full)
                    if ok2 then
                        pcall(function()
                            for f in it2, dh do
                                if f ~= "." and f ~= ".." then
                                    local fp = H.join_path(full, f)
                                    if lfs.attributes(fp, "mode") == "file" then
                                        bytes = bytes + (lfs.attributes(fp, "size") or 0)
                                        local mt = lfs.attributes(fp, "modification") or 0
                                        if mt > latest then latest = mt end
                                        if f:match("%.html$") then chapters = chapters + 1
                                        elseif not f:match("%.lua$") and not f:match("^%._") then
                                            images = images + 1
                                        end
                                    end
                                end
                            end
                        end)
                    end
                    out[#out + 1] = {
                        book_id = entry, bytes = bytes, chapters = chapters,
                        images = images, updated_at = latest,
                    }
                end
            end
        end
    end)
    return out
end

--- 当前正在打开的章节文件（属于 book_id 时返回路径，否则 nil）。
local function current_chapter_path(settings, book_id)
    local path = _state.current_document_path
    if not path or type(_state.book_id_from_path) ~= "function" then return nil end
    if tostring(_state.book_id_from_path(path)) ~= tostring(book_id) then return nil end
    return path
end

--- 删除后同步缓存索引：把指向已不存在文件的条目去掉。
local function sync_index(settings, book_id)
    local index = Content.load_cache_index(settings, book_id) or {}
    local changed = false
    for item_id, path in pairs(index) do
        if not H.file_exists(path) then
            index[item_id] = nil
            changed = true
        end
    end
    if changed then Content.save_cache_index(settings, book_id, index) end
    return index
end

--- 清理一本书的缓存。
-- @param mode "all" 整本 | "images" 仅图片 | "read" 已读完章（当前章之前）
-- @return ok, removed_files, removed_bytes, err
function M.clear_book(plugin, book_id, mode)
    local settings = plugin.settings
    book_id = tostring(book_id)
    -- 活动下载保护：正在下载时不允许清理（下载器会边删边写）
    if _state.is_downloading then
        return false, 0, 0, _("正在下载中，请稍候再试")
    end
    local dir = Content.book_cache_dir(settings, book_id)
    if not H.dir_exists(dir) then return true, 0, 0 end
    local protect = current_chapter_path(settings, book_id)

    local removed_files, removed_bytes = 0, 0
    local function remove_file(fp)
        if fp == protect then return end
        local size = lfs.attributes(fp, "size") or 0
        if os.remove(fp) then
            removed_files = removed_files + 1
            removed_bytes = removed_bytes + size
        end
    end

    if mode == "all" then
        -- 整本：当前章也保护（用户正在读它）
        local ok, iter, dh = pcall(lfs.dir, dir)
        if not ok then return false, 0, 0, _("目录读取失败") end
        pcall(function()
            for f in iter, dh do
                if f ~= "." and f ~= ".." then
                    remove_file(H.join_path(dir, f))
                end
            end
        end)
        pcall(lfs.rmdir, dir)
    elseif mode == "images" then
        local ok, iter, dh = pcall(lfs.dir, dir)
        if not ok then return false, 0, 0, _("目录读取失败") end
        pcall(function()
            for f in iter, dh do
                if f ~= "." and f ~= ".." and not f:match("%.html$")
                        and not f:match("%.lua$") and not f:match("^%._") then
                    remove_file(H.join_path(dir, f))
                end
            end
        end)
    elseif mode == "read" then
        -- 已读完章：资料库位置之前的 .html（当前章由 protect 兜底）
        local record = plugin.library and plugin.library:get(book_id)
        local read_idx = record and record.position and record.position.chapter_index
        if not read_idx or read_idx < 2 then
            return false, 0, 0, _("没有可清理的已读章节")
        end
        local chapters = Content.load_catalog_cache(settings, book_id) or {}
        for i = 1, read_idx - 1 do
            local item_id = chapters[i] and tostring(chapters[i].itemId or chapters[i].item_id or "")
            if item_id ~= "" then
                remove_file(H.join_path(dir, "chapter_" .. item_id .. ".html"))
            end
        end
    else
        return false, 0, 0, _("未知清理模式")
    end

    -- 删除成功后才同步索引与资料库；失败时旧索引保留（指向的文件已不存在，
    -- 打开时会按「未缓存」重下，不会读到坏文件）
    local index = sync_index(settings, book_id)
    local chapters_now = 0
    for _ in pairs(index) do chapters_now = chapters_now + 1 end
    if plugin.library then
        pcall(plugin.library.cache_observation, plugin.library, book_id, chapters_now,
            M.book_bytes(settings, book_id))
    end
    if Log and Log.info then
        Log.info("[cache_manager] clear", book_id, mode, removed_files, "files", removed_bytes, "bytes")
    end
    return true, removed_files, removed_bytes
end

--- 单本书当前占用（删后重算用）。
function M.book_bytes(settings, book_id)
    local dir = Content.book_cache_dir(settings, book_id)
    local total = 0
    local ok, iter, dh = pcall(lfs.dir, dir)
    if not ok then return 0 end
    pcall(function()
        for f in iter, dh do
            if f ~= "." and f ~= ".." then
                total = total + (lfs.attributes(H.join_path(dir, f), "size") or 0)
            end
        end
    end)
    return total
end

return M
