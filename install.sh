#!/usr/bin/env bash
# install.sh — Автоматическая установка серверного фикса HostingNetFix и синхронизация настроек панели Pterodactyl для Barotrauma
# Запускается перед стартом DedicatedServer:
# curl -fsSL https://raw.githubusercontent.com/VORON2272/barotrauma-netfix/main/install.sh | tr -d '\r' | bash

MOD_DIR="LocalMods/HostingNetFix"
LUA_DIR="${MOD_DIR}/Lua/Autorun"
FILELIST_PATH="${MOD_DIR}/filelist.xml"
LUA_SCRIPT_PATH="${LUA_DIR}/hosting_netfix.lua"
PANEL_LUA_PATH="${MOD_DIR}/Lua/panel_settings.lua"
SNAPSHOT_FILE="${MOD_DIR}/.panel_env_snapshot"
SETTINGS_FILE="serversettings.xml"

mkdir -p "${LUA_DIR}"

if [ "${ENABLE_NETFIX:-1}" = "1" ]; then
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

local modPath = ...
local SAFE_LIDGREN_MTU = 1150

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
EOF
fi
else
    rm -rf "${MOD_DIR}" 2>/dev/null || true
    if [ -f "config_player.xml" ]; then
        sed -i '/HostingNetFix/d' "config_player.xml"
    fi
fi
mkdir -p "${MOD_DIR}/Lua" 2>/dev/null || true

# 3. Установка патча LuaCsForBarotrauma (если включено INSTALL_LUACS=1 или если LuaCs ещё не установлен)
if [ "${INSTALL_LUACS:-1}" = "1" ] && [ ! -d "LocalMods/LuaCsForBarotrauma" ]; then
    LUACS_ZIP="/tmp/luacs_patch.zip"
    if [ -z "${LUACS_VERSION}" ] || [ "${LUACS_VERSION}" = "latest" ]; then
        LUACS_URL="https://github.com/evilfactory/LuaCsForBarotrauma/releases/latest/download/luacsforbarotrauma_patch_linux_server.zip"
    else
        LUACS_URL="https://github.com/evilfactory/LuaCsForBarotrauma/releases/download/${LUACS_VERSION}/luacsforbarotrauma_patch_linux_server.zip"
    fi
    if curl -fsSL "$LUACS_URL" -o "$LUACS_ZIP" 2>/dev/null; then
        unzip -o -q "$LUACS_ZIP" -d "$PWD/"
        rm -f "$LUACS_ZIP"
        chmod +x ./DedicatedServer 2>/dev/null || true
        echo "[LuaCs] Установлен"
    fi
fi

# 4. Подгрузка отдельных модов из WORKSHOP_MODS (если заданы через запятую)
if [ -n "${WORKSHOP_MODS}" ]; then
    STEAMCMD_EXEC=""
    for CANDIDATE in "$PWD/steamcmd/steamcmd.sh" "/mnt/server/steamcmd/steamcmd.sh" "$HOME/steamcmd/steamcmd.sh" "/home/steam/steamcmd/steamcmd.sh"; do
        if [ -f "$CANDIDATE" ]; then
            STEAMCMD_EXEC="$CANDIDATE"
            break
        fi
    done
    [ -z "$STEAMCMD_EXEC" ] && command -v steamcmd >/dev/null 2>&1 && STEAMCMD_EXEC="steamcmd"

    if [ -n "$STEAMCMD_EXEC" ]; then
        IFS=', ' read -r -a MANUAL_MODS <<< "${WORKSHOP_MODS}"
        STEAMCMD_ARGS="+force_install_dir $PWD +login ${STEAM_USER:-anonymous} ${STEAM_PASS:-} ${STEAM_AUTH:-}"
        NEED_DOWNLOAD=0
        for M_ID in "${MANUAL_MODS[@]}"; do
            if [ -n "$M_ID" ]; then
                if [ "${AUTO_UPDATE_MODS:-1}" = "0" ] && [ -d "LocalMods/$M_ID" ]; then
                    continue
                fi
                STEAMCMD_ARGS="$STEAMCMD_ARGS +workshop_download_item 602960 $M_ID"
                NEED_DOWNLOAD=1
            fi
        done
        if [ "$NEED_DOWNLOAD" = "1" ]; then
            $STEAMCMD_EXEC $STEAMCMD_ARGS +quit || true
            for WDIR in "$PWD/steamapps/workshop/content/602960" "$PWD/steamcmd/steamapps/workshop/content/602960" "$HOME/.steam/steam/steamapps/workshop/content/602960"; do
                if [ -d "$WDIR" ]; then
                    for M_ID in "${MANUAL_MODS[@]}"; do
                        if [ -n "$M_ID" ] && [ -d "$WDIR/$M_ID" ]; then
                            mkdir -p "LocalMods/$M_ID"
                            cp -rf "$WDIR/$M_ID/"* "LocalMods/$M_ID/" 2>/dev/null || true
                        fi
                    done
                fi
            done
        fi
    fi
fi

# 5. Бережная синхронизация настроек:
#    Если serversettings.xml уже существует, мы НЕ затираем его дефолтами панели,
#    а меняем только те параметры, которые пользователь явно задал или изменил в панели Pterodactyl.
NEW_SETTINGS_FILE=0
if [ ! -f "$SETTINGS_FILE" ]; then
    NEW_SETTINGS_FILE=1
    cat << 'EOF' > "$SETTINGS_FILE"
<?xml version="1.0" encoding="utf-8"?>
<serversettings
  ServerName="Barotrauma Server"
  IsPublic="True"
  MaxPlayers="16"
  TickRate="60"
  MissionTypes="All"
  autorestart="True" />
EOF
fi

if [ -f "$SNAPSHOT_FILE" ]; then
    # shellcheck disable=SC1090
    source "$SNAPSHOT_FILE" 2>/dev/null || true
    HAS_SNAPSHOT=1
else
    HAS_SNAPSHOT=0
fi

# Проверяет, нужно ли применять переменную из панели:
# Возвращает 0 (применять), если:
# - переменная не пустая, И
# - либо файл serversettings.xml только что создан с нуля,
# - либо есть прошлый снимок и значение переменной в панели изменилось с прошлого запуска,
# - либо снимка ещё нет, но значение отличается от старых дефолтов Egg.
should_apply_var() {
    local var_name="$1"
    local default_egg_val="$2"
    local cur_val="${!var_name}"
    local prev_var="PREV_${var_name}"
    local prev_val="${!prev_var}"

    [ -z "$cur_val" ] && return 1
    [ "$NEW_SETTINGS_FILE" = "1" ] && return 0

    if [ "$HAS_SNAPSHOT" = "1" ]; then
        [ "$cur_val" != "$prev_val" ] && return 0 || return 1
    else
        [ "$cur_val" != "$default_egg_val" ] && return 0 || return 1
    fi
}

set_xml_setting() {
    local key="$1"
    local val="$2"
    local file="$SETTINGS_FILE"

    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys, re, html
key, val, file = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(file, 'r', encoding='utf-8') as f:
        c = f.read()
    safe = html.escape(val, quote=True).replace('\r', '').replace('\n', '&#xA;')
    pattern = r'(^|[\s<])(' + re.escape(key) + r'=\"[^\"]*\")'
    if re.search(pattern, c, re.IGNORECASE):
        c = re.sub(pattern, lambda m: m.group(1) + f'{key}=\"{safe}\"', c, flags=re.IGNORECASE)
    else:
        c = re.sub(r'<serversettings\b', f'<serversettings\n  {key}=\"{safe}\"', c, count=1, flags=re.IGNORECASE)
    with open(file, 'w', encoding='utf-8') as f:
        f.write(c)
except Exception:
    pass
" "$key" "$val" "$file"
    else
        local safe_val
        safe_val=$(printf '%s' "$val" | sed 's/[&#\\]/\\&/g; s/"/\&quot;/g')
        if grep -iqE "(^|[[:space:]])${key}=\"[^\"]*\"" "$file"; then
            sed -i -E "s#(^|[[:space:]])${key}=\"[^\"]*\"#\1${key}=\"${safe_val}\"#Ig" "$file"
        else
            sed -i "s#<serversettings#<serversettings\n  ${key}=\"${safe_val}\"#" "$file"
        fi
    fi
}

echo "return {" > "${PANEL_LUA_PATH}"

if should_apply_var "SERVER_NAME" "Hosting-Project Encelada"; then
    set_xml_setting "ServerName" "${SERVER_NAME}"
    set_xml_setting "name" "${SERVER_NAME}"
    printf '  ServerName = %q,\n' "${SERVER_NAME}" >> "${PANEL_LUA_PATH}"
fi
if should_apply_var "SERVER_PASSWORD" ""; then
    set_xml_setting "password" "${SERVER_PASSWORD}"
elif [ "$HAS_SNAPSHOT" = "1" ] && [ -z "${SERVER_PASSWORD}" ] && [ -n "${PREV_SERVER_PASSWORD}" ]; then
    set_xml_setting "password" ""
fi
if should_apply_var "SERVER_MESSAGE" "Добро пожаловать на наш сервер Barotrauma!"; then
    set_xml_setting "ServerMessageText" "${SERVER_MESSAGE}"
fi
if should_apply_var "MAX_PLAYERS" "16"; then
    set_xml_setting "MaxPlayers" "${MAX_PLAYERS}"
    printf '  MaxPlayers = %s,\n' "${MAX_PLAYERS}" >> "${PANEL_LUA_PATH}"
fi
if should_apply_var "TICKRATE" "60"; then
    TR_VAL="${TICKRATE}"
    [ "$TR_VAL" -gt 60 ] 2>/dev/null && TR_VAL=60
    [ "$TR_VAL" -lt 1 ] 2>/dev/null && TR_VAL=20
    set_xml_setting "TickRate" "${TR_VAL}"
    printf '  TickRate = %s,\n' "${TR_VAL}" >> "${PANEL_LUA_PATH}"
fi
if should_apply_var "PLAYSTYLE" "Casual"; then
    set_xml_setting "PlayStyle" "${PLAYSTYLE}"
fi
if should_apply_var "LANGUAGE" "Russian"; then
    set_xml_setting "Language" "${LANGUAGE}"
    printf '  Language = %q,\n' "${LANGUAGE}" >> "${PANEL_LUA_PATH}"
    if [ -f "config_player.xml" ]; then
        sed -i -E "s#language=\"[^\"]*\"#language=\"${LANGUAGE}\"#Ig" "config_player.xml"
    fi
fi
if should_apply_var "RESPAWN_INTERVAL" "300"; then
    set_xml_setting "RespawnInterval" "${RESPAWN_INTERVAL}"
    printf '  RespawnInterval = %s,\n' "${RESPAWN_INTERVAL}" >> "${PANEL_LUA_PATH}"
fi
if should_apply_var "TRAITOR_PROBABILITY" "0"; then
    TP_FLOAT=$(awk "BEGIN { v = ${TRAITOR_PROBABILITY} + 0; v = v / 100.0; if (v < 0) v = 0; if (v > 1) v = 1; printf \"%.2f\", v }")
    set_xml_setting "TraitorProbability" "${TP_FLOAT}"
    printf '  TraitorProbability = %s,\n' "${TP_FLOAT}" >> "${PANEL_LUA_PATH}"
fi
if should_apply_var "BOT_COUNT" "0"; then
    set_xml_setting "BotCount" "${BOT_COUNT}"
    printf '  BotCount = %s,\n' "${BOT_COUNT}" >> "${PANEL_LUA_PATH}"
fi
if should_apply_var "SUB_VOTING" "Vote"; then
    set_xml_setting "SubSelectionMode" "${SUB_VOTING}"
fi
if should_apply_var "MODE_VOTING" "Vote"; then
    set_xml_setting "ModeSelectionMode" "${MODE_VOTING}"
fi

if should_apply_var "PUBLIC_SERVER" "1"; then
    if [ "${PUBLIC_SERVER}" = "1" ] || [ "${PUBLIC_SERVER}" = "true" ] || [ "${PUBLIC_SERVER}" = "True" ]; then
        set_xml_setting "IsPublic" "True"
        set_xml_setting "public" "True"
        echo "  IsPublic = true," >> "${PANEL_LUA_PATH}"
    else
        set_xml_setting "IsPublic" "False"
        set_xml_setting "public" "False"
        echo "  IsPublic = false," >> "${PANEL_LUA_PATH}"
    fi
fi

if should_apply_var "ALLOW_FRIENDLY_FIRE" "1"; then
    if [ "${ALLOW_FRIENDLY_FIRE}" = "1" ]; then
        set_xml_setting "AllowFriendlyFire" "True"
        echo "  AllowFriendlyFire = true," >> "${PANEL_LUA_PATH}"
    else
        set_xml_setting "AllowFriendlyFire" "False"
        echo "  AllowFriendlyFire = false," >> "${PANEL_LUA_PATH}"
    fi
fi

if should_apply_var "ALLOW_REWIRING" "1"; then
    if [ "${ALLOW_REWIRING}" = "1" ]; then
        set_xml_setting "AllowRewiring" "True"
        echo "  AllowRewiring = true," >> "${PANEL_LUA_PATH}"
    else
        set_xml_setting "AllowRewiring" "False"
        echo "  AllowRewiring = false," >> "${PANEL_LUA_PATH}"
    fi
fi

if should_apply_var "ALLOW_SPECTATING" "1"; then
    if [ "${ALLOW_SPECTATING}" = "1" ]; then
        set_xml_setting "AllowSpectating" "True"
        echo "  AllowSpectating = true," >> "${PANEL_LUA_PATH}"
    else
        set_xml_setting "AllowSpectating" "False"
        echo "  AllowSpectating = false," >> "${PANEL_LUA_PATH}"
    fi
fi

if should_apply_var "ALLOW_RESPAWN" "1"; then
    [ "${ALLOW_RESPAWN}" = "1" ] && set_xml_setting "RespawnMode" "MidRound" || set_xml_setting "RespawnMode" "None"
fi

if should_apply_var "KARMA_ENABLED" "0"; then
    if [ "${KARMA_ENABLED}" = "1" ]; then
        set_xml_setting "KarmaEnabled" "True"
        echo "  KarmaEnabled = true," >> "${PANEL_LUA_PATH}"
    else
        set_xml_setting "KarmaEnabled" "False"
        echo "  KarmaEnabled = false," >> "${PANEL_LUA_PATH}"
    fi
fi

if should_apply_var "AUTO_RESTART" "0"; then
    if [ "${AUTO_RESTART}" = "1" ]; then
        set_xml_setting "AutoRestart" "True"
        set_xml_setting "autorestart" "true"
        echo "  AutoRestart = true," >> "${PANEL_LUA_PATH}"
    else
        set_xml_setting "AutoRestart" "False"
        set_xml_setting "autorestart" "false"
        echo "  AutoRestart = false," >> "${PANEL_LUA_PATH}"
    fi
fi

if should_apply_var "VOICE_CHAT" "1"; then
    if [ "${VOICE_CHAT}" = "1" ] || [ "${VOICE_CHAT}" = "Local" ] || [ "${VOICE_CHAT}" = "True" ]; then
        set_xml_setting "VoiceChatEnabled" "True"
        echo "  VoiceChatEnabled = true," >> "${PANEL_LUA_PATH}"
    else
        set_xml_setting "VoiceChatEnabled" "False"
        echo "  VoiceChatEnabled = false," >> "${PANEL_LUA_PATH}"
    fi
fi

if should_apply_var "GAME_MODE" "Campaign"; then
    GMLOW=$(echo "${GAME_MODE}" | tr '[:upper:]' '[:lower:]')
    if [[ "$GMLOW" == *"camp"* ]]; then
        GM_ID="multiplayercampaign"
    elif [[ "$GMLOW" == *"sand"* ]]; then
        GM_ID="sandbox"
    elif [[ "$GMLOW" == *"pvp"* ]]; then
        GM_ID="pvp"
    else
        GM_ID="mission"
    fi
    set_xml_setting "GameModeIdentifier" "$GM_ID"
    printf '  GameModeIdentifier = %q,\n' "$GM_ID" >> "${PANEL_LUA_PATH}"
fi

echo "}" >> "${PANEL_LUA_PATH}"

# Сохраняем снимок текущих переменных панели для сравнения при следующем рестарте
cat << EOF > "${SNAPSHOT_FILE}"
PREV_SERVER_NAME=$(printf '%q' "${SERVER_NAME}")
PREV_SERVER_PASSWORD=$(printf '%q' "${SERVER_PASSWORD}")
PREV_SERVER_MESSAGE=$(printf '%q' "${SERVER_MESSAGE}")
PREV_MAX_PLAYERS=$(printf '%q' "${MAX_PLAYERS}")
PREV_TICKRATE=$(printf '%q' "${TICKRATE}")
PREV_PLAYSTYLE=$(printf '%q' "${PLAYSTYLE}")
PREV_LANGUAGE=$(printf '%q' "${LANGUAGE}")
PREV_RESPAWN_INTERVAL=$(printf '%q' "${RESPAWN_INTERVAL}")
PREV_TRAITOR_PROBABILITY=$(printf '%q' "${TRAITOR_PROBABILITY}")
PREV_BOT_COUNT=$(printf '%q' "${BOT_COUNT}")
PREV_SUB_VOTING=$(printf '%q' "${SUB_VOTING}")
PREV_MODE_VOTING=$(printf '%q' "${MODE_VOTING}")
PREV_PUBLIC_SERVER=$(printf '%q' "${PUBLIC_SERVER}")
PREV_ALLOW_FRIENDLY_FIRE=$(printf '%q' "${ALLOW_FRIENDLY_FIRE}")
PREV_ALLOW_REWIRING=$(printf '%q' "${ALLOW_REWIRING}")
PREV_ALLOW_SPECTATING=$(printf '%q' "${ALLOW_SPECTATING}")
PREV_ALLOW_RESPAWN=$(printf '%q' "${ALLOW_RESPAWN}")
PREV_KARMA_ENABLED=$(printf '%q' "${KARMA_ENABLED}")
PREV_AUTO_RESTART=$(printf '%q' "${AUTO_RESTART}")
PREV_VOICE_CHAT=$(printf '%q' "${VOICE_CHAT}")
PREV_GAME_MODE=$(printf '%q' "${GAME_MODE}")
EOF

if [ -n "${SERVER_PORT}" ]; then
    set_xml_setting "port" "${SERVER_PORT}"
    set_xml_setting "queryport" "$(( ${SERVER_PORT} + 1 ))"
fi

if ! grep -iq "MissionTypes=" "$SETTINGS_FILE"; then
    set_xml_setting "MissionTypes" "All"
fi

# 6. Выдача прав администратора OWNER_STEAMID в Data/clientpermissions.xml
if [ -n "${OWNER_STEAMID}" ]; then
    mkdir -p Data
    PERM_FILE="Data/clientpermissions.xml"
    if [ ! -f "$PERM_FILE" ]; then
        cat << EOF > "$PERM_FILE"
<?xml version="1.0" encoding="utf-8"?>
<ClientPermissions>
  <Client name="Owner" steamid="${OWNER_STEAMID}" permissions="All" />
</ClientPermissions>
EOF
    elif ! grep -q "${OWNER_STEAMID}" "$PERM_FILE"; then
        sed -i "s#</ClientPermissions>#  <Client name=\"Owner\" steamid=\"${OWNER_STEAMID}\" permissions=\"All\" />\n</ClientPermissions>#" "$PERM_FILE"
    fi
fi

# 7. Прописываем LocalMods/HostingNetFix/filelist.xml в config_player.xml
CFG_LANG="${LANGUAGE:-Russian}"
if [ ! -f "config_player.xml" ]; then
    cat << EOF > "config_player.xml"
<?xml version="1.0" encoding="utf-8"?>
<config language="${CFG_LANG}">
  <contentpackages>
    <!--Vanilla-->
    <corepackage path="Content/ContentPackages/Vanilla.xml" />
    <regularpackages>
    </regularpackages>
  </contentpackages>
</config>
EOF
fi

if grep -q "<regularpackages[[:space:]]*/>" "config_player.xml"; then
    sed -i 's#<regularpackages[[:space:]]*/>#<regularpackages>\n    </regularpackages>#' "config_player.xml"
fi

if [ "${ENABLE_NETFIX:-1}" = "1" ]; then
    if ! grep -q "LocalMods/HostingNetFix/filelist.xml" "config_player.xml"; then
        sed -i 's#</regularpackages>#  <!--HostingNetFix-->\n      <package path="LocalMods/HostingNetFix/filelist.xml" />\n    </regularpackages>#' "config_player.xml"
    fi
else
    rm -rf "${MOD_DIR}" 2>/dev/null || true
    sed -i '/HostingNetFix/d' "config_player.xml"
fi

if [ "${ADD_PACKAGES:-1}" = "1" ]; then
    for FILE in $(find LocalMods -maxdepth 2 -name "filelist.xml" 2>/dev/null); do
        if [ "$FILE" != "LocalMods/LuaCsForBarotrauma/filelist.xml" ] && ! grep -q "$FILE" "config_player.xml"; then
            sed -i "s#</regularpackages>#  <package path=\"$FILE\" />\n    </regularpackages>#" "config_player.xml"
        fi
    done
fi

echo "[HostingNetFix] Конфиг обновлён"
