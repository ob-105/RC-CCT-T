-- RC-CCT-T  Base Station client  v1.0
-- Run on a regular computer (not a turtle) that has a Plethora neural interface
-- or manipulator peripheral attached.  Reports player introspection data, entity
-- sensing, and block scanning to the Python control server.
--
-- The peripheral side is auto-detected — just attach the module container to any
-- side of the computer.

local GITHUB_API  = "https://api.github.com/repos/ob-105/RC-CCT-T/contents/url.txt"
local POLL_SECS   = 2     -- seconds between server updates
local URL_TIMEOUT = 10    -- seconds between GitHub re-checks on failure

-- ── Base-64 decoder ───────────────────────────────────────────────────────────
local function b64decode(data)
    local b = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    data = data:gsub("[^" .. b .. "=]", "")
    return (data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", string.find(b, x, 1, true) - 1
        for i = 6, 1, -1 do
            r = r .. (math.floor(f / 2 ^ (i - 1)) % 2 == 1 and "1" or "0")
        end
        return r
    end):gsub("%d%d%d%d%d%d%d%d", function(x)
        local c = 0
        for i = 1, 8 do c = c + (tonumber(x:sub(i, i)) * 2 ^ (8 - i)) end
        return string.char(c)
    end))
end

-- ── GitHub URL fetch ──────────────────────────────────────────────────────────
local function fetchServerUrl()
    local ok, resp = pcall(http.get, GITHUB_API, {
        ["Accept"]     = "application/vnd.github.v3+json",
        ["User-Agent"] = "CC-BaseStation/1.0",
    })
    if not ok or not resp then return nil end
    local body = resp.readAll()
    resp.close()
    local data = textutils.unserializeJSON(body)
    if not data or not data.content then return nil end
    local url = b64decode(data.content):gsub("%s+", "")
    if url == "" then return nil end
    return url
end

-- ── Find the Plethora module container ───────────────────────────────────────
local function findModuleContainer()
    -- Check directly attached sides first
    local sides = { "top", "bottom", "left", "right", "front", "back" }
    for _, side in ipairs(sides) do
        local ok, mods = pcall(peripheral.call, side, "listModules")
        if ok and type(mods) == "table" then
            return side
        end
    end
    -- Check networked peripherals (modems)
    for _, name in ipairs(peripheral.getNames()) do
        local ok, mods = pcall(peripheral.call, name, "listModules")
        if ok and type(mods) == "table" then
            return name
        end
    end
    return nil
end

-- ── Safe peripheral call wrapper ─────────────────────────────────────────────
local function pcall_peripheral(side, method, ...)
    local ok, result = pcall(peripheral.call, side, method, ...)
    if ok then return result end
    return nil
end

-- ── Collect all available data from the module container ─────────────────────
local function collectData(side)
    local payload = { player = {}, entities = {}, blocks = {} }

    -- Introspection module
    local hasIntro = pcall_peripheral(side, "hasModule", "plethora:introspection")
    if hasIntro then
        payload.player.name = pcall_peripheral(side, "getName") or ""
        payload.player.uuid = pcall_peripheral(side, "getID")   or ""

        local rotOk, ryaw, rpitch = pcall(peripheral.call, side, "getRotation")
        if rotOk then
            payload.player.rotation = { yaw = ryaw or 0, pitch = rpitch or 0 }
        else
            payload.player.rotation = { yaw = 0, pitch = 0 }
        end

        local inv = pcall_peripheral(side, "getInventory")
        if type(inv) == "table" then
            -- Convert sparse table to array
            local arr = {}
            for i = 1, 36 do
                arr[i] = inv[i] or nil
            end
            payload.player.inventory = arr
        end

        local ender = pcall_peripheral(side, "getEnder")
        if type(ender) == "table" then
            local arr = {}
            for i = 1, 27 do
                arr[i] = ender[i] or nil
            end
            payload.player.ender = arr
        end

        local equip = pcall_peripheral(side, "getEquipment")
        if type(equip) == "table" then
            payload.player.equipment = equip
        end
    end

    -- Sensor module (entities)
    local hasSensor = pcall_peripheral(side, "hasModule", "plethora:sensor")
    if hasSensor then
        local entities = pcall_peripheral(side, "sense", 16)
        if type(entities) == "table" then
            payload.entities = entities
        end
    end

    -- Scanner module (blocks)
    local hasScanner = pcall_peripheral(side, "hasModule", "plethora:scanner")
    if hasScanner then
        local blocks = pcall_peripheral(side, "scan", 8)
        if type(blocks) == "table" then
            -- Filter out air blocks to save bandwidth
            local filtered = {}
            for _, b in ipairs(blocks) do
                if not b.air then
                    filtered[#filtered + 1] = b
                end
            end
            payload.blocks = filtered
        end
    end

    return payload
end

-- ── HTTP helpers ──────────────────────────────────────────────────────────────
local function postJSON(url, data)
    local body = textutils.serializeJSON(data)
    local ok, resp = pcall(http.post, url, body, {
        ["Content-Type"] = "application/json",
    })
    if not ok or not resp then return nil end
    local text = resp.readAll()
    resp.close()
    return textutils.unserializeJSON(text)
end

-- ── Main ─────────────────────────────────────────────────────────────────────
local function main()
    term.setTextColor(colors.cyan)
    print("RC-CCT-T Base Station v1.0")
    term.setTextColor(colors.white)

    -- Find module container
    local modSide = findModuleContainer()
    while not modSide do
        term.setTextColor(colors.red)
        print("No Plethora module container found — retrying…")
        term.setTextColor(colors.white)
        sleep(5)
        modSide = findModuleContainer()
    end
    term.setTextColor(colors.green)
    print("Module container: " .. modSide)
    local mods = peripheral.call(modSide, "listModules")
    print("Modules: " .. textutils.serialize(mods))
    term.setTextColor(colors.white)

    -- Discover server URL
    local serverUrl = nil
    while not serverUrl do
        term.setTextColor(colors.yellow)
        print("Fetching server URL from GitHub…")
        term.setTextColor(colors.white)
        serverUrl = fetchServerUrl()
        if not serverUrl then
            print("Not found — retrying in " .. URL_TIMEOUT .. "s")
            sleep(URL_TIMEOUT)
        end
    end
    term.setTextColor(colors.green)
    print("Server: " .. serverUrl)
    term.setTextColor(colors.white)

    local pollUrl  = serverUrl .. "/api/base/poll"
    local failures = 0

    while true do
        local data = collectData(modSide)
        local resp = postJSON(pollUrl, data)

        if resp then
            failures = 0
            -- print(".")  -- uncomment for verbose tick output
        else
            failures = failures + 1
            term.setTextColor(colors.red)
            print("Server unreachable (" .. failures .. ")")
            term.setTextColor(colors.white)

            if failures >= 3 then
                print("Re-checking GitHub…")
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
