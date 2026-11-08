-- Base Station Storage: namespace, constants, pure helpers.
-- Deliberately free of world and ModData access: tests/logic_test.lua executes this
-- file outside the game, so anything touching the engine belongs in BSSData.lua.

BSS = BSS or {}
local BSS = BSS

BSS.MOD_ID       = "BaseStationStorage"
BSS.VERSION      = "1.3.2"
BSS.NET_MODULE   = "BaseStationStorage"
BSS.DATA_KEY     = "BaseStationStorageData"
BSS.DATA_VERSION = 1

BSS.MAX_CONTAINERS = 256

-- Containers this close to the player are trusted without registration. It equals the
-- reach of an opened loot window, so wrapping the vanilla craft funnel can only ever
-- add containers, never take away something the player could already use.
BSS.TRUST_RADIUS = 3

-- One auto-sort run plans every move before executing; the execution itself is the
-- vanilla bulk transfer, which already queues one action per item.

-- Квадрата и типа контейнера недостаточно: два ящика, стоящих друг на друге, и
-- половины холодильника (холодильник/морозилка) давали одинаковый ключ, и реестр
-- считал их одним хранилищем. Игра в своих сетевых командах адресует контейнер той же
-- тройкой, что и мы: getObjectIndex() родительского объекта + индекс контейнера в нём
-- (см. ISInventoryPage.lua, clearContainerExplore в ClientCommands.lua).
-- Два паттерна, а не один с необязательной группой: в Lua-паттернах "?" применяется
-- только к одиночному символу или классу, но не к захвату "(...)", поэтому
-- "(#(%d+):(%d+))?$" не совпадает ни с чем.
local KEY_PATTERN_FULL = "^world:(%-?%d+),(%-?%d+),(%-?%d+):([%w_%-%.]+)#(%-?%d+):(%-?%d+)$"
local KEY_PATTERN_BASE = "^world:(%-?%d+),(%-?%d+),(%-?%d+):([%w_%-%.]+)$"

-- Индексные части необязательны: ключи, записанные до 1.3.0, читаются как раньше и
-- переносятся в новый вид при старте сервера.
function BSS.keyOf(x, y, z, ctype, objectIndex, containerIndex)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    if not BSS.isValidContainerType(ctype) then return nil end
    local base = string.format("world:%d,%d,%d:%s", x, y, z, ctype)
    if type(objectIndex) == "number" and type(containerIndex) == "number" then
        return base .. string.format("#%d:%d", objectIndex, containerIndex)
    end
    return base
end

function BSS.parseKey(key)
    if type(key) ~= "string" then return nil end
    local x, y, z, ctype, objectIndex, containerIndex = key:match(KEY_PATTERN_FULL)
    if x then
        return tonumber(x), tonumber(y), tonumber(z), ctype,
            tonumber(objectIndex), tonumber(containerIndex)
    end
    x, y, z, ctype = key:match(KEY_PATTERN_BASE)
    if not x then return nil end
    return tonumber(x), tonumber(y), tonumber(z), ctype, nil, nil
end

-- Ключ старого вида: без пары "#объект:контейнер".
function BSS.isLegacyKey(key)
    local x, _, _, _, objectIndex = BSS.parseKey(key)
    return x ~= nil and objectIndex == nil
end

-- Container type becomes part of the registry key, so ":" and "," must never slip in.
function BSS.isValidContainerType(ctype)
    if type(ctype) ~= "string" or ctype == "" then return false end
    return ctype:match("^[%w_%-%.]+$") ~= nil
end

function BSS.isAdminLevel(level)
    return level == "admin" or level == "moderator"
end

-- Vertical reach is far shorter than horizontal in this game (one floor is a lot),
-- so a Z step counts as three tiles.
function BSS.chebyshev(ax, ay, az, bx, by, bz)
    if type(ax) ~= "number" or type(bx) ~= "number" then return nil end
    if type(ay) ~= "number" or type(by) ~= "number" then return nil end
    local dx = math.abs(ax - bx)
    local dy = math.abs(ay - by)
    local dz = math.abs((az or 0) - (bz or 0)) * 3
    return math.max(dx, dy, dz)
end

function BSS.isWithin(ax, ay, az, bx, by, bz, radius)
    local distance = BSS.chebyshev(ax, ay, az, bx, by, bz)
    if distance == nil then return false end
    return distance <= (radius or BSS.TRUST_RADIUS)
end

function BSS.sortedKeys(map)
    local out = {}
    if type(map) ~= "table" then return out end
    for key in pairs(map) do out[#out + 1] = key end
    table.sort(out)
    return out
end

-- Roles are stored as explicit booleans; a missing flag means "enabled", so an entry
-- saved by an older build keeps working.
function BSS.hasRole(entry, role)
    if type(entry) ~= "table" then return false end
    return entry[role] ~= false
end

-- Sort target selection, pure so the rule is testable outside the game.
-- candidates: array of { key = string, free = number, types = set of item full types },
-- in registration order. The rule is "same item type first, then first container with
-- room" -- predictable, and it consolidates stacks instead of scattering them.
function BSS.pickSortTarget(candidates, fullType, weight)
    if type(candidates) ~= "table" then return nil end
    weight = tonumber(weight) or 0

    -- 1) Туда, где такой предмет уже лежит: стопки сливаются, а не расползаются.
    local mergeInto = nil
    for i = 1, #candidates do
        local candidate = candidates[i]
        if (candidate.free or 0) >= weight and candidate.types and fullType and candidate.types[fullType] then
            if not mergeInto or (candidate.free or 0) > (mergeInto.free or 0) then mergeInto = candidate end
        end
    end
    if mergeInto then return mergeInto end

    -- 2) Иначе -- самый свободный: раскладка ложится кучно, а не по первому попавшемуся.
    local best = nil
    for i = 1, #candidates do
        local candidate = candidates[i]
        if (candidate.free or 0) >= weight then
            if not best or (candidate.free or 0) > (best.free or 0) then best = candidate end
        end
    end
    return best
end

-- Applies one planned transfer to the candidate view so the next item in the same run
-- sees the reduced room and the freshly added type.
function BSS.reserveCapacity(candidate, fullType, weight)
    if type(candidate) ~= "table" then return end
    candidate.free = (candidate.free or 0) - (tonumber(weight) or 0)
    if fullType then
        candidate.types = candidate.types or {}
        candidate.types[fullType] = true
    end
end

-- Same safehouse rectangle. The game returns SafeHouse objects that are not guaranteed
-- to be the same instance on every lookup, so identity is compared by bounds.
function BSS.sameRectangle(ax, ay, ax2, ay2, bx, by, bx2, by2)
    if not (ax and ay and ax2 and ay2 and bx and by and bx2 and by2) then return false end
    return ax == bx and ay == by and ax2 == bx2 and ay2 == by2
end
