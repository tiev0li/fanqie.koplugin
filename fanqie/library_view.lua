-- 本地历史、追更、缓存与统计的统一轻量列表。
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InfoMessage = require("ui/widget/infomessage")
local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

local M = {}

function M.show_history(plugin)
    if not plugin.library then return end
    local records = plugin.library:recent(plugin.settings:get("history", {}).limit or 50)
    local items = {}
    for _, book in ipairs(records) do
        local p = book.position
        items[#items + 1] = {
            text = string.format("%s\n第 %s 章 · 第 %s 页", book.title or book.book_id,
                p.chapter_index or "?", p.page or "?"),
            callback = function()
                plugin:openBook({ book_id = book.book_id, title = book.title,
                    author = book.author, item_id = p.item_id })
            end,
        }
    end
    if #items == 0 then
        UIManager:show(InfoMessage:new{ text = _("还没有阅读记录"), timeout = 2 })
        return
    end
    UIManager:show(Menu:new{ title = _("最近阅读"), item_table = items,
        is_borderless = true, is_popout = false })
end

-- 阅读统计：本章/全书进度、剩余页、预计时间、按书时长。
-- 未知数据显示「未知」，绝不产生 >100% 或伪造估算。
function M.show_reading_stats(plugin)
    local PS = require("fanqie.progress_stats")
    local State = require("fanqie.runtime").state
    local book = State.current_book
    local chapters = State.current_chapters
    if not book then
        UIManager:show(InfoMessage:new{ text = _("无书籍信息"), timeout = 2 })
        return
    end
    local lines = {}
    lines[#lines + 1] = string.format("《%s》", book.title or book.book_id)
    lines[#lines + 1] = ""

    -- 本章
    local page = plugin.ui and plugin.ui.state and plugin.ui.state.page
    local total_pages = plugin.ui and plugin.ui.document
        and (plugin.ui.document.info and plugin.ui.document.info.number_of_pages
            or plugin.ui.document:getPageCount())
    local ch_idx = State.current_chapter_index
    local ch_pct = PS.chapter_percent(page, total_pages)
    local remain = PS.chapter_remaining(page, total_pages)
    lines[#lines + 1] = _("本章")
    if ch_idx and chapters then
        lines[#lines + 1] = string.format("  %s", _("第") .. " " .. ch_idx .. "/" .. #chapters .. " " .. _("章"))
    end
    if page and total_pages then
        lines[#lines + 1] = string.format("  %s：%s / %s", _("页"), page, total_pages)
    end
    lines[#lines + 1] = string.format("  %s：%s", _("章内进度"),
        ch_pct and (ch_pct .. "%") or _("未知"))
    lines[#lines + 1] = string.format("  %s：%s", _("剩余页"),
        remain ~= nil and tostring(remain) or _("未知"))
    -- 预计时间：用近期页耗时（这里用章内进度近似每页耗时不可得，样本不足显示未知）
    local est = PS.estimate_seconds(plugin._page_durations, remain)
    lines[#lines + 1] = string.format("  %s：%s", _("预计剩余时间"),
        est and string.format("%d %s", math.ceil(est / 60), _("分钟")) or _("暂无法估计"))
    lines[#lines + 1] = ""

    -- 全书
    local record = plugin.library and plugin.library:get(book.book_id)
    local total_chapters = chapters and #chapters
        or (record and record.catalog and record.catalog.total_chapters)
    local read_idx = ch_idx or (record and record.position and record.position.chapter_index)
    local ch_progress = (page and total_pages and total_pages > 0)
        and math.min(page / total_pages, 1) or nil
    local book_pct = PS.book_progress(read_idx, ch_progress, total_chapters)
    lines[#lines + 1] = _("全书")
    lines[#lines + 1] = string.format("  %s：%s", _("总章数"),
        total_chapters and tostring(total_chapters) or _("未知"))
    lines[#lines + 1] = string.format("  %s：%s", _("已读进度"),
        book_pct and (book_pct .. "%") or _("未知"))
    lines[#lines + 1] = string.format("  %s：%s", _("剩余未读"),
        (total_chapters and read_idx) and tostring(math.max(total_chapters - read_idx, 0)) .. " " .. _("章") or _("未知"))

    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

return M
