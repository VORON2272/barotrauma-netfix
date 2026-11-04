#!/usr/bin/env bash
# install.sh — Автоматическая установка серверного фикса HostingNetFix и синхронизация всех настроек панели Pterodactyl для Barotrauma
# Запускается перед стартом DedicatedServer:
# curl -fsSL https://raw.githubusercontent.com/VORON2272/barotrauma-netfix/main/install.sh | tr -d '\r' | bash

MOD_DIR="LocalMods/HostingNetFix"
LUA_DIR="${MOD_DIR}/Lua/Autorun"
FILELIST_PATH="${MOD_DIR}/filelist.xml"
LUA_SCRIPT_PATH="${LUA_DIR}/hosting_netfix.lua"
PANEL_LUA_PATH="${MOD_DIR}/Lua/panel_settings.lua"
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

local modPath = ...

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

print("[HostingNetFix] Мод загружен")
EOF
fi

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

# 5. Синхронизация всех настроек панели Pterodactyl с serversettings.xml И генерация panel_settings.lua
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

# Используем разделитель # в sed (без конфликта с символом | внутри регулярки)
set_xml_setting() {
    local key="$1"
    local val="$2"
    local file="$SETTINGS_FILE"
    local safe_val
    safe_val=$(printf '%s' "$val" | sed 's/[&#\\]/\\&/g; s/"/\&quot;/g')

    if grep -iqE "(^|[[:space:]])${key}=\"[^\"]*\"" "$file"; then
        sed -i -E "s#(^|[[:space:]])${key}=\"[^\"]*\"#\1${key}=\"${safe_val}\"#Ig" "$file"
    else
        sed -i "s#<serversettings#<serversettings\n  ${key}=\"${safe_val}\"#" "$file"
    fi
}

echo "return {" > "${PANEL_LUA_PATH}"

if [ -n "${SERVER_NAME}" ]; then
    set_xml_setting "ServerName" "${SERVER_NAME}"
    set_xml_setting "name" "${SERVER_NAME}"
    printf '  ServerName = %q,\n' "${SERVER_NAME}" >> "${PANEL_LUA_PATH}"
fi
[ -n "${SERVER_PASSWORD+x}" ] && set_xml_setting "password" "${SERVER_PASSWORD}"
if [ -n "${SERVER_MESSAGE}" ]; then
    set_xml_setting "ServerMessageText" "${SERVER_MESSAGE}"
    printf '  ServerMessage = %q,\n' "${SERVER_MESSAGE}" >> "${PANEL_LUA_PATH}"
fi
if [ -n "${MAX_PLAYERS}" ]; then
    set_xml_setting "MaxPlayers" "${MAX_PLAYERS}"
    printf '  MaxPlayers = %s,\n' "${MAX_PLAYERS}" >> "${PANEL_LUA_PATH}"
fi
if [ -n "${TICKRATE}" ]; then
    TR_VAL="${TICKRATE}"
    [ "$TR_VAL" -gt 60 ] 2>/dev/null && TR_VAL=60
    [ "$TR_VAL" -lt 1 ] 2>/dev/null && TR_VAL=20
    set_xml_setting "TickRate" "${TR_VAL}"
    printf '  TickRate = %s,\n' "${TR_VAL}" >> "${PANEL_LUA_PATH}"
fi
[ -n "${PLAYSTYLE}" ] && set_xml_setting "PlayStyle" "${PLAYSTYLE}"
if [ -n "${LANGUAGE}" ]; then
    set_xml_setting "Language" "${LANGUAGE}"
    printf '  Language = %q,\n' "${LANGUAGE}" >> "${PANEL_LUA_PATH}"
fi
if [ -n "${RESPAWN_INTERVAL}" ]; then
    set_xml_setting "RespawnInterval" "${RESPAWN_INTERVAL}"
    printf '  RespawnInterval = %s,\n' "${RESPAWN_INTERVAL}" >> "${PANEL_LUA_PATH}"
fi
if [ -n "${TRAITOR_PROBABILITY}" ]; then
    TP_FLOAT=$(awk "BEGIN { v = ${TRAITOR_PROBABILITY} + 0; if (v > 1.0) v = v / 100.0; if (v < 0) v = 0; if (v > 1) v = 1; printf \"%.2f\", v }")
    set_xml_setting "TraitorProbability" "${TP_FLOAT}"
    printf '  TraitorProbability = %s,\n' "${TP_FLOAT}" >> "${PANEL_LUA_PATH}"
fi
if [ -n "${BOT_COUNT}" ]; then
    set_xml_setting "BotCount" "${BOT_COUNT}"
    printf '  BotCount = %s,\n' "${BOT_COUNT}" >> "${PANEL_LUA_PATH}"
fi
[ -n "${SUB_VOTING}" ] && set_xml_setting "SubSelectionMode" "${SUB_VOTING}"
[ -n "${MODE_VOTING}" ] && set_xml_setting "ModeSelectionMode" "${MODE_VOTING}"

if [ -n "${PUBLIC_SERVER}" ]; then
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

if [ -n "${ALLOW_FRIENDLY_FIRE}" ]; then
    if [ "${ALLOW_FRIENDLY_FIRE}" = "1" ]; then
        set_xml_setting "AllowFriendlyFire" "True"
        echo "  AllowFriendlyFire = true," >> "${PANEL_LUA_PATH}"
    else
        set_xml_setting "AllowFriendlyFire" "False"
        echo "  AllowFriendlyFire = false," >> "${PANEL_LUA_PATH}"
    fi
fi

if [ -n "${ALLOW_REWIRING}" ]; then
    if [ "${ALLOW_REWIRING}" = "1" ]; then
        set_xml_setting "AllowRewiring" "True"
        echo "  AllowRewiring = true," >> "${PANEL_LUA_PATH}"
    else
        set_xml_setting "AllowRewiring" "False"
        echo "  AllowRewiring = false," >> "${PANEL_LUA_PATH}"
    fi
fi

if [ -n "${ALLOW_SPECTATING}" ]; then
    if [ "${ALLOW_SPECTATING}" = "1" ]; then
        set_xml_setting "AllowSpectating" "True"
        echo "  AllowSpectating = true," >> "${PANEL_LUA_PATH}"
    else
        set_xml_setting "AllowSpectating" "False"
        echo "  AllowSpectating = false," >> "${PANEL_LUA_PATH}"
    fi
fi

if [ -n "${ALLOW_RESPAWN}" ]; then
    [ "${ALLOW_RESPAWN}" = "1" ] && set_xml_setting "RespawnMode" "MidRound" || set_xml_setting "RespawnMode" "None"
fi

if [ -n "${KARMA_ENABLED}" ]; then
    if [ "${KARMA_ENABLED}" = "1" ]; then
        set_xml_setting "KarmaEnabled" "True"
        echo "  KarmaEnabled = true," >> "${PANEL_LUA_PATH}"
    else
        set_xml_setting "KarmaEnabled" "False"
        echo "  KarmaEnabled = false," >> "${PANEL_LUA_PATH}"
    fi
fi

if [ -n "${AUTO_RESTART}" ]; then
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

if [ -n "${VOICE_CHAT}" ]; then
    if [ "${VOICE_CHAT}" = "1" ] || [ "${VOICE_CHAT}" = "Local" ] || [ "${VOICE_CHAT}" = "True" ]; then
        set_xml_setting "VoiceChatEnabled" "True"
        echo "  VoiceChatEnabled = true," >> "${PANEL_LUA_PATH}"
    else
        set_xml_setting "VoiceChatEnabled" "False"
        echo "  VoiceChatEnabled = false," >> "${PANEL_LUA_PATH}"
    fi
fi

if [ -n "${GAME_MODE}" ]; then
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

# 7. Прописываем LocalMods/HostingNetFix/filelist.xml и выбранный LANGUAGE в config_player.xml
CFG_LANG="${LANGUAGE:-Russian}"
if [ ! -f "config_player.xml" ]; then
    cat << EOF > "config_player.xml"
<?xml version="1.0" encoding="utf-8"?>
<config language="${CFG_LANG}">
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
    if [ -n "${LANGUAGE}" ]; then
        sed -i -E "s#language=\"[^\"]*\"#language=\"${LANGUAGE}\"#Ig" "config_player.xml"
    fi
    if grep -q "<regularpackages[[:space:]]*/>" "config_player.xml"; then
        sed -i 's#<regularpackages[[:space:]]*/>#<regularpackages>\n    </regularpackages>#' "config_player.xml"
    fi
    if ! grep -q "LocalMods/HostingNetFix/filelist.xml" "config_player.xml"; then
        sed -i 's#</regularpackages>#  <!--HostingNetFix-->\n      <package path="LocalMods/HostingNetFix/filelist.xml" />\n    </regularpackages>#' "config_player.xml"
    fi
    if [ "${ADD_PACKAGES:-1}" = "1" ]; then
        for FILE in $(find LocalMods -maxdepth 2 -name "filelist.xml" 2>/dev/null); do
            if [ "$FILE" != "LocalMods/LuaCsForBarotrauma/filelist.xml" ] && ! grep -q "$FILE" "config_player.xml"; then
                sed -i "s#</regularpackages>#  <package path=\"$FILE\" />\n    </regularpackages>#" "config_player.xml"
            fi
        done
    fi
fi

echo "[HostingNetFix] Конфиг обновлён"
