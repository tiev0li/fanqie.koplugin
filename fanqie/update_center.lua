-- 追更中心：串行检查书架各书目录变化，快照进本地资料库。
-- 首轮只建基线；失败/空响应保留上次快照，不清数据。
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end
local Content = require("fanqie.content")
local Async = require("fanqie.async")
local Log = require("fanqie.logger")
local Runtime = require("fanqie.runtime")
local _state = Runtime.state

local M = {}

--- 检查一本书的目录变化（同步，子进程内调用）。
-- @return table|nil 更新状态（library.update_state 口径）
function M.check_book(plugin, book)
    local book_id = book.book_id or book.bookId
    if not book_id then return nil end
    local b = { book_id = book_id }
    local ok, chapters = pcall(Content.fetch_catalog, plugin.client, b)
    if not ok or type(chapters) ~= "table" or #chapters == 0 then
        if Log and Log.warn then Log.warn("update_center: catalog empty/failed for", tostring(book_id)) end
        return nil
    end
    plugin.library:catalog_observation(book_id, chapters, book.status)
    return plugin.library:update_state(book_id, #chapters)
end

--- 串行检查整个书架。UI 线程只轮询，不阻塞。
-- @param books table 书架记录列表
-- @param on_done function(ok, results) results: book_id -> update_state
function M.refresh(plugin, books, on_done)
    if not (plugin.library and books and #books > 0) then
        if on_done then on_done(false, {}) end
        return
    end
    local updates = plugin.settings:get("updates", {})
    if updates.enabled == false then
        if on_done then on_done(false, {}) end
        return
    end
    local results = {}
    local UIManager = require("ui/uimanager")
    local function process_next(i)
        if i > #books then
            if on_done then on_done(true, results) end
            return
        end
        local book = books[i]
        Async.run(function()
            return M.check_book(plugin, book)
        end, function(ok, result)
            if ok and type(result) == "table" then
                results[tostring(book.book_id or book.bookId)] = result
            end
            UIManager:scheduleIn(0, function() process_next(i + 1) end)
        end, { poll_interval = 0.3, timeout = 60, tag = "update_center" })
    end
    process_next(1)
end

--- 书架徽标：把资料库里的更新状态合并进书架记录（只加字段，不改原字段）。
function M.decorate(books, library)
    if not library then return books end
    for _, book in ipairs(books or {}) do
        local state = library:update_state(book.book_id or book.bookId)
        if state then
            book.update_unread = state.unread_count
            book.update_new = state.new_count
        end
    end
    return books
end

--- 下载全部更新：逐书串行，复用 Download.execute 的节流/跳过/取消。
function M.download_updates(plugin, books)
    local Download = require("fanqie.download")
    local queue = {}
    for _, book in ipairs(books or {}) do
        local state = plugin.library:update_state(book.book_id or book.bookId)
        if state and state.new_count > 0 then queue[#queue + 1] = book end
    end
    if #queue == 0 then
        plugin:showInfo(_("没有需要下载的更新"))
        return
    end
    local function next_book(i)
        if i > #queue then return end
        local book = queue[i]
        local chapters = Content.load_catalog_cache(plugin.settings, book.book_id)
        if not chapters or #chapters == 0 then
            next_book(i + 1)
            return
        end
        local state = plugin.library:update_state(book.book_id)
        local start = math.max(#chapters - (state and state.new_count or 0) + 1, 1)
        Download.execute(plugin, book, chapters, start, #chapters)
    end
    next_book(1)
end

return M
