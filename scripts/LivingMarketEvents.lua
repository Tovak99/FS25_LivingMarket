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
    minActive      = 10,     -- so viele Ereignisse sollen etwa gleichzeitig laufen (inkl. angekündigter)
    maxActive      = 20,
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

LivingMarket.events = {}   -- { type, fillTypeIndex, stationKey (nil = marktweit), price, maxFactor, months, startHour, endHour, active }

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
    -- auf volle 100 Liter abrunden (28.171 l -> 28.100 l)
    entry.max = math.max(100, math.floor((entry.baseMax or entry.max or 0) * factor / 100) * 100)
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
        if event.active and event.fillTypeIndex == fillTypeIndex then
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
        if event.active then
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

-- ---------------------------------------------------------------------
-- Zeit: Ereignisse laufen in Spielstunden, damit Beginn und Ende über den
-- Monat verteilt sind (nicht alle um 00:00 des Monatswechsels)
-- ---------------------------------------------------------------------
LivingMarket.testHourOffset = 0   -- Testknöpfe spulen hiermit vor

function LivingMarket.getNowHour()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil then
        return LivingMarket.testHourOffset
    end
    local day = env.currentMonotonicDay or env.currentDay or 0
    return day * 24 + (env.currentHour or 0) + LivingMarket.testHourOffset
end

-- Zeitpunkt (absolute Stunde) als "Okt 14:00" bzw. "Okt 2. 14:00" bei mehreren Tagen je Monat
function LivingMarket:formatEventTime(absHour)
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local daysPerMonth = math.max(1, math.floor(self.getHoursPerMonth() / 24 + 0.5))
    local hoursPerMonth = daysPerMonth * 24
    local now = self.getNowHour()
    local nowHourOfDay = (env ~= nil and env.currentHour or 0) + self.testHourOffset
    local dayInMonth = env ~= nil and env.currentDayInPeriod or 1
    local month = self.getCurrentMonth() or 1
    -- Stunden seit Beginn des aktuellen Monats bis zum Zeitpunkt
    local total = (dayInMonth - 1) * 24 + nowHourOfDay + (absHour - now)
    local monthsAhead = math.floor(total / hoursPerMonth)
    local rest = total - monthsAhead * hoursPerMonth
    local day = math.floor(rest / 24) + 1
    local hour = math.floor(rest % 24)
    local text = self.getMonthName(self.wrapMonth(month + monthsAhead))
    if daysPerMonth > 1 then
        text = string.format("%s %d.", text, day)
    end
    return string.format("%s %02d:00", text, hour)
end

-- Gespeicherte/alte Angaben in absolute Stunden umrechnen
function LivingMarket:normalizeEvents()
    local now = self.getNowHour()
    local hoursPerMonth = self.getHoursPerMonth()
    for _, event in ipairs(self.events) do
        if event.startHour == nil then
            if event.startIn ~= nil then
                event.startHour = now + event.startIn
                event.endHour = now + (event.endIn or (event.startIn + event.months * hoursPerMonth))
            else   -- alter Stand (Monate): ab jetzt umrechnen
                local startIn = (event.startsIn or 0) * hoursPerMonth
                event.startHour = now + startIn
                event.endHour = event.startHour + (event.months or 1) * hoursPerMonth
            end
            event.active = event.startHour <= now
            event.startIn, event.endIn, event.startsIn = nil, nil, nil
        end
    end
end

-- ---------------------------------------------------------------------
-- Würfeln
-- ---------------------------------------------------------------------
function LivingMarket:createRandomEvent()
    local s = self.EVENT_SETTINGS
    local roll = math.random()
    local months = math.random(s.minMonths, s.maxMonths)
    local change = randomRange(s.minPrice, s.maxPrice)
    local now = self.getNowHour()
    local hoursPerMonth = self.getHoursPerMonth()

    if roll < s.weightShortage + s.weightSurplus then
        local station, stationKey, fillTypeIndex = self:pickStationWare()
        if station == nil then
            return nil
        end
        local eventType = roll < s.weightShortage and self.EVENT_SHORTAGE or self.EVENT_SURPLUS
        return {   -- Stationsereignis: beginnt sofort
            type = eventType, fillTypeIndex = fillTypeIndex, stationKey = stationKey,
            price = eventType == self.EVENT_SHORTAGE and (1 + change) or (1 - change),
            maxFactor = s.maxFactor[eventType], months = months,
            startHour = now, endHour = now + months * hoursPerMonth, active = false,
        }
    end

    local fillTypeIndex = self:pickMarketWare()
    if fillTypeIndex == nil then
        return nil
    end
    local eventType = math.random() < 0.5 and self.EVENT_BOOM or self.EVENT_SLUMP
    local startHour = now + hoursPerMonth   -- marktweit: einen Monat vorher angekündigt
    return {
        type = eventType, fillTypeIndex = fillTypeIndex, stationKey = nil,
        price = eventType == self.EVENT_BOOM and (1 + change) or (1 - change),
        maxFactor = s.maxFactor[eventType], months = months,
        startHour = startHour, endHour = startHour + months * hoursPerMonth, active = false,
    }
end

function LivingMarket:rollEventTarget()
    local s = self.EVENT_SETTINGS
    self.eventTarget = math.random(s.minActive, s.maxActive)
end

-- Ein neues Ereignis würfeln und melden (angekündigt oder sofort gestartet)
function LivingMarket:spawnEvent()
    local event = self:createRandomEvent()
    if event == nil then
        return false
    end
    table.insert(self.events, event)
    if event.startHour > self.getNowHour() then
        self:announceEvent(event, "announce")
    end
    return true
end

-- Jede Spielstunde: fällige Ereignisse starten/beenden, gelegentlich neue würfeln.
-- Neue Ereignisse kommen zufällig über den Monat verteilt, solange weniger als das Ziel laufen.
function LivingMarket:tickEvents()
    if g_server == nil or not self.eventsInitialized then
        return
    end
    self:normalizeEvents()
    local now = self.getNowHour()
    local changed = false

    local kept = {}
    for _, event in ipairs(self.events) do
        if not event.active and now >= event.startHour then
            event.active = true
            self:announceEvent(event, "start")
            changed = true
        end
        if event.active and now >= event.endHour then
            self:announceEvent(event, "end")
            changed = true
        else
            table.insert(kept, event)
        end
    end
    self.events = kept

    if self.eventTarget == nil then
        self:rollEventTarget()
    end
    local missing = self.eventTarget - #self.events
    if missing > 0 then
        -- Fehlende Ereignisse kommen verteilt im Lauf von etwa einem Drittel Monat:
        -- je Stunde im Schnitt missing / window neue (ganzzahliger Teil sicher, Rest als Chance)
        local window = math.max(4, self.getHoursPerMonth() / 3)
        local expected = missing / window
        local count = math.floor(expected) + ((math.random() < expected % 1) and 1 or 0)
        for _ = 1, math.min(count, missing) do
            if self:spawnEvent() then
                changed = true
            end
        end
    end

    -- sofort beginnende Ereignisse starten
    for _, event in ipairs(self.events) do
        if not event.active and now >= event.startHour then
            event.active = true
            self:announceEvent(event, "start")
            changed = true
        end
    end

    if changed then
        self:applyEventsToAll()
    end
end

-- Beim Laden: gespeicherte Ereignisse übernehmen bzw. das erste würfeln
function LivingMarket:initEvents()
    self:normalizeEvents()
    self:rollEventTarget()
    if #self.events == 0 then
        self:spawnEvent()   -- eins sofort, der Rest kommt verteilt über die nächsten Stunden
        for _, event in ipairs(self.events) do
            if not event.active and event.startHour <= self.getNowHour() then
                event.active = true
                self:announceEvent(event, "start")
            end
        end
    end
    self:applyEventsToAll()
    log("Marktereignisse: %d (Ziel %d)", #self.events, self.eventTarget)
end

-- Monatswechsel: nur noch kleine Schwankungen und neues Ziel für die Anzahl
function LivingMarket:onPeriodChanged()
    if g_server == nil then
        return
    end
    for _, data in pairs(self.stations) do
        for _, entry in pairs(data) do
            entry.noise = self:rollNoise()
        end
    end
    self:rollEventTarget()
    self:applyEventsToAll()
    log("Monatswechsel: Schwankungen neu, Ziel %d Marktereignisse", self.eventTarget)
end

-- Testknöpfe: Stunden vorspulen (Auffüllen + Ereignisse), Monat = so viele Stunden + Monatswechsel
function LivingMarket:simulateHours(hours)
    for _ = 1, hours do
        self.testHourOffset = self.testHourOffset + 1
        self:onHourChanged()
    end
end

function LivingMarket:simulateMonth()
    self:simulateHours(self.getHoursPerMonth())
    self:onPeriodChanged()
end

-- ---------------------------------------------------------------------
-- Speichern / Laden (Zeiten relativ zu jetzt, damit sie nach dem Laden passen)
-- ---------------------------------------------------------------------
function LivingMarket:saveEventsToXML(xmlFile, baseKey)
    self:normalizeEvents()
    local now = self.getNowHour()
    for i, event in ipairs(self.events) do
        local key = string.format("%s.event(%d)", baseKey, i - 1)
        setXMLInt(xmlFile, key .. "#type", event.type)
        setXMLString(xmlFile, key .. "#fillType", g_fillTypeManager:getFillTypeNameByIndex(event.fillTypeIndex) or "")
        if event.stationKey ~= nil then
            setXMLString(xmlFile, key .. "#station", event.stationKey)
        end
        setXMLFloat(xmlFile, key .. "#price", event.price)
        setXMLFloat(xmlFile, key .. "#maxFactor", event.maxFactor)
        setXMLInt(xmlFile, key .. "#months", event.months or 1)
        setXMLInt(xmlFile, key .. "#startIn", math.floor(event.startHour - now))
        setXMLInt(xmlFile, key .. "#endIn", math.floor(event.endHour - now))
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
                startIn       = getXMLInt(xmlFile, key .. "#startIn"),      -- ab 0.1.0.78
                endIn         = getXMLInt(xmlFile, key .. "#endIn"),
                startsIn      = getXMLInt(xmlFile, key .. "#startsIn"),     -- ältere Versionen (Monate)
                active        = false,
            })
        end
        i = i + 1
    end
    -- gespeicherter Stand: nicht neu würfeln, nur anwenden (initEvents kurz nach dem Laden)
    self.eventsInitialized = false
    self.eventInitTimer = 0
end

-- ---------------------------------------------------------------------
-- Liste für die Ansicht "Marktnachrichten"
-- ---------------------------------------------------------------------
function LivingMarket.wrapMonth(month)
    return ((math.floor(month) - 1) % 12) + 1
end

function LivingMarket:getEventList()
    self:normalizeEvents()
    local rows = {}
    for _, event in ipairs(self.events or {}) do
        local pending = not event.active
        local fillType = g_fillTypeManager:getFillTypeByIndex(event.fillTypeIndex)
        table.insert(rows, {
            type          = event.type,
            fillTypeIndex = event.fillTypeIndex,
            wareTitle     = fillType ~= nil and (fillType.title or fillType.name) or "?",
            stationName   = event.stationKey ~= nil and self:getEventStationName(event) or g_i18n:getText("livingMarket_allStations"),
            pricePercent  = math.floor((event.price - 1) * 100 + 0.5),
            maxFactor     = event.maxFactor,
            startText     = self:formatEventTime(event.startHour),
            endText       = self:formatEventTime(event.endHour),
            pending       = pending,
            sortKey       = pending and (1e9 + event.startHour) or event.endHour,
        })
    end
    -- laufende zuerst (die bald enden oben), dann angekündigte (die bald beginnen oben)
    table.sort(rows, function(a, b)
        if a.sortKey ~= b.sortKey then
            return a.sortKey < b.sortKey
        end
        return a.wareTitle < b.wareTitle
    end)
    return rows
end
