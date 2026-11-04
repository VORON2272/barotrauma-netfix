#!/usr/bin/env bash
# install.sh — Автоматическая установка серверного фикса HostingNetFix и синхронизация всех настроек панели Pterodactyl для Barotrauma
# Запускается перед стартом DedicatedServer:
# curl -fsSL https://raw.githubusercontent.com/VORON2272/barotrauma-netfix/main/install.sh | tr -d '\r' | bash

set -e

MOD_DIR="LocalMods/HostingNetFix"
LUA_DIR="${MOD_DIR}/Lua/Autorun"
FILELIST_PATH="${MOD_DIR}/filelist.xml"
LUA_SCRIPT_PATH="${LUA_DIR}/hosting_netfix.lua"
SETTINGS_FILE="serversettings.xml"

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
    if not client or Game.RoundStarted then return end
    pcall(function()
        if client.Connection == nil then return end
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

print("[HostingNetFix] Loaded server-side fix for Lobby UI sync, MissionTypes & A2S_RULES MTU.")
EOF
fi

# 3. Установка патча LuaCsForBarotrauma (если включено INSTALL_LUACS=1 или если LuaCs ещё не установлен)
if [ "${INSTALL_LUACS:-1}" = "1" ] && [ ! -d "LocalMods/LuaCsForBarotrauma" ]; then
    echo "[HostingNetFix] Установка патча LuaCsForBarotrauma..."
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
        echo "[HostingNetFix] Патч LuaCsForBarotrauma успешно установлен в $PWD"
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

# 5. Синхронизация всех настроек панели Pterodactyl с serversettings.xml
#    (Исправлен баг регистра grep -i / sed -I: теперь заменяет и нижний, и верхний регистр атрибутов)
if [ ! -f "$SETTINGS_FILE" ]; then
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

set_xml_setting() {
    local key="$1"
    local val="$2"
    local file="$SETTINGS_FILE"
    # Экранируем спецсимволы для sed (& и |)
    local safe_val
    safe_val=$(printf '%s' "$val" | sed 's/[&|]/\\&/g; s/"/\&quot;/g')

    if grep -iqE "(^|[[:space:]])${key}=\"[^\"]*\"" "$file"; then
        sed -i -E "s|(^|[[:space:]])${key}=\"[^\"]*\"|\1${key}=\"${safe_val}\"|Ig" "$file"
    else
        sed -i "s|<serversettings|<serversettings\n  ${key}=\"${safe_val}\"|" "$file"
    fi
}

if [ -n "${SERVER_NAME}" ]; then
    set_xml_setting "ServerName" "${SERVER_NAME}"
    set_xml_setting "name" "${SERVER_NAME}"
fi
[ -n "${SERVER_PASSWORD+x}" ] && set_xml_setting "password" "${SERVER_PASSWORD}"
[ -n "${SERVER_MESSAGE}" ] && set_xml_setting "ServerMessageText" "${SERVER_MESSAGE}"
[ -n "${MAX_PLAYERS}" ] && set_xml_setting "MaxPlayers" "${MAX_PLAYERS}"
if [ -n "${TICKRATE}" ]; then
    # В Barotrauma C# TickRate зажимается в диапазоне 1..60
    TR_VAL="${TICKRATE}"
    [ "$TR_VAL" -gt 60 ] 2>/dev/null && TR_VAL=60
    [ "$TR_VAL" -lt 1 ] 2>/dev/null && TR_VAL=20
    set_xml_setting "TickRate" "${TR_VAL}"
fi
[ -n "${PLAYSTYLE}" ] && set_xml_setting "PlayStyle" "${PLAYSTYLE}"
[ -n "${LANGUAGE}" ] && set_xml_setting "Language" "${LANGUAGE}"
[ -n "${RESPAWN_INTERVAL}" ] && set_xml_setting "RespawnInterval" "${RESPAWN_INTERVAL}"
if [ -n "${TRAITOR_PROBABILITY}" ]; then
    # В Barotrauma TraitorProbability хранится как число от 0.0 до 1.0 (проценты / 100)
    TP_FLOAT=$(awk "BEGIN { v = ${TRAITOR_PROBABILITY} + 0; if (v > 1.0) v = v / 100.0; if (v < 0) v = 0; if (v > 1) v = 1; printf \"%.2f\", v }")
    set_xml_setting "TraitorProbability" "${TP_FLOAT}"
fi
[ -n "${BOT_COUNT}" ] && set_xml_setting "BotCount" "${BOT_COUNT}"
[ -n "${SUB_VOTING}" ] && set_xml_setting "SubSelectionMode" "${SUB_VOTING}"
[ -n "${MODE_VOTING}" ] && set_xml_setting "ModeSelectionMode" "${MODE_VOTING}"

if [ -n "${PUBLIC_SERVER}" ]; then
    if [ "${PUBLIC_SERVER}" = "1" ] || [ "${PUBLIC_SERVER}" = "true" ] || [ "${PUBLIC_SERVER}" = "True" ]; then
        set_xml_setting "IsPublic" "True"
        set_xml_setting "public" "True"
    else
        set_xml_setting "IsPublic" "False"
        set_xml_setting "public" "False"
    fi
fi

if [ -n "${ALLOW_FRIENDLY_FIRE}" ]; then
    [ "${ALLOW_FRIENDLY_FIRE}" = "1" ] && set_xml_setting "AllowFriendlyFire" "True" || set_xml_setting "AllowFriendlyFire" "False"
fi

if [ -n "${ALLOW_REWIRING}" ]; then
    [ "${ALLOW_REWIRING}" = "1" ] && set_xml_setting "AllowRewiring" "True" || set_xml_setting "AllowRewiring" "False"
fi

if [ -n "${ALLOW_SPECTATING}" ]; then
    [ "${ALLOW_SPECTATING}" = "1" ] && set_xml_setting "AllowSpectating" "True" || set_xml_setting "AllowSpectating" "False"
fi

if [ -n "${ALLOW_RESPAWN}" ]; then
    [ "${ALLOW_RESPAWN}" = "1" ] && set_xml_setting "RespawnMode" "MidRound" || set_xml_setting "RespawnMode" "None"
fi

if [ -n "${KARMA_ENABLED}" ]; then
    [ "${KARMA_ENABLED}" = "1" ] && set_xml_setting "KarmaEnabled" "True" || set_xml_setting "KarmaEnabled" "False"
fi

if [ -n "${AUTO_RESTART}" ]; then
    [ "${AUTO_RESTART}" = "1" ] && set_xml_setting "AutoRestart" "True" || set_xml_setting "AutoRestart" "False"
    [ "${AUTO_RESTART}" = "1" ] && set_xml_setting "autorestart" "true" || set_xml_setting "autorestart" "false"
fi

if [ -n "${VOICE_CHAT}" ]; then
    if [ "${VOICE_CHAT}" = "1" ] || [ "${VOICE_CHAT}" = "Local" ] || [ "${VOICE_CHAT}" = "True" ]; then
        set_xml_setting "VoiceChatEnabled" "True"
    else
        set_xml_setting "VoiceChatEnabled" "False"
    fi
fi

if [ -n "${GAME_MODE}" ]; then
    GMLOW=$(echo "${GAME_MODE}" | tr '[:upper:]' '[:lower:]')
    if [[ "$GMLOW" == *"camp"* ]]; then
        set_xml_setting "GameModeIdentifier" "multiplayercampaign"
    elif [[ "$GMLOW" == *"sand"* ]]; then
        set_xml_setting "GameModeIdentifier" "sandbox"
    elif [[ "$GMLOW" == *"pvp"* ]]; then
        set_xml_setting "GameModeIdentifier" "pvp"
    else
        set_xml_setting "GameModeIdentifier" "mission"
    fi
fi

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
        sed -i "s|</ClientPermissions>|  <Client name=\"Owner\" steamid=\"${OWNER_STEAMID}\" permissions=\"All\" />\n</ClientPermissions>|" "$PERM_FILE"
    fi
fi

# 7. Прописываем LocalMods/HostingNetFix/filelist.xml (и другие LocalMods при ADD_PACKAGES=1) в config_player.xml
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
else
    if grep -q "<regularpackages[[:space:]]*/>" "config_player.xml"; then
        sed -i 's|<regularpackages[[:space:]]*/>|<regularpackages>\n    </regularpackages>|' "config_player.xml"
    fi
    if ! grep -q "LocalMods/HostingNetFix/filelist.xml" "config_player.xml"; then
        sed -i 's|</regularpackages>|  <!--HostingNetFix-->\n      <package path="LocalMods/HostingNetFix/filelist.xml" />\n    </regularpackages>|' "config_player.xml"
    fi
    if [ "${ADD_PACKAGES:-1}" = "1" ]; then
        for FILE in $(find LocalMods -maxdepth 2 -name "filelist.xml" 2>/dev/null); do
            if [ "$FILE" != "LocalMods/LuaCsForBarotrauma/filelist.xml" ] && ! grep -q "$FILE" "config_player.xml"; then
                sed -i "s|</regularpackages>|  <package path=\"$FILE\" />\n    </regularpackages>|" "config_player.xml"
            fi
        done
    fi
fi

echo "[HostingNetFix] Настройки панели синхронизированы с serversettings.xml, мод зарегистрирован в config_player.xml."
