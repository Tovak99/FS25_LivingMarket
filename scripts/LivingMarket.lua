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
LivingMarket.MENU_PAGE_NAME = "pageLivingMarket"
LivingMarket.MENU_AFTER     = "pagePrices"   -- Reiter hinter "Preise" einsortieren (falls vorhanden)
LivingMarket.DEBUG          = false   -- true: Testknöpfe im Menü und ausführliche Log-Einträge

-- Bedarf je Ware: kommt aus der Konfigurationsdatei (config/defaultConfig.xml bzw. die Kopie
-- in modSettings). Diese Werte gelten nur, falls keine Datei gelesen werden kann.
LivingMarket.CONFIG_FILENAME  = "FS25_LivingMarket_config.xml"
LivingMarket.FALLBACK_MAX     = 60000   -- Liter
LivingMarket.FALLBACK_REFILL  = 0.30    -- Anteil vom Maximum je Spielmonat
LivingMarket.config           = nil     -- { default = {max, refillPerMonth}, byFillType = {[index] = {max, refillPerMonth, group}} }

-- Fruchtsorten, die nie begrenzt und nicht angezeigt werden (Name wie in fillTypes.xml).
-- Geld/Bargeld: die Bank begrenzt auch nicht.
LivingMarket.EXCLUDED_FILLTYPES = {
    MONEY       = true,
    CASH        = true,
    SERVICE     = true,   -- Wartung: wird nur verteilt, nicht transportiert
    MAINTENANCE = true,
    ELECTRICCHARGE = true, -- Elektrische Energie: nur verteilt/direkt verkauft
    ELECTRICITY    = true,
}

-- Waren, die sich gar nicht transportieren lassen (keine Palette und in keiner Füllart-Kategorie
-- für Anhänger, Tanks, Ballen ...), z. B. Wartung oder Strom: Sie werden nur verteilt und nicht
-- an Verkaufsstellen geliefert. Ergebnis wird beim ersten Zugriff ermittelt.
local function buildCategorizedSet()
    local set = {}
    local manager = g_fillTypeManager
    if manager == nil then
        return nil
    end
    local found = false
    if type(manager.fillTypeToCategories) == "table" then
        for index, categories in pairs(manager.fillTypeToCategories) do
            if type(categories) == "table" and next(categories) ~= nil then
                set[index] = true
                found = true
            end
        end
    end
    if type(manager.categoryNameToFillTypes) == "table" then
        for _, fillTypes in pairs(manager.categoryNameToFillTypes) do
            if type(fillTypes) == "table" then
                for key, value in pairs(fillTypes) do
                    -- je nach Spielversion { [index] = true } oder { index, ... }
                    local index = (value == true) and key or value
                    if type(index) == "number" then
                        set[index] = true
                        found = true
                    end
                end
            end
        end
    end
    return found and set or nil
end

function LivingMarket:isTransportableFillType(fillTypeIndex)
    if self.categorizedFillTypes == nil then
        self.categorizedFillTypes = buildCategorizedSet() or false
    end
    if self.categorizedFillTypes == false then
        return true   -- Kategorien nicht lesbar: nichts ausschließen
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType == nil then
        return true
    end
    if fillType.palletFilename ~= nil then
        return true
    end
    return self.categorizedFillTypes[fillTypeIndex] == true
end

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

-- Gehört die Verkaufsstelle zu einer Produktion? Ergebnis: das Objekt, dem sie gehört
-- (Gebäude oder Produktion), sonst nil
local function getProductionOwner(station)
    local placeable = station.owningPlaceable
    if placeable ~= nil and placeable.spec_productionPoint ~= nil then
        return placeable
    end

    local manager = g_currentMission ~= nil and g_currentMission.productionChainManager or nil
    if manager ~= nil and manager.productionPoints ~= nil then
        for _, productionPoint in pairs(manager.productionPoints) do
            if productionPoint.sellingStation == station or productionPoint.unloadingStation == station then
                return productionPoint.owningPlaceable or productionPoint
            end
        end
    end
    return nil
end

-- Gehört das Objekt einem Hof (Spieler)? Produktionen der Karte gehören niemandem.
local function isOwnedByFarm(object)
    if object == nil then
        return false
    end
    local farmId = nil
    if object.getOwnerFarmId ~= nil then
        local ok, value = pcall(object.getOwnerFarmId, object)
        farmId = ok and value or nil
    end
    farmId = farmId or object.ownerFarmId
    local spectator = FarmManager ~= nil and FarmManager.SPECTATOR_FARM_ID or 15
    return farmId ~= nil and farmId ~= 0 and farmId ~= spectator
end

-- Begrenzt werden Verkaufsstellen der Karte und fremde Produktionen (z. B. die BGA der Karte).
-- Ausgenommen sind Produktionen, die einem Hof gehören: dort liefert man eigene Zutaten an.
-- Die Art wird zwischengespeichert, der Besitz bei jeder Abfrage geprüft (Gebäude kann gekauft werden).
function LivingMarket:isLimitedStation(station)
    local kind = self.stationKind[station]
    if kind == nil then
        if not isSellingStation(station) then
            kind = false
        else
            local owner = getProductionOwner(station)
            kind = owner ~= nil and owner or true   -- true = reine Verkaufsstelle, Objekt = Produktion
        end
        self.stationKind[station] = kind
    end
    if kind == false then
        return false
    elseif kind == true then
        return true
    end
    return not isOwnedByFarm(kind)
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

function LivingMarket:getStationNameOf(station)
    return getStationName(station)
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
            or string.find(name, "SERVICE", 1, true) ~= nil
            or string.find(name, "MAINTENANCE", 1, true) ~= nil
        if not excluded and not self:isTransportableFillType(fillTypeIndex) then
            excluded = true
            log("Ware ausgenommen (nicht transportierbar, nur verteilbar): %s", name)
        end
    end

    self.excludedCache[fillTypeIndex] = excluded
    return excluded
end

-- Maximum + Auffüllrate für eine Station/Fruchtsorte
-- ---------------------------------------------------------------------
-- Konfiguration: Bedarf und Auffüllung je Warengruppe
-- ---------------------------------------------------------------------
function LivingMarket:getModSettingsDir()
    local dir = g_modSettingsDirectory
    if dir == nil and getUserProfileAppPath ~= nil then
        dir = getUserProfileAppPath() .. "modSettings/"
    end
    if dir == nil then
        return nil
    end
    if string.sub(dir, -1) ~= "/" then
        dir = dir .. "/"
    end
    if createFolder ~= nil then
        pcall(createFolder, dir)
    end
    return dir
end

-- Einstellungen für Marktlage, Schwankungen und Marktereignisse (fehlende Werte: Standard)
function LivingMarket:loadSettingsFromConfig(xmlFile)
    local function num(key, current)
        local value = getXMLFloat(xmlFile, key)
        return value ~= nil and value or current
    end

    local priceKey = "livingMarket.marketPrice"
    self.PRICE_FULL_SHARE = math.max(0.01, math.min(1, num(priceKey .. "#fullShare", self.PRICE_FULL_SHARE)))
    self.PRICE_MIN_SHARE  = math.max(0, math.min(self.PRICE_FULL_SHARE - 0.01, num(priceKey .. "#minShare", self.PRICE_MIN_SHARE)))
    self.PRICE_MIN_FACTOR = math.max(0, math.min(1, num(priceKey .. "#minFactor", self.PRICE_MIN_FACTOR)))
    self.PRICE_CURVE      = math.max(0.1, num(priceKey .. "#curve", self.PRICE_CURVE))

    local s = self.EVENT_SETTINGS
    s.noise       = math.max(0, math.min(0.9, num("livingMarket.variation#demand", s.noise)))
    s.refillNoise = math.max(0, math.min(0.9, num("livingMarket.variation#refill", s.refillNoise)))

    local eventsKey = "livingMarket.events"
    if hasXMLProperty(xmlFile, eventsKey) then
        local enabled = getXMLBool(xmlFile, eventsKey .. "#enabled")
        if enabled ~= nil then
            s.enabled = enabled
        end
        s.minActive      = math.max(0, math.floor(num(eventsKey .. "#minActive", s.minActive)))
        s.maxActive      = math.max(s.minActive, math.floor(num(eventsKey .. "#maxActive", s.maxActive)))
        s.minMonths      = math.max(1, math.floor(num(eventsKey .. "#minMonths", s.minMonths)))
        s.maxMonths      = math.max(s.minMonths, math.floor(num(eventsKey .. "#maxMonths", s.maxMonths)))
        s.announceMonths = math.max(0, num(eventsKey .. "#announceMonths", s.announceMonths))

        local byName = {}
        for _, settings in pairs(s.types) do
            byName[settings.name] = settings
        end
        local i = 0
        while true do
            local key = string.format("%s.event(%d)", eventsKey, i)
            if not hasXMLProperty(xmlFile, key) then
                break
            end
            local settings = byName[getXMLString(xmlFile, key .. "#type") or ""]
            if settings ~= nil then
                settings.weight       = math.max(0, num(key .. "#weight", settings.weight))
                settings.minPrice     = num(key .. "#minPrice", settings.minPrice)
                settings.maxPrice     = num(key .. "#maxPrice", settings.maxPrice)
                settings.demandFactor = num(key .. "#demandFactor", settings.demandFactor)
                settings.minRefill    = num(key .. "#minRefill", settings.minRefill)
                settings.maxRefill    = num(key .. "#maxRefill", settings.maxRefill)
                local palletOnly = getXMLBool(xmlFile, key .. "#palletOnly")
                if palletOnly ~= nil then
                    settings.palletOnly = palletOnly
                end
            end
            i = i + 1
        end
    end
end

function LivingMarket:loadConfig()
    local config = {
        default      = { max = self.FALLBACK_MAX, refillPerMonth = self.FALLBACK_REFILL },
        byFillType   = {},
        groupsByName = {},
        groupOrder   = {},   -- Reihenfolge wie in der Konfiguration (für den Gruppenfilter)
        -- Automatische Zuordnung für Waren, die nicht ausdrücklich in einer Gruppe stehen
        auto = {
            enabled      = true,
            fruitGroup   = "grain",      -- Feldfrüchte (Erntegut)
            windrowGroup = "forage",     -- Schwad/Halmgut
            milkGroup    = "milk",       -- Milch (lose)
            priceTiers   = {             -- Paletten-/Stückware nach Grundpreis je 1000 l
                { minPrice = 4000, group = "premium" },
                { minPrice = 1500, group = "food" },
                { minPrice = 0,    group = "intermediate" },
            }
        }
    }
    self.config = config

    local defaultPath = Utils.getFilename("config/defaultConfig.xml", self.modDir)
    local dir = self:getModSettingsDir()
    local userPath = dir ~= nil and (dir .. self.CONFIG_FILENAME) or nil

    -- Ältere Kopie (kleinere Version als die Standarddatei): als ..._old.xml sichern und neu anlegen
    if userPath ~= nil and fileExists(userPath) and copyFile ~= nil then
        local function readVersion(file)
            local xml = loadXMLFile("LivingMarketConfigVersion", file)
            if xml == nil or xml == 0 then
                return nil
            end
            local version = getXMLInt(xml, "livingMarket#version") or 1
            delete(xml)
            return version
        end
        local userVersion, defaultVersion = readVersion(userPath), readVersion(defaultPath)
        if userVersion ~= nil and defaultVersion ~= nil and userVersion < defaultVersion then
            local backupPath = dir .. string.gsub(self.CONFIG_FILENAME, "%.xml$", "_old.xml")
            pcall(copyFile, userPath, backupPath, true)
            pcall(copyFile, defaultPath, userPath, true)
            print(string.format("[LivingMarket] Konfiguration auf Version %d aktualisiert, alte Datei gesichert: %s", defaultVersion, backupPath))
        end
    end

    -- Beim ersten Start die Standarddatei nach modSettings kopieren, damit man sie anpassen kann
    if userPath ~= nil and not fileExists(userPath) and copyFile ~= nil then
        local ok = pcall(copyFile, defaultPath, userPath, false)
        if ok and fileExists(userPath) then
            log("Konfiguration angelegt: %s", userPath)
        end
    end
    local path = (userPath ~= nil and fileExists(userPath)) and userPath or defaultPath
    if not fileExists(path) then
        log("WARNUNG: keine Konfiguration gefunden - Standardwerte (%d l, %d %% je Monat)",
            self.FALLBACK_MAX, math.floor(self.FALLBACK_REFILL * 100 + 0.5))
        return
    end

    local xmlFile = loadXMLFile("LivingMarketConfig", path)
    if xmlFile == nil or xmlFile == 0 then
        log("WARNUNG: %s konnte nicht gelesen werden", path)
        return
    end

    config.default.max = getXMLFloat(xmlFile, "livingMarket.default#max") or config.default.max
    config.default.refillPerMonth = getXMLFloat(xmlFile, "livingMarket.default#refillPerMonth") or config.default.refillPerMonth

    local groupCount, fillTypeCount, unknown = 0, 0, {}
    local g = 0
    while true do
        local groupKey = string.format("livingMarket.groups.group(%d)", g)
        if not hasXMLProperty(xmlFile, groupKey) then
            break
        end
        local group = {
            name           = getXMLString(xmlFile, groupKey .. "#name") or tostring(g),
            title          = getXMLString(xmlFile, groupKey .. "#title"),
            max            = getXMLFloat(xmlFile, groupKey .. "#max") or config.default.max,
            refillPerMonth = getXMLFloat(xmlFile, groupKey .. "#refillPerMonth") or config.default.refillPerMonth
        }
        groupCount = groupCount + 1
        if config.groupsByName[group.name] == nil then
            table.insert(config.groupOrder, group)
        end
        config.groupsByName[group.name] = group
        local f = 0
        while true do
            local fillTypeKey = string.format("%s.fillType(%d)", groupKey, f)
            if not hasXMLProperty(xmlFile, fillTypeKey) then
                break
            end
            local name = getXMLString(xmlFile, fillTypeKey .. "#name")
            local fillTypeIndex = name ~= nil and g_fillTypeManager:getFillTypeIndexByName(name) or nil
            if fillTypeIndex ~= nil then
                config.byFillType[fillTypeIndex] = group
                fillTypeCount = fillTypeCount + 1
            elseif name ~= nil then
                table.insert(unknown, name)
            end
            f = f + 1
        end
        g = g + 1
    end

    -- Einstellungen der automatischen Zuordnung (fehlt der Abschnitt, gelten die Standardwerte)
    local autoKey = "livingMarket.autoGroups"
    if hasXMLProperty(xmlFile, autoKey) then
        local auto = config.auto
        local enabled = getXMLBool(xmlFile, autoKey .. "#enabled")
        if enabled ~= nil then
            auto.enabled = enabled
        end
        auto.fruitGroup   = getXMLString(xmlFile, autoKey .. "#fruitGroup") or auto.fruitGroup
        auto.windrowGroup = getXMLString(xmlFile, autoKey .. "#windrowGroup") or auto.windrowGroup
        auto.milkGroup    = getXMLString(xmlFile, autoKey .. "#milkGroup") or auto.milkGroup
        local tiers = {}
        local t = 0
        while true do
            local tierKey = string.format("%s.priceTier(%d)", autoKey, t)
            if not hasXMLProperty(xmlFile, tierKey) then
                break
            end
            local minPrice = getXMLFloat(xmlFile, tierKey .. "#minPrice")
            local group = getXMLString(xmlFile, tierKey .. "#group")
            if minPrice ~= nil and group ~= nil then
                table.insert(tiers, { minPrice = minPrice, group = group })
            end
            t = t + 1
        end
        if #tiers > 0 then
            table.sort(tiers, function(a, b) return a.minPrice > b.minPrice end)
            auto.priceTiers = tiers
        end
    end
    self:loadSettingsFromConfig(xmlFile)
    if self.loadContractSettings ~= nil then
        self:loadContractSettings(xmlFile)
    end
    delete(xmlFile)

    log("Konfiguration gelesen (%s): %d Gruppen, %d Waren zugeordnet, Rest %d l / %d %% je Monat",
        path, groupCount, fillTypeCount, config.default.max, math.floor(config.default.refillPerMonth * 100 + 0.5))
    if #unknown > 0 then
        log("Konfiguration: auf dieser Karte unbekannte Waren übersprungen: %s", table.concat(unknown, ", "))
    end

    if config.auto.enabled then
        local ok, err = pcall(self.assignAutoGroups, self)
        if not ok then
            print("[LivingMarket] FEHLER bei der automatischen Gruppenzuordnung: " .. tostring(err))
        end
    end
end

-- Gruppe für eine Ware vorschlagen, die nicht in der Konfiguration steht
function LivingMarket:getAutoGroupName(fillType)
    local auto = self.config.auto
    local name = fillType.name or ""
    local index = fillType.index

    if self:getConsumables()[index] then
        return nil   -- Betriebsmittel: Standardwerte
    end
    -- Schwad/Halmgut (Gras, Heu, Luzerne ...)
    if string.find(name, "WINDROW", 1, true) ~= nil
        or (g_fillTypeManager.getIsFillTypeInCategory ~= nil and g_fillTypeManager:getIsFillTypeInCategory(index, "FORAGEWAGON")) then
        return auto.windrowGroup
    end
    -- Milch, lose (abgefüllte Milch auf Paletten läuft über den Preis)
    if string.find(name, "MILK", 1, true) ~= nil and fillType.palletFilename == nil then
        return auto.milkGroup
    end
    -- Feldfrucht: Erntegut einer Fruchtart
    if g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByFillTypeIndex ~= nil
        and g_fruitTypeManager:getFruitTypeByFillTypeIndex(index) ~= nil then
        return auto.fruitGroup
    end
    -- Paletten-/Stückware: je teurer, desto kleiner der Bedarf
    if fillType.palletFilename ~= nil then
        local price = self:getBasePricePer1000(index)
        if price ~= nil then
            for _, tier in ipairs(auto.priceTiers) do
                if price >= tier.minPrice then
                    return tier.group
                end
            end
        end
    end
    return nil   -- sonstiges Schüttgut / Flüssigkeit: Standardwerte
end

function LivingMarket:assignAutoGroups()
    local config = self.config
    local fillTypes = g_fillTypeManager.getFillTypes ~= nil and g_fillTypeManager:getFillTypes() or g_fillTypeManager.fillTypes
    local byGroup = {}
    local count = 0
    for _, fillType in pairs(fillTypes or {}) do
        local index = fillType.index
        if index ~= nil and config.byFillType[index] == nil and not self:isExcludedFillType(index) then
            local groupName = self:getAutoGroupName(fillType)
            local group = groupName ~= nil and config.groupsByName[groupName] or nil
            if group ~= nil then
                config.byFillType[index] = group
                byGroup[groupName] = byGroup[groupName] or {}
                table.insert(byGroup[groupName], fillType.name)
                count = count + 1
            end
        end
    end
    log("Automatisch zugeordnet: %d Waren", count)
    for groupName, names in pairs(byGroup) do
        table.sort(names)
        log("  automatisch %s: %s", groupName, table.concat(names, ", "))
    end
end

-- ---------------------------------------------------------------------
-- Gruppenfilter: Bedarfsgruppe einer Ware und Liste der Gruppen (Reihenfolge der Konfiguration,
-- zuletzt "Sonstige" = Waren mit Standardwerten)
-- ---------------------------------------------------------------------
LivingMarket.GROUP_OTHER = "default"

function LivingMarket:getGroupNameOf(fillTypeIndex)
    local config = self.config
    local group = config ~= nil and config.byFillType[fillTypeIndex] or nil
    return group ~= nil and group.name or self.GROUP_OTHER
end

function LivingMarket:getFilterGroups()
    local list = {}
    local config = self.config
    for _, group in ipairs(config ~= nil and config.groupOrder or {}) do
        table.insert(list, { name = group.name, title = group.title })
    end
    table.insert(list, { name = self.GROUP_OTHER })
    return list
end

-- Anzeigename einer Gruppe: eingebaute Gruppen übersetzt, eigene mit ihrem title
function LivingMarket:getGroupLabel(group)
    local key = "livingMarket_grp_" .. tostring(group.name)
    if g_i18n ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return group.title or group.name
end

-- Maximum (Liter) und Auffüllung (Liter je Spielmonat) für eine Ware
function LivingMarket:getLimitFor(station, fillTypeIndex)
    if self.config == nil then
        local ok, err = pcall(self.loadConfig, self)
        if not ok then
            print("[LivingMarket] FEHLER beim Lesen der Konfiguration: " .. tostring(err))
            self.config = self.config or { default = { max = self.FALLBACK_MAX, refillPerMonth = self.FALLBACK_REFILL }, byFillType = {} }
        end
    end
    local values = self.config.byFillType[fillTypeIndex] or self.config.default
    -- Platz für spätere Logik: Stationstyp, Ereignisse ...
    return values.max, values.max * values.refillPerMonth
end

-- Spielstunden je Monat (Tage je Monat aus den Spieleinstellungen × 24)
function LivingMarket.getHoursPerMonth()
    local mission = g_currentMission
    local days = nil
    if mission ~= nil and mission.environment ~= nil then
        days = mission.environment.daysPerPeriod
    end
    if (days == nil or days <= 0) and mission ~= nil and mission.missionInfo ~= nil then
        days = mission.missionInfo.plannedDaysPerPeriod
    end
    if days == nil or days <= 0 then
        days = 1
    end
    return days * 24
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
        local baseMax, baseRefill = self:getLimitFor(station, fillTypeIndex)
        entry = {
            baseMax    = baseMax,       -- aus der Konfiguration
            baseRefill = baseRefill,    -- Liter je Spielmonat
            noise      = self:rollNoise(),   -- kleine Schwankung des Bedarfs (±10 %), neu zu jedem Monat
            refillNoise = self:rollRefillNoise(),   -- Schwankung der Auffüllung (±25 %), neu zu jedem Monat
            eventPrice = 1,             -- Preisfaktor durch Marktereignisse
            eventMax   = 1,             -- Bedarfsfaktor durch Marktereignisse
            eventRefill = 1,            -- Auffüllfaktor durch Marktereignisse
            eventType  = 0,             -- 0 kein Ereignis, sonst LivingMarket.EVENT_*
        }
        -- Stand aus dem Spielstand übernehmen (falls vorhanden): Schwankung, Restbedarf
        local saved = self:takeSavedEntry(station, fillTypeIndex)
        if saved ~= nil and saved.noise ~= nil and saved.noise > 0 then
            entry.noise = saved.noise
        end
        if saved ~= nil and saved.refillNoise ~= nil and saved.refillNoise > 0 then
            entry.refillNoise = saved.refillNoise
        end
        self:applyEventsToEntry(station, fillTypeIndex, entry)
        self:recalcEntryLimits(entry, false)
        entry.remaining = entry.max
        if saved ~= nil and saved.remaining ~= nil then
            local remaining = saved.remaining
            if saved.baseMax == nil then
                -- Spielstand vor 0.2.1.29 (ohne gespeicherten Grundwert): einmalig voll
                remaining = entry.max
            elseif saved.baseMax > 0 and math.abs(saved.baseMax - (entry.baseMax or 0)) > 0.5 then
                -- Grundwert in der Konfiguration geändert: freie Menge anteilig umrechnen
                remaining = remaining * (entry.baseMax or 0) / saved.baseMax
            end
            entry.remaining = math.max(0, math.min(remaining, entry.max))
        end
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
-- ---------------------------------------------------------------------
-- Preis abhängig vom freien Bedarf
-- Ab PRICE_FULL_SHARE frei: Normalpreis. Darunter fällt der Preis immer schneller
-- (quadratisch) bis auf PRICE_MIN_FACTOR bei PRICE_MIN_SHARE frei und weniger.
-- ---------------------------------------------------------------------
LivingMarket.PRICE_FULL_SHARE = 0.50   -- ab 50 % freiem Bedarf voller Preis
LivingMarket.PRICE_MIN_SHARE  = 0.10   -- ab 10 % und weniger der Tiefstpreis
LivingMarket.PRICE_MIN_FACTOR = 0.50   -- Tiefstpreis = 50 % des Normalpreises
LivingMarket.PRICE_CURVE      = 2      -- 1 = gleichmäßig, 2 = erst langsam, dann immer schneller

function LivingMarket:getFactorForShare(share)
    if share >= self.PRICE_FULL_SHARE then
        return 1
    elseif share <= self.PRICE_MIN_SHARE then
        return self.PRICE_MIN_FACTOR
    end
    local t = (self.PRICE_FULL_SHARE - share) / (self.PRICE_FULL_SHARE - self.PRICE_MIN_SHARE)
    return 1 - (1 - self.PRICE_MIN_FACTOR) * t ^ self.PRICE_CURVE
end

-- Faktor auf den Spielpreis für diese Station und Ware (1 = unverändert)
function LivingMarket:getPriceFactor(station, fillTypeIndex)
    local entry = self:getEntry(station, fillTypeIndex)
    if entry == nil or entry.max <= 0 then
        return 1
    end
    return self:getFactorForShare(entry.remaining / entry.max) * (entry.eventPrice or 1)
end

-- Nur der Malus durch Massenverkauf (Marktlage), ohne Ereignis
function LivingMarket:getDemandFactor(station, fillTypeIndex)
    local entry = self:getEntry(station, fillTypeIndex)
    if entry == nil or entry.max <= 0 then
        return 1
    end
    return self:getFactorForShare(entry.remaining / entry.max)
end

-- Erlös für eine Menge schätzen: der Preis sinkt während des Abladens mit,
-- deshalb in Schritten rechnen statt Menge × aktueller Preis
function LivingMarket:estimateRevenue(basePricePerLiter, remaining, max, amount)
    if amount <= 0 or max <= 0 then
        return 0
    end
    local steps = 40
    local stepAmount = amount / steps
    local revenue = 0
    for i = 1, steps do
        local level = remaining - (i - 0.5) * stepAmount
        revenue = revenue + stepAmount * basePricePerLiter * self:getFactorForShare(math.max(level, 0) / max)
    end
    return revenue
end

-- Grundpreis der Ware aus dem Basisspiel (je 1000 l), unabhängig von Station, Monat und Marktlage.
-- Grundwert der Ware × Faktor des Schwierigkeitsgrads (Schwer 1,0 / Normal 1,8 / Einfach 3,0).
-- Ausnahme Verbrauchsgüter (Diesel, Dünger, Saatgut ...): immer Faktor 1,0.
LivingMarket.PRICE_DEBUG_FILLTYPES = { "DIESEL", "FERTILIZER", "WHEAT", "FABRIC", "WOODBEAM" }

local function getRawPriceValues(fillTypeIndex)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    local raw = fillType ~= nil and fillType.pricePerLiter or nil
    local multiplier, managerPrice = nil, nil
    if EconomyManager ~= nil and EconomyManager.getPriceMultiplier ~= nil then
        local ok, value = pcall(EconomyManager.getPriceMultiplier, fillTypeIndex)
        multiplier = ok and value or nil
    end
    local economyManager = g_currentMission ~= nil and g_currentMission.economyManager or nil
    if economyManager ~= nil and economyManager.getPricePerLiter ~= nil then
        local ok, value = pcall(economyManager.getPricePerLiter, economyManager, fillTypeIndex)
        managerPrice = ok and value or nil
    end
    return raw, multiplier, managerPrice
end

function LivingMarket:logPriceDebug()
    if not self.DEBUG or self.hasLoggedPriceDebug then
        return
    end
    self.hasLoggedPriceDebug = true   -- vor dem Rest setzen: getYearPrices ruft wieder getBasePricePer1000
    for _, name in ipairs(self.PRICE_DEBUG_FILLTYPES) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(name)
        if fillTypeIndex ~= nil then
            local raw, multiplier, managerPrice = getRawPriceValues(fillTypeIndex)
            log("Preisdaten %s: Grundwert/l=%s Faktor=%s economyManager/l=%s", name,
                tostring(raw), tostring(multiplier), tostring(managerPrice))
            -- Aufbau der Wirtschaftsdaten der Ware (Monatsfaktoren / Preisverlauf?)
            local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
            local economy = fillType ~= nil and fillType.economy or nil
            if type(economy) == "table" then
                local parts = {}
                for key, value in pairs(economy) do
                    if type(value) == "table" then
                        local values = {}
                        for i = 1, 12 do
                            if value[i] ~= nil then
                                table.insert(values, type(value[i]) == "number" and string.format("%.3f", value[i]) or type(value[i]))
                            end
                        end
                        local count = 0
                        for _ in pairs(value) do count = count + 1 end
                        table.insert(parts, string.format("%s={%d Einträge: %s}", tostring(key), count, table.concat(values, " ")))
                    else
                        table.insert(parts, string.format("%s=%s", tostring(key), tostring(value)))
                    end
                end
                table.sort(parts)
                log("Wirtschaft %s: %s", name, table.concat(parts, " | "))
            else
                log("Wirtschaft %s: keine economy-Tabelle", name)
            end
            local result = self:getYearPrices(fillTypeIndex)
            if result ~= nil and result.text ~= nil then
                log("Jahrespreise %s (je 1000 l): %s", name, table.concat(result.text, " "))
            end
        end
    end
end

-- Verbrauchsgüter: Grundpreis ohne Faktor des Schwierigkeitsgrads (immer 1,0).
-- Nur feste Liste: Eine automatische Erkennung über Kaufstationen erwischt auf Karten
-- mit Einkaufsstellen auch normale Waren (Holzbalken, Mist ...), die den Faktor haben.
LivingMarket.CONSUMABLE_FILLTYPES = {
    "DIESEL", "DEF", "METHANE",   -- ELECTRICCHARGE (Elektrische Energie) bekommt den Schwierigkeitsfaktor wie andere Waren
    "FERTILIZER", "LIQUIDFERTILIZER", "SEEDS", "HERBICIDE", "LIME", "LIQUIDLIME",
    "MINERAL_FEED", "SILAGE_ADDITIVE", "ROADSALT", "TREESAPLINGS"
}

function LivingMarket:getConsumables()
    if self.consumables ~= nil then
        return self.consumables
    end
    local consumables = {}
    for _, name in ipairs(self.CONSUMABLE_FILLTYPES) do
        local fillTypeIndex = g_fillTypeManager:getFillTypeIndexByName(name)
        if fillTypeIndex ~= nil then
            consumables[fillTypeIndex] = true
        end
    end
    self.consumables = consumables
    return consumables
end

-- Preis je Monat (1-12) aus den Monatsfaktoren der Ware, falls das Spiel sie bereitstellt.
-- Ergebnis: { prices = {[monat] = Preis je 1000 l}, max, maxMonth, min, minMonth, text = {...} }
-- Zwischenspeicher je Ware: neu berechnet nur, wenn sich Grundpreis (z. B. Schwierigkeit) oder Kurve ändern
LivingMarket.yearPriceCache = {}

function LivingMarket:getYearPrices(fillTypeIndex)
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    local economy = fillType ~= nil and fillType.economy or nil
    local factors = economy ~= nil and economy.factors or nil
    local base = self:getBasePricePer1000(fillTypeIndex)
    if type(factors) ~= "table" or base == nil then
        return nil
    end
    local cached = self.yearPriceCache[fillTypeIndex]
    if cached ~= nil and cached.base == base and cached.factors == factors then
        return cached.result
    end
    local result = self:computeYearPrices(factors, base)
    self.yearPriceCache[fillTypeIndex] = { base = base, factors = factors, result = result }
    return result
end

function LivingMarket:computeYearPrices(factors, base)
    local result = { prices = {}, text = self.DEBUG and {} or nil }
    for month = 1, 12 do
        local factor = factors[month]
        if type(factor) == "number" then
            local price = base * factor
            result.prices[month] = price
            if result.text ~= nil then
                table.insert(result.text, string.format("%d:%.0f", month, price))
            end
            if result.max == nil or price > result.max then
                result.max, result.maxMonth = price, month
            end
            if result.min == nil or price < result.min then
                result.min, result.minMonth = price, month
            end
        end
    end
    if result.max == nil then
        return nil
    end
    return result
end

-- Aktueller Monat der Preiskurve (1 = erster Monat im Preismenü)
function LivingMarket.getCurrentMonth()
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    return environment ~= nil and environment.currentPeriod or nil
end

-- Monatsname zum Monat der Preiskurve (1 = erster Monat im Preismenü, meist März)
function LivingMarket.getMonthName(month)
    if g_i18n ~= nil and g_i18n.formatPeriod ~= nil then
        local ok, name = pcall(g_i18n.formatPeriod, g_i18n, month, true)
        if ok and name ~= nil and name ~= "" then
            return name
        end
    end
    return tostring(month)
end

function LivingMarket:getBasePricePer1000(fillTypeIndex)
    self:logPriceDebug()
    local fillType = g_fillTypeManager:getFillTypeByIndex(fillTypeIndex)
    if fillType == nil or fillType.pricePerLiter == nil then
        return nil
    end
    local multiplier = 1
    if not self:getConsumables()[fillTypeIndex] and EconomyManager ~= nil and EconomyManager.getPriceMultiplier ~= nil then
        local ok, value = pcall(EconomyManager.getPriceMultiplier, fillTypeIndex)
        if ok and value ~= nil then
            multiplier = value
        end
    end
    return fillType.pricePerLiter * multiplier * 1000
end

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
                            basePrice     = self:getBasePricePer1000(fillTypeIndex),
                            year          = self:getYearPrices(fillTypeIndex),     -- Höchstpreis und bester Monat
                            stations      = {}
                        }
                        byFillType[fillTypeIndex] = ware
                        table.insert(wares, ware)
                    end
                    local price  = self:getPricePer1000(station, fillTypeIndex)   -- enthält Marktlage und Ereignis
                    local factor = self:getPriceFactor(station, fillTypeIndex)     -- gesamt
                    table.insert(ware.stations, {
                        name      = stationName,
                        searchKey = LivingMarket.toLower(stationName),
                        price     = price,
                        factor    = self:getDemandFactor(station, fillTypeIndex),  -- Marktlage (Massenverkauf)
                        eventPrice = entry.eventPrice or 1,
                        eventRefill = entry.eventRefill or 1,
                        eventMax   = entry.eventMax or 1,
                        eventType  = entry.eventType or 0,
                        basePrice = factor > 0 and price / factor or price,      -- Spielpreis ohne Marktlage und Ereignis
                        deviation = (ware.basePrice ~= nil and ware.basePrice > 0) and price / ware.basePrice or nil,   -- Preis / Grundpreis
                        remaining = entry.remaining,
                        max       = entry.max,
                        share     = entry.max > 0 and entry.remaining / entry.max or 0,
                        stars     = self.getStationStars ~= nil and self:getStationStars(self:getFarmId(), station) or 3,   -- Ansehen des eigenen Hofs
                        reputation = self.getStationReputation ~= nil and self:getStationReputation(self:getFarmId(), station) or 50,
                    })
                    if self.getStationContractInfo ~= nil then
                        local row = ware.stations[#ware.stations]
                        row.contractState, row.contractPrice = self:getStationContractInfo(self:getFarmId(), station, fillTypeIndex)
                    end
                end
            end
        end
    end

    -- Marktpreis des aktuellen Monats (Grundpreis × Monatsfaktor) für Markt und Preis-Pfeil
    local currentMonth = LivingMarket.getCurrentMonth()
    for _, ware in ipairs(wares) do
        ware.marketPrice = ware.basePrice
        if ware.year ~= nil and currentMonth ~= nil and ware.year.prices[currentMonth] ~= nil then
            ware.marketPrice = ware.year.prices[currentMonth]
        end
        for _, station in ipairs(ware.stations) do
            station.deviation = (ware.marketPrice ~= nil and ware.marketPrice > 0) and station.price / ware.marketPrice or nil
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
            ware.revenue  = self:estimateRevenue(ware.best.basePrice * ware.best.eventPrice / 1000, ware.best.remaining, ware.best.max, ware.sellable)
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

-- Wird beim Sammeln der Lagerorte gesetzt: function(fillTypeIndex, menge, name, gebäude)
local locationCollector = nil

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

-- onlyFillTypes (optional): nur diese Füllarten zählen, z. B. die Erzeugnisse einer Produktion
-- skipFillTypes (optional): diese Füllarten nicht zählen, z. B. Einstreu-Stroh im Stall
local function addStorage(stock, storage, farmId, visited, sources, kind, onlyFillTypes, owner, skipFillTypes)
    if storage == nil or visited[storage] or getOwner(storage) ~= farmId then
        return
    end
    visited[storage] = true
    local displayName = describe(owner or storage, "?")
    local name = kind .. " '" .. displayName .. "'"
    for fillTypeIndex, level in pairs(storage.fillLevels or {}) do
        if (onlyFillTypes == nil or onlyFillTypes[fillTypeIndex]) and (skipFillTypes == nil or not skipFillTypes[fillTypeIndex]) then
            if locationCollector ~= nil and level ~= nil and level > 0 then
                locationCollector(fillTypeIndex, level, displayName, owner)
            end
            addStock(stock, fillTypeIndex, level, sources, name)
        end
    end
end

-- Erzeugnisse (Ausgangswaren) einer Produktion; Zutaten zählen nicht als Lagerware
local function getProductionOutputs(productionPoint)
    local outputs = {}
    if productionPoint.outputFillTypeIds ~= nil then
        for fillTypeIndex, isOutput in pairs(productionPoint.outputFillTypeIds) do
            if isOutput then
                outputs[fillTypeIndex] = true
            end
        end
    end
    for _, production in pairs(productionPoint.productions or {}) do
        for _, output in pairs(production.outputs or {}) do
            local fillTypeIndex = output.type or output.fillTypeIndex or output.fillType
            if type(fillTypeIndex) == "number" then
                outputs[fillTypeIndex] = true
            end
        end
    end
    return outputs
end

-- Fahrzeuge: nur Paletten sind Lagerware. Anhänger zählen nicht (Ladung kann
-- Auftragsware oder geliehen sein), Sämaschinen, Streuer usw. auch nicht.
local function isStockVehicle(vehicle)
    return vehicle.isPallet == true or vehicle.spec_pallet ~= nil
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

    -- Lager der Produktionen vorab markieren: die werden in Schritt 2 gezählt,
    -- und zwar nur mit ihren Erzeugnissen
    local productionStorages = {}
    local manager = mission.productionChainManager
    if manager ~= nil and manager.productionPoints ~= nil then
        for _, productionPoint in pairs(manager.productionPoints) do
            if productionPoint.storage ~= nil then
                productionStorages[productionPoint.storage] = true
            end
        end
    end

    -- Lager den Gebäuden zuordnen (wie im FieldManager): Tierställe und Silos der Gebäude.
    -- Im Stall liegt Stroh als Einstreu - das ist kein Verkaufsbestand.
    local husbandryStorages = {}
    local storageOwners = {}
    local placeables = (mission.placeableSystem ~= nil and mission.placeableSystem.placeables) or {}
    for _, placeable in pairs(placeables) do
        local husbandry = placeable.spec_husbandry
        if husbandry ~= nil and husbandry.storage ~= nil then
            husbandryStorages[husbandry.storage] = true
            storageOwners[husbandry.storage] = placeable
        end
        local silo = placeable.spec_silo
        if silo ~= nil then
            for _, storage in pairs(silo.storages or {}) do
                storageOwners[storage] = placeable
            end
        end
    end
    local strawIndex = g_fillTypeManager:getFillTypeIndexByName("STRAW")
    local skipInStable = strawIndex ~= nil and { [strawIndex] = true } or nil

    local function addPlainStorage(storage)
        if type(storage) ~= "table" or productionStorages[storage] then
            return
        end
        if husbandryStorages[storage] then
            addStorage(stock, storage, farmId, visited, sources, "Stall", nil, storageOwners[storage], skipInStable)
        else
            addStorage(stock, storage, farmId, visited, sources, "Lager", nil, storageOwners[storage])
        end
    end

    -- 1) Silos und Lager (auch Tierställe), wie sie das Storage-System kennt
    local storageSystem = mission.storageSystem
    if storageSystem ~= nil and storageSystem.storages ~= nil then
        for key, value in pairs(storageSystem.storages) do
            local storage = (type(key) == "table" and key.fillLevels ~= nil) and key or value
            addPlainStorage(storage)
        end
    end
    -- 1b) Silos der Gebäude, falls das Storage-System sie nicht führt
    for storage in pairs(storageOwners) do
        addPlainStorage(storage)
    end

    -- 2) Lager der Produktionen: nur die Erzeugnisse, keine Zutaten
    if manager ~= nil and manager.productionPoints ~= nil then
        for _, productionPoint in pairs(manager.productionPoints) do
            if getOwner(productionPoint) == farmId then
                addStorage(stock, productionPoint.storage, farmId, visited, sources, "Produktion",
                    getProductionOutputs(productionPoint), productionPoint)
            end
        end
    end

    -- 3) Paletten (Füllstände ihrer Fülleinheiten)
    local vehicles = (mission.vehicleSystem ~= nil and mission.vehicleSystem.vehicles) or mission.vehicles
    for _, vehicle in pairs(vehicles or {}) do
        local spec = vehicle.spec_fillUnit
        if spec ~= nil and spec.fillUnits ~= nil and isStockVehicle(vehicle) and getOwner(vehicle) == farmId then
            -- Betriebsstoffe (Diesel, AdBlue, Strom, Methan im Tank) zählen nicht als Ware
            local consumers = vehicle.spec_motorized ~= nil and vehicle.spec_motorized.consumersByFillType or nil
            for _, fillUnit in ipairs(spec.fillUnits) do
                local isConsumable = consumers ~= nil and fillUnit.fillType ~= nil and consumers[fillUnit.fillType] ~= nil
                if not isConsumable then
                    if locationCollector ~= nil and fillUnit.fillLevel ~= nil and fillUnit.fillLevel > 0 then
                        locationCollector(fillUnit.fillType, fillUnit.fillLevel, nil, vehicle)   -- Name: "Paletten"
                    end
                    addStock(stock, fillUnit.fillType, fillUnit.fillLevel, sources, "Palette '" .. describe(vehicle, "?") .. "'")
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

-- Kartenmarkierung eines Gebäudes/einer Produktion/einer Palette (falls vorhanden)
local function findHotspot(object)
    if object == nil then
        return nil
    end
    if object.mapHotspot ~= nil then
        return object.mapHotspot
    end
    for _, candidate in ipairs({ object, object.owningPlaceable }) do
        local spec = candidate ~= nil and candidate.spec_hotspots or nil
        for _, hotspot in ipairs(spec ~= nil and spec.mapHotspots or {}) do
            if hotspot.worldX ~= nil and hotspot.worldZ ~= nil then
                return hotspot
            end
        end
    end
    return nil
end

-- Alle Lagerorte einer Ware (gleiche Regeln wie der Lagerbestand), größte zuerst.
-- Ergebnis: { { name, level, hotspot }, ... }; lose Paletten als eine Zeile "Paletten"
function LivingMarket:getStockLocations(fillTypeIndex)
    local byKey, list = {}, {}
    local palletsLabel = g_i18n:getText("livingMarket_locPallets")
    locationCollector = function(ft, level, name, owner)
        if ft ~= fillTypeIndex then
            return
        end
        local isPallet = name == nil
        local key = isPallet and "pallets" or tostring(owner or name)
        local row = byKey[key]
        if row == nil then
            row = { name = isPallet and palletsLabel or name, level = 0, hotspot = (not isPallet) and findHotspot(owner) or nil }
            byKey[key] = row
            table.insert(list, row)
        end
        row.level = row.level + level
    end
    local ok, err = pcall(self.getFarmStock, self)
    locationCollector = nil
    if not ok then
        print("[LivingMarket] FEHLER beim Ermitteln der Lagerorte: " .. tostring(err))
    end
    table.sort(list, function(a, b) return a.level > b.level end)
    return list
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
    local contractRest = LivingMarket.getContractCapacity ~= nil and LivingMarket:getContractCapacity(station, fillTypeIndex) or 0
    return math.min(capacity or math.huge, math.max(entry.remaining, 0) + contractRest)
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

    -- Liefervertrag dieses Hofs: zuerst die Vertragsmenge zum Festpreis (zählt nicht gegen die Liefermenge)
    local contractMoved = 0
    local contract = LivingMarket.getActiveContractFor ~= nil and LivingMarket:getActiveContractFor(station, farmId, fillTypeIndex) or nil
    if contract ~= nil then
        contractMoved = LivingMarket:deliverToContract(contract, station, superFunc, farmId, deltaFillLevel, fillTypeIndex, ...)
        deltaFillLevel = deltaFillLevel - contractMoved
        if deltaFillLevel <= 0.0001 then
            return contractMoved
        end
    end

    local allowed = math.min(deltaFillLevel, math.max(entry.remaining, 0))
    if allowed <= 0 then
        return contractMoved
    end

    -- Verkaufsprotokoll (DEBUG): Preis vor dem Abladen und tatsächlich gutgeschriebenes Geld
    local farm = (LivingMarket.DEBUG and g_farmManager ~= nil) and g_farmManager:getFarmById(farmId) or nil
    local moneyBefore = farm ~= nil and farm.money or nil
    local priceBefore = LivingMarket:getPricePer1000(station, fillTypeIndex)

    local moved = superFunc(station, farmId, allowed, fillTypeIndex, ...)
    local used = moved or allowed
    if not LivingMarket.hasSellHook and LivingMarket.recordSale ~= nil then
        LivingMarket:recordSale(station, farmId, fillTypeIndex, used, used * priceBefore / 1000)
    end

    if moneyBefore ~= nil then
        LivingMarket:trackSale(station, fillTypeIndex, used, farm.money - moneyBefore, priceBefore)
    end
    entry.remaining = math.max(entry.remaining - used, 0)
    LivingMarket:markDirty(entry)
    -- Hinweise beim Abladen (Kurzmeldung danach, Warnung bei voller Station)
    if LivingMarket.trackUnload ~= nil then
        local ok, err = pcall(LivingMarket.trackUnload, LivingMarket, station, farmId, fillTypeIndex, used, priceBefore, entry)
        if not ok then
            print("[LivingMarket] FEHLER bei den Abladehinweisen: " .. tostring(err))
        end
    end
    if entry.remaining < 1 and LivingMarket.onStationSoldOut ~= nil then
        LivingMarket:onStationSoldOut(station, fillTypeIndex)
    end
    if contractMoved > 0 then
        return contractMoved + (moved or used)
    end
    return moved
end

-- Preis: Spielpreis × Marktfaktor. Gilt für den Verkaufserlös und jede Preisanzeige.
function LivingMarket.getEffectiveFillTypePrice(station, superFunc, fillTypeIndex, ...)
    local override = LivingMarket.contractOverride
    if override ~= nil and override.station == station and override.fillTypeIndex == fillTypeIndex then
        return override.pricePerLiter   -- Vertragslieferung: Festpreis
    end
    local price = superFunc(station, fillTypeIndex, ...)
    if price == nil or fillTypeIndex == nil then
        return price
    end
    return price * LivingMarket:getPriceFactor(station, fillTypeIndex)
end

-- Verkäufe sammeln und nach kurzer Pause zusammengefasst ins Log schreiben
LivingMarket.saleLog = {}

function LivingMarket:trackSale(station, fillTypeIndex, liters, money, pricePer1000)
    local key = tostring(station) .. "/" .. tostring(fillTypeIndex)
    local sale = self.saleLog[key]
    if sale == nil then
        sale = { station = station, fillTypeIndex = fillTypeIndex, liters = 0, money = 0,
                 firstPrice = pricePer1000, entry = self:getEntry(station, fillTypeIndex) }
        sale.startShare = sale.entry ~= nil and sale.entry.max > 0 and (sale.entry.remaining + liters) / sale.entry.max or nil
        self.saleLog[key] = sale
    end
    sale.liters = sale.liters + liters
    sale.money = sale.money + money
    sale.lastPrice = pricePer1000
    sale.idle = 0
end

function LivingMarket:flushSaleLog(dt)
    for key, sale in pairs(self.saleLog) do
        sale.idle = (sale.idle or 0) + dt
        if sale.idle > 5000 then   -- 5 s keine Lieferung mehr: Abladen beendet
            local priceAfter = self:getPricePer1000(sale.station, sale.fillTypeIndex)
            local paid = sale.liters > 0 and sale.money / sale.liters * 1000 or 0
            local shareAfter = sale.entry ~= nil and sale.entry.max > 0 and sale.entry.remaining / sale.entry.max or nil
            log("Verkauf '%s' %s: %.0f l, Geld %+.0f, bezahlt %.1f je 1000 l | Preis beim ersten Liter %.1f, beim letzten %.1f, jetzt %.1f | frei %s -> %s",
                getStationName(sale.station), tostring(g_fillTypeManager:getFillTypeNameByIndex(sale.fillTypeIndex)),
                sale.liters, sale.money, paid, sale.firstPrice or 0, sale.lastPrice or 0, priceAfter,
                sale.startShare ~= nil and string.format("%.0f %%", sale.startShare * 100) or "?",
                shareAfter ~= nil and string.format("%.0f %%", shareAfter * 100) or "?")
            self.saleLog[key] = nil
        end
    end
end

function LivingMarket.onStationDelete(station)
    LivingMarket.stations[station] = nil
    LivingMarket.stationKeys[station] = nil
    LivingMarket.stationKind[station] = nil
    LivingMarket.stationNames[station] = nil
end

if SellingStation ~= nil then
    SellingStation.getFreeCapacity      = Utils.overwrittenFunction(SellingStation.getFreeCapacity, LivingMarket.getFreeCapacity)
    SellingStation.addFillLevelFromTool = Utils.overwrittenFunction(SellingStation.addFillLevelFromTool, LivingMarket.addFillLevelFromTool)
    SellingStation.delete               = Utils.prependedFunction(SellingStation.delete, LivingMarket.onStationDelete)
    if SellingStation.getEffectiveFillTypePrice ~= nil then
        SellingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(SellingStation.getEffectiveFillTypePrice, LivingMarket.getEffectiveFillTypePrice)
    else
        print("[LivingMarket] WARNUNG: getEffectiveFillTypePrice nicht gefunden - Preise bleiben unverändert")
    end
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
    local hoursPerMonth = LivingMarket.getHoursPerMonth()   -- refill ist je Spielmonat angegeben
    for _, data in pairs(self.stations) do
        for _, entry in pairs(data) do
            if entry.remaining < entry.max then
                entry.remaining = math.min(entry.remaining + entry.refill / hoursPerMonth, entry.max)
                self:markDirty(entry)
            end
        end
    end

    -- Marktereignisse: fällige starten/beenden, gelegentlich neue (verteilt über den Monat)
    if self.tickContracts ~= nil then
        local okC, errC = pcall(self.tickContracts, self)
        if not okC then
            print("[LivingMarket] FEHLER bei den Lieferverträgen: " .. tostring(errC))
        end
    end
    local ok, err = pcall(self.tickEvents, self)
    if not ok then
        print("[LivingMarket] FEHLER bei den Marktereignissen: " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------
-- Multiplayer
-- Der Server verwaltet die Kontingente allein und schickt sie an die
-- Clients. Clients ändern nie selbst etwas, sie zeigen nur an.
-- ---------------------------------------------------------------------
LivingMarket.SYNC_INTERVAL = 1000   -- ms, geänderte Werte höchstens so oft senden
LivingMarket.SYNC_CHUNK    = 200    -- Einträge je Netzwerkpaket (große Karten: mehrere Pakete)

function LivingMarket.chunkEntries(entries)
    local chunks, current = {}, {}
    for _, e in ipairs(entries) do
        table.insert(current, e)
        if #current >= LivingMarket.SYNC_CHUNK then
            table.insert(chunks, current)
            current = {}
        end
    end
    if #current > 0 then
        table.insert(chunks, current)
    end
    return chunks
end
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
                        refill        = entry.refill,
                        eventPrice    = entry.eventPrice or 1,
                        eventRefill   = entry.eventRefill or 1,
                        eventMax      = entry.eventMax or 1,
                        eventType     = entry.eventType or 0
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
                entry.remaining  = e.remaining
                entry.max        = e.max
                entry.refill     = e.refill
                entry.eventPrice = e.eventPrice or 1
                entry.eventRefill = e.eventRefill or 1
                entry.eventMax   = e.eventMax or 1
                entry.eventType  = e.eventType or 0
            end
        end
    end
end

-- Neuer Mitspieler: kompletten Stand schicken
function LivingMarket.sendInitialClientState(mission, connection, user, farm)
    local entries = LivingMarket:collectSyncEntries(false)
    for _, chunk in ipairs(LivingMarket.chunkEntries(entries)) do
        connection:sendEvent(LivingMarketSyncEvent.new(chunk))
    end
    if LivingMarketEventListEvent ~= nil then
        connection:sendEvent(LivingMarketEventListEvent.new(LivingMarket.events))
    end
    if LivingMarket.sendSalesToConnection ~= nil then
        LivingMarket:sendSalesToConnection(connection)
    end
    if LivingMarketContractListEvent ~= nil then
        connection:sendEvent(LivingMarketContractListEvent.new())
    end
    if LivingMarketSettingsEvent ~= nil then
        connection:sendEvent(LivingMarketSettingsEvent.new(LivingMarket.maxContractsSetting or 0))
    end
    if LivingMarketFavoritesEvent ~= nil then
        LivingMarket:isFavorite(0)
        connection:sendEvent(LivingMarketFavoritesEvent.new(LivingMarket:getFavoriteNames()))
    end
end

if FSBaseMission ~= nil and FSBaseMission.sendInitialClientState ~= nil then
    FSBaseMission.sendInitialClientState = Utils.appendedFunction(FSBaseMission.sendInitialClientState, LivingMarket.sendInitialClientState)
end

function LivingMarket:update(dt)
    if not self.eventsInitialized and isServer() then
        self.eventInitTimer = (self.eventInitTimer or 10000) - dt
        if self.eventInitTimer <= 0 then
            self.eventsInitialized = true
            local ok, err = pcall(self.initEvents, self)
            if not ok then
                print("[LivingMarket] FEHLER bei den Marktereignissen: " .. tostring(err))
            end
        end
    end
    if next(self.saleLog) ~= nil then
        self:flushSaleLog(dt)
    end
    if self.updateSalesSync ~= nil then
        self:updateSalesSync(dt)
    end
    if self.updateContractsSync ~= nil then
        self:updateContractsSync(dt)
    end
    if self.updateUnloads ~= nil and isServer() then
        self:updateUnloads(dt)
    end
    self:updateMenuPlacement(dt)
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
        for _, chunk in ipairs(self.chunkEntries(entries)) do
            g_server:broadcastEvent(LivingMarketSyncEvent.new(chunk))
        end
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
    self.menuFrame = frame
    self.menuPlaceTries = 0
    log("Menüseite angelegt")
    self:placeMenuPageAfterFieldManager()
end

-- ---------------------------------------------------------------------
-- Reiter direkt hinter den Field Manager (Feld-Info-Mod, Seite "pageFieldOverview") setzen.
-- Der Field Manager baut seine Seite evtl. erst nach uns ein, deshalb in der ersten
-- Minute jede Sekunde prüfen (nur solange das Menü geschlossen ist).
-- Ohne Field Manager bleibt der Reiter hinter "Preise".
-- ---------------------------------------------------------------------
LivingMarket.FIELD_MANAGER_PAGE = "pageFieldOverview"
LivingMarket.MENU_PLACE_MAX_TRIES = 60

local function isFieldManagerFrame(frame)
    return frame ~= nil and (frame.name == LivingMarket.FIELD_MANAGER_PAGE or frame.pageName == LivingMarket.FIELD_MANAGER_PAGE)
end

function LivingMarket:placeMenuPageAfterFieldManager()
    local menu = g_inGameMenu
    local frame = self.menuFrame
    if menu == nil or frame == nil or menu.pageFrames == nil or menu.pagingElement == nil then
        return false
    end
    if menu.isOpen or (g_gui ~= nil and g_gui.currentGuiName == "InGameMenu") then
        return false   -- nicht umsortieren, während das Menü offen ist
    end
    local fmIndex = findIndex(menu.pageFrames, isFieldManagerFrame)
    local ownIndex = findIndex(menu.pageFrames, function(f) return f == frame end)
    if fmIndex == nil or ownIndex == nil then
        return false
    end
    if ownIndex == fmIndex + 1 then
        return true   -- liegt schon richtig
    end
    local fmFrame = menu.pageFrames[fmIndex]
    local function moveAfter(list, isOwn, isFm)
        if list == nil then
            return
        end
        local i = findIndex(list, isOwn)
        if i == nil then
            return
        end
        local item = table.remove(list, i)
        local j = findIndex(list, isFm)
        if j ~= nil then
            table.insert(list, j + 1, item)
        else
            table.insert(list, i, item)   -- Field Manager hier nicht gefunden: zurück an alte Stelle
        end
    end
    moveAfter(menu.pageFrames, function(f) return f == frame end, function(f) return f == fmFrame end)
    moveAfter(menu.pagingElement.elements, function(e) return e == frame end, function(e) return e == fmFrame end)
    moveAfter(menu.pagingElement.pages, function(p) return p.element == frame end, function(p) return p.element == fmFrame end)
    if menu.pagingElement.updateAbsolutePosition ~= nil then
        menu.pagingElement:updateAbsolutePosition()
    end
    if menu.pagingElement.updatePageMapping ~= nil then
        menu.pagingElement:updatePageMapping()
    end
    menu:rebuildTabList()
    log("Reiter hinter den Field Manager gesetzt")
    return true
end

function LivingMarket:updateMenuPlacement(dt)
    if self.menuFrame == nil or (self.menuPlaceTries or 0) >= self.MENU_PLACE_MAX_TRIES then
        return
    end
    self.menuPlaceTimer = (self.menuPlaceTimer or 0) - dt
    if self.menuPlaceTimer > 0 then
        return
    end
    self.menuPlaceTimer = 1000
    self.menuPlaceTries = (self.menuPlaceTries or 0) + 1
    local ok, err = pcall(self.placeMenuPageAfterFieldManager, self)
    if not ok then
        log("Reiter umsetzen fehlgeschlagen: %s", tostring(err))
        self.menuPlaceTries = self.MENU_PLACE_MAX_TRIES
    end
end

-- ---------------------------------------------------------------------
-- Favoriten: gemeinsam für alle Spieler, im Spielstand gespeichert (livingMarket.xml)
-- Im Multiplayer verwaltet der Server die Liste und schickt Änderungen an alle.
-- Alte Favoriten aus modSettings/FS25_LivingMarket.xml (bis 0.2.0.4) werden einmalig übernommen,
-- wenn der Spielstand noch keine Favoriten hat.
-- ---------------------------------------------------------------------
LivingMarket.favorites = nil   -- [fillTypeName] = true

function LivingMarket:getSettingsPath()
    local dir = g_modSettingsDirectory
    if dir == nil and getUserProfileAppPath ~= nil then
        dir = getUserProfileAppPath() .. "modSettings/"
    end
    if dir == nil then
        return nil
    end
    if string.sub(dir, -1) ~= "/" then
        dir = dir .. "/"
    end
    return dir .. "FS25_LivingMarket.xml"
end

local function readFillTypeNames(xmlFile, baseKey)
    local names = {}
    local i = 0
    while true do
        local key = string.format("%s.fillType(%d)", baseKey, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local name = getXMLString(xmlFile, key .. "#name")
        if name ~= nil and name ~= "" then
            names[name] = true
        end
        i = i + 1
    end
    return names
end
LivingMarket.readFillTypeNames = readFillTypeNames

local function writeFillTypeNames(xmlFile, baseKey, set)
    local names = {}
    for name in pairs(set or {}) do
        table.insert(names, name)
    end
    table.sort(names)
    for i, name in ipairs(names) do
        setXMLString(xmlFile, string.format("%s.fillType(%d)#name", baseKey, i - 1), name)
    end
end
LivingMarket.writeFillTypeNames = writeFillTypeNames

-- Spielstand ohne Favoriten: alte lokale Favoriten übernehmen (nur Einzelspieler/Server)
function LivingMarket:initFavorites()
    self.favorites = {}
    if not isServer() then
        return   -- Mitspieler bekommen die Liste vom Server
    end
    local path = self:getSettingsPath()
    if path == nil or not fileExists(path) then
        return
    end
    local xmlFile = loadXMLFile("LivingMarketSettings", path)
    if xmlFile == nil or xmlFile == 0 then
        return
    end
    -- globale Liste (bis 0.2.0.3)
    if hasXMLProperty(xmlFile, "livingMarket.favorites") then
        for name in pairs(readFillTypeNames(xmlFile, "livingMarket.favorites")) do
            self.favorites[name] = true
        end
    end
    delete(xmlFile)
    log("Favoriten aus modSettings übernommen")
end

function LivingMarket:getFavoriteNames()
    local names = {}
    for name in pairs(self.favorites or {}) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

-- Liste vom Server bzw. von einem Mitspieler übernehmen
function LivingMarket:setFavoriteNames(names)
    self.favorites = {}
    for _, name in ipairs(names or {}) do
        self.favorites[name] = true
    end
    self.favoritesVersion = (self.favoritesVersion or 0) + 1
end

function LivingMarket:isFavorite(fillTypeIndex)
    if self.favorites == nil then
        local ok, err = pcall(self.initFavorites, self)
        if not ok then
            print("[LivingMarket] FEHLER beim Laden der Favoriten: " .. tostring(err))
        end
        self.favorites = self.favorites or {}
    end
    local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    return name ~= nil and self.favorites[name] == true
end

function LivingMarket:toggleFavorite(fillTypeIndex)
    local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    if name == nil then
        return
    end
    if self:isFavorite(fillTypeIndex) then
        self.favorites[name] = nil
    else
        self.favorites[name] = true
    end
    self.favoritesVersion = (self.favoritesVersion or 0) + 1
    -- Multiplayer: Server schickt an alle, Mitspieler schickt an den Server
    if isMultiplayer() and LivingMarketFavoritesEvent ~= nil then
        local event = LivingMarketFavoritesEvent.new(self:getFavoriteNames())
        if g_server ~= nil then
            g_server:broadcastEvent(event)
        elseif g_client ~= nil then
            g_client:getServerConnection():sendEvent(event)
        end
    end
end

-- ---------------------------------------------------------------------
-- Spielstand: Restbedarf speichern und laden
-- Datei: <Spielstand-Ordner>/livingMarket.xml
-- Je Eintrag: Restbedarf, Maximum, Auffüllrate. Gespeichert wird nur, was vom Standard abweicht.
-- ---------------------------------------------------------------------
LivingMarket.SAVE_FILENAME = "livingMarket.xml"
LivingMarket.SAVE_VERSION  = 4   -- 4: Schwankung je Eintrag + Marktereignisse; Maxima immer aus Konfiguration
LivingMarket.savedData     = {}   -- [stationKey] = { name = ..., fillTypes = { [fillTypeName] = { remaining, max, refill } } }

-- Dauerhafte Kennung einer Station: uniqueId ihres Gebäudes (vom Spiel im Spielstand geführt).
-- Rückfall für Stationen ohne Gebäude: Name der Station.
LivingMarket.stationKeys = {}   -- Zwischenspeicher: [station] = Kennung

function LivingMarket:getStationKey(station)
    local cached = self.stationKeys[station]
    if cached ~= nil then
        return cached
    end
    local key = nil
    local placeable = station.owningPlaceable
    if placeable ~= nil and placeable.getUniqueId ~= nil then
        local ok, uniqueId = pcall(placeable.getUniqueId, placeable)
        if ok and uniqueId ~= nil and uniqueId ~= "" then
            key = tostring(uniqueId)
        end
    end
    key = key or ("name:" .. getStationName(station))
    self.stationKeys[station] = key
    return key
end

-- Gespeicherten Eintrag abholen (und aus dem Zwischenspeicher entfernen)
function LivingMarket:takeSavedEntry(station, fillTypeIndex)
    local stationData = self.savedData[self:getStationKey(station)]
    if stationData == nil then
        return nil
    end
    local fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
    local saved = fillTypeName ~= nil and stationData.fillTypes[fillTypeName] or nil
    if saved ~= nil then
        stationData.fillTypes[fillTypeName] = nil
    end
    return saved
end

function LivingMarket:loadFromSavegame()
    self.savedData = {}
    local missionInfo = g_currentMission ~= nil and g_currentMission.missionInfo or nil
    if not isServer() or missionInfo == nil or missionInfo.savegameDirectory == nil then
        return
    end

    local path = missionInfo.savegameDirectory .. "/" .. self.SAVE_FILENAME
    if not fileExists(path) then
        log("kein gespeicherter Stand (%s) - alle Stationen starten voll", self.SAVE_FILENAME)
        return
    end

    local xmlFile = loadXMLFile("LivingMarketSave", path)
    if xmlFile == nil or xmlFile == 0 then
        log("WARNUNG: %s konnte nicht gelesen werden", path)
        return
    end

    -- Maxima/Auffüllung kommen immer aus der Konfiguration; gespeichert sind Restbedarf,
    -- Schwankung (ab Version 4) und die Marktereignisse (ab Version 4)
    local version = getXMLInt(xmlFile, "livingMarket#version") or 1

    local stationCount, entryCount = 0, 0
    local i = 0
    while true do
        local stationKey = string.format("livingMarket.stations.station(%d)", i)
        if not hasXMLProperty(xmlFile, stationKey) then
            break
        end
        local id = getXMLString(xmlFile, stationKey .. "#id")
        if id ~= nil then
            local stationData = { name = getXMLString(xmlFile, stationKey .. "#name"), fillTypes = {} }
            local j = 0
            while true do
                local fillTypeKey = string.format("%s.fillType(%d)", stationKey, j)
                if not hasXMLProperty(xmlFile, fillTypeKey) then
                    break
                end
                local name = getXMLString(xmlFile, fillTypeKey .. "#name")
                local remaining = getXMLFloat(xmlFile, fillTypeKey .. "#remaining")
                if name ~= nil and remaining ~= nil then
                    stationData.fillTypes[name] = {
                        remaining = remaining,
                        noise     = version >= 4 and getXMLFloat(xmlFile, fillTypeKey .. "#noise") or nil,
                        refillNoise = getXMLFloat(xmlFile, fillTypeKey .. "#refillNoise"),
                        baseMax   = getXMLFloat(xmlFile, fillTypeKey .. "#baseMax"),
                    }
                    entryCount = entryCount + 1
                end
                j = j + 1
            end
            self.savedData[id] = stationData
            stationCount = stationCount + 1
        end
        i = i + 1
    end
    if version >= 4 then
        self:loadEventsFromXML(xmlFile, "livingMarket.events")
    end
    -- Lieferverträge und Ansehen (ab 0.2.2)
    if self.loadContractsFromXML ~= nil then
        self:loadContractsFromXML(xmlFile, "livingMarket.contracts")
    end
    -- Verkaufsverlauf (ab 0.2.1.5)
    if self.loadSalesFromXML ~= nil then
        self:loadSalesFromXML(xmlFile, "livingMarket.sales")
    end
    -- Favoriten (gemeinsam, ab 0.2.0.5)
    if hasXMLProperty(xmlFile, "livingMarket.favorites") then
        self.favorites = readFillTypeNames(xmlFile, "livingMarket.favorites")
    end

    -- Filter und Sortierung der Menüseite
    if hasXMLProperty(xmlFile, "livingMarket.ui") then
        local function sortState(name)
            local key = getXMLString(xmlFile, "livingMarket.ui#" .. name .. "Sort")
            if key == nil then
                return nil
            end
            local asc = getXMLBool(xmlFile, "livingMarket.ui#" .. name .. "Asc")
            return { key = key, asc = asc ~= false }
        end
        self.uiState = {
            filterMode  = getXMLString(xmlFile, "livingMarket.ui#filter"),
            eventFilter = getXMLString(xmlFile, "livingMarket.ui#eventFilter"),
            contractFilter = getXMLString(xmlFile, "livingMarket.ui#contractFilter"),
            wareSort    = sortState("ware"),
            detailSort  = sortState("detail"),
            eventSort   = sortState("event"),
            saleSort    = sortState("sale"),
        }
    end
    self.uiStateVersion = (self.uiStateVersion or 0) + 1
    delete(xmlFile)
    log("Spielstand geladen: %d Stationen, %d Einträge, %d Marktereignisse", stationCount, entryCount, #self.events)
end

function LivingMarket.saveToSavegame(missionInfo)
    local self = LivingMarket
    if not isServer() or missionInfo == nil or not missionInfo.isValid or missionInfo.savegameDirectory == nil then
        return
    end

    -- Alles sammeln: aktuelle Einträge + noch nicht abgerufene Werte aus dem letzten Laden
    local toSave = {}   -- [stationKey] = { name = ..., fillTypes = { [name] = remaining } }
    for key, stationData in pairs(self.savedData) do
        toSave[key] = { name = stationData.name, fillTypes = {} }
        for name, saved in pairs(stationData.fillTypes) do
            toSave[key].fillTypes[name] = saved
        end
    end
    for station, data in pairs(self.stations) do
        local key = self:getStationKey(station)
        toSave[key] = toSave[key] or { name = getStationName(station), fillTypes = {} }
        toSave[key].name = getStationName(station)
        for fillTypeIndex, entry in pairs(data) do
            local name = g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex)
            if name ~= nil then
                -- Gespeichert wird, was vom Standard abweicht: Restbedarf unter Maximum oder eine Schwankung
                local differs = entry.remaining < entry.max or math.abs((entry.noise or 1) - 1) > 0.0005
                    or math.abs((entry.refillNoise or 1) - 1) > 0.0005
                if differs then
                    toSave[key].fillTypes[name] = { remaining = entry.remaining, noise = entry.noise, refillNoise = entry.refillNoise, baseMax = entry.baseMax }
                else
                    toSave[key].fillTypes[name] = nil   -- alles Standard, muss nicht gespeichert werden
                end
            end
        end
    end

    local path = missionInfo.savegameDirectory .. "/" .. self.SAVE_FILENAME
    local xmlFile = createXMLFile("LivingMarketSave", path, "livingMarket")
    if xmlFile == nil or xmlFile == 0 then
        log("WARNUNG: %s konnte nicht geschrieben werden", path)
        return
    end
    setXMLInt(xmlFile, "livingMarket#version", self.SAVE_VERSION)

    local i, entryCount = 0, 0
    for key, stationData in pairs(toSave) do
        local hasEntries = next(stationData.fillTypes) ~= nil
        if hasEntries then
            local stationKey = string.format("livingMarket.stations.station(%d)", i)
            setXMLString(xmlFile, stationKey .. "#id", key)
            setXMLString(xmlFile, stationKey .. "#name", stationData.name or "")
            local j = 0
            for name, saved in pairs(stationData.fillTypes) do
                local fillTypeKey = string.format("%s.fillType(%d)", stationKey, j)
                setXMLString(xmlFile, fillTypeKey .. "#name", name)
                setXMLFloat(xmlFile, fillTypeKey .. "#remaining", saved.remaining)
                if saved.noise ~= nil then
                    setXMLFloat(xmlFile, fillTypeKey .. "#noise", saved.noise)
                end
                if saved.refillNoise ~= nil then
                    setXMLFloat(xmlFile, fillTypeKey .. "#refillNoise", saved.refillNoise)
                end
                if saved.baseMax ~= nil then
                    setXMLFloat(xmlFile, fillTypeKey .. "#baseMax", saved.baseMax)   -- Grundwert aus der Konfiguration beim Speichern
                end
                j = j + 1
                entryCount = entryCount + 1
            end
            i = i + 1
        end
    end

    self:saveEventsToXML(xmlFile, "livingMarket.events")

    if self.saveSalesToXML ~= nil then
        self:saveSalesToXML(xmlFile, "livingMarket.sales")
    end
    if self.saveContractsToXML ~= nil then
        self:saveContractsToXML(xmlFile, "livingMarket.contracts")
    end

    -- Favoriten (gemeinsam für alle Spieler); Abschnitt auch bei leerer Liste, damit nichts neu übernommen wird
    self:isFavorite(0)
    setXMLBool(xmlFile, "livingMarket.favorites#saved", true)
    writeFillTypeNames(xmlFile, "livingMarket.favorites", self.favorites)

    -- Filter und Sortierung der Menüseite
    local ui = self.uiState
    if ui ~= nil then
        if ui.filterMode ~= nil then setXMLString(xmlFile, "livingMarket.ui#filter", ui.filterMode) end
        if ui.eventFilter ~= nil then setXMLString(xmlFile, "livingMarket.ui#eventFilter", ui.eventFilter) end
        if ui.contractFilter ~= nil then setXMLString(xmlFile, "livingMarket.ui#contractFilter", ui.contractFilter) end
        for _, name in ipairs({ "ware", "detail", "event", "sale" }) do
            local state = ui[name .. "Sort"]
            if state ~= nil and state.key ~= nil then
                setXMLString(xmlFile, "livingMarket.ui#" .. name .. "Sort", state.key)
                setXMLBool(xmlFile, "livingMarket.ui#" .. name .. "Asc", state.asc ~= false)
            end
        end
    end

    saveXMLFile(xmlFile)
    delete(xmlFile)
    log("Spielstand gespeichert: %d Stationen, %d Einträge, %d Marktereignisse", i, entryCount, #self.events)
end

-- Beim Speichern des Spielstands mitspeichern (wie z. B. Courseplay für LS25)
if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.prependedFunction(FSCareerMissionInfo.saveToXMLFile, function(missionInfo, ...)
        local ok, err = pcall(LivingMarket.saveToSavegame, missionInfo)
        if not ok then
            print("[LivingMarket] FEHLER beim Speichern: " .. tostring(err))
        end
    end)
end

-- ---------------------------------------------------------------------
-- Mod-Event-Listener
-- ---------------------------------------------------------------------
function LivingMarket:loadMap(name)
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
    if MessageType.PERIOD_CHANGED ~= nil then
        g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
    end
    self.events = {}
    self.eventsInitialized = false
    self.eventInitTimer = 10000   -- erste Ereignisse 10 s nach dem Laden würfeln (falls keine gespeichert)

    self.config = nil
    local okConfig, errConfig = pcall(self.loadConfig, self)
    if not okConfig then
        print("[LivingMarket] FEHLER beim Lesen der Konfiguration: " .. tostring(errConfig))
    end

    local okLoad, errLoad = pcall(self.loadFromSavegame, self)
    if not okLoad then
        print("[LivingMarket] FEHLER beim Laden des Spielstands: " .. tostring(errLoad))
    end

    local okDialog, errDialog = pcall(LivingMarketLocationDialog.register)
    if not okDialog then
        print("[LivingMarket] FEHLER beim Anlegen des Fensters Lagerorte: " .. tostring(errDialog))
    end

    local ok, err = pcall(self.addMenuPage, self)
    if not ok then
        print("[LivingMarket] FEHLER beim Anlegen der Menüseite: " .. tostring(err))
    end

    log("geladen")
end

function LivingMarket:deleteMap()
    self.favorites = nil
    if self.resetSales ~= nil then
        self:resetSales()
    end
    if self.resetContracts ~= nil then
        self:resetContracts()
    end
    g_messageCenter:unsubscribeAll(self)
    self.stations = {}
    self.savedData = {}
    self.stationKind = {}
    self.stationNames = {}
    self.stationKeys = {}
    self.excludedCache = {}
    self.categorizedFillTypes = nil
    self.loggedMissionDeliveries = {}
    self.yearPriceCache = {}
    if self.resetUnloads ~= nil then
        self:resetUnloads()
    end
    self.hasLoggedStock = false
    self.hasLoggedStations = false
    self.hasLoggedPriceDebug = false
    self.consumables = nil
    self.config = nil
    self.events = {}
    self.eventsInitialized = false
    self.uiState = nil
    self.uiStateVersion = (self.uiStateVersion or 0) + 1
    self.hasDirty = false
    self.syncTimer = 0
end

addModEventListener(LivingMarket)
