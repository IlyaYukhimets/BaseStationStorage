-- Base Station Storage: server-side guard for the craft container list.
--
-- Two problems with the vanilla chain, both confirmed in the 42.21 sources:
--  1) ISHandcraftAction:serverStart() rebuilds HandcraftLogic from the container list the
--     client sent, and manualInputs items are resolved by ID from *any* container in the
--     world, so a modified client could craft out of a crate in another city.
--  2) HandcraftLogic.performCurrentRecipe() -> BaseCraftingLogic.isContainersAccessible()
--     rejects any container whose square is further than 2.5 tiles from the player. That
--     check is Java and cannot be overridden from Lua, so a registered fridge across the
--     base would simply refuse to give ingredients.
-- The guard solves (1) by rejecting what we can prove is wrong, and (2) by running the
-- recipe ourselves for registered donors, replicating performCurrentRecipe minus the
-- distance check (perform + outputs + consumed items, exactly as the vanilla tail does).

if not isServer() then return end

require "BaseStationStorage/BSS"
require "BaseStationStorage/BSSData"

-- Classifies one container of a craft list. Returns allowed, isFar.
local function classify(character, container)
    local square = nil
    if container.getSourceGrid then square = container:getSourceGrid() end
    if not square then return true, false end -- bag, vehicle proxy, corpse: nothing to verify

    local key = BSS.keyOfContainer(container)
    local entry = key and BSS.getEntry(key) or nil
    local playerSquare = character:getCurrentSquare()
    if not playerSquare then return true, false end

    local near = BSS.isWithin(playerSquare:getX(), playerSquare:getY(), playerSquare:getZ(),
        square:getX(), square:getY(), square:getZ(), BSS.TRUST_RADIUS)
    local registered = entry and BSS.hasRole(entry, "donor")
    if registered then return true, not near end
    -- Not registered and out of reach: vanilla would refuse it too, so refusing here is
    -- no stricter than the game -- it only closes the manualInputs hole.
    return near, false
end

-- Returns allowed, farRegistered, blockedKey
function BSS.evaluateCraft(character, containers)
    if not character or not containers then return true, false, nil end
    local farRegistered = false
    for i = 0, containers:size() - 1 do
        local container = containers:get(i)
        if container then
            local allowed, far = classify(character, container)
            if not allowed then
                return false, farRegistered, BSS.keyOfContainer(container) or "unknown"
            end
            if far then farRegistered = true end
        end
    end
    return true, farRegistered, nil
end

-- Manual inputs are not checked by Java at all, so they are stripped here: an item whose
-- container is neither registered nor within reach is removed from its input group. The
-- recipe then simply fails to find it, which is the vanilla outcome.
function BSS.stripBlockedManualInputs(action)
    if not action or not action.manualInputs then return end
    for _, items in pairs(action.manualInputs) do
        if items and items.size then
            local kept = {}
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                local container = item and item.getContainer and item:getContainer() or nil
                local allowed = true
                if container then allowed = classify(action.character, container) end
                if allowed then kept[#kept + 1] = item end
            end
            if #kept ~= items:size() then
                items:clear()
                for i = 1, #kept do items:add(kept[i]) end
            end
        end
    end
end

-- Same work as HandcraftLogic.performCurrentRecipe(), minus isContainersAccessible().
function BSS.performWithRegisteredDonors(action)
    local logic = action.logic
    if not logic then return false end
    logic:updateFloorContainer(logic:getContainers())

    local recipeData = logic:getRecipeData()
    if not recipeData then return false end

    local overrideItems = nil
    if not logic:isManualSelectInputs() then overrideItems = logic:getAllItems() end

    if not recipeData:perform(action.character, logic:getSourceResources(), overrideItems, logic:getContainers()) then
        return false
    end

    local items = ArrayList.new()
    logic:getCreatedOutputItems(items)
    for i = 0, items:size() - 1 do
        Actions.addOrDropItem(action.character, items:get(i))
    end
    recipeData:luaCallOnCreate(action.character)
    recipeData:processDestroyAndUsedItems(action.character)

    -- Vanilla records the consumed item types on a single output item (recipe bookkeeping).
    if items:size() == 1 then
        local resultItem = items:get(0)
        local modData = resultItem:getModData()
        local consumed = recipeData:getAllConsumedItems()
        for i = 0, consumed:size() - 1 do
            local fullType = consumed:get(i):getFullType()
            modData[fullType] = (modData[fullType] or 0) + 1
        end
    end
    return true
end

local originalServerStart = ISHandcraftAction and ISHandcraftAction.serverStart
if originalServerStart then
    -- Idempotent on purpose: a retried packet re-runs serverStart from scratch.
    function ISHandcraftAction:serverStart()
        local callOk, allowed, farRegistered, blockedKey =
            pcall(BSS.evaluateCraft, self.character, self.containers)

        if not callOk then
            -- A guard bug must not make crafting impossible.
            print("[BaseStationStorage] guard error, allowing vanilla craft: " .. tostring(allowed))
            allowed, farRegistered = true, false
        end
        if not allowed then
            print("[BaseStationStorage] craft rejected for " .. tostring(self.character and self.character:getUsername())
                .. ": container outside base " .. tostring(blockedKey))
            self:forceStop()
            return
        end

        self.bssFarDonor = farRegistered
        pcall(BSS.stripBlockedManualInputs, self)
        return originalServerStart(self)
    end
else
    print("[BaseStationStorage] WARNING: ISHandcraftAction.serverStart is missing, craft guard inactive")
end

local originalPerformRecipe = ISHandcraftAction and ISHandcraftAction.performRecipe
if originalPerformRecipe then
    function ISHandcraftAction:performRecipe()
        if not self.bssFarDonor or not self.logic then return originalPerformRecipe(self) end

        local ok, done = pcall(BSS.performWithRegisteredDonors, self)
        if not ok then
            -- No vanilla retry after an attempted perform: a second consumption pass could
            -- duplicate items. The craft fails, the log says why.
            print("[BaseStationStorage] registered-donor craft failed: " .. tostring(done))
        end
        return done
    end
else
    print("[BaseStationStorage] WARNING: ISHandcraftAction.performRecipe is missing, distant donors unavailable")
end
