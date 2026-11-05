-- =====================================================================
-- Multiplayer: Marktereignisse und Meldungen vom Server an die Clients
--
-- LivingMarketEventListEvent : komplette Ereignisliste (für die Ansicht Marktnachrichten).
--                              Zeiten relativ zu "jetzt", jeder Rechner rechnet mit seiner Spielzeit um.
-- LivingMarketNotifyEvent    : eine Meldung als Text-Schlüssel + Werte, damit jeder Mitspieler
--                              sie in seiner eigenen Sprache sieht.
-- =====================================================================

LivingMarketEventListEvent = {}
local LivingMarketEventListEvent_mt = Class(LivingMarketEventListEvent, Event)
InitEventClass(LivingMarketEventListEvent, "LivingMarketEventListEvent")

function LivingMarketEventListEvent.emptyNew()
    return Event.new(LivingMarketEventListEvent_mt)
end

-- events: Liste der Ereignisse des Servers (LivingMarket.events)
function LivingMarketEventListEvent.new(events)
    local self = LivingMarketEventListEvent.emptyNew()
    self.events = events or {}
    return self
end

function LivingMarketEventListEvent:writeStream(streamId, connection)
    local now = LivingMarket.getNowHour()
    streamWriteUInt8(streamId, math.min(#self.events, 255))
    for i = 1, math.min(#self.events, 255) do
        local e = self.events[i]
        streamWriteUInt8(streamId, e.type or 0)
        streamWriteUIntN(streamId, e.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
        streamWriteString(streamId, e.stationKey or "")
        streamWriteString(streamId, e.stationKey ~= nil and LivingMarket:getEventStationName(e) or "")
        streamWriteFloat32(streamId, e.price or 1)
        streamWriteFloat32(streamId, e.maxFactor or 1)
        streamWriteFloat32(streamId, e.refillFactor or 1)
        streamWriteUInt8(streamId, e.months or 1)
        streamWriteInt32(streamId, math.floor((e.startHour or now) - now))
        streamWriteInt32(streamId, math.floor((e.endHour or now) - now))
        streamWriteBool(streamId, e.active == true)
    end
end

function LivingMarketEventListEvent:readStream(streamId, connection)
    local now = LivingMarket.getNowHour()
    self.events = {}
    local count = streamReadUInt8(streamId)
    for _ = 1, count do
        local e = {}
        e.type          = streamReadUInt8(streamId)
        e.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
        local stationKey = streamReadString(streamId)
        e.stationKey    = stationKey ~= "" and stationKey or nil
        local stationName = streamReadString(streamId)
        e.stationName   = stationName ~= "" and stationName or nil
        e.price         = streamReadFloat32(streamId)
        e.maxFactor     = streamReadFloat32(streamId)
        e.refillFactor  = streamReadFloat32(streamId)
        e.months        = streamReadUInt8(streamId)
        e.startHour     = now + streamReadInt32(streamId)
        e.endHour       = now + streamReadInt32(streamId)
        e.active        = streamReadBool(streamId)
        table.insert(self.events, e)
    end
    self:run(connection)
end

function LivingMarketEventListEvent:run(connection)
    if connection:getIsServer() and g_server == nil then   -- nur auf Clients übernehmen
        LivingMarket.events = self.events
    end
end

-- ---------------------------------------------------------------------

LivingMarketNotifyEvent = {}
local LivingMarketNotifyEvent_mt = Class(LivingMarketNotifyEvent, Event)
InitEventClass(LivingMarketNotifyEvent, "LivingMarketNotifyEvent")

function LivingMarketNotifyEvent.emptyNew()
    return Event.new(LivingMarketNotifyEvent_mt)
end

-- key: Text-Schlüssel; stationName ("" = marktweit); fillTypeIndex; percent; months; isWarning
function LivingMarketNotifyEvent.new(key, stationName, fillTypeIndex, percent, months, isWarning)
    local self = LivingMarketNotifyEvent.emptyNew()
    self.key, self.stationName, self.fillTypeIndex = key, stationName or "", fillTypeIndex
    self.percent, self.months, self.isWarning = percent or 0, months or 1, isWarning == true
    return self
end

function LivingMarketNotifyEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.key)
    streamWriteString(streamId, self.stationName)
    streamWriteUIntN(streamId, self.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
    streamWriteUInt8(streamId, math.min(self.percent, 255))
    streamWriteUInt8(streamId, math.min(self.months, 255))
    streamWriteBool(streamId, self.isWarning)
end

function LivingMarketNotifyEvent:readStream(streamId, connection)
    self.key           = streamReadString(streamId)
    self.stationName   = streamReadString(streamId)
    self.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
    self.percent       = streamReadUInt8(streamId)
    self.months        = streamReadUInt8(streamId)
    self.isWarning     = streamReadBool(streamId)
    self:run(connection)
end

function LivingMarketNotifyEvent:run(connection)
    if connection:getIsServer() and g_server == nil then
        LivingMarket:showNotification(self.key, self.stationName, self.fillTypeIndex, self.percent, self.months, self.isWarning)
    end
end

-- ---------------------------------------------------------------------
-- Favoriten (gemeinsam für alle): komplette Liste der Warennamen.
-- Mitspieler -> Server: Server übernimmt und schickt an alle anderen weiter.
-- Server -> Mitspieler: Mitspieler übernimmt.
-- ---------------------------------------------------------------------
LivingMarketFavoritesEvent = {}
local LivingMarketFavoritesEvent_mt = Class(LivingMarketFavoritesEvent, Event)
InitEventClass(LivingMarketFavoritesEvent, "LivingMarketFavoritesEvent")

function LivingMarketFavoritesEvent.emptyNew()
    return Event.new(LivingMarketFavoritesEvent_mt)
end

function LivingMarketFavoritesEvent.new(names)
    local self = LivingMarketFavoritesEvent.emptyNew()
    self.names = names or {}
    return self
end

function LivingMarketFavoritesEvent:writeStream(streamId, connection)
    local count = math.min(#self.names, 1000)
    streamWriteUInt16(streamId, count)
    for i = 1, count do
        streamWriteString(streamId, self.names[i])
    end
end

function LivingMarketFavoritesEvent:readStream(streamId, connection)
    self.names = {}
    local count = streamReadUInt16(streamId)
    for _ = 1, count do
        table.insert(self.names, streamReadString(streamId))
    end
    self:run(connection)
end

function LivingMarketFavoritesEvent:run(connection)
    LivingMarket:setFavoriteNames(self.names)
    if not connection:getIsServer() and g_server ~= nil then
        -- kam von einem Mitspieler: an alle anderen weitergeben
        g_server:broadcastEvent(LivingMarketFavoritesEvent.new(self.names), nil, connection)
    end
end

-- ---------------------------------------------------------------------
-- Verkaufsverlauf: Server -> Mitspieler (neue/geänderte Verkäufe; replace = komplette Liste beim Beitreten)
-- ---------------------------------------------------------------------
LivingMarketSalesEvent = {}
local LivingMarketSalesEvent_mt = Class(LivingMarketSalesEvent, Event)
InitEventClass(LivingMarketSalesEvent, "LivingMarketSalesEvent")

function LivingMarketSalesEvent.emptyNew()
    return Event.new(LivingMarketSalesEvent_mt)
end

function LivingMarketSalesEvent.new(sales, replace)
    local self = LivingMarketSalesEvent.emptyNew()
    self.sales = sales or {}
    self.replace = replace == true
    return self
end

function LivingMarketSalesEvent:writeStream(streamId, connection)
    local now = LivingMarket.getNowMinute()
    local count = math.min(#self.sales, 4000)
    streamWriteBool(streamId, self.replace)
    streamWriteUInt16(streamId, count)
    for i = 1, count do
        local sale = self.sales[i]
        streamWriteInt32(streamId, sale.id)
        streamWriteUInt8(streamId, sale.farmId)
        streamWriteUIntN(streamId, sale.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
        streamWriteString(streamId, sale.stationName or "")
        streamWriteFloat32(streamId, sale.liters)
        streamWriteFloat32(streamId, sale.money)
        streamWriteInt32(streamId, (sale.minute or now) - now)
        streamWriteFloat32(streamId, sale.factor or 1)
        streamWriteUInt8(streamId, sale.eventType or 0)
    end
end

function LivingMarketSalesEvent:readStream(streamId, connection)
    local now = LivingMarket.getNowMinute()
    self.replace = streamReadBool(streamId)
    self.sales = {}
    local count = streamReadUInt16(streamId)
    for _ = 1, count do
        local sale = {}
        sale.id            = streamReadInt32(streamId)
        sale.farmId        = streamReadUInt8(streamId)
        sale.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
        sale.stationName   = streamReadString(streamId)
        sale.liters        = streamReadFloat32(streamId)
        sale.money         = streamReadFloat32(streamId)
        sale.minute        = now + streamReadInt32(streamId)
        sale.factor        = streamReadFloat32(streamId)
        sale.eventType     = streamReadUInt8(streamId)
        table.insert(self.sales, sale)
    end
    self:run(connection)
end

function LivingMarketSalesEvent:run(connection)
    if connection:getIsServer() and g_server == nil then   -- nur auf Clients übernehmen
        LivingMarket:applySales(self.sales, self.replace)
    end
end

-- ---------------------------------------------------------------------
-- Lieferverträge: komplette Liste + Ansehen (Server -> Mitspieler)
-- ---------------------------------------------------------------------
LivingMarketContractListEvent = {}
local LivingMarketContractListEvent_mt = Class(LivingMarketContractListEvent, Event)
InitEventClass(LivingMarketContractListEvent, "LivingMarketContractListEvent")

function LivingMarketContractListEvent.emptyNew()
    return Event.new(LivingMarketContractListEvent_mt)
end

function LivingMarketContractListEvent.new()
    return LivingMarketContractListEvent.emptyNew()
end

function LivingMarketContractListEvent:writeStream(streamId, connection)
    local now = LivingMarket.getNowHour()
    local contracts = LivingMarket.contracts or {}
    local count = math.min(#contracts, 1000)
    streamWriteUInt16(streamId, count)
    for i = 1, count do
        local c = contracts[i]
        streamWriteInt32(streamId, c.id)
        streamWriteBool(streamId, c.state == "active")
        streamWriteString(streamId, c.stationKey or "")
        streamWriteString(streamId, c.stationName or "")
        streamWriteUIntN(streamId, c.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
        streamWriteFloat32(streamId, c.amount)
        streamWriteFloat32(streamId, c.delivered or 0)
        streamWriteFloat32(streamId, c.basePrice or 0)
        streamWriteFloat32(streamId, c.markup or 0)
        streamWriteFloat32(streamId, c.eventMarkup or 0)
        streamWriteUInt8(streamId, c.months or 1)
        streamWriteInt32(streamId, math.floor((c.offerEndHour or now) - now))
        streamWriteInt32(streamId, math.floor((c.deadlineHour or now) - now))
        if c.state == "active" then
            streamWriteUInt8(streamId, c.farmId or 0)
            streamWriteFloat32(streamId, c.price or 0)
            streamWriteFloat32(streamId, c.bonus or 0)
        end
    end
    local entries = {}
    for farmId, farm in pairs(LivingMarket.reputation or {}) do
        for stationKey, value in pairs(farm) do
            table.insert(entries, { farmId = farmId, stationKey = stationKey, value = value })
        end
    end
    streamWriteUInt16(streamId, math.min(#entries, 4000))
    for i = 1, math.min(#entries, 4000) do
        streamWriteUInt8(streamId, entries[i].farmId)
        streamWriteString(streamId, entries[i].stationKey)
        streamWriteFloat32(streamId, entries[i].value)
    end
    -- abgeschlossene Verträge
    local history = LivingMarket.contractHistory or {}
    streamWriteUInt16(streamId, math.min(#history, 2000))
    for i = 1, math.min(#history, 2000) do
        local e = history[i]
        streamWriteInt32(streamId, e.id or 0)
        streamWriteUInt8(streamId, e.farmId or 0)
        streamWriteString(streamId, e.result or "done")
        streamWriteString(streamId, e.stationKey or "")
        streamWriteString(streamId, e.stationName or "")
        streamWriteUIntN(streamId, e.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
        streamWriteFloat32(streamId, e.amount or 0)
        streamWriteFloat32(streamId, e.delivered or 0)
        streamWriteFloat32(streamId, e.price or 0)
        streamWriteFloat32(streamId, e.money or 0)
        streamWriteInt32(streamId, math.floor(e.repChange or 0))
        streamWriteInt32(streamId, math.floor((e.endHour or now) - now))
    end
end

function LivingMarketContractListEvent:readStream(streamId, connection)
    local now = LivingMarket.getNowHour()
    self.contracts = {}
    local count = streamReadUInt16(streamId)
    for _ = 1, count do
        local c = {}
        c.id            = streamReadInt32(streamId)
        c.state         = streamReadBool(streamId) and "active" or "offer"
        c.stationKey    = streamReadString(streamId)
        c.stationName   = streamReadString(streamId)
        c.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
        c.amount        = streamReadFloat32(streamId)
        c.delivered     = streamReadFloat32(streamId)
        c.basePrice     = streamReadFloat32(streamId)
        c.markup        = streamReadFloat32(streamId)
        c.eventMarkup   = streamReadFloat32(streamId)
        c.months        = streamReadUInt8(streamId)
        c.offerEndHour  = now + streamReadInt32(streamId)
        c.deadlineHour  = now + streamReadInt32(streamId)
        if c.state == "active" then
            c.farmId       = streamReadUInt8(streamId)
            c.price        = streamReadFloat32(streamId)
            c.bonus        = streamReadFloat32(streamId)
        end
        table.insert(self.contracts, c)
    end
    self.reputation = {}
    local repCount = streamReadUInt16(streamId)
    for _ = 1, repCount do
        local farmId = streamReadUInt8(streamId)
        local stationKey = streamReadString(streamId)
        local value = streamReadFloat32(streamId)
        self.reputation[farmId] = self.reputation[farmId] or {}
        self.reputation[farmId][stationKey] = value
    end
    self.history = {}
    local historyCount = streamReadUInt16(streamId)
    for _ = 1, historyCount do
        local e = {}
        e.id            = streamReadInt32(streamId)
        e.farmId        = streamReadUInt8(streamId)
        e.result        = streamReadString(streamId)
        e.stationKey    = streamReadString(streamId)
        e.stationName   = streamReadString(streamId)
        e.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
        e.amount        = streamReadFloat32(streamId)
        e.delivered     = streamReadFloat32(streamId)
        e.price         = streamReadFloat32(streamId)
        e.money         = streamReadFloat32(streamId)
        e.repChange     = streamReadInt32(streamId)
        e.endHour       = now + streamReadInt32(streamId)
        table.insert(self.history, e)
    end
    self:run(connection)
end

function LivingMarketContractListEvent:run(connection)
    if connection:getIsServer() and g_server == nil then
        LivingMarket.contracts = self.contracts
        LivingMarket.reputation = self.reputation
        LivingMarket.contractHistory = self.history or {}
        LivingMarket.contractsVersion = (LivingMarket.contractsVersion or 0) + 1
    end
end

-- ---------------------------------------------------------------------
-- Lieferverträge: Annahme / Kündigung (Mitspieler -> Server)
-- ---------------------------------------------------------------------
LivingMarketContractRequestEvent = {}
local LivingMarketContractRequestEvent_mt = Class(LivingMarketContractRequestEvent, Event)
InitEventClass(LivingMarketContractRequestEvent, "LivingMarketContractRequestEvent")

function LivingMarketContractRequestEvent.emptyNew()
    return Event.new(LivingMarketContractRequestEvent_mt)
end

function LivingMarketContractRequestEvent.new(accept, contractId, farmId)
    local self = LivingMarketContractRequestEvent.emptyNew()
    self.accept, self.contractId, self.farmId = accept == true, contractId, farmId or 0
    return self
end

function LivingMarketContractRequestEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.accept)
    streamWriteInt32(streamId, self.contractId)
    streamWriteUInt8(streamId, self.farmId)
end

function LivingMarketContractRequestEvent:readStream(streamId, connection)
    self.accept = streamReadBool(streamId)
    self.contractId = streamReadInt32(streamId)
    self.farmId = streamReadUInt8(streamId)
    self:run(connection)
end

function LivingMarketContractRequestEvent:run(connection)
    if connection:getIsServer() or g_server == nil then
        return   -- nur der Server bearbeitet Anfragen
    end
    -- Hof des anfragenden Spielers verwenden, falls bekannt
    local farmId = self.farmId
    if g_currentMission ~= nil and g_currentMission.userManager ~= nil and g_currentMission.userManager.getUserByConnection ~= nil then
        local user = g_currentMission.userManager:getUserByConnection(connection)
        if user ~= nil and g_farmManager ~= nil and g_farmManager.getFarmByUserId ~= nil then
            local farm = g_farmManager:getFarmByUserId(user:getId())
            if farm ~= nil and farm.farmId ~= nil then
                farmId = farm.farmId
            end
        end
    end
    if self.accept then
        LivingMarket:acceptContract(self.contractId, farmId)
    else
        LivingMarket:cancelContract(self.contractId, farmId)
    end
end

-- ---------------------------------------------------------------------
-- Lieferverträge: Meldung (Server -> Mitspieler; farmId 0 = alle, sonst nur dieser Hof)
-- ---------------------------------------------------------------------
LivingMarketContractNotifyEvent = {}
local LivingMarketContractNotifyEvent_mt = Class(LivingMarketContractNotifyEvent, Event)
InitEventClass(LivingMarketContractNotifyEvent, "LivingMarketContractNotifyEvent")

function LivingMarketContractNotifyEvent.emptyNew()
    return Event.new(LivingMarketContractNotifyEvent_mt)
end

function LivingMarketContractNotifyEvent.new(farmId, key, stationName, fillTypeIndex, liters, money)
    local self = LivingMarketContractNotifyEvent.emptyNew()
    self.farmId, self.key, self.stationName = farmId or 0, key, stationName or ""
    self.fillTypeIndex, self.liters, self.money = fillTypeIndex, liters or 0, money or 0
    return self
end

function LivingMarketContractNotifyEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.farmId)
    streamWriteString(streamId, self.key)
    streamWriteString(streamId, self.stationName)
    streamWriteUIntN(streamId, self.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
    streamWriteFloat32(streamId, self.liters)
    streamWriteFloat32(streamId, self.money)
end

function LivingMarketContractNotifyEvent:readStream(streamId, connection)
    self.farmId = streamReadUInt8(streamId)
    self.key = streamReadString(streamId)
    self.stationName = streamReadString(streamId)
    self.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
    self.liters = streamReadFloat32(streamId)
    self.money = streamReadFloat32(streamId)
    self:run(connection)
end

function LivingMarketContractNotifyEvent:run(connection)
    if connection:getIsServer() and g_server == nil then
        LivingMarket:showContractNotification(self.farmId, self.key, self.stationName, self.fillTypeIndex, self.liters, self.money)
    end
end

-- ---------------------------------------------------------------------
-- Optionen (gilt für das ganze Spiel): Anzahl der Verträge
-- Mitspieler (Admin) -> Server: neuen Wert anfragen; Server -> alle: Wert übernehmen.
-- 0 = Standard aus der Konfiguration
-- ---------------------------------------------------------------------
LivingMarketSettingsEvent = {}
local LivingMarketSettingsEvent_mt = Class(LivingMarketSettingsEvent, Event)
InitEventClass(LivingMarketSettingsEvent, "LivingMarketSettingsEvent")

function LivingMarketSettingsEvent.emptyNew()
    return Event.new(LivingMarketSettingsEvent_mt)
end

function LivingMarketSettingsEvent.new(maxContracts)
    local self = LivingMarketSettingsEvent.emptyNew()
    self.maxContracts = math.max(0, math.min(255, math.floor(maxContracts or 0)))
    return self
end

function LivingMarketSettingsEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.maxContracts)
end

function LivingMarketSettingsEvent:readStream(streamId, connection)
    self.maxContracts = streamReadUInt8(streamId)
    self:run(connection)
end

function LivingMarketSettingsEvent:run(connection)
    local value = self.maxContracts > 0 and self.maxContracts or nil
    if connection:getIsServer() then
        if g_server == nil then   -- Mitspieler: Wert vom Server übernehmen
            LivingMarket:applyMaxContracts(value)
        end
        return
    end
    -- Server: nur Admins dürfen ändern
    if g_server == nil or g_currentMission == nil or g_currentMission.userManager == nil then
        return
    end
    local user = g_currentMission.userManager.getUserByConnection ~= nil and g_currentMission.userManager:getUserByConnection(connection) or nil
    if user ~= nil and user.getIsMasterUser ~= nil and user:getIsMasterUser() then
        LivingMarket:applyMaxContracts(value)
    end
end

-- ---------------------------------------------------------------------
-- Hinweise beim Abladen (Server -> alle, angezeigt nur beim abladenden Hof)
-- kind 1 = Kurzmeldung nach dem Abladen, 2 = Station voll (mit Alternative)
-- ---------------------------------------------------------------------
LivingMarketUnloadNotifyEvent = {}
local LivingMarketUnloadNotifyEvent_mt = Class(LivingMarketUnloadNotifyEvent, Event)
InitEventClass(LivingMarketUnloadNotifyEvent, "LivingMarketUnloadNotifyEvent")

function LivingMarketUnloadNotifyEvent.emptyNew()
    return Event.new(LivingMarketUnloadNotifyEvent_mt)
end

function LivingMarketUnloadNotifyEvent.new(data)
    local self = LivingMarketUnloadNotifyEvent.emptyNew()
    self.data = data
    return self
end

function LivingMarketUnloadNotifyEvent:writeStream(streamId, connection)
    local d = self.data
    streamWriteUInt8(streamId, d.kind or 1)
    streamWriteUInt8(streamId, d.farmId or 0)
    streamWriteUIntN(streamId, d.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
    streamWriteString(streamId, d.stationName or "")
    if d.kind == LivingMarket.UNLOAD_FULL then
        streamWriteString(streamId, d.altName or "")
        streamWriteFloat32(streamId, d.altPrice or 0)
        streamWriteUInt8(streamId, d.altFree or 0)
    else
        streamWriteFloat32(streamId, d.liters or 0)
        streamWriteFloat32(streamId, d.money or 0)
        streamWriteFloat32(streamId, d.price or 0)
        streamWriteFloat32(streamId, d.change or 0)
        streamWriteUInt8(streamId, d.free or 0)
    end
end

function LivingMarketUnloadNotifyEvent:readStream(streamId, connection)
    local d = {}
    d.kind = streamReadUInt8(streamId)
    d.farmId = streamReadUInt8(streamId)
    d.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
    d.stationName = streamReadString(streamId)
    if d.kind == LivingMarket.UNLOAD_FULL then
        d.altName = streamReadString(streamId)
        d.altPrice = streamReadFloat32(streamId)
        d.altFree = streamReadUInt8(streamId)
    else
        d.liters = streamReadFloat32(streamId)
        d.money = streamReadFloat32(streamId)
        d.price = streamReadFloat32(streamId)
        d.change = streamReadFloat32(streamId)
        d.free = streamReadUInt8(streamId)
    end
    self.data = d
    self:run(connection)
end

function LivingMarketUnloadNotifyEvent:run(connection)
    if connection:getIsServer() and g_server == nil then
        LivingMarket:showUnloadNotification(self.data)
    end
end
