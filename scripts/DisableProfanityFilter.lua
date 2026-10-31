-- ---------------------------------------------------------------------
-- Schimpfwortfilter des Spiels abschalten
-- Der Filter ersetzt harmlose Wörter (z. B. "Aldi" -> "Al$i") in Suchfeld,
-- Namen und Chat. Idee übernommen aus "Disable Profanity Filter" von Supermaschine.
-- Wirkt im ganzen Spiel, solange der Mod aktiv ist.
-- ---------------------------------------------------------------------
local ok, err = pcall(function()
    local meta = getmetatable(_G)
    local globalEnv = meta ~= nil and meta.__index or nil
    if type(globalEnv) ~= "table" then
        globalEnv = _G
    end
    globalEnv.filterText = function(text, ...)
        return text
    end
end)
if not ok then
    print("[LivingMarket] WARNUNG: Schimpfwortfilter konnte nicht abgeschaltet werden: " .. tostring(err))
end
