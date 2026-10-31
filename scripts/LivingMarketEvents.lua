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
LivingMarket.EVENT_DEMAND    = 5   -- Nachgefragt: Station füllt schneller auf (eine Station)
LivingMarket.EVENT_SLOW      = 6   -- Ladenhüter: Station füllt langsamer auf (eine Station, nur Palettenware)

-- Standardwerte; werden aus der Konfigurationsdatei (<variation>, <events>) überschrieben
LivingMarket.EVENT_SETTINGS = {
    enabled        = true,
    minActive      = 10,     -- so viele Ereignisse sollen etwa gleichzeitig laufen (inkl. angekündigter)
    maxActive      = 20,
    minMonths      = 1,      -- Dauer eines Ereignisses
    maxMonths      = 2,
    announceMonths = 1,      -- marktweite Ereignisse so lange vorher ankündigen
    noise          = 0.10,   -- kleine Schwankung des Bedarfs ±10 % (je Monat neu)
    refillNoise    = 0.10,   -- kleine Schwankung der Auffüllung ±10 % (je Monat neu)
    -- je Ereignistyp: Gewicht (Häufigkeit), Preisänderung, Bedarfsfaktor, Auffüllungsänderung
    types = {
        [1] = { name = "shortage",   weight = 0.30,  minPrice = 0.10, maxPrice = 0.25, demandFactor = 1.5 },
        [2] = { name = "surplus",    weight = 0.25,  minPrice = 0.10, maxPrice = 0.25, demandFactor = 0.6 },
        [3] = { name = "boom",       weight = 0.125, minPrice = 0.10, maxPrice = 0.25, demandFactor = 1.3 },
        [4] = { name = "slump",      weight = 0.125, minPrice = 0.10, maxPrice = 0.25, demandFactor = 0.7 },
        [5] = { name = "demand",     weight = 0.12,  minRefill = 0.10, maxRefill = 0.50 },
        [6] = { name = "slowSeller", weight = 0.08,  minRefill = 0.10, maxRefill = 0.50, palletOnly = true },
    },
}
LivingMarket.EVENT_POSITIVE = { [1] = true, [3] = true, [5] = true }   -- erhöhen Preis/Auffüllung
LivingMarket.EVENT_GLOBAL   = { [3] = true, [4] = true }               -- marktweit, mit Ankündigung

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

-- Schwankung der Auffüllgeschwindigkeit
function LivingMarket:rollRefillNoise()
    local n = self.EVENT_SETTINGS.refillNoise
    return 1 + randomRange(-n, n)
end

-- Maximum/Auffüllung aus Grundwert × Schwankung × Ereignis.
-- Die Auffüllung wächst mit dem Maximum und hat zusätzlich eigene Schwankung und Ereignisfaktor.
-- keepShare = true: wächst das Maximum, wächst der freie Bedarf mit (Station braucht plötzlich mehr)
function LivingMarket:recalcEntryLimits(entry, keepShare)
    local factor = (entry.noise or 1) * (entry.eventMax or 1)
    local oldMax = entry.max
    -- auf volle 100 Liter abrunden (28.171 l -> 28.100 l)
    entry.max = math.max(100, math.floor((entry.baseMax or entry.max or 0) * factor / 100) * 100)
    local refillFactor = factor * (entry.refillNoise or 1) * (entry.eventRefill or 1)
    entry.refill = (entry.baseRefill or entry.refill or 0) * refillFactor
    if entry.remaining ~= nil then
        if keepShare and oldMax ~= nil and entry.max > oldMax then
            entry.remaining = entry.remaining + (entry.max - oldMax)
        end
        entry.remaining = math.max(0, math.min(entry.remaining, entry.max))
    end
end

-- Aktive Ereignisse auf einen Eintrag anwenden (Station + marktweit, Effekte werden multipliziert)
function LivingMarket:applyEventsToEntry(station, fillTypeIndex, entry)
    entry.eventPrice, entry.eventMax, entry.eventRefill, entry.eventType = 1, 1, 1, self.EVENT_NONE
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
                entry.eventRefill = entry.eventRefill * (event.refillFactor or 1)
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
            local oldPrice, oldMax, oldRefill, oldType = entry.eventPrice, entry.max, entry.refill, entry.eventType
            self:applyEventsToEntry(station, fillTypeIndex, entry)
            self:recalcEntryLimits(entry, true)
            if oldPrice ~= entry.eventPrice or oldMax ~= entry.max or oldRefill ~= entry.refill or oldType ~= entry.eventType then
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

-- Meldung aus Schlüssel + Werten zusammensetzen (jeder Rechner in seiner Sprache)
function LivingMarket:showNotification(key, stationName, fillTypeIndex, percent, months, isWarning)
    local ware = fillTypeTitle(fillTypeIndex)
    local text = g_i18n:getText(key)
    if stationName ~= nil and stationName ~= "" then
        text = string.format(text, stationName, ware, percent, months)
    else
        text = string.format(text, ware, percent, months)
    end
    self:notify(text, isWarning)
end

-- Ereignisliste an alle Mitspieler schicken (nur Server, nur im Multiplayer)
function LivingMarket:broadcastEventList()
    if g_server ~= nil and g_currentMission ~= nil and g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer and LivingMarketEventListEvent ~= nil then
        g_server:broadcastEvent(LivingMarketEventListEvent.new(self.events))
    end
end

function LivingMarket:announceEvent(event, phase)
    local isRefillEvent = event.type == self.EVENT_DEMAND or event.type == self.EVENT_SLOW
    local percent = math.floor(math.abs((isRefillEvent and (event.refillFactor or 1) or event.price) - 1) * 100 + 0.5)
    local key
    if phase == "end" then
        key = event.stationKey ~= nil and "livingMarket_evEndStation" or "livingMarket_evEndMarket"
    elseif event.type == self.EVENT_DEMAND then
        key = "livingMarket_evDemand"
    elseif event.type == self.EVENT_SLOW then
        key = "livingMarket_evSlow"
    elseif event.type == self.EVENT_SHORTAGE then
        key = "livingMarket_evShortage"
    elseif event.type == self.EVENT_SURPLUS then
        key = "livingMarket_evSurplus"
    elseif event.type == self.EVENT_BOOM then
        key = phase == "announce" and "livingMarket_evBoomAnnounce" or "livingMarket_evBoomStart"
    else
        key = phase == "announce" and "livingMarket_evSlumpAnnounce" or "livingMarket_evSlumpStart"
    end
    local stationName = event.stationKey ~= nil and self:getEventStationName(event) or ""
    local isWarning = event.type == self.EVENT_SURPLUS or event.type == self.EVENT_SLUMP or event.type == self.EVENT_SLOW
    self:showNotification(key, stationName, event.fillTypeIndex, percent, event.months or 1, isWarning)
    -- Mitspieler bekommen die Meldung als Schlüssel + Werte und setzen sie in ihrer Sprache zusammen
    if g_server ~= nil and LivingMarketNotifyEvent ~= nil and g_currentMission.missionDynamicInfo ~= nil
        and g_currentMission.missionDynamicInfo.isMultiplayer then
        g_server:broadcastEvent(LivingMarketNotifyEvent.new(key, stationName, event.fillTypeIndex, percent, event.months or 1, isWarning))
    end
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

-- Palettenware (Ladenhüter nur bei diesen Waren)
function LivingMarket.isPalletWare(fillTypeIndex)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    return fillType ~= nil and fillType.palletFilename ~= nil
end

-- Zufällige Station und Ware für ein Stationsereignis (filter: optionale Bedingung für die Ware)
function LivingMarket:pickStationWare(filter)
    local stations = self:collectStations()
    for _ = 1, (filter ~= nil and 40 or 20) do
        local station = stations[math.random(1, math.max(1, #stations))]
        if station ~= nil and station.acceptedFillTypes ~= nil then
            local candidates = {}
            for fillTypeIndex, accepted in pairs(station.acceptedFillTypes) do
                if accepted and (filter == nil or filter(fillTypeIndex)) and self:getEntry(station, fillTypeIndex) ~= nil then
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
function LivingMarket.getNowHour()
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    if env == nil then
        return 0
    end
    local day = env.currentMonotonicDay or env.currentDay or 0
    return day * 24 + (env.currentHour or 0)
end

-- Zeitpunkt (absolute Stunde) als "Okt 14:00" bzw. "Okt 2. 14:00" bei mehreren Tagen je Monat
function LivingMarket:formatEventTime(absHour)
    local env = g_currentMission ~= nil and g_currentMission.environment or nil
    local daysPerMonth = math.max(1, math.floor(self.getHoursPerMonth() / 24 + 0.5))
    local hoursPerMonth = daysPerMonth * 24
    local now = self.getNowHour()
    local nowHourOfDay = env ~= nil and env.currentHour or 0
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
-- Ereignistyp nach Gewicht auswählen
function LivingMarket:pickEventType()
    local total = 0
    for _, settings in pairs(self.EVENT_SETTINGS.types) do
        total = total + math.max(0, settings.weight or 0)
    end
    if total <= 0 then
        return nil
    end
    local roll = math.random() * total
    for eventType = 1, 6 do
        local settings = self.EVENT_SETTINGS.types[eventType]
        if settings ~= nil and (settings.weight or 0) > 0 then
            roll = roll - settings.weight
            if roll <= 0 then
                return eventType, settings
            end
        end
    end
    return nil
end

-- Änderung um ±min..max (Vorzeichen je nach Typ), 1 = keine Änderung
local function rollChange(eventType, minValue, maxValue)
    if maxValue == nil or maxValue <= 0 then
        return 1
    end
    local change = randomRange(minValue or 0, maxValue)
    return LivingMarket.EVENT_POSITIVE[eventType] and (1 + change) or math.max(0.05, 1 - change)
end

function LivingMarket:createRandomEvent()
    local s = self.EVENT_SETTINGS
    local eventType, settings = self:pickEventType()
    if eventType == nil then
        return nil
    end
    local months = math.random(s.minMonths, math.max(s.minMonths, s.maxMonths))
    local now = self.getNowHour()
    local hoursPerMonth = self.getHoursPerMonth()

    local event = {
        type         = eventType,
        price        = rollChange(eventType, settings.minPrice, settings.maxPrice),
        maxFactor    = settings.demandFactor or 1,
        refillFactor = rollChange(eventType, settings.minRefill, settings.maxRefill),
        months       = months,
        active       = false,
    }
    if self.EVENT_GLOBAL[eventType] then
        -- marktweit: vorher angekündigt
        event.fillTypeIndex = self:pickMarketWare()
        if event.fillTypeIndex == nil then
            return nil
        end
        event.startHour = now + (s.announceMonths or 0) * hoursPerMonth
    else
        -- eine Station: beginnt sofort
        local filter = settings.palletOnly and self.isPalletWare or nil
        local station, stationKey, fillTypeIndex = self:pickStationWare(filter)
        if station == nil then
            return nil
        end
        event.fillTypeIndex, event.stationKey = fillTypeIndex, stationKey
        event.startHour = now
    end
    event.endHour = event.startHour + months * hoursPerMonth
    return event
end

function LivingMarket:rollEventTarget()
    local s = self.EVENT_SETTINGS
    self.eventTarget = math.random(s.minActive, math.max(s.minActive, s.maxActive))
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
    local missing = self.EVENT_SETTINGS.enabled and (self.eventTarget - #self.events) or 0
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
        self:broadcastEventList()
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
    self:broadcastEventList()
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
            entry.refillNoise = self:rollRefillNoise()
        end
    end
    self:rollEventTarget()
    self:applyEventsToAll()
    log("Monatswechsel: Schwankungen neu, Ziel %d Marktereignisse", self.eventTarget)
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
        if event.refillFactor ~= nil and event.refillFactor ~= 1 then
            setXMLFloat(xmlFile, key .. "#refillFactor", event.refillFactor)
        end
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
                refillFactor  = getXMLFloat(xmlFile, key .. "#refillFactor") or 1,
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
            isGlobal      = event.stationKey == nil,
            startHour     = event.startHour,
            endHour       = event.endHour,
            pricePercent  = math.floor((event.price - 1) * 100 + 0.5),
            maxFactor     = event.maxFactor,
            refillFactor  = event.refillFactor or 1,
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
