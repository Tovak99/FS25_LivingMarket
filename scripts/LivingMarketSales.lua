-- =====================================================================
-- Verkaufsverlauf: die letzten 50 Verkäufe je Hof
--
-- Erfasst wird beim eigentlichen Verkauf (SellingStation.sellFillType), damit alles
-- mitkommt, was an einer Verkaufsstelle Geld bringt: Schüttgut, Flüssiges, Paletten,
-- Ballen ... Lieferungen für laufende Aufträge werden nicht erfasst.
-- Ein Abladevorgang (gleicher Hof, Station und Ware ohne längere Pause) wird zu
-- einem Eintrag zusammengefasst – auch wenn dazwischen andere Waren verkauft werden
-- (z. B. Paletten verschiedener Waren abwechselnd).
-- Server führt die Liste, speichert sie im Spielstand und schickt sie an die Mitspieler.
-- =====================================================================

LivingMarket.SALES_MAX        = 50      -- Einträge je Hof
LivingMarket.SALES_MERGE_TIME = 30000   -- ms: gleiche Station + Ware ohne längere Pause = ein Abladevorgang

LivingMarket.sales        = {}   -- [farmId] = { sale, ... } neueste zuerst
LivingMarket.saleNextId   = 1
LivingMarket.salesDirty   = {}   -- [id] = sale (Server, noch an Mitspieler zu schicken)
LivingMarket.salesVersion = 0    -- zählt bei jeder Änderung hoch (Menüseite aktualisiert sich)

local function isServerSide()
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

local function isMultiplayerGame()
    return g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer == true
end

-- Spielzeit in Minuten seit Spielbeginn
function LivingMarket.getNowMinute()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil then
        return 0
    end
    local day = env.currentMonotonicDay or env.currentDay or 0
    return day * 1440 + math.floor((env.dayTime or 0) / 60000)
end

-- Zeitpunkt (absolute Minute) als "Okt 14:35" bzw. "Okt 2. 14:35"
function LivingMarket:formatSaleTime(absMinute)
    local text = self:formatEventTime(math.floor(absMinute / 60))
    return (string.gsub(text, "(%d%d):00$", "%1:" .. string.format("%02d", absMinute % 60)))
end

local function sortSales(list)
    table.sort(list, function(a, b) return a.id > b.id end)
    while #list > LivingMarket.SALES_MAX do
        table.remove(list)
    end
end

function LivingMarket:recordSale(station, farmId, fillTypeIndex, liters, money)
    if not isServerSide() or station == nil or fillTypeIndex == nil or liters == nil or liters <= 0 then
        return
    end
    if farmId == nil or farmId == 0 or (FarmManager ~= nil and farmId == FarmManager.SPECTATOR_FARM_ID) then
        return
    end
    if self:isMissionDelivery(station, fillTypeIndex, farmId) then
        return   -- Auftragsware zählt nicht als eigener Verkauf
    end

    local list = self.sales[farmId]
    if list == nil then
        list = {}
        self.sales[farmId] = list
    end
    local stationKey = self:getStationKey(station)
    local now = g_time or 0
    -- Vertragslieferung (Festpreis) als eigener Eintrag, markiert als "Vertrag"
    local override = self.contractOverride
    local isContract = override ~= nil and override.station == station and override.fillTypeIndex == fillTypeIndex
    -- laufenden Abladevorgang derselben Station und Ware suchen (nicht nur den obersten Eintrag)
    local sale = nil
    for _, existing in ipairs(list) do
        if existing.stationKey == stationKey and existing.fillTypeIndex == fillTypeIndex
            and (existing.eventType == self.EVENT_CONTRACT) == isContract
            and existing.realTime ~= nil and now - existing.realTime < self.SALES_MERGE_TIME then
            sale = existing
            break
        end
    end
    if sale ~= nil then
        sale.liters = sale.liters + liters
        sale.money = sale.money + (money or 0)
        sale.realTime = now
    else
        local entry = self:getEntry(station, fillTypeIndex)
        sale = {
            id            = self.saleNextId,
            farmId        = farmId,
            fillTypeIndex = fillTypeIndex,
            stationKey    = stationKey,
            stationName   = self:getStationNameOf(station) or "?",
            liters        = liters,
            money         = money or 0,
            minute        = self.getNowMinute(),
            factor        = (entry ~= nil and not isContract) and self:getDemandFactor(station, fillTypeIndex) or 1,   -- Marktlage zu Beginn
            eventType     = isContract and self.EVENT_CONTRACT or (entry ~= nil and entry.eventType or 0),
            realTime      = now,
        }
        self.saleNextId = self.saleNextId + 1
        table.insert(list, 1, sale)
        sortSales(list)
    end
    self.salesDirty[sale.id] = sale
    self.salesVersion = self.salesVersion + 1
end

-- Verkäufe des eigenen Hofs (für die Menüseite)
function LivingMarket:getSalesForFarm(farmId)
    return self.sales[farmId or 0] or {}
end

-- Mitspieler: Verkäufe vom Server übernehmen (neu oder aktualisiert)
function LivingMarket:applySales(sales, replace)
    if replace then
        self.sales = {}
    end
    for _, sale in ipairs(sales) do
        local list = self.sales[sale.farmId]
        if list == nil then
            list = {}
            self.sales[sale.farmId] = list
        end
        local found = false
        for i, existing in ipairs(list) do
            if existing.id == sale.id then
                list[i] = sale
                found = true
                break
            end
        end
        if not found then
            table.insert(list, sale)
        end
        sortSales(list)
    end
    self.salesVersion = self.salesVersion + 1
end

local function collectAllSales()
    local all = {}
    for _, list in pairs(LivingMarket.sales) do
        for _, sale in ipairs(list) do
            table.insert(all, sale)
        end
    end
    return all
end

-- Server: geänderte Verkäufe etwa einmal pro Sekunde an alle schicken
function LivingMarket:updateSalesSync(dt)
    if not isServerSide() or not isMultiplayerGame() or LivingMarketSalesEvent == nil then
        self.salesDirty = {}
        return
    end
    self.salesSyncTimer = (self.salesSyncTimer or 0) - dt
    if self.salesSyncTimer > 0 or next(self.salesDirty) == nil then
        return
    end
    self.salesSyncTimer = 1000
    local changed = {}
    for _, sale in pairs(self.salesDirty) do
        table.insert(changed, sale)
    end
    self.salesDirty = {}
    g_server:broadcastEvent(LivingMarketSalesEvent.new(changed, false))
end

function LivingMarket:sendSalesToConnection(connection)
    if LivingMarketSalesEvent ~= nil then
        connection:sendEvent(LivingMarketSalesEvent.new(collectAllSales(), true))
    end
end

-- ---------------------------------------------------------------------
-- Speichern / Laden (Zeit relativ zu jetzt in Minuten)
-- ---------------------------------------------------------------------
function LivingMarket:saveSalesToXML(xmlFile, baseKey)
    local now = self.getNowMinute()
    local i = 0
    for _, sale in ipairs(collectAllSales()) do
        local name = g_fillTypeManager:getFillTypeNameByIndex(sale.fillTypeIndex)
        if name ~= nil then
            local key = string.format("%s.sale(%d)", baseKey, i)
            setXMLInt(xmlFile, key .. "#id", sale.id)
            setXMLInt(xmlFile, key .. "#farm", sale.farmId)
            setXMLString(xmlFile, key .. "#fillType", name)
            setXMLString(xmlFile, key .. "#station", sale.stationName or "")
            setXMLFloat(xmlFile, key .. "#liters", sale.liters)
            setXMLFloat(xmlFile, key .. "#money", sale.money)
            setXMLInt(xmlFile, key .. "#minutesAgo", math.max(0, now - (sale.minute or now)))
            setXMLFloat(xmlFile, key .. "#factor", sale.factor or 1)
            setXMLInt(xmlFile, key .. "#eventType", sale.eventType or 0)
            i = i + 1
        end
    end
end

function LivingMarket:loadSalesFromXML(xmlFile, baseKey)
    self.sales = {}
    local now = self.getNowMinute()
    local maxId = 0
    local i = 0
    while true do
        local key = string.format("%s.sale(%d)", baseKey, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local fillTypeName = getXMLString(xmlFile, key .. "#fillType")
        local fillTypeIndex = fillTypeName ~= nil and g_fillTypeManager:getFillTypeIndexByName(fillTypeName) or nil
        local farmId = getXMLInt(xmlFile, key .. "#farm")
        if fillTypeIndex ~= nil and farmId ~= nil then
            local sale = {
                id            = getXMLInt(xmlFile, key .. "#id") or (i + 1),
                farmId        = farmId,
                fillTypeIndex = fillTypeIndex,
                stationName   = getXMLString(xmlFile, key .. "#station") or "?",
                liters        = getXMLFloat(xmlFile, key .. "#liters") or 0,
                money         = getXMLFloat(xmlFile, key .. "#money") or 0,
                minute        = now - (getXMLInt(xmlFile, key .. "#minutesAgo") or 0),
                factor        = getXMLFloat(xmlFile, key .. "#factor") or 1,
                eventType     = getXMLInt(xmlFile, key .. "#eventType") or 0,
            }
            maxId = math.max(maxId, sale.id)
            self.sales[farmId] = self.sales[farmId] or {}
            table.insert(self.sales[farmId], sale)
        end
        i = i + 1
    end
    for _, list in pairs(self.sales) do
        sortSales(list)
    end
    self.saleNextId = maxId + 1
    self.salesVersion = self.salesVersion + 1
end

function LivingMarket:resetSales()
    self.sales = {}
    self.saleNextId = 1
    self.salesDirty = {}
    self.salesVersion = self.salesVersion + 1
end

-- ---------------------------------------------------------------------
-- Hook: jeder Verkauf an einer Verkaufsstelle
-- ---------------------------------------------------------------------
function LivingMarket.sellFillType(station, superFunc, farmId, fillDelta, fillTypeIndex, ...)
    local result = superFunc(station, farmId, fillDelta, fillTypeIndex, ...)
    local ok, err = pcall(function()
        if fillDelta ~= nil and fillDelta > 0 then
            local money = type(result) == "number" and result or nil
            if money == nil and station.getEffectiveFillTypePrice ~= nil then
                money = fillDelta * (station:getEffectiveFillTypePrice(fillTypeIndex) or 0)
            end
            LivingMarket:recordSale(station, farmId, fillTypeIndex, fillDelta, money or 0)
        end
    end)
    if not ok then
        print("[LivingMarket] FEHLER im Verkaufsverlauf: " .. tostring(err))
    end
    return result
end

if SellingStation ~= nil and SellingStation.sellFillType ~= nil then
    SellingStation.sellFillType = Utils.overwrittenFunction(SellingStation.sellFillType, LivingMarket.sellFillType)
    LivingMarket.hasSellHook = true
else
    print("[LivingMarket] WARNUNG: SellingStation.sellFillType nicht gefunden - Verkaufsverlauf nur für begrenzte Waren")
    LivingMarket.hasSellHook = false
end
