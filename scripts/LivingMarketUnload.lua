-- =====================================================================
-- Hinweise beim Abladen an einer begrenzten Verkaufsstelle
--
-- 1. Kurzmeldung nach dem Abladen: Menge, Erlös, Preis jetzt (Änderung), freier Bedarf
-- 2. Warnung, sobald die Station während des Abladens voll ist, mit der besten Alternative
--
-- Der Server verfolgt jeden Abladevorgang (Hof + Station + Ware). Nach einer kurzen
-- Pause gilt er als beendet. Meldungen gehen nur an den abladenden Hof.
-- Lieferungen für Aufträge und Verträge zählen nicht (die haben eigene Meldungen).
-- =====================================================================

LivingMarket.UNLOAD_IDLE_TIME  = 5000   -- ms ohne weitere Lieferung = Abladen beendet
LivingMarket.UNLOAD_MIN_LITERS = 1      -- kleinere Mengen ohne Meldung

LivingMarket.UNLOAD_SUMMARY = 1
LivingMarket.UNLOAD_FULL    = 2

LivingMarket.unloads = {}   -- [Station][Hof * 65536 + Ware] = laufender Abladevorgang (nur Server)
LivingMarket.unloadCount = 0

local function isMultiplayerGame()
    return g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer == true
end

local function isPlayerFarm(farmId)
    local spectator = FarmManager ~= nil and FarmManager.SPECTATOR_FARM_ID or 15
    return farmId ~= nil and farmId ~= 0 and farmId ~= spectator
end

local function freePercent(entry)
    if entry == nil or entry.max == nil or entry.max <= 0 then
        return 0
    end
    return math.max(0, math.min(100, math.floor(entry.remaining / entry.max * 100 + 0.5)))
end

-- Beste andere Station für die Ware: höchster Preis bei freiem Bedarf
function LivingMarket:findUnloadAlternative(station, fillTypeIndex)
    local best, bestPrice, bestFree = nil, 0, 0
    for _, other in ipairs(self:collectStations()) do
        if other ~= station then
            local entry = self:getEntry(other, fillTypeIndex)
            if entry ~= nil and entry.remaining >= 1 and self:isContractWareSellable(other, fillTypeIndex) then
                local price = self:getPricePer1000(other, fillTypeIndex)
                if price > bestPrice then
                    best, bestPrice, bestFree = other, price, freePercent(entry)
                end
            end
        end
    end
    if best == nil then
        return nil
    end
    return self:getStationNameOf(best) or "?", bestPrice, bestFree
end

-- Aus addFillLevelFromTool (Server): angenommene Menge eines Abladeschritts
function LivingMarket:trackUnload(station, farmId, fillTypeIndex, liters, pricePer1000, entry)
    if not isPlayerFarm(farmId) or liters == nil or liters <= 0 then
        return
    end
    -- Schlüssel ohne Zeichenketten (wird in jedem Bild des Abladens aufgerufen)
    local byStation = self.unloads[station]
    if byStation == nil then
        byStation = {}
        self.unloads[station] = byStation
    end
    local key = farmId * 65536 + fillTypeIndex
    local unload = byStation[key]
    if unload == nil then
        unload = {
            station       = station,
            farmId        = farmId,
            fillTypeIndex = fillTypeIndex,
            entry         = entry,
            liters        = 0,
            money         = 0,
            startPrice    = pricePer1000,
        }
        byStation[key] = unload
        self.unloadCount = self.unloadCount + 1
    end
    unload.liters = unload.liters + liters
    unload.money = unload.money + liters * (pricePer1000 or 0) / 1000
    unload.idle = 0

    -- Station während des Abladens voll: sofort warnen (einmal je Abladevorgang)
    if entry ~= nil and entry.remaining < 1 and not unload.fullWarned then
        unload.fullWarned = true
        local altName, altPrice, altFree = self:findUnloadAlternative(station, fillTypeIndex)
        self:sendUnloadNotification({
            kind          = self.UNLOAD_FULL,
            farmId        = farmId,
            fillTypeIndex = fillTypeIndex,
            stationName   = self:getStationNameOf(station) or "?",
            altName       = altName or "",
            altPrice      = altPrice or 0,
            altFree       = altFree or 0,
        })
    end
end

-- Jedes Bild (Server): beendete Abladevorgänge melden
function LivingMarket:updateUnloads(dt)
    if self.unloadCount == 0 then
        return
    end
    for station, byStation in pairs(self.unloads) do
        for key, unload in pairs(byStation) do
            unload.idle = (unload.idle or 0) + dt
            if unload.idle > self.UNLOAD_IDLE_TIME then
                byStation[key] = nil
                self.unloadCount = self.unloadCount - 1
                self:finishUnload(unload)
            end
        end
        if next(byStation) == nil then
            self.unloads[station] = nil
        end
    end
end

-- Abladen beendet: Kurzmeldung schicken
function LivingMarket:finishUnload(unload)
    if unload.liters < self.UNLOAD_MIN_LITERS then
        return
    end
    local priceNow = self:getPricePer1000(unload.station, unload.fillTypeIndex)
    local change = 0
    if unload.startPrice ~= nil and unload.startPrice > 0 then
        change = (priceNow / unload.startPrice - 1) * 100
    end
    self:sendUnloadNotification({
        kind          = self.UNLOAD_SUMMARY,
        farmId        = unload.farmId,
        fillTypeIndex = unload.fillTypeIndex,
        stationName   = self:getStationNameOf(unload.station) or "?",
        liters        = unload.liters,
        money         = unload.money,
        price         = priceNow,
        change        = change,
        free          = freePercent(unload.entry),
    })
end

function LivingMarket:sendUnloadNotification(data)
    self:showUnloadNotification(data)
    if isMultiplayerGame() and g_server ~= nil and LivingMarketUnloadNotifyEvent ~= nil then
        g_server:broadcastEvent(LivingMarketUnloadNotifyEvent.new(data))
    end
end

-- Meldung anzeigen (nur beim abladenden Hof, in der eigenen Sprache)
function LivingMarket:showUnloadNotification(data)
    local ownFarm = self:getFarmId()
    if ownFarm == nil or ownFarm ~= data.farmId then
        return
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(data.fillTypeIndex)
    local ware = fillType ~= nil and (fillType.title or fillType.name) or "?"
    local text
    if data.kind == self.UNLOAD_FULL then
        text = string.format(g_i18n:getText("livingMarket_unloadFull"), data.stationName, ware)
        if data.altName ~= nil and data.altName ~= "" then
            text = text .. " " .. string.format(g_i18n:getText("livingMarket_unloadAlt"),
                data.altName, self.formatMoney(data.altPrice or 0), data.altFree or 0)
        else
            text = text .. " " .. g_i18n:getText("livingMarket_unloadNoAlt")
        end
        self:notify(text, true)
    else
        local raw = data.change or 0
        local change = math.floor(raw + (raw >= 0 and 0.5 or -0.5))
        local changeText = change == 0 and "±0 %" or string.format("%+d %%", change)
        text = string.format(g_i18n:getText("livingMarket_unloadSummary"), ware, data.stationName,
            self.formatLiters(data.liters or 0), self.formatMoney(data.money or 0),
            self.formatMoney(data.price or 0), changeText, data.free or 0)
        self:notify(text, false)
    end
end

function LivingMarket:resetUnloads()
    self.unloads = {}
    self.unloadCount = 0
end
