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

-- Returns the usable subset of the container list, the number of dropped entries and the
-- reason for the first drop. Dropping entries instead of failing the action matters here:
-- a floor recipe ignores most of the list, so a stale far container must not break it.
local function allowedContainers(character, containers)
    local kept = ArrayList.new()
    local dropped, reason = 0, nil
    for i = 0, containers:size() - 1 do
        local container = containers:get(i)
        if container then
            if BSS.canUseDonor(character, container) then
                kept:add(container)
            else
                dropped = dropped + 1
                local key = BSS.keyOfContainer(container)
                local why = "not_registered"
                if key and BSS.getEntry(key) then why = "outside_base" end
                reason = reason or why
                print("[BaseStationStorage] legacy craft source dropped (" .. why .. "): " .. tostring(key))
            end
        end
    end
    return kept, dropped, reason
end

local installed = false

local function install()
    if installed then return end
    local originalComplete = ISCraftAction and ISCraftAction.complete
    if not originalComplete then return end

    function ISCraftAction:complete()
        if self.containers then
            local ok, kept, dropped, reason = pcall(allowedContainers, self.character, self.containers)
            if not ok then
                -- A guard bug must not stop crafting: fall through to vanilla.
                print("[BaseStationStorage] legacy guard error, allowing vanilla craft: " .. tostring(kept))
                return originalComplete(self)
            end
            if kept:size() == 0 and self.containers:size() > 0 then
                print("[BaseStationStorage] legacy craft stopped for "
                    .. tostring(self.character and self.character:getUsername())
                    .. ": no usable containers (" .. tostring(reason) .. ")")
                if self.character then
                    sendServerCommand(self.character, BSS.NET_MODULE, "denied", { err = reason or "outside_base" })
                end
                -- The action counts as finished, only nothing is produced or consumed.
                return true
            end
            if dropped > 0 then
                self.containers = kept
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
