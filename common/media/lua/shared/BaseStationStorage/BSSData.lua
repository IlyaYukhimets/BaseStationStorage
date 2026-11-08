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

-- Клиентская копия реестра. Сервер кладёт снапшот в каждый ответ (BSS.exportList),
-- клиент держит его в обычной Lua-таблице. Полагаться на ModData.transmit нельзя:
-- синхронизация до клиента не доходила, и вся клиентская логика (меню, список,
-- подмешивание хранилищ в крафт) молча работала по пустой таблице.
local replica = {}
local replicaReady = false

-- Единственное место, где решается "чьи данные читаем": сервер -- ModData, клиент -- копию.
local function store()
    if isServer() then return registry().c end
    return replica
end

-- Разворачивает снапшот в клиентскую копию. Формат плоский: числа, строки, булевы
-- значения -- ничего из ModData-обёрток, чтобы таблица пережила сетевую передачу.
function BSS.setReplica(list)
    replica = {}
    -- Сетевые таблицы приходят обёртками Kahlua: проверяем не type(), а индексацию и
    -- сами данные. Именно лишнее допущение о типе и дало тихий отказ в 1.2.1.
    if list ~= nil then
        for i = 1, #list do
            local item = list[i]
            local itemKey = item and item.k
            if type(itemKey) == "string" then
                replica[itemKey] = {
                    x = tonumber(item.x), y = tonumber(item.y), z = tonumber(item.z),
                    t = item.t,
                    oi = tonumber(item.oi), ci = tonumber(item.ci),
                    donor = item.d ~= false,
                    sink = item.s ~= false,
                    by = item.b,
                }
            end
        end
    end
    replicaReady = true
    return BSS.countRegistered()
end

function BSS.replicaReady()
    return replicaReady
end

-- Снапшот для клиента; вызывается только на сервере, поэтому читает ModData.
function BSS.exportList()
    local out = {}
    local containers = registry().c
    for _, key in ipairs(BSS.sortedKeys(containers)) do
        local entry = containers[key]
        if type(entry) == "table" then
            out[#out + 1] = {
                k = key,
                x = entry.x, y = entry.y, z = entry.z, t = entry.t,
                oi = entry.oi, ci = entry.ci,
                d = BSS.hasRole(entry, "donor"),
                s = BSS.hasRole(entry, "sink"),
                b = entry.by,
            }
        end
    end
    return out
end

function BSS.getEntry(key)
    if type(key) ~= "string" then return nil end
    return store()[key]
end

function BSS.countRegistered()
    local count = 0
    for _ in pairs(store()) do count = count + 1 end
    return count
end

-- Entries that may supply ingredients (donor) or receive items (sink).
function BSS.getEntries(role)
    local out = {}
    local containers = store()
    for _, key in ipairs(BSS.sortedKeys(containers)) do
        local entry = containers[key]
        if type(entry) == "table" and BSS.hasRole(entry, role) then out[#out + 1] = entry end
    end
    return out
end

-- Полный список в порядке ключей: команда "показать хранилища" и диагностика.
function BSS.allEntries()
    local out = {}
    local containers = store()
    for _, key in ipairs(BSS.sortedKeys(containers)) do
        local entry = containers[key]
        if type(entry) == "table" then out[#out + 1] = entry end
    end
    return out
end

local function squareAt(x, y, z)
    if not getCell then return nil end
    local cell = getCell()
    if not cell then return nil end
    return cell:getGridSquare(x, y, z)
end

-- Загружен ли чанк с этим квадратом. Нужно миграции: nil от findContainer означает
-- либо "контейнера нет", либо "чанк не загружен", и путать эти случаи нельзя.
function BSS.squareLoaded(x, y, z)
    return squareAt(x, y, z) ~= nil
end

-- Перебор контейнеров объекта: у мебели их бывает несколько (холодильник и морозилка),
-- поэтому getContainer() недостаточно -- он отдаёт только первый.
local function forEachContainer(object, callback)
    if not object then return end
    if object.getContainerCount then
        local count = object:getContainerCount()
        for i = 0, count - 1 do
            local container = object:getContainerByIndex(i)
            if container then callback(container, i) end
        end
        return
    end
    if object.getContainer then
        local container = object:getContainer()
        if container then callback(container, 0) end
    end
end

-- Индекс контейнера внутри родительского объекта и индекс самого объекта на квадрате.
-- Та же пара, которой игра адресует контейнер в своих клиент-серверных командах.
function BSS.containerIndexOf(container)
    local parent = container and container.getParent and container:getParent() or nil
    if not parent or not parent.getContainerCount then return nil, nil end
    local index
    for i = 0, parent:getContainerCount() - 1 do
        if parent:getContainerByIndex(i) == container then index = i end
    end
    local objectIndex = parent.getObjectIndex and parent:getObjectIndex() or nil
    return objectIndex, index
end

function BSS.findContainer(x, y, z, ctype, objectIndex, containerIndex)
    local square = squareAt(x, y, z)
    if not square then return nil end
    local objects = square:getObjects()
    if not objects then return nil end

    -- Прямое попадание по индексам: так же разрешает контейнер сам сервер игры.
    if type(objectIndex) == "number" and objectIndex >= 0 and objectIndex < objects:size() then
        local object = objects:get(objectIndex)
        local found, matched = nil, false
        forEachContainer(object, function(container, index)
            if not matched and (containerIndex == nil or index == containerIndex)
                and tostring(container:getType()) == ctype then
                found = container
                matched = true
            end
        end)
        if found then return found, object end
    end

    -- Индексы могли съехать (объект переставили): ищем по типу на том же квадрате.
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        local found = nil
        forEachContainer(object, function(container, index)
            if not found and tostring(container:getType()) == ctype
                and (containerIndex == nil or index == containerIndex) then
                found = container
            end
        end)
        if found then return found, object end
    end
    return nil
end

-- Canonical identity of a container: its square plus its container type. Bags and
-- carried containers have no source square, hence nil -- they can never be registered.
-- Пол и инвентарь персонажа -- не хранилища: игра сама исключает их из переименования
-- (ISInventoryPage:onBackpackRightMouseDown), и регистрировать их бессмысленно.
local NON_REGISTRABLE = { floor = true, inventorymale = true, inventoryfemale = true }

function BSS.keyOfContainer(container)
    if not container or not container.getSourceGrid then return nil end
    local square = container:getSourceGrid()
    if not square then return nil end
    local ctype = tostring(container:getType())
    if NON_REGISTRABLE[ctype] then return nil end
    local objectIndex, containerIndex = BSS.containerIndexOf(container)
    return BSS.keyOf(square:getX(), square:getY(), square:getZ(),
        ctype, objectIndex, containerIndex)
end

function BSS.resolve(key)
    local x, y, z, ctype, objectIndex, containerIndex = BSS.parseKey(key)
    if not x then return nil end
    return BSS.findContainer(x, y, z, ctype, objectIndex, containerIndex)
end

-- Registered entries that currently resolve to a real container in a loaded chunk.
function BSS.resolveRegistered(role)
    local out = {}
    for _, entry in ipairs(BSS.getEntries(role)) do
        local key = BSS.keyOf(entry.x, entry.y, entry.z, entry.t, entry.oi, entry.ci)
        if key then
            local container = BSS.resolve(key)
            if container then
                out[#out + 1] = { key = key, entry = entry, container = container }
            end
        end
    end
    return out
end

-- Ключи, записанные до 1.3.0, не содержат индексов и после смены формата перестали бы
-- находить свой контейнер. Переписываем их в новый вид. Запись удаляем только если чанк
-- загружен и контейнера там действительно нет: иначе на старте сервера, когда мир ещё не
-- поднят, миграция снесла бы весь реестр.
-- Сколько записей ещё в старом виде: пока их не ноль, миграцию нужно повторять,
-- потому что её результат зависит от того, какие чанки успели загрузиться.
function BSS.countLegacyKeys()
    local count = 0
    for key in pairs(registry().c) do
        if BSS.isLegacyKey(key) then count = count + 1 end
    end
    return count
end

-- Убирает запись старого вида для того же квадрата и типа. Нужна при добавлении: иначе
-- контейнер, чья запись ещё не мигрирована, попал бы в реестр дважды.
function BSS.forgetLegacySibling(x, y, z, ctype)
    local containers = registry().c
    local victims = {}
    for key in pairs(containers) do
        local ex, ey, ez, et, objectIndex = BSS.parseKey(key)
        if objectIndex == nil and ex == x and ey == y and ez == z and et == ctype then
            victims[#victims + 1] = key
        end
    end
    for i = 1, #victims do containers[victims[i]] = nil end
    return #victims
end

function BSS.migrateKeys()
    local containers = registry().c
    -- Ключи собираем заранее: вставка в таблицу во время pairs() даёт
    -- "invalid key to 'next'" на следующей итерации.
    local legacy = {}
    for key in pairs(containers) do
        if BSS.isLegacyKey(key) then legacy[#legacy + 1] = key end
    end

    local migrated, dropped = 0, 0
    for i = 1, #legacy do
        local key = legacy[i]
        local entry = containers[key]
        if type(entry) == "table" then
            local container = BSS.findContainer(entry.x, entry.y, entry.z, entry.t)
            if container then
                containers[key] = nil
                entry.oi, entry.ci = BSS.containerIndexOf(container)
                containers[BSS.keyOfContainer(container)] = entry
                migrated = migrated + 1
            elseif BSS.squareLoaded(entry.x, entry.y, entry.z) then
                containers[key] = nil
                dropped = dropped + 1
            end
        end
    end
    if migrated > 0 or dropped > 0 then
        ModData.transmit(BSS.DATA_KEY)
    end
    return migrated, dropped
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
    local playerSafehouse = BSS.safehouseAt(playerSquare)

    -- Клиент фильтрует только очевидное: он может не знать границ чужого убежища, а
    -- молча выкинуть доступное хранилище -- значит сломать крафт без объяснения.
    -- Подлинное решение принимает сервер (BSSGuard), и там правило закрыто по умолчанию.
    if not isServer() then
        if containerSafehouse and playerSafehouse
            and not BSS.sameSafehouse(playerSafehouse, containerSafehouse) then
            return false
        end
        return true
    end

    if not containerSafehouse then return false end
    local username = player:getUsername()
    if not (containerSafehouse:isOwner(username) or containerSafehouse:playerAllowed(player)) then
        return false
    end
    return BSS.sameSafehouse(playerSafehouse, containerSafehouse)
end

-- May this player use this container for the given role right now?
-- Adjacent containers are vanilla behaviour and always allowed; anything further must be a
-- registered container of that role inside the safehouse the player is standing in.
-- Admins get no shortcut here: the rule is about where you stand, not about your rank.
-- (Managing the registry is a different right and still open to admins, see BSSServer.)
function BSS.canUseRole(player, container, role)
    if not player or not container or not role then return false end

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
