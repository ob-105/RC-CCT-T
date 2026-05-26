-- RC-CCT-T  Turtle client  v2.0
-- Polls a Python control server whose URL is published to GitHub.
-- Builds a persistent world map using inspect() after each move
-- and the Plethora scanner module if one is equipped/attached.

local GITHUB_API    = "https://api.github.com/repos/ob-105/RC-CCT-T/contents/url.txt"
local POLL_SECS     = 0.5   -- how often to poll the server
local URL_TIMEOUT   = 10    -- seconds between GitHub re-checks on failure
local SCAN_EVERY    = 10    -- run full scanner every N polls (if available)
local MAP_MAX       = 8000  -- max blocks to keep in world map before pruning

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
        ["User-Agent"] = "CC-Turtle/2.0",
    })
    if not ok or not resp then return nil end
    local body = resp.readAll(); resp.close()
    local data = textutils.unserializeJSON(body)
    if not data or not data.content then return nil end
    local url = b64decode(data.content):gsub("%s+", "")
    return url ~= "" and url or nil
end

-- ── Position / facing tracking ────────────────────────────────────────────────
local pos    = { x = 0, y = 0, z = 0 }
local facing = 0   -- 0=north 1=east 2=south 3=west
local FACING_NAMES = { [0]="north", [1]="east", [2]="south", [3]="west" }
local DX = { [0]=0,  [1]=1,  [2]=0,  [3]=-1 }
local DZ = { [0]=-1, [1]=0,  [2]=1,  [3]=0  }

-- Forward-facing delta as {dx,dz} for inspect-based block placement
local function frontDelta()
    return DX[facing], DZ[facing]
end

-- ── World map ─────────────────────────────────────────────────────────────────
-- Persistent record of known blocks in absolute coords.
-- Key: "x,y,z"  Value: {name=string, x=int, y=int, z=int}
-- Air blocks are simply absent from the map.
local worldMap   = {}
local dirtyBlocks = {}   -- blocks changed since last poll (sent as delta)
local mapSize    = 0

local function mapKey(x, y, z)
    return x .. "," .. y .. "," .. z
end

-- Record a block at world position (wx, wy, wz).
-- name=nil means the position is known-air (remove from map).
local function setBlock(wx, wy, wz, name)
    local key = mapKey(wx, wy, wz)
    local isAir = not name or name == "" or name:find(":air")

    if isAir then
        if worldMap[key] then
            worldMap[key] = nil
            mapSize = mapSize - 1
            dirtyBlocks[key] = { x = wx, y = wy, z = wz, air = true }
        end
    else
        local existing = worldMap[key]
        if not existing or existing.name ~= name then
            if not existing then mapSize = mapSize + 1 end
            worldMap[key] = { name = name, x = wx, y = wy, z = wz }
            dirtyBlocks[key] = worldMap[key]
        end
    end
end

-- Prune the map when it gets too large: remove blocks furthest from turtle.
local function pruneMap()
    if mapSize <= MAP_MAX then return end
    local entries = {}
    for _, v in pairs(worldMap) do
        local dx = v.x - pos.x
        local dy = v.y - pos.y
        local dz = v.z - pos.z
        entries[#entries + 1] = { dist = dx*dx + dy*dy + dz*dz, key = mapKey(v.x, v.y, v.z) }
    end
    table.sort(entries, function(a, b) return a.dist > b.dist end)
    local toRemove = mapSize - math.floor(MAP_MAX * 0.8)
    for i = 1, toRemove do
        worldMap[entries[i].key] = nil
        mapSize = mapSize - 1
    end
end

-- Collect and clear the dirty set, returning it as an array.
local function flushDirty()
    local out = {}
    for _, v in pairs(dirtyBlocks) do
        out[#out + 1] = v
    end
    dirtyBlocks = {}
    return out
end

-- ── Scanner integration ───────────────────────────────────────────────────────
-- Finds a Plethora scanner peripheral attached to or equipped on the turtle.
local function findScanner()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "plethora:scanner") then
            return peripheral.wrap(name)
        end
    end
    -- Also check equipped sides
    for _, side in ipairs({"left", "right"}) do
        local ok, mods = pcall(peripheral.call, side, "listModules")
        if ok and type(mods) == "table" then
            for _, m in ipairs(mods) do
                if m == "plethora:scanner" then
                    return peripheral.wrap(side)
                end
            end
        end
    end
    return nil
end

local cachedScanner = nil
local scannerChecked = false

local function getScanner()
    if not scannerChecked then
        cachedScanner = findScanner()
        scannerChecked = true
    end
    return cachedScanner
end

-- Run a full scan and update the world map using absolute coordinates.
-- The scanner returns world-axis-aligned offsets so we just add turtle pos.
local function runScanner()
    local scanner = getScanner()
    if not scanner then return false end
    local ok, blocks = pcall(scanner.scan, 8)
    if not ok or type(blocks) ~= "table" then
        cachedScanner = nil; scannerChecked = false  -- redetect next time
        return false
    end
    for _, b in ipairs(blocks) do
        setBlock(pos.x + b.x, pos.y + b.y, pos.z + b.z, b.air and nil or b.name)
    end
    pruneMap()
    return true
end

-- ── Inspect-based mapping ─────────────────────────────────────────────────────
-- After each move, inspect what's adjacent and record it.
local function inspectAround()
    -- Position turtle is at = air
    setBlock(pos.x, pos.y, pos.z, nil)

    -- Front
    local fdx, fdz = frontDelta()
    local ok, data = turtle.inspect()
    setBlock(pos.x + fdx, pos.y, pos.z + fdz, ok and data.name or nil)

    -- Above
    ok, data = turtle.inspectUp()
    setBlock(pos.x, pos.y + 1, pos.z, ok and data.name or nil)

    -- Below
    ok, data = turtle.inspectDown()
    setBlock(pos.x, pos.y - 1, pos.z, ok and data.name or nil)
end

-- ── Inventory snapshot ────────────────────────────────────────────────────────
local function getInventory()
    local inv = {}
    for i = 1, 16 do
        local d = turtle.getItemDetail(i, false)
        inv[i] = d and {
            name        = d.name,
            displayName = d.displayName or d.name,
            count       = d.count,
            maxCount    = d.maxCount or 64,
        } or nil
    end
    return inv
end

-- ── Surroundings (for live display in UI) ────────────────────────────────────
local function getSurroundings()
    local function insp(fn)
        local ok, d = fn(); return ok and d or nil
    end
    return {
        front = insp(turtle.inspect),
        up    = insp(turtle.inspectUp),
        down  = insp(turtle.inspectDown),
    }
end

-- ── Command execution ─────────────────────────────────────────────────────────
local lastResult = nil

local function executeCommand(cmd)
    local action = cmd.action
    local ok, result = false, nil

    if action == "forward" then
        local oldPos = {x=pos.x, y=pos.y, z=pos.z}
        ok, result = turtle.forward()
        if ok then
            pos.x = pos.x + DX[facing]
            pos.z = pos.z + DZ[facing]
            setBlock(oldPos.x, oldPos.y, oldPos.z, nil)  -- old pos = air
            inspectAround()
        end

    elseif action == "back" then
        local oldPos = {x=pos.x, y=pos.y, z=pos.z}
        ok, result = turtle.back()
        if ok then
            pos.x = pos.x - DX[facing]
            pos.z = pos.z - DZ[facing]
            setBlock(oldPos.x, oldPos.y, oldPos.z, nil)
            inspectAround()
        end

    elseif action == "up" then
        local oldPos = {x=pos.x, y=pos.y, z=pos.z}
        ok, result = turtle.up()
        if ok then
            pos.y = pos.y + 1
            setBlock(oldPos.x, oldPos.y, oldPos.z, nil)
            inspectAround()
        end

    elseif action == "down" then
        local oldPos = {x=pos.x, y=pos.y, z=pos.z}
        ok, result = turtle.down()
        if ok then
            pos.y = pos.y - 1
            setBlock(oldPos.x, oldPos.y, oldPos.z, nil)
            inspectAround()
        end

    elseif action == "turnLeft" then
        ok = turtle.turnLeft()
        if ok then
            facing = (facing - 1) % 4
            inspectAround()  -- front changed after turning
        end

    elseif action == "turnRight" then
        ok = turtle.turnRight()
        if ok then
            facing = (facing + 1) % 4
            inspectAround()
        end

    elseif action == "dig" then
        ok, result = turtle.dig()
        if ok then
            local fdx, fdz = frontDelta()
            setBlock(pos.x + fdx, pos.y, pos.z + fdz, nil)  -- block is now gone
        end

    elseif action == "digUp" then
        ok, result = turtle.digUp()
        if ok then setBlock(pos.x, pos.y + 1, pos.z, nil) end

    elseif action == "digDown" then
        ok, result = turtle.digDown()
        if ok then setBlock(pos.x, pos.y - 1, pos.z, nil) end

    elseif action == "place" then
        ok, result = turtle.place()
        if ok then
            local fdx, fdz = frontDelta()
            -- We don't know the placed block name here without detail; re-inspect
            local iok, idata = turtle.inspect()
            setBlock(pos.x + fdx, pos.y, pos.z + fdz, iok and idata.name or nil)
        end

    elseif action == "placeUp" then
        ok, result = turtle.placeUp()
        if ok then
            local iok, idata = turtle.inspectUp()
            setBlock(pos.x, pos.y + 1, pos.z, iok and idata.name or nil)
        end

    elseif action == "placeDown" then
        ok, result = turtle.placeDown()
        if ok then
            local iok, idata = turtle.inspectDown()
            setBlock(pos.x, pos.y - 1, pos.z, iok and idata.name or nil)
        end

    elseif action == "select" then
        if cmd.slot then ok = turtle.select(cmd.slot) end

    elseif action == "equipLeft"  then ok = turtle.equipLeft();  scannerChecked = false
    elseif action == "equipRight" then ok = turtle.equipRight(); scannerChecked = false

    elseif action == "refuel" then
        ok = turtle.refuel(cmd.count or 64)
        result = tostring(turtle.getFuelLevel())

    elseif action == "drop"      then ok, result = turtle.drop(cmd.count)
    elseif action == "dropUp"    then ok, result = turtle.dropUp(cmd.count)
    elseif action == "dropDown"  then ok, result = turtle.dropDown(cmd.count)
    elseif action == "suck"      then ok, result = turtle.suck(cmd.count)
    elseif action == "suckUp"    then ok, result = turtle.suckUp(cmd.count)
    elseif action == "suckDown"  then ok, result = turtle.suckDown(cmd.count)

    else
        ok, result = false, "unknown action: " .. tostring(action)
    end

    lastResult = { ok = ok, action = action, result = result }
    return lastResult
end

-- ── Poll payload ──────────────────────────────────────────────────────────────
local function buildStatus()
    return {
        position      = pos,
        facing        = FACING_NAMES[facing],
        fuel          = turtle.getFuelLevel(),
        fuel_limit    = turtle.getFuelLimit(),
        inventory     = getInventory(),
        selected_slot = turtle.getSelectedSlot(),
        surroundings  = getSurroundings(),
        last_result   = lastResult,
        block_delta   = flushDirty(),
        map_size      = mapSize,
        has_scanner   = getScanner() ~= nil,
    }
end

-- ── HTTP helpers ──────────────────────────────────────────────────────────────
local function postJSON(url, data)
    local body = textutils.serializeJSON(data)
    local ok, resp = pcall(http.post, url, body, {["Content-Type"] = "application/json"})
    if not ok or not resp then return nil end
    local text = resp.readAll(); resp.close()
    return textutils.unserializeJSON(text)
end

-- ── Main loop ─────────────────────────────────────────────────────────────────
local function main()
    term.setTextColor(colors.cyan)
    print("RC-CCT-T Turtle v2.0")
    term.setTextColor(colors.white)

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
    if getScanner() then
        print("Scanner module detected!")
    end
    term.setTextColor(colors.white)

    -- Initial inspect to seed the map around starting position
    inspectAround()

    local pollUrl  = serverUrl .. "/api/turtle/poll"
    local pollCount = 0
    local failures = 0

    while true do
        pollCount = pollCount + 1

        -- Periodic full scanner sweep
        if pollCount % SCAN_EVERY == 0 then
            runScanner()
            pruneMap()
        end

        local status = buildStatus()
        local resp   = postJSON(pollUrl, status)

        if resp then
            failures = 0
            if resp.command then
                executeCommand(resp.command)
            end
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
                    pollUrl   = serverUrl .. "/api/turtle/poll"
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
