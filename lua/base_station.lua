-- RC-CCT-T  Base Station client  v2.0
-- Run on a computer with a Plethora block scanner peripheral attached.
-- Scans blocks around the base station and sends them to the control server
-- so they get merged into the shared world map.
--
-- Set BASE_POS below to the base station's in-game coordinates so the
-- scanned blocks can be positioned correctly in the world map.
-- (You can read your coordinates with F3 in-game.)

local GITHUB_API  = "https://api.github.com/repos/ob-105/RC-CCT-T/contents/url.txt"
local POLL_SECS   = 3     -- seconds between scans / server updates
local URL_TIMEOUT = 10    -- seconds between GitHub re-checks on failure

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
    local ok, resp = pcall(http.get, GITHUB_API, {
        ["Accept"]     = "application/vnd.github.v3+json",
        ["User-Agent"] = "CC-BaseStation/2.0",
    })
    if not ok or not resp then return nil end
    local body = resp.readAll(); resp.close()
    local data = textutils.unserializeJSON(body)
    if not data or not data.content then return nil end
    local url = b64decode(data.content):gsub("%s+", "")
    return url ~= "" and url or nil
end

-- ── Find the scanner peripheral ───────────────────────────────────────────────
-- The scanner can be directly attached on any side, or connected via modem.
local function findScanner()
    local sides = { "top", "bottom", "left", "right", "front", "back" }
    for _, side in ipairs(sides) do
        if peripheral.hasType(side, "plethora:scanner") then
            return peripheral.wrap(side), side
        end
        -- Also check if it's a module container with scanner module
        local ok, mods = pcall(peripheral.call, side, "listModules")
        if ok and type(mods) == "table" then
            for _, m in ipairs(mods) do
                if m == "plethora:scanner" then
                    return peripheral.wrap(side), side
                end
            end
        end
    end
    -- Check networked peripherals
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "plethora:scanner") then
            return peripheral.wrap(name), name
        end
        local ok, mods = pcall(peripheral.call, name, "listModules")
        if ok and type(mods) == "table" then
            for _, m in ipairs(mods) do
                if m == "plethora:scanner" then
                    return peripheral.wrap(name), name
                end
            end
        end
    end
    return nil, nil
end

-- ── Collect scanner data and convert to world coordinates ────────────────────
-- The scanner returns offsets in world-aligned axes (not local/facing axes),
-- so converting to world coordinates is simply:  world = BASE_POS + offset
local function collectBlocks(scanner)
    local ok, blocks = pcall(scanner.scan, 8)
    if not ok or type(blocks) ~= "table" then return nil end

    local out = {}
    for _, b in ipairs(blocks) do
        if not b.air then
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

-- ── HTTP helpers ──────────────────────────────────────────────────────────────
local function postJSON(url, data)
    local body = textutils.serializeJSON(data)
    local ok, resp = pcall(http.post, url, body, {["Content-Type"] = "application/json"})
    if not ok or not resp then return nil end
    local text = resp.readAll(); resp.close()
    return textutils.unserializeJSON(text)
end

-- ── Main ──────────────────────────────────────────────────────────────────────
local function main()
    term.setTextColor(colors.cyan)
    print("RC-CCT-T Base Station v2.0 (scanner)")
    term.setTextColor(colors.white)

    -- Find scanner
    local scanner, scannerName = findScanner()
    while not scanner do
        term.setTextColor(colors.red)
        print("No scanner peripheral found. Retrying in 5s...")
        print("Attach a Plethora scanner block to any side.")
        term.setTextColor(colors.white)
        sleep(5)
        scanner, scannerName = findScanner()
    end
    term.setTextColor(colors.green)
    print("Scanner found: " .. scannerName)
    term.setTextColor(colors.white)
    print("Base position: " .. BASE_POS.x .. ", " .. BASE_POS.y .. ", " .. BASE_POS.z)
    print("(Edit BASE_POS at the top of this file if incorrect)")

    -- Discover server URL
    local serverUrl = nil
    while not serverUrl do
        term.setTextColor(colors.yellow)
        print("Fetching server URL from GitHub...")
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
        -- Re-find scanner if it disconnected
        if not scanner then
            scanner, scannerName = findScanner()
        end

        local blocks = scanner and collectBlocks(scanner) or {}
        if not blocks then
            scanner = nil  -- scanner errored; will re-find next loop
            blocks = {}
        end

        local payload = {
            base_pos     = BASE_POS,
            block_delta  = blocks,
            scanner_name = scannerName or "",
        }

        local resp = postJSON(pollUrl, payload)
        if resp then
            failures = 0
            term.setTextColor(colors.gray)
            print("Sent " .. #blocks .. " blocks")
            term.setTextColor(colors.white)
        else
            failures = failures + 1
            term.setTextColor(colors.red)
            print("Server unreachable (" .. failures .. ")")
            term.setTextColor(colors.white)

            if failures >= 3 then
                print("Re-checking GitHub...")
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
