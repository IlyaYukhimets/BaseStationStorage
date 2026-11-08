-- Base Station Storage: authoritative side of the registry.
-- Every write goes through here: a client can only *ask*, the server decides.

if not isServer() then return end

require "BaseStationStorage/BSS"
require "BaseStationStorage/BSSData"

-- Lua-биндинг sendServerCommand принимает игрока ПЕРВЫМ аргументом. Варианта с
-- clientID не существует: попытка sendServerCommand(module, command, payload, clientID)
-- падает с "No implementation found" уже после записи реестра, поэтому клиент остаётся
-- без ответа и показывает ноль контейнеров.
local function reply(player, command, payload)
    payload.cmd = command
    sendServerCommand(player, BSS.NET_MODULE, "reply", payload)
end

-- Client tables arrive as plain Lua tables with arbitrary contents: coerce numbers,
-- floor them and reject a container type that would corrupt the registry key.
local function sanitize(args)
    if type(args) ~= "table" then return nil end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    local ctype = args.t
    if not x or not y or not z then return nil end
    if not BSS.isValidContainerType(ctype) then return nil end
    return math.floor(x), math.floor(y), math.floor(z), ctype
end

local function squareOf(x, y, z)
    local cell = getCell()
    if not cell then return nil end
    return cell:getGridSquare(x, y, z)
end

-- Owner or allowed resident of the safehouse that covers the container's square.
-- Admins and moderators skip the check. No safehouse at all means "no base here".
local function canManage(player, square)
    if BSS.isAdminLevel(player:getAccessLevel()) then return true end
    if not SafeHouse or not SafeHouse.isSafeHouse then return false end
    local safehouse = SafeHouse.isSafeHouse(square, nil, false)
    if not safehouse then return false end
    if safehouse:getOwner() == player:getUsername() then return true end
    return safehouse:playerAllowed(player) and true or false
end

local handlers = {}

function handlers.add(args, player)
    local x, y, z, ctype = sanitize(args)
    if not x then return reply(player, "add", { ok = false, err = "badargs" }) end

    local square = squareOf(x, y, z)
    if not square then return reply(player, "add", { ok = false, err = "nosquare" }) end
    if not BSS.findContainer(x, y, z, ctype) then
        return reply(player, "add", { ok = false, err = "nocontainer" })
    end
    if not canManage(player, square) then
        return reply(player, "add", { ok = false, err = "permission" })
    end

    local key = BSS.keyOf(x, y, z, ctype)
    local registry = BSS.getData()
    if not registry.c[key] then
        if BSS.countRegistered() >= BSS.MAX_CONTAINERS then
            return reply(player, "add", { ok = false, err = "limit" })
        end
        registry.c[key] = {
            x = x, y = y, z = z, t = ctype,
            donor = true, sink = true,
            by = player:getUsername(),
        }
        ModData.transmit(BSS.DATA_KEY)
    end
    return reply(player, "add", { ok = true, key = key, count = BSS.countRegistered() })
end

function handlers.remove(args, player)
    local x, y, z, ctype = sanitize(args)
    if not x then return reply(player, "remove", { ok = false, err = "badargs" }) end

    local square = squareOf(x, y, z)
    if not square then return reply(player, "remove", { ok = false, err = "nosquare" }) end
    if not canManage(player, square) then
        return reply(player, "remove", { ok = false, err = "permission" })
    end

    local key = BSS.keyOf(x, y, z, ctype)
    local registry = BSS.getData()
    if not registry.c[key] then
        return reply(player, "remove", { ok = false, err = "notregistered" })
    end
    registry.c[key] = nil
    ModData.transmit(BSS.DATA_KEY)
    return reply(player, "remove", { ok = true, key = key, count = BSS.countRegistered() })
end

-- Two independent roles: "donor" supplies ingredients to craft and cooking,
-- "sink" accepts items from auto-sort.
function handlers.toggle(args, player)
    local x, y, z, ctype = sanitize(args)
    local role = args and args.r
    if not x or (role ~= "donor" and role ~= "sink") then
        return reply(player, "toggle", { ok = false, err = "badargs" })
    end

    local square = squareOf(x, y, z)
    if not square then return reply(player, "toggle", { ok = false, err = "nosquare" }) end
    if not canManage(player, square) then
        return reply(player, "toggle", { ok = false, err = "permission" })
    end

    local key = BSS.keyOf(x, y, z, ctype)
    local entry = BSS.getEntry(key)
    if not entry then return reply(player, "toggle", { ok = false, err = "notregistered" }) end

    entry[role] = not BSS.hasRole(entry, role)
    ModData.transmit(BSS.DATA_KEY)
    return reply(player, "toggle", {
        ok = true, key = key, role = role,
        value = BSS.hasRole(entry, role), count = BSS.countRegistered(),
    })
end

function handlers.sync(args, player)
    return reply(player, "sync", { ok = true, count = BSS.countRegistered() })
end

-- OnClientCommand в B42 передаёт ровно четыре аргумента: module, command, player, args.
local function onClientCommand(module, command, player, args)
    if module ~= BSS.NET_MODULE then return end
    local handler = handlers[command]
    if not handler or not player then return end
    -- A malformed packet must not take down the OnClientCommand chain for other mods.
    local ok, err = pcall(handler, args, player)
    if not ok then
        print("[BaseStationStorage] command " .. tostring(command) .. " failed: " .. tostring(err))
    end
end

Events.OnClientCommand.Add(onClientCommand)

Events.OnServerStarted.Add(function()
    print("[BaseStationStorage] server ready, registered containers: " .. BSS.countRegistered())
end)
