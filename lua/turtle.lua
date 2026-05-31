-- RC-CCT-T  Turtle client  v3.0
-- Uses the Plethora `modules` global (turtle inventory modules).
-- Place module items in the turtle's inventory and reboot to activate them.
--
-- Supported modules (all optional — turtle works without any):
--   plethora:scanner  → modules.scan(radius)   for full area block mapping
--   plethora:sensor   → modules.sense(radius)  for nearby entity detection

local GITHUB_API    = "https://api.github.com/repos/ob-105/RC-CCT-T/contents/url.txt"
local SELF_API      = "https://api.github.com/repos/ob-105/RC-CCT-T/contents/lua/turtle.lua"
local POLL_SECS     = 0.5
local URL_TIMEOUT   = 10
local SCAN_EVERY    = 4     -- full scan every N polls (~2s) if scanner available
local MAP_MAX       = 8000

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
        ["User-Agent"] = "CC-Turtle/3.0",
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

-- ── Self-updater ─────────────────────────────────────────────────────────────
-- Downloads the latest script from GitHub via the API (no CDN caching) and
-- overwrites this file + reboots if the content changed.
local function selfUpdate()
    term.setTextColor(colors.yellow)
    print("Checking for updates...")
    term.setTextColor(colors.white)

    local ok, resp = pcall(http.get, SELF_API, {
        ["Accept"]     = "application/vnd.github.v3+json",
        ["User-Agent"] = "CC-Turtle/3.0",
    })
    if not ok or not resp then
        print("(Update check failed — continuing)")
        return
    end
    local body = resp.readAll(); resp.close()
    local data = textutils.unserializeJSON(body)
    if not data or not data.content then
        print("(Update: bad GitHub response — continuing)")
        return
    end

    local latest = b64decode(data.content)
    if #latest < 50 then
        print("(Update: suspiciously short response — skipping)")
        return
    end

    local selfPath = shell.getRunningProgram()
    local f = fs.open(selfPath, "r")
    local current = f and f.readAll() or ""
    if f then f.close() end

    if latest == current then
        term.setTextColor(colors.green)
        print("Already up to date.")
        term.setTextColor(colors.white)
        return
    end

    print("Update found! Writing new version...")
    local wf = fs.open(selfPath, "w")
    if not wf then
        print("(Cannot write update — check file permissions)")
        return
    end
    wf.write(latest)
    wf.close()
    term.setTextColor(colors.green)
    print("Updated! Rebooting in 2s...")
    term.setTextColor(colors.white)
    sleep(2)
    os.reboot()
end

-- ── Module availability ───────────────────────────────────────────────────────
-- The `modules` global is set by Plethora at boot if module items are in the
-- turtle's inventory.  Each method listed in modules.listMethods().loaded is
-- safe to call.
local loadedMethods = {}

local function initModules()
    loadedMethods = {}
    if not modules then
        print("(No Plethora modules found — place items in inventory and reboot)")
        return
    end
    local ok, info = pcall(modules.listMethods)
    if ok and type(info) == "table" and type(info.loaded) == "table" then
        for _, m in ipairs(info.loaded) do
            loadedMethods[m] = true
        end
        print("Modules loaded: " .. textutils.serialize(info.loaded))
    else
        -- Probe directly for known methods
        for _, m in ipairs({"scan", "sense", "fire", "getRotation"}) do
            if type(modules[m]) == "function" then loadedMethods[m] = true end
        end
    end
    -- getRotation is exposed with sensor OR introspection — probe separately
    -- in case listMethods didn't include it
    if not loadedMethods["getRotation"] and type(modules) == "table" then
        if type(modules.getRotation) == "function" then
            loadedMethods["getRotation"] = true
        end
    end
end

local function hasMethod(name)
    return loadedMethods[name] == true
end

-- ── Position / facing tracking ────────────────────────────────────────────────
local pos    = { x = 0, y = 0, z = 0 }
local facing = 0   -- 0=north  1=east  2=south  3=west
local FACING_NAMES = { [0]="north", [1]="east", [2]="south", [3]="west" }
local DX = { [0]=0,  [1]=1,  [2]=0,  [3]=-1 }
local DZ = { [0]=-1, [1]=0,  [2]=1,  [3]=0  }

local function frontDelta()
    return DX[facing], DZ[facing]
end

-- Convert Minecraft yaw degrees to our facing enum.
-- MC yaw: 0=south, 90=west, 180/-180=north, -90/270=east
local function yawToFacing(yaw)
    yaw = yaw % 360
    if yaw < 0 then yaw = yaw + 360 end
    if     yaw >= 315 or yaw < 45  then return 2  -- south
    elseif yaw >= 45  and yaw < 135 then return 3  -- west
    elseif yaw >= 135 and yaw < 225 then return 0  -- north
    else                                 return 1  -- east (225-315)
    end
end

-- Sync facing from real yaw — call after every turn to prevent drift.
local function syncFacing()
    if not hasMethod("getRotation") then return end
    local ok, yaw = pcall(modules.getRotation)
    if ok and type(yaw) == "number" then
        local real = yawToFacing(yaw)
        if real ~= facing then
            print("[DBG] Facing corrected " .. FACING_NAMES[facing] .. " → " .. FACING_NAMES[real])
            facing = real
        end
    end
end

-- ── Yield helper ─────────────────────────────────────────────────────────────
-- CC kills scripts that run >~10k instructions without yielding.
-- This yields instantly (no sleep delay) by firing a synthetic event.
local function yield()
    os.queueEvent("__rc_yield")
    os.pullEvent("__rc_yield")
end

-- ── World map ─────────────────────────────────────────────────────────────────
local worldMap    = {}
local dirtyBlocks = {}
local mapSize     = 0

local MAX_DELTA_PER_POLL = 400  -- cap dirty blocks sent per poll to bound JSON size

local function mapKey(x, y, z) return x .. "," .. y .. "," .. z end

local function setBlock(wx, wy, wz, name)
    local key   = mapKey(wx, wy, wz)
    local isAir = not name or name == "" or name == "minecraft:air" or name:find(":air$")
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
            worldMap[key]    = { name = name, x = wx, y = wy, z = wz }
            dirtyBlocks[key] = worldMap[key]
        end
    end
end

local function pruneMap()
    if mapSize <= MAP_MAX then return end
    local entries = {}
    local i = 0
    for _, v in pairs(worldMap) do
        i = i + 1
        local dx = v.x - pos.x
        local dy = v.y - pos.y
        local dz = v.z - pos.z
        entries[#entries + 1] = { dist = dx*dx + dy*dy + dz*dz, key = mapKey(v.x, v.y, v.z) }
        if i % 500 == 0 then yield() end   -- yield every 500 iterations
    end
    table.sort(entries, function(a, b) return a.dist > b.dist end)
    local toRemove = mapSize - math.floor(MAP_MAX * 0.8)
    for i = 1, toRemove do
        worldMap[entries[i].key] = nil
        mapSize = mapSize - 1
    end
end

local function flushDirty()
    local out   = {}
    local count = 0
    for k, v in pairs(dirtyBlocks) do
        out[#out + 1] = v
        dirtyBlocks[k] = nil
        count = count + 1
        if count >= MAX_DELTA_PER_POLL then break end  -- send the rest next poll
    end
    -- (remaining dirty entries stay in dirtyBlocks for the next poll)
    return out
    return out
end

-- ── Scanner (modules.scan) ────────────────────────────────────────────────────
-- modules.scan() returns world-axis-aligned offsets — just add turtle pos.
local function runScanner()
    if not hasMethod("scan") then return false end
    local ok, blocks = pcall(modules.scan, 8)
    if not ok or type(blocks) ~= "table" then
        print("[DBG] modules.scan error: " .. tostring(blocks))
        return false
    end
    for i, b in ipairs(blocks) do
        local name  = b.name or ""
        local isAir = b.air or name == "" or name == "minecraft:air" or name:find(":air$")
        setBlock(pos.x + b.x, pos.y + b.y, pos.z + b.z, isAir and nil or name)
        if i % 250 == 0 then yield() end   -- yield every 250 blocks
    end
    pruneMap()
    return true
end

-- ── Sensor (modules.sense) ────────────────────────────────────────────────────
local lastEntities = {}

local function runSensor()
    if not hasMethod("sense") then return end
    local ok, entities = pcall(modules.sense, 16)
    if not ok or type(entities) ~= "table" then return end
    lastEntities = entities
end

-- ── Inspect-based mapping (no scanner needed) ─────────────────────────────────
local function inspectAround()
    setBlock(pos.x, pos.y, pos.z, nil)   -- turtle's own position is always air

    local fdx, fdz = frontDelta()
    local ok, data = turtle.inspect()
    setBlock(pos.x + fdx, pos.y, pos.z + fdz, ok and data.name or nil)

    ok, data = turtle.inspectUp()
    setBlock(pos.x, pos.y + 1, pos.z, ok and data.name or nil)

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

-- ── Surroundings ──────────────────────────────────────────────────────────────
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

-- ── Peripheral slot tracking ──────────────────────────────────────────────────
-- CC has no read API for what's equipped, so we track it ourselves.
-- Both start nil (unknown) until an equip command is issued this session.
local equippedLeft  = nil
local equippedRight = nil

-- ── Command execution ─────────────────────────────────────────────────────────
local lastResult = nil

local function executeCommand(cmd)
    local action = cmd.action
    local ok, result = false, nil

    if action == "forward" then
        local old = {x=pos.x, y=pos.y, z=pos.z}
        ok, result = turtle.forward()
        if ok then
            pos.x = pos.x + DX[facing]; pos.z = pos.z + DZ[facing]
            setBlock(old.x, old.y, old.z, nil)
            inspectAround()
        end
    elseif action == "back" then
        local old = {x=pos.x, y=pos.y, z=pos.z}
        ok, result = turtle.back()
        if ok then
            pos.x = pos.x - DX[facing]; pos.z = pos.z - DZ[facing]
            setBlock(old.x, old.y, old.z, nil)
            inspectAround()
        end
    elseif action == "up" then
        local old = {x=pos.x, y=pos.y, z=pos.z}
        ok, result = turtle.up()
        if ok then
            pos.y = pos.y + 1
            setBlock(old.x, old.y, old.z, nil)
            inspectAround()
        end
    elseif action == "down" then
        local old = {x=pos.x, y=pos.y, z=pos.z}
        ok, result = turtle.down()
        if ok then
            pos.y = pos.y - 1
            setBlock(old.x, old.y, old.z, nil)
            inspectAround()
        end
    elseif action == "turnLeft" then
        ok = turtle.turnLeft()
        if ok then
            facing = (facing - 1) % 4
            syncFacing()   -- correct any drift against real yaw
            inspectAround()
        end
    elseif action == "turnRight" then
        ok = turtle.turnRight()
        if ok then
            facing = (facing + 1) % 4
            syncFacing()
            inspectAround()
        end

    elseif action == "dig"      then
        ok, result = turtle.dig()
        if ok then
            local fdx, fdz = frontDelta()
            setBlock(pos.x + fdx, pos.y, pos.z + fdz, nil)
        end
    elseif action == "digUp"    then
        ok, result = turtle.digUp()
        if ok then setBlock(pos.x, pos.y + 1, pos.z, nil) end
    elseif action == "digDown"  then
        ok, result = turtle.digDown()
        if ok then setBlock(pos.x, pos.y - 1, pos.z, nil) end

    elseif action == "place"    then
        ok, result = turtle.place()
        if ok then
            local fdx, fdz = frontDelta()
            local iok, idata = turtle.inspect()
            setBlock(pos.x + fdx, pos.y, pos.z + fdz, iok and idata.name or nil)
        end
    elseif action == "placeUp"  then
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

    elseif action == "equipLeft" then
        -- Record what's in the selected slot before equipping
        local slot = turtle.getSelectedSlot()
        local incoming = turtle.getItemDetail(slot, false)
        ok = turtle.equipLeft()
        if ok then
            -- incoming item is now in the left peripheral slot
            -- whatever was there before is now in the selected slot
            local swappedOut = equippedLeft
            equippedLeft = incoming and {
                name        = incoming.name,
                displayName = incoming.displayName or incoming.name,
                count       = incoming.count,
            } or nil
            result = swappedOut and swappedOut.displayName or "empty"
            initModules()
        end

    elseif action == "equipRight" then
        local slot = turtle.getSelectedSlot()
        local incoming = turtle.getItemDetail(slot, false)
        ok = turtle.equipRight()
        if ok then
            local swappedOut = equippedRight
            equippedRight = incoming and {
                name        = incoming.name,
                displayName = incoming.displayName or incoming.name,
                count       = incoming.count,
            } or nil
            result = swappedOut and swappedOut.displayName or "empty"
            initModules()
        end

    elseif action == "refuel"   then
        ok = turtle.refuel(cmd.count or 64)
        result = tostring(turtle.getFuelLevel())
    elseif action == "drop"     then ok, result = turtle.drop(cmd.count)
    elseif action == "dropUp"   then ok, result = turtle.dropUp(cmd.count)
    elseif action == "dropDown" then ok, result = turtle.dropDown(cmd.count)
    elseif action == "suck"     then ok, result = turtle.suck(cmd.count)
    elseif action == "suckUp"   then ok, result = turtle.suckUp(cmd.count)
    elseif action == "suckDown" then ok, result = turtle.suckDown(cmd.count)

    elseif action == "reboot" then
        print("Reboot requested by control panel.")
        sleep(0.5)
        os.reboot()   -- does not return

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
        entities      = lastEntities,
        last_result   = lastResult,
        block_delta   = flushDirty(),
        map_size      = mapSize,
        has_scanner   = hasMethod("scan"),
        has_sensor    = hasMethod("sense"),
        has_rotation  = hasMethod("getRotation"),
        equipped      = { left = equippedLeft, right = equippedRight },
    }
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
    print("RC-CCT-T Turtle v3.0")
    term.setTextColor(colors.white)

    selfUpdate()   -- check GitHub for a newer version first; reboots if updated

    initModules()

    -- Seed the map with what's immediately around us
    inspectAround()

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

    local pollUrl   = serverUrl .. "/api/turtle/poll"
    local pollCount = 0
    local failures  = 0

    while true do
        pollCount = pollCount + 1

        -- Periodic full scanner + sensor sweep
        if pollCount % SCAN_EVERY == 0 then
            runScanner()
            runSensor()
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
