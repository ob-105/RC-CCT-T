-- RC-CCT-T  Turtle client  v1.0
-- Polls a Python control server whose URL is published to GitHub.
-- Place this file on the turtle and run it.  Position tracking starts from
-- wherever the turtle is when the script is launched (0,0,0 facing north).

local GITHUB_API  = "https://api.github.com/repos/ob-105/RC-CCT-T/contents/url.txt"
local POLL_SECS   = 0.5   -- how often to poll the server for commands
local URL_TIMEOUT = 10    -- seconds between GitHub URL re-checks on failure

-- ── Base-64 decoder (needed to read GitHub API responses) ────────────────────
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

-- ── Fetch server URL from GitHub ─────────────────────────────────────────────
local function fetchServerUrl()
    local ok, resp = pcall(http.get, GITHUB_API, {
        ["Accept"]     = "application/vnd.github.v3+json",
        ["User-Agent"] = "CC-Turtle/1.0",
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

-- ── Position / facing tracking ───────────────────────────────────────────────
local pos    = { x = 0, y = 0, z = 0 }
local facing = 0   -- 0=north 1=east 2=south 3=west
local FACING_NAMES = { [0]="north", [1]="east", [2]="south", [3]="west" }
-- Forward-movement deltas per facing direction
local DX = { [0]=0,  [1]=1,  [2]=0,  [3]=-1 }
local DZ = { [0]=-1, [1]=0,  [2]=1,  [3]=0  }

-- ── Inventory snapshot ───────────────────────────────────────────────────────
local function getInventory()
    local inv = {}
    for i = 1, 16 do
        local d = turtle.getItemDetail(i, false)
        if d then
            inv[i] = {
                name        = d.name,
                displayName = d.displayName or d.name,
                count       = d.count,
                maxCount    = d.maxCount or 64,
            }
        else
            inv[i] = nil  -- textutils.serializeJSON treats nil slots as null
        end
    end
    return inv
end

-- ── Surroundings (what is adjacent to the turtle) ───────────────────────────
local function getSurroundings()
    local function insp(fn)
        local ok, data = fn()
        if ok then return data end
        return nil
    end
    return {
        front = insp(turtle.inspect),
        up    = insp(turtle.inspectUp),
        down  = insp(turtle.inspectDown),
    }
end

-- ── Execute one command received from the server ─────────────────────────────
local lastResult = nil

local function executeCommand(cmd)
    local action = cmd.action
    local ok, result = false, nil

    if action == "forward" then
        ok, result = turtle.forward()
        if ok then
            pos.x = pos.x + DX[facing]
            pos.z = pos.z + DZ[facing]
        end

    elseif action == "back" then
        ok, result = turtle.back()
        if ok then
            pos.x = pos.x - DX[facing]
            pos.z = pos.z - DZ[facing]
        end

    elseif action == "up" then
        ok, result = turtle.up()
        if ok then pos.y = pos.y + 1 end

    elseif action == "down" then
        ok, result = turtle.down()
        if ok then pos.y = pos.y - 1 end

    elseif action == "turnLeft" then
        ok = turtle.turnLeft()
        if ok then facing = (facing - 1) % 4 end

    elseif action == "turnRight" then
        ok = turtle.turnRight()
        if ok then facing = (facing + 1) % 4 end

    elseif action == "dig"     then ok, result = turtle.dig()
    elseif action == "digUp"   then ok, result = turtle.digUp()
    elseif action == "digDown" then ok, result = turtle.digDown()

    elseif action == "place"     then ok, result = turtle.place()
    elseif action == "placeUp"   then ok, result = turtle.placeUp()
    elseif action == "placeDown" then ok, result = turtle.placeDown()

    elseif action == "select" then
        if cmd.slot then ok = turtle.select(cmd.slot) end

    elseif action == "equipLeft"  then ok = turtle.equipLeft()
    elseif action == "equipRight" then ok = turtle.equipRight()

    elseif action == "refuel" then
        ok = turtle.refuel(cmd.count or 64)
        result = tostring(turtle.getFuelLevel())

    elseif action == "drop"     then ok, result = turtle.drop(cmd.count)
    elseif action == "dropUp"   then ok, result = turtle.dropUp(cmd.count)
    elseif action == "dropDown" then ok, result = turtle.dropDown(cmd.count)

    elseif action == "suck"     then ok, result = turtle.suck(cmd.count)
    elseif action == "suckUp"   then ok, result = turtle.suckUp(cmd.count)
    elseif action == "suckDown" then ok, result = turtle.suckDown(cmd.count)

    elseif action == "inspect" then
        local fok, fdata = turtle.inspect()
        local uok, udata = turtle.inspectUp()
        local dok, ddata = turtle.inspectDown()
        ok = true
        result = {
            front = fok and fdata or nil,
            up    = uok and udata or nil,
            down  = dok and ddata or nil,
        }

    else
        ok, result = false, "unknown action: " .. tostring(action)
    end

    lastResult = { ok = ok, action = action, result = result }
    return lastResult
end

-- ── Build the status payload to POST to the server ───────────────────────────
local function buildStatus()
    return {
        position     = pos,
        facing       = FACING_NAMES[facing],
        fuel         = turtle.getFuelLevel(),
        fuel_limit   = turtle.getFuelLimit(),
        inventory    = getInventory(),
        selected_slot = turtle.getSelectedSlot(),
        surroundings = getSurroundings(),
        last_result  = lastResult,
    }
end

-- ── HTTP helpers ─────────────────────────────────────────────────────────────
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

-- ── Main loop ─────────────────────────────────────────────────────────────────
local serverUrl = nil

local function main()
    term.setTextColor(colors.cyan)
    print("RC-CCT-T Turtle v1.0")
    term.setTextColor(colors.white)

    -- Discover server URL
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

    local pollUrl  = serverUrl .. "/api/turtle/poll"
    local failures = 0

    while true do
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
                print("Re-checking GitHub for new URL…")
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
