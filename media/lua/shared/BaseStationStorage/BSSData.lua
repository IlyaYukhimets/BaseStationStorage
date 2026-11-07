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

-- Appends registered containers that are not already in the list. Dedupe runs on the
-- registry key rather than object identity: two Lua wrappers of the same Java container
-- are not guaranteed to compare equal, coordinates always do.
function BSS.appendRegistered(list, role)
    if not list then return 0 end
    local existing = {}
    for i = 0, list:size() - 1 do
        local key = BSS.keyOfContainer(list:get(i))
        if key then existing[key] = true end
    end
    local added = 0
    for _, resolved in ipairs(BSS.resolveRegistered(role)) do
        if not existing[resolved.key] then
            list:add(resolved.container)
            existing[resolved.key] = true
            added = added + 1
        end
    end
    return added
end
