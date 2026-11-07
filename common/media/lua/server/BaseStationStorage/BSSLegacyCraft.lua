-- Base Station Storage: server-side guard for the legacy craft path.
--
-- The old (B41-era) crafting system is still alive in B42: ISCraftAction:complete() calls
-- RecipeManager.PerformMakeItem(recipe, selectedItem, character, containers), and that Java
-- function performs no access or distance checks at all -- it takes the container list from
-- the caller and consumes from it. Vanilla gets away with it because the list only ever
-- holds containers opened at arm's length; our getContainers hook makes base containers
-- appear there too, so the rule has to be enforced here.
--
-- The guard sits on the Lua method instead of the Java function: Lua methods are
-- replaceable from a mod, Java statics are not. ISCraftAction is the only gameplay caller
-- that passes a container list (the two others are a test harness and a moveable-sprite
-- path that passes nil), so wrapping complete() covers the whole surface.

if not isServer() then return end

require "BaseStationStorage/BSS"
require "BaseStationStorage/BSSData"

-- Returns reason, key when some container in the list must not be used right now.
local function offendingContainer(character, containers)
    if not containers then return nil end
    for i = 0, containers:size() - 1 do
        local container = containers:get(i)
        if container and not BSS.canUseDonor(character, container) then
            local key = BSS.keyOfContainer(container)
            local reason = "not_registered"
            if key and BSS.getEntry(key) then reason = "outside_base" end
            return reason, key
        end
    end
    return nil
end

local installed = false

local function install()
    if installed then return end
    local originalComplete = ISCraftAction and ISCraftAction.complete
    if not originalComplete then return end

    function ISCraftAction:complete()
        if self.containers then
            local ok, reason, key = pcall(offendingContainer, self.character, self.containers)
            if not ok then
                -- A guard bug must not stop crafting: fall through to vanilla.
                print("[BaseStationStorage] legacy guard error, allowing vanilla craft: " .. tostring(reason))
            elseif reason then
                print("[BaseStationStorage] legacy craft rejected for "
                    .. tostring(self.character and self.character:getUsername())
                    .. ": " .. tostring(reason) .. " " .. tostring(key))
                if self.character then
                    sendServerCommand(self.character, BSS.NET_MODULE, "denied", { err = reason })
                end
                -- The action counts as finished, only nothing is produced or consumed.
                return true
            end
        end
        return originalComplete(self)
    end

    installed = true
    print("[BaseStationStorage] legacy craft guard installed")
end

install()

-- Mod lua loads after the vanilla tree, but if another mod reordered things the guard is
-- installed no later than here, and the failure is loud instead of silent.
Events.OnServerStarted.Add(function()
    install()
    if not installed then
        print("[BaseStationStorage] WARNING: ISCraftAction.complete is missing, legacy craft guard inactive")
    end
end)
