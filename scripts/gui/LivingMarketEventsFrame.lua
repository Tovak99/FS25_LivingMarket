-- =====================================================================
-- LivingMarketEventsFrame: zweite Seite im Ingame-Menü (ESC)
-- Liste aller laufenden und angekündigten Marktereignisse mit Beginn/Ende.
-- =====================================================================

LivingMarketEventsFrame = {}
local LivingMarketEventsFrame_mt = Class(LivingMarketEventsFrame, TabbedMenuFrameElement)

-- Farben (linear, siehe LivingMarketFrame)
local COLOR_GOOD  = { 0.100, 0.692, 0.100, 1 }
local COLOR_LOW   = { 0.890, 0.100, 0.073, 1 }
local COLOR_MID   = { 0.890, 0.604, 0.051, 1 }
local COLOR_TEXT  = { 1, 1, 1, 1 }
local COLOR_MUTED = { 0.55, 0.55, 0.55, 1 }
local ROW_DARK    = { 0.023, 0.023, 0.023, 1 }
local ROW_LIGHT   = { 0.033, 0.033, 0.033, 1 }
local FRAME_COLOR = { 0.040, 0.040, 0.040, 1 }

local EVENT_LABELS = { [1] = "livingMarket_evLabelShortage", [2] = "livingMarket_evLabelSurplus",
                       [3] = "livingMarket_evLabelBoom",     [4] = "livingMarket_evLabelSlump" }

function LivingMarketEventsFrame.new(target, customMt)
    local self = TabbedMenuFrameElement.new(target, customMt or LivingMarketEventsFrame_mt)
    self.rows = {}
    self.hasCustomMenuButtons = true
    self.backButtonInfo = {}
    self.testMonthButtonInfo = {}
    return self
end

function LivingMarketEventsFrame:initialize()
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }
    self.testMonthButtonInfo = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("livingMarket_testMonth"),
        callback = function()
            LivingMarket:onPeriodChanged()
            self:refreshData()
        end
    }
    self.eventList:setDataSource(self)
    self.eventList:setDelegate(self)
    self:updateMenuButtons()
end

function LivingMarketEventsFrame:updateMenuButtons()
    self.menuButtonInfo = { self.backButtonInfo }
    if LivingMarket.DEBUG and g_server ~= nil and InputAction.MENU_ACTIVATE ~= nil then
        table.insert(self.menuButtonInfo, self.testMonthButtonInfo)
    end
    self:setMenuButtonInfoDirty()
end

function LivingMarketEventsFrame:onFrameOpen()
    LivingMarketEventsFrame:superClass().onFrameOpen(self)
    if self.eventFrame ~= nil and self.eventFrame.setImageColor ~= nil and GuiOverlay ~= nil then
        self.eventFrame:setImageColor(GuiOverlay.STATE_NORMAL, FRAME_COLOR[1], FRAME_COLOR[2], FRAME_COLOR[3], FRAME_COLOR[4])
    end
    if self.eventSlider ~= nil then
        self.eventSlider:setDataElement(self.eventList)
    end
    self:refreshData()
end

function LivingMarketEventsFrame:refreshData()
    self.rows = LivingMarket:getEventList()
    if self.emptyText ~= nil then
        self.emptyText:setVisible(#self.rows == 0)
    end
    self.eventList:reloadData(true)
    self:updateMenuButtons()
end

-- ---------------------------------------------------------------------
-- Datenquelle
-- ---------------------------------------------------------------------
function LivingMarketEventsFrame:getNumberOfSections(list)
    return 1
end

function LivingMarketEventsFrame:getNumberOfItemsInSection(list, section)
    return #self.rows
end

function LivingMarketEventsFrame:getCellTypeForItemInSection(list, section, index)
    return "event"
end

local function setColor(textElement, c)
    if textElement == nil then
        return
    end
    textElement:setTextColor(c[1], c[2], c[3], c[4])
    for _, setter in ipairs({ "setTextHighlightedColor", "setTextSelectedColor", "setTextFocusedColor" }) do
        if textElement[setter] ~= nil then
            textElement[setter](textElement, c[1], c[2], c[3], c[4])
        end
    end
end

local function setText(cell, name, text, color)
    local element = cell:getAttribute(name)
    if element ~= nil then
        element:setText(text or "")
        setColor(element, color or COLOR_TEXT)
    end
end

function LivingMarketEventsFrame:populateCellForItemInSection(list, section, index, cell)
    local row = self.rows[index]
    if row == nil or cell:getAttribute("type") == nil then
        return
    end

    local bg = cell:getAttribute("bg")
    if bg ~= nil and bg.setImageColor ~= nil and GuiOverlay ~= nil then
        local c = (index % 2 == 0) and ROW_LIGHT or ROW_DARK
        bg:setImageColor(GuiOverlay.STATE_NORMAL, c[1], c[2], c[3], c[4])
    end

    local positive = row.type == LivingMarket.EVENT_SHORTAGE or row.type == LivingMarket.EVENT_BOOM
    local typeColor = positive and COLOR_GOOD or COLOR_LOW
    local main = row.pending and COLOR_MUTED or COLOR_TEXT

    setText(cell, "type", g_i18n:getText(EVENT_LABELS[row.type] or "livingMarket_evLabelShortage"), typeColor)
    setText(cell, "ware", row.wareTitle, main)
    setText(cell, "station", row.stationName, main)
    setText(cell, "price", string.format("%+d %%", row.pricePercent), typeColor)
    setText(cell, "demand", (string.gsub(string.format("x%.1f", row.maxFactor), "%.", ",")), main)
    setText(cell, "start", LivingMarket.getMonthName(row.startMonth), row.pending and COLOR_MID or main)
    setText(cell, "end", LivingMarket.getMonthName(row.endMonth), main)
    setText(cell, "status", g_i18n:getText(row.pending and "livingMarket_evPending" or "livingMarket_evRunning"),
        row.pending and COLOR_MID or COLOR_GOOD)

    local icon = cell:getAttribute("icon")
    if icon ~= nil then
        local fillType = g_fillTypeManager:getFillTypeByIndex(row.fillTypeIndex)
        local filename = fillType ~= nil and fillType.hudOverlayFilename or nil
        if filename ~= nil and filename ~= "" then
            icon:setImageFilename(filename)
            icon:setVisible(true)
        else
            icon:setVisible(false)
        end
    end
end
