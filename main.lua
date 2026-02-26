local CheckButton = require("ui/widget/checkbutton")
local ConfirmBox = require("ui/widget/confirmbox")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InputDialog = require("ui/widget/inputdialog")
local _ = require("gettext")
local T = require("ffi/util").template

local ReadingGoal = WidgetContainer:extend{
    name = "reading_goal",

    goal_type = nil,
    goal_percentage = 0,
    goal_page = 0,
    goal_stable_page_idx = 0,
    last_goal_percentage = 0,

    start_percentage = 0,
    start_page = 0,
    start_stable_page_idx = 0,

    reminder_enabled = false,
    reminder_interval = 25,
    reminders_fired = {},

    goal_symbol = "\u{02691}",
    goal_letter = "G",
}

function ReadingGoal:onDispatcherRegisterActions()
    Dispatcher:registerAction("show_goal", {
        category = "none", event = "ShowGoal",
        title = _("Set reading goal"), general = true
    })
    Dispatcher:registerAction("stop_goal", {
        category = "none", event = "StopGoal",
        title = _("Stop reading goal"), general = true, separator = true
    })
end

function ReadingGoal:init()
    self:onDispatcherRegisterActions()
    self.settings = G_reader_settings:readSetting("reading_goal_settings", {})

    self:_repositionInMenu()

    self.additional_header_content_func = function()
        local txt = self:_statusBarText()
        if txt then return self.goal_symbol .. " " .. txt end
    end
    self.additional_footer_content_func = function()
        local txt = self:_statusBarText()
        if not txt then return end
        local item_prefix = self.ui.view and self.ui.view.footer.settings.item_prefix or "letters"
        if item_prefix == "icons" then
            return self.goal_symbol .. " " .. txt
        elseif item_prefix == "compact_items" then
            return self.goal_symbol .. txt
        else
            return self.goal_letter .. ": " .. txt
        end
    end

    if self.settings.show_value_in_header then self:addAdditionalHeaderContent() end
    if self.settings.show_value_in_footer then self:addAdditionalFooterContent() end

    self.ui.menu:registerToMainMenu(self)
    self:_loadGoalFromDoc()
end

function ReadingGoal:onReaderReady()
    self:_loadGoalFromDoc()
    self:_initGlobalTrackingForBook()
    return false
end

function ReadingGoal:_repositionInMenu()
    local function inject(order_path)
        local ok, order = pcall(require, order_path)
        if not ok or not order or not order.tools then return end
        for _, v in ipairs(order.tools) do
            if v == "reading_goal" then return end
        end
        for i, v in ipairs(order.tools) do
            if v == "read_timer" then
                table.insert(order.tools, i + 1, "reading_goal")
                return
            end
        end
    end
    inject("ui/elements/reader_menu_order")
    inject("ui/elements/filemanager_menu_order")
end

function ReadingGoal:_statusBarText()
    if self:goalActive() then
        return self:remainingProgress()
    end
    local dw = self:_getActiveDailyWeekly()
    if dw then
        local read = self:_getDailyWeeklyRead(dw)
        local effective = dw.target_pages + (dw.deficit or 0)
        if dw.mode == "weekly" then
            return string.format("%d/%d wk", read, effective)
        else
            return string.format("%d/%d today", read, effective)
        end
    end
    return nil
end

function ReadingGoal:addAdditionalHeaderContent()
    if self.ui and self.ui.crelistener then
        self.ui.crelistener:addAdditionalHeaderContent(self.additional_header_content_func)
        self:update_status_bars(-1)
    end
end

function ReadingGoal:addAdditionalFooterContent()
    if self.ui and self.ui.view and self.ui.view.footer then
        self.ui.view.footer:addAdditionalFooterContent(self.additional_footer_content_func)
        self:update_status_bars(-1)
    end
end

function ReadingGoal:removeAdditionalHeaderContent()
    if self.ui and self.ui.crelistener then
        self.ui.crelistener:removeAdditionalHeaderContent(self.additional_header_content_func)
        self:update_status_bars(-1)
        UIManager:broadcastEvent(Event:new("UpdateHeader"))
    end
end

function ReadingGoal:removeAdditionalFooterContent()
    if self.ui and self.ui.view and self.ui.view.footer then
        self.ui.view.footer:removeAdditionalFooterContent(self.additional_footer_content_func)
        self:update_status_bars(-1)
        UIManager:broadcastEvent(Event:new("UpdateFooter", true))
    end
end

function ReadingGoal:update_status_bars(seconds)
    if self.settings.show_value_in_header then
        UIManager:broadcastEvent(Event:new("UpdateHeader"))
    end
    if self.settings.show_value_in_footer then
        UIManager:broadcastEvent(Event:new("RefreshAdditionalContent"))
    end
    if seconds and seconds >= 0 then
        UIManager:scheduleIn(math.max(math.floor(seconds) % 60, 0.001), self.update_status_bars, self)
    else
        UIManager:scheduleIn(60, self.update_status_bars, self)
    end
end

function ReadingGoal:_hasStablePages()
    return self.ui.pagemap
        and self.ui.pagemap.wantsPageLabels
        and self.ui.pagemap:wantsPageLabels()
end

function ReadingGoal:_getPages()
    if not self.ui then return nil, nil, nil, nil, nil end
    local curr, total
    if self.ui.getCurrentPage then
        local ok, v = pcall(function() return self.ui:getCurrentPage() end)
        if ok and type(v) == "number" and v > 0 then curr = v end
    end
    if (not curr) and self.ui.document and self.ui.document.getCurrentPage then
        local ok, v = pcall(function() return self.ui.document:getCurrentPage() end)
        if ok and type(v) == "number" and v > 0 then curr = v end
    end
    if self.ui.document and self.ui.document.getPageCount then
        local ok, v = pcall(function() return self.ui.document:getPageCount() end)
        if ok and type(v) == "number" and v > 0 then total = v end
    end
    local stable_label, stable_idx, stable_count
    if self:_hasStablePages() then
        local ok, l, i, c = pcall(function()
            return self.ui.pagemap:getCurrentPageLabel(true)
        end)
        if ok then
            stable_label, stable_idx, stable_count = l, i, c
        end
    end
    return curr, total, stable_label, stable_idx, stable_count
end

function ReadingGoal:currentProgress()
    local curr, total = self:_getPages()
    if not curr or not total or total == 0 then return 0 end
    return (curr / total) * 100
end

function ReadingGoal:goalActive()
    return self.goal_percentage > 0 or self.goal_page > 0 or self.goal_stable_page_idx > 0
end

function ReadingGoal:remainingProgress()
    if not self:goalActive() then return "" end
    local curr, total, _sl, stable_idx, _sc = self:_getPages()

    if self.goal_type == "percentage" then
        if not (curr and total and total > 0) then return _("Calculating…") end
        local remaining = self.goal_percentage - (curr / total) * 100
        return string.format("%.0f%% left", math.max(remaining, 0))
    elseif self.goal_type == "stable_page" then
        if not stable_idx then return _("Calculating…") end
        local remaining = self.goal_stable_page_idx - stable_idx
        return string.format("%d sp left", math.max(remaining, 0))
    else
        if not curr then return _("Calculating…") end
        local remaining = self.goal_page - curr
        return string.format("%d pg left", math.max(remaining, 0))
    end
end

function ReadingGoal:_computeGoalProgress()
    local curr, total, _sl, stable_idx, _sc = self:_getPages()
    if self.goal_type == "percentage" then
        if not (curr and total and total > 0) then return 0 end
        local curr_pct = (curr / total) * 100
        local span = self.goal_percentage - self.start_percentage
        if span <= 0 then return 100 end
        return math.min(100, ((curr_pct - self.start_percentage) / span) * 100)
    elseif self.goal_type == "page" then
        if not curr then return 0 end
        local span = self.goal_page - self.start_page
        if span <= 0 then return 100 end
        return math.min(100, ((curr - self.start_page) / span) * 100)
    elseif self.goal_type == "stable_page" then
        if not stable_idx then return 0 end
        local span = self.goal_stable_page_idx - self.start_stable_page_idx
        if span <= 0 then return 100 end
        return math.min(100, ((stable_idx - self.start_stable_page_idx) / span) * 100)
    end
    return 0
end

function ReadingGoal:_checkReminders()
    if not self.reminder_enabled or not self.reminder_interval then return end
    if self.reminder_interval <= 0 then return end

    local progress = self:_computeGoalProgress()
    local milestone_count = math.floor(progress / self.reminder_interval)

    for i = 1, milestone_count do
        if not self.reminders_fired[i] then
            self.reminders_fired[i] = true
            local pct_of_goal = i * self.reminder_interval
            if pct_of_goal < 100 then
                UIManager:show(InfoMessage:new{
                    text = T(_("Goal progress: %1%"), pct_of_goal),
                    timeout = 5,
                })
            end
            self:_persistGoalToDoc()
        end
    end
end

function ReadingGoal:_maybeFireGoal()
    if not self:goalActive() then
        self:_trackPages()
        return false
    end
    local curr, total, _sl, stable_idx, _sc = self:_getPages()
    self:_trackPages()
    self:_checkReminders()

    local reached = false
    if self.goal_type == "percentage" then
        if curr and total and total > 0 then
            reached = (curr / total) * 100 >= self.goal_percentage
        end
    elseif self.goal_type == "stable_page" then
        if stable_idx then
            reached = stable_idx >= self.goal_stable_page_idx
        end
    else
        if curr then
            reached = curr >= self.goal_page
        end
    end

    if reached then
        self:goal_callback()
        return true
    end
    self:update_status_bars()
    return false
end

function ReadingGoal:checkGoal()
    if not self:goalActive() then return end
    local curr, total, _sl, stable_idx, _sc = self:_getPages()
    self:_checkReminders()

    local reached = false
    if self.goal_type == "percentage" then
        if curr and total and total > 0 then
            reached = (curr / total) * 100 >= self.goal_percentage
        end
    elseif self.goal_type == "stable_page" then
        if stable_idx then
            reached = stable_idx >= self.goal_stable_page_idx
        end
    else
        if curr then
            reached = curr >= self.goal_page
        end
    end

    if reached then
        self:goal_callback()
    else
        UIManager:scheduleIn(30, self.checkGoal, self)
    end
end

function ReadingGoal:setGoal(value, goal_type)
    local curr, total, _sl, stable_idx, _sc = self:_getPages()

    self.goal_type = goal_type
    self.reminder_enabled = false
    self.reminders_fired = {}

    if goal_type == "percentage" then
        self.goal_percentage = value
        self.goal_page = 0
        self.goal_stable_page_idx = 0
        self.last_goal_percentage = value
        self.start_percentage = (curr and total and total > 0) and (curr / total) * 100 or 0
        self.start_page = 0
        self.start_stable_page_idx = 0
    elseif goal_type == "stable_page" then
        self.goal_percentage = 0
        self.goal_page = 0
        self.goal_stable_page_idx = value
        self.last_goal_percentage = 0
        self.start_percentage = 0
        self.start_page = 0
        self.start_stable_page_idx = stable_idx or 0
    else
        self.goal_percentage = 0
        self.goal_page = value
        self.goal_stable_page_idx = 0
        self.last_goal_percentage = 0
        self.start_percentage = 0
        self.start_page = curr or 0
        self.start_stable_page_idx = 0
    end

    self:_persistGoalToDoc()
    self:update_status_bars()
    UIManager:show(InfoMessage:new{
        text = T(_("Goal set: %1"), self:remainingProgress()),
        timeout = 5,
    })
    UIManager:scheduleIn(30, self.checkGoal, self)
end

function ReadingGoal:setGoalWithReminder(value, goal_type, reminder_interval)
    self:setGoal(value, goal_type)
    if reminder_interval and reminder_interval > 0 then
        self.reminder_enabled = true
        self.reminder_interval = reminder_interval
        self.reminders_fired = {}
        self:_persistGoalToDoc()
    end
end

function ReadingGoal:unscheduleGoal()
    self.goal_type = nil
    self.goal_percentage = 0
    self.goal_page = 0
    self.goal_stable_page_idx = 0
    self.last_goal_percentage = 0
    self.start_percentage = 0
    self.start_page = 0
    self.start_stable_page_idx = 0
    self.reminder_enabled = false
    self.reminders_fired = {}
    UIManager:unschedule(self.checkGoal, self)
    self:_persistGoalToDoc()
    self:update_status_bars()
end

function ReadingGoal:_persistGoalToDoc()
    if not (self.ui and self.ui.doc_settings) then return end
    local existing = self.ui.doc_settings:readSetting("reading_goal") or {}

    if self:goalActive() then
        existing.goal_type = self.goal_type
        existing.goal_percentage = self.goal_percentage
        existing.goal_page = self.goal_page
        existing.goal_stable_page_idx = self.goal_stable_page_idx
        existing.last_goal_percentage = self.last_goal_percentage
        existing.start_percentage = self.start_percentage
        existing.start_page = self.start_page
        existing.start_stable_page_idx = self.start_stable_page_idx
        existing.reminder_enabled = self.reminder_enabled
        existing.reminder_interval = self.reminder_interval
        existing.reminders_fired = self.reminders_fired
        self.ui.doc_settings:saveSetting("reading_goal", existing)
    else
        existing.goal_type = nil
        existing.goal_percentage = nil
        existing.goal_page = nil
        existing.goal_stable_page_idx = nil
        existing.last_goal_percentage = nil
        existing.start_percentage = nil
        existing.start_page = nil
        existing.start_stable_page_idx = nil
        existing.reminder_enabled = nil
        existing.reminder_interval = nil
        existing.reminders_fired = nil
        if not existing.daily_weekly then
            if self.ui.doc_settings.delSetting then
                self.ui.doc_settings:delSetting("reading_goal")
            else
                self.ui.doc_settings:saveSetting("reading_goal", nil)
            end
        else
            self.ui.doc_settings:saveSetting("reading_goal", existing)
        end
    end
end

function ReadingGoal:_loadGoalFromDoc()
    if not (self.ui and self.ui.doc_settings) then return end
    local data = self.ui.doc_settings:readSetting("reading_goal")
    if type(data) ~= "table" then
        self:_resetGoalState()
        return
    end

    UIManager:unschedule(self.checkGoal, self)

    if not data.goal_type then
        if data.use_percentage ~= false and data.goal_percentage and data.goal_percentage > 0 then
            data.goal_type = "percentage"
        elseif data.goal_page and data.goal_page > 0 then
            data.goal_type = "page"
        end
    end

    self.goal_type = data.goal_type
    self.goal_percentage = tonumber(data.goal_percentage) or 0
    self.goal_page = tonumber(data.goal_page) or 0
    self.goal_stable_page_idx = tonumber(data.goal_stable_page_idx) or 0
    self.last_goal_percentage = tonumber(data.last_goal_percentage) or 0
    self.start_percentage = tonumber(data.start_percentage) or 0
    self.start_page = tonumber(data.start_page) or 0
    self.start_stable_page_idx = tonumber(data.start_stable_page_idx) or 0
    self.reminder_enabled = data.reminder_enabled or false
    self.reminder_interval = tonumber(data.reminder_interval) or 25
    self.reminders_fired = data.reminders_fired or {}

    self.book_daily_weekly = data.daily_weekly

    if self:goalActive() then
        UIManager:scheduleIn(30, self.checkGoal, self)
        self:update_status_bars(-1)
    else
        self:update_status_bars()
    end
end

function ReadingGoal:_resetGoalState()
    self.goal_type = nil
    self.goal_percentage = 0
    self.goal_page = 0
    self.goal_stable_page_idx = 0
    self.last_goal_percentage = 0
    self.start_percentage = 0
    self.start_page = 0
    self.start_stable_page_idx = 0
    self.reminder_enabled = false
    self.reminders_fired = {}
    UIManager:unschedule(self.checkGoal, self)
end

function ReadingGoal:_today()
    return os.date("%Y-%m-%d")
end

function ReadingGoal:_getWeekStartDate()
    local t = os.date("*t")
    local days_since_monday = (t.wday - 2) % 7
    t.day = t.day - days_since_monday
    return os.date("%Y-%m-%d", os.time(t))
end

function ReadingGoal:_getActiveDailyWeekly()
    if self.book_daily_weekly and self.book_daily_weekly.target_pages
        and self.book_daily_weekly.target_pages > 0 then
        return self.book_daily_weekly
    end
    local gdw = self.settings.global_daily_weekly
    if gdw and gdw.target_pages and gdw.target_pages > 0 then
        return gdw
    end
    return nil
end

function ReadingGoal:_dailyWeeklyActive()
    return self:_getActiveDailyWeekly() ~= nil
end

function ReadingGoal:_getDailyWeeklyRead(dw)
    if not dw then return 0 end
    if dw.mode == "weekly" then
        local week_key = self:_getWeekStartDate()
        local log = dw.weekly_log or dw.tracking
        if log and log[week_key] then
            if log[week_key].pages_read then
                return log[week_key].pages_read
            elseif log[week_key].start_page and log[week_key].end_page then
                return math.max(0, log[week_key].end_page - log[week_key].start_page)
            end
        end
        return 0
    else
        local today = self:_today()
        local log = dw.daily_log or dw.tracking
        if log and log[today] then
            if log[today].pages_read then
                return log[today].pages_read
            elseif log[today].start_page and log[today].end_page then
                return math.max(0, log[today].end_page - log[today].start_page)
            end
        end
        return 0
    end
end

function ReadingGoal:_initGlobalTrackingForBook()
    local gdw = self.settings.global_daily_weekly
    if not gdw or not gdw.target_pages or gdw.target_pages <= 0 then return end
    local book_path = self.ui.document and self.ui.document.file
    if not book_path then return end
    gdw.last_known_pages = gdw.last_known_pages or {}
    local curr = self:_getPages()
    if curr then
        gdw.last_known_pages[book_path] = curr
    end
end

function ReadingGoal:_trackPages()
    self:_trackBookPages()
    self:_trackGlobalPages()
end

function ReadingGoal:_trackBookPages()
    if not self.book_daily_weekly or not self.book_daily_weekly.target_pages
        or self.book_daily_weekly.target_pages <= 0 then return end

    local curr = self:_getPages()
    if not curr then return end

    local dw = self.book_daily_weekly
    dw.tracking = dw.tracking or {}

    local key
    if dw.mode == "weekly" then
        key = self:_getWeekStartDate()
    else
        key = self:_today()
    end

    if not dw.tracking[key] then
        self:_computeBookDeficit(dw, key)
        dw.tracking[key] = { start_page = curr, end_page = curr }
    else
        if curr > (dw.tracking[key].end_page or 0) then
            dw.tracking[key].end_page = curr
        end
    end

    self:_persistDailyWeeklyToDoc()
end

function ReadingGoal:_trackGlobalPages()
    local gdw = self.settings.global_daily_weekly
    if not gdw or not gdw.target_pages or gdw.target_pages <= 0 then return end

    local curr = self:_getPages()
    if not curr then return end

    local book_path = self.ui.document and self.ui.document.file
    if not book_path then return end

    gdw.last_known_pages = gdw.last_known_pages or {}
    local last = gdw.last_known_pages[book_path]

    if last and curr > last then
        local delta = curr - last

        if gdw.mode == "weekly" then
            local week_key = self:_getWeekStartDate()
            gdw.weekly_log = gdw.weekly_log or {}
            if not gdw.weekly_log[week_key] then
                self:_computeGlobalWeeklyDeficit(gdw, week_key)
                gdw.weekly_log[week_key] = { pages_read = 0 }
            end
            gdw.weekly_log[week_key].pages_read = gdw.weekly_log[week_key].pages_read + delta
        else
            local today = self:_today()
            gdw.daily_log = gdw.daily_log or {}
            if not gdw.daily_log[today] then
                self:_computeGlobalDailyDeficit(gdw, today)
                gdw.daily_log[today] = { pages_read = 0 }
            end
            gdw.daily_log[today].pages_read = gdw.daily_log[today].pages_read + delta
        end
    end

    gdw.last_known_pages[book_path] = curr
    self:_pruneGlobalLogs(gdw)
end

function ReadingGoal:_computeBookDeficit(dw, current_key)
    dw.deficit = dw.deficit or 0
    local prev_key, prev_data
    for k, v in pairs(dw.tracking or {}) do
        if k < current_key and (not prev_key or k > prev_key) then
            prev_key = k
            prev_data = v
        end
    end
    if prev_data then
        local read = math.max(0, (prev_data.end_page or 0) - (prev_data.start_page or 0))
        local shortfall = (dw.target_pages or 0) - read
        if shortfall > 0 then
            dw.deficit = dw.deficit + shortfall
        end
    end
end

function ReadingGoal:_computeGlobalDailyDeficit(gdw, today)
    gdw.deficit = gdw.deficit or 0
    local prev_key, prev_data
    for k, v in pairs(gdw.daily_log or {}) do
        if k < today and (not prev_key or k > prev_key) then
            prev_key = k
            prev_data = v
        end
    end
    if prev_data then
        local shortfall = (gdw.target_pages or 0) - (prev_data.pages_read or 0)
        if shortfall > 0 then
            gdw.deficit = gdw.deficit + shortfall
        end
    end
end

function ReadingGoal:_computeGlobalWeeklyDeficit(gdw, week_key)
    gdw.deficit = gdw.deficit or 0
    local prev_key, prev_data
    for k, v in pairs(gdw.weekly_log or {}) do
        if k < week_key and (not prev_key or k > prev_key) then
            prev_key = k
            prev_data = v
        end
    end
    if prev_data then
        local shortfall = (gdw.target_pages or 0) - (prev_data.pages_read or 0)
        if shortfall > 0 then
            gdw.deficit = gdw.deficit + shortfall
        end
    end
end

function ReadingGoal:_pruneGlobalLogs(gdw)
    local cutoff_daily = os.date("%Y-%m-%d", os.time() - 30 * 86400)
    local cutoff_weekly = os.date("%Y-%m-%d", os.time() - 56 * 86400)
    if gdw.daily_log then
        for k in pairs(gdw.daily_log) do
            if k < cutoff_daily then gdw.daily_log[k] = nil end
        end
    end
    if gdw.weekly_log then
        for k in pairs(gdw.weekly_log) do
            if k < cutoff_weekly then gdw.weekly_log[k] = nil end
        end
    end
end

function ReadingGoal:_persistDailyWeeklyToDoc()
    if not (self.ui and self.ui.doc_settings) then return end
    local existing = self.ui.doc_settings:readSetting("reading_goal") or {}
    existing.daily_weekly = self.book_daily_weekly
    self.ui.doc_settings:saveSetting("reading_goal", existing)
end

function ReadingGoal:onGotoPage() return self:_maybeFireGoal() end
function ReadingGoal:onPosUpdate() return self:_maybeFireGoal() end
function ReadingGoal:onUpdatePos() return self:_maybeFireGoal() end

function ReadingGoal:addCheckboxes(widget)
    widget:addWidget(CheckButton:new{
        text = _("Show goal in alt status bar"),
        checked = self.settings.show_value_in_header,
        parent = widget,
        callback = function()
            self.settings.show_value_in_header = not self.settings.show_value_in_header or nil
            if self.settings.show_value_in_header then self:addAdditionalHeaderContent()
            else self:removeAdditionalHeaderContent() end
        end,
    })
    widget:addWidget(CheckButton:new{
        text = _("Show goal in status bar"),
        checked = self.settings.show_value_in_footer,
        parent = widget,
        callback = function()
            self.settings.show_value_in_footer = not self.settings.show_value_in_footer or nil
            if self.settings.show_value_in_footer then self:addAdditionalFooterContent()
            else self:removeAdditionalFooterContent() end
        end,
    })
end

function ReadingGoal:addToMainMenu(menu_items)
    menu_items.reading_goal = {
        sorting_hint = "tools",
        text = _("Reading goal"),
        checked_func = function() return self:goalActive() or self:_dailyWeeklyActive() end,
        sub_item_table = {
            {
                text_func = function()
                    local pct = self:currentProgress()
                    local cur = (pct and pct > 0) and string.format(" (current: %d%%)", math.floor(pct + 0.5)) or ""
                    return _("Set percentage goal") .. cur
                end,
                keep_menu_open = true,
                callback = function(tmi) self:_showAbsoluteGoalDialog("percentage", tmi) end,
            },
            {
                text_func = function()
                    local curr = self:_getPages()
                    local cur = (curr and curr > 0) and string.format(" (current: %d)", curr) or ""
                    return _("Set page goal") .. cur
                end,
                keep_menu_open = true,
                callback = function(tmi) self:_showAbsoluteGoalDialog("page", tmi) end,
            },
            {
                text_func = function()
                    if self:_hasStablePages() then
                        local _c, _t, _sl, idx = self:_getPages()
                        local cur = idx and string.format(" (current: %d)", idx) or ""
                        return _("Set stable page goal") .. cur
                    else
                        return _("Set stable page goal (N/A)")
                    end
                end,
                enabled_func = function() return self:_hasStablePages() end,
                keep_menu_open = true,
                callback = function(tmi) self:_showAbsoluteGoalDialog("stable_page", tmi) end,
                separator = true,
            },
            {
                text = _("Read X% more"),
                keep_menu_open = true,
                callback = function(tmi) self:_showRelativeGoalDialog("percentage", tmi) end,
            },
            {
                text = _("Read X more pages"),
                keep_menu_open = true,
                callback = function(tmi) self:_showRelativeGoalDialog("page", tmi) end,
            },
            {
                text_func = function()
                    if self:_hasStablePages() then
                        return _("Read X more stable pages")
                    else
                        return _("Read X more stable pages (N/A)")
                    end
                end,
                enabled_func = function() return self:_hasStablePages() end,
                keep_menu_open = true,
                callback = function(tmi) self:_showRelativeGoalDialog("stable_page", tmi) end,
                separator = true,
            },
            {
                text = _("Stop goal"),
                keep_menu_open = true,
                enabled_func = function() return self:goalActive() end,
                callback = function(tmi) self:onStopGoal(tmi) end,
                separator = true,
            },
            {
                text_func = function()
                    local dw = self:_getActiveDailyWeekly()
                    if dw then
                        local read = self:_getDailyWeeklyRead(dw)
                        return T(_("Daily/Weekly goals (%1/%2)"), read, dw.target_pages)
                    end
                    return _("Daily/Weekly goals")
                end,
                sub_item_table = {
                    {
                        text = _("Set daily goal (this book)"),
                        keep_menu_open = true,
                        callback = function(tmi) self:_showSetDailyWeeklyDialog("book", "daily", tmi) end,
                    },
                    {
                        text = _("Set weekly goal (this book)"),
                        keep_menu_open = true,
                        callback = function(tmi) self:_showSetDailyWeeklyDialog("book", "weekly", tmi) end,
                        separator = true,
                    },
                    {
                        text = _("Set daily goal (all books)"),
                        keep_menu_open = true,
                        callback = function(tmi) self:_showSetDailyWeeklyDialog("global", "daily", tmi) end,
                    },
                    {
                        text = _("Set weekly goal (all books)"),
                        keep_menu_open = true,
                        callback = function(tmi) self:_showSetDailyWeeklyDialog("global", "weekly", tmi) end,
                        separator = true,
                    },
                    {
                        text = _("View progress"),
                        keep_menu_open = true,
                        callback = function() self:_showDailyWeeklyProgress() end,
                    },
                    {
                        text = _("Stop daily/weekly goal"),
                        keep_menu_open = true,
                        enabled_func = function() return self:_dailyWeeklyActive() end,
                        callback = function(tmi) self:_stopDailyWeekly(tmi) end,
                    },
                },
            },
        },
    }
end

function ReadingGoal:_showAbsoluteGoalDialog(goal_type, touchmenu_instance)
    local title, hint
    if goal_type == "percentage" then
        title = _("Set percentage goal (0-100)")
        hint = _("Enter target percentage")
    elseif goal_type == "stable_page" then
        title = _("Set stable page goal")
        local _c, _t, _sl, _si, count = self:_getPages()
        hint = count and T(_("Enter target stable page (1-%1)"), count) or _("Enter target stable page")
    else
        title = _("Set page goal")
        local _c, total = self:_getPages()
        hint = total and T(_("Enter target page (1-%1)"), total) or _("Enter target page")
    end

    local reminder_enabled = false
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = "",
        input_hint = hint,
        input_type = "number",
        buttons = { { { text = _("Cancel") }, { text = _("Set") } } },
    }

    dlg.buttons[1][1].callback = function() UIManager:close(dlg) end
    dlg.buttons[1][2].callback = function()
        local value = tonumber(dlg:getInputText())
        if not value or value <= 0 then
            UIManager:close(dlg)
            return
        end

        local already_past = false
        if goal_type == "percentage" then
            local currPct = self:currentProgress() or 0
            if value <= currPct then already_past = true end
        elseif goal_type == "stable_page" then
            local _c, _t, _sl, idx = self:_getPages()
            if idx and value <= idx then already_past = true end
        else
            local curr = self:_getPages()
            if curr and value <= curr then already_past = true end
        end

        if already_past then
            UIManager:show(InfoMessage:new{ text = _("You are already past that goal") })
            UIManager:close(dlg)
            return
        end

        UIManager:close(dlg)

        if reminder_enabled then
            self:_showReminderIntervalDialog(value, goal_type, touchmenu_instance)
        else
            self:setGoal(value, goal_type)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end
    end

    self:addCheckboxes(dlg)

    dlg:addWidget(CheckButton:new{
        text = _("Enable progress reminders"),
        checked = false,
        parent = dlg,
        callback = function()
            reminder_enabled = not reminder_enabled
        end,
    })

    UIManager:show(dlg)
    return true
end

function ReadingGoal:_showReminderIntervalDialog(goal_value, goal_type, touchmenu_instance)
    local title
    if goal_type == "page" then
        title = _("Remind every X pages into goal")
    else
        title = _("Remind every X% of goal progress")
    end

    local dlg
    dlg = InputDialog:new{
        title = title,
        input = "25",
        input_hint = goal_type == "page" and _("e.g. 50 pages") or _("e.g. 25%"),
        input_type = "number",
        buttons = { { { text = _("Skip") }, { text = _("Set") } } },
    }

    dlg.buttons[1][1].callback = function()
        UIManager:close(dlg)
        self:setGoal(goal_value, goal_type)
        if touchmenu_instance then touchmenu_instance:updateItems() end
    end

    dlg.buttons[1][2].callback = function()
        local interval = tonumber(dlg:getInputText())
        UIManager:close(dlg)
        if interval and interval > 0 then
            self:setGoalWithReminder(goal_value, goal_type, interval)
        else
            self:setGoal(goal_value, goal_type)
        end
        if touchmenu_instance then touchmenu_instance:updateItems() end
    end

    UIManager:show(dlg)
end

function ReadingGoal:_showRelativeGoalDialog(goal_type, touchmenu_instance)
    local title, hint
    if goal_type == "percentage" then
        title = _("Read X% more")
        hint = _("e.g. 10 to read 10% more")
    elseif goal_type == "stable_page" then
        title = _("Read X more stable pages")
        hint = _("e.g. 50 to read 50 more stable pages")
    else
        title = _("Read X more pages")
        hint = _("e.g. 100 to read 100 more pages")
    end

    local reminder_enabled = false
    local dlg
    dlg = InputDialog:new{
        title = title,
        input = "",
        input_hint = hint,
        input_type = "number",
        buttons = { { { text = _("Cancel") }, { text = _("Set") } } },
    }

    dlg.buttons[1][1].callback = function() UIManager:close(dlg) end
    dlg.buttons[1][2].callback = function()
        local amount = tonumber(dlg:getInputText())
        if not amount or amount <= 0 then
            UIManager:close(dlg)
            return
        end

        local target
        if goal_type == "percentage" then
            local currPct = self:currentProgress() or 0
            target = currPct + amount
            if target > 100 then target = 100 end
        elseif goal_type == "stable_page" then
            local _c, _t, _sl, idx = self:_getPages()
            if not idx then
                UIManager:show(InfoMessage:new{ text = _("Cannot determine current stable page") })
                UIManager:close(dlg)
                return
            end
            target = idx + amount
        else
            local curr = self:_getPages()
            if not curr then
                UIManager:show(InfoMessage:new{ text = _("Cannot determine current page") })
                UIManager:close(dlg)
                return
            end
            target = curr + amount
        end

        UIManager:close(dlg)

        if reminder_enabled then
            self:_showReminderIntervalDialog(target, goal_type, touchmenu_instance)
        else
            self:setGoal(target, goal_type)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end
    end

    self:addCheckboxes(dlg)
    dlg:addWidget(CheckButton:new{
        text = _("Enable progress reminders"),
        checked = false,
        parent = dlg,
        callback = function()
            reminder_enabled = not reminder_enabled
        end,
    })

    UIManager:show(dlg)
    return true
end

function ReadingGoal:onShowGoal()
    self:_showAbsoluteGoalDialog("percentage", nil)
    return true
end

function ReadingGoal:onStopGoal(touchmenu_instance)
    if self:goalActive() then
        self.last_goal_percentage = 0
        self:unscheduleGoal()
        if touchmenu_instance then
            touchmenu_instance:updateItems()
        else
            UIManager:show(InfoMessage:new{ text = _("Goal stopped") })
        end
    end
    return true
end

ReadingGoal.goal_callback = function(self)
    if not self:goalActive() then return end
    local tip_text = _("Goal reached!")
    if self.last_goal_percentage > 0 then
        local box
        box = ConfirmBox:new{
            text = tip_text,
            ok_text = _("Repeat"),
            ok_callback = function()
                UIManager:close(box)
                self:setGoal(self.last_goal_percentage, "percentage")
            end,
            cancel_text = _("Done"),
            cancel_callback = function()
                self.last_goal_percentage = 0
                self:_persistGoalToDoc()
            end,
        }
        UIManager:show(box)
    else
        UIManager:show(InfoMessage:new{ text = tip_text })
    end
    self:unscheduleGoal()
end

function ReadingGoal:_showSetDailyWeeklyDialog(scope, period, touchmenu_instance)
    local title
    if scope == "book" then
        title = period == "weekly"
            and _("Set weekly page goal (this book)")
            or _("Set daily page goal (this book)")
    else
        title = period == "weekly"
            and _("Set weekly page goal (all books)")
            or _("Set daily page goal (all books)")
    end

    local hint = period == "weekly"
        and _("Pages per week (e.g. 210)")
        or _("Pages per day (e.g. 30)")

    local dlg
    dlg = InputDialog:new{
        title = title,
        input = "",
        input_hint = hint,
        input_type = "number",
        buttons = { { { text = _("Cancel") }, { text = _("Set") } } },
    }

    dlg.buttons[1][1].callback = function() UIManager:close(dlg) end
    dlg.buttons[1][2].callback = function()
        local target = tonumber(dlg:getInputText())
        UIManager:close(dlg)
        if not target or target <= 0 then return end

        if scope == "book" then
            local curr = self:_getPages()
            self.book_daily_weekly = {
                mode = period,
                target_pages = target,
                start_date = self:_today(),
                deficit = 0,
                tracking = {},
            }
            local key = period == "weekly" and self:_getWeekStartDate() or self:_today()
            self.book_daily_weekly.tracking[key] = {
                start_page = curr or 0,
                end_page = curr or 0,
            }
            self:_persistDailyWeeklyToDoc()
        else
            self.settings.global_daily_weekly = {
                mode = period,
                target_pages = target,
                deficit = 0,
                daily_log = {},
                weekly_log = {},
                last_known_pages = {},
            }
            self:_initGlobalTrackingForBook()
            local key = period == "weekly" and self:_getWeekStartDate() or self:_today()
            if period == "weekly" then
                self.settings.global_daily_weekly.weekly_log[key] = { pages_read = 0 }
            else
                self.settings.global_daily_weekly.daily_log[key] = { pages_read = 0 }
            end
        end

        self:update_status_bars()
        local period_label = period == "weekly" and _("week") or _("day")
        UIManager:show(InfoMessage:new{
            text = T(_("Goal set: %1 pages per %2"), target, period_label),
            timeout = 5,
        })
        if touchmenu_instance then touchmenu_instance:updateItems() end
    end

    UIManager:show(dlg)
end

function ReadingGoal:_showDailyWeeklyProgress()
    local lines = {}

    if self.book_daily_weekly and self.book_daily_weekly.target_pages
        and self.book_daily_weekly.target_pages > 0 then
        local dw = self.book_daily_weekly
        local read = self:_getDailyWeeklyRead(dw)
        local deficit = dw.deficit or 0
        local effective = dw.target_pages + deficit
        local remaining = math.max(0, effective - read)
        local period_label = dw.mode == "weekly" and _("Weekly") or _("Daily")

        table.insert(lines, _("── This book ──"))
        table.insert(lines, T(_("%1 goal: %2 pages"), period_label, dw.target_pages))
        table.insert(lines, T(_("Read: %1/%2 pages"), read, dw.target_pages))
        if deficit > 0 then
            table.insert(lines, T(_("Deficit: +%1 pages"), deficit))
            table.insert(lines, T(_("Effective target: %1 pages (%2 remaining)"), effective, remaining))
        else
            table.insert(lines, T(_("Remaining: %1 pages"), remaining))
        end
        table.insert(lines, "")
    end

    local gdw = self.settings.global_daily_weekly
    if gdw and gdw.target_pages and gdw.target_pages > 0 then
        local read = self:_getDailyWeeklyRead(gdw)
        local deficit = gdw.deficit or 0
        local effective = gdw.target_pages + deficit
        local remaining = math.max(0, effective - read)
        local period_label = gdw.mode == "weekly" and _("Weekly") or _("Daily")

        table.insert(lines, _("── All books ──"))
        table.insert(lines, T(_("%1 goal: %2 pages"), period_label, gdw.target_pages))
        table.insert(lines, T(_("Read: %1/%2 pages"), read, gdw.target_pages))
        if deficit > 0 then
            table.insert(lines, T(_("Deficit: +%1 pages"), deficit))
            table.insert(lines, T(_("Effective target: %1 pages (%2 remaining)"), effective, remaining))
        else
            table.insert(lines, T(_("Remaining: %1 pages"), remaining))
        end
    end

    if #lines == 0 then
        table.insert(lines, _("No daily/weekly goal is active."))
    end

    UIManager:show(InfoMessage:new{
        text = table.concat(lines, "\n"),
    })
end

function ReadingGoal:_stopDailyWeekly(touchmenu_instance)
    if self.book_daily_weekly then
        self.book_daily_weekly = nil
        self:_persistDailyWeeklyToDoc()
    end
    if self.settings.global_daily_weekly then
        self.settings.global_daily_weekly = nil
    end
    self:update_status_bars()
    UIManager:show(InfoMessage:new{ text = _("Daily/weekly goal stopped") })
    if touchmenu_instance then touchmenu_instance:updateItems() end
end

return ReadingGoal
