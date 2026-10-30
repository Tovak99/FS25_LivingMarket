-- =====================================================================
-- DynamicMarketSyncEvent
-- Schickt Kontingente vom Server an die Clients:
--  - komplett, wenn ein Spieler beitritt
--  - nur die geänderten Einträge, wenn verkauft oder aufgefüllt wurde
--
-- Stationen werden über ihr Placeable (Netzwerk-Objekt) identifiziert,
-- weil die Lua-Tabelle der Station auf jedem Rechner eine andere ist.
-- =====================================================================

DynamicMarketSyncEvent = {}
local DynamicMarketSyncEvent_mt = Class(DynamicMarketSyncEvent, Event)

InitEventClass(DynamicMarketSyncEvent, "DynamicMarketSyncEvent")

function DynamicMarketSyncEvent.emptyNew()
    return Event.new(DynamicMarketSyncEvent_mt)
end

-- entries: Liste von { placeable, fillTypeIndex, remaining, max, refill }
function DynamicMarketSyncEvent.new(entries)
    local self = DynamicMarketSyncEvent.emptyNew()
    self.entries = entries or {}
    return self
end

function DynamicMarketSyncEvent:writeStream(streamId, connection)
    streamWriteUInt16(streamId, #self.entries)
    for _, e in ipairs(self.entries) do
        NetworkUtil.writeNodeObject(streamId, e.placeable)
        streamWriteUIntN(streamId, e.fillTypeIndex, FillTypeManager.SEND_NUM_BITS)
        streamWriteFloat32(streamId, e.remaining)
        streamWriteFloat32(streamId, e.max)
        streamWriteFloat32(streamId, e.refill)
    end
end

function DynamicMarketSyncEvent:readStream(streamId, connection)
    self.entries = {}
    local count = streamReadUInt16(streamId)
    for _ = 1, count do
        local e = {}
        e.placeable     = NetworkUtil.readNodeObject(streamId)
        e.fillTypeIndex = streamReadUIntN(streamId, FillTypeManager.SEND_NUM_BITS)
        e.remaining     = streamReadFloat32(streamId)
        e.max           = streamReadFloat32(streamId)
        e.refill        = streamReadFloat32(streamId)
        table.insert(self.entries, e)
    end
    self:run(connection)
end

function DynamicMarketSyncEvent:run(connection)
    -- Nur Daten vom Server übernehmen, nie von einem Client
    if connection:getIsServer() then
        DynamicMarket:applySyncEntries(self.entries)
    end
end
