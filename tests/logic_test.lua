-- Unit tests for the pure part of Base Station Storage.
-- Run outside the game: lua5.1 tests/logic_test.lua
-- Only BSS.lua takes part; ModData is a stand-in so BSSData.lua can be loaded and the
-- registry accessors exercised without a running client or server.

package.path = "media/lua/shared/?.lua;" .. package.path

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

local keys = BSS.sortedKeys(registry.c)
equal(keys[1], "world:1,1,0:crate", "sortedKeys is deterministic")

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
