-- Base Station Storage: auto-sort.
-- Plans which item goes to which registered sink (consolidation first, then free room)
-- and executes the plan through vanilla ISInventoryPane:transferItemsByWeight, so the
-- move itself stays a normal networked transfer the server validates.

if isServer() then return end

require "BaseStationStorage/BSS"
require "BaseStationStorage/BSSData"

BSSSort = BSSSort or {}

local function notify(text)
    local player = getPlayer()
    if player and text then HaloTextHelper.addText(player, text) end
end

local function freeCapacity(container, playerObj)
    local max = container:getMaxWeight() or 0
    local effective = container:getEffectiveCapacity(playerObj)
    if effective then max = effective end
    return max - (container:getCapacityWeight() or 0)
end

local function collectTypes(container)
    local types = {}
    local items = container:getItems()
    if items then
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if item then types[item:getFullType()] = true end
        end
    end
    return types
end

function BSSSort.distribute(playerObj, source)
    if not playerObj or not source then return 0 end

    local sourceKey = BSS.keyOfContainer(source)
    local candidates = {}
    for _, resolved in ipairs(BSS.resolveRegistered("sink")) do
        -- Same rule as crafting: a base container beyond arm's reach only works while the
        -- player stands inside that base, so outside it there is nothing to sort into.
        if resolved.key ~= sourceKey and BSS.canUseSink(playerObj, resolved.container, resolved.key) then
            candidates[#candidates + 1] = {
                key = resolved.key,
                container = resolved.container,
                free = freeCapacity(resolved.container, playerObj),
                types = collectTypes(resolved.container),
            }
        end
    end

    if #candidates == 0 then
        notify(getText("UI_BSS_NoTargets"))
        return 0
    end

    local items = source:getItems()
    if not items or items:size() == 0 then
        notify(getText("UI_BSS_SortNothing"))
        return 0
    end

    -- Plan first: a target is reserved as soon as it is chosen, so the next item sees
    -- the remaining room and the freshly added type.
    local plans, order = {}, {}
    for i = items:size() - 1, 0, -1 do
        local item = items:get(i)
        if item then
            local fullType = item:getFullType()
            local weight = item:getUnequippedWeight()
            if not weight or weight <= 0 then weight = item:getWeight() or 0 end
            local target = BSS.pickSortTarget(candidates, fullType, weight)
            if target then
                BSS.reserveCapacity(target, fullType, weight)
                local plan = plans[target.key]
                if not plan then
                    plan = { container = target.container, items = {} }
                    plans[target.key] = plan
                    order[#order + 1] = target.key
                end
                plan.items[#plan.items + 1] = item
            end
        end
    end

    if #order == 0 then
        notify(getText("UI_BSS_SortNothing"))
        return 0
    end

    local pane = getPlayerInventory(playerObj:getPlayerNum()).inventoryPane
    local queued = 0
    for _, key in ipairs(order) do
        local plan = plans[key]
        queued = queued + #plan.items
        pane:transferItemsByWeight(plan.items, plan.container)
    end

    notify(string.format(getText("UI_BSS_Sorted"), queued))
    return queued
end
