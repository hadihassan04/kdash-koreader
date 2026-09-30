--[[--
kdash for KOReader: the dashboard pages drawn natively, so they can be tapped.

The render (render.py on GitHub Actions, in your own data repo) writes data.json,
and the photo page's PNG, to the "out" branch. This plugin downloads them and
lays each page out with KOReader widgets. Swipe left/right between pages, swipe down or Close to leave.

Taps:
  event or forecast day  -> details
  to-do                  -> tick/untick (commits data/todos.md)
  habit                  -> tick/untick today (commits data/habits.md)
  headline               -> QR code of the link
A commit to main starts a render, so data.json catches up.

Open it from Tools > Dashboard (kdash), or bind "Dashboard (kdash)" to a gesture.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local QRMessage = require("ui/widget/qrmessage")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local mime = require("mime")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")
local Screen = Device.screen

-- ------------------------------------------------------------------ config ---
local OUT_BRANCH = "out"
local MAIN_BRANCH = "main"                      -- to-do and habit edits are committed here
local WORKFLOW = "render.yml"                   -- Refresh runs this workflow first
local RENDER_WAIT = 60                          -- seconds to wait for that render (it takes ~20)
local POLL_EVERY = 5                            -- seconds between checks while waiting
local STALE_MIN = 30                            -- older data re-renders on open and on wake
-- While the dashboard is open, the Kindle wakes itself at these times (menu:
-- Timed refresh), refreshes and sleeps again. Hours, or HH:MM, comma separated.
local WAKE_TIMES = "7, 12, 17, 21"
-- "Update plugin" downloads the plugin's files from this public repo
local PLUGIN_URL = "https://raw.githubusercontent.com/hadihassan04/kdash-koreader/main/kdash.koplugin/"
-- The repo ("owner/name") and token are set in the plugin's menu. If not, they're
-- read from repo.txt and token.txt in koreader/kdash/ (easier than typing a token).
local CONF_DIR = DataStorage:getDataDir() .. "/kdash"
local REPO_FILE = CONF_DIR .. "/repo.txt"
local TOKEN_FILE = CONF_DIR .. "/token.txt"
-- -----------------------------------------------------------------------------

local CACHE = DataStorage:getDataDir() .. "/cache/kdash"
local RAW = "application/vnd.github.raw+json"
local JSON = "application/vnd.github+json"

local INK = Blitbuffer.COLOR_BLACK
local MID = Blitbuffer.COLOR_GRAY_5             -- lightest grey used for text
local FAINT = Blitbuffer.COLOR_GRAY_9
local PAPER = Blitbuffer.COLOR_WHITE

local DAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
local MONTHS = { "January", "February", "March", "April", "May", "June", "July",
                 "August", "September", "October", "November", "December" }

-- Layout, set from the screen size in layout(). Sizes below are in pixels of the
-- 758 px wide PNG design (templates/), scaled to the actual screen width.
local W, H, M, CW, SCALE

local function layout()
    W, H = Screen:getWidth(), Screen:getHeight()
    SCALE = W / 758
    M = math.floor(48 * SCALE)                  -- side margin, as in base.html
    CW = W - 2 * M                              -- content width
end

local function px(n)                            -- design px -> screen px
    return math.floor(n * SCALE + 0.5)
end

-- -------------------------------------------------------------------- fonts ---
-- Literata (the PNG pages' typeface) if its TTFs are in koreader/fonts, else
-- Noto Serif, which ships with KOReader. "display" is Literata's 72pt optical
-- size, drawn for big numbers and titles like the PNG pages' 800 weight.
local FONT_FILES = {
    regular = { "Literata-Regular.ttf", "NotoSerif-Regular.ttf" },
    italic = { "Literata-Italic.ttf", "NotoSerif-Italic.ttf" },
    semibold = { "Literata-SemiBold.ttf", "NotoSerif-Bold.ttf" },
    bold = { "Literata-Bold.ttf", "NotoSerif-Bold.ttf" },
    display = { "Literata72pt-ExtraBold.ttf", "Literata-ExtraBold.ttf", "NotoSerif-Bold.ttf" },
    icons = { "nerdfonts/symbols.ttf", "symbols.ttf" },  -- Weather Icons + Font Awesome, bundled
}
local font_names = {}

local function fontName(style)
    if not font_names[style] then
        for __, f in ipairs(FONT_FILES[style]) do
            if Font:getFace(f, 12) then
                font_names[style] = f
                break
            end
        end
        font_names[style] = font_names[style] or "cfont"
    end
    return font_names[style]
end

-- Font:getFace scales its size for the DPI; undo that so `size` is design px
local function face(style, size)
    local unit = Screen:scaleBySize(1000) / 1000
    return Font:getFace(fontName(style or "regular"), (size or 26) * SCALE / unit)
end

-- Codepoints in KOReader's fonts/nerdfonts/symbols.ttf
local ICON = {
    sunny = 0xE30D, mostly_clear = 0xE30C, partly = 0xE302, cloudy = 0xE312, fog = 0xE313,
    drizzle = 0xE31B, rain = 0xE318, rain_mix = 0xE316, showers = 0xE319, snow = 0xE31A,
    thunder = 0xE31D, hail = 0xE314, cloud = 0xE33D,
    sunrise = 0xE34C, sunset = 0xE34D, wind = 0xE34B, raindrop = 0xE371, thermometer = 0xE350,
    refresh = 0xF021, close = 0xF00D, plus = 0xF067, box = 0xF096, box_checked = 0xF14A,
    pin = 0xF041, qr = 0xF029, flame = 0xF06D, quote = 0xF10D, calendar = 0xF073,
}

-- Weather description (sources.WMO) -> icon; first match wins
local WEATHER_ICONS = {
    { "thunder", "thunder" }, { "hail", "hail" }, { "freezing rain", "rain_mix" },
    { "snow", "snow" }, { "shower", "showers" }, { "drizzle", "drizzle" }, { "rain", "rain" },
    { "fog", "fog" }, { "overcast", "cloudy" }, { "partly", "partly" },
    { "mostly clear", "mostly_clear" }, { "clear", "sunny" },
}

local function weatherIcon(desc)
    desc = (desc or ""):lower()
    for __, m in ipairs(WEATHER_ICONS) do
        if desc:find(m[1], 1, true) then return ICON[m[2]] end
    end
    return ICON.cloud
end

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40,
                           0x80 + cp % 0x40)
    end
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
                       0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

-- ----------------------------------------------------------- small helpers ---
local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function lines(s)
    local t, pos = {}, 1
    s = s:gsub("\r", "")
    while pos <= #s do
        local e = s:find("\n", pos, true)
        if not e then
            t[#t + 1] = s:sub(pos)
            break
        end
        t[#t + 1] = s:sub(pos, e - 1)
        pos = e + 1
    end
    return t
end

local function readFile(path, mode)
    local f = io.open(path, mode or "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function writeFile(path, data)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "wb")
    if not f then return false end
    f:write(data)
    f:close()
    return os.rename(tmp, path)
end

-- JSON null decodes to rapidjson.null, which is true in Lua; make it nil
local function denull(v)
    if v == rapidjson.null then return nil end
    if type(v) == "table" then
        for k, x in pairs(v) do v[k] = denull(x) end
    end
    return v
end

local function decode(s)
    local ok, v = pcall(rapidjson.decode, s or "")
    if ok and type(v) == "table" then return denull(v) end
end

-- "2026-09-30" or "2026-09-30T16:00:00+02:00" -> parts
local function parseDate(iso)
    local y, m, d = (iso or ""):match("^(%d+)-(%d+)-(%d+)")
    if not y then return nil end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    local t = os.time{ year = y, month = m, day = d, hour = 12 }
    return { y = y, m = m, d = d, wday = os.date("*t", t).wday,
             ord = math.floor(t / 86400), hm = iso:match("T(%d%d:%d%d)") }
end

local function longDate(p)       -- "Thursday 1 October"
    return string.format("%s %d %s", DAYS[p.wday], p.d, MONTHS[p.m])
end

local function shortDate(p)      -- "Thu 1 Oct"
    return string.format("%s %d %s", DAYS[p.wday]:sub(1, 3), p.d, MONTHS[p.m]:sub(1, 3))
end

-- "Today", "Tomorrow" or "Thu 1 Oct", relative to the render's date
local function dayLabel(iso, today)
    local p, t = parseDate(iso), parseDate(today)
    if p and t then
        if p.ord == t.ord then return _("Today") end
        if p.ord == t.ord + 1 then return _("Tomorrow") end
    end
    return p and shortDate(p) or ""
end

-- ------------------------------------------------------------------ GitHub ---
-- A setting from the plugin menu, else the first word of `file`
local function setting(key, file)
    local v = G_reader_settings:readSetting(key)
    if v and v ~= "" then return v end
    v = readFile(file)
    v = v and v:match("%S+")
    if v and v ~= "" then return v end
end

local function getToken() return setting("kdash_token", TOKEN_FILE) end
local function getRepo() return setting("kdash_repo", REPO_FILE) end

local function wakeSetting() return G_reader_settings:readSetting("kdash_wake_times") or WAKE_TIMES end

-- Seconds until the next timed refresh, or nil if none are set
local function secondsToNextWake()
    local now = os.time()
    local t = os.date("*t", now)
    local best
    for hs, ms in wakeSetting():gmatch("(%d+):?(%d*)") do
        local h, m = tonumber(hs), tonumber(ms) or 0
        if h < 24 and m < 60 then
            local at = os.time{ year = t.year, month = t.month, day = t.day, hour = h, min = m, sec = 0 }
            if at <= now + 60 then
                at = os.time{ year = t.year, month = t.month, day = t.day + 1, hour = h, min = m, sec = 0 }
            end
            if not best or at < best then best = at end
        end
    end
    return best and best - now
end

-- Call the GitHub API for the configured repo. Returns the body, or nil and an error text.
local function api(method, path, accept, body)
    local repo = getRepo()
    if not repo then return nil, _("no GitHub repo set (Tools > Dashboard (kdash))") end
    local headers = { ["Accept"] = accept or JSON, ["User-Agent"] = "kdash",
                      ["X-GitHub-Api-Version"] = "2022-11-28" }
    local token = getToken()
    if token then headers["Authorization"] = "Bearer " .. token end
    local source
    if body then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
        source = ltn12.source.string(body)
    end
    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, resp_headers, status = socket.skip(1, http.request{
        url = "https://api.github.com/repos/" .. repo .. "/" .. path,
        method = method, headers = headers, source = source,
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    local text = table.concat(sink)
    if type(code) ~= "number" then
        logger.warn("kdash:", method, path, "failed:", code)
        return nil, tostring(code or "no connection")
    end
    if code >= 300 then
        local ok, j = pcall(rapidjson.decode, text)
        local msg = ok and type(j) == "table" and j.message or status or ""
        logger.warn("kdash:", method, path, code, msg)
        if code == 401 or code == 403 or code == 404 then
            if not token then return nil, _("no GitHub token set") end
            msg = msg .. " (check the token's access)"
        end
        return nil, code .. " " .. msg
    end
    return text
end

local function outSha()
    local sha = api("GET", "commits/" .. OUT_BRANCH, "application/vnd.github.sha")
    return sha and trim(sha)
end

-- Read a file on main, change it with fn(text) -> new text (or nil, error), commit it.
local function editRepoFile(path, fn, message)
    local body, err = api("GET", "contents/" .. path .. "?ref=" .. MAIN_BRANCH)
    if not body then return nil, err end
    local j = rapidjson.decode(body)
    local b64 = (j.content or ""):gsub("%s", "")
    local old = mime.unb64(b64) or ""
    local new, e2 = fn(old)
    if not new then return nil, e2 end
    local put = rapidjson.encode({ message = message, content = (mime.b64(new)),
                                   sha = j.sha, branch = MAIN_BRANCH })
    return api("PUT", "contents/" .. path, JSON, put)
end

-- -------------------------------------------------------- data file edits ---
local TODO = "^(%s*[-*]%s*%[)([ xX])(%]%s*)(.-)%s*$"

local function setTodo(md, target, done)
    local L, found = lines(md), false
    for i, line in ipairs(L) do
        local pre, mark, post, item = line:match(TODO)
        if pre and item == target then
            L[i] = pre .. (done and "x" or " ") .. post .. item
            found = true
            break
        end
    end
    if not found then return nil, _("to-do not found; it may have changed elsewhere") end
    return table.concat(L, "\n") .. "\n"
end

local function deleteTodo(md, target)
    local L = lines(md)
    for i, line in ipairs(L) do
        local pre, mark, post, item = line:match(TODO)
        if pre and item == target then
            table.remove(L, i)
            return table.concat(L, "\n") .. "\n"
        end
    end
    return nil, _("to-do not found; it may have changed elsewhere")
end

local function addTodo(md, text)
    local L, last = lines(md), nil
    for i, line in ipairs(L) do
        if line:match(TODO) then last = i end
    end
    table.insert(L, (last or #L) + 1, "- [ ] " .. text)
    return table.concat(L, "\n") .. "\n"
end

-- Tick or untick `day` for habit `name` under "## YYYY-MM" (section made if missing).
local function setHabit(md, ym, names, name, day, on)
    local L, s = lines(md), nil
    for i, l in ipairs(L) do
        local y, m = l:match("^##%s*(%d%d%d%d)%-(%d%d)")
        if y and y .. "-" .. m == ym then s = i end
    end
    if not s then
        if #L > 0 and trim(L[#L]) ~= "" then L[#L + 1] = "" end
        L[#L + 1] = "## " .. ym
        s = #L
        for __, n in ipairs(names) do L[#L + 1] = n .. ":" end
    end
    local e = #L
    for i = s + 1, #L do
        if L[i]:match("^%s*##") then e = i - 1 break end
    end
    local idx
    for i = s + 1, e do
        local l = trim(L[i])
        local n = not l:match("^#") and l:match("^([^:]+):")
        if n and trim(n) == name then idx = i break end
    end
    if not idx then
        local at = s
        for i = s + 1, e do
            if trim(L[i]) ~= "" then at = i end
        end
        table.insert(L, at + 1, name .. ":")
        idx = at + 1
    end
    local n, rest = L[idx]:match("^([^:]*):(.*)$")
    local set, nums = {}, {}
    for num in rest:gmatch("%d+") do set[tonumber(num)] = true end
    set[day] = on or nil
    for k in pairs(set) do nums[#nums + 1] = k end
    table.sort(nums)
    L[idx] = trim(n) .. ":" .. (#nums > 0 and " " .. table.concat(nums, " ") or "")
    return table.concat(L, "\n") .. "\n"
end

-- Count and streak for a habit row, the same way sources.habits() does
local function habitStats(row, today)
    local on, count = {}, 0
    for __, d in ipairs(row.days) do
        on[d] = true
        if d <= today then count = count + 1 end
    end
    local d, streak = on[today] and today or today - 1, 0
    while d >= 1 and on[d] do streak, d = streak + 1, d - 1 end
    row.count, row.streak = count, streak
end

-- ---------------------------------------------------------------- widgets ---
-- o: style (regular/italic/semibold/bold/display/icons), size (design px), color, width
local function text(s, o)            -- one line, cut with an ellipsis if too wide
    o = o or {}
    local t = TextWidget:new{ text = s or "", face = face(o.style, o.size), fgcolor = o.color or INK,
                              max_width = o.width or CW, padding = 0 }
    if o.tight then                  -- big numbers: line box hugs the digits, like line-height .8
        local sz = px(o.size)
        t.forced_height = math.floor(sz * 0.78)
        t.forced_baseline = math.floor(sz * 0.74)
    end
    return t
end

local function para(s, o)            -- wrapped text
    o = o or {}
    return TextBoxWidget:new{ text = s or "", face = face(o.style, o.size), fgcolor = o.color or INK,
                              width = o.width or CW, alignment = o.align or "left",
                              line_height = o.line_height or 0.25 }
end

-- name is a key of ICON or a codepoint. Weather Icons glyphs draw well past their
-- advance width, so each icon sits centred in a slot 1.5x its size to not overlap.
local function icon(name, size, color)
    size = size or 26
    local g = TextWidget:new{ text = utf8char(type(name) == "number" and name or ICON[name]),
                              face = face("icons", size), fgcolor = color or INK, padding = 0 }
    return CenterContainer:new{ dimen = Geom:new{ w = px(size * 1.5), h = g:getSize().h }, g }
end

local function vgap(n) return VerticalSpan:new{ width = px(n) } end

-- Lay out texts (and spans) side by side with their baselines level
local function baseline(...)
    local items, top = { ... }, 0
    for __, w in ipairs(items) do
        if w.getBaseline then top = math.max(top, w:getBaseline()) end
    end
    local g = HorizontalGroup:new{ align = "top" }
    for __, w in ipairs(items) do
        if w.getBaseline then
            w = FrameContainer:new{ bordersize = 0, padding = 0, padding_top = top - w:getBaseline(), w }
        end
        table.insert(g, w)
    end
    return g
end
local function hgap(n) return HorizontalSpan:new{ width = px(n) } end

-- Fixed-size slot, child at the top left (FrameContainer's width/height don't set its size)
local Box = WidgetContainer:extend{ box_w = nil, box_h = nil }

function Box:getSize()
    local s = self[1]:getSize()
    return Geom:new{ w = self.box_w or s.w, h = self.box_h or s.h }
end

function Box:paintTo(bb, x, y)
    local s = self:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = s.w, h = s.h }
    self[1]:paintTo(bb, x, y)
end

local function box(widget, w, h)
    return Box:new{ box_w = w, box_h = h, widget }
end

-- A column of width w; align = "left" (default), "right" or "center", vertically centred on h
local function cell(widget, w, align, h)
    h = h or widget:getSize().h
    local C = align == "right" and RightContainer or align == "center" and CenterContainer or LeftContainer
    return C:new{ dimen = Geom:new{ w = w, h = h }, widget }
end

local function pad(widget, top, bottom, left)
    return FrameContainer:new{ bordersize = 0, padding = 0, padding_top = px(top or 0),
                               padding_bottom = px(bottom or 0), padding_left = px(left or 0), widget }
end

-- Rules as in base.html: .rule is 2 px ink, table lines 1 px grey
local function rule(kind, top, bottom)
    local thick = kind ~= "thin"
    return pad(LineWidget:new{ dimen = Geom:new{ w = CW, h = thick and math.max(2, px(2)) or 1 },
                               background = thick and INK or FAINT },
               top or (thick and 18 or 0), bottom or (thick and 16 or 0))
end

local function heading(s, sub)
    local t = text(s, { style = "bold", size = 30 })
    if sub then
        t = baseline(t, hgap(12), text(sub, { size = 20, color = MID, width = CW - t:getSize().w - px(12) }))
    end
    return pad(t, 4, 10)
end

local function note(s)               -- muted italic line (hints, empty states, errors)
    return pad(para(s, { style = "italic", size = 20, color = MID }), 0, 10)
end

-- Two columns: fixed-width left, the rest right
local function cols(left, right, left_w)
    return HorizontalGroup:new{ align = "top", box(left, left_w), right }
end

-- Draws a line through its child (done to-dos, like the PNG page)
local Strike = WidgetContainer:extend{}
function Strike:getSize() return self[1]:getSize() end
function Strike:paintTo(bb, x, y)
    local s = self[1]:getSize()
    self[1]:paintTo(bb, x, y)
    bb:paintRect(x, y + math.floor(s.h * 0.55), s.w, math.max(1, px(1.5)), MID)
end

-- A full-width row that runs `callback` when tapped
local Tappable = InputContainer:extend{ callback = nil, hold_callback = nil, width = nil }

function Tappable:init()
    local s = self[1]:getSize()
    local w = self.width or CW
    self[1] = box(self[1], w, s.h)
    self.dimen = Geom:new{ x = 0, y = 0, w = w, h = s.h }
    local range = function() return self.dimen end
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = range } } }
    if self.hold_callback then
        self.ges_events.Hold = { GestureRange:new{ ges = "hold", range = range } }
    end
end

function Tappable:onTap()
    if self.callback then self.callback() end
    return true
end

function Tappable:onHold()
    if self.hold_callback then self.hold_callback() end
    return true
end

local function row(widget, callback, bottom, hold)
    local w = pad(widget, 0, bottom or 14)
    local r = callback and Tappable:new{ callback = callback, hold_callback = hold, w } or w
    r.is_item = true
    return r
end

-- Icon button: glyph with a generous tap area
local function iconButton(name, callback, size)
    size = size or 30
    local g = icon(name, size)
    local s = g:getSize()
    local hit = px(12)
    return Tappable:new{ callback = callback, width = s.w + hit * 2,
        FrameContainer:new{ bordersize = 0, padding = 0, padding_left = hit, padding_right = hit,
                            padding_top = px(4), padding_bottom = px(4), g } }
end

-- Page dots in the footer (base.html .dots: 14 px circles, 2 px ring, 9 px apart)
local PageDots = Widget:extend{ n = 1, cur = 1 }
function PageDots:init() self.size, self.gap = px(14), px(9) end
function PageDots:getSize()
    return Geom:new{ w = self.n * self.size + (self.n - 1) * self.gap, h = self.size }
end
function PageDots:paintTo(bb, x, y)
    local r = math.floor(self.size / 2)
    for i = 1, self.n do
        local cx = x + (i - 1) * (self.size + self.gap)
        bb:paintCircle(cx + r, y + r, r, INK, i ~= self.cur and math.max(1, px(2)) or nil)
    end
end

-- One dot per day; days gone are filled, today has a thick ring
local DotGrid = Widget:extend{ total = 1, gone = 0, width = 100, height = 100 }
function DotGrid:init()
    local total = math.max(self.total, 1)
    self.cols = math.max(1, math.ceil(math.sqrt(total * self.width / self.height)))
    self.rows = math.ceil(total / self.cols)
    self.cell = math.floor(math.min(self.width / self.cols, self.height / self.rows))
    self.dot = math.max(4, math.floor(self.cell * 0.62))
end
function DotGrid:getSize() return Geom:new{ w = self.cols * self.cell, h = self.rows * self.cell } end
function DotGrid:paintTo(bb, x, y)
    local off = math.floor((self.cell - self.dot) / 2)
    local r = math.floor(self.dot / 2)
    for i = 0, self.total - 1 do
        local dx = x + (i % self.cols) * self.cell + off
        local dy = y + math.floor(i / self.cols) * self.cell + off
        local ring
        if i == self.gone then
            ring = math.max(2, math.floor(r / 2))
        elseif i > self.gone then
            ring = math.max(1, px(1.5))
        end
        bb:paintCircle(dx + r, dy + r, r, INK, ring)
    end
end

-- A month of habit cells (habits.html .grid)
local HabitGrid = Widget:extend{ ndays = 30, day = 1, days = nil, width = 100 }
function HabitGrid:init()
    self.gap = math.max(1, px(2))
    self.cell = (self.width + self.gap) / self.ndays
    self.sq = math.floor(self.cell - self.gap)
    self.h = math.floor(self.sq * 1.25)
    self.on = {}
    for __, d in ipairs(self.days or {}) do self.on[d] = true end
end
function HabitGrid:getSize() return Geom:new{ w = self.width, h = self.h } end
function HabitGrid:paintTo(bb, x, y)
    for d = 1, self.ndays do
        local bx = x + math.floor((d - 1) * self.cell)
        if self.on[d] then
            bb:paintRect(bx, y, self.sq, self.h, INK)
        elseif d > self.day then
            bb:paintBorder(bx, y, self.sq, self.h, 1, FAINT)
        else
            bb:paintBorder(bx, y, self.sq, self.h, d == self.day and math.max(2, px(3)) or math.max(1, px(1.5)), INK)
        end
    end
end

-- Day numbers under the first habit grid (1, 5, 10, ...)
local DayNums = Widget:extend{ ndays = 30, width = 100 }
function DayNums:init()
    self.cell = (self.width + math.max(1, px(2))) / self.ndays
    self.labels = {}
    for d = 1, self.ndays do
        if d == 1 or d % 5 == 0 then self.labels[d] = text(tostring(d), { size = 14, color = MID }) end
    end
    self.h = self.labels[1]:getSize().h
end
function DayNums:getSize() return Geom:new{ w = self.width, h = self.h } end
function DayNums:paintTo(bb, x, y)
    for d, t in pairs(self.labels) do
        local cx = x + math.floor((d - 1) * self.cell + self.cell / 2)
        t:paintTo(bb, cx - math.floor(t:getSize().w / 2), y)
    end
end

-- Stack rows top to bottom until max_h; the rest become "+N more"
local function stack(rows, max_h)
    local out, used = {}, 0
    for i, r in ipairs(rows) do
        local h = r:getSize().h
        if used + h > max_h then
            local more = 0
            for j = i, #rows do
                if rows[j].is_item then more = more + 1 end
            end
            if more > 0 then
                local line_h = text("+", { size = 20 }):getSize().h
                while #out > 0 and used + line_h > max_h do
                    local last = table.remove(out)
                    used = used - last:getSize().h
                    if last.is_item then more = more + 1 end
                end
                out[#out + 1] = text("+" .. more .. " more", { style = "italic", size = 20, color = MID })
            end
            break
        end
        out[#out + 1] = r
        used = used + h
    end
    return VerticalGroup:new{ align = "left", unpack(out) }
end

local function info(s)
    UIManager:show(InfoMessage:new{ text = s, show_icon = false, face = face("regular", 26) })
end

local function toast(s)
    UIManager:show(InfoMessage:new{ text = s, show_icon = false, timeout = 4, face = face("regular", 24) })
end

-- ---------------------------------------------------------------- the pages ---
-- Each page: title(d, all) -> title, subtitle (or masthead(d, all) -> widget);
-- body(dash, d, height, all) -> list of rows.
local Pages = {}

local function eventDetail(e)
    local s = parseDate(e.start)
    local when = s and longDate(s) or ""
    if e.allday then
        when = when .. ", " .. _("all day")
    else
        local en = parseDate(e["end"])
        when = when .. ", " .. (s.hm or "") .. (en and en.hm and (" to " .. en.hm) or "")
    end
    local t = e.title .. "\n" .. when
    if e.location and e.location ~= "" then t = t .. "\n" .. e.location end
    if e.deadline then t = t .. "\n" .. _("Deadline") end
    return t
end

-- today.html .ev: 128 px time column, title 24 px, location 20 px grey
local function eventRow(e, today, show_day)
    local s = parseDate(e.start) or {}
    local lw = px(140)
    local left = VerticalGroup:new{ align = "left" }
    if show_day then
        table.insert(left, text(dayLabel(e.start, today), { style = "semibold", size = 21, width = lw - px(6) }))
    end
    table.insert(left, text(e.allday and _("All day") or s.hm, { size = 20, color = MID, width = lw - px(6) }))
    local rw = CW - lw
    local right = VerticalGroup:new{ align = "left",
        text(e.title, { style = e.deadline and "bold" or "regular", size = 24, width = rw }) }
    if e.location and e.location ~= "" then
        table.insert(right, HorizontalGroup:new{ align = "center",
            icon("pin", 16, MID), hgap(6), text(e.location, { size = 20, color = MID, width = rw - px(24) }) })
    end
    return row(cols(left, right, lw), function() info(eventDetail(e)) end, 12)
end

local function weatherDetail(day)
    local p = parseDate(day.date)
    return string.format("%s\n%s, %d° / %d°\n%s %d%%, %s %d km/h, UV %d\n%s %s, %s %s",
        p and longDate(p) or "", day.desc, day.hi, day.lo, _("Rain"), day.rain,
        _("wind"), day.wind, day.uv, _("Sunrise"), day.sunrise, _("sunset"), day.sunset)
end

-- todos.html: box, then text; done ones grey and struck through
local function todoRow(dash, t, size)
    size = size or 26
    local g = icon(t.done and "box_checked" or "box", math.floor(size * 1.15), t.done and MID or INK)
    local gw = px(size * 1.6)
    local tw = CW - gw
    local label = t.done and Strike:new{ text(t.text, { size = size, color = MID, width = tw }) }
                          or para(t.text, { size = size, width = tw })
    return row(HorizontalGroup:new{ align = "top", cell(g, gw, "left", text("X", { size = size }):getSize().h),
                                    label }, function() dash:toggleTodo(t) end, 10,
               function() dash:askDeleteTodo(t) end)
end

local function errorRows(rows, ...)
    for __, e in ipairs({ ... }) do
        if e then rows[#rows + 1] = note(e) end
    end
end

Pages.today = {
    -- today.html masthead: huge day number, weekday, month and year
    masthead = function(d, all, avail_w)
        local p = parseDate(all.today)
        if not p then return text(_("Today"), { style = "display", size = 56 }) end
        local num = text(tostring(p.d), { style = "display", size = 190, tight = true })
        local side = VerticalGroup:new{ align = "left",
            text(DAYS[p.wday], { style = "semibold", size = 46, width = avail_w - num:getSize().w - px(26) }),
            text(MONTHS[p.m] .. " " .. p.y, { size = 30, color = MID }) }
        return HorizontalGroup:new{ align = "bottom", num, hgap(26), pad(side, 0, 0) }
    end,
    body = function(dash, d, h, all)
        local rows = { rule("thick", 20, 18) }
        local w = d.weather
        if w and w.days and w.days[1] then
            local d0 = w.days[1]
            -- The facts column takes the width its lines need; the rest is for
            -- the icon, temperature and description, side by side
            local FS = 23
            local function fact(ic, s)
                return HorizontalGroup:new{ align = "center", text(s, { size = FS }), icon(ic, 20) }
            end
            local facts = VerticalGroup:new{ align = "right",
                fact("thermometer", string.format("%s %d°, %s %d°", _("High"), d0.hi, _("low"), d0.lo)),
                vgap(4),
                fact("wind", string.format("%s %d°, %d km/h", _("Feels"), w.feels, w.wind)),
                vgap(4),
                HorizontalGroup:new{ align = "center",   -- sunrise and sunset share a line
                    text(d0.sunrise, { size = FS }), icon("sunrise", 20), hgap(10),
                    text(d0.sunset, { size = FS }), icon("sunset", 20) } }
            local fw = math.min(facts:getSize().w, math.floor(CW * 0.5))
            local lw = CW - fw - px(12)
            local now = HorizontalGroup:new{ align = "center",
                icon(weatherIcon(w.desc), 64),
                hgap(18), text(w.temp .. "°", { style = "display", size = 88, tight = true }) }
            now = HorizontalGroup:new{ align = "center", now, hgap(14),
                para(w.desc, { style = "semibold", size = 30, width = lw - now:getSize().w - px(14) }) }
            rows[#rows + 1] = row(HorizontalGroup:new{ align = "center", box(now, lw), cell(facts, CW - lw, "right") },
                                  function() info(weatherDetail(d0)) end, 14)
            local hours = HorizontalGroup:new{ align = "top" }
            local n = #(w.hours or {})
            local colw = math.floor(CW / math.max(n, 1))
            for __, hr in ipairs(w.hours or {}) do
                table.insert(hours, cell(VerticalGroup:new{ align = "center",
                    text(hr.time, { size = 22, color = MID }),
                    text(hr.temp .. "°", { style = "bold", size = 28 }),
                    HorizontalGroup:new{ align = "center", icon("raindrop", 18, MID), hgap(4),
                                         text(hr.rain .. "%", { size = 22 }) } }, colw, "center"))
            end
            if n > 0 then rows[#rows + 1] = hours end
            rows[#rows + 1] = rule("thick", 16, 14)
        else
            errorRows(rows, d.weather_error)
        end

        rows[#rows + 1] = heading(_("Next up"))
        errorRows(rows, d.events_error)
        if not d.has_calendar then
            rows[#rows + 1] = note(_("No calendar set."))
        elseif #(d.upcoming or {}) == 0 then
            rows[#rows + 1] = note(_("Nothing coming up."))
        end
        for __, e in ipairs(d.upcoming or {}) do rows[#rows + 1] = eventRow(e, all.today, true) end

        if #(d.open_todos or {}) > 0 then
            rows[#rows + 1] = rule("thick", 16, 14)
            rows[#rows + 1] = heading(_("To-do"))
            for __, t in ipairs(d.open_todos) do rows[#rows + 1] = todoRow(dash, t, 24) end
        end
        return rows
    end,
}

Pages.agenda = {
    title = function() return _("Agenda"), _("next 7 days") end,
    body = function(dash, d, h, all)
        local rows = {}
        errorRows(rows, d.events_error)
        for i, day in ipairs(d.agenda or {}) do
            local p = parseDate(day.date)
            if i > 1 then rows[#rows + 1] = rule("thin", 2, 10) end
            rows[#rows + 1] = heading(day.today and _("Today") or (p and DAYS[p.wday] or ""),
                                      p and (p.d .. " " .. MONTHS[p.m]) or nil)
            if #(day.events or {}) == 0 then
                rows[#rows + 1] = note(_("Nothing planned."))
            end
            for __, e in ipairs(day.events or {}) do rows[#rows + 1] = eventRow(e, all.today, false) end
        end
        return rows
    end,
}

-- weather.html: now at the top, then a table of 7 days
Pages.weather = {
    title = function(d, all) return _("Weather"), all.location end,
    body = function(dash, d, h, all)
        local rows = {}
        local w = d.weather
        if not w then
            errorRows(rows, d.weather_error or _("No weather."))
            return rows
        end
        rows[#rows + 1] = row(HorizontalGroup:new{ align = "center",
            icon(weatherIcon(w.desc), 70),
            hgap(20),
            text(w.temp .. "°", { style = "display", size = 88, tight = true }), hgap(28),
            VerticalGroup:new{ align = "left",
                text(w.desc, { style = "semibold", size = 28, width = CW - px(330) }),
                text(string.format("%s %d°, UV %d", _("Feels like"), w.feels, w.uv), { size = 22, color = MID }) } },
            w.days and w.days[1] and function() info(weatherDetail(w.days[1])) end, 22)
        -- column widths: day, icon, conditions, high/low, rain, wind, uv
        local cw = { px(92), px(46), 0, px(112), px(78), px(62), px(46) }
        cw[3] = CW - cw[1] - cw[2] - cw[4] - cw[5] - cw[6] - cw[7]
        local rh = px(56)
        local function line(c, hh)
            return HorizontalGroup:new{ align = "center",
                cell(c[1], cw[1], "left", hh), cell(c[2], cw[2], "left", hh), cell(c[3], cw[3], "left", hh),
                cell(c[4], cw[4], "right", hh), cell(c[5], cw[5], "right", hh),
                cell(c[6], cw[6], "right", hh), cell(c[7], cw[7], "right", hh) }
        end
        local function th(s) return text(s, { size = 18, color = MID }) end
        rows[#rows + 1] = line({ th(_("Day")), th(""), th(""), th(_("High, low")), th(_("Rain")),
                                 th(_("Wind")), th("UV") }, px(30))
        rows[#rows + 1] = rule("thick", 0, 0)
        for i, day in ipairs(w.days or {}) do
            local p = parseDate(day.date)
            local label = i == 1 and _("Today") or (p and DAYS[p.wday]:sub(1, 3) or "")
            local hilo = baseline(text(day.hi .. "°", { style = "bold", size = 24 }), hgap(6),
                                  text(day.lo .. "°", { size = 22 }))
            rows[#rows + 1] = row(line({
                text(label, { style = "bold", size = 24, width = cw[1] }),
                icon(weatherIcon(day.desc), 26),
                text(day.desc, { size = 21, width = cw[3] - px(8) }),
                hilo,
                text(day.rain .. "%", { size = 22 }),
                text(tostring(day.wind), { size = 22 }),
                text(tostring(day.uv), { size = 22 }) }, rh), function() info(weatherDetail(day)) end, 0)
            rows[#rows + 1] = rule("thin", 0, 0)
        end
        rows[#rows + 1] = pad(para(_("Wind in km/h. Tap a day for sunrise and sunset."),
                                   { size = 20, color = MID }), 14, 0)
        return rows
    end,
}

Pages.todos = {
    title = function(d)
        local open = 0
        for __, t in ipairs(d.todos or {}) do if not t.done then open = open + 1 end end
        return _("To-do"), open .. " " .. _("open")
    end,
    add_button = true,
    body = function(dash, d)
        local rows = {}
        if #(d.todos or {}) == 0 then rows[#rows + 1] = note(_("Nothing to do. Tap + to add one.")) end
        for __, t in ipairs(d.todos or {}) do rows[#rows + 1] = todoRow(dash, t) end
        if #(d.todos or {}) > 0 then
            rows[#rows + 1] = pad(note(_("Tap to tick. Hold to delete.")), 10, 0)
        end
        return rows
    end,
}

Pages.countdowns = {
    title = function() return _("Countdowns") end,
    body = function(dash, d)
        local rows = {}
        errorRows(rows, d.events_error)
        if #(d.countdowns or {}) == 0 then rows[#rows + 1] = note(_("No countdowns.")) end
        local lw = px(170)
        for i, c in ipairs(d.countdowns or {}) do
            local p = parseDate(c.date)
            local num = c.days == 0 and text(_("Today"), { style = "display", size = 40 })
                or VerticalGroup:new{ align = "left",
                    text(tostring(c.days), { style = "display", size = 64, tight = true }),
                    vgap(6), text(c.days == 1 and _("day") or _("days"), { size = 20, color = MID }) }
            if i > 1 then rows[#rows + 1] = rule("thin", 0, 16) end
            rows[#rows + 1] = row(HorizontalGroup:new{ align = "center", box(num, lw),
                VerticalGroup:new{ align = "left",
                    para(c.name, { style = "bold", size = 28, width = CW - lw }),
                    text(p and (longDate(p) .. " " .. p.y) or "", { size = 20, color = MID, width = CW - lw }) } },
                nil, 16)
        end
        return rows
    end,
}

Pages.dots = {
    -- dots.html head: the count first, then "days left <name>" and the end date
    masthead = function(d, all, avail_w)
        local left = math.max(d.left or 0, 0)
        local num = text(tostring(left), { style = "display", size = 120, tight = true })
        local lw = avail_w - num:getSize().w - px(22)
        local label = (left == 1 and _("day") or _("days")) .. " " .. _("left")
        if d.name and d.name ~= "" then label = label .. " " .. d.name end
        local e = parseDate(d["end"])
        local side = VerticalGroup:new{ align = "left",
            para(label, { style = "semibold", size = 34, width = lw, line_height = 0.1 }) }
        if e then
            table.insert(side, text(_("until") .. " " .. shortDate(e) .. " " .. e.y, { size = 22, color = MID, width = lw }))
        end
        return HorizontalGroup:new{ align = "bottom", num, hgap(22), side }
    end,
    body = function(dash, d, h)
        local foot = text(string.format("%d %s %d %s", d.gone or 0, _("of"), d.total or 0, _("days gone")),
                          { size = 22, color = MID })
        local rows = { rule("thick", 22, 26) }
        local used = rows[1]:getSize().h + foot:getSize().h + px(20)
        local grid = DotGrid:new{ total = d.total or 1, gone = d.gone or 0, width = CW, height = h - used }
        rows[#rows + 1] = cell(grid, CW, "center")
        rows[#rows + 1] = pad(foot, 20, 0)
        return rows
    end,
}

Pages.reading = {
    title = function() return _("Reading") end,
    body = function(dash, d)
        local rows = {}
        errorRows(rows, d.reading_error)
        for s, sec in ipairs(d.sections or {}) do
            if s > 1 then rows[#rows + 1] = vgap(10) end
            rows[#rows + 1] = heading(sec.name)
            rows[#rows + 1] = rule("thick", 0, 10)
            for __, e in ipairs(sec.entries or {}) do
                local tw = CW - px(40)
                local g = VerticalGroup:new{ align = "left", para(e.title, { size = 23, width = tw }) }
                if e.meta and e.meta ~= "" then
                    table.insert(g, text(e.meta, { size = 18, color = MID, width = tw }))
                end
                local has_link = e.link and e.link ~= ""
                local line = HorizontalGroup:new{ align = "top", box(g, tw),
                    has_link and cell(icon("qr", 20, MID), px(40), "right") or hgap(40) }
                rows[#rows + 1] = row(line, has_link and function()
                    UIManager:show(QRMessage:new{ text = e.link, width = math.floor(W * 0.7),
                                                  height = math.floor(W * 0.7) })
                end or nil, 12)
            end
        end
        return rows
    end,
}

Pages.habits = {
    title = function(d) return _("Habits"), d.habits and d.habits.month end,
    body = function(dash, d)
        local rows = {}
        errorRows(rows, d.habits_error)
        local hb = d.habits
        if not hb then return rows end
        if #(hb.rows or {}) == 0 then rows[#rows + 1] = note(_("No habits yet. Add them to data/habits.md.")) end
        for i, r in ipairs(hb.rows or {}) do
            local stats = r.count .. " " .. _("of") .. " " .. hb.day .. " " .. _("days")
            local done_today = false
            for __, x in ipairs(r.days) do if x == hb.day then done_today = true end end
            local right = HorizontalGroup:new{ align = "center" }
            if r.streak > 1 then
                table.insert(right, icon("flame", 18))
                table.insert(right, hgap(5))
                table.insert(right, text(r.streak .. " " .. _("in a row") .. " · ", { size = 20 }))
            end
            table.insert(right, text(stats, { size = 20, color = MID }))
            local hh = text(r.name, { style = "bold", size = 26 }):getSize().h
            local head = OverlapGroup:new{ dimen = Geom:new{ w = CW, h = hh },
                cell(text(r.name, { style = "bold", size = 26, width = CW - right:getSize().w - px(16) }), CW, "left", hh),
                cell(right, CW, "right", hh) }
            local g = VerticalGroup:new{ align = "left", head, vgap(8),
                HabitGrid:new{ ndays = hb.ndays, day = hb.day, days = r.days, width = CW } }
            if i == 1 then
                table.insert(g, vgap(4))
                table.insert(g, DayNums:new{ ndays = hb.ndays, width = CW })
            end
            rows[#rows + 1] = row(g, function() dash:toggleHabit(r, not done_today) end, 30)
        end
        if #(hb.rows or {}) > 0 then rows[#rows + 1] = note(_("Tap a habit to tick or untick today.")) end
        return rows
    end,
}

Pages.quote = {
    title = function() return _("Quote") end,
    body = function(dash, d)
        local rows = {}
        local q, w = d.quote, d.word
        if q then
            rows[#rows + 1] = pad(icon("quote", 40, MID), 24, 18)
            rows[#rows + 1] = para(q.text, { style = "italic", size = 40, line_height = 0.25 })
            rows[#rows + 1] = pad(text("— " .. (q.author or ""), { size = 24, color = MID }), 28, 0)
        end
        if w then
            rows[#rows + 1] = rule("thick", 70, 44)
            rows[#rows + 1] = text(_("Word of the day"), { size = 20, color = MID })
            rows[#rows + 1] = vgap(12)
            rows[#rows + 1] = baseline(text(w.word, { style = "display", size = 48 }), hgap(14),
                                       text(w.kind or "", { style = "italic", size = 24, color = MID }))
            rows[#rows + 1] = vgap(22)
            rows[#rows + 1] = para(w.meaning, { size = 26, line_height = 0.3 })
            rows[#rows + 1] = vgap(18)
            rows[#rows + 1] = para(w.example, { style = "italic", size = 24, color = MID, line_height = 0.3 })
        end
        if not q and not w then rows[#rows + 1] = note(_("No quote or word yet.")) end
        return rows
    end,
}

local TITLES = { photo = _("Photo"), empty = _("Dashboard") }

-- ---------------------------------------------------------- the dashboard ---
local Dash = InputContainer:extend{ covers_fullscreen = true, idx = 1 }

function Dash:init()
    layout()
    util.makePath(CACHE)
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } } }
    self.data = decode(readFile(CACHE .. "/data.json"))
    self[1] = self:view()
end

function Dash:pages()
    return self.data and self.data.pages or {}
end

function Dash:rebuild(mode)
    self[1]:free()
    self[1] = self:view()
    UIManager:setDirty(self, mode or "ui")
end

-- Title (h1: 56 px, extra bold) or the page's masthead, with icon buttons on the right
function Dash:header(page)
    local def = Pages[page.name]
    local btns = HorizontalGroup:new{ align = "center" }
    if self.busy then
        table.insert(btns, text(self.busy, { style = "italic", size = 20, color = MID }))
        table.insert(btns, hgap(12))
    else
        if def and def.add_button then
            table.insert(btns, iconButton("plus", function() self:askTodo() end))
        end
        table.insert(btns, iconButton("refresh", function() self:refresh(true) end))
    end
    table.insert(btns, iconButton("close", function() self:onClose() end))
    btns = FrameContainer:new{ bordersize = 0, padding = 0, padding_right = 0, btns }
    btns.overlap_align = "right"
    local bw = btns:getSize().w
    local left
    if def and def.masthead then
        left = def.masthead(page.data or {}, self.data, CW - bw)
    else
        local title, sub = TITLES[page.name] or page.name, nil
        if def and def.title then title, sub = def.title(page.data or {}, self.data) end
        local t = text(title, { style = "display", size = 56, width = CW - bw - px(10) })
        left = t
        local room = CW - bw - t:getSize().w - px(24)
        if sub and room > px(40) then
            left = baseline(t, hgap(12), text(sub, { size = 26, color = MID, width = room }))
        end
    end
    local hh = math.max(left:getSize().h, btns:getSize().h)
    -- pull the icons up so they sit level with the title's cap height
    return OverlapGroup:new{ dimen = Geom:new{ w = CW + px(12), h = hh }, left, btns }
end

-- base.html footer: 1 px grey line, "Updated HH:MM" left, page dots right
function Dash:footer()
    local pages = self:pages()
    local updated = self.data and self.data.updated and self.data.updated:match("T(%d%d:%d%d)")
    local label = text(updated and (_("Updated") .. " " .. updated) or _("Not updated yet"),
                       { size = 20, color = MID, width = math.floor(CW * 0.5) })
    local dots = PageDots:new{ n = math.max(#pages, 1), cur = self.idx }
    local fh = math.max(label:getSize().h, dots:getSize().h)
    return VerticalGroup:new{ align = "left",
        LineWidget:new{ dimen = Geom:new{ w = CW, h = 1 }, background = FAINT },
        vgap(12),
        OverlapGroup:new{ dimen = Geom:new{ w = CW, h = fh },
            cell(label, CW, "left", fh), cell(dots, CW, "right", fh) } }
end

function Dash:view()
    local pages = self:pages()
    if self.idx > #pages then self.idx = 1 end
    local page = pages[self.idx] or { name = "empty", data = {} }
    -- The photo is the render's dithered PNG, shown full screen
    if page.name == "photo" and lfs.attributes(CACHE .. "/photo.png", "mode") == "file" then
        return FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, background = PAPER,
            width = W, height = H,
            CenterContainer:new{ dimen = Geom:new{ w = W, h = H },
                ImageWidget:new{ file = CACHE .. "/photo.png", file_do_cache = false,
                                 width = W, height = H, scale_factor = 0 } } }
    end
    local top, bottom = px(44), px(30)          -- base.html body padding and footer offset
    local hdr, ftr = self:header(page), self:footer()
    local gap = (Pages[page.name] or {}).masthead and 0 or px(26)
    local body_h = H - top - hdr:getSize().h - gap - ftr:getSize().h - bottom - px(12)
    local rows
    if #pages == 0 then
        local msg = _("No data yet. Tap refresh at the top right.")
        if not getRepo() then
            msg = _("No GitHub repo set. Set it in Tools > Dashboard (kdash) > Set GitHub repo.")
        elseif not getToken() then
            msg = _("No GitHub token set. Set it in Tools > Dashboard (kdash) > Set GitHub token.")
        end
        rows = { note(msg) }
    elseif Pages[page.name] then
        local ok, r = pcall(Pages[page.name].body, self, page.data or {}, body_h, self.data)
        rows = ok and r or { note(_("Couldn't draw this page: ") .. tostring(r)) }
        if not ok then logger.warn("kdash: page", page.name, r) end
    else
        rows = { note(_("This page isn't drawn here yet.")) }
    end
    local function indent(w)
        return FrameContainer:new{ bordersize = 0, padding = 0, padding_left = M, w }
    end
    return FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, background = PAPER,
        width = W, height = H,
        VerticalGroup:new{ align = "left",
            VerticalSpan:new{ width = top },
            indent(hdr),
            VerticalSpan:new{ width = gap },
            indent(box(stack(rows, body_h), CW, body_h)),
            VerticalSpan:new{ width = px(12) },
            indent(ftr) } }
end

function Dash:go(delta)
    local n = #self:pages()
    if n == 0 then return end
    self.idx = (self.idx - 1 + delta) % n + 1
    self:rebuild("flashui")              -- flash to clear e-ink ghosting from the last page
end

function Dash:onSwipe(arg, ges)
    if ges.direction == "west" then
        self:go(1)
    elseif ges.direction == "east" then
        self:go(-1)
    elseif ges.direction == "south" then
        self:onClose()
    end
    return true
end

function Dash:onClose()
    self.closed = true
    if self.poll then UIManager:unschedule(self.poll) end
    if self.timer then UIManager:unschedule(self.timer) end
    self:unscheduleWake()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    return true
end

function Dash:setBusy(s)
    self.busy = s
    self:rebuild("ui")
    UIManager:forceRePaint()             -- show it before the network call blocks
end

-- Minutes since data.json was last downloaded
function Dash:ageMin()
    local t = lfs.attributes(CACHE .. "/data.json", "modification")
    return t and (os.time() - t) / 60 or math.huge
end

-- Fetch data.json (and the photo). render=true first asks GitHub to render fresh data.
function Dash:refresh(render)
    if self.busy then return end
    local function go()
        if self.closed then return end
        if not render then return self:download() end
        self:setBusy(_("Starting render…"))
        local before = outSha()
        local ok, err = api("POST", "actions/workflows/" .. WORKFLOW .. "/dispatches", JSON,
                            rapidjson.encode({ ref = MAIN_BRANCH }))
        if not ok then
            toast(_("Couldn't start a render: ") .. err)
            return self:download()
        end
        self:waitForRender(before)
    end
    -- A timed wake turns Wi-Fi on without asking; nobody is there to answer
    if self.timed_wake then NetworkMgr:turnOnWifiAndWaitForConnection(go) else NetworkMgr:runWhenOnline(go) end
end

function Dash:waitForRender(before)
    self:setBusy(_("Rendering…"))
    local started = os.time()
    local function poll()
        if self.closed then return end
        local sha = outSha()
        if sha and sha ~= before then return self:download() end
        if os.time() - started >= RENDER_WAIT then
            toast(_("The render took too long; showing the last one."))
            return self:download()
        end
        UIManager:scheduleIn(POLL_EVERY, poll)
    end
    self.poll = poll
    UIManager:scheduleIn(POLL_EVERY, poll)
end

function Dash:download()
    self:setBusy(_("Downloading…"))
    local body, err = api("GET", "contents/data.json?ref=" .. OUT_BRANCH, RAW)
    local d = body and decode(body)
    if not d then
        self.busy = nil
        self:rebuild("ui")
        toast(_("Download failed: ") .. (err or _("data.json is not valid (render not updated yet?)")))
        return self:timedWakeDone()
    end
    writeFile(CACHE .. "/data.json", body)
    for __, p in ipairs(d.pages or {}) do
        if p.name == "photo" and p.png then
            local img = api("GET", "contents/" .. p.png .. "?ref=" .. OUT_BRANCH, RAW)
            if img then writeFile(CACHE .. "/photo.png", img) end
        end
    end
    self.data, self.busy = d, nil
    self:rebuild("full")
    self:timedWakeDone()
end

-- Refresh every STALE_MIN while open, and after waking if the data is old
function Dash:startTimer()
    self.timer = function()
        if self.closed then return end
        self:refresh(true)
        UIManager:scheduleIn(STALE_MIN * 60, self.timer)
    end
    UIManager:scheduleIn(STALE_MIN * 60, self.timer)
end

function Dash:onResume()
    if self.closed then return end
    if self.timed_wake then
        UIManager:scheduleIn(2, function() self:refresh(true) end)
        -- Sleep again even if the refresh hangs
        self.wake_guard = function() self:timedWakeDone() end
        UIManager:scheduleIn(RENDER_WAIT + 60, self.wake_guard)
    elseif self:ageMin() >= STALE_MIN then
        UIManager:scheduleIn(2, function() self:refresh(true) end)   -- let Wi-Fi come back first
    end
end

-- Timed refresh: KOReader's WakeupMgr sets the Kindle's RTC alarm when it goes to
-- sleep. On that alarm we wake the Kindle fully (powerd's wakeUp), onResume
-- refreshes, and timedWakeDone puts it back to sleep with the new data on screen.
function Dash:scheduleWake()
    local mgr = Device.wakeup_mgr
    if not mgr then return end
    self:unscheduleWake()
    local secs = secondsToNextWake()
    if not secs then return end
    self.wake_task = function() self:onTimedWake() end
    mgr:addTask(secs, self.wake_task)
    logger.info("kdash: next timed refresh in", secs, "s, at", os.date("%a %H:%M", os.time() + secs))
end

function Dash:unscheduleWake()
    if self.wake_task and Device.wakeup_mgr then Device.wakeup_mgr:removeTasks(nil, self.wake_task) end
    self.wake_task = nil
end

function Dash:onTimedWake()
    logger.info("kdash: timed wake")
    -- WakeupMgr removes the task that is running; don't remove it here, just add the next
    self.wake_task = nil
    self:scheduleWake()
    if self.closed then return end
    self.timed_wake = true
    local lipc = Device.powerd and Device.powerd.lipc_handle
    local ok = lipc and pcall(lipc.set_int_property, lipc, "com.lab126.powerd", "wakeUp", 1)
    if not ok then                   -- no powerd: refresh as we are, then sleep
        logger.warn("kdash: couldn't wake the Kindle via powerd; refreshing in the screensaver")
        self:onResume()
    end
end

function Dash:timedWakeDone()
    if not self.timed_wake then return end
    self.timed_wake = nil
    if self.wake_guard then UIManager:unschedule(self.wake_guard) end
    logger.info("kdash: timed refresh done, sleeping")
    UIManager:scheduleIn(3, function() UIManager:suspend() end)   -- let the e-ink finish drawing
end

-- Same to-do on every page (today's list and the full list)
function Dash:eachTodo(text_, fn)
    for __, p in ipairs(self:pages()) do
        for __, key in ipairs({ "todos", "open_todos" }) do
            for __, t in ipairs((p.data or {})[key] or {}) do
                if t.text == text_ then fn(t) end
            end
        end
    end
end

-- Run an edit of a repo file in the background of an already-updated screen
function Dash:commit(path, fn, message, undo)
    NetworkMgr:runWhenOnline(function()
        local ok, err = editRepoFile(path, fn, message)
        if not ok then
            undo()
            self:rebuild("ui")
            toast(_("Not saved: ") .. tostring(err))
        end
    end)
end

function Dash:toggleTodo(t)
    local done = not t.done
    self:eachTodo(t.text, function(x) x.done = done end)
    self:rebuild("ui")
    UIManager:forceRePaint()
    self:commit("data/todos.md", function(md) return setTodo(md, t.text, done) end,
        (done and "Tick" or "Untick") .. " to-do from the Kindle: " .. t.text,
        function() self:eachTodo(t.text, function(x) x.done = not done end) end)
end

function Dash:askDeleteTodo(t)
    UIManager:show(ConfirmBox:new{
        text = _("Delete this to-do?") .. "\n\n" .. t.text,
        ok_text = _("Delete"),
        ok_callback = function() self:deleteTodo(t) end,
    })
end

-- Remove the to-do from every list on screen, commit, and put it back if that fails
function Dash:deleteTodo(t)
    local removed = {}
    for __, p in ipairs(self:pages()) do
        for __, key in ipairs({ "todos", "open_todos" }) do
            local l = (p.data or {})[key]
            for i = #(l or {}), 1, -1 do
                if l[i].text == t.text then
                    removed[#removed + 1] = { l, i, table.remove(l, i) }
                end
            end
        end
    end
    self:rebuild("ui")
    UIManager:forceRePaint()
    self:commit("data/todos.md", function(md) return deleteTodo(md, t.text) end,
        "Delete to-do from the Kindle: " .. t.text,
        function()
            for k = #removed, 1, -1 do table.insert(removed[k][1], removed[k][2], removed[k][3]) end
        end)
end

function Dash:askTodo()
    local dlg
    dlg = InputDialog:new{
        title = _("New to-do"),
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Add"), is_enter_default = true, callback = function()
                local s = trim(dlg:getInputText() or ""):gsub("\n", " ")
                UIManager:close(dlg)
                if s ~= "" then self:addTodo(s) end
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function Dash:addTodo(s)
    local item = { text = s, done = false }
    local lists = {}
    for __, p in ipairs(self:pages()) do
        for __, key in ipairs({ "todos", "open_todos" }) do
            local l = (p.data or {})[key]
            if l then
                table.insert(l, 1, { text = s, done = false })
                lists[#lists + 1] = l
            end
        end
    end
    self:rebuild("ui")
    UIManager:forceRePaint()
    self:commit("data/todos.md", function(md) return addTodo(md, item.text) end,
        "Add to-do from the Kindle: " .. s,
        function() for __, l in ipairs(lists) do table.remove(l, 1) end end)
end

function Dash:toggleHabit(r, on)
    local hb
    for __, p in ipairs(self:pages()) do
        if p.name == "habits" then hb = p.data.habits end
    end
    if not hb or not self.data.today then return end
    local old = r.days
    local days = {}
    for __, x in ipairs(old) do if x ~= hb.day then days[#days + 1] = x end end
    if on then days[#days + 1] = hb.day end
    table.sort(days)
    r.days = days
    habitStats(r, hb.day)
    self:rebuild("ui")
    UIManager:forceRePaint()
    local names = {}
    for __, x in ipairs(hb.rows) do names[#names + 1] = x.name end
    local ym = self.data.today:sub(1, 7)
    self:commit("data/habits.md", function(md) return setHabit(md, ym, names, r.name, hb.day, on) end,
        (on and "Tick " or "Untick ") .. r.name .. " from the Kindle",
        function() r.days = old; habitStats(r, hb.day) end)
end

-- -------------------------------------------------------------- the plugin ---
local Kdash = WidgetContainer:extend{ name = "kdash", is_doc_only = false }

function Kdash:init()
    layout()                         -- toasts and dialogs from the menu need the sizes too
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Kdash:onDispatcherRegisterActions()
    Dispatcher:registerAction("kdash_show", { category = "none", event = "ShowKdash",
                                              title = _("Dashboard (kdash)"), general = true })
end

function Kdash:addToMainMenu(menu_items)
    menu_items.kdash = {
        text = _("Dashboard (kdash)"),
        sorting_hint = "tools",
        sub_item_table = {
            { text = _("Open dashboard"), callback = function() self:onShowKdash() end },
            { text = _("Set GitHub repo"), keep_menu_open = true, callback = function()
                self:ask("kdash_repo", _("GitHub repo"), _("owner/name of the repo whose render publishes data.json to its \"out\" branch. Used instead of ") .. REPO_FILE .. ".")
            end },
            { text = _("Set GitHub token"), keep_menu_open = true, callback = function()
                self:ask("kdash_token", _("GitHub token"), _("Fine-grained token for that repo only: Contents and Actions, read and write. Used instead of ") .. TOKEN_FILE .. ".")
            end },
            { text = _("Timed refresh"), keep_menu_open = true, callback = function()
                self:ask("kdash_wake_times", _("Timed refresh"), _("While the dashboard is open and the Kindle sleeps, it wakes at these times, refreshes and sleeps again. Hours or HH:MM, comma separated, e.g. 7, 12, 17, 21:30. Empty turns it off."), wakeSetting())
            end },
            { text = _("Update plugin"), callback = function() self:update() end },
        },
    }
end

function Kdash:onShowKdash()
    local dash = Dash:new{}
    UIManager:show(dash)
    dash:startTimer()
    dash:scheduleWake()
    if dash:ageMin() >= STALE_MIN then
        UIManager:scheduleIn(0.5, function() dash:refresh(true) end)
    end
    return true
end

-- Download the latest plugin files, check they compile, replace them, then
-- offer a restart. Nothing is written unless every file downloaded fine.
function Kdash:update()
    NetworkMgr:runWhenOnline(function()
        toast(_("Checking for an update…"))
        UIManager:forceRePaint()
        local dir = self.path or (DataStorage:getDataDir() .. "/plugins/kdash.koplugin")
        local files, changed = {}, false
        for __, name in ipairs({ "_meta.lua", "main.lua" }) do
            local sink = {}
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
            local code = socket.skip(1, http.request{ url = PLUGIN_URL .. name, headers = { ["User-Agent"] = "kdash" },
                                                      sink = ltn12.sink.table(sink) })
            socketutil:reset_timeout()
            local body = table.concat(sink)
            if code ~= 200 then
                return info(_("Update failed: ") .. name .. " " .. tostring(code or _("no connection")))
            end
            local ok, err = loadstring(body, name)
            if not ok then return info(_("Update failed: the new ") .. name .. _(" doesn't load: ") .. tostring(err)) end
            files[name] = body
            if body ~= readFile(dir .. "/" .. name) then changed = true end
        end
        if not changed then return info(_("kdash is up to date.")) end
        for name, body in pairs(files) do
            local path = dir .. "/" .. name
            if not writeFile(path, body) then
                return info(_("Update failed: couldn't write ") .. path)
            end
        end
        logger.info("kdash: plugin updated from", PLUGIN_URL)
        UIManager:askForRestart(_("kdash was updated. Restart KOReader to use the new version."))
    end)
end

function Kdash:ask(key, title, description, default)
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = G_reader_settings:readSetting(key) or default or "",
        description = description,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dlg) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                G_reader_settings:saveSetting(key, trim(dlg:getInputText() or ""))
                UIManager:close(dlg)
                toast(_("Saved."))
            end },
        } },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

return Kdash
