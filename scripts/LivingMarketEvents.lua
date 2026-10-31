-- =====================================================================
-- Living Market - Marktereignisse und kleine Schwankungen
--
-- Ereignisse (laufen 1-2 Spielmonate, gezählt in Monatswechseln):
--  - Engpass      : eine Station braucht eine Ware dringend   -> Bedarf x1,5, Preis +10..25 %, sofort
--  - Überangebot  : eine Station ist übersättigt              -> Bedarf x0,6, Preis -10..25 %, sofort
--  - Marktweit    : eine Ware an allen Stationen (Boom/Flaute) -> Bedarf x1,3/x0,7, Preis ±10..25 %,
--                   einen Monat vorher angekündigt
-- Kleine Schwankungen: Maximum jedes Eintrags ±10 %, neu zu jedem Monatswechsel, ohne Meldung.
--
-- Nur der Server würfelt und verwaltet; Clients bekommen Maximum, Preisfaktor und Ereignistyp
-- je Eintrag über den normalen Sync.
-- =====================================================================

LivingMarket.EVENT_NONE      = 0
LivingMarket.EVENT_SHORTAGE  = 1   -- Engpass (eine Station)
LivingMarket.EVENT_SURPLUS   = 2   -- Überangebot (eine Station)
LivingMarket.EVENT_BOOM      = 3   -- marktweit gefragt
LivingMarket.EVENT_SLUMP     = 4   -- marktweit Überangebot

LivingMarket.EVENT_SETTINGS = {
    minActive      = 3,      -- so viele Ereignisse sollen etwa gleichzeitig laufen (inkl. angekündigter)
    maxActive      = 5,
    minPrice       = 0.10,   -- Preisänderung ±10..25 %
    maxPrice       = 0.25,
    minMonths      = 1,
    maxMonths      = 2,
    noise          = 0.10,   -- kleine Schwankung des Bedarfs ±10 %
    weightShortage = 0.40,
    weightSurplus  = 0.35,   -- Rest: marktweit
    maxFactor = {
        [1] = 1.5,   -- Engpass
        [2] = 0.6,   -- Überangebot
        [3] = 1.3,   -- Boom
        [4] = 0.7,   -- Flaute
    },
}

LivingMarket.events = {}   -- { type, fillTypeIndex, stationKey (nil = marktweit), price, maxFactor, months, startsIn }

local function log(fmt, ...)
    if LivingMarket.DEBUG then
        print("[LivingMarket] " .. string.format(fmt, ...))
    end
end

local function randomRange(minValue, maxValue)
    return minValue + math.random() * (maxValue - minValue)
end

-- Kleine Schwankung für einen Eintrag
function LivingMarket:rollNoise()
    local n = self.EVENT_SETTINGS.noise
    return 1 + randomRange(-n, n)
end

-- Maximum/Auffüllung aus Grundwert × Schwankung × Ereignis.
-- keepShare = true: wächst das Maximum, wächst der freie Bedarf mit (Station braucht plötzlich mehr)
function LivingMarket:recalcEntryLimits(entry, keepShare)
    local factor = (entry.noise or 1) * (entry.eventMax or 1)
    local oldMax = entry.max
    entry.max = math.max(1, (entry.baseMax or entry.max or 0) * factor)
    entry.refill = (entry.baseRefill or entry.refill or 0) * factor
    if entry.remaining ~= nil then
        if keepShare and oldMax ~= nil and entry.max > oldMax then
            entry.remaining = entry.remaining + (entry.max - oldMax)
        end
        entry.remaining = math.max(0, math.min(entry.remaining, entry.max))
    end
end

-- Aktive Ereignisse auf einen Eintrag anwenden (Station + marktweit, Effekte werden multipliziert)
function LivingMarket:applyEventsToEntry(station, fillTypeIndex, entry)
    entry.eventPrice, entry.eventMax, entry.eventType = 1, 1, self.EVENT_NONE
    if self.events == nil or #self.events == 0 then
        return
    end
    local stationKey = nil
    for _, event in ipairs(self.events) do
        if event.startsIn <= 0 and event.fillTypeIndex == fillTypeIndex then
            local matches = event.stationKey == nil
            if not matches then
                stationKey = stationKey or self:getStationKey(station)
                matches = event.stationKey == stationKey
            end
            if matches then
                entry.eventPrice = entry.eventPrice * event.price
                entry.eventMax = entry.eventMax * event.maxFactor
                -- Stationsereignis hat Vorrang bei der Anzeige
                if entry.eventType == self.EVENT_NONE or event.stationKey ~= nil then
                    entry.eventType = event.type
                end
            end
        end
    end
end

-- Alle Einträge neu berechnen (nach Monatswechsel oder Ereignisänderung)
function LivingMarket:applyEventsToAll()
    -- für marktweite Ereignisse alle Stationen mit dieser Ware anlegen
    local stations = self:collectStations()
    for _, event in ipairs(self.events) do
        if event.startsIn <= 0 then
            for _, station in ipairs(stations) do
                if station.acceptedFillTypes ~= nil and station.acceptedFillTypes[event.fillTypeIndex] then
                    self:getEntry(station, event.fillTypeIndex)
                end
            end
        end
    end
    for station, data in pairs(self.stations) do
        for fillTypeIndex, entry in pairs(data) do
            local oldPrice, oldMax, oldType = entry.eventPrice, entry.max, entry.eventType
            self:applyEventsToEntry(station, fillTypeIndex, entry)
            self:recalcEntryLimits(entry, true)
            if oldPrice ~= entry.eventPrice or oldMax ~= entry.max or oldType ~= entry.eventType then
                self:markDirty(entry)
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- Meldungen
-- ---------------------------------------------------------------------
local function fillTypeTitle(fillTypeIndex)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    return fillType ~= nil and (fillType.title or fillType.name) or tostring(fillTypeIndex)
end

function LivingMarket:findStationByKey(stationKey)
    for _, station in ipairs(self:collectStations()) do
        if self:getStationKey(station) == stationKey then
            return station
        end
    end
    return nil
end

function LivingMarket:getEventStationName(event)
    if event.stationName ~= nil then
        return event.stationName
    end
    local station = event.stationKey ~= nil and self:findStationByKey(event.stationKey) or nil
    if station ~= nil then
        event.stationName = self:getStationNameOf(station)
    end
    return event.stationName or "?"
end

function LivingMarket:notify(text, isWarning)
    log("Marktmeldung: %s", text)
    local mission = g_currentMission
    if mission ~= nil and mission.addIngameNotification ~= nil and FSBaseMission ~= nil then
        local kind = isWarning and FSBaseMission.INGAME_NOTIFICATION_CRITICAL or FSBaseMission.INGAME_NOTIFICATION_INFO
        pcall(mission.addIngameNotification, mission, kind or FSBaseMission.INGAME_NOTIFICATION_INFO, text)
    end
end

function LivingMarket:announceEvent(event, phase)
    local ware = fillTypeTitle(event.fillTypeIndex)
    local percent = math.floor(math.abs(event.price - 1) * 100 + 0.5)
    local key
    if phase == "end" then
        key = event.stationKey ~= nil and "livingMarket_evEndStation" or "livingMarket_evEndMarket"
    elseif event.type == self.EVENT_SHORTAGE then
        key = "livingMarket_evShortage"
    elseif event.type == self.EVENT_SURPLUS then
        key = "livingMarket_evSurplus"
    elseif event.type == self.EVENT_BOOM then
        key = phase == "announce" and "livingMarket_evBoomAnnounce" or "livingMarket_evBoomStart"
    else
        key = phase == "announce" and "livingMarket_evSlumpAnnounce" or "livingMarket_evSlumpStart"
    end
    local text = g_i18n:getText(key)
    if event.stationKey ~= nil then
        text = string.format(text, self:getEventStationName(event), ware, percent, event.months)
    else
        text = string.format(text, ware, percent, event.months)
    end
    self:notify(text, event.type == self.EVENT_SURPLUS or event.type == self.EVENT_SLUMP)
end

-- ---------------------------------------------------------------------
-- Würfeln
-- ---------------------------------------------------------------------
function LivingMarket:hasEventFor(fillTypeIndex, stationKey)
    for _, event in ipairs(self.events) do
        if event.fillTypeIndex == fillTypeIndex and (event.stationKey == nil or event.stationKey == stationKey) then
            return true
        end
    end
    return false
end

-- Zufällige Station und Ware für ein Stationsereignis
function LivingMarket:pickStationWare()
    local stations = self:collectStations()
    for _ = 1, 20 do
        local station = stations[math.random(1, math.max(1, #stations))]
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
                if not self:hasEventFor(fillTypeIndex, stationKey) then
                    return station, stationKey, fillTypeIndex
                end
            end
        end
    end
    return nil
end

-- Zufällige Ware für ein marktweites Ereignis (nur Waren, die mindestens 2 Stationen annehmen)
function LivingMarket:pickMarketWare()
    local count = {}
    for _, station in ipairs(self:collectStations()) do
        for fillTypeIndex, accepted in pairs(station.acceptedFillTypes or {}) do
            if accepted and self:getEntry(station, fillTypeIndex) ~= nil then
                count[fillTypeIndex] = (count[fillTypeIndex] or 0) + 1
            end
        end
    end
    local candidates = {}
    for fillTypeIndex, n in pairs(count) do
        if n >= 2 and not self:hasEventFor(fillTypeIndex, nil) then
            table.insert(candidates, fillTypeIndex)
        end
    end
    if #candidates == 0 then
        return nil
    end
    return candidates[math.random(1, #candidates)]
end

function LivingMarket:createRandomEvent()
    local s = self.EVENT_SETTINGS
    local roll = math.random()
    local months = math.random(s.minMonths, s.maxMonths)
    local change = randomRange(s.minPrice, s.maxPrice)

    if roll < s.weightShortage + s.weightSurplus then
        local station, stationKey, fillTypeIndex = self:pickStationWare()
        if station == nil then
            return nil
        end
        local eventType = roll < s.weightShortage and self.EVENT_SHORTAGE or self.EVENT_SURPLUS
        local event = {
            type = eventType, fillTypeIndex = fillTypeIndex, stationKey = stationKey,
            price = eventType == self.EVENT_SHORTAGE and (1 + change) or (1 - change),
            maxFactor = s.maxFactor[eventType], months = months, startsIn = 0,
            startPeriod = self.getCurrentMonth(),
        }
        return event
    end

    local fillTypeIndex = self:pickMarketWare()
    if fillTypeIndex == nil then
        return nil
    end
    local eventType = math.random() < 0.5 and self.EVENT_BOOM or self.EVENT_SLUMP
    return {
        type = eventType, fillTypeIndex = fillTypeIndex, stationKey = nil,
        price = eventType == self.EVENT_BOOM and (1 + change) or (1 - change),
        maxFactor = s.maxFactor[eventType], months = months,
        startsIn = 1,   -- marktweit: einen Monat vorher angekündigt
        startPeriod = self.wrapMonth((self.getCurrentMonth() or 1) + 1),
    }
end

function LivingMarket:addRandomEvents()
    local s = self.EVENT_SETTINGS
    local target = math.random(s.minActive, s.maxActive)
    local tries = 0
    while #self.events < target and tries < 20 do
        tries = tries + 1
        local event = self:createRandomEvent()
        if event ~= nil then
            table.insert(self.events, event)
            self:announceEvent(event, event.startsIn > 0 and "announce" or "start")
        end
    end
end

-- Beim ersten Laden ohne gespeicherte Ereignisse
function LivingMarket:initEvents()
    if #self.events == 0 then
        self:addRandomEvents()
    end
    self:applyEventsToAll()
    log("Marktereignisse aktiv: %d", #self.events)
end

-- Monatswechsel: Ereignisse weiterzählen, neue würfeln, Schwankungen neu
function LivingMarket:onPeriodChanged()
    if g_server == nil then
        return
    end
    local kept = {}
    for _, event in ipairs(self.events) do
        if event.startsIn > 0 then
            event.startsIn = event.startsIn - 1
            if event.startsIn <= 0 then
                self:announceEvent(event, "start")
            end
            table.insert(kept, event)
        else
            event.months = event.months - 1
            if event.months > 0 then
                table.insert(kept, event)
            else
                self:announceEvent(event, "end")
            end
        end
    end
    self.events = kept

    -- kleine Schwankungen neu würfeln
    for _, data in pairs(self.stations) do
        for _, entry in pairs(data) do
            entry.noise = self:rollNoise()
        end
    end

    self:addRandomEvents()
    self:applyEventsToAll()
    self.eventsInitialized = true
    log("Monatswechsel: %d Marktereignisse", #self.events)
end

-- ---------------------------------------------------------------------
-- Speichern / Laden
-- ---------------------------------------------------------------------
function LivingMarket:saveEventsToXML(xmlFile, baseKey)
    for i, event in ipairs(self.events) do
        local key = string.format("%s.event(%d)", baseKey, i - 1)
        setXMLInt(xmlFile, key .. "#type", event.type)
        setXMLString(xmlFile, key .. "#fillType", g_fillTypeManager:getFillTypeNameByIndex(event.fillTypeIndex) or "")
        if event.stationKey ~= nil then
            setXMLString(xmlFile, key .. "#station", event.stationKey)
        end
        setXMLFloat(xmlFile, key .. "#price", event.price)
        setXMLFloat(xmlFile, key .. "#maxFactor", event.maxFactor)
        setXMLInt(xmlFile, key .. "#months", event.months)
        setXMLInt(xmlFile, key .. "#startsIn", event.startsIn)
        if event.startPeriod ~= nil then
            setXMLInt(xmlFile, key .. "#startPeriod", event.startPeriod)
        end
    end
end

function LivingMarket:loadEventsFromXML(xmlFile, baseKey)
    self.events = {}
    local i = 0
    while true do
        local key = string.format("%s.event(%d)", baseKey, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local fillTypeName = getXMLString(xmlFile, key .. "#fillType")
        local fillTypeIndex = fillTypeName ~= nil and g_fillTypeManager:getFillTypeIndexByName(fillTypeName) or nil
        if fillTypeIndex ~= nil then
            table.insert(self.events, {
                type          = getXMLInt(xmlFile, key .. "#type") or self.EVENT_SHORTAGE,
                fillTypeIndex = fillTypeIndex,
                stationKey    = getXMLString(xmlFile, key .. "#station"),
                price         = getXMLFloat(xmlFile, key .. "#price") or 1,
                maxFactor     = getXMLFloat(xmlFile, key .. "#maxFactor") or 1,
                months        = getXMLInt(xmlFile, key .. "#months") or 1,
                startsIn      = getXMLInt(xmlFile, key .. "#startsIn") or 0,
                startPeriod   = getXMLInt(xmlFile, key .. "#startPeriod"),
            })
        end
        i = i + 1
    end
    -- gespeicherter Stand mit Ereignissen: nicht neu würfeln, nur anwenden
    self.eventsInitialized = false
    self.eventInitTimer = 0
end

-- ---------------------------------------------------------------------
-- Liste für die Seite "Marktnachrichten"
-- ---------------------------------------------------------------------
function LivingMarket.wrapMonth(month)
    return ((math.floor(month) - 1) % 12) + 1
end

function LivingMarket:getEventList()
    local current = self.getCurrentMonth() or 1
    local rows = {}
    for _, event in ipairs(self.events or {}) do
        local pending = event.startsIn > 0
        local startMonth = event.startPeriod
        if startMonth == nil then
            startMonth = pending and self.wrapMonth(current + event.startsIn) or current
        end
        -- Ende: aktiv = aktueller Monat + verbleibende Monate - 1; angekündigt = Beginn + Dauer - 1
        local endMonth = pending and self.wrapMonth(current + event.startsIn + event.months - 1)
            or self.wrapMonth(current + event.months - 1)
        local fillType = g_fillTypeManager:getFillTypeByIndex(event.fillTypeIndex)
        table.insert(rows, {
            type          = event.type,
            fillTypeIndex = event.fillTypeIndex,
            wareTitle     = fillType ~= nil and (fillType.title or fillType.name) or "?",
            stationName   = event.stationKey ~= nil and self:getEventStationName(event) or g_i18n:getText("livingMarket_allStations"),
            pricePercent  = math.floor((event.price - 1) * 100 + 0.5),
            maxFactor     = event.maxFactor,
            startMonth    = startMonth,
            endMonth      = endMonth,
            pending       = pending,
            sortKey       = (pending and 100 or 0) + event.startsIn * 12 + event.months,
        })
    end
    -- laufende zuerst (die bald enden oben), dann angekündigte
    table.sort(rows, function(a, b)
        if a.sortKey ~= b.sortKey then
            return a.sortKey < b.sortKey
        end
        return a.wareTitle < b.wareTitle
    end)
    return rows
end
