-- 阅读进度与统计的纯计算：本章/全书百分比、剩余页、时长估算。
-- 未知数据一律返回 nil（界面显示「未知」），绝不产生 >100% 或伪造估算。
local M = {}

--- 全书进度百分比（0~100）。
-- 口径：(已完整读完的章数 + 当前章内进度) / 总章数。
-- 章数未知或非法时返回 nil。
function M.book_progress(chapter_index, chapter_progress, total_chapters)
    local total = tonumber(total_chapters)
    local idx = tonumber(chapter_index)
    if not total or total <= 0 or not idx or idx < 1 then return nil end
    local p = tonumber(chapter_progress) or 0
    if p < 0 then p = 0 end
    if p > 1 then p = 1 end
    local done = (idx - 1) + p
    if done > total then done = total end
    return math.floor(done / total * 100)
end

--- 本章剩余页数；未知返回 nil。
function M.chapter_remaining(page, total_pages)
    local p, t = tonumber(page), tonumber(total_pages)
    if not p or not t or t <= 0 or p < 1 then return nil end
    return math.max(t - p, 0)
end

--- 本章内百分比（0~100）；未知返回 nil。
function M.chapter_percent(page, total_pages)
    local p, t = tonumber(page), tonumber(total_pages)
    if not p or not t or t <= 0 or p < 1 then return nil end
    return math.min(math.floor(p / t * 100), 100)
end

--- 剩余时间估算（秒）。按近期每页耗时的中位数外推。
-- 样本不足（<3 页）返回 nil —— 宁可显示「暂无法估计」也不瞎猜。
-- @param page_durations table 每页耗时（秒）的数组，按时间顺序
-- @param remaining_pages number
function M.estimate_seconds(page_durations, remaining_pages)
    local n = page_durations and #page_durations or 0
    local rem = tonumber(remaining_pages)
    if n < 3 or not rem or rem <= 0 then return nil end
    local sorted = {}
    for i = 1, n do
        local v = tonumber(page_durations[i])
        if v and v > 0 then sorted[#sorted + 1] = v end
    end
    if #sorted < 3 then return nil end
    table.sort(sorted)
    local median = sorted[math.ceil(#sorted / 2)]
    return math.floor(median * rem)
end

--- 按书时长聚合：{ [book_id] = { seconds, last_ts } }。
-- 输入是 (book_id, seconds, ts) 的增量记录；重复/负值忽略。
function M.aggregate_duration(store, book_id, seconds, ts)
    if type(store) ~= "table" or not book_id then return store end
    local s = tonumber(seconds)
    if not s or s <= 0 then return store end
    local entry = store[book_id]
    if not entry then
        entry = { seconds = 0, last_ts = 0 }
        store[book_id] = entry
    end
    entry.seconds = entry.seconds + s
    local t = tonumber(ts) or os.time()
    if t > entry.last_ts then entry.last_ts = t end
    return store
end

return M
