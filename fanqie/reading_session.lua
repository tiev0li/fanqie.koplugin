-- 阅读会话：页级位置、冲突候选和一次性返回栈。不持有上传队列。
local Runtime = require("fanqie.runtime")
local State = Runtime.state
local UIManager = require("ui/uimanager")

local M = {}

local function item_id(chapter)
    return chapter and tostring(chapter.itemId or chapter.item_id or "") or nil
end

function M.current_position(plugin, force)
    local book = State.current_book
    local chapters = State.current_chapters
    if not book or not chapters or not (plugin.ui and plugin.ui.document) then return nil end
    local doc = plugin.ui.document
    local doc_item = plugin:_currentDocChapterItemId()
    local idx = doc_item and plugin:_chapterIndexByItemId(chapters, doc_item)
        or State.current_chapter_index
    local chapter = chapters[idx]
    if not chapter then return nil end
    local page = plugin.ui.state and plugin.ui.state.page or State.last_page_number or 1
    local total = doc.info and doc.info.number_of_pages or doc:getPageCount()
    return {
        book_id = book.book_id, item_id = item_id(chapter), chapter_index = idx,
        page = page, total_pages = total,
        chapter_progress = total and total > 0 and math.min(page / total, 1) or nil,
        title = book.title, author = book.author, force = force,
    }
end

function M.record(plugin, force)
    local position = M.current_position(plugin, force)
    if position and plugin.library then plugin.library:record_position(position) end
end

function M.restore(plugin)
    local book = State.current_book
    local record = book and plugin.library and plugin.library:get(book.book_id)
    local p = record and record.position
    local chapters = State.current_chapters
    if not p or not chapters then return end
    local idx = plugin:_chapterIndexByItemId(chapters, p.item_id)
    if idx ~= State.current_chapter_index or not p.page or p.page <= 1 then return end
    UIManager:nextTick(function()
        if plugin.ui and plugin.ui.state and plugin.ui.document
                and plugin:_currentDocChapterItemId() == p.item_id then
            local total = plugin.ui.document.info and plugin.ui.document.info.number_of_pages
            if not total or p.page <= total then plugin.ui.state.page = p.page; plugin.ui:updatePage() end
        end
    end)
end

--- 云端候选位置。
-- 🔴 形参不能叫 item_id：会遮蔽模块级 item_id(chapter) 函数（真机回归踩中，
--    报 "attempt to call local 'item_id' (a string value)"）。
function M.cloud_position(book_id, target_item_id, chapters, progress, timestamp)
    if not target_item_id then return nil end
    local idx
    local want = tostring(target_item_id)
    for i, chapter in ipairs(chapters or {}) do
        if item_id(chapter) == want then idx = i; break end
    end
    if not idx then return nil end
    local total = tonumber(progress and progress.total_pages)
    return {
        book_id = book_id, item_id = want, chapter_index = idx,
        page = tonumber(progress and (progress.page or progress.page_index)),
        total_pages = total,
        chapter_progress = tonumber(progress and (progress.read_progress or progress.progress)),
        updated_at = tonumber(timestamp),
    }
end

function M.conflict(local_position, cloud_position)
    if not local_position or not cloud_position then return nil end
    if tostring(local_position.item_id) ~= tostring(cloud_position.item_id) then
        return { local_position = local_position, cloud_position = cloud_position }
    end
    if local_position.page and cloud_position.page
            and local_position.page ~= cloud_position.page then
        return { local_position = local_position, cloud_position = cloud_position }
    end
    return nil
end

function M.remember_return(plugin)
    local p = M.current_position(plugin)
    if p then State.return_position = p end
end

function M.return_back(plugin)
    local p = State.return_position
    local book = State.current_book
    local chapters = State.current_chapters
    State.return_position = nil
    if not p or not book or not chapters or tostring(book.book_id) ~= tostring(p.book_id) then
        return false
    end
    local idx = plugin:_chapterIndexByItemId(chapters, p.item_id)
    if not idx then return false end
    State.restore_page = p.page
    return plugin:navigateToChapter(book, chapters, idx, {
        after_navigate = function() M.restore(plugin) end,
    })
end

return M
