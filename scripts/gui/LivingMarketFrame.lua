-- =====================================================================
-- LivingMarketFrame: eigene Seite im Ingame-Menü (ESC)
-- Oben: eine Zeile pro Ware mit Lager, bester Station (höchster Preis mit
-- freiem Bedarf), Preis je 1000 l, verkaufbarer Menge und Erlös.
-- Unten: Detailfenster mit allen Stationen der gewählten Ware.
-- =====================================================================

LivingMarketFrame = {}
local LivingMarketFrame_mt = Class(LivingMarketFrame, TabbedMenuFrameElement)

LivingMarketFrame.LOW_SHARE    = 0.15   -- ab hier gilt der Restbedarf als "knapp"
LivingMarketFrame.SEARCH_DELAY = 250    -- ms nach dem letzten Tastendruck, dann wird gefiltert
LivingMarketFrame.FRAME_COLOR  = { 0.040, 0.040, 0.040, 1 }   -- Tabellenrahmen (#383838)

-- Farben: Das Spiel rechnet Farbwerte linear (Gammakorrektur), deshalb sind die
-- Zielfarben (#hex, wie sie auf dem Bildschirm erscheinen) hier umgerechnet eingetragen.
local COLOR_GOOD  = { 0.100, 0.692, 0.100, 1 }
local COLOR_MID   = { 0.890, 0.604, 0.051, 1 }
local COLOR_LOW   = { 0.890, 0.100, 0.073, 1 }
local COLOR_TEXT  = { 1, 1, 1, 1 }
local COLOR_MUTED = { 0.184, 0.184, 0.184, 1 }
local COLOR_MUTED_LIGHT = { 0.30, 0.30, 0.30, 1 }

function LivingMarketFrame.new(target, customMt)
    local self = TabbedMenuFrameElement.new(target, customMt or LivingMarketFrame_mt)

    self.wares = {}               -- alle Waren (von LivingMarket)
    self.visibleWares = {}        -- nach Lager/Suche gefiltert
    self.selectedFillType = nil   -- gewählte Ware (bleibt beim Aktualisieren erhalten)
    self.searchText = ""
    self.filterMode = "stock"     -- Filter: "all" = alle Waren, "stock" = lagernd, "fav" = Favoriten
    self.viewMode = "market"      -- Ansicht: "market" = Warenliste + Details, "events" = Marktnachrichten
    self.eventRows = {}
    self.wareSort = { key = "title", asc = true }      -- Sortierung Warenliste
    self.detailSort = { key = "price", asc = false }   -- Sortierung Detailliste
    self.detailStations = {}      -- Stationen der gewählten Ware, sortiert

    self.hasCustomMenuButtons = true
    self.backButtonInfo = {}
    self.clearSearchButtonInfo = {}
    self.favButtonInfo = {}
    self.testRefillButtonInfo = {}
    self.testMonthButtonInfo = {}
    self.locationButtonInfo = {}

    return self
end

function LivingMarketFrame:initialize()
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }
    -- Nur zum Testen (DEBUG): eine Spielstunde Auffüllen sofort ausführen
    self.testRefillButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_2,
        text = g_i18n:getText("livingMarket_testRefill"),
        callback = function() self:onTestRefill() end
    }
    self.locationButtonInfo = {
        inputAction = InputAction.MENU_ACTIVATE,
        text = g_i18n:getText("livingMarket_locButton"),
        callback = function() self:onShowLocations() end
    }
    self.testMonthButtonInfo = {
        inputAction = InputAction.MENU_ACCEPT,
        text = g_i18n:getText("livingMarket_testMonth"),
        callback = function() self:onTestMonth() end
    }
    self.favButtonInfo = {
        inputAction = InputAction.MENU_EXTRA_1,
        text = g_i18n:getText("livingMarket_favAdd"),
        callback = function() self:onToggleFavorite() end
    }
    self.clearSearchButtonInfo = {
        inputAction = InputAction.MENU_CANCEL,
        text = g_i18n:getText("livingMarket_clearSearch"),
        callback = function() self:clearSearch() end
    }

    -- Beide Listen werden von dieser Seite befüllt; welche gemeint ist, steht im Parameter "list"
    self.wareList:setDataSource(self)
    self.wareList:setDelegate(self)
    self.detailList:setDataSource(self)
    self.detailList:setDelegate(self)
    if self.eventList ~= nil then
        self.eventList:setDataSource(self)
        self.eventList:setDelegate(self)
    end

    self:setupSortHeaders()

    self:updateMenuButtons()
end

function LivingMarketFrame:onFrameOpen()
    LivingMarketFrame:superClass().onFrameOpen(self)

    -- Tabellenrahmen einfärben (etwas heller als der Seitenhintergrund)
    for _, frame in ipairs({ self.wareFrame, self.detailFrame, self.eventFrame }) do
        if frame ~= nil and frame.setImageColor ~= nil and GuiOverlay ~= nil and GuiOverlay.STATE_NORMAL ~= nil then
            local c = LivingMarketFrame.FRAME_COLOR
            frame:setImageColor(GuiOverlay.STATE_NORMAL, c[1], c[2], c[3], c[4])
        end
    end

    -- Scrollbalken mit ihren Listen verbinden
    if self.wareSlider ~= nil then
        self.wareSlider:setDataElement(self.wareList)
    end
    if self.detailSlider ~= nil then
        self.detailSlider:setDataElement(self.detailList)
    end
    if self.eventSlider ~= nil then
        self.eventSlider:setDataElement(self.eventList)
    end
    self:refreshData()
    self:setViewMode(self.viewMode)
end

function LivingMarketFrame:onFrameClose()
    LivingMarketFrame:superClass().onFrameClose(self)
end

-- ---------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------
local function trim(text)
    return (string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
end

-- Farbe für alle Zustände setzen. Die Markierung der gewählten Zeile übernimmt
-- diese Seite selbst (selectedWareIndex), nicht das Spiel: bei den verwendeten
-- Profilen teilen sich die Zustände intern dieselbe Farbe.
local COLOR_ON_GREEN = { 0.013, 0.013, 0.013, 1 }

local function setTextColorAll(textElement, c)
    if textElement == nil then
        return
    end
    textElement:setTextColor(c[1], c[2], c[3], c[4])
    for _, setter in ipairs({ "setTextHighlightedColor", "setTextSelectedColor", "setTextFocusedColor",
                              "setTextFocusedSelectedColor", "setTextHighlightedSelectedColor" }) do
        if textElement[setter] ~= nil then
            textElement[setter](textElement, c[1], c[2], c[3], c[4])
        end
    end
end

-- Icon der Ware (dasselbe, das das Spiel in seiner Anzeige nutzt)
local function setWareIcon(iconElement, fillTypeIndex)
    if iconElement == nil then
        return
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    local filename = fillType ~= nil and fillType.hudOverlayFilename or nil
    if filename ~= nil and filename ~= "" then
        iconElement:setImageFilename(filename)
        iconElement:setVisible(true)
    else
        iconElement:setVisible(false)
    end
end

local function setColor(textElement, c)
    setTextColorAll(textElement, c)
end

local function shareColor(share)
    if share > 0.5 then
        return COLOR_GOOD
    elseif share > LivingMarketFrame.LOW_SHARE then
        return COLOR_MID
    end
    return COLOR_LOW
end

-- Marktabweichung vom Normalpreis: "-12 %" rot, "+5 %" grün, unverändert "-"
local function getMarketText(factor)
    local percent = math.floor(((factor or 1) - 1) * 100 + 0.5)
    if percent == 0 then
        return "-", COLOR_MUTED
    end
    return string.format("%+d %%", percent), percent < 0 and COLOR_LOW or COLOR_GOOD
end

-- Farbe des Preises im Vergleich zum Grundpreis:
-- über Grundpreis grün, gleich weiß, 75–99 % gelb, unter 75 % rot
local function priceColor(price, basePrice)
    if price == nil or basePrice == nil or basePrice <= 0 then
        return COLOR_TEXT
    end
    local percent = math.floor(price / basePrice * 100 + 0.5)
    if percent > 100 then
        return COLOR_GOOD
    elseif percent == 100 then
        return COLOR_TEXT
    elseif percent >= 75 then
        return COLOR_MID
    end
    return COLOR_LOW
end

-- Markt: Unterschied meines Preises zum Marktpreis (Grundpreis), z. B. "+1,8 %"
local function getDeviationText(price, basePrice)
    if price == nil or basePrice == nil or basePrice <= 0 then
        return "-", COLOR_MUTED
    end
    local percent = (price / basePrice - 1) * 100
    local text = string.format("%+.1f %%", percent):gsub("%.", ",")
    return text, priceColor(price, basePrice)
end

-- Pfeil vor dem Preis: über dem Grundpreis grün nach oben, darunter rot nach unten, gleich = keiner
local function setTrendIcon(icon, price, basePrice)
    if icon == nil then
        return
    end
    local percent = (price ~= nil and basePrice ~= nil and basePrice > 0) and math.floor(price / basePrice * 100 + 0.5) or 100
    if percent == 100 then
        icon:setVisible(false)
        return
    end
    icon:setImageFilename(Utils.getFilename(percent > 100 and "images/priceUp.dds" or "images/priceDown.dds", LivingMarket.modDir))
    icon:setVisible(true)
end

-- Marktereignis einer Station: Text und Farbe (Engpass/Gefragt grün, Überangebot/Flaute rot)
local EVENT_LABELS = { [1] = "livingMarket_evLabelShortage", [2] = "livingMarket_evLabelSurplus",
                       [3] = "livingMarket_evLabelBoom",     [4] = "livingMarket_evLabelSlump" }
local function getEventText(eventType, eventPrice)
    local label = EVENT_LABELS[eventType or 0]
    if label == nil then
        return nil, nil
    end
    local percent = math.floor(((eventPrice or 1) - 1) * 100 + 0.5)
    local color = (eventType == 1 or eventType == 3) and COLOR_GOOD or COLOR_LOW
    return string.format("%s %+d %%", g_i18n:getText(label), percent), color
end

local function formatPrice(pricePer1000)
    return LivingMarket.formatMoney(pricePer1000)
end

-- ---------------------------------------------------------------------
-- Daten
-- ---------------------------------------------------------------------
function LivingMarketFrame:refreshData()
    self.wares = LivingMarket:getWareData()

    self:updateSearchHint()
    self:rebuildWareList()
    if self.viewMode == "events" then
        if self.emptyText ~= nil then
            self.emptyText:setVisible(false)
        end
        self:refreshEvents()
    end
end

-- Waren nach Lagerbestand und Suchbegriff filtern.
-- Die Suche trifft den Namen der Ware oder den Namen einer Station, die sie annimmt.
function LivingMarketFrame:getFilteredWares()
    local searching = self:isSearching()
    local query = LivingMarket.toLower(self.searchText)
    local result = {}

    for _, ware in ipairs(self.wares) do
        local stockOk = true
        if self.filterMode == "stock" then
            stockOk = ware.stock >= 1
        elseif self.filterMode == "fav" then
            stockOk = LivingMarket:isFavorite(ware.fillTypeIndex)
        end
        local searchOk = not searching or string.find(ware.searchKey, query, 1, true) ~= nil
        local row = ware
        if stockOk and searching and not searchOk then
            -- Suche trifft eine Station: Zeile zeigt die Werte dieser Station, auch wenn sie nicht die beste ist
            local match = nil
            for _, station in ipairs(ware.stations) do
                if string.find(station.searchKey, query, 1, true) ~= nil then
                    -- mehrere Treffer (z. B. mehrere Tankstellen): höchster Preis mit freiem Bedarf zuerst
                    if match == nil or (match.remaining < 1 and station.remaining >= 1)
                        or ((match.remaining >= 1) == (station.remaining >= 1) and station.price > match.price) then
                        match = station
                    end
                end
            end
            if match ~= nil then
                searchOk = true
                row = setmetatable({}, { __index = ware })
                row.best = match
                -- gefundene Station ist zugleich die beste (höchster Preis mit freiem Bedarf)?
                row.isBestStation = ware.best ~= nil and match.remaining >= 1 and match.price >= ware.best.price
                row.sellable = math.min(ware.stock, math.max(match.remaining, 0))
                row.revenue = LivingMarket:estimateRevenue(match.basePrice * (match.eventPrice or 1) / 1000, match.remaining, match.max, row.sellable)
            end
        end
        if stockOk and searchOk then
            table.insert(result, row)
        end
    end
    self:sortWares(result)
    return result
end

function LivingMarketFrame:rebuildWareList()
    self.visibleWares = self:getFilteredWares()

    -- Hinweis bei leerer Liste
    if self.emptyText ~= nil then
        local text = nil
        if #self.wares == 0 then
            text = g_i18n:getText("livingMarket_none")
        elseif #self.visibleWares == 0 and self:isSearching() then
            text = string.format(g_i18n:getText("livingMarket_noResults"), self.searchText)
        elseif #self.visibleWares == 0 and self.filterMode == "fav" then
            text = g_i18n:getText("livingMarket_noFavorites")
        elseif #self.visibleWares == 0 then
            text = g_i18n:getText("livingMarket_noStock")
        end
        self.emptyText:setVisible(text ~= nil)
        if text ~= nil then
            self.emptyText:setText(text)
        end
    end

    -- Gewählte Ware wieder auswählen, sonst die erste
    local index = 1
    for i, ware in ipairs(self.visibleWares) do
        if ware.fillTypeIndex == self.selectedFillType then
            index = i
            break
        end
    end
    self.selectedWareIndex = index

    self.wareList:reloadData(true)
    if #self.visibleWares > 0 then
        self.wareList:setSelectedItem(1, index)
    end
    self:updateDetail(self.visibleWares[index])
    self:updateMenuButtons()
end

-- Detailfenster für eine Ware befüllen
function LivingMarketFrame:updateDetail(ware)
    self.detailWare = ware
    self.detailStations = {}
    if ware ~= nil then
        for _, station in ipairs(ware.stations) do
            -- Erlös, wenn der Lagerbestand (soweit möglich) an diese Station geht
            local amount = math.min(ware.stock or 0, math.max(station.remaining, 0))
            station.deliverable = amount   -- Liefermenge: höchstens der eigene Lagerbestand
            station.revenue = LivingMarket:estimateRevenue((station.basePrice or station.price) * (station.eventPrice or 1) / 1000, station.remaining, station.max, amount)
            table.insert(self.detailStations, station)
        end
        self:sortStations(self.detailStations)
    end
    self.selectedFillType = ware ~= nil and ware.fillTypeIndex or self.selectedFillType

    -- Icon der Ware im Kopf des Detailfensters
    if self.detailIcon ~= nil then
        if ware ~= nil then
            setWareIcon(self.detailIcon, ware.fillTypeIndex)
        else
            self.detailIcon:setVisible(false)
        end
    end

    self:updateSortHeaders()

    self.detailList:reloadData(true)
end

-- Auswahl in der Warenliste geändert (Tastatur, Controller, Maus)
function LivingMarketFrame:onListSelectionChanged(list, section, index)
    if list ~= self.wareList or self.isRepaintingSelection then
        return
    end
    local ware = self.visibleWares[index]
    if ware == nil then
        return
    end
    if ware ~= self.detailWare then
        self:updateDetail(ware)
        self:updateMenuButtons()
    end
    if index ~= self.selectedWareIndex then
        -- grüne Markierung umsetzen: sichtbare Zeilen neu befüllen
        self.selectedWareIndex = index
        self.isRepaintingSelection = true
        self.wareList:reloadData()
        self.isRepaintingSelection = false
    end
end

-- Zusätzlich bei Klick, falls die Liste die Auswahländerung nicht meldet
function LivingMarketFrame:onClickWare(list, section, index)
    self:onListSelectionChanged(self.wareList, section, index)
end

-- ---------------------------------------------------------------------
-- Sortieren per Klick auf die Spaltenköpfe
-- ---------------------------------------------------------------------

-- Spalten: Text der Überschrift und ob es eine Textspalte ist (erster Klick A→Z, sonst groß→klein)
LivingMarketFrame.WARE_COLUMNS = {
    title    = { label = "livingMarket_colWare",        isText = true  },
    stock    = { label = "livingMarket_colStock",       isText = false },
    station  = { label = "livingMarket_colBestStation", isText = true  },
    highPrice = { label = "livingMarket_colHighPrice",  isText = false },
    bestMonth = { label = "livingMarket_colBestMonth",  isText = true  },   -- erster Klick aufsteigend: bald am besten zuerst
    deviation = { label = "livingMarket_colDeviation",  isText = false },
    price    = { label = "livingMarket_colPrice",       isText = false },
    sellable = { label = "livingMarket_colSellable",    isText = false },
    revenue  = { label = "livingMarket_colRevenue",     isText = false },
}
LivingMarketFrame.DETAIL_COLUMNS = {
    name   = { label = nil,                         isText = true  },   -- Überschrift = Name der Ware
    price  = { label = "livingMarket_colPrice",     isText = false },
    market = { label = "livingMarket_colMarket",    isText = false },
    amount = { label = "livingMarket_colSellable",  isText = false },
    max    = { label = "livingMarket_colMax",       isText = false },
    share  = { label = "livingMarket_colShare",     isText = false },
    revenue = { label = "livingMarket_colRevenue",  isText = false },
}

local function wareValue(ware, key)
    if key == "title" then
        return ware.searchKey
    elseif key == "stock" then
        return ware.stock
    elseif key == "station" then
        return ware.best ~= nil and LivingMarket.toLower(ware.best.name) or nil
    elseif key == "price" then
        return ware.best ~= nil and ware.best.price or nil
    elseif key == "market" then
        return ware.best ~= nil and ware.best.factor or nil
    elseif key == "basePrice" then
        return ware.basePrice
    elseif key == "highPrice" then
        return ware.year ~= nil and ware.year.max or nil
    elseif key == "bestMonth" then
        -- Monate bis zum besten Monat (0 = jetzt), damit "bald am besten" oben steht
        if ware.year == nil then
            return nil
        end
        local current = LivingMarket.getCurrentMonth()
        if current == nil then
            return ware.year.maxMonth
        end
        return (ware.year.maxMonth - current) % 12
    elseif key == "deviation" then
        return (ware.best ~= nil and ware.marketPrice ~= nil and ware.marketPrice > 0) and ware.best.price / ware.marketPrice or nil
    elseif key == "sellable" then
        return ware.sellable
    elseif key == "revenue" then
        return ware.revenue
    end
end

local function stationValue(station, key)
    if key == "name" then
        return station.searchKey
    elseif key == "price" then
        return station.price
    elseif key == "market" then
        return station.factor
    elseif key == "deviation" then
        return station.deviation
    elseif key == "amount" then
        return station.deliverable or station.remaining
    elseif key == "max" then
        return station.max
    elseif key == "revenue" then
        return station.revenue
    elseif key == "share" then
        return station.share
    end
end

-- Vergleich mit Richtung; fehlende Werte (z. B. "alle voll") immer ans Ende
local function compare(a, b, asc, tieA, tieB)
    if a == nil and b == nil then
        return tieA < tieB
    elseif a == nil then
        return false
    elseif b == nil then
        return true
    elseif a == b then
        return tieA < tieB
    end
    if asc then
        return a < b
    end
    return a > b
end

function LivingMarketFrame:sortWares(wares)
    local key, asc = self.wareSort.key, self.wareSort.asc
    table.sort(wares, function(a, b)
        return compare(wareValue(a, key), wareValue(b, key), asc, a.searchKey, b.searchKey)
    end)
end

function LivingMarketFrame:sortStations(stations)
    local key, asc = self.detailSort.key, self.detailSort.asc
    table.sort(stations, function(a, b)
        -- Volle Stationen (kein Bedarf mehr) immer ans Ende, egal wie sortiert ist
        local aFull, bFull = a.remaining < 1, b.remaining < 1
        if aFull ~= bFull then
            return bFull
        end
        return compare(stationValue(a, key), stationValue(b, key), asc, a.searchKey, b.searchKey)
    end)
end

-- Klick auf einen Spaltenkopf: gleiche Spalte = Richtung umdrehen, neue Spalte = Standardrichtung
function LivingMarketFrame:onClickSortHeader(element)
    local id = element ~= nil and element.id or nil
    if id == nil then
        return
    end

    local sortState, columns, key
    if id == "detailTitle" then
        sortState, columns, key = self.detailSort, self.DETAIL_COLUMNS, "name"
    else
        local table_, column = string.match(id, "^sort(%a+)_(%a+)$")
        if table_ == "Ware" then
            sortState, columns, key = self.wareSort, self.WARE_COLUMNS, column
        elseif table_ == "Detail" then
            sortState, columns, key = self.detailSort, self.DETAIL_COLUMNS, column
        end
    end
    if sortState == nil or columns[key] == nil then
        return
    end

    if sortState.key == key then
        sortState.asc = not sortState.asc
    else
        sortState.key = key
        sortState.asc = columns[key].isText
    end

    if sortState == self.wareSort then
        self:rebuildWareList()
    else
        self:updateDetail(self.detailWare)
    end
end

-- Die Spaltenköpfe sind laut Spielprofil 450px breit und überlappen sich. Damit ein Klick
-- beim richtigen Kopf landet, nimmt jeder Kopf nur Klicks auf seinem sichtbaren Text an.
local HEADER_HIT_PADDING = 0.006   -- Bildschirmanteil, etwas Rand um den Text

local function getHeaderTextWidth(button)
    local text = button.text or ""
    if button.getTextWidth ~= nil then
        local ok, width = pcall(button.getTextWidth, button)
        if ok and width ~= nil and width > 0 then
            return width
        end
    end
    if getTextWidth ~= nil and button.textSize ~= nil then
        return getTextWidth(button.textSize, text)
    end
    return button.absSize[1]
end

local function limitHeaderHitArea(button)
    if button == nil or button.limitedHitArea then
        return
    end
    button.limitedHitArea = true

    -- Button-Hintergrund in allen Zuständen unsichtbar (zusätzlich zum Profil)
    if button.setImageColor ~= nil and GuiOverlay ~= nil then
        for _, state in ipairs({ GuiOverlay.STATE_NORMAL, GuiOverlay.STATE_FOCUSED, GuiOverlay.STATE_SELECTED,
                                 GuiOverlay.STATE_HIGHLIGHTED, GuiOverlay.STATE_PRESSED, GuiOverlay.STATE_DISABLED }) do
            if state ~= nil then
                pcall(button.setImageColor, button, state, 0, 0, 0, 0)
            end
        end
    end

    local originalMouseEvent = button.mouseEvent
    button.mouseEvent = function(self, posX, posY, isDown, isUp, mouseButton, eventUsed)
        local width = getHeaderTextWidth(self)
        local x1, x2
        if RenderText ~= nil and self.textAlignment == RenderText.ALIGN_RIGHT then
            x2 = self.absPosition[1] + self.absSize[1]
            x1 = x2 - width
        else
            x1 = self.absPosition[1]
            x2 = x1 + width
        end
        if posX < x1 - HEADER_HIT_PADDING or posX > x2 + HEADER_HIT_PADDING then
            -- außerhalb des eigenen Textes: wie "Maus woanders" behandeln, Klick nicht verbrauchen
            return originalMouseEvent(self, -1, -1, isDown, isUp, mouseButton, eventUsed)
        end
        return originalMouseEvent(self, posX, posY, isDown, isUp, mouseButton, eventUsed)
    end
end

function LivingMarketFrame:setupSortHeaders()
    limitHeaderHitArea(self.filterButton)
    limitHeaderHitArea(self.viewMarketButton)
    limitHeaderHitArea(self.viewEventsButton)
    limitHeaderHitArea(self.detailTitle)
    for key in pairs(self.WARE_COLUMNS) do
        limitHeaderHitArea(self["sortWare_" .. key])
    end
    for key in pairs(self.DETAIL_COLUMNS) do
        limitHeaderHitArea(self["sortDetail_" .. key])
    end
end

-- Pfeil vor die Überschrift der sortierten Spalte setzen
function LivingMarketFrame:updateSortHeaders()
    local function apply(prefix, columns, sortState)
        local sortedElement = nil
        for key, column in pairs(columns) do
            local element = prefix == "Detail" and key == "name" and self.detailTitle or self["sort" .. prefix .. "_" .. key]
            if element ~= nil then
                local label
                if column.label ~= nil then
                    label = g_i18n:getText(column.label)
                elseif self.detailWare ~= nil then
                    label = self.detailWare.title
                else
                    label = g_i18n:getText("livingMarket_detailHint")
                end
                element:setText(label)
                if sortState.key == key then
                    sortedElement = element
                end
            end
        end
        return sortedElement
    end
    self:placeSortArrow(self.wareSortArrow, apply("Ware", self.WARE_COLUMNS, self.wareSort), self.wareSort.asc)
    self:placeSortArrow(self.detailSortArrow, apply("Detail", self.DETAIL_COLUMNS, self.detailSort), self.detailSort.asc)
end

-- Pfeil-Grafik links neben den sichtbaren Text der sortierten Spalte setzen.
-- (Die Spielschrift kann die Zeichen ▲/▼ nicht darstellen.)
local SORT_ARROW_GAP = 0.003   -- Bildschirmanteil zwischen Pfeil und Text

function LivingMarketFrame:placeSortArrow(arrow, header, asc)
    if arrow == nil then
        return
    end
    if header == nil or header.absPosition == nil then
        arrow:setVisible(false)
        return
    end

    arrow:setImageFilename(Utils.getFilename(asc and "images/sortUp.dds" or "images/sortDown.dds", LivingMarket.modDir))

    local textWidth = getHeaderTextWidth(header)
    local textLeft = header.absPosition[1]
    if RenderText ~= nil and header.textAlignment == RenderText.ALIGN_RIGHT then
        textLeft = header.absPosition[1] + header.absSize[1] - textWidth
    end
    local x = textLeft - arrow.absSize[1] - SORT_ARROW_GAP
    local y = header.absPosition[2] + (header.absSize[2] - arrow.absSize[2]) / 2
    arrow:setAbsolutePosition(x, y)
    arrow:setVisible(true)
end

-- ---------------------------------------------------------------------
-- Suche
-- ---------------------------------------------------------------------
-- Beim Tippen nur merken; gefiltert wird kurz danach in update()
function LivingMarketFrame:onSearchTextChanged(element, text)
    self.pendingSearchText = trim(text)
    self.searchTimer = self.SEARCH_DELAY
    if self.searchHint ~= nil then
        self.searchHint:setVisible(self.pendingSearchText == "")
    end
end

-- Enter: sofort filtern
function LivingMarketFrame:onSearchEnter(element)
    self.pendingSearchText = trim(element ~= nil and element.text or self.searchText)
    self:applySearch()
end

function LivingMarketFrame:applySearch()
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

function LivingMarketFrame:clearSearch()
    if self.searchInput ~= nil then
        self.searchInput:setText("")
    end
    self.searchText = ""
    self.pendingSearchText = nil
    self.searchTimer = nil
    self:updateSearchHint()
    self:rebuildWareList()
end

function LivingMarketFrame:updateSearchHint()
    if self.searchHint ~= nil then
        self.searchHint:setVisible(self.searchText == "")
    end
end

function LivingMarketFrame:isSearching()
    return self.searchText ~= ""
end

function LivingMarketFrame:update(dt)
    LivingMarketFrame:superClass().update(self, dt)

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
-- Klick auf den Filter: Alle → Lagernd → Favoriten → Alle
LivingMarketFrame.FILTER_NEXT  = { all = "stock", stock = "fav", fav = "all" }
LivingMarketFrame.FILTER_LABEL = { all = "livingMarket_filterAll", stock = "livingMarket_filterStock", fav = "livingMarket_filterFav" }

function LivingMarketFrame:onClickFilter()
    self.filterMode = self.FILTER_NEXT[self.filterMode] or "all"
    self:rebuildWareList()
end

function LivingMarketFrame:updateFilterButton()
    if self.filterButton ~= nil then
        self.filterButton:setText(g_i18n:getText(self.FILTER_LABEL[self.filterMode] or "livingMarket_filterAll"))
    end
end

-- Gewählte Ware als Favorit markieren bzw. Markierung entfernen
function LivingMarketFrame:onToggleFavorite()
    local ware = self.visibleWares ~= nil and self.visibleWares[self.selectedWareIndex] or nil
    if ware == nil then
        return
    end
    self.selectedFillType = ware.fillTypeIndex
    LivingMarket:toggleFavorite(ware.fillTypeIndex)
    self:rebuildWareList()
end

-- Fenster "Lagerorte" für die gewählte Ware
function LivingMarketFrame:onShowLocations()
    local ware = self.visibleWares ~= nil and self.visibleWares[self.selectedWareIndex] or nil
    if ware ~= nil and LivingMarketLocationDialog ~= nil then
        LivingMarketLocationDialog.show(ware.fillTypeIndex, ware.title)
    end
end

function LivingMarketFrame:onTestMonth()
    LivingMarket:simulateMonth()
    self:refreshData()
end

-- ---------------------------------------------------------------------
-- Ansicht umschalten: Markt / Marktnachrichten
-- ---------------------------------------------------------------------
local VIEW_ACTIVE   = { 0.212, 0.376, 0.012, 1 }   -- LS-Grün
local VIEW_INACTIVE = { 0.85, 0.85, 0.85, 1 }

function LivingMarketFrame:onClickViewMarket()
    self:setViewMode("market")
end

function LivingMarketFrame:onClickViewEvents()
    self:setViewMode("events")
end

function LivingMarketFrame:setViewMode(mode)
    self.viewMode = mode
    local showMarket = mode ~= "events"

    for _, element in ipairs({ self.wareFrame, self.wareHeader, self.wareArea, self.detailPanel,
                               self.filterButton, self.searchInput }) do
        if element ~= nil then
            element:setVisible(showMarket)
        end
    end
    if self.emptyText ~= nil and not showMarket then
        self.emptyText:setVisible(false)
    end
    for _, element in ipairs({ self.eventFrame, self.eventHeader, self.eventArea }) do
        if element ~= nil then
            element:setVisible(not showMarket)
        end
    end

    if showMarket then
        self:rebuildWareList()   -- setzt auch den Hinweis bei leerer Liste
        if self.eventEmptyText ~= nil then
            self.eventEmptyText:setVisible(false)
        end
    else
        self:refreshEvents()
    end

    local function paint(button, active)
        if button ~= nil then
            local c = active and VIEW_ACTIVE or VIEW_INACTIVE
            button:setTextColor(c[1], c[2], c[3], c[4])
            if button.setTextSelectedColor ~= nil then
                button:setTextSelectedColor(c[1], c[2], c[3], c[4])
            end
            if button.setTextFocusedColor ~= nil then
                button:setTextFocusedColor(c[1], c[2], c[3], c[4])
            end
        end
    end
    paint(self.viewMarketButton, showMarket)
    paint(self.viewEventsButton, not showMarket)
    self:updateMenuButtons()
end

function LivingMarketFrame:refreshEvents()
    self.eventRows = LivingMarket:getEventList()
    if self.eventEmptyText ~= nil then
        self.eventEmptyText:setVisible(self.viewMode == "events" and #self.eventRows == 0)
    end
    if self.eventList ~= nil then
        self.eventList:reloadData(true)
    end
end

-- Eine Zeile der Marktnachrichten
local EVENT_TYPE_LABELS = { [1] = "livingMarket_evLabelShortage", [2] = "livingMarket_evLabelSurplus",
                            [3] = "livingMarket_evLabelBoom",     [4] = "livingMarket_evLabelSlump" }

function LivingMarketFrame:populateEventCell(row, cell)
    if row == nil or cell:getAttribute("type") == nil then
        return
    end
    local positive = row.type == LivingMarket.EVENT_SHORTAGE or row.type == LivingMarket.EVENT_BOOM
    local typeColor = positive and COLOR_GOOD or COLOR_LOW
    local main = row.pending and COLOR_MUTED_LIGHT or COLOR_TEXT

    local function put(name, text, color)
        local element = cell:getAttribute(name)
        if element ~= nil then
            element:setText(text or "")
            setTextColorAll(element, color or COLOR_TEXT)
        end
    end
    put("type", g_i18n:getText(EVENT_TYPE_LABELS[row.type] or "livingMarket_evLabelShortage"), typeColor)
    put("ware", row.wareTitle, main)
    put("station", row.stationName, main)
    put("price", string.format("%+d %%", row.pricePercent), typeColor)
    put("demand", (string.gsub(string.format("x%.1f", row.maxFactor), "%.", ",")), main)
    put("start", row.startText, row.pending and COLOR_MID or main)
    put("end", row.endText, main)
    put("status", g_i18n:getText(row.pending and "livingMarket_evPending" or "livingMarket_evRunning"),
        row.pending and COLOR_MID or COLOR_GOOD)
    setWareIcon(cell:getAttribute("icon"), row.fillTypeIndex)
end

function LivingMarketFrame:onTestRefill()
    LivingMarket:simulateHours(1)
    self:refreshData()
end

function LivingMarketFrame:updateMenuButtons()
    self:updateFilterButton()

    self.menuButtonInfo = { self.backButtonInfo }
    local ware = self.visibleWares ~= nil and self.visibleWares[self.selectedWareIndex] or nil
    if self.viewMode == "events" then
        ware = nil   -- in den Marktnachrichten keine Favoriten-Taste
    end
    if ware ~= nil then
        table.insert(self.menuButtonInfo, self.locationButtonInfo)
        self.favButtonInfo.text = g_i18n:getText(LivingMarket:isFavorite(ware.fillTypeIndex) and "livingMarket_favRemove" or "livingMarket_favAdd")
        table.insert(self.menuButtonInfo, self.favButtonInfo)
    end
    if self:isSearching() and self.viewMode ~= "events" then
        table.insert(self.menuButtonInfo, self.clearSearchButtonInfo)
    end
    -- Testknopf nur im Debug-Modus und nur, wo der Bedarf verwaltet wird (Server/Einzelspieler)
    if LivingMarket.DEBUG and g_server ~= nil then
        table.insert(self.menuButtonInfo, self.testRefillButtonInfo)
        if InputAction.MENU_ACCEPT ~= nil then
            table.insert(self.menuButtonInfo, self.testMonthButtonInfo)
        end
    end
    self:setMenuButtonInfoDirty()
end

-- ---------------------------------------------------------------------
-- Datenquelle für beide Listen
-- ---------------------------------------------------------------------
function LivingMarketFrame:getNumberOfSections(list)
    return 1
end

function LivingMarketFrame:getNumberOfItemsInSection(list, section)
    if list == self.wareList then
        return #self.visibleWares
    elseif list == self.eventList then
        return #self.eventRows
    end
    return #self.detailStations
end

function LivingMarketFrame:getCellTypeForItemInSection(list, section, index)
    if list == self.eventList then
        return "event"
    end
    return list == self.wareList and "ware" or "station"
end

-- Zeilenhintergrund wie im Vorbild: abwechselnd dunkel/heller, ausgewählt in LS-Grün
local ROW_DARK      = { 0.023, 0.023, 0.023, 1 }   -- #2a2a2a
local ROW_LIGHT     = { 0.033, 0.033, 0.033, 1 }   -- #333333
local ROW_SELECTED  = { 0.212, 0.376, 0.012, 1 }   -- #7fa51c

local function setRowBackground(bg, index, isSelected)
    if bg == nil or bg.setImageColor == nil or GuiOverlay == nil or GuiOverlay.STATE_NORMAL == nil then
        return
    end
    local c = isSelected and ROW_SELECTED or ((index % 2 == 0) and ROW_LIGHT or ROW_DARK)
    bg:setImageColor(GuiOverlay.STATE_NORMAL, c[1], c[2], c[3], c[4])
end

function LivingMarketFrame:populateCellForItemInSection(list, section, index, cell)
    if list == self.eventList then
        setRowBackground(cell:getAttribute("bg"), index, false)
        self:populateEventCell(self.eventRows[index], cell)
        return
    end
    local isSelected = list == self.wareList and index == self.selectedWareIndex
    setRowBackground(cell:getAttribute("bg"), index, isSelected)

    if list == self.wareList then
        self:populateWareCell(self.visibleWares[index], cell, isSelected)
    elseif self.detailWare ~= nil then
        self:populateStationCell(self.detailStations[index], cell)
    end
end

function LivingMarketFrame:populateWareCell(ware, cell, isSelected)
    if ware == nil or cell:getAttribute("title") == nil then
        return
    end

    -- In der gewählten (grünen) Zeile ist jede Schrift dunkel.
    -- Waren ohne Lagerbestand ausgegraut, wie volle Stationen im Detailfenster.
    local noStock = (ware.stock or 0) < 1
    local function setColor(textElement, c)
        if isSelected then
            c = COLOR_ON_GREEN
        elseif noStock then
            c = COLOR_MUTED
        end
        setTextColorAll(textElement, c)
    end

    local favText = cell:getAttribute("fav")
    if favText ~= nil then
        local isFav = LivingMarket:isFavorite(ware.fillTypeIndex)
        favText:setText(isFav and "*" or "-")
        setColor(favText, isFav and COLOR_MID or COLOR_MUTED)
    end

    setWareIcon(cell:getAttribute("icon"), ware.fillTypeIndex)
    cell:getAttribute("title"):setText(ware.title)
    setColor(cell:getAttribute("title"), COLOR_TEXT)
    cell:getAttribute("stock"):setText(ware.stock >= 1 and LivingMarket.formatLiters(ware.stock) or "-")
    setColor(cell:getAttribute("stock"), COLOR_TEXT)

    local highPriceText = cell:getAttribute("highPrice")
    if highPriceText ~= nil then
        highPriceText:setText(ware.year ~= nil and formatPrice(ware.year.max) or "-")
        setColor(highPriceText, COLOR_TEXT)
    end
    local bestMonthText = cell:getAttribute("bestMonth")
    if bestMonthText ~= nil then
        if ware.year ~= nil then
            bestMonthText:setText(LivingMarket.getMonthName(ware.year.maxMonth))
            -- jetzt ist der beste Monat: grün
            setColor(bestMonthText, ware.year.maxMonth == LivingMarket.getCurrentMonth() and COLOR_GOOD or COLOR_TEXT)
        else
            bestMonthText:setText("-")
            setColor(bestMonthText, COLOR_TEXT)
        end
    end


    local stationText = cell:getAttribute("station")
    local priceText = cell:getAttribute("price")
    local marketText = cell:getAttribute("market")
    local deviationText = cell:getAttribute("deviation")
    local sellableText = cell:getAttribute("sellable")
    local revenueText = cell:getAttribute("revenue")

    if ware.best == nil then
        -- Keine Station mit freiem Bedarf
        stationText:setText(g_i18n:getText("livingMarket_allFull"))
        setColor(stationText, COLOR_LOW)
        priceText:setText("-")
        setColor(priceText, COLOR_TEXT)
        setTrendIcon(cell:getAttribute("trend"), nil, nil)
        if marketText ~= nil then
            marketText:setText("-")
            setColor(marketText, COLOR_MUTED)
        end
        if deviationText ~= nil then
            deviationText:setText("-")
            setColor(deviationText, COLOR_MUTED)
        end
        sellableText:setText("-")
        setColor(sellableText, COLOR_TEXT)
        revenueText:setText("-")
        setColor(revenueText, COLOR_MUTED)
        return
    end

    stationText:setText(ware.best.name)
    local _, eventColor = getEventText(ware.best.eventType, ware.best.eventPrice)
    setColor(stationText, ware.isBestStation and COLOR_GOOD or eventColor or COLOR_TEXT)
    priceText:setText(formatPrice(ware.best.price))
    setColor(priceText, COLOR_TEXT)
    setTrendIcon(cell:getAttribute("trend"), ware.best.price, ware.marketPrice)
    if marketText ~= nil then
        local text, color = getMarketText(ware.best.factor)
        marketText:setText(text)
        setColor(marketText, color)
    end
    if deviationText ~= nil then
        local text, color = getDeviationText(ware.best.price, ware.marketPrice)
        deviationText:setText(text)
        setColor(deviationText, color)
    end

    if ware.sellable >= 1 then
        sellableText:setText(LivingMarket.formatLiters(ware.sellable))
        setColor(sellableText, COLOR_TEXT)
        revenueText:setText(LivingMarket.formatMoney(ware.revenue))
        setColor(revenueText, COLOR_GOOD)
    else
        sellableText:setText("-")
        setColor(sellableText, COLOR_TEXT)
        revenueText:setText("-")
        setColor(revenueText, COLOR_MUTED)
    end
end

function LivingMarketFrame:populateStationCell(station, cell)
    if station == nil or cell:getAttribute("name") == nil then
        return
    end

    local isFull = station.remaining < 1
    local nameText = cell:getAttribute("name")
    local priceText = cell:getAttribute("price")
    local amountText = cell:getAttribute("amount")
    local shareText = cell:getAttribute("share")
    local marketText = cell:getAttribute("market")
    local deviationText = cell:getAttribute("deviation")

    nameText:setText(station.name)
    priceText:setText(formatPrice(station.price))
    local deliverable = station.deliverable or station.remaining
    amountText:setText(deliverable >= 1 and LivingMarket.formatLiters(deliverable) or "-")
    local eventText = cell:getAttribute("event")
    if eventText ~= nil then
        local text, color = getEventText(station.eventType, station.eventPrice)
        eventText:setText(text or "")
        setColor(eventText, isFull and COLOR_MUTED or color or COLOR_TEXT)
    end
    local revenueText = cell:getAttribute("revenue")
    if revenueText ~= nil then
        if (station.revenue or 0) >= 1 then
            revenueText:setText(LivingMarket.formatMoney(station.revenue))
            setColor(revenueText, isFull and COLOR_MUTED or COLOR_GOOD)
        else
            revenueText:setText("-")
            setColor(revenueText, COLOR_MUTED)
        end
    end
    local maxText = cell:getAttribute("max")
    if maxText ~= nil then
        maxText:setText(LivingMarket.formatLiters(station.max))
        setColor(maxText, isFull and COLOR_MUTED or COLOR_TEXT)
    end
    shareText:setText(string.format("%d %%", math.floor(station.share * 100 + 0.5)))

    -- Volle Stationen ausgegraut
    local main = isFull and COLOR_MUTED or COLOR_TEXT
    setColor(nameText, main)
    -- Vergleich mit dem Marktpreis des aktuellen Monats
    local basePrice = self.detailWare ~= nil and (self.detailWare.marketPrice or self.detailWare.basePrice) or nil
    setColor(priceText, main)
    setTrendIcon(cell:getAttribute("trend"), station.price, basePrice)
    setColor(amountText, main)
    setColor(shareText, isFull and COLOR_MUTED or shareColor(station.share))
    if marketText ~= nil then
        local text, color = getMarketText(station.factor)
        marketText:setText(text)
        setColor(marketText, isFull and COLOR_MUTED or color)
    end
    if deviationText ~= nil then
        local text, color = getDeviationText(station.price, basePrice)
        deviationText:setText(text)
        setColor(deviationText, isFull and COLOR_MUTED or color)
    end
end
