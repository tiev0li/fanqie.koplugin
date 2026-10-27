local root = (arg and arg[1]) or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local State = { current_book = { book_id = "10", title = "书" }, current_chapters = {
    { itemId = "100" }, { itemId = "200" },
}, current_chapter_index = 1 }
package.preload["fanqie.runtime"] = function() return { state = State } end
package.preload["ui/uimanager"] = function() return { nextTick = function(_, f) f() end } end
local Session = require("fanqie.reading_session")
local failures = 0
local function check(v, m) if not v then failures = failures + 1; io.stderr:write("FAIL: ", m, "\n") end end
local plugin = { ui = { document = { info = { number_of_pages = 20 } }, state = { page = 8 },
    updatePage = function(self) State.updated = self.state.page end },
    _currentDocChapterItemId = function() return "100" end,
    _chapterIndexByItemId = function(_, chapters, id)
        for i, c in ipairs(chapters) do if c.itemId == id then return i end end
    end,
    library = { record_position = function(_, p) State.saved = p end,
        get = function() return { position = { item_id = "100", chapter_index = 1, page = 8 } } end },
    updatePage = function(self) State.updated = self.ui.state.page end,
}
Session.record(plugin)
check(State.saved.page == 8 and State.saved.item_id == "100", "page captured by old document item")
State.current_chapter_index = 2
Session.restore(plugin)
check(State.updated == nil, "does not restore page on another chapter")
State.current_chapter_index = 1
Session.restore(plugin)
check(State.updated == 8, "restores after ready for same item")
local conflict = Session.conflict({ item_id = "100", chapter_index = 1, page = 8 },
    { item_id = "200", chapter_index = 2, page = 3 })
check(conflict ~= nil, "different chapter conflicts")
check(Session.conflict({ item_id = "100", page = 8 }, { item_id = "100", page = 8 }) == nil,
    "same position does not conflict")
check(Session.conflict({ item_id = "100", page = 8 }, { item_id = "100", page = 9 }) ~= nil,
    "same chapter different page conflicts")
check(Session.conflict({ item_id = "100", page = 8 }, { item_id = "100" }) == nil,
    "unknown cloud page keeps chapter-only semantics")
Session.remember_return(plugin)
State.current_chapter_index = 2
plugin.navigateToChapter = function(_, book, chapters, index, opts)
    check(index == 1, "return uses original item")
    State.current_chapter_index = index
    opts.after_navigate()
    return true
end
check(Session.return_back(plugin), "returns to original location")
check(State.updated == 8, "return restores page")
check(Session.return_back(plugin) == false, "return stack is single use")
State.return_position = { book_id = "other", item_id = "100", page = 1 }
check(Session.return_back(plugin) == false, "does not return across books")

-- cloud_position：形参曾遮蔽同名函数（真机 "attempt to call local 'item_id'"）
local chapters = { { itemId = "100" }, { itemId = "200" } }
local cp = Session.cloud_position("10", "200", chapters, { page = 3, total_pages = 10 }, 123)
check(cp ~= nil, "cloud_position resolves item")
check(cp.chapter_index == 2 and cp.item_id == "200", "cloud item index resolved")
check(cp.page == 3, "cloud page mapped")
check(Session.cloud_position("10", "999", chapters, {}, nil) == nil, "unknown cloud item -> nil")
check(Session.cloud_position("10", nil, chapters, {}, nil) == nil, "nil item -> nil")
if failures > 0 then os.exit(1) end
print("Reading session: OK")
