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
