-- LocalMods/HostingNetFix/Lua/Autorun/hosting_netfix.lua
-- Серверный сетевой фикс и синхронизатор для хостинга Barotrauma (Pterodactyl):
-- 1. Защита от падения ServerSettings.get_MissionTypes (NullReference / ArgumentNullException)
-- 2. Сжатие UDP-ответа A2S_RULES до 1 пакета (< 800 байт, защита от дропа по MTU / ТСПУ в РФ)
-- 3. Повторная синхронизация лобби (InitClientSync + ForcePropertyUpdate) после загрузки LuaCs у клиента
-- 4. Авто-выдача полного списка консольных команд администраторам из clientpermissions.xml

if not SERVER then return end

-- 1. Инициализация AllowedRandomMissionTypes при старте сервера
if Game.Server and Game.Server.ServerSettings then
    if Game.Server.ServerSettings.AllowedRandomMissionTypes == nil then
        Game.Server.ServerSettings.MissionTypes = "All"
    end
end

-- 2. Перехват геттера ServerSettings.get_MissionTypes (защита от ArgumentNullException)
Hook.Patch("Barotrauma.Networking.ServerSettings", "get_MissionTypes", function(instance, ptable)
    if instance.AllowedRandomMissionTypes == nil then
        ptable.PreventExecution = true
        ptable.ReturnValue = "All"
        return "All"
    end
end, Hook.HookMethodType.Before)

-- 3. Защита A2S_RULES от превышения MTU (1472 байт) и фильтрации фрагментированных UDP на ТСПУ РФ
Hook.Patch("Steamworks.SteamServer", "SetKey", function(instance, ptable)
    local k = tostring(ptable["Key"] or "")
    if string.sub(k, 1, 7) == "message" and k ~= "message0" and k ~= "messagecount" then
        ptable.PreventExecution = true
        return
    end
    if string.sub(k, 1, 14) == "contentpackage" then
        local idx = tonumber(string.sub(k, 15))
        if idx and idx >= 3 then
            ptable.PreventExecution = true
            return
        end
    end
end, Hook.HookMethodType.Before)

-- 4. Автоматическая досылка полного состояния лобби и выдача консольных команд админам
local function resyncClientLobby(client)
    if not client or Game.RoundStarted then return end
    pcall(function()
        if client.Connection == nil then return end
        if client.HasPermission and client.HasPermission(ClientPermissions.ConsoleCommands) then
            client.SetPermissions(client.Permissions, DebugConsole.Commands)
        end
        client.InitClientSync()
        if Game.Server and Game.Server.ServerSettings then
            Game.Server.ServerSettings.ForcePropertyUpdate()
        end
        if Game.NetLobbyScreen then
            Game.NetLobbyScreen.LastUpdateID = Game.NetLobbyScreen.LastUpdateID + 1
        end
    end)
end

Hook.Add("clientConnected", "HostingNetFix_ResyncLobby", function(client)
    Timer.Wait(function() resyncClientLobby(client) end, 1500)
    Timer.Wait(function() resyncClientLobby(client) end, 4500)
end)

print("[HostingNetFix] Загружен серверный фикс: синхронизация UI лобби, защита MissionTypes и сжатие A2S_RULES (MTU РФ).")
