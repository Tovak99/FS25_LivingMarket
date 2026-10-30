-- =====================================================================
-- DynamicMarketFrame: eigene Seite im Ingame-Menü (ESC)
-- Oben: eine Zeile pro Ware mit Lager, bester Station (höchster Preis mit
-- freiem Bedarf), Preis je 1000 l, verkaufbarer Menge und Erlös.
-- Unten: Detailfenster mit allen Stationen der gewählten Ware.
-- =====================================================================

DynamicMarketFrame = {}
local DynamicMarketFrame_mt = Class(DynamicMarketFrame, TabbedMenuFrameElement)

DynamicMarketFrame.LOW_SHARE    = 0.15   -- ab hier gilt der Restbedarf als "knapp"
DynamicMarketFrame.SEARCH_DELAY = 250    -- ms nach dem letzten Tastendruck, dann wird gefiltert

-- Farben
local COLOR_GOOD  = { 0.35, 0.85, 0.35, 1 }
local COLOR_MID   = { 0.95, 0.8, 0.25, 1 }
local COLOR_LOW   = { 0.95, 0.35, 0.3, 1 }
local COLOR_TEXT  = { 1, 1, 1, 1 }
local COLOR_MUTED = { 0.5, 0.5, 0.5, 1 }

function DynamicMarketFrame.new(target, customMt)
    local self = TabbedMenuFrameElement.new(target, customMt or DynamicMarketFrame_mt)

    self.wares = {}               -- alle Waren (von DynamicMarket)
    self.visibleWares = {}        -- nach Lager/Suche gefiltert
    self.selectedFillType = nil   -- gewählte Ware (bleibt beim Aktualisieren erhalten)
    self.searchText = ""
    self.stockOnly = true         -- nur Waren zeigen, die der Hof auf Lager hat

    self.hasCustomMenuButtons = true
    self.backButtonInfo = {}
    self.stockButtonInfo = {}
    self.clearSearchButtonInfo = {}

    return self
end

function DynamicMarketFrame:initialize()
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }
    self.stockButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("dynamicMarket_showAll"),
        callback = function() self:onToggleStockOnly() end
    }
    self.clearSearchButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("dynamicMarket_clearSearch"),
        callback = function() self:clearSearch() end
    }

    -- Beide Listen werden von dieser Seite befüllt; welche gemeint ist, steht im Parameter "list"
    self.wareList:setDataSource(self)
    self.wareList:setDelegate(self)
    self.detailList:setDataSource(self)
    self.detailList:setDelegate(self)

    self:updateMenuButtons()
end

function DynamicMarketFrame:onFrameOpen()
    DynamicMarketFrame:superClass().onFrameOpen(self)
    self:refreshData()
end

function DynamicMarketFrame:onFrameClose()
    DynamicMarketFrame:superClass().onFrameClose(self)
end

-- ---------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------
local function trim(text)
    return (string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
end

-- Farbe für alle Zustände setzen, sonst überschreibt das Profil sie bei ausgewählter Zeile
local function setColor(textElement, c)
    textElement:setTextColor(c[1], c[2], c[3], c[4])
    for _, setter in ipairs({ "setTextSelectedColor", "setTextFocusedColor", "setTextHighlightedColor",
                              "setTextFocusedSelectedColor", "setTextHighlightedSelectedColor" }) do
        if textElement[setter] ~= nil then
            textElement[setter](textElement, c[1], c[2], c[3], c[4])
        end
    end
end

local function shareColor(share)
    if share > 0.5 then
        return COLOR_GOOD
    elseif share > DynamicMarketFrame.LOW_SHARE then
        return COLOR_MID
    end
    return COLOR_LOW
end

local function formatPrice(pricePer1000)
    return DynamicMarket.formatMoney(pricePer1000)
end

-- ---------------------------------------------------------------------
-- Daten
-- ---------------------------------------------------------------------
function DynamicMarketFrame:refreshData()
    self.wares = DynamicMarket:getWareData()

    if self.infoText ~= nil then
        local percent = math.floor(DynamicMarket.REFILL_SHARE * 100 + 0.5)
        self.infoText:setText(string.format(g_i18n:getText("dynamicMarket_info"), percent))
    end

    self:updateSearchHint()
    self:rebuildWareList()
end

-- Waren nach Lagerbestand und Suchbegriff filtern.
-- Die Suche trifft den Namen der Ware oder den Namen einer Station, die sie annimmt.
function DynamicMarketFrame:getFilteredWares()
    local searching = self:isSearching()
    local query = DynamicMarket.toLower(self.searchText)
    local result = {}

    for _, ware in ipairs(self.wares) do
        local stockOk = not self.stockOnly or ware.stock >= 1
        local searchOk = not searching or string.find(ware.searchKey, query, 1, true) ~= nil
        if stockOk and searching and not searchOk then
            for _, station in ipairs(ware.stations) do
                if string.find(station.searchKey, query, 1, true) ~= nil then
                    searchOk = true
                    break
                end
            end
        end
        if stockOk and searchOk then
            table.insert(result, ware)
        end
    end
    return result
end

function DynamicMarketFrame:rebuildWareList()
    self.visibleWares = self:getFilteredWares()

    -- Hinweis bei leerer Liste
    if self.emptyText ~= nil then
        local text = nil
        if #self.wares == 0 then
            text = g_i18n:getText("dynamicMarket_none")
        elseif #self.visibleWares == 0 and self:isSearching() then
            text = string.format(g_i18n:getText("dynamicMarket_noResults"), self.searchText)
        elseif #self.visibleWares == 0 then
            text = g_i18n:getText("dynamicMarket_noStock")
        end
        self.emptyText:setVisible(text ~= nil)
        if text ~= nil then
            self.emptyText:setText(text)
        end
    end

    self.wareList:reloadData(true)

    -- Gewählte Ware wieder auswählen, sonst die erste
    local index = 1
    for i, ware in ipairs(self.visibleWares) do
        if ware.fillTypeIndex == self.selectedFillType then
            index = i
            break
        end
    end
    if #self.visibleWares > 0 then
        self.wareList:setSelectedItem(1, index)
    end
    self:updateDetail(self.visibleWares[index])
    self:updateMenuButtons()
end

-- Detailfenster für eine Ware befüllen
function DynamicMarketFrame:updateDetail(ware)
    self.detailWare = ware
    self.selectedFillType = ware ~= nil and ware.fillTypeIndex or self.selectedFillType

    if self.detailTitle ~= nil then
        if ware ~= nil then
            self.detailTitle:setText(ware.title)
        else
            self.detailTitle:setText(g_i18n:getText("dynamicMarket_detailHint"))
        end
    end

    self.detailList:reloadData(true)
end

-- Auswahl in der Warenliste geändert (Tastatur, Controller, Maus)
function DynamicMarketFrame:onListSelectionChanged(list, section, index)
    if list == self.wareList then
        local ware = self.visibleWares[index]
        if ware ~= nil and ware ~= self.detailWare then
            self:updateDetail(ware)
        end
    end
end

-- Zusätzlich bei Klick, falls die Liste die Auswahländerung nicht meldet
function DynamicMarketFrame:onClickWare(list, section, index)
    self:onListSelectionChanged(self.wareList, section, index)
end

-- ---------------------------------------------------------------------
-- Suche
-- ---------------------------------------------------------------------
-- Beim Tippen nur merken; gefiltert wird kurz danach in update()
function DynamicMarketFrame:onSearchTextChanged(element, text)
    self.pendingSearchText = trim(text)
    self.searchTimer = self.SEARCH_DELAY
    if self.searchHint ~= nil then
        self.searchHint:setVisible(self.pendingSearchText == "")
    end
end

-- Enter: sofort filtern
function DynamicMarketFrame:onSearchEnter(element)
    self.pendingSearchText = trim(element ~= nil and element.text or self.searchText)
    self:applySearch()
end

function DynamicMarketFrame:applySearch()
    self.searchTimer = nil
    if self.pendingSearchText == nil or self.pendingSearchText == self.searchText then
        self.pendingSearchText = nil
        return
    end
    self.searchText = self.pendingSearchText
    self.pendingSearchText = nil
    self:updateSearchHint()
    self:rebuildWareList()
end

function DynamicMarketFrame:clearSearch()
    if self.searchInput ~= nil then
        self.searchInput:setText("")
    end
    self.searchText = ""
    self.pendingSearchText = nil
    self.searchTimer = nil
    self:updateSearchHint()
    self:rebuildWareList()
end

function DynamicMarketFrame:updateSearchHint()
    if self.searchHint ~= nil then
        self.searchHint:setVisible(self.searchText == "")
    end
end

function DynamicMarketFrame:isSearching()
    return self.searchText ~= ""
end

function DynamicMarketFrame:update(dt)
    DynamicMarketFrame:superClass().update(self, dt)

    if self.searchTimer ~= nil then
        self.searchTimer = self.searchTimer - dt
        if self.searchTimer <= 0 then
            self:applySearch()
        end
    end
end

-- ---------------------------------------------------------------------
-- Tastenleiste
-- ---------------------------------------------------------------------
function DynamicMarketFrame:onToggleStockOnly()
    self.stockOnly = not self.stockOnly
    self:rebuildWareList()
end

function DynamicMarketFrame:updateMenuButtons()
    -- Text zeigt, wohin umgeschaltet wird
    if self.stockOnly then
        self.stockButtonInfo.text = g_i18n:getText("dynamicMarket_showAll")
    else
        self.stockButtonInfo.text = g_i18n:getText("dynamicMarket_stockOnly")
    end

    self.menuButtonInfo = { self.backButtonInfo, self.stockButtonInfo }
    if self:isSearching() then
        table.insert(self.menuButtonInfo, self.clearSearchButtonInfo)
    end
    self:setMenuButtonInfoDirty()
end

-- ---------------------------------------------------------------------
-- Datenquelle für beide Listen
-- ---------------------------------------------------------------------
function DynamicMarketFrame:getNumberOfSections(list)
    return 1
end

function DynamicMarketFrame:getNumberOfItemsInSection(list, section)
    if list == self.wareList then
        return #self.visibleWares
    end
    return self.detailWare ~= nil and #self.detailWare.stations or 0
end

function DynamicMarketFrame:getCellTypeForItemInSection(list, section, index)
    return list == self.wareList and "ware" or "station"
end

function DynamicMarketFrame:populateCellForItemInSection(list, section, index, cell)
    if list == self.wareList then
        self:populateWareCell(self.visibleWares[index], cell)
    elseif self.detailWare ~= nil then
        self:populateStationCell(self.detailWare.stations[index], cell)
    end
end

function DynamicMarketFrame:populateWareCell(ware, cell)
    if ware == nil or cell:getAttribute("title") == nil then
        return
    end

    cell:getAttribute("title"):setText(ware.title)
    cell:getAttribute("stock"):setText(ware.stock >= 1 and DynamicMarket.formatLiters(ware.stock) or "-")

    local stationText = cell:getAttribute("station")
    local priceText = cell:getAttribute("price")
    local sellableText = cell:getAttribute("sellable")
    local revenueText = cell:getAttribute("revenue")

    if ware.best == nil then
        -- Keine Station mit freiem Bedarf
        stationText:setText(g_i18n:getText("dynamicMarket_allFull"))
        setColor(stationText, COLOR_LOW)
        priceText:setText("-")
        sellableText:setText("-")
        revenueText:setText("-")
        setColor(revenueText, COLOR_MUTED)
        return
    end

    stationText:setText(ware.best.name)
    setColor(stationText, COLOR_TEXT)
    priceText:setText(formatPrice(ware.best.price))

    if ware.sellable >= 1 then
        sellableText:setText(DynamicMarket.formatLiters(ware.sellable))
        setColor(sellableText, ware.sellable < ware.stock and COLOR_MID or COLOR_TEXT)   -- gelb: nicht alles passt rein
        revenueText:setText(DynamicMarket.formatMoney(ware.revenue))
        setColor(revenueText, COLOR_GOOD)
    else
        sellableText:setText("-")
        setColor(sellableText, COLOR_TEXT)
        revenueText:setText("-")
        setColor(revenueText, COLOR_MUTED)
    end
end

function DynamicMarketFrame:populateStationCell(station, cell)
    if station == nil or cell:getAttribute("name") == nil then
        return
    end

    local isFull = station.remaining < 1
    local nameText = cell:getAttribute("name")
    local priceText = cell:getAttribute("price")
    local amountText = cell:getAttribute("amount")
    local shareText = cell:getAttribute("share")

    nameText:setText(station.name)
    cell:getAttribute("category"):setText(g_i18n:getText("dynamicMarket_cat_" .. station.category))
    priceText:setText(formatPrice(station.price))
    amountText:setText(string.format("%s / %s", DynamicMarket.formatLiters(station.remaining), DynamicMarket.formatLiters(station.max)))
    shareText:setText(string.format("%d %%", math.floor(station.share * 100 + 0.5)))

    -- Volle Stationen ausgegraut
    local main = isFull and COLOR_MUTED or COLOR_TEXT
    setColor(nameText, main)
    setColor(priceText, main)
    setColor(amountText, main)
    setColor(shareText, isFull and COLOR_MUTED or shareColor(station.share))
end
