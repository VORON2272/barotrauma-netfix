#!/usr/bin/env bash
# install.sh — Автоматическая установка серверного фикса HostingNetFix для Barotrauma (Pterodactyl)
# Запускается перед стартом DedicatedServer:
# curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/install.sh | tr -d '\r' | bash

set -e

MOD_DIR="LocalMods/HostingNetFix"
LUA_DIR="${MOD_DIR}/Lua/Autorun"
FILELIST_PATH="${MOD_DIR}/filelist.xml"
LUA_SCRIPT_PATH="${LUA_DIR}/hosting_netfix.lua"

mkdir -p "${LUA_DIR}"

# 1. Создаём пустой по контенту filelist.xml (HasMultiplayerSyncedContent = false,
#    поэтому игрокам НЕ нужно скачивать этот мод из Steam для входа на сервер)
cat << 'EOF' > "${FILELIST_PATH}"
<?xml version="1.0" encoding="utf-8"?>
<contentpackage name="HostingNetFix" modversion="1.0.0" corepackage="false" gameversion="1.13.5.0" />
EOF

# 2. Скачиваем актуальный серверный Lua-скрипт из репозитория (с резервной локальной записью)
if ! curl -fsSL "https://raw.githubusercontent.com/VORON2272/barotrauma-netfix/main/LocalMods/HostingNetFix/Lua/Autorun/hosting_netfix.lua" -o "${LUA_SCRIPT_PATH}" 2>/dev/null; then
cat << 'EOF' > "${LUA_SCRIPT_PATH}"
if not SERVER then return end

pcall(function() LuaUserData.RegisterType("Barotrauma.Networking.Client") end)
pcall(function() LuaUserData.RegisterType("Barotrauma.Networking.ServerSettings") end)
pcall(function() LuaUserData.RegisterType("Steamworks.SteamServer") end)

if Game.Server and Game.Server.ServerSettings then
    if Game.Server.ServerSettings.AllowedRandomMissionTypes == nil then
        Game.Server.ServerSettings.MissionTypes = "All"
    end
end

Hook.Patch("Barotrauma.Networking.ServerSettings", "get_MissionTypes", function(instance, ptable)
    if instance.AllowedRandomMissionTypes == nil then
        ptable.PreventExecution = true
        ptable.ReturnValue = "All"
        return "All"
    end
end, Hook.HookMethodType.Before)

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

local function resyncClientLobby(client)
    if not client or client.Removed or Game.RoundStarted then return end
    pcall(function() client.InitClientSync() end)
    pcall(function()
        if Game.Server and Game.Server.ServerSettings then
            Game.Server.ServerSettings.ForcePropertyUpdate()
        end
    end)
    pcall(function()
        if Game.NetLobbyScreen then
            Game.NetLobbyScreen.LastUpdateID = Game.NetLobbyScreen.LastUpdateID + 1
        end
    end)
end

Hook.Add("clientConnected", "HostingNetFix_ResyncLobby", function(client)
    Timer.Wait(function() resyncClientLobby(client) end, 1500)
    Timer.Wait(function() resyncClientLobby(client) end, 4500)
end)

print("[HostingNetFix] Loaded server-side fix for Lobby UI sync, MissionTypes & A2S_RULES MTU.")
EOF
fi

# 3. Прописываем LocalMods/HostingNetFix/filelist.xml в config_player.xml
if [ ! -f "config_player.xml" ]; then
    cat << 'EOF' > "config_player.xml"
<?xml version="1.0" encoding="utf-8"?>
<config language="Russian">
  <contentpackages>
    <!--Vanilla-->
    <corepackage path="Content/ContentPackages/Vanilla.xml" />
    <regularpackages>
      <!--HostingNetFix-->
      <package path="LocalMods/HostingNetFix/filelist.xml" />
    </regularpackages>
  </contentpackages>
</config>
EOF
elif ! grep -q "LocalMods/HostingNetFix/filelist.xml" "config_player.xml"; then
    if grep -q "<regularpackages[[:space:]]*/>" "config_player.xml"; then
        sed -i 's|<regularpackages[[:space:]]*/>|<regularpackages>\n      <!--HostingNetFix-->\n      <package path="LocalMods/HostingNetFix/filelist.xml" />\n    </regularpackages>|' "config_player.xml"
    elif grep -q "</regularpackages>" "config_player.xml"; then
        sed -i 's|</regularpackages>|  <!--HostingNetFix-->\n      <package path="LocalMods/HostingNetFix/filelist.xml" />\n    </regularpackages>|' "config_player.xml"
    fi
fi

# 4. Проверяем наличие MissionTypes="All" в serversettings.xml
if [ -f "serversettings.xml" ] && ! grep -q "MissionTypes=" "serversettings.xml"; then
    sed -i 's/<serversettings /<serversettings MissionTypes="All" /' "serversettings.xml"
fi

echo "[HostingNetFix] Mod installed in ${MOD_DIR} and registered in config_player.xml."
