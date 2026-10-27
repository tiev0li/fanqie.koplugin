-- 本地资料库：阅读位置、追更快照与缓存元数据。绝不保存账号或设备身份。
local H = require("fanqie.helper")

local Library = {}
Library.__index = Library
Library.SCHEMA = 1
Library.MAX_BOOKS = 500

local function text(value)
    if value == nil then return nil end
    local s = tostring(value)
    return s ~= "" and s or nil
end

local function number(value)
    local n = tonumber(value)
    return n and n >= 0 and n or nil
end

local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

local function now()
    return os.time()
end

function Library:new(settings, opts)
    opts = opts or {}
    local obj = {
        settings = settings,
        path = opts.path or (settings.data_dir .. "/library.json"),
        now = opts.now or now,
        data = { schema = self.SCHEMA, books = {}, migrated = false },
        dirty = false,
        last_write = 0,
        write_interval = opts.write_interval or 15,
    }
    setmetatable(obj, self)
    obj:load()
    return obj
end

function Library:load()
    local file = io.open(self.path, "rb")
    if not file then return end
    local raw = file:read("*a")
    file:close()
    local parsed = H.json_decode(raw)
    if type(parsed) ~= "table" or parsed.schema ~= self.SCHEMA
            or type(parsed.books) ~= "table" then
        -- 不用损坏的备份继续覆盖；正文缓存与此文件互不影响。
        os.rename(self.path, self.path .. ".corrupt")
        return
    end
    self.data = parsed
end

function Library:flush()
    if not self.dirty then return true end
    local encoded = H.json_encode(self.data)
    if not encoded then return false, "无法序列化本地资料库" end
    local temp = self.path .. ".tmp"
    local file, err = io.open(temp, "wb")
    if not file then return false, err end
    local ok, write_err = file:write(encoded)
    file:close()
    if not ok then os.remove(temp); return false, write_err end
    local renamed, rename_err = os.rename(temp, self.path)
    if not renamed then os.remove(temp); return false, rename_err end
    self.dirty = false
    self.last_write = self.now()
    return true
end

function Library:save(force)
    if force or self.now() - self.last_write >= self.write_interval then
        return self:flush()
    end
    return true
end

function Library:touch()
    self.dirty = true
end

function Library:book(book_id, create)
    local id = text(book_id)
    if not id then return nil end
    local book = self.data.books[id]
    if not book and create then
        book = { book_id = id }
        self.data.books[id] = book
    end
    return book
end

function Library:get(book_id)
    return copy(self:book(book_id))
end

function Library:record_position(position)
    if type(position) ~= "table" then return false end
    local book = self:book(position.book_id, true)
    if not book then return false end
    local item_id = text(position.item_id or position.itemId)
    if not item_id then return false end
    local p = book.position or {}
    -- 同一章节的较旧回调不能覆盖较新的页位置。
    if p.item_id == item_id and number(position.updated_at)
            and number(p.updated_at) and position.updated_at < p.updated_at then
        return false
    end
    book.title = text(position.title) or book.title
    book.author = text(position.author) or book.author
    book.position = {
        item_id = item_id,
        chapter_index = number(position.chapter_index),
        page = number(position.page),
        total_pages = number(position.total_pages),
        chapter_progress = number(position.chapter_progress),
        updated_at = number(position.updated_at) or self.now(),
    }
    self:touch()
    return self:save(position.force == true)
end

function Library:recent(limit)
    local list = {}
    for _, book in pairs(self.data.books) do
        if book.position then list[#list + 1] = copy(book) end
    end
    table.sort(list, function(a, b)
        local at = a.position.updated_at or 0
        local bt = b.position.updated_at or 0
        if at ~= bt then return at > bt end
        return a.book_id < b.book_id
    end)
    local out = {}
    for i = 1, math.min(limit or 50, #list) do out[i] = list[i] end
    return out
end

function Library:catalog_observation(book_id, chapters, status)
    if type(chapters) ~= "table" or #chapters == 0 then return false end
    local ids = {}
    for i, chapter in ipairs(chapters) do
        local id = text(chapter.itemId or chapter.item_id)
        if not id then return false end
        ids[i] = id
    end
    local book = self:book(book_id, true)
    if not book then return false end
    book.catalog = {
        ids = ids,
        latest_item_id = ids[#ids],
        total_chapters = #ids,
        status = text(status),
        checked_at = self.now(),
    }
    self:touch()
    return self:save()
end

function Library:update_state(book_id, total_chapters)
    local book = self:book(book_id)
    if not book or not book.catalog then return nil end
    local catalog = book.catalog
    local latest = catalog.total_chapters or #catalog.ids
    local read = book.position and book.position.chapter_index or 0
    local seen = book.seen_latest_item_id
    local new_count = 0
    if seen then
        local found = false
        for i, id in ipairs(catalog.ids) do
            if found then new_count = new_count + 1 end
            if id == seen then found = true end
        end
        if not found and seen ~= catalog.latest_item_id then new_count = latest end
    end
    return {
        book_id = book.book_id,
        unread_count = math.max(latest - read, 0),
        new_count = new_count,
        total_chapters = latest,
        status = catalog.status,
        checked_at = catalog.checked_at,
    }
end

function Library:mark_seen(book_id)
    local book = self:book(book_id)
    if not book or not book.catalog then return false end
    book.seen_latest_item_id = book.catalog.latest_item_id
    self:touch()
    return self:save(true)
end

function Library:cache_observation(book_id, chapters, bytes)
    local book = self:book(book_id, true)
    if not book then return false end
    book.cache = {
        chapters = number(chapters) or 0,
        bytes = number(bytes) or 0,
        updated_at = self.now(),
    }
    self:touch()
    return self:save()
end

function Library:migrate(pending, current)
    if self.data.migrated then return end
    for _, item in pairs(pending or {}) do
        if type(item) == "table" then
            self:record_position({
                book_id = item.book_id, item_id = item.item_id,
                chapter_index = (number(item.chapter_idx) or 0) + 1,
                chapter_progress = item.progress, updated_at = item.timestamp,
            })
        end
    end
    if type(current) == "table" then self:record_position(current) end
    self.data.migrated = true
    self:touch()
    self:flush()
end

return Library
