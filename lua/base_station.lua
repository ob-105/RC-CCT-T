-- RC-CCT-T  Base Station client  v3.0  (Advanced Peripherals edition)
-- Run on a computer with Advanced Peripherals peripherals attached.
-- Geo Scanner: place the block adjacent to this computer (or connect via modem).
--   Note: the Geo Scanner item is for turtles; the block is for computers.
-- Player Detector: place adjacent or via modem (optional).
--
-- Set BASE_POS to this computer's in-game coordinates (F3 → XYZ).

local GITHUB_API  = "https://api.github.com/repos/ob-105/RC-CCT-T/contents/url.txt"
local POLL_SECS   = 3
local URL_TIMEOUT = 10
local SCAN_RADIUS = 8   -- AP Geo Scanner default max is 8 without upgrades

-- ── Set this to the base station computer's in-game position (F3) ─────────────
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
    if not ok then print("[DBG] pcall err: " .. tostring(resp)); return nil end
    if not resp then print("[DBG] http.get=nil"); return nil end
    local status = resp.getResponseCode and resp.getResponseCode() or "?"
    print("[DBG] status=" .. tostring(status))
    local body = resp.readAll(); resp.close()
    print("[DBG] body len=" .. #body)
    local data = textutils.unserializeJSON(body)
    if not data then print("[DBG] JSON fail: " .. body:sub(1,80)); return nil end
    if not data.content then
        print("[DBG] no content, msg=" .. tostring(data.message)); return nil
    end
    local url = b64decode(data.content):gsub("%s+", "")
    print("[DBG] url=" .. url .. " (len=" .. #url .. ")")
    return url ~= "" and url or nil
end

-- ── Peripheral discovery ──────────────────────────────────────────────────────
local function findPeripheral(ptype)
    -- peripheral.find is the cleanest way in CC:T
    local p = peripheral.find(ptype)
    if p then return p end
    -- Fallback: manual scan of all sides + network names
    local locations = {"top","bottom","left","right","front","back"}
    for _, name in ipairs(peripheral.getNames()) do
        locations[#locations + 1] = name
    end
    for _, loc in ipairs(locations) do
        if peripheral.getType(loc) == ptype then
            return peripheral.wrap(loc)
        end
    end
    return nil
end

local function listAllPeripherals()
    local locations = {"top","bottom","left","right","front","back"}
    for _, name in ipairs(peripheral.getNames()) do
        locations[#locations + 1] = name
    end
    print("[DBG] All peripherals:")
    for _, loc in ipairs(locations) do
        local t = peripheral.getType(loc)
        if t then print("[DBG]   " .. loc .. " = " .. t) end
    end
end

-- ── Geo Scanner — block data ──────────────────────────────────────────────────
-- AP Geo Scanner returns {name, x, y, z, tags} with world-aligned offsets.
-- Converting to world coords: world = BASE_POS + offset  (no facing math needed)
local function collectBlocks(scanner)
    local ok, blocks = pcall(scanner.scan, SCAN_RADIUS)
    if not ok then
        print("[DBG] scan() error: " .. tostring(blocks))
        return nil
    end
    if type(blocks) ~= "table" then
        print("[DBG] scan() returned " .. type(blocks))
        return nil
    end
    local out = {}
    for _, b in ipairs(blocks) do
        local name = b.name or ""
        if name ~= "" and name ~= "minecraft:air" and not name:find(":air$") then
            out[#out + 1] = {
                name = name,
                x    = BASE_POS.x + b.x,
                y    = BASE_POS.y + b.y,
                z    = BASE_POS.z + b.z,
            }
        end
    end
    return out
end

-- ── Player Detector — optional ────────────────────────────────────────────────
local function collectPlayers(detector)
    if not detector then return {} end
    local ok, players = pcall(detector.getOnlinePlayers)
    if not ok or type(players) ~= "table" then return {} end
    local out = {}
    for _, name in ipairs(players) do
        local ok2, data = pcall(detector.getPlayer, name)
        if ok2 and type(data) == "table" then
            out[#out + 1] = {
                name      = data.name or name,
                x         = data.x,
                y         = data.y,
                z         = data.z,
                health    = data.health,
                maxHealth = data.maxHealth,
                dimension = data.dimension,
            }
        end
    end
    return out
end

-- ── HTTP POST helper ──────────────────────────────────────────────────────────
local function postJSON(url, data)
    local body = textutils.serializeJSON(data)
    local ok, resp = pcall(http.post, url, body, {["Content-Type"] = "application/json"})
    if not ok then print("[DBG] POST err: " .. tostring(resp)); return nil end
    if not resp then print("[DBG] POST=nil"); return nil end
    local status = resp.getResponseCode and resp.getResponseCode() or "?"
    if status ~= 200 then print("[DBG] POST status=" .. tostring(status)) end
    local text = resp.readAll(); resp.close()
    return textutils.unserializeJSON(text)
end

-- ── Main ──────────────────────────────────────────────────────────────────────
local function main()
    term.setTextColor(colors.cyan)
    print("RC-CCT-T Base Station v3.0 (Advanced Peripherals)")
    term.setTextColor(colors.white)

    -- Show everything attached so user can see what's available
    listAllPeripherals()

    -- Find Geo Scanner (required)
    local scanner = findPeripheral("geoScanner")
    while not scanner do
        term.setTextColor(colors.red)
        print("No Geo Scanner found. Place one adjacent or connect via modem.")
        term.setTextColor(colors.white)
        sleep(5)
        listAllPeripherals()
        scanner = findPeripheral("geoScanner")
    end
    term.setTextColor(colors.green)
    print("Geo Scanner ready.")
    term.setTextColor(colors.white)

    -- Find Player Detector (optional)
    local detector = findPeripheral("playerDetector")
    if detector then
        term.setTextColor(colors.green)
        print("Player Detector ready.")
    else
        print("(No Player Detector found — player data disabled)")
    end
    term.setTextColor(colors.white)

    print("Base pos: " .. BASE_POS.x .. ", " .. BASE_POS.y .. ", " .. BASE_POS.z)

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
        -- Re-acquire if lost
        if not scanner then scanner = findPeripheral("geoScanner") end
        if not detector then detector = findPeripheral("playerDetector") end

        local blocks = {}
        if scanner then
            local result = collectBlocks(scanner)
            if result then
                blocks = result
            else
                scanner = nil  -- will redetect next loop
            end
        end

        local payload = {
            base_pos    = BASE_POS,
            block_delta = blocks,
            players     = collectPlayers(detector),
        }

        local resp = postJSON(pollUrl, payload)
        if resp then
            failures = 0
            term.setTextColor(colors.gray)
            print("OK — " .. #blocks .. " blocks sent")
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
