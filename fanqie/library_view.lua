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

return M
