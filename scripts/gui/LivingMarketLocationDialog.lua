-- =====================================================================
-- LivingMarketLocationDialog: Fenster "Lagerorte" über dem ESC-Menü
-- Zeigt für die gewählte Ware alle eigenen Lagerorte mit Menge.
-- "Markieren" setzt den Ort als Ziel auf der Karte (wie TS Stock Check).
-- =====================================================================

LivingMarketLocationDialog = {}
local LivingMarketLocationDialog_mt = Class(LivingMarketLocationDialog, MessageDialog)

LivingMarketLocationDialog.NAME = "LivingMarketLocationDialog"

function LivingMarketLocationDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or LivingMarketLocationDialog_mt)
    self.locations = {}
    self.selectedIndex = 1
    return self
end

-- Einmal beim Laden der Karte anmelden
function LivingMarketLocationDialog.register()
    local dialog = LivingMarketLocationDialog.new()
    g_gui:loadGui(LivingMarket.modDir .. "gui/LivingMarketLocationDialog.xml", LivingMarketLocationDialog.NAME, dialog)
    LivingMarketLocationDialog.instance = dialog
end

-- Öffnen für eine Ware
function LivingMarketLocationDialog.show(fillTypeIndex, title)
    local dialog = g_gui:showDialog(LivingMarketLocationDialog.NAME)
    if dialog ~= nil and dialog.target ~= nil then
        dialog.target:setWare(fillTypeIndex, title)
    end
end

function LivingMarketLocationDialog:onGuiSetupFinished()
    LivingMarketLocationDialog:superClass().onGuiSetupFinished(self)
    self.locationList:setDataSource(self)
    self.locationList:setDelegate(self)
end

function LivingMarketLocationDialog:onOpen()
    LivingMarketLocationDialog:superClass().onOpen(self)
    FocusManager:setFocus(self.locationList)
end

function LivingMarketLocationDialog:setWare(fillTypeIndex, title)
    if self.dialogTitleElement ~= nil then
        self.dialogTitleElement:setText(string.format(g_i18n:getText("livingMarket_locTitle"), title or "?"))
    end
    self.locations = LivingMarket:getStockLocations(fillTypeIndex)
    self.selectedIndex = 1
    if self.emptyText ~= nil then
        self.emptyText:setVisible(#self.locations == 0)
    end
    self.locationList:reloadData()
    self:updateTagButton()
end

-- ---------------------------------------------------------------------
-- Liste
-- ---------------------------------------------------------------------
function LivingMarketLocationDialog:getNumberOfSections()
    return 1
end

function LivingMarketLocationDialog:getNumberOfItemsInSection(list, section)
    return #self.locations
end

function LivingMarketLocationDialog:populateCellForItemInSection(list, section, index, cell)
    local location = self.locations[index]
    if location == nil then
        return
    end
    cell:getAttribute("place"):setText(location.name or "?")
    cell:getAttribute("amount"):setText(LivingMarket.formatLiters(location.level))
end

function LivingMarketLocationDialog:onListSelectionChanged(list, section, index)
    self.selectedIndex = index
    self:updateTagButton()
end

-- ---------------------------------------------------------------------
-- Auf der Karte markieren
-- ---------------------------------------------------------------------
function LivingMarketLocationDialog:getSelectedHotspot()
    local location = self.locations[self.selectedIndex]
    return location ~= nil and location.hotspot or nil
end

function LivingMarketLocationDialog:updateTagButton()
    if self.tagButton == nil then
        return
    end
    local hotspot = self:getSelectedHotspot()
    self.tagButton:setDisabled(hotspot == nil)
    local tagged = hotspot ~= nil and hotspot == g_currentMission.currentMapTargetHotspot
    self.tagButton:setText(g_i18n:getText(tagged and "livingMarket_locUntag" or "livingMarket_locTag"))
end

function LivingMarketLocationDialog:onClickTag()
    local hotspot = self:getSelectedHotspot()
    if hotspot == nil then
        return
    end
    if hotspot == g_currentMission.currentMapTargetHotspot then
        g_currentMission:setMapTargetHotspot()
    else
        g_currentMission:setMapTargetHotspot(hotspot)
    end
    self:updateTagButton()
end

function LivingMarketLocationDialog:onClickBack()
    self:close()
end
