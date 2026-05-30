-- RC-CCT-T  Base Station client  v3.0
-- Run on a regular computer with a Plethora module container (manipulator)
-- attached to any side or connected via wired modem.
--
-- Supported modules (detected automatically from listModules):
--   plethora:scanner      → scan(radius)         block data
--   plethora:sensor       → sense(radius)         entity data
--   plethora:introspection → getInventory/Equipment/Rotation  player data
--
-- Set BASE_POS to this computer's in-game coordinates (F3 → XYZ).

local GITHUB_API  = "https://api.github.com/repos/ob-105/RC-CCT-T/contents/url.txt"
local POLL_SECS   = 3
local URL_TIMEOUT = 10
local SCAN_RADIUS = 8

-- ── Set this to the base station computer's in-game position ─────────────────
local BASE_POS = { x = 0, y = 0, z = 0 }
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Base-64 decoder ───────────────────────────────────────────────────────────
local function b64decode(data)
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    data = data:gsub("[^" .. b .. "=]", "")
    local bits = data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", string.find(b, x, 1, true) - 1
        for i = 6, 1, -1 do
            r = r .. (math.floor(f / 2 ^ (i - 1)) % 2 == 1 and "1" or "0")
        end
        return r
    end)
    bits = bits:sub(1, math.floor(#bits / 8) * 8)
    return (bits:gsub("%d%d%d%d%d%d%d%d", function(x)
        local c = 0
        for i = 1, 8 do c = c + (tonumber(x:sub(i, i)) * 2 ^ (8 - i)) end
        return string.char(c)
    end))
end

-- ── GitHub URL fetch ──────────────────────────────────────────────────────────
local function fetchServerUrl()
    print("[DBG] GET " .. GITHUB_API)
    local ok, resp = pcall(http.get, GITHUB_API, {
        ["Accept"]     = "application/vnd.github.v3+json",
        ["User-Agent"] = "CC-BaseStation/3.0",
    })
    if not ok  then print("[DBG] pcall err: " .. tostring(resp)); return nil end
    if not resp then print("[DBG] http.get=nil"); return nil end
    local status = resp.getResponseCode and resp.getResponseCode() or "?"
    print("[DBG] status=" .. tostring(status))
    local body = resp.readAll(); resp.close()
    print("[DBG] body len=" .. #body)
    local data = textutils.unserializeJSON(body)
    if not data then print("[DBG] JSON fail: " .. body:sub(1, 80)); return nil end
    if not data.content then
        print("[DBG] no content, msg=" .. tostring(data.message)); return nil
    end
    local url = b64decode(data.content):gsub("%s+", "")
    print("[DBG] url=" .. url .. " (len=" .. #url .. ")")
    return url ~= "" and url or nil
end

-- ── Module container discovery ────────────────────────────────────────────────
-- Find any peripheral that responds to listModules().
local function findContainer()
    local toCheck = {"top","bottom","left","right","front","back"}
    for _, name in ipairs(peripheral.getNames()) do
        toCheck[#toCheck + 1] = name
    end
    print("[DBG] Scanning " .. #toCheck .. " peripheral locations...")
    for _, loc in ipairs(toCheck) do
        local ptype = peripheral.getType(loc)
        if ptype then
            print("[DBG]  " .. loc .. " = " .. ptype)
            local ok, mods = pcall(peripheral.call, loc, "listModules")
            if ok and type(mods) == "table" then
                print("[DBG]    modules: " .. textutils.serialize(mods))
                return loc, mods
            end
        end
    end
    return nil, nil
end

-- Build a set of available module IDs for quick lookup.
local function buildModuleSet(mods)
    local set = {}
    for _, m in ipairs(mods or {}) do set[m] = true end
    return set
end

-- ── Data collection ───────────────────────────────────────────────────────────

-- Scanner: blocks relative to base station → convert to world coords.
-- The scanner returns world-axis-aligned offsets, so: world = BASE_POS + offset.
local function collectBlocks(side)
    local ok, blocks = pcall(peripheral.call, side, "scan", SCAN_RADIUS)
    if not ok or type(blocks) ~= "table" then
        print("[DBG] scan error: " .. tostring(blocks)); return {}
    end
    local out = {}
    for _, b in ipairs(blocks) do
        if not b.air and b.name and b.name ~= "minecraft:air" and not b.name:find(":air$") then
            out[#out + 1] = {
                name = b.name,
                x    = BASE_POS.x + b.x,
                y    = BASE_POS.y + b.y,
                z    = BASE_POS.z + b.z,
            }
        end
    end
    return out
end

-- Sensor: entities near the base station.
local function collectEntities(side)
    local ok, entities = pcall(peripheral.call, side, "sense", 16)
    if not ok or type(entities) ~= "table" then return {} end
    return entities
end

-- Introspection: player info.
-- getRotation() works with either sensor or introspection present.
-- getInventory/getEquipment are player-only; we try and silently skip on error.
local function collectPlayerData(side, hasIntrospection, hasSensorOrIntro)
    local player = {}

    if hasSensorOrIntro then
        local ok, yaw, pitch = pcall(function()
            return peripheral.call(side, "getRotation")
        end)
        if ok and yaw then
            player.rotation = { yaw = yaw, pitch = pitch }
        end
    end

    if hasIntrospection then
        local ok, name = pcall(peripheral.call, side, "getName")
        if ok and name then player.name = name end

        local ok2, uuid = pcall(peripheral.call, side, "getID")
        if ok2 and uuid then player.uuid = uuid end

        -- Inventory (player-only; will error on non-player origin)
        local ok3, inv = pcall(peripheral.call, side, "getInventory")
        if ok3 and type(inv) == "table" then
            local arr = {}
            for i = 1, 36 do arr[i] = inv[i] or nil end
            player.inventory = arr
        end

        -- Ender chest
        local ok4, ender = pcall(peripheral.call, side, "getEnder")
        if ok4 and type(ender) == "table" then
            local arr = {}
            for i = 1, 27 do arr[i] = ender[i] or nil end
            player.ender = arr
        end

        -- Equipment
        local ok5, equip = pcall(peripheral.call, side, "getEquipment")
        if ok5 and type(equip) == "table" then
            player.equipment = equip
        end
    end

    return player
end

-- ── HTTP POST helper ──────────────────────────────────────────────────────────
local function postJSON(url, data)
    local body = textutils.serializeJSON(data)
    local ok, resp = pcall(http.post, url, body, {["Content-Type"] = "application/json"})
    if not ok  then print("[DBG] POST err: " .. tostring(resp)); return nil end
    if not resp then print("[DBG] POST=nil"); return nil end
    local status = resp.getResponseCode and resp.getResponseCode() or "?"
    if status ~= 200 then print("[DBG] POST status=" .. tostring(status)) end
    local text = resp.readAll(); resp.close()
    return textutils.unserializeJSON(text)
end

-- ── Main ──────────────────────────────────────────────────────────────────────
local function main()
    term.setTextColor(colors.cyan)
    print("RC-CCT-T Base Station v3.0")
    term.setTextColor(colors.white)
    print("Base pos: " .. BASE_POS.x .. ", " .. BASE_POS.y .. ", " .. BASE_POS.z)

    -- Find module container
    local containerSide, mods = findContainer()
    while not containerSide do
        term.setTextColor(colors.red)
        print("No module container found. Attach a Plethora manipulator and reboot.")
        term.setTextColor(colors.white)
        sleep(5)
        containerSide, mods = findContainer()
    end

    local modSet       = buildModuleSet(mods)
    local hasScanner   = modSet["plethora:scanner"]      == true
    local hasSensor    = modSet["plethora:sensor"]       == true
    local hasIntro     = modSet["plethora:introspection"] == true

    term.setTextColor(colors.green)
    print("Container on: " .. containerSide)
    print("Scanner:      " .. tostring(hasScanner))
    print("Sensor:       " .. tostring(hasSensor))
    print("Introspection:" .. tostring(hasIntro))
    term.setTextColor(colors.white)

    -- Discover server URL
    local serverUrl = nil
    while not serverUrl do
        term.setTextColor(colors.yellow)
        print("Fetching server URL from GitHub...")
        term.setTextColor(colors.white)
        serverUrl = fetchServerUrl()
        if not serverUrl then
            print("Retrying in " .. URL_TIMEOUT .. "s")
            sleep(URL_TIMEOUT)
        end
    end
    term.setTextColor(colors.green)
    print("Server: " .. serverUrl)
    term.setTextColor(colors.white)

    local pollUrl  = serverUrl .. "/api/base/poll"
    local failures = 0

    while true do
        local payload = {
            base_pos    = BASE_POS,
            block_delta = hasScanner and collectBlocks(containerSide) or {},
            entities    = (hasSensor or hasIntro) and collectEntities(containerSide) or {},
            player      = collectPlayerData(containerSide, hasIntro, hasSensor or hasIntro),
        }

        local resp = postJSON(pollUrl, payload)
        if resp then
            failures = 0
            local nb = payload.block_delta and #payload.block_delta or 0
            local ne = payload.entities    and #payload.entities    or 0
            term.setTextColor(colors.gray)
            print("OK — " .. nb .. " blocks, " .. ne .. " entities")
            term.setTextColor(colors.white)
        else
            failures = failures + 1
            term.setTextColor(colors.red)
            print("Server unreachable (" .. failures .. ")")
            term.setTextColor(colors.white)
            if failures >= 3 then
                local newUrl = fetchServerUrl()
                if newUrl and newUrl ~= serverUrl then
                    serverUrl = newUrl
                    pollUrl   = serverUrl .. "/api/base/poll"
                    print("New URL: " .. serverUrl)
                    failures = 0
                end
                sleep(URL_TIMEOUT)
            end
        end

        sleep(POLL_SECS)
    end
end

main()
