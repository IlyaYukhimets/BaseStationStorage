-- Base Station Storage: server-side guard for the craft container list.
--
-- Three facts from the 42.21 sources decide the design of this file:
--  1) ISHandcraftAction:serverStart() rebuilds HandcraftLogic from the container list the
--     client sent, and Java never validates manualInputs at all -- an item is resolved by
--     ID in any container in the world.
--  2) BaseCraftingLogic.isContainersAccessible() rejects any container further than 2.5
--     tiles from the player; it is Java and cannot be overridden from Lua.
--  3) The rule of this mod: base storage is usable only from inside the base. So a
--     registered container further away is legal only while the player stands in the very
--     same safehouse -- that is BSS.canUseDonor().
-- Hence: drop unreachable containers from the list (one by one -- the loot panel keeps
-- stale containers open after the player walks away, and that must not block an ordinary
-- craft), and for allowed-but-distant containers run the recipe ourselves, replicating
-- performCurrentRecipe minus the distance check.

if not isServer() then return end

require "BaseStationStorage/BSS"
require "BaseStationStorage/BSSData"

local function squareOf(container)
    if container and container.getSourceGrid then return container:getSourceGrid() end
    return nil
end

local function isNear(character, square, playerSquare)
    if not square or not playerSquare then return false end
    return BSS.isWithin(playerSquare:getX(), playerSquare:getY(), playerSquare:getZ(),
        square:getX(), square:getY(), square:getZ(), BSS.TRUST_RADIUS)
end

-- Builds the container list the craft may actually use. Unreachable containers are
-- dropped one by one instead of failing the whole craft: the loot panel keeps containers
-- open after the player walks away, and rejecting everything would block a perfectly
-- ordinary craft whose ingredients are all in reach.
-- Returns kept (ArrayList), farDonor, droppedCount, dropReason
function BSS.filterCraftContainers(character, containers)
    local kept = ArrayList.new()
    if not character or not containers then return kept, false, 0, nil end
    local playerSquare = character:getCurrentSquare()
    if not playerSquare then
        for i = 0, containers:size() - 1 do
            if containers:get(i) then kept:add(containers:get(i)) end
        end
        return kept, false, 0, nil
    end

    local farDonor, dropped, dropReason = false, 0, nil
    for i = 0, containers:size() - 1 do
        local container = containers:get(i)
        if container then
            if not BSS.canUseDonor(character, container) then
                dropped = dropped + 1
                local key = BSS.keyOfContainer(container)
                local reason = "outside_base"
                if not (key and BSS.getEntry(key)) then reason = "not_registered" end
                dropReason = dropReason or reason
                print("[BaseStationStorage] craft source dropped (" .. reason .. "): " .. tostring(key))
            else
                kept:add(container)
                local square = squareOf(container)
                if square and not isNear(character, square, playerSquare) then
                    -- Java would refuse this one, so the craft has to go through our own path.
                    farDonor = true
                end
            end
        end
    end
    return kept, farDonor, dropped, dropReason
end

-- Manual inputs are not checked by Java at all, so they are filtered here with the same
-- rule as the container list.
function BSS.stripBlockedManualInputs(action)
    if not action or not action.manualInputs or not action.character then return end
    for _, items in pairs(action.manualInputs) do
        if items and items.size then
            local kept = {}
            for i = 0, items:size() - 1 do
                local item = items:get(i)
                local container = item and item.getContainer and item:getContainer() or nil
                if not container or BSS.canUseDonor(action.character, container) then
                    kept[#kept + 1] = item
                end
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
        local callOk, kept, farDonor, dropped, reason =
            pcall(BSS.filterCraftContainers, self.character, self.containers)

        if not callOk then
            -- A guard bug must not make crafting impossible.
            print("[BaseStationStorage] guard error, allowing vanilla craft: " .. tostring(kept))
            return originalServerStart(self)
        end

        if kept:size() == 0 and self.containers and self.containers:size() > 0 then
            -- Nothing usable left: crafting from a list we emptied would only crash.
            print("[BaseStationStorage] craft stopped for "
                .. tostring(self.character and self.character:getUsername())
                .. ": no usable containers (" .. tostring(reason) .. ")")
            if self.character then
                sendServerCommand(self.character, BSS.NET_MODULE, "denied", { err = reason or "outside_base" })
            end
            self:forceStop()
            return
        end

        if dropped > 0 then
            self.containers = kept
        end
        self.bssFarDonor = farDonor
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
