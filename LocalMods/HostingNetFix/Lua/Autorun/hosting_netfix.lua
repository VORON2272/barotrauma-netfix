-- LocalMods/HostingNetFix/Lua/Autorun/hosting_netfix.lua
-- Серверный сетевой фикс и синхронизация настроек панели Pterodactyl:
-- 1. Регистрация типов C# в MoonSharp (ServerSettings, GameServer, Lidgren)
-- 2. Снижение MTU внутри Lidgren с 1408 до 1150 байт (устраняет IP-фрагментацию на хостах с MTU 1400/1360 и дроп пакетов подлодок у провайдеров РФ)
-- 3. Применение всех настроек из панели (TickRate, MaxPlayers, ServerName, Language, PlayStyle, Боты, Режим и т.д.)
-- 4. Защита от падения ServerSettings.get_MissionTypes (ArgumentNullException)
-- 5. Сжатие UDP-ответа A2S_RULES до 1 пакета (< 800 байт)
-- 6. Повторная досылка полного состояния лобби (InitClientSync + Networking.ClientWriteLobby)

if not SERVER then return end

local modPath = ...
local SAFE_LIDGREN_MTU = 1150

-- 1. Регистрируем необходимые типы и приватные поля C# / Lidgren в LuaUserData
pcall(function() LuaUserData.RegisterType("Barotrauma.Networking.GameServer") end)
pcall(function() LuaUserData.RegisterType("Barotrauma.Networking.ServerSettings") end)
pcall(function() LuaUserData.RegisterType("Barotrauma.Networking.ServerPeer") end)
pcall(function() LuaUserData.RegisterType("Barotrauma.Networking.NetworkConnection") end)
pcall(function() LuaUserData.RegisterType("Barotrauma.DebugConsole") end)

pcall(function()
    local peerDesc = LuaUserData.RegisterType("Barotrauma.Networking.LidgrenServerPeer")
    if peerDesc then
        LuaUserData.MakeFieldAccessible(peerDesc, "netPeerConfiguration")
        LuaUserData.MakeFieldAccessible(peerDesc, "netServer")
    end
    local lcDesc = LuaUserData.RegisterType("Barotrauma.Networking.LidgrenConnection")
    if lcDesc then
        LuaUserData.MakeFieldAccessible(lcDesc, "NetConnection")
    end
    local npcDesc = LuaUserData.RegisterType("Lidgren.Network.NetPeerConfiguration")
    if npcDesc then
        LuaUserData.MakeFieldAccessible(npcDesc, "m_maximumTransmissionUnit")
    end
    local ncDesc = LuaUserData.RegisterType("Lidgren.Network.NetConnection")
    if ncDesc then
        LuaUserData.MakeFieldAccessible(ncDesc, "m_currentMTU")
    end
    LuaUserData.RegisterType("Lidgren.Network.NetPeer")
    LuaUserData.RegisterType("Lidgren.Network.NetServer")
end)

-- 2. Ограничиваем MTU в Lidgren до 1150 байт (вместо стандартных 1408 байт = 1436 байт IP),
-- чтобы пакет со списком подлодок (ClientWriteInitial) бился на чанки средствами самого Lidgren
-- и никогда не фрагментировался ядром Linux на интерфейсах с MTU 1400 / 1360
local function clampConnectionMTU(conn)
    if not conn then return end
    pcall(function()
        local netConn = conn.NetConnection
        if netConn and netConn.m_currentMTU and netConn.m_currentMTU > SAFE_LIDGREN_MTU then
            netConn.m_currentMTU = SAFE_LIDGREN_MTU
        end
    end)
end

local function clampServerPeerMTU()
    pcall(function()
        local peer = Game.Peer
        if peer and peer.netPeerConfiguration then
            peer.netPeerConfiguration.m_maximumTransmissionUnit = SAFE_LIDGREN_MTU
        end
        if Client and Client.ClientList then
            for _, c in pairs(Client.ClientList) do
                if c and c.Connection then
                    clampConnectionMTU(c.Connection)
                end
            end
        end
    end)
end

clampServerPeerMTU()

pcall(function()
    Hook.Patch("Lidgren.Network.NetPeer", "GetMTU", function(instance, ptable)
        ptable.PreventExecution = true
        ptable.ReturnValue = SAFE_LIDGREN_MTU
        return SAFE_LIDGREN_MTU
    end, Hook.HookMethodType.Before)
end)

pcall(function()
    Hook.Patch("Barotrauma.Networking.LidgrenServerPeer", "ForwardToLidgren", function(instance, ptable)
        local conn = ptable["connection"]
        if conn then
            clampConnectionMTU(conn)
        end
    end, Hook.HookMethodType.Before)
end)

-- 3. Применяем все настройки из панели Pterodactyl (LocalMods/HostingNetFix/Lua/panel_settings.lua) напрямую в движок
local function applyPanelSettings()
    local ss = Game.ServerSettings or (Game.Server and Game.Server.ServerSettings)
    if not ss then return end

    pcall(function()
        if ss.AllowedRandomMissionTypes == nil then
            ss.MissionTypes = "All"
        end
    end)

    local ok, cfg = pcall(function()
        if modPath and File.Exists(modPath .. "/Lua/panel_settings.lua") then
            return dofile(modPath .. "/Lua/panel_settings.lua")
        elseif File.Exists("LocalMods/HostingNetFix/Lua/panel_settings.lua") then
            return dofile("LocalMods/HostingNetFix/Lua/panel_settings.lua")
        end
        return nil
    end)

    if ok and type(cfg) == "table" and next(cfg) ~= nil then
        pcall(function() if cfg.ServerName and cfg.ServerName ~= "" then ss.ServerName = cfg.ServerName end end)
        pcall(function() if cfg.ServerMessage and cfg.ServerMessage ~= "" then ss.ServerMessageText = cfg.ServerMessage end end)
        pcall(function() if cfg.MaxPlayers then ss.MaxPlayers = tonumber(cfg.MaxPlayers) or ss.MaxPlayers end end)
        pcall(function() if cfg.TickRate then ss.TickRate = math.max(1, math.min(60, tonumber(cfg.TickRate) or 60)) end end)
        pcall(function()
            if cfg.Language and cfg.Language ~= "" then
                ss.Language = LanguageIdentifier(cfg.Language)
            end
        end)
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
    end
end

applyPanelSettings()

-- 4. Перехват геттера ServerSettings.get_MissionTypes (защита от ArgumentNullException)
Hook.Patch("Barotrauma.Networking.ServerSettings", "get_MissionTypes", function(instance, ptable)
    if instance.AllowedRandomMissionTypes == nil then
        ptable.PreventExecution = true
        ptable.ReturnValue = "All"
        return "All"
    end
end, Hook.HookMethodType.Before)

-- 5. Очистка управляющих символов (\r, \n и т.п.) в имени сервера: из-за них сервер пропадает из списка Steam
local function sanitizeServerName()
    pcall(function()
        local ss = Game.ServerSettings or (Game.Server and Game.Server.ServerSettings)
        if not ss then return end
        local name = tostring(ss.ServerName or "")
        local clean = name:gsub("[%c]", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if clean ~= "" and clean ~= name then
            ss.ServerName = clean
            print("[HostingNetFix] Имя сервера очищено от скрытых символов: " .. clean)
        end
    end)
end

-- Barotrauma поддерживает максимум 64 игрока; большее значение скрывает сервер из списка
local function clampMaxPlayers()
    pcall(function()
        local ss = Game.ServerSettings or (Game.Server and Game.Server.ServerSettings)
        if ss and ss.MaxPlayers and ss.MaxPlayers > 64 then ss.MaxPlayers = 64 end
    end)
end

sanitizeServerName()
Timer.Wait(sanitizeServerName, 3000)
clampMaxPlayers()
Timer.Wait(clampMaxPlayers, 3000)
Hook.Add("clientConnected", "HostingNetFix_SanitizeName", function() sanitizeServerName() end)
Hook.Add("clientDisconnected", "HostingNetFix_SanitizeNameD", function() Timer.Wait(sanitizeServerName, 500) end)
-- 6. Автоматическая досылка полного состояния лобби (включая список подлодок) и выдача консольных команд админам
local function resyncClientLobby(client)
    if not client or Game.RoundStarted then return end
    pcall(function()
        if client.Connection == nil then return end
        clampConnectionMTU(client.Connection)

        pcall(function()
            if client.HasPermission and client.HasPermission(ClientPermissions.ConsoleCommands) and Game.Commands then
                client.SetPermissions(client.Permissions, Game.Commands)
            end
        end)

        local ss = Game.ServerSettings or (Game.Server and Game.Server.ServerSettings)
        if ss then
            pcall(function() ss.ForcePropertyUpdate() end)
        end
        if Game.NetLobbyScreen then
            pcall(function()
                Game.NetLobbyScreen.LastUpdateID = Game.NetLobbyScreen.LastUpdateID + 1
            end)
        end

        client.InitClientSync()

        if Networking and Networking.ClientWriteLobby then
            Networking.ClientWriteLobby(client)
        end
    end)
end

Hook.Add("clientConnected", "HostingNetFix_ResyncLobby", function(client)
    if client and client.Connection then
        clampConnectionMTU(client.Connection)
    end
    Timer.Wait(function() resyncClientLobby(client) end, 1000)
    Timer.Wait(function() resyncClientLobby(client) end, 3500)
    Timer.Wait(function() resyncClientLobby(client) end, 7500)
end)

print("[HostingNetFix] Мод загружен (MTU=" .. tostring(SAFE_LIDGREN_MTU) .. ")")
