-- =====================================================================
-- LivingMarket (LS25 / FS25)
-- Verkaufsstellen nehmen pro Fruchtsorte nur eine begrenzte Menge an.
-- Der Bedarf füllt sich jede Spielstunde langsam wieder auf.
-- Anzeige auf einer eigenen Seite im Ingame-Menü (ESC).
--
-- Stand: Grundgerüst, nur Singleplayer, noch ohne Speichern.
-- =====================================================================

LivingMarket = {}
LivingMarket.modName = g_currentModName
LivingMarket.modDir  = g_currentModDirectory

-- ---------------------------------------------------------------------
-- Einstellungen
-- ---------------------------------------------------------------------
LivingMarket.DEFAULT_MAX    = 30000   -- Liter, wenn Fruchtsorte nicht in der Liste
LivingMarket.REFILL_SHARE   = 0.05    -- Anteil vom Maximum, der pro Spielstunde zurückkommt
LivingMarket.MENU_PAGE_NAME = "pageLivingMarket"
LivingMarket.MENU_AFTER     = "pagePrices"   -- Reiter hinter "Preise" einsortieren (falls vorhanden)
LivingMarket.DEBUG          = true

-- Grundmengen pro Fruchtsorte (Name wie in fillTypes.xml)
LivingMarket.BASE_AMOUNTS = {
    WHEAT     = 60000,
    BARLEY    = 60000,
    OAT       = 30000,
    MAIZE     = 60000,
    SORGHUM   = 30000,
    CANOLA    = 25000,
    SUNFLOWER = 25000,
    SOYBEAN   = 25000,
    POTATO    = 40000,
    SUGARBEET = 40000,
    RICE      = 30000,
    MILK      = 20000,
}

-- Fruchtsorten, die nie begrenzt und nicht angezeigt werden (Name wie in fillTypes.xml).
-- Geld/Bargeld: die Bank begrenzt auch nicht.
LivingMarket.EXCLUDED_FILLTYPES = {
    MONEY = true,
    CASH  = true,
}

-- ---------------------------------------------------------------------
-- Laufzeitdaten
-- ---------------------------------------------------------------------
LivingMarket.stations    = {}   -- [station] = { [fillTypeIndex] = { remaining, max, refill } }
LivingMarket.stationKind = {}   -- [station] = true (wird begrenzt) / false (z. B. Produktion)
LivingMarket.hasLoggedStations = false
LivingMarket.stationNames  = {}   -- [station] = Name (Cache)
LivingMarket.excludedCache = {}   -- [fillTypeIndex] = true/false (Cache)
LivingMarket.loggedMissionDeliveries = {}   -- nur fürs Log, damit jede Auftragslieferung einmal gemeldet wird

local function log(fmt, ...)
    if LivingMarket.DEBUG then
        print(string.format("[LivingMarket] " .. fmt, ...))
    end
end

-- ---------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------
local function isSellingStation(station)
    if type(station) ~= "table" then
        return false
    end
    if station.isSellingPoint == true then
        return true
    end
    if SellingStation ~= nil and station.isa ~= nil then
        local ok, result = pcall(station.isa, station, SellingStation)
        return ok and result == true
    end
    return false
end

-- Gehört die Verkaufsstelle zu einer Produktion? Dann wird sie nicht begrenzt.
local function isProductionStation(station)
    local placeable = station.owningPlaceable
    if placeable ~= nil and placeable.spec_productionPoint ~= nil then
        return true
    end

    local manager = g_currentMission ~= nil and g_currentMission.productionChainManager or nil
    if manager ~= nil and manager.productionPoints ~= nil then
        for _, productionPoint in pairs(manager.productionPoints) do
            if productionPoint.sellingStation == station or productionPoint.unloadingStation == station then
                return true
            end
        end
    end
    return false
end

-- Nur reine Verkaufsstellen (keine Produktionen) werden begrenzt.
-- Ergebnis wird pro Station zwischengespeichert, weil die Abfrage beim Abladen oft kommt.
function LivingMarket:isLimitedStation(station)
    local cached = self.stationKind[station]
    if cached == nil then
        cached = isSellingStation(station) and not isProductionStation(station)
        self.stationKind[station] = cached
    end
    return cached
end

local function readStationName(station)
    if station.getName ~= nil then
        local ok, name = pcall(station.getName, station)
        if ok and name ~= nil and name ~= "" then
            return name
        end
    end
    local placeable = station.owningPlaceable
    if placeable ~= nil and placeable.getName ~= nil then
        local ok, name = pcall(placeable.getName, placeable)
        if ok and name ~= nil and name ~= "" then
            return name
        end
    end
    return station.stationName or g_i18n:getText("livingMarket_unknownStation")
end

-- Name wird pro Station zwischengespeichert (wird beim Sortieren sehr oft abgefragt)
local function getStationName(station)
    local name = LivingMarket.stationNames[station]
    if name == nil then
        name = readStationName(station)
        LivingMarket.stationNames[station] = name
    end
    return name
end

-- Kleinschreibung für die Suche (utf8ToLower kann auch Umlaute)
function LivingMarket.toLower(text)
    if utf8ToLower ~= nil then
        return utf8ToLower(text or "")
    end
    return string.lower(text or "")
end

local function getFillTypeTitle(fillTypeIndex)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType ~= nil then
        return fillType.title or fillType.name
    end
    return tostring(fillTypeIndex)
end

local function formatLiters(liters)
    if g_i18n ~= nil and g_i18n.formatVolume ~= nil then
        return g_i18n:formatVolume(liters, 0)
    end
    return string.format("%d l", math.floor(liters))
end

local function isServer()
    return g_server ~= nil
end

local function isMultiplayer()
    local mission = g_currentMission
    return mission ~= nil and mission.missionDynamicInfo ~= nil and mission.missionDynamicInfo.isMultiplayer == true
end

-- Ausgenommene Fruchtsorte (z. B. Geld)? Prüft den internen Namen und als
-- Rückfall alles, was "MONEY" oder "CASH" im Namen trägt (Mod-Füllarten).
-- Ergebnis wird je Füllart gemerkt, weil die Abfrage beim Abladen jeden Frame kommt.
function LivingMarket:isExcludedFillType(fillTypeIndex)
    local cached = self.excludedCache[fillTypeIndex]
    if cached ~= nil then
        return cached
    end

    local excluded = false
    local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    if name ~= nil then
        name = string.upper(name)
        excluded = self.EXCLUDED_FILLTYPES[name] == true
            or string.find(name, "MONEY", 1, true) ~= nil
            or string.find(name, "CASH", 1, true) ~= nil
    end

    self.excludedCache[fillTypeIndex] = excluded
    return excluded
end

-- Maximum + Auffüllrate für eine Station/Fruchtsorte
function LivingMarket:getLimitFor(station, fillTypeIndex)
    local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    local max = self.BASE_AMOUNTS[name] or self.DEFAULT_MAX
    -- Platz für spätere Logik: Preisfaktor, Stationstyp, Ereignisse ...
    return max, max * self.REFILL_SHARE
end

function LivingMarket:getStationData(station)
    local data = self.stations[station]
    if data == nil then
        data = {}
        self.stations[station] = data
    end
    return data
end

function LivingMarket:getEntry(station, fillTypeIndex)
    if fillTypeIndex == nil or not self:isLimitedStation(station) or self:isExcludedFillType(fillTypeIndex) then
        return nil
    end
    if station.acceptedFillTypes ~= nil and not station.acceptedFillTypes[fillTypeIndex] then
        return nil
    end
    local data = self:getStationData(station)
    local entry = data[fillTypeIndex]
    if entry == nil then
        local max, refill = self:getLimitFor(station, fillTypeIndex)
        entry = { remaining = max, max = max, refill = refill }
        data[fillTypeIndex] = entry
    end
    return entry
end

-- Alle Verkaufsstellen der Map einsammeln
function LivingMarket:collectStations()
    local result = {}
    local storageSystem = g_currentMission ~= nil and g_currentMission.storageSystem or nil
    if storageSystem == nil or storageSystem.getUnloadingStations == nil then
        log("storageSystem:getUnloadingStations() nicht gefunden")
        return result
    end
    for key, value in pairs(storageSystem:getUnloadingStations()) do
        -- je nach Version ist die Station Schlüssel oder Wert der Tabelle
        local station = type(key) == "table" and key or value
        if self:isLimitedStation(station) then
            table.insert(result, station)
        end
    end
    table.sort(result, function(a, b) return getStationName(a) < getStationName(b) end)
    return result
end

-- Aktueller Verkaufspreis je 1000 Liter an dieser Station (wie im Preise-Menü des Spiels)
function LivingMarket:getPricePer1000(station, fillTypeIndex)
    if station.getEffectiveFillTypePrice ~= nil then
        local ok, pricePerLiter = pcall(station.getEffectiveFillTypePrice, station, fillTypeIndex)
        if ok and pricePerLiter ~= nil then
            return pricePerLiter * 1000
        end
    end
    return 0
end

function LivingMarket.formatMoney(value)
    if g_i18n ~= nil and g_i18n.formatMoney ~= nil then
        local ok, text = pcall(g_i18n.formatMoney, g_i18n, value, 0, true, true)
        if ok and text ~= nil then
            return text
        end
    end
    return string.format("%d €", math.floor(value + 0.5))
end

-- Aufbereitete Daten für die Menüseite: eine Zeile pro Ware, darin alle
-- Stationen mit Preis und Restbedarf, sortiert nach Preis
function LivingMarket:getWareData()
    local stations = self:collectStations()   -- nur einmal pro Aufruf einsammeln

    -- Einmalig alle Stationen mit ihren Waren ins Log (Hilfe bei der Fehlersuche)
    if self.DEBUG and not self.hasLoggedStations then
        self.hasLoggedStations = true
        for _, station in ipairs(stations) do
            local names = {}
            for fillTypeIndex, accepted in pairs(station.acceptedFillTypes or {}) do
                if accepted then
                    local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex) or tostring(fillTypeIndex)
                    if self:isExcludedFillType(fillTypeIndex) then
                        name = name .. "(ausgenommen)"
                    end
                    table.insert(names, name)
                end
            end
            table.sort(names)
            log("Station '%s' (%d Waren): %s", getStationName(station), #names, table.concat(names, ", "))
        end
    end

    -- Pro Ware alle Stationen sammeln, die sie annehmen
    local wares = {}
    local byFillType = {}
    local stock = self:getFarmStock()

    for _, station in ipairs(stations) do
        local stationName = getStationName(station)
        for fillTypeIndex, accepted in pairs(station.acceptedFillTypes or {}) do
            if accepted then
                local entry = self:getEntry(station, fillTypeIndex)
                if entry ~= nil then
                    local ware = byFillType[fillTypeIndex]
                    if ware == nil then
                        local title = getFillTypeTitle(fillTypeIndex)
                        ware = {
                            fillTypeIndex = fillTypeIndex,
                            title         = title,
                            searchKey     = LivingMarket.toLower(title),
                            stock         = stock[fillTypeIndex] or 0,
                            stations      = {}
                        }
                        byFillType[fillTypeIndex] = ware
                        table.insert(wares, ware)
                    end
                    table.insert(ware.stations, {
                        name      = stationName,
                        searchKey = LivingMarket.toLower(stationName),
                        price     = self:getPricePer1000(station, fillTypeIndex),
                        remaining = entry.remaining,
                        max       = entry.max,
                        share     = entry.max > 0 and entry.remaining / entry.max or 0
                    })
                end
            end
        end
    end

    -- Stationen je Ware nach Preis sortieren, beste Station mit freiem Bedarf bestimmen
    for _, ware in ipairs(wares) do
        table.sort(ware.stations, function(a, b)
            if a.price ~= b.price then
                return a.price > b.price
            end
            return a.name < b.name
        end)

        ware.best = nil
        for _, entry in ipairs(ware.stations) do
            if entry.remaining >= 1 then
                ware.best = entry   -- erste mit Bedarf = höchster Preis mit Bedarf
                break
            end
        end

        if ware.best ~= nil then
            ware.sellable = math.min(ware.stock, ware.best.remaining)
            ware.revenue  = ware.sellable * ware.best.price / 1000
        else
            ware.sellable = 0
            ware.revenue  = 0
        end
    end

    table.sort(wares, function(a, b) return a.title < b.title end)
    return wares
end

-- ---------------------------------------------------------------------
-- Lagerbestand des eigenen Hofs
-- Zählt Silos/Lager (inkl. Tierställe), Produktionslager sowie Paletten
-- und Fahrzeuge. Ergebnis: [fillTypeIndex] = Liter
-- ---------------------------------------------------------------------
local function getOwner(object)
    if object == nil then
        return nil
    end
    if object.getOwnerFarmId ~= nil then
        local ok, farmId = pcall(object.getOwnerFarmId, object)
        if ok and farmId ~= nil then
            return farmId
        end
    end
    return object.ownerFarmId
end

-- Name eines Lagers/Gebäudes/Fahrzeugs fürs Log
local function describe(object, fallback)
    for _, candidate in ipairs({ object, object ~= nil and object.owningPlaceable or nil }) do
        if candidate ~= nil then
            for _, getter in ipairs({ "getFullName", "getName" }) do
                if candidate[getter] ~= nil then
                    local ok, name = pcall(candidate[getter], candidate)
                    if ok and name ~= nil and name ~= "" then
                        return name
                    end
                end
            end
        end
    end
    return fallback
end

-- sources (nur zur Fehlersuche): [fillTypeIndex] = { "Quelle: Menge", ... }
local function addStock(stock, fillTypeIndex, amount, sources, sourceName)
    if fillTypeIndex ~= nil and amount ~= nil and amount > 0 then
        stock[fillTypeIndex] = (stock[fillTypeIndex] or 0) + amount
        if sources ~= nil then
            sources[fillTypeIndex] = sources[fillTypeIndex] or {}
            table.insert(sources[fillTypeIndex], string.format("%s: %.0f", sourceName, amount))
        end
    end
end

local function addStorage(stock, storage, farmId, visited, sources, kind)
    if storage == nil or visited[storage] or getOwner(storage) ~= farmId then
        return
    end
    visited[storage] = true
    local name = kind .. " '" .. describe(storage, "?") .. "'"
    for fillTypeIndex, level in pairs(storage.fillLevels or {}) do
        addStock(stock, fillTypeIndex, level, sources, name)
    end
end

function LivingMarket:getFarmId()
    local mission = g_currentMission
    if mission ~= nil and mission.getFarmId ~= nil then
        return mission:getFarmId()
    end
    return mission ~= nil and mission.player ~= nil and mission.player.farmId or nil
end

function LivingMarket:getFarmStock()
    local stock = {}
    local farmId = self:getFarmId()
    local mission = g_currentMission
    if farmId == nil or mission == nil then
        return stock
    end
    local visited = {}

    -- Beim ersten Aufruf ins Log schreiben, woher jede Lagermenge stammt
    local sources = (self.DEBUG and not self.hasLoggedStock) and {} or nil

    -- 1) Silos und Lager (auch Tierställe), wie sie das Storage-System kennt
    local storageSystem = mission.storageSystem
    if storageSystem ~= nil and storageSystem.storages ~= nil then
        for key, value in pairs(storageSystem.storages) do
            local storage = (type(key) == "table" and key.fillLevels ~= nil) and key or value
            if type(storage) == "table" then
                addStorage(stock, storage, farmId, visited, sources, "Lager")
            end
        end
    end

    -- 2) Lager der Produktionen (fertige Erzeugnisse)
    local manager = mission.productionChainManager
    if manager ~= nil and manager.productionPoints ~= nil then
        for _, productionPoint in pairs(manager.productionPoints) do
            if getOwner(productionPoint) == farmId then
                addStorage(stock, productionPoint.storage, farmId, visited, sources, "Produktion")
            end
        end
    end

    -- 3) Paletten und Fahrzeuge (Füllstände aller Fülleinheiten)
    local vehicles = (mission.vehicleSystem ~= nil and mission.vehicleSystem.vehicles) or mission.vehicles
    for _, vehicle in pairs(vehicles or {}) do
        local spec = vehicle.spec_fillUnit
        if spec ~= nil and spec.fillUnits ~= nil and getOwner(vehicle) == farmId then
            -- Betriebsstoffe (Diesel, AdBlue, Strom, Methan im Tank) zählen nicht als Ware
            local consumers = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.consumersByFillType or nil
            for _, fillUnit in ipairs(spec.fillUnits) do
                local isConsumable = consumers ~= nil and fillUnit.fillType ~= nil and consumers[fillUnit.fillType] ~= nil
                if not isConsumable then
                    addStock(stock, fillUnit.fillType, fillUnit.fillLevel, sources, "Fahrzeug/Palette '" .. describe(vehicle, "?") .. "'")
                end
            end
        end
    end

    if sources ~= nil then
        self.hasLoggedStock = true
        local lines = {}
        for fillTypeIndex, list in pairs(sources) do
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            local name = fillType ~= nil and fillType.name or tostring(fillTypeIndex)
            local unit = fillType ~= nil and fillType.unitShort or nil
            table.insert(lines, string.format("Lager %s = %.0f%s <- %s", name, stock[fillTypeIndex] or 0,
                unit ~= nil and (" (Einheit " .. tostring(unit) .. ")") or "", table.concat(list, " | ")))
        end
        table.sort(lines)
        for _, line in ipairs(lines) do
            log("%s", line)
        end
    end

    return stock
end

function LivingMarket.formatLiters(liters)
    return formatLiters(liters)
end

-- ---------------------------------------------------------------------
-- Hooks in die SellingStation
-- ---------------------------------------------------------------------

-- Freie Kapazität: das Abkippen stoppt, wenn hier 0 zurückkommt
-- ---------------------------------------------------------------------
-- Aufträge (z. B. Ernteaufträge): Lieferungen dafür werden nie begrenzt
-- und zählen nicht gegen das Kontingent, sonst ließe sich ein Auftrag
-- an einer vollen Station nicht abschließen.
-- ---------------------------------------------------------------------
local function getMissionFillType(mission)
    if mission.fillTypeIndex ~= nil then
        return mission.fillTypeIndex
    end
    if type(mission.fillType) == "number" then
        return mission.fillType
    end
    if mission.fruitTypeIndex ~= nil and g_fruitTypeManager ~= nil and g_fruitTypeManager.getFillTypeIndexByFruitTypeIndex ~= nil then
        return g_fruitTypeManager:getFillTypeIndexByFruitTypeIndex(mission.fruitTypeIndex)
    end
    return nil   -- unbekannt: dann gilt der Auftrag für jede Ware dieser Station
end

local function missionTargetsStation(mission, station)
    if mission.sellingStation == station then
        return true
    end
    local placeable = mission.sellingStationPlaceable
    return placeable ~= nil and station.owningPlaceable == placeable
end

function LivingMarket:isMissionDelivery(station, fillTypeIndex, farmId)
    local manager = g_missionManager
    if manager == nil or manager.getMissions == nil or MissionStatus == nil then
        return false
    end
    for _, mission in ipairs(manager:getMissions() or {}) do
        if mission.status == MissionStatus.RUNNING
            and (farmId == nil or mission.farmId == farmId)
            and missionTargetsStation(mission, station) then
            local missionFillType = getMissionFillType(mission)
            if missionFillType == nil or missionFillType == fillTypeIndex then
                return true
            end
        end
    end
    return false
end

function LivingMarket.getFreeCapacity(station, superFunc, fillTypeIndex, ...)
    local capacity = superFunc(station, fillTypeIndex, ...)
    local entry = LivingMarket:getEntry(station, fillTypeIndex)
    if entry == nil then
        return capacity
    end
    -- Hof ist hier nicht sicher bekannt: laufender Auftrag irgendeines Hofs gibt die Ware frei
    if LivingMarket:isMissionDelivery(station, fillTypeIndex, nil) then
        return capacity
    end
    return math.min(capacity or math.huge, math.max(entry.remaining, 0))
end

-- Tatsächliche Annahme: Menge auf den Restbedarf kürzen und abziehen
function LivingMarket.addFillLevelFromTool(station, superFunc, farmId, deltaFillLevel, fillTypeIndex, ...)
    if not isServer() or deltaFillLevel == nil or deltaFillLevel <= 0 then
        return superFunc(station, farmId, deltaFillLevel, fillTypeIndex, ...)
    end

    local entry = LivingMarket:getEntry(station, fillTypeIndex)
    if entry == nil then
        return superFunc(station, farmId, deltaFillLevel, fillTypeIndex, ...)
    end

    -- Lieferung für einen laufenden Auftrag dieses Hofs: unbegrenzt, Kontingent bleibt unberührt
    if LivingMarket:isMissionDelivery(station, fillTypeIndex, farmId) then
        local key = tostring(station) .. "/" .. tostring(fillTypeIndex)
        if not LivingMarket.loggedMissionDeliveries[key] then
            LivingMarket.loggedMissionDeliveries[key] = true
            log("Auftragslieferung erkannt: '%s', %s - kein Limit", getStationName(station),
                tostring(g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)))
        end
        return superFunc(station, farmId, deltaFillLevel, fillTypeIndex, ...)
    end

    local allowed = math.min(deltaFillLevel, math.max(entry.remaining, 0))
    if allowed <= 0 then
        return 0
    end

    local moved = superFunc(station, farmId, allowed, fillTypeIndex, ...)
    local used = moved or allowed
    entry.remaining = math.max(entry.remaining - used, 0)
    LivingMarket:markDirty(entry)
    return moved
end

function LivingMarket.onStationDelete(station)
    LivingMarket.stations[station] = nil
    LivingMarket.stationKind[station] = nil
    LivingMarket.stationNames[station] = nil
end

if SellingStation ~= nil then
    SellingStation.getFreeCapacity      = Utils.overwrittenFunction(SellingStation.getFreeCapacity, LivingMarket.getFreeCapacity)
    SellingStation.addFillLevelFromTool = Utils.overwrittenFunction(SellingStation.addFillLevelFromTool, LivingMarket.addFillLevelFromTool)
    SellingStation.delete               = Utils.prependedFunction(SellingStation.delete, LivingMarket.onStationDelete)
else
    print("[LivingMarket] WARNUNG: Klasse SellingStation nicht gefunden - Begrenzung inaktiv")
end

-- ---------------------------------------------------------------------
-- Auffüllen jede Spielstunde
-- ---------------------------------------------------------------------
function LivingMarket:onHourChanged()
    if not isServer() then
        return
    end
    for _, data in pairs(self.stations) do
        for _, entry in pairs(data) do
            if entry.remaining < entry.max then
                entry.remaining = math.min(entry.remaining + entry.refill, entry.max)
                self:markDirty(entry)
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- Multiplayer
-- Der Server verwaltet die Kontingente allein und schickt sie an die
-- Clients. Clients ändern nie selbst etwas, sie zeigen nur an.
-- ---------------------------------------------------------------------
LivingMarket.SYNC_INTERVAL = 1000   -- ms, geänderte Werte höchstens so oft senden
LivingMarket.syncTimer     = 0
LivingMarket.hasDirty      = false

function LivingMarket:markDirty(entry)
    if isServer() and isMultiplayer() then
        entry.isDirty = true
        self.hasDirty = true
    end
end

-- Station zu einem Placeable finden (Gegenstück für die Clients)
function LivingMarket:getStationByPlaceable(placeable)
    if placeable == nil then
        return nil
    end
    local spec = placeable.spec_sellingStation
    if spec ~= nil and spec.sellingStation ~= nil then
        return spec.sellingStation
    end
    for _, station in ipairs(self:collectStations()) do
        if station.owningPlaceable == placeable then
            return station
        end
    end
    return nil
end

-- Einträge für das Sync-Event zusammenstellen
-- onlyDirty = true: nur geänderte, sonst alle (für neue Mitspieler)
function LivingMarket:collectSyncEntries(onlyDirty)
    local result = {}

    if not onlyDirty then
        -- sicherstellen, dass alle Einträge existieren
        for _, station in ipairs(self:collectStations()) do
            if station.acceptedFillTypes ~= nil then
                for fillTypeIndex, accepted in pairs(station.acceptedFillTypes) do
                    if accepted then
                        self:getEntry(station, fillTypeIndex)
                    end
                end
            end
        end
    end

    for station, data in pairs(self.stations) do
        local placeable = station.owningPlaceable
        for fillTypeIndex, entry in pairs(data) do
            if not onlyDirty or entry.isDirty then
                if placeable ~= nil then
                    table.insert(result, {
                        placeable     = placeable,
                        fillTypeIndex = fillTypeIndex,
                        remaining     = entry.remaining,
                        max           = entry.max,
                        refill        = entry.refill
                    })
                end
                entry.isDirty = false
            end
        end
    end
    return result
end

-- Auf dem Client: Werte vom Server übernehmen
function LivingMarket:applySyncEntries(entries)
    for _, e in ipairs(entries) do
        local station = self:getStationByPlaceable(e.placeable)
        if station ~= nil then
            local entry = self:getEntry(station, e.fillTypeIndex)
            if entry ~= nil then
                entry.remaining = e.remaining
                entry.max       = e.max
                entry.refill    = e.refill
            end
        end
    end
end

-- Neuer Mitspieler: kompletten Stand schicken
function LivingMarket.sendInitialClientState(mission, connection, user, farm)
    local entries = LivingMarket:collectSyncEntries(false)
    if #entries > 0 then
        connection:sendEvent(LivingMarketSyncEvent.new(entries))
    end
end

if FSBaseMission ~= nil and FSBaseMission.sendInitialClientState ~= nil then
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, LivingMarket.sendInitialClientState)
end

function LivingMarket:update(dt)
    if not self.hasDirty then
        return
    end
    self.syncTimer = self.syncTimer - dt
    if self.syncTimer > 0 then
        return
    end
    self.syncTimer = self.SYNC_INTERVAL
    self.hasDirty = false

    local entries = self:collectSyncEntries(true)
    if #entries > 0 and g_server ~= nil then
        g_server:broadcastEvent(LivingMarketSyncEvent.new(entries))
    end
end

-- ---------------------------------------------------------------------
-- Eigene Seite im Ingame-Menü (ESC)
-- Vorgehen wie bei Courseplay / ImprovedControlsMenu für LS25
-- ---------------------------------------------------------------------
local function findIndex(list, matchFn)
    for i = 1, #list do
        if matchFn(list[i]) then
            return i
        end
    end
    return nil
end

local function moveTo(list, matchFn, position)
    local index = findIndex(list, matchFn)
    if index ~= nil and position ~= nil then
        local item = table.remove(list, index)
        table.insert(list, math.max(1, math.min(position, #list + 1)), item)
    end
end

function LivingMarket:addMenuPage()
    local inGameMenu = g_inGameMenu
    if inGameMenu == nil or inGameMenu.pagingElement == nil then
        log("Ingame-Menü nicht gefunden, Seite wird nicht angelegt")
        return
    end

    local pageName = self.MENU_PAGE_NAME
    if inGameMenu[pageName] ~= nil then
        return   -- schon vorhanden (z. B. zweiter Spielstand in derselben Sitzung)
    end

    local frame = LivingMarketFrame.new()
    frame.customEnvironment = self.modName
    g_gui:loadGui(self.modDir .. "gui/LivingMarketFrame.xml", "LivingMarketFrame", frame, true)
    frame:initialize()

    -- Zielpositionen hinter der "Preise"-Seite ermitteln (vor dem Einfügen)
    local afterPage = inGameMenu[self.MENU_AFTER]
    local posElement, posPage, posFrame
    if afterPage ~= nil then
        local i = findIndex(inGameMenu.pagingElement.elements, function(e) return e == afterPage end)
        posElement = i and i + 1
        i = findIndex(inGameMenu.pagingElement.pages, function(p) return p.element == afterPage end)
        posPage = i and i + 1
        i = findIndex(inGameMenu.pageFrames, function(f) return f == afterPage end)
        posFrame = i and i + 1
    else
        log("Seite '%s' nicht gefunden, Reiter wird hinten angehängt", self.MENU_AFTER)
    end

    inGameMenu.controlIDs[pageName] = nil
    inGameMenu[pageName] = frame
    inGameMenu.pagingElement:addElement(frame)
    inGameMenu:exposeControlsAsFields(pageName)

    moveTo(inGameMenu.pagingElement.elements, function(e) return e == frame end, posElement)
    moveTo(inGameMenu.pagingElement.pages, function(p) return p.element == frame end, posPage)

    inGameMenu.pagingElement:updateAbsolutePosition()
    inGameMenu.pagingElement:updatePageMapping()

    inGameMenu:registerPage(frame, posFrame, function() return true end)

    local iconFile = Utils.getFilename("images/menuIcon.dds", self.modDir)
    inGameMenu:addPageTab(frame, iconFile, GuiUtils.getUVs({0, 0, 128, 128}, {128, 128}))

    inGameMenu:rebuildTabList()
    log("Menüseite angelegt")
end

-- ---------------------------------------------------------------------
-- Mod-Event-Listener
-- ---------------------------------------------------------------------
function LivingMarket:loadMap(name)
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)

    local ok, err = pcall(self.addMenuPage, self)
    if not ok then
        print("[LivingMarket] FEHLER beim Anlegen der Menüseite: " .. tostring(err))
    end

    log("geladen")
end

function LivingMarket:deleteMap()
    g_messageCenter:unsubscribeAll(self)
    self.stations = {}
    self.stationKind = {}
    self.stationNames = {}
    self.excludedCache = {}
    self.loggedMissionDeliveries = {}
    self.hasLoggedStock = false
    self.hasLoggedStations = false
    self.hasDirty = false
    self.syncTimer = 0
end

addModEventListener(LivingMarket)
