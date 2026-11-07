-- Base Station Storage: registry storage and world binding.
-- Shared by client and server; the client only ever reads, the server is the writer.

BSS = BSS or {}
local BSS = BSS

local function registry()
    local data = ModData.getOrCreate(BSS.DATA_KEY)
    if type(data.c) ~= "table" then data.c = {} end
    data.v = BSS.DATA_VERSION
    return data
end

function BSS.getData()
    return registry()
end

function BSS.getEntry(key)
    if type(key) ~= "string" then return nil end
    return registry().c[key]
end

function BSS.countRegistered()
    local count = 0
    for _ in pairs(registry().c) do count = count + 1 end
    return count
end

-- Entries that may supply ingredients (donor) or receive items (sink).
function BSS.getEntries(role)
    local out = {}
    local containers = registry().c
    for _, key in ipairs(BSS.sortedKeys(containers)) do
        local entry = containers[key]
        if type(entry) == "table" and BSS.hasRole(entry, role) then out[#out + 1] = entry end
    end
    return out
end

function BSS.findContainer(x, y, z, ctype)
    if not getCell then return nil end
    local cell = getCell()
    if not cell then return nil end
    local square = cell:getGridSquare(x, y, z)
    if not square then return nil end
    local objects = square:getObjects()
    if not objects then return nil end
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if object and object.getContainer then
            local container = object:getContainer()
            if container and tostring(container:getType()) == ctype then
                return container, object
            end
        end
    end
    return nil
end

-- Canonical identity of a container: its square plus its container type. Bags and
-- carried containers have no source square, hence nil -- they can never be registered.
function BSS.keyOfContainer(container)
    if not container or not container.getSourceGrid then return nil end
    local square = container:getSourceGrid()
    if not square then return nil end
    return BSS.keyOf(square:getX(), square:getY(), square:getZ(), tostring(container:getType()))
end

function BSS.resolve(key)
    local x, y, z, ctype = BSS.parseKey(key)
    if not x then return nil end
    return BSS.findContainer(x, y, z, ctype)
end

-- Registered entries that currently resolve to a real container in a loaded chunk.
function BSS.resolveRegistered(role)
    local out = {}
    for _, entry in ipairs(BSS.getEntries(role)) do
        local key = BSS.keyOf(entry.x, entry.y, entry.z, entry.t)
        if key then
            local container = BSS.resolve(key)
            if container then
                out[#out + 1] = { key = key, entry = entry, container = container }
            end
        end
    end
    return out
end

function BSS.label(entry)
    if type(entry) ~= "table" then return "?" end
    local translateKey = "UI_BSS_Type_" .. tostring(entry.t)
    local name = getText(translateKey)
    if name == translateKey then name = tostring(entry.t) end
    return string.format("%s (%d,%d,%d)", name, entry.x, entry.y, entry.z)
end

-- Safehouse covering a square, or nil when the server has no safehouse there.
function BSS.safehouseAt(square)
    if not square then return nil end
    if not SafeHouse or not SafeHouse.getSafeHouse then return nil end
    return SafeHouse.getSafeHouse(square)
end

function BSS.sameSafehouse(first, second)
    if not first or not second then return false end
    return BSS.sameRectangle(first:getX(), first:getY(), first:getX2(), first:getY2(),
        second:getX(), second:getY(), second:getX2(), second:getY2())
end

-- The rule the whole mod stands on: base storage is usable only from inside the base.
-- The player must stand in the very same safehouse the container belongs to and be
-- allowed there. Standing outside (or in someone else's safehouse) gives nothing.
function BSS.canReachBase(player, playerSquare, containerSquare)
    local containerSafehouse = BSS.safehouseAt(containerSquare)
    if not containerSafehouse then return false end
    local username = player:getUsername()
    if not (containerSafehouse:isOwner(username) or containerSafehouse:playerAllowed(player)) then
        return false
    end
    return BSS.sameSafehouse(BSS.safehouseAt(playerSquare), containerSafehouse)
end

-- May this player use this container for the given role right now?
-- Adjacent containers are vanilla behaviour and always allowed; anything further must be a
-- registered container of that role inside the safehouse the player is standing in.
function BSS.canUseRole(player, container, role)
    if not player or not container or not role then return false end
    if BSS.isAdminLevel(player:getAccessLevel()) then return true end

    local containerSquare = nil
    if container.getSourceGrid then containerSquare = container:getSourceGrid() end
    if not containerSquare then return true end -- bag, vehicle proxy, corpse: nothing to verify

    local playerSquare = player:getCurrentSquare()
    if not playerSquare then return false end

    if BSS.isWithin(playerSquare:getX(), playerSquare:getY(), playerSquare:getZ(),
        containerSquare:getX(), containerSquare:getY(), containerSquare:getZ(), BSS.TRUST_RADIUS) then
        return true
    end

    local entry = BSS.getEntry(BSS.keyOfContainer(container))
    if not (entry and BSS.hasRole(entry, role)) then return false end
    return BSS.canReachBase(player, playerSquare, containerSquare)
end

function BSS.canUseDonor(player, container)
    return BSS.canUseRole(player, container, "donor")
end

function BSS.canUseSink(player, container)
    return BSS.canUseRole(player, container, "sink")
end

-- Appends registered containers that are not already in the list. Dedupe runs on the
-- registry key rather than object identity: two Lua wrappers of the same Java container
-- are not guaranteed to compare equal, coordinates always do.
-- When a player is given, containers that player could not use right now (standing
-- outside the base) are skipped, so the craft UI never offers an impossible recipe.
function BSS.appendRegistered(list, role, player)
    if not list then return 0 end
    local existing = {}
    for i = 0, list:size() - 1 do
        local key = BSS.keyOfContainer(list:get(i))
        if key then existing[key] = true end
    end
    local added = 0
    for _, resolved in ipairs(BSS.resolveRegistered(role)) do
        if not existing[resolved.key] then
            if not player or BSS.canUseDonor(player, resolved.container) then
                list:add(resolved.container)
                existing[resolved.key] = true
                added = added + 1
            end
        end
    end
    return added
end
