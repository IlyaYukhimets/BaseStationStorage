-- Unit tests for the pure part of Base Station Storage.
-- Run outside the game: lua5.1 tests/logic_test.lua
-- Only BSS.lua takes part; ModData is a stand-in so BSSData.lua can be loaded and the
-- registry accessors exercised without a running client or server.

package.path = "common/media/lua/shared/?.lua;" .. package.path

local failures = 0
local checks = 0

local function check(condition, message)
    checks = checks + 1
    if not condition then
        failures = failures + 1
        print("FAIL: " .. message)
    end
end

local function equal(actual, expected, message)
    checks = checks + 1
    if actual ~= expected then
        failures = failures + 1
        print(string.format("FAIL: %s (expected %s, got %s)", message, tostring(expected), tostring(actual)))
    end
end

-- Minimal engine stand-ins -------------------------------------------------------------
local modDataStore = {}
ModData = {
    getOrCreate = function(key)
        modDataStore[key] = modDataStore[key] or {}
        return modDataStore[key]
    end,
    transmit = function(key) return key end,
}
getText = function(key) return key end
getCell = nil

-- Сторона исполнения переключается в тестах: сервер читает ModData, клиент -- снапшот.
local serverSide = true
isServer = function() return serverSide end

require "BaseStationStorage/BSS"
require "BaseStationStorage/BSSData"

-- Keys ---------------------------------------------------------------------------------
local key = BSS.keyOf(8137, 12045, 0, "crate")
equal(key, "world:8137,12045,0:crate", "keyOf builds the canonical key")
local x, y, z, ctype = BSS.parseKey(key)
equal(x, 8137, "parseKey x")
equal(y, 12045, "parseKey y")
equal(z, 0, "parseKey z")
equal(ctype, "crate", "parseKey type")
equal(BSS.parseKey("world:1,2:crate"), nil, "parseKey rejects malformed keys")
equal(BSS.parseKey("world:1,2,3:cr:ate"), nil, "parseKey rejects a type containing ':'")
equal(BSS.keyOf(1, 2, 3, "fr:idge"), nil, "keyOf rejects a type with the key separator")
equal(BSS.keyOf(1, 2, 3, ""), nil, "keyOf rejects an empty type")
equal(BSS.keyOf("1", 2, 3, "crate"), nil, "keyOf rejects non-numeric coordinates")
equal(BSS.parseKey(BSS.keyOf(-10, -20, -3, "freezer")), -10, "negative coordinates survive a round trip")

-- Permissions ------------------------------------------------------------------------
check(BSS.isAdminLevel("admin"), "admin is privileged")
check(BSS.isAdminLevel("moderator"), "moderator is privileged")
check(not BSS.isAdminLevel("user"), "a plain user is not privileged")
check(not BSS.isAdminLevel(nil), "missing level is not privileged")

-- Distance ---------------------------------------------------------------------------
equal(BSS.chebyshev(0, 0, 0, 3, 0, 0), 3, "chebyshev horizontal")
equal(BSS.chebyshev(0, 0, 0, 0, 0, 1), 3, "one floor counts as three tiles")
check(BSS.isWithin(0, 0, 0, 3, 0, 0), "three tiles is within the trust radius")
check(not BSS.isWithin(0, 0, 0, 4, 0, 0), "four tiles is outside the trust radius")
check(not BSS.isWithin(0, 0, 0, 0, 0, 2), "two floors is outside the trust radius")
check(not BSS.isWithin(nil, 0, 0, 1, 1, 1), "unknown position is never within reach")

-- Registry ---------------------------------------------------------------------------
local registry = BSS.getData()
registry.c["world:1,1,0:crate"] = { x = 1, y = 1, z = 0, t = "crate", donor = true, sink = false }
registry.c["world:2,2,0:fridge"] = { x = 2, y = 2, z = 0, t = "fridge" }
equal(BSS.countRegistered(), 2, "two containers registered")
equal(#BSS.getEntries("donor"), 2, "missing role flag means enabled")
equal(#BSS.getEntries("sink"), 1, "explicitly disabled role is honoured")
check(BSS.getEntry("world:2,2,0:fridge") ~= nil, "entry lookup by key")
equal(BSS.getEntry("world:9,9,9:crate"), nil, "unknown key returns nil")
equal(BSS.getEntry(nil), nil, "nil key returns nil")

-- Snapshot round trip: то, что сервер отправляет клиенту -------------------------------
local exported = BSS.exportList()
equal(#exported, 2, "exportList covers every registered container")
equal(exported[1].k, "world:1,1,0:crate", "exportList is ordered by key")
equal(exported[1].d, true, "exportList carries the donor flag")
equal(exported[1].s, false, "exportList carries the disabled sink flag")
equal(exported[2].d, true, "a missing role flag exports as enabled")

serverSide = false -- с этого момента читаем как клиент
equal(BSS.countRegistered(), 0, "a client starts with an empty replica")
equal(BSS.getEntry("world:1,1,0:crate"), nil, "the replica is empty before the snapshot")
BSS.setReplica(exported)
check(BSS.replicaReady(), "the replica is marked ready after the snapshot")
equal(BSS.countRegistered(), 2, "the snapshot fills the replica")
equal(BSS.getEntry("world:1,1,0:crate").sink, false, "a disabled role survives the snapshot")
equal(BSS.getEntry("world:2,2,0:fridge").donor, true, "a missing role means enabled after the snapshot")
equal(#BSS.getEntries("sink"), 1, "getEntries filters the replica")
equal(#BSS.allEntries(), 2, "allEntries lists the replica")
BSS.setReplica({ { k = "broken" }, { k = 5 }, "мусор" })
equal(BSS.countRegistered(), 1, "malformed snapshot entries are dropped, valid ones kept")
BSS.setReplica({})
equal(BSS.countRegistered(), 0, "an empty snapshot clears the replica")
serverSide = true

-- Safehouse rule: сервер закрыт по умолчанию, клиент не блокирует крафт вслепую --------
local function square(x, y)
    return { getX = function() return x end, getY = function() return y end, getZ = function() return 0 end }
end
local player = { getUsername = function() return "bobr" end, getCurrentSquare = function() return square(10, 10) end }

SafeHouse = { getSafeHouse = function() return nil end }
serverSide = true
check(not BSS.canReachBase(player, square(10, 10), square(10, 10)), "server: no safehouse means no access")
serverSide = false
check(BSS.canReachBase(player, square(10, 10), square(10, 10)), "client: unknown safehouse does not block crafting")

local houseA = {
    getX = function() return 0 end, getY = function() return 0 end,
    getX2 = function() return 20 end, getY2 = function() return 20 end,
    isOwner = function(_, who) return who == "bobr" end,
    playerAllowed = function() return true end,
}
local houseB = {
    getX = function() return 100 end, getY = function() return 100 end,
    getX2 = function() return 120 end, getY2 = function() return 120 end,
    isOwner = function() return false end,
    playerAllowed = function() return false end,
}
SafeHouse = { getSafeHouse = function(s) return (s:getX() < 50) and houseA or houseB end }

serverSide = true
check(BSS.canReachBase(player, square(10, 10), square(12, 12)), "server: owner inside the safehouse is allowed")
check(not BSS.canReachBase(player, square(110, 110), square(12, 12)), "server: standing elsewhere is denied")
serverSide = false
check(not BSS.canReachBase(player, square(110, 110), square(12, 12)), "client: crafting from a foreign safehouse is hidden")
check(BSS.canReachBase(player, square(10, 10), square(12, 12)), "client: own safehouse passes")
serverSide = true

local keys = BSS.sortedKeys(registry.c)
equal(keys[1], "world:1,1,0:crate", "sortedKeys is deterministic")

-- Safehouse comparison ---------------------------------------------------------------
check(BSS.sameRectangle(0, 0, 10, 10, 0, 0, 10, 10), "identical rectangles match")
check(not BSS.sameRectangle(0, 0, 10, 10, 1, 0, 11, 10), "shifted rectangle does not match")
check(not BSS.sameRectangle(0, 0, 10, 10, 0, 0, 10, 11), "resized rectangle does not match")
check(not BSS.sameRectangle(0, 0, 10, 10, nil, 0, 10, 10), "missing bound never matches")

-- Sort planning ----------------------------------------------------------------------
local crate = { key = "a", free = 5, types = { ["Base.Nails"] = true } }
local fridge = { key = "b", free = 20, types = { ["Base.Steak"] = true } }
local full = { key = "c", free = 0, types = {} }
local candidates = { full, fridge, crate }

equal(BSS.pickSortTarget(candidates, "Base.Nails", 1).key, "a", "same item type wins over free space")
equal(BSS.pickSortTarget(candidates, "Base.Saw", 1).key, "b", "unknown type goes to the first container with room")
equal(BSS.pickSortTarget(candidates, "Base.Saw", 25), nil, "nothing is chosen when no container has room")
equal(BSS.pickSortTarget(nil, "Base.Saw", 1), nil, "no candidates means no target")

BSS.reserveCapacity(crate, "Base.Saw", 3)
equal(crate.free, 2, "reserveCapacity reduces free space")
check(crate.types["Base.Saw"], "reserveCapacity records the new type")
equal(BSS.pickSortTarget({ crate }, "Base.Saw", 2).key, "a", "second item of the same type reuses the container")
equal(BSS.pickSortTarget({ crate }, "Base.Saw", 3), nil, "reserved space is respected")

-- ------------------------------------------------------------------------------------
print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
