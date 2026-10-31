-- =====================================================================
-- Lieferverträge (Ausschreibungen) und Ansehen
--
-- Stationen der Karte schreiben Lieferungen aus: Menge einer Ware bis zu einer Frist
-- zum Festpreis (Marktpreis des Monats + Aufschlag, höchstens +10 %). Ein Hof nimmt
-- die Ausschreibung an und liefert aus eigenem Bestand. Vertragslieferungen werden zum
-- Festpreis bezahlt, zählen nicht gegen die freie Liefermenge und unterliegen nicht der
-- Marktlage. Vollständig geliefert: Bonus und mehr Ansehen. Frist verpasst oder
-- gekündigt: Strafe auf die fehlende Menge und weniger Ansehen.
--
-- Ansehen je Hof und Station 0..100 (Start 50 = 3 Sterne), pendelt jeden Monat
-- langsam zurück zur Mitte. Unter 2 Sternen keine Angebote dieser Station für den Hof.
--
-- Server verwaltet alles; Mitspieler bekommen die Liste und schicken Annahme/Kündigung.
-- =====================================================================

LivingMarket.CONTRACT_SETTINGS = {
    enabled          = true,
    minOffers        = 3,      -- nicht mehr verwendet (Anzahl = Option "Anzahl der Verträge", Standard 6)
    maxOffers        = 6,      -- nicht mehr verwendet
    offerMonths      = 1,      -- nicht angenommene Ausschreibung verfällt nach ...
    minMonths        = 1,      -- Frist ab Annahme
    maxMonths        = 3,
    minShare         = 0.30,   -- Menge als Anteil vom Maximum der Station
    maxShare         = 0.80,
    minMarkup        = 0.02,   -- Grundaufschlag auf den Marktpreis
    maxMarkup        = 0.05,
    reputationMarkup = 0.03,   -- zusätzlich bei bestem Ansehen
    eventMarkup      = 0.02,   -- zusätzlich bei Engpass/Nachgefragt an der Station
    maxTotalMarkup   = 0.10,   -- Aufschlag insgesamt höchstens
    bonusRate        = 0.20,   -- Bonus bei vollständiger Lieferung (Anteil vom Vertragswert)
    penaltyRate      = 0.50,   -- Strafe auf den Wert der fehlenden Menge
    maxActivePerFarm = 3,      -- laufende Verträge je Hof
    repStart         = 50,
    repFulfilled     = 2,      -- mittlerer Auftragswert
    repFulfilledSmall = 1,     -- Vertragswert unter repSmallValue
    repFulfilledLarge = 3,     -- Vertragswert ab repLargeValue
    repSmallValue    = 22500,  -- €
    repLargeValue    = 90000,  -- €
    repFailed        = 10,
    repDriftPerMonth = 1,
    repMinStars      = 2,      -- darunter keine Angebote dieser Station
}

LivingMarket.EVENT_CONTRACT = 100   -- Markierung in der Verkaufsliste

LivingMarket.contracts       = {}   -- { id, state = "offer"|"active", stationKey, stationName, fillTypeIndex, amount, basePrice, markup, eventMarkup, months, offerEndHour, farmId, price, bonus, deadlineHour, delivered }
LivingMarket.contractNextId  = 1
LivingMarket.reputation      = {}   -- [farmId] = { [stationKey] = 0..100 }
LivingMarket.contractHistory = {}   -- abgeschlossene Verträge, neueste zuerst: { id, farmId, result = "done"|"failed"|"cancelled", stationKey, stationName, fillTypeIndex, amount, delivered, price, money, endHour }
LivingMarket.CONTRACT_HISTORY_MAX = 20   -- je Hof
LivingMarket.contractsVersion = 0
LivingMarket.contractOverride = nil  -- während einer Vertragslieferung: { station, fillTypeIndex, pricePerLiter }

-- Option "Anzahl der Verträge" (Optionsseite, gilt für das ganze Spiel, im Spielstand):
-- so viele Ausschreibungen gibt es gleichzeitig; fehlende werden innerhalb eines Spieltags ersetzt
LivingMarket.MAX_CONTRACTS_LIMIT = 15    -- höchster einstellbarer Wert
LivingMarket.DEFAULT_CONTRACTS   = 6     -- Standard (nichts im Spielstand)
LivingMarket.maxContractsSetting = nil   -- nil = Standard
LivingMarket.CONTRACT_REFILL_HOURS = 24  -- fehlende Ausschreibungen spätestens nach so vielen Spielstunden ersetzt
LivingMarket.contractSpawnHours = {}     -- geplante Zeitpunkte (Spielstunde) für neue Ausschreibungen

local function isServerSide()
    return g_currentMission ~= nil and g_currentMission:getIsServer()
end

local function isMultiplayerGame()
    return g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer == true
end

local function randomRange(minValue, maxValue)
    return minValue + math.random() * (maxValue - minValue)
end

-- ---------------------------------------------------------------------
-- Ansehen
-- ---------------------------------------------------------------------
function LivingMarket:getReputation(farmId, stationKey)
    local farm = self.reputation[farmId or 0]
    local value = farm ~= nil and farm[stationKey] or nil
    return value or self.CONTRACT_SETTINGS.repStart
end

function LivingMarket.getReputationStars(value)
    return math.max(1, math.min(5, math.floor((value or 50) / 20) + 1))
end

function LivingMarket:changeReputation(farmId, stationKey, delta)
    if farmId == nil or stationKey == nil then
        return
    end
    self.reputation[farmId] = self.reputation[farmId] or {}
    local value = self:getReputation(farmId, stationKey) + delta
    self.reputation[farmId][stationKey] = math.max(0, math.min(100, value))
end

-- Jeden Monat: Ansehen pendelt langsam zurück zur Mitte
function LivingMarket:driftReputation()
    local s = self.CONTRACT_SETTINGS
    for _, farm in pairs(self.reputation) do
        for stationKey, value in pairs(farm) do
            if value > s.repStart then
                value = math.max(s.repStart, value - s.repDriftPerMonth)
            elseif value < s.repStart then
                value = math.min(s.repStart, value + s.repDriftPerMonth)
            end
            farm[stationKey] = value
            if value == s.repStart then
                farm[stationKey] = nil   -- Mitte muss nicht gespeichert werden
            end
        end
    end
end

-- Ansehen bei Erfüllung je nach Vertragswert (Menge × Marktpreis): klein +1, mittel +2, groß +3
function LivingMarket:getContractRepGain(contract)
    local s = self.CONTRACT_SETTINGS
    local value = (contract.amount or 0) / 1000 * (contract.basePrice or contract.price or 0)
    if value >= s.repLargeValue then
        return s.repFulfilledLarge
    elseif value < s.repSmallValue then
        return s.repFulfilledSmall
    end
    return s.repFulfilled
end

-- Ansehen-Anteil am Aufschlag (0 bei 50 und darunter, voll bei 100)
function LivingMarket:getReputationMarkup(farmId, stationKey)
    local value = self:getReputation(farmId, stationKey)
    return math.max(0, (value - 50) / 50) * self.CONTRACT_SETTINGS.reputationMarkup
end

-- Bietet die Station diesem Hof Verträge an?
function LivingMarket:isStationOpenForFarm(farmId, stationKey)
    return self.getReputationStars(self:getReputation(farmId, stationKey)) >= self.CONTRACT_SETTINGS.repMinStars
end

-- ---------------------------------------------------------------------
-- Preise
-- ---------------------------------------------------------------------
-- Festpreis je 1000 l für einen Hof (Aufschlag gedeckelt)
function LivingMarket:getContractPrice(contract, farmId)
    if contract.state == "active" and contract.price ~= nil then
        return contract.price
    end
    local s = self.CONTRACT_SETTINGS
    local markup = (contract.markup or 0) + (contract.eventMarkup or 0) + self:getReputationMarkup(farmId, contract.stationKey)
    markup = math.min(markup, s.maxTotalMarkup)
    return math.floor((contract.basePrice or 0) * (1 + markup) + 0.5)
end

function LivingMarket:getContractValue(contract, farmId)
    return contract.amount / 1000 * self:getContractPrice(contract, farmId)
end

function LivingMarket:getContractBonus(contract, farmId)
    if contract.state == "active" and contract.bonus ~= nil then
        return contract.bonus
    end
    return math.floor(self:getContractValue(contract, farmId) * self.CONTRACT_SETTINGS.bonusRate + 0.5)
end

function LivingMarket:getContractPenalty(contract, farmId)
    local missing = math.max(0, contract.amount - (contract.delivered or 0))
    return math.floor(missing / 1000 * self:getContractPrice(contract, farmId) * self.CONTRACT_SETTINGS.penaltyRate + 0.5)
end

-- Marktpreis des aktuellen Monats je 1000 l (ohne Marktlage)
function LivingMarket:getMonthMarketPrice(fillTypeIndex)
    local year = self:getYearPrices(fillTypeIndex)
    local month = self.getCurrentMonth()
    if year ~= nil and month ~= nil and year.prices[month] ~= nil then
        return year.prices[month]
    end
    return self:getBasePricePer1000(fillTypeIndex)
end

-- ---------------------------------------------------------------------
-- Ausschreibungen erzeugen
-- ---------------------------------------------------------------------
local NEGATIVE_EVENTS = { [2] = true, [4] = true, [6] = true }
local POSITIVE_LOCAL  = { [1] = true, [5] = true }

-- Ereignisse für Station + Ware: negativ (keine Ausschreibung) / positiv lokal (Aufschlag)
function LivingMarket:getContractEventState(stationKey, fillTypeIndex)
    local negative, positive = false, false
    for _, event in ipairs(self.events or {}) do
        if event.fillTypeIndex == fillTypeIndex and (event.stationKey == nil or event.stationKey == stationKey) then
            if NEGATIVE_EVENTS[event.type] then
                negative = true
            elseif POSITIVE_LOCAL[event.type] and event.stationKey == stationKey then
                positive = true
            end
        end
    end
    return negative, positive
end

-- Kann man diese Ware an dieser Station wirklich verkaufen? (Preis > 0, Ware hat einen Grundpreis)
-- Schließt z. B. Wartung, Wasser oder Wickelfolie aus, die manche Stationen annehmen, aber nicht bezahlen.
function LivingMarket:isContractWareSellable(station, fillTypeIndex)
    if station == nil or fillTypeIndex == nil or self:isExcludedFillType(fillTypeIndex) then
        return false
    end
    if station.acceptedFillTypes ~= nil and not station.acceptedFillTypes[fillTypeIndex] then
        return false
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType == nil or (fillType.pricePerLiter or 0) <= 0 then
        return false
    end
    -- Waren, die das Spiel nicht in der Preisübersicht führt ("Keine Verkaufsstellen verfügbar",
    -- z. B. Wasser, Gärreste, Abwasser, Wickelfolie): keine Ereignisse und keine Verträge
    if fillType.showOnPriceTable == false then
        return false
    end
    if station.getEffectiveFillTypePrice ~= nil then
        local ok, price = pcall(station.getEffectiveFillTypePrice, station, fillTypeIndex)
        if not ok or price == nil or price <= 0 then
            return false
        end
    end
    return true
end

function LivingMarket:hasContractFor(stationKey, fillTypeIndex)
    for _, contract in ipairs(self.contracts) do
        if contract.stationKey == stationKey and contract.fillTypeIndex == fillTypeIndex then
            return true
        end
    end
    return false
end

function LivingMarket:createContractOffer()
    local s = self.CONTRACT_SETTINGS
    local stations = self:collectStations()
    if #stations == 0 then
        return nil
    end
    for _ = 1, 30 do
        local station = stations[math.random(1, #stations)]
        if station ~= nil and station.acceptedFillTypes ~= nil then
            local candidates = {}
            for fillTypeIndex, accepted in pairs(station.acceptedFillTypes) do
                if accepted and self:getEntry(station, fillTypeIndex) ~= nil then
                    table.insert(candidates, fillTypeIndex)
                end
            end
            if #candidates > 0 then
                local fillTypeIndex = candidates[math.random(1, #candidates)]
                local stationKey = self:getStationKey(station)
                local negative, positive = self:getContractEventState(stationKey, fillTypeIndex)
                local basePrice = self:getMonthMarketPrice(fillTypeIndex)
                if not negative and not self:hasContractFor(stationKey, fillTypeIndex) and basePrice ~= nil and basePrice > 0
                    and self:isContractWareSellable(station, fillTypeIndex) then
                    local entry = self:getEntry(station, fillTypeIndex)
                    local amount = math.floor((entry.baseMax or entry.max) * randomRange(s.minShare, s.maxShare) / 1000) * 1000
                    amount = math.max(1000, amount)
                    local contract = {
                        id            = self.contractNextId,
                        state         = "offer",
                        stationKey    = stationKey,
                        stationName   = self:getStationNameOf(station) or "?",
                        fillTypeIndex = fillTypeIndex,
                        amount        = amount,
                        basePrice     = basePrice,
                        markup        = randomRange(s.minMarkup, s.maxMarkup),
                        eventMarkup   = positive and s.eventMarkup or 0,
                        months        = math.random(s.minMonths, math.max(s.minMonths, s.maxMonths)),
                        delivered     = 0,
                    }
                    -- Frist zählt ab Erscheinen der Ausschreibung; annehmen geht bis zum Verfall
                    -- (höchstens offerMonths, nie nach der Frist)
                    local now = self.getNowHour()
                    contract.deadlineHour = now + contract.months * self.getHoursPerMonth()
                    contract.offerEndHour = math.min(contract.deadlineHour, now + s.offerMonths * self.getHoursPerMonth())
                    self.contractNextId = self.contractNextId + 1
                    return contract
                end
            end
        end
    end
    return nil
end

function LivingMarket:rollContractTarget()
    local s = self.CONTRACT_SETTINGS
    self.contractTarget = math.random(s.minOffers, math.max(s.minOffers, s.maxOffers))
end

local function countOffers()
    local count = 0
    for _, contract in ipairs(LivingMarket.contracts) do
        if contract.state == "offer" then
            count = count + 1
        end
    end
    return count
end

-- Laufende Verträge je Hof höchstens (Konfiguration)
function LivingMarket:getMaxActiveContracts()
    return self.CONTRACT_SETTINGS.maxActivePerFarm
end

-- Ausschreibungen gleichzeitig (Option oder Standard)
function LivingMarket:getDefaultContractCount()
    return self.DEFAULT_CONTRACTS
end

function LivingMarket:getContractOfferTarget()
    return self.maxContractsSetting or self:getDefaultContractCount()
end

function LivingMarket:getMaxContractsLimit()
    return self.MAX_CONTRACTS_LIMIT
end

-- Darf dieser Spieler die Spiel-Optionen ändern? (Einzelspieler/Host oder Admin)
function LivingMarket:canChangeGameSettings()
    if g_currentMission == nil then
        return false
    end
    return g_currentMission:getIsServer() or g_currentMission.isMasterUser == true
end

-- Wert übernehmen (Server: speichern und an alle schicken; Mitspieler: vom Server erhalten)
function LivingMarket:applyMaxContracts(value)
    if value ~= nil then
        value = math.floor(value)
        if value < 1 or value == self:getDefaultContractCount() then
            value = nil   -- Standard
        else
            value = math.min(value, self:getMaxContractsLimit())
        end
    end
    self.maxContractsSetting = value
    self.contractsVersion = self.contractsVersion + 1
    if isServerSide() and isMultiplayerGame() and LivingMarketSettingsEvent ~= nil and g_server ~= nil then
        g_server:broadcastEvent(LivingMarketSettingsEvent.new(value or 0))
    end
end

-- Aus der Optionsseite: neuen Wert setzen (nil = Standard)
function LivingMarket:requestMaxContracts(value)
    if not self:canChangeGameSettings() then
        return
    end
    if isServerSide() then
        self:applyMaxContracts(value)
    elseif LivingMarketSettingsEvent ~= nil and g_client ~= nil then
        g_client:getServerConnection():sendEvent(LivingMarketSettingsEvent.new(value or 0))
    end
end

function LivingMarket:countActiveContracts(farmId)
    local count = 0
    for _, contract in ipairs(self.contracts) do
        if contract.state == "active" and contract.farmId == farmId then
            count = count + 1
        end
    end
    return count
end

-- ---------------------------------------------------------------------
-- Meldungen (nur an den betroffenen Hof; farmId 0 = alle)
-- ---------------------------------------------------------------------
function LivingMarket:showContractNotification(farmId, key, stationName, fillTypeIndex, liters, money)
    local ownFarm = g_currentMission ~= nil and g_currentMission.getFarmId ~= nil and g_currentMission:getFarmId() or 0
    if farmId ~= 0 and farmId ~= ownFarm then
        return
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    local ware = fillType ~= nil and (fillType.title or fillType.name) or "?"
    local text
    if key == "livingMarket_ctNewOffer" then
        text = string.format(g_i18n:getText(key), stationName, self.formatLiters(liters), ware)
    else
        text = string.format(g_i18n:getText(key), self.formatLiters(liters), ware, stationName, self.formatMoney(money))
    end
    local isWarning = key == "livingMarket_ctFailed" or key == "livingMarket_ctCancelled"
    self:notify(text, isWarning)
end

function LivingMarket:announceContract(farmId, key, contract, money)
    self:showContractNotification(farmId, key, contract.stationName, contract.fillTypeIndex, contract.amount, money or 0)
    if isMultiplayerGame() and g_server ~= nil and LivingMarketContractNotifyEvent ~= nil then
        g_server:broadcastEvent(LivingMarketContractNotifyEvent.new(farmId, key, contract.stationName, contract.fillTypeIndex, contract.amount, money or 0))
    end
end

-- ---------------------------------------------------------------------
-- Geld
-- ---------------------------------------------------------------------
local function addFarmMoney(farmId, amount)
    if amount == 0 or g_currentMission == nil then
        return
    end
    local moneyType = MoneyType ~= nil and (MoneyType.OTHER or MoneyType.SOLD_PRODUCTS) or nil
    g_currentMission:addMoney(amount, farmId, moneyType, true)
end

-- ---------------------------------------------------------------------
-- Annahme, Kündigung, Erfüllung, Fristablauf (nur Server)
-- ---------------------------------------------------------------------
function LivingMarket:findContract(id)
    for i, contract in ipairs(self.contracts) do
        if contract.id == id then
            return contract, i
        end
    end
    return nil
end

-- Abgeschlossenen Vertrag in den Verlauf (je Hof die letzten 20)
local function addToHistory(contract, result, money)
    table.insert(LivingMarket.contractHistory, 1, {
        id            = contract.id,
        farmId        = contract.farmId,
        result        = result,
        stationKey    = contract.stationKey,
        stationName   = contract.stationName,
        fillTypeIndex = contract.fillTypeIndex,
        amount        = contract.amount,
        delivered     = contract.delivered or 0,
        price         = contract.price or 0,
        money         = money or 0,
        repChange     = contract.repChange or 0,
        endHour       = LivingMarket.getNowHour(),
    })
    local count = 0
    for i = 1, #LivingMarket.contractHistory do
        local entry = LivingMarket.contractHistory[i]
        if entry ~= nil and entry.farmId == contract.farmId then
            count = count + 1
            if count > LivingMarket.CONTRACT_HISTORY_MAX then
                table.remove(LivingMarket.contractHistory, i)
            end
        end
    end
end

local function removeContract(contract)
    local _, index = LivingMarket:findContract(contract.id)
    if index ~= nil then
        table.remove(LivingMarket.contracts, index)
    end
end

function LivingMarket:contractsChanged()
    self.contractsVersion = self.contractsVersion + 1
    if isServerSide() and isMultiplayerGame() and LivingMarketContractListEvent ~= nil then
        g_server:broadcastEvent(LivingMarketContractListEvent.new())
    end
end

function LivingMarket:acceptContract(id, farmId)
    if not isServerSide() then
        return false
    end
    local contract = self:findContract(id)
    if contract == nil or contract.state ~= "offer" or farmId == nil or farmId == 0 then
        return false
    end
    if self:countActiveContracts(farmId) >= self:getMaxActiveContracts() then
        return false
    end
    if not self:isStationOpenForFarm(farmId, contract.stationKey) then
        return false
    end
    contract.price = self:getContractPrice(contract, farmId)
    contract.bonus = self:getContractBonus(contract, farmId)
    contract.farmId = farmId
    contract.state = "active"
    contract.delivered = 0
    if contract.deadlineHour == nil then   -- ältere Angebote ohne feste Frist
        contract.deadlineHour = self.getNowHour() + contract.months * self.getHoursPerMonth()
    end
    self:contractsChanged()
    return true
end

-- Vertrag scheitert (Frist verpasst oder gekündigt): Strafe, Ansehen
function LivingMarket:failContract(contract, cancelled)
    local penalty = self:getContractPenalty(contract, contract.farmId)
    addFarmMoney(contract.farmId, -penalty)
    self:changeReputation(contract.farmId, contract.stationKey, -self.CONTRACT_SETTINGS.repFailed)
    contract.repChange = -self.CONTRACT_SETTINGS.repFailed
    self:announceContract(contract.farmId, cancelled and "livingMarket_ctCancelled" or "livingMarket_ctFailed", contract, penalty)
    addToHistory(contract, cancelled and "cancelled" or "failed", -penalty)
    removeContract(contract)
    self:contractsChanged()
end

function LivingMarket:cancelContract(id, farmId)
    if not isServerSide() then
        return false
    end
    local contract = self:findContract(id)
    if contract == nil or contract.state ~= "active" or contract.farmId ~= farmId then
        return false
    end
    self:failContract(contract, true)
    return true
end

function LivingMarket:completeContract(contract)
    addFarmMoney(contract.farmId, contract.bonus or 0)
    contract.repChange = self:getContractRepGain(contract)
    self:changeReputation(contract.farmId, contract.stationKey, contract.repChange)
    self:announceContract(contract.farmId, "livingMarket_ctDone", contract, contract.bonus or 0)
    addToHistory(contract, "done", contract.bonus or 0)
    removeContract(contract)
    self:contractsChanged()
end

-- Mitspieler/Server: Annahme oder Kündigung anstoßen
function LivingMarket:requestContractAction(action, id)
    local farmId = g_currentMission ~= nil and g_currentMission:getFarmId() or 0
    if isServerSide() then
        if action == "accept" then
            self:acceptContract(id, farmId)
        else
            self:cancelContract(id, farmId)
        end
    elseif LivingMarketContractRequestEvent ~= nil and g_client ~= nil then
        g_client:getServerConnection():sendEvent(LivingMarketContractRequestEvent.new(action == "accept", id, farmId))
    end
end

-- ---------------------------------------------------------------------
-- Lieferung (aus dem Hook addFillLevelFromTool)
-- ---------------------------------------------------------------------
function LivingMarket:getActiveContractFor(station, farmId, fillTypeIndex)
    if #self.contracts == 0 or farmId == nil then
        return nil
    end
    local stationKey = nil
    for _, contract in ipairs(self.contracts) do
        if contract.state == "active" and contract.farmId == farmId and contract.fillTypeIndex == fillTypeIndex then
            stationKey = stationKey or self:getStationKey(station)
            if contract.stationKey == stationKey and contract.delivered < contract.amount then
                return contract
            end
        end
    end
    return nil
end

-- Offene Vertragsmenge an dieser Station (alle Höfe) – kommt zur freien Kapazität dazu
function LivingMarket:getContractCapacity(station, fillTypeIndex)
    if #self.contracts == 0 then
        return 0
    end
    local stationKey = self:getStationKey(station)
    local total = 0
    for _, contract in ipairs(self.contracts) do
        if contract.state == "active" and contract.fillTypeIndex == fillTypeIndex and contract.stationKey == stationKey then
            total = total + math.max(0, contract.amount - contract.delivered)
        end
    end
    return total
end

-- Liefert die Vertragsmenge über superFunc zum Festpreis. Rückgabe: angenommene Menge
function LivingMarket:deliverToContract(contract, station, superFunc, farmId, deltaFillLevel, fillTypeIndex, ...)
    local part = math.min(deltaFillLevel, contract.amount - contract.delivered)
    if part <= 0 then
        return 0
    end
    self.contractOverride = { station = station, fillTypeIndex = fillTypeIndex, pricePerLiter = contract.price / 1000 }
    local ok, moved = pcall(superFunc, station, farmId, part, fillTypeIndex, ...)
    self.contractOverride = nil
    if not ok then
        print("[LivingMarket] FEHLER bei Vertragslieferung: " .. tostring(moved))
        return 0
    end
    local used = moved or part
    contract.delivered = contract.delivered + used
    if contract.delivered >= contract.amount - 0.5 then
        contract.delivered = contract.amount
        self:completeContract(contract)
    else
        self.contractsDeliveryDirty = true   -- Fortschritt gelegentlich an die Mitspieler
    end
    return used
end

-- ---------------------------------------------------------------------
-- Stündlich (Server): Fristen, Verfall, neue Ausschreibungen
-- ---------------------------------------------------------------------
function LivingMarket:tickContracts()
    if not isServerSide() then
        return
    end
    local s = self.CONTRACT_SETTINGS
    local now = self.getNowHour()
    local changed = false

    -- Verträge über Waren, die die Station gar nicht bezahlt (ältere Ausschreibungen):
    -- Angebote entfernen, laufende ohne Strafe auflösen
    for i = #self.contracts, 1, -1 do
        local contract = self.contracts[i]
        local station = self:findStationByKey(contract.stationKey)
        if station ~= nil and not self:isContractWareSellable(station, contract.fillTypeIndex) then
            table.remove(self.contracts, i)
            changed = true
        end
    end

    for i = #self.contracts, 1, -1 do
        local contract = self.contracts[i]
        if contract.state == "offer" and now >= (contract.offerEndHour or now) then
            table.remove(self.contracts, i)
            changed = true
        elseif contract.state == "active" and now >= (contract.deadlineHour or now) then
            self:failContract(contract, false)
        end
    end

    -- Ausschreibungen auf die eingestellte Anzahl auffüllen: jede fehlende bekommt einen
    -- zufälligen Zeitpunkt innerhalb des nächsten Spieltags
    local spawns = self.contractSpawnHours
    local missing = s.enabled and (self:getContractOfferTarget() - countOffers()) or 0
    while #spawns > math.max(0, missing) do
        table.remove(spawns)   -- Anzahl gesenkt oder Angebote anders entstanden
    end
    while #spawns < missing do
        table.insert(spawns, now + math.random(1, self.CONTRACT_REFILL_HOURS))
    end
    for i = #spawns, 1, -1 do
        if now >= spawns[i] then
            local contract = self:createContractOffer()
            if contract ~= nil then
                table.insert(self.contracts, contract)
                self:announceContract(0, "livingMarket_ctNewOffer", contract, 0)
                table.remove(spawns, i)
                changed = true
            else
                spawns[i] = now + 1   -- gerade nichts Passendes: nächste Stunde erneut versuchen
            end
        end
    end

    if changed or self.contractsDeliveryDirty then
        self.contractsDeliveryDirty = false
        self:contractsChanged()
    end
end

function LivingMarket:onContractsPeriodChanged()
    if not isServerSide() then
        return
    end
    self:driftReputation()
    self:rollContractTarget()
    self:contractsChanged()
end

-- ---------------------------------------------------------------------
-- Liste für die Menüseite (eigener Hof): offene Angebote + eigene laufende Verträge
-- ---------------------------------------------------------------------
function LivingMarket:getContractRows(farmId)
    local rows = {}
    for _, contract in ipairs(self.contracts) do
        local own = contract.state == "active" and contract.farmId == farmId
        local offer = contract.state == "offer" and self:isStationOpenForFarm(farmId, contract.stationKey)
        if own or offer then
            local fillType = g_fillTypeManager:getFillTypeByIndex(contract.fillTypeIndex)
            local reputation = self:getReputation(farmId, contract.stationKey)
            table.insert(rows, {
                id            = contract.id,
                isActive      = own,
                fillTypeIndex = contract.fillTypeIndex,
                wareTitle     = fillType ~= nil and (fillType.title or fillType.name) or "?",
                stationName   = contract.stationName,
                stationKey    = contract.stationKey,
                amount        = contract.amount,
                delivered     = contract.delivered or 0,
                price         = self:getContractPrice(contract, farmId),
                bonus         = self:getContractBonus(contract, farmId),
                penalty       = self:getContractPenalty(contract, farmId),
                months        = contract.months,
                deadlineHour  = contract.deadlineHour,
                offerEndHour  = contract.offerEndHour,
                stars         = self.getReputationStars(reputation),
                reputation    = reputation,
                repGain       = self:getContractRepGain(contract),
                sortKey       = own and (contract.deadlineHour or 0) or (1e9 + (contract.offerEndHour or 0)),
            })
        end
    end
    -- abgeschlossene Verträge des Hofs (neueste zuerst, unter Angeboten und laufenden)
    for _, entry in ipairs(self.contractHistory) do
        if entry.farmId == farmId then
            local fillType = g_fillTypeManager:getFillTypeByIndex(entry.fillTypeIndex)
            table.insert(rows, {
                id            = entry.id,
                isHistory     = true,
                result        = entry.result,
                fillTypeIndex = entry.fillTypeIndex,
                wareTitle     = fillType ~= nil and (fillType.title or fillType.name) or "?",
                stationName   = entry.stationName,
                stationKey    = entry.stationKey,
                amount        = entry.amount,
                delivered     = entry.delivered,
                price         = entry.price,
                money         = entry.money,
                endHour       = entry.endHour,
                stars         = self.getReputationStars(self:getReputation(farmId, entry.stationKey)),
                reputation    = self:getReputation(farmId, entry.stationKey),
                repChange     = entry.repChange,
                sortKey       = 3e9 - (entry.endHour or 0),
            })
        end
    end
    table.sort(rows, function(a, b)
        if a.sortKey ~= b.sortKey then
            return a.sortKey < b.sortKey
        end
        return a.id < b.id
    end)
    return rows
end

-- Ansehen-Wert (0..100) für das Detailfenster
-- Vertrag dieser Station für die Ware: "active" (eigener laufender Vertrag) bzw. "offer" (offenes Angebot), dazu der Festpreis je 1000 l
function LivingMarket:getStationContractInfo(farmId, station, fillTypeIndex)
    if #self.contracts == 0 or station == nil then
        return nil
    end
    local stationKey = self:getStationKey(station)
    local offer = nil
    for _, contract in ipairs(self.contracts) do
        if contract.stationKey == stationKey and contract.fillTypeIndex == fillTypeIndex then
            if contract.state == "active" and contract.farmId == farmId then
                return "active", contract.price
            elseif contract.state == "offer" and offer == nil and self:isStationOpenForFarm(farmId, stationKey) then
                offer = contract
            end
        end
    end
    if offer ~= nil then
        return "offer", self:getContractPrice(offer, farmId)
    end
    return nil
end

function LivingMarket:getStationReputation(farmId, station)
    return self:getReputation(farmId, self:getStationKey(station))
end

-- Ansehen für das Detailfenster (Stationen der Marktansicht)
function LivingMarket:getStationStars(farmId, station)
    return self.getReputationStars(self:getReputation(farmId, self:getStationKey(station)))
end

-- ---------------------------------------------------------------------
-- Speichern / Laden
-- ---------------------------------------------------------------------
function LivingMarket:saveContractsToXML(xmlFile, baseKey)
    local now = self.getNowHour()
    setXMLInt(xmlFile, baseKey .. "#nextId", self.contractNextId)
    if self.maxContractsSetting ~= nil then
        setXMLInt(xmlFile, baseKey .. "#maxActive", self.maxContractsSetting)
    end
    local i = 0
    for _, contract in ipairs(self.contracts) do
        local name = g_fillTypeManager:getFillTypeNameByIndex(contract.fillTypeIndex)
        if name ~= nil then
            local key = string.format("%s.contract(%d)", baseKey, i)
            setXMLInt(xmlFile, key .. "#id", contract.id)
            setXMLString(xmlFile, key .. "#state", contract.state)
            setXMLString(xmlFile, key .. "#station", contract.stationKey)
            setXMLString(xmlFile, key .. "#stationName", contract.stationName or "")
            setXMLString(xmlFile, key .. "#fillType", name)
            setXMLFloat(xmlFile, key .. "#amount", contract.amount)
            setXMLFloat(xmlFile, key .. "#delivered", contract.delivered or 0)
            setXMLFloat(xmlFile, key .. "#basePrice", contract.basePrice or 0)
            setXMLFloat(xmlFile, key .. "#markup", contract.markup or 0)
            setXMLFloat(xmlFile, key .. "#eventMarkup", contract.eventMarkup or 0)
            setXMLInt(xmlFile, key .. "#months", contract.months or 1)
            if contract.state == "active" then
                setXMLInt(xmlFile, key .. "#farm", contract.farmId)
                setXMLFloat(xmlFile, key .. "#price", contract.price or 0)
                setXMLFloat(xmlFile, key .. "#bonus", contract.bonus or 0)
            else
                setXMLInt(xmlFile, key .. "#offerEndIn", math.floor((contract.offerEndHour or now) - now))
            end
            if contract.deadlineHour ~= nil then
                setXMLInt(xmlFile, key .. "#deadlineIn", math.floor(contract.deadlineHour - now))
            end
            i = i + 1
        end
    end
    local now2 = self.getNowHour()
    for h, entry in ipairs(self.contractHistory) do
        local name = g_fillTypeManager:getFillTypeNameByIndex(entry.fillTypeIndex)
        if name ~= nil then
            local key = string.format("%s.history(%d)", baseKey, h - 1)
            setXMLInt(xmlFile, key .. "#id", entry.id)
            setXMLInt(xmlFile, key .. "#farm", entry.farmId or 0)
            setXMLString(xmlFile, key .. "#result", entry.result)
            setXMLString(xmlFile, key .. "#station", entry.stationKey or "")
            setXMLString(xmlFile, key .. "#stationName", entry.stationName or "")
            setXMLString(xmlFile, key .. "#fillType", name)
            setXMLFloat(xmlFile, key .. "#amount", entry.amount)
            setXMLFloat(xmlFile, key .. "#delivered", entry.delivered)
            setXMLFloat(xmlFile, key .. "#price", entry.price)
            setXMLFloat(xmlFile, key .. "#money", entry.money)
            setXMLInt(xmlFile, key .. "#repChange", entry.repChange or 0)
            setXMLInt(xmlFile, key .. "#hoursAgo", math.max(0, math.floor(now2 - (entry.endHour or now2))))
        end
    end
    local r = 0
    for farmId, farm in pairs(self.reputation) do
        for stationKey, value in pairs(farm) do
            local key = string.format("%s.reputation(%d)", baseKey, r)
            setXMLInt(xmlFile, key .. "#farm", farmId)
            setXMLString(xmlFile, key .. "#station", stationKey)
            setXMLFloat(xmlFile, key .. "#value", value)
            r = r + 1
        end
    end
end

function LivingMarket:loadContractsFromXML(xmlFile, baseKey)
    self.contracts = {}
    self.reputation = {}
    local now = self.getNowHour()
    self.contractNextId = getXMLInt(xmlFile, baseKey .. "#nextId") or 1
    self.maxContractsSetting = nil
    local maxActive = getXMLInt(xmlFile, baseKey .. "#maxActive")
    if maxActive ~= nil and maxActive >= 1 and maxActive ~= self:getDefaultContractCount() then
        self.maxContractsSetting = math.min(maxActive, self:getMaxContractsLimit())
    end
    local i = 0
    while true do
        local key = string.format("%s.contract(%d)", baseKey, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local name = getXMLString(xmlFile, key .. "#fillType")
        local fillTypeIndex = name ~= nil and g_fillTypeManager:getFillTypeIndexByName(name) or nil
        local stationKey = getXMLString(xmlFile, key .. "#station")
        if fillTypeIndex ~= nil and stationKey ~= nil then
            local contract = {
                id            = getXMLInt(xmlFile, key .. "#id") or self.contractNextId,
                state         = getXMLString(xmlFile, key .. "#state") == "active" and "active" or "offer",
                stationKey    = stationKey,
                stationName   = getXMLString(xmlFile, key .. "#stationName") or "?",
                fillTypeIndex = fillTypeIndex,
                amount        = getXMLFloat(xmlFile, key .. "#amount") or 1000,
                delivered     = getXMLFloat(xmlFile, key .. "#delivered") or 0,
                basePrice     = getXMLFloat(xmlFile, key .. "#basePrice") or 0,
                markup        = getXMLFloat(xmlFile, key .. "#markup") or 0,
                eventMarkup   = getXMLFloat(xmlFile, key .. "#eventMarkup") or 0,
                months        = getXMLInt(xmlFile, key .. "#months") or 1,
            }
            if contract.state == "active" then
                contract.farmId = getXMLInt(xmlFile, key .. "#farm")
                contract.price = getXMLFloat(xmlFile, key .. "#price")
                contract.bonus = getXMLFloat(xmlFile, key .. "#bonus")
            else
                contract.offerEndHour = now + (getXMLInt(xmlFile, key .. "#offerEndIn") or 0)
            end
            local deadlineIn = getXMLInt(xmlFile, key .. "#deadlineIn")
            if deadlineIn ~= nil then
                contract.deadlineHour = now + deadlineIn
            elseif contract.state == "active" then
                contract.deadlineHour = now
            end
            self.contractNextId = math.max(self.contractNextId, contract.id + 1)
            table.insert(self.contracts, contract)
        end
        i = i + 1
    end
    self.contractHistory = {}
    local h = 0
    while true do
        local key = string.format("%s.history(%d)", baseKey, h)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local name = getXMLString(xmlFile, key .. "#fillType")
        local fillTypeIndex = name ~= nil and g_fillTypeManager:getFillTypeIndexByName(name) or nil
        if fillTypeIndex ~= nil then
            table.insert(self.contractHistory, {
                id            = getXMLInt(xmlFile, key .. "#id") or 0,
                farmId        = getXMLInt(xmlFile, key .. "#farm") or 0,
                result        = getXMLString(xmlFile, key .. "#result") or "done",
                stationKey    = getXMLString(xmlFile, key .. "#station"),
                stationName   = getXMLString(xmlFile, key .. "#stationName") or "?",
                fillTypeIndex = fillTypeIndex,
                amount        = getXMLFloat(xmlFile, key .. "#amount") or 0,
                delivered     = getXMLFloat(xmlFile, key .. "#delivered") or 0,
                price         = getXMLFloat(xmlFile, key .. "#price") or 0,
                money         = getXMLFloat(xmlFile, key .. "#money") or 0,
                repChange     = getXMLInt(xmlFile, key .. "#repChange"),
                endHour       = now - (getXMLInt(xmlFile, key .. "#hoursAgo") or 0),
            })
        end
        h = h + 1
    end
    local r = 0
    while true do
        local key = string.format("%s.reputation(%d)", baseKey, r)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local farmId = getXMLInt(xmlFile, key .. "#farm")
        local stationKey = getXMLString(xmlFile, key .. "#station")
        local value = getXMLFloat(xmlFile, key .. "#value")
        if farmId ~= nil and stationKey ~= nil and value ~= nil then
            self.reputation[farmId] = self.reputation[farmId] or {}
            self.reputation[farmId][stationKey] = value
        end
        r = r + 1
    end
    self.contractsVersion = self.contractsVersion + 1
end

function LivingMarket:resetContracts()
    self.contracts = {}
    self.contractHistory = {}
    self.reputation = {}
    self.contractNextId = 1
    self.contractTarget = nil
    self.contractSpawnHours = {}
    self.contractOverride = nil
    self.maxContractsSetting = nil
    self.contractsVersion = self.contractsVersion + 1
end

-- ---------------------------------------------------------------------
-- Einstellungen aus der Konfigurationsdatei (<contracts .../>)
-- ---------------------------------------------------------------------
function LivingMarket:loadContractSettings(xmlFile)
    local key = "livingMarket.contracts"
    if not hasXMLProperty(xmlFile, key) then
        return
    end
    local s = self.CONTRACT_SETTINGS
    local enabled = getXMLBool(xmlFile, key .. "#enabled")
    if enabled ~= nil then
        s.enabled = enabled
    end
    local function num(name, minValue, maxValue)
        local value = getXMLFloat(xmlFile, key .. "#" .. name)
        if value ~= nil then
            s[name] = math.max(minValue, math.min(maxValue, value))
        end
    end
    num("minOffers", 0, 50)
    num("maxOffers", 0, 50)
    num("offerMonths", 0.25, 12)
    num("minMonths", 1, 12)
    num("maxMonths", 1, 12)
    num("minShare", 0.05, 5)
    num("maxShare", 0.05, 5)
    num("minMarkup", 0, 1)
    num("maxMarkup", 0, 1)
    num("reputationMarkup", 0, 1)
    num("eventMarkup", 0, 1)
    num("maxTotalMarkup", 0, 1)
    num("bonusRate", 0, 1)
    num("penaltyRate", 0, 5)
    num("maxActivePerFarm", 1, 50)
    num("repFulfilled", 0, 100)
    num("repFulfilledSmall", 0, 100)
    num("repFulfilledLarge", 0, 100)
    num("repSmallValue", 0, 1e9)
    num("repLargeValue", 0, 1e9)
    num("repFailed", 0, 100)
    num("repDriftPerMonth", 0, 100)
    num("repMinStars", 1, 5)
    s.minOffers, s.maxOffers = math.floor(s.minOffers), math.floor(math.max(s.minOffers, s.maxOffers))
    s.minMonths, s.maxMonths = math.floor(s.minMonths), math.floor(math.max(s.minMonths, s.maxMonths))
    s.maxActivePerFarm = math.floor(s.maxActivePerFarm)
    s.maxShare = math.max(s.minShare, s.maxShare)
    s.maxMarkup = math.max(s.minMarkup, s.maxMarkup)
end

-- Lieferfortschritt etwa alle 2 Sekunden an die Mitspieler (statt bei jedem Teilstück)
function LivingMarket:updateContractsSync(dt)
    if not self.contractsDeliveryDirty then
        return
    end
    self.contractsSyncTimer = (self.contractsSyncTimer or 0) - dt
    if self.contractsSyncTimer <= 0 then
        self.contractsSyncTimer = 2000
        self.contractsDeliveryDirty = false
        self:contractsChanged()
    end
end
