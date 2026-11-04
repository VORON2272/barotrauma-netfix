-- LocalMods/HostingNetFix/Lua/Autorun/hosting_netfix.lua
-- Серверный сетевой фикс и применение всех настроек панели Pterodactyl внутри LuaCs:
-- 1. Применение всех настроек из панели (TickRate, MaxPlayers, ServerName, Боты, Режим и т.д.) напрямую в Game.Server.ServerSettings
-- 2. Защита от падения ServerSettings.get_MissionTypes (NullReference / ArgumentNullException)
-- 3. Сжатие UDP-ответа A2S_RULES до 1 пакета (< 800 байт, защита от дропа по MTU / ТСПУ в РФ)
-- 4. Повторная синхронизация лобби (InitClientSync + ForcePropertyUpdate) после загрузки LuaCs у клиента
-- 5. Авто-выдача полного списка консольных команд администраторам (OWNER_STEAMID)

if not SERVER then return end

local modPath = ...

-- 1. Применяем все настройки из панели Pterodactyl (LocalMods/HostingNetFix/Lua/panel_settings.lua) напрямую в движок
local function applyPanelSettings()
    if not Game.Server or not Game.Server.ServerSettings then return end
    local ss = Game.Server.ServerSettings

    if ss.AllowedRandomMissionTypes == nil then
        ss.MissionTypes = "All"
    end

    local ok, cfg = pcall(function()
        if modPath and File.Exists(modPath .. "/Lua/panel_settings.lua") then
            return dofile(modPath .. "/Lua/panel_settings.lua")
        elseif File.Exists("LocalMods/HostingNetFix/Lua/panel_settings.lua") then
            return dofile("LocalMods/HostingNetFix/Lua/panel_settings.lua")
        end
        return nil
    end)

    if ok and type(cfg) == "table" then
        pcall(function() if cfg.ServerName and cfg.ServerName ~= "" then ss.ServerName = cfg.ServerName end end)
        pcall(function() if cfg.ServerMessage and cfg.ServerMessage ~= "" then ss.ServerMessageText = cfg.ServerMessage end end)
        pcall(function() if cfg.MaxPlayers then ss.MaxPlayers = tonumber(cfg.MaxPlayers) or ss.MaxPlayers end end)
        pcall(function() if cfg.TickRate then ss.TickRate = math.max(1, math.min(60, tonumber(cfg.TickRate) or 60)) end end)
        pcall(function() if cfg.IsPublic ~= nil then ss.IsPublic = cfg.IsPublic end end)
        pcall(function() if cfg.AllowFriendlyFire ~= nil then ss.AllowFriendlyFire = cfg.AllowFriendlyFire end end)
        pcall(function() if cfg.AllowRewiring ~= nil then ss.AllowRewiring = cfg.AllowRewiring end end)
        pcall(function() if cfg.AllowSpectating ~= nil then ss.AllowSpectating = cfg.AllowSpectating end end)
        pcall(function() if cfg.RespawnInterval then ss.RespawnInterval = tonumber(cfg.RespawnInterval) or ss.RespawnInterval end end)
        pcall(function() if cfg.TraitorProbability then ss.TraitorProbability = tonumber(cfg.TraitorProbability) or ss.TraitorProbability end end)
        pcall(function()
            if cfg.BotCount then
                ss.BotCount = tonumber(cfg.BotCount) or 0
                if Game.NetLobbyScreen then Game.NetLobbyScreen.SetBotCount(ss.BotCount) end
            end
        end)
        pcall(function() if cfg.KarmaEnabled ~= nil then ss.KarmaEnabled = cfg.KarmaEnabled end end)
        pcall(function() if cfg.AutoRestart ~= nil then ss.AutoRestart = cfg.AutoRestart end end)
        pcall(function() if cfg.VoiceChatEnabled ~= nil then ss.VoiceChatEnabled = cfg.VoiceChatEnabled end end)
        pcall(function()
            if cfg.GameModeIdentifier and cfg.GameModeIdentifier ~= "" then
                ss.GameModeIdentifier = Identifier(cfg.GameModeIdentifier)
                if Game.NetLobbyScreen then Game.NetLobbyScreen.SelectedModeIdentifier = ss.GameModeIdentifier end
            end
        end)
        pcall(function() ss.ForcePropertyUpdate() end)
        pcall(function() ss.SaveSettings() end)
        print("[HostingNetFix] Настройки панели Pterodactyl применены напрямую в ServerSettings (TickRate=" .. tostring(ss.TickRate) .. ", MaxPlayers=" .. tostring(ss.MaxPlayers) .. ").")
    end
end

applyPanelSettings()

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

print("[HostingNetFix] Загружен серверный фикс: синхронизация UI лобби, настройки панели, защита MissionTypes и сжатие A2S_RULES (MTU РФ).")
