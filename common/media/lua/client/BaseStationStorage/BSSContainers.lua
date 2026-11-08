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
            BSS.appendRegistered(list, "donor", character)
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
            BSS.appendRegistered(self.containerList, "donor", self.character)
        end
    else
        print("[BaseStationStorage] WARNING: CraftTooltip:getContainers is missing, tooltips may undercount")
    end

    wrappersInstalled = true
end

-- Меню на иконке контейнера в колонке слева от окна добычи: там игра сама предлагает
-- "Переименовать контейнер", и наше "Убежище" встаёт рядом -- одно привычное место для
-- всех действий с контейнером, включая пустой ящик с пола.
local function installContainerButtonMenu()
    if not ISInventoryPage or not ISInventoryPage.addContainerButton then
        print("[BaseStationStorage] WARNING: ISInventoryPage.addContainerButton is missing, loot-column menu inactive")
        return
    end

    local originalAddContainerButton = ISInventoryPage.addContainerButton
    function ISInventoryPage:addContainerButton(container, texture, name, tooltip)
        local button = originalAddContainerButton(self, container, texture, name, tooltip)
        if not button or not container then return button end

        -- Ванильный обработчик не подменяем, а вызываем: он открывает общее контекстное
        -- меню (переименование, админские действия) и возвращается раньше для сумок.
        local vanillaRightClick = button.onRightMouseDown
        button.onRightMouseDown = function(btn, x, y)
            if vanillaRightClick then vanillaRightClick(btn, x, y) end
            local page = btn.parent and btn.parent.parent
            BSS.openContainerMenu(page and page.player or 0, btn.inventory or container)
        end
        return button
    end
end

Events.OnGameStart.Add(installCraftFunnel)
Events.OnGameStart.Add(installContainerButtonMenu)
