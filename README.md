# Barotrauma Hosting NetFix (Pterodactyl)

Серверный фикс для хостинга **Barotrauma** на панели **Pterodactyl** (`LuaCsForBarotrauma`), который автоматически устанавливается в `LocalMods/HostingNetFix` и прописывается в `config_player.xml`.

## Что исправляет мод:
1. **Видимость сервера в браузере у всех игроков из РФ (ТСПУ / MTU фикс):**
   Сжимает UDP-ответ `A2S_RULES` (на порту `queryport = port + 1`) с 2000–4800 байт до ~700 байт (1 нефрагментированный UDP-пакет) через перехват `Steamworks.SteamServer::SetKey`.
2. **Непрогрузка половины UI лобби при входе (чёрный список подлодок, пустые биомы, отсутствие кнопки Старт):**
   Через 1.5с и 4.5с после входа игрока (после завершения инициализации `LuaCs` и перехода в `Staging`) вызывает `client.InitClientSync()` и `Game.Server.ServerSettings.ForcePropertyUpdate()`.
3. **Ошибка `ServerSettings.get_MissionTypes` (`Value cannot be null. Parameter 'source'`):**
   Перехватывает геттер `get_MissionTypes` и гарантирует наличие `MissionTypes="All"` в `serversettings.xml`.

> **Важно:** В `LocalMods/HostingNetFix/filelist.xml` нет клиентских контент-тегов (`HasMultiplayerSyncedContent = false`), поэтому **обычным игрокам из Steam НЕ нужно скачивать этот мод**, чтобы зайти на сервер.

---

## Быстрое подключение к вашему Egg в Pterodactyl

1. Репозиторий: `https://github.com/VORON2272/barotrauma-netfix`
2. Прямая Raw-ссылка на `install.sh`:
   ```text
   https://raw.githubusercontent.com/VORON2272/barotrauma-netfix/main/install.sh
   ```
3. В настройках вашего Egg в Pterodactyl укажите короткую строку **Startup Command**:
   ```bash
   if [ "${ENABLE_NETFIX:-1}" != "1" ]; then rm -rf LocalMods/HostingNetFix && [ -f config_player.xml ] && sed -i '/HostingNetFix/d' config_player.xml || true; fi && bash run.sh && if [ "${ENABLE_NETFIX:-1}" = "1" ]; then (curl -fsSL https://raw.githubusercontent.com/VORON2272/barotrauma-netfix/main/install.sh | tr -d '\r' | bash || true); fi && export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$PWD/linux64" && port={{SERVER_PORT}} && ./DedicatedServer -port $port -queryport $(( $port + 1 ))
   ```
