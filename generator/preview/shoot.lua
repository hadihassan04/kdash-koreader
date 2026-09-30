-- KOReader user patch: open the kdash dashboard, save a screenshot of every
-- page to $KDASH_SHOTS/page-N.png plus pages.json, then quit. preview.sh
-- installs it; it is not for use on a device.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Event = require("ui/event")
local out = os.getenv("KDASH_SHOTS")

local function dash()                 -- the dashboard, wherever it is in the window stack
    for i = #UIManager._window_stack, 1, -1 do
        local w = UIManager._window_stack[i].widget
        if w and w.pages and w.rebuild then return w end
    end
end

UIManager:scheduleIn(1, function() UIManager:broadcastEvent(Event:new("ShowKdash")) end)
UIManager:scheduleIn(4, function()
    local d = dash()
    if not d then io.stderr:write("kdash-shoot: no dashboard open\n") end
    local pages = d and d.pages and d:pages() or {}
    local names = {}
    local function shot(i)
        if i > #pages then
            local f = io.open(out .. "/pages.json", "w")
            f:write('{"pages":[' .. table.concat(names, ",") .. ']}\n')
            f:close()
            return UIManager:quit()
        end
        d.idx = i
        d:rebuild("full")
        UIManager:scheduleIn(0.5, function()
            UIManager:forceRePaint()
            Screen:shot(out .. "/page-" .. i .. ".png")
            names[#names + 1] = string.format('{"name":"%s","file":"page-%d.png"}', pages[i].name, i)
            shot(i + 1)
        end)
    end
    if #pages == 0 then return UIManager:quit() end
    shot(1)
end)
UIManager:scheduleIn(120, function() UIManager:quit() end)   -- never hang the workflow
