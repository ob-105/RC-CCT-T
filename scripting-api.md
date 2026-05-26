# Plethora NeoForge Scripting API (Current Port)

This file tracks scripting-facing API behavior that has been implemented in the NeoForge port.
It is meant to be a practical reference while writing Lua scripts.

## Status

- Target: Minecraft 1.21.1 + NeoForge
- Scope: Methods currently registered and callable from module containers
- Note: This is a live document and should be updated whenever API-facing behavior changes

## Core Module Container Methods

These methods are available on module containers (for example manipulator/neural module peripheral contexts):

- listModules()
  - Returns: table (1-indexed array of module ids)
- hasModule(module)
  - Args:
    - module: string (resource id like plethora:sensor)
  - Returns: boolean
- filterModules(...names)
  - Args:
    - names: string...
  - Returns: table|nil (filtered object exposing matching module methods)
- getDocs([name])
  - Args:
    - name: optional string
  - Returns: string|table

### Example

```lua
local methods = peripheral.call(side, "listModules")
print(textutils.serialize(methods))

if peripheral.call(side, "hasModule", "plethora:sensor") then
  local docs = peripheral.call(side, "getDocs", "sense")
  print(docs)
end

local filtered = peripheral.call(side, "filterModules", "plethora:sensor", "plethora:introspection")
print(filtered and filtered.getDocs and filtered.getDocs() or "no match")
```

## Scanner Module (plethora:scanner)

- scan([radius])
  - Returns nearby block snapshot list.
  - Each entry includes:
    - x, y, z: relative coordinates
    - name: block id
    - air: boolean
    - hardness: number
- getBlockMeta(x, y, z)
  - Args are relative coordinates.
  - Returns block info table with same baseline fields as scan entries.

### Example

```lua
local blocks = peripheral.call(side, "scan", 8)
for i, block in ipairs(blocks) do
  print(i, block.name, block.x, block.y, block.z)
end

local meta = peripheral.call(side, "getBlockMeta", 1, 0, 0)
print(meta.name, meta.hardness)
```

## Sensor Module (plethora:sensor)

- sense([radius])
  - Returns nearby entity snapshot list.
  - Each entry includes:
    - id: UUID string
    - name: display name string
    - type: entity type id
    - x, y, z: relative coordinates
    - health: number (when entity is living)
- getMetaByID(id)
  - Args:
    - id: UUID string
  - Returns: table|nil (entity metadata for a nearby match)
- getMetaByName(name)
  - Args:
    - name: player name string
  - Returns: table|nil (player metadata for a nearby match)

### Example

```lua
local entities = peripheral.call(side, "sense", 16)
for i, entity in ipairs(entities) do
  print(i, entity.name, entity.type, entity.id)
end

local alice = peripheral.call(side, "getMetaByName", "Alice")
if alice then
  print(alice.name, alice.x, alice.y, alice.z)
end
```

## Introspection Module (plethora:introspection)

- getID()
  - Returns owner/origin entity UUID string.
- getName()
  - Returns owner/origin entity display name.
- getRotation()
  - Returns: yaw, pitch (both numbers, in degrees) for the owner/origin entity.
  - Availability: exposed when either sensor or introspection module is present.
- getMetaOwner()
  - Returns metadata table for owner/origin entity.
- getInventory()
  - Player-only.
  - Returns sparse 1-indexed table of non-empty slots.
  - Slot value fields:
    - name
    - displayName
    - count
    - maxCount
    - damage
    - maxDamage
    - nbtHash (currently null placeholder)
- getInventory([playerName])
  - If playerName is provided, returns that online player's inventory snapshot.
  - If omitted, keeps existing behavior (origin player inventory).
- getEnder()
  - Player-only.
  - Same return shape as getInventory().
- getEnder([playerName])
  - If playerName is provided, returns that online player's ender chest snapshot.
  - If omitted, keeps existing behavior (origin player ender chest).
- getEquipment()
  - Living-entity-only.
  - Returns table with keys:
    - mainhand
    - offhand
    - head
    - chest
    - legs
    - feet
  - Each slot uses the same item fields as getInventory().
- getEquipment([playerName])
  - If playerName is provided, returns that online player's equipment snapshot.
  - If omitted, keeps existing behavior (origin living entity equipment).

### Example

```lua
print(peripheral.call(side, "getID"))
print(peripheral.call(side, "getName"))

local yaw, pitch = peripheral.call(side, "getRotation")
print(yaw, pitch)

local inventory = peripheral.call(side, "getInventory")
print(textutils.serialize(inventory))

local ender = peripheral.call(side, "getEnder", "dev")
print(textutils.serialize(ender))

local equipment = peripheral.call(side, "getEquipment")
print(textutils.serialize(equipment))
```

### Introspection Item Behavior

- Right-clicking the introspection module item opens the player's ender chest.

## Kinetic Module (plethora:kinetic)

- launch(yaw, pitch, power)
  - Launches origin living entity in a direction.
- look(yaw, pitch)
  - Sets look direction of the origin living entity.
- disableAI()
  - Mob-only.
  - Disables AI for the origin mob.
- enableAI()
  - Mob-only.
  - Re-enables AI for the origin mob.
- walk(x, y, z)
  - Mob-only.
  - Attempts to pathfind to a relative destination.
  - Returns: boolean, string|nil
- isWalking()
  - Mob-only.
  - Returns whether current pathfinding is active.
- propel([power])
  - Pushes the origin entity in its current look direction.
- teleport(x, y, z)
  - Teleports the origin entity to a relative coordinate.
  - Returns: boolean, string|nil
- explode([power])
  - Triggers a local explosion centered on the origin entity.
  - Returns table with explosion confirmation and used power.
- shoot(yaw, pitch, [power])
  - Fires a kinetic hit-scan shot.
  - Returns a result table with hit information.
  - Includes: power, range, hitBlock, and block hit metadata when a block is struck.
- swing([hand])
  - Living-entity-only.
  - hand: optional string (`main` or `offhand`), default `main`.
- use([hand])
  - Player-only.
  - Uses held item in selected hand.
  - Returns: boolean, string|nil
- takeControl(playerName)
  - Living-entity-only.
  - Starts first-pass neural possession for the named online player.
  - Forces that player's camera onto this entity and relays movement/looking.
  - Sneak exits control.
  - Returns: boolean, string|nil
- releaseControl([playerName])
  - Living-entity-only.
  - Releases neural possession for this entity.
  - If playerName is omitted, releases whoever is controlling this entity.
  - Returns: boolean

### Example

```lua
local ok, err = peripheral.call(side, "takeControl", "dev")
print(ok, err or "")

-- Later, from the controlled entity context:
local released = peripheral.call(side, "releaseControl")
print(released)
```

## Laser Module (plethora:laser)

- fire(yaw, pitch, [power])
  - Fires a laser ray and returns result table:
    - fired: true
    - power: number
    - range: number
    - hit: boolean
    - target: string (when hit)
    - targetType: string (when hit)
    - hitBlock: boolean
    - blockX, blockY, blockZ, blockFace (when a block is hit)

### Example

```lua
local shot = peripheral.call(side, "fire", 0, 0, 4)
print(textutils.serialize(shot))
```

## Glasses Module (plethora:glasses)

Current implementation is a minimal synced canvas/object path for 2D overlays.

- canvas()
  - Returns a 2D canvas object.
- canvas3d()
  - Returns a 3D canvas root object.

### Shared Glasses Object Methods

- clear()
  - On groups/canvases, removes all child objects.
- remove()
  - On objects, removes that object from its parent group.

### Rendering Notes

- Dot and Line objects now render on the client HUD for the local goggles wearer.
- Rectangle and Text objects now render on the client HUD for the local goggles wearer.
- State is synced through module data and read by a minimal client overlay renderer.
- Current renderer scope is intentionally 2D overlay focused.
- First-pass canvas3d projection rendering is available for 3D dots/lines.
- Client-to-server glasses interaction events are now forwarded to neural computers for active glasses sessions.
- Implemented events: `glasses_click`, `glasses_up`, `glasses_drag`, `glasses_scroll`.
- Event args:
  - click/up/drag: `(x, y, button)`
  - scroll: `(x, y, direction)` where direction is `1` or `-1`

### 2D Canvas/Group Methods

- getSize()
  - 2D canvas only.
  - Returns: width, height (currently 320, 240)
- addGroup(x, y)
  - Returns child group object.
- addRectangle(x, y, width, height[, colour])
  - Returns rectangle object.
- addText(x, y, contents[, colour[, scale]])
  - Returns text object.
- addDot(x, y[, size[, colour]])
  - Returns dot object.
  - Default size: 2.0
  - Default colour: white (0xFFFFFFFF)
- addLine(x1, y1, x2, y2[, width[, colour]])
  - Returns line object.
  - Default width: 1.0
  - Default colour: white (0xFFFFFFFF)
- setPosition(x, y)
  - Group position setter.
- setPosition3d(x, y, z)
  - Group 3D position setter.

### 3D Canvas Methods

- addGroup3d(x, y, z)
  - Returns child group object.
- addDot3d(x, y, z[, size[, colour]])
  - Returns 3D dot object.
  - Default size: 0.15
  - Default colour: white (0xFFFFFFFF)
- addLine3d(x1, y1, z1, x2, y2, z2[, width[, colour]])
  - Returns 3D line object.
  - Default width: 0.08
  - Default colour: white (0xFFFFFFFF)

### Rectangle Object Methods

- setPosition(x, y)
- setSize(width, height)
- setColour(colour)

### Text Object Methods

- setPosition(x, y)
- setText(contents)
- setScale(scale)
- setColour(colour)

### Dot Object Methods

- setPosition(x, y)
- setSize(size)
- setColour(colour)

### Line Object Methods

- setStart(x, y)
- setEnd(x, y)
- setWidth(width)
- setColour(colour)

### 3D Dot Object Methods

- setPosition(x, y, z)
- setSize(size)
- setColour(colour)

### 3D Line Object Methods

- setStart(x, y, z)
- setEnd(x, y, z)
- setWidth(width)
- setColour(colour)

### Example

```lua
local canvas = peripheral.call(side, "canvas")
local group = canvas.addGroup(10, 10)
group.addText(0, 0, "Plethora", 0xFFFF00)
group.addRectangle(0, 10, 80, 12, 0x202020)

local dot = canvas.addDot(40, 40, 3, 0xFF0000)
local line = canvas.addLine(10, 10, 60, 60, 2, 0xFFFFFF)

canvas.clear()
```

## Important Current Gaps (Known)

The original Plethora has broader behavior than what is listed above.
The following are not fully ported yet and should be treated as pending:

- Introspection: transfer-object style inventory handles (current impl returns snapshot tables)
- Glasses: full legacy object set (polygons/items/3d frame behaviors, richer text/shape rendering, mouse/event integration)
- Keyboard relay parity polish (current implementation relays key/key_up only; char/text composition parity is still pending)
- Remaining kinetic subtarget-specific methods (entity-class-specific shoot variants and advanced edge cases)

## Changelog

### 2026-05-18 (Current Session)

- Added glasses Dot object: addDot, with setPosition, setSize, setColour methods.
- Added glasses Line object: addLine, with setStart, setEnd, setWidth, setColour methods.
- Added minimal glasses client renderer path for synced 2D Dot/Line overlay display in goggles.
- Added introspection method: getRotation (yaw, pitch in degrees) for precise script-side projection.
- Updated getRotation availability: now exposed with sensor or introspection module.
- Expanded client glasses renderer: rectangle and text objects are now drawn in goggles.
- Added first-pass canvas3d API and rendering: addGroup3d, addDot3d, addLine3d, and 3D object mutators.
- Added kinetic methods: swing and use.
- Added kinetic possession methods: takeControl(playerName) and releaseControl([playerName]).
- Updated neural connector behavior: right-click living entities to attach/open neural interface on mob targets.
- Added non-Curios mob fallback: connector now mounts neural interfaces in head slot when curio inventory is unavailable.
- Updated possession movement relay: uses live player movement input axes for reliable WASD mob control.
- Added client->server possession input packets for camera-control mode, ensuring WASD/jump/sprint input reaches controlled mobs reliably.
- Updated possession packet data to include camera yaw/pitch so look direction and forward/back movement stay aligned with player view.
- Expanded introspection inventory access: getInventory([playerName]) and getEnder([playerName]) now support querying any online player's inventory by name.
- Added kinetic methods: propel, teleport, explode, and shoot.
- Laser fire now includes block-hit and range details and respects block occlusion before entity hits.
- Added kinetic method: enableAI.
- Added glasses interaction event relay from client input: `glasses_click`, `glasses_up`, and `glasses_drag`.
- Added glasses interaction event relay: `glasses_scroll`.
- Kinetic `shoot` now respects block occlusion and returns block-hit metadata.
- Added first-pass neural keyboard relay outside keyboard GUI using standard ComputerCraft `key` and `key_up` events for interfaces with the keyboard module.
- Expanded introspection equipment access: getEquipment([playerName]) now supports querying any online player's equipment by name.

### 2026-05-19

- Added and expanded practical Lua examples for the main non-cheat scripting surfaces.

### 2026-05-18
- Added introspection methods: getInventory, getEnder, getEquipment.
- Added sensor methods: getMetaByID, getMetaByName.
- Added glasses methods: canvas, canvas3d, clear, remove, getSize, addGroup, addRectangle, addText, and basic object mutators.
- Added kinetic methods: look, disableAI, walk, isWalking.
- Added introspection module item right-click ender chest behavior.
