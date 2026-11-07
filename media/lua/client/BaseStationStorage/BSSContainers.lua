-- Base Station Storage: the one integration point with the game's craft UI.
-- Vanilla and Neat_Crafting both take their donor containers from
-- ISInventoryPaneContextMenu.getContainers(), so appending the registered containers
-- here covers handcraft, cooking and building without replacing any window.

if isServer() then return end

require "BaseStationStorage/BSS"
require "BaseStationStorage/BSSData"

local wrappersInstalled = false

local function installCraftFunnel()
    if wrappersInstalled then return end

    local originalGetContainers = ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.getContainers
    if originalGetContainers then
        ISInventoryPaneContextMenu.getContainers = function(character)
            local list = originalGetContainers(character)
            BSS.appendRegistered(list, "donor")
            return list
        end
    else
        print("[BaseStationStorage] WARNING: ISInventoryPaneContextMenu.getContainers is missing, craft integration inactive")
    end

    -- CraftTooltip keeps its own copy of the container scan; without this the tooltip
    -- would claim a recipe is unavailable while the craft panel offers it.
    if CraftTooltip and CraftTooltip.getContainers then
        local originalTooltipContainers = CraftTooltip.getContainers
        function CraftTooltip:getContainers()
            originalTooltipContainers(self)
            BSS.appendRegistered(self.containerList, "donor")
        end
    else
        print("[BaseStationStorage] WARNING: CraftTooltip:getContainers is missing, tooltips may undercount")
    end

    wrappersInstalled = true
end

Events.OnGameStart.Add(installCraftFunnel)
