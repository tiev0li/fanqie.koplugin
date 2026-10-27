-- 目录搜索与返回位置：字面匹配、空结果、大目录、单层返回栈。
local root = (arg and arg[1]) or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local State = { current_book = nil, current_chapters = nil, active_menu = nil }
package.preload["fanqie.runtime"] = function() return { state = State } end
package.preload["ui/uimanager"] = function()
    return { close = function() end, show = function(_, w) State.shown = w end,
        scheduleIn = function() end }
end
package.preload["ui/widget/infomessage"] = function() return setmetatable({}, { __index = { new = function(_, t) return t end } }) end
package.preload["ui/widget/inputdialog"] = function() return setmetatable({}, { __index = { new = function(_, t) return t end } }) end
package.preload["ui/widget/menu"] = function() return setmetatable({}, { __index = { new = function(_, t) return t end } }) end
package.preload["ui/event"] = function() return { new = function() return {} end } end
package.preload["fanqie.content"] = function() return {} end
package.preload["fanqie.helper"] = function() return { trim = function(s) return (s or ""):match("^%s*(.-)%s*$") or "" end } end
package.preload["fanqie.logger"] = function() return {} end
package.preload["fanqie.async"] = function() return {} end
package.preload["gettext"] = function() return function(t) return t end end
package.preload["ffi/util"] = function() return { template = function(f, ...) return f end } end
package.preload["fanqie.reading_session"] = function()
    return { remember_return = function(_, p) State.return_pos = p end }
end

local M = dofile(root .. "/fanqie/chapters/chapter_actions.lua")
local failures = 0
local function check(v, m) if not v then failures = failures + 1; io.stderr:write("FAIL: ", m, "\n") end end

-- 1500 章大目录
local chapters = {}
for i = 1, 1500 do chapters[i] = { itemId = tostring(i), title = "第" .. i .. "章 测试" .. (i % 7 == 0 and "特殊" or "") } end
local book = { book_id = "1", title = "书" }

M.showChapterSearchResults(M, book, chapters, "特殊")
check(State.shown and #State.shown.item_table == 214, "large catalog literal search finds 214")
check(State.shown.item_table[1].text:find("第7章", 1, true) ~= nil, "first match is chapter 7")
M.showChapterSearchResults(M, book, chapters, "不存在的章节")
check(State.shown == nil or State.shown.item_table == nil, "no results shows info not menu")
M.showChapterSearchResults(M, book, chapters, "TEST")
check(State.shown == nil or State.shown.item_table == nil, "case sensitive literal: no match for TEST")
M.showChapterSearchResults(M, book, chapters, "第1章")
check(State.shown and #State.shown.item_table >= 1, "prefix match works")
-- 结果项回指原章节对象：点击跳转用原索引
local item = State.shown.item_table[1]
local opened
M.openChapter = function(_, b, chs, idx) opened = idx end
item.callback()
check(opened == 1, "result item opens original chapter index")
if failures > 0 then os.exit(1) end
print("Catalog: OK")
