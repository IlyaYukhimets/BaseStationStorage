-- Base Station Storage: client side -- registry replica, menus and feedback.
-- The client never writes the registry; it sends requests and renders the reply.

if isServer() then return end

require "BaseStationStorage/BSS"
require "BaseStationStorage/BSSData"

local function localPlayer()
    return getPlayer()
end

local function notify(text)
    local player = localPlayer()
    if player and text then HaloTextHelper.addText(player, text) end
end

-- Global ModData is synced to the client on join and on every ModData.transmit();
-- priming it here matches the vanilla forageClient pattern.
Events.OnInitGlobalModData.Add(function()
    ModData.getOrCreate(BSS.DATA_KEY)
end)

local function send(command, payload)
    local player = localPlayer()
    if not player then return end
    sendClientCommand(player, BSS.NET_MODULE, command, payload)
end

local function payloadFor(container)
    local key = BSS.keyOfContainer(container)
    if not key then return nil end
    local x, y, z, ctype = BSS.parseKey(key)
    if not x then return nil end
    return { x = x, y = y, z = z, t = ctype }, key
end

local function onOff(value)
    if value then return getText("UI_BSS_On") end
    return getText("UI_BSS_Off")
end

local function showRegistry()
    local registry = BSS.getData()
    local keys = BSS.sortedKeys(registry.c)
    print("[BaseStationStorage] registered containers: " .. #keys)
    for i = 1, #keys do
        local entry = registry.c[keys[i]]
        print(string.format("  %s donor=%s sink=%s by=%s",
            BSS.label(entry), tostring(BSS.hasRole(entry, "donor")),
            tostring(BSS.hasRole(entry, "sink")), tostring(entry.by)))
    end
    notify(string.format(getText("UI_BSS_ListCount"), #keys))
end

-- One submenu, same place for every container: add/remove, the two roles, sort.
local function fillBaseMenu(context, playerObj, container, asSource)
    local payload, key = payloadFor(container)
    if not payload then return end
    local entry = BSS.getEntry(key)

    local root = context:addOption(getText("UI_BSS_Menu"), nil, nil)
    local submenu = context:getNew(context)
    context:addSubMenu(root, submenu)

    if entry then
        submenu:addOption(string.format(getText("UI_BSS_ToggleDonor"), onOff(BSS.hasRole(entry, "donor"))),
            playerObj, function(player) send("toggle", { x = payload.x, y = payload.y, z = payload.z, t = payload.t, r = "donor" }) end)
        submenu:addOption(string.format(getText("UI_BSS_ToggleSink"), onOff(BSS.hasRole(entry, "sink"))),
            playerObj, function(player) send("toggle", { x = payload.x, y = payload.y, z = payload.z, t = payload.t, r = "sink" }) end)
        submenu:addOption(getText("UI_BSS_Remove"), playerObj,
            function(player) send("remove", payload) end)
    else
        local option = submenu:addOption(getText("UI_BSS_Add"), playerObj,
            function(player) send("add", payload) end)
        if ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.addToolTip then
            local tooltip = ISInventoryPaneContextMenu.addToolTip()
            tooltip.description = getText("UI_BSS_AddTooltip")
            option.toolTip = tooltip
        end
    end

    if asSource then
        submenu:addOption(getText("UI_BSS_Sort"), playerObj,
            function(player) BSSSort.distribute(player, container) end)
    end

    submenu:addOption(getText("UI_BSS_List"), playerObj, showRegistry)
end

-- Right-click the crate/fridge/cabinet itself. This is the way to register an empty
-- container: the loot-window route would need at least one item inside.
Events.OnFillWorldObjectContextMenu.Add(function(playerNum, context, worldobjects, test)
    if test or not context or not worldobjects then return end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end

    local seen = {}
    for i = 1, #worldobjects do
        local object = worldobjects[i]
        if object and object.getContainer then
            local container = object:getContainer()
            if container then
                local key = BSS.keyOfContainer(container)
                if key and not seen[key] then
                    seen[key] = true
                    fillBaseMenu(context, playerObj, container, true)
                    return
                end
            end
        end
    end
end)

-- Right-click your own inventory: distribute what you carry over the registered sinks.
Events.OnFillInventoryObjectContextMenu.Add(function(playerNum, context, items)
    if not context or not items or #items == 0 then return end
    local playerObj = getSpecificPlayer(playerNum)
    if not playerObj then return end

    local item = items[1]
    local container = item and item.getContainer and item:getContainer() or nil
    if not container then return end
    local parent = container.getParent and container:getParent() or nil
    if not parent or not instanceof(parent, "IsoPlayer") then return end

    local option = context:addOption(getText("UI_BSS_SortInventory"), playerObj,
        function(player) BSSSort.distribute(player, player:getInventory()) end)
    if option and ISInventoryPaneContextMenu and ISInventoryPaneContextMenu.addToolTip then
        local tooltip = ISInventoryPaneContextMenu.addToolTip()
        tooltip.description = getText("UI_BSS_SortInventoryTooltip")
        option.toolTip = tooltip
    end
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= BSS.NET_MODULE then return end
    if type(args) ~= "table" then return end

    if command == "denied" then
        notify(getText("UI_BSS_Deny_" .. tostring(args.err)))
        return
    end
    if command ~= "reply" then return end

    if not args.ok then
        notify(getText("UI_BSS_Err_" .. tostring(args.err)))
        return
    end

    if args.cmd == "add" then
        notify(string.format(getText("UI_BSS_Added"), args.count or 0))
    elseif args.cmd == "remove" then
        notify(string.format(getText("UI_BSS_Removed"), args.count or 0))
    elseif args.cmd == "toggle" then
        notify(string.format(getText("UI_BSS_Toggled"), getText("UI_BSS_" .. (args.role == "donor" and "RoleDonor" or "RoleSink")), onOff(args.value)))
    elseif args.cmd == "sync" then
        notify(string.format(getText("UI_BSS_ListCount"), args.count or 0))
    end
end)
