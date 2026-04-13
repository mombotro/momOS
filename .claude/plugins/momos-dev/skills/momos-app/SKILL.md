---
name: momOS App Development
description: This skill should be used when the user asks to "write a momOS app", "make a game for momOS", "create a momOS program", "add an app to momOS", "write Lua for momOS", "how do I make an app", or asks about the momOS Lua API, gfx, audio, fs, wm, input, mouse, sys, ipc, or lib/game.lua framework.
version: 1.0.0
---

# momOS App Development

momOS runs Lua 5.4 apps on a bare-metal i686 kernel. All apps share a single global Lua state. Every app is a `.lua` file that returns an app table with `draw`, `update`, and optionally `input` callbacks. Apps live in `initrd/apps/` and are packed into `initrd.lfs` at build time.

## App Structure

Every app returns a table that the scheduler calls each frame:

```lua
local WIN_W, WIN_H = 320, 240

local win = wm.open("My App", (640-WIN_W)//2, (480-WIN_H)//2, WIN_W, WIN_H)

local function draw()
  wm.focus(win)
  gfx.cls(0)
  gfx.print("Hello momOS!", 10, 10, 7)
  wm.unfocus()
end

local function update()
  -- game logic here, called every tick (~60/s)
end

local function on_input(c)
  if c == "\x1b" then wm.close(win); return "quit" end
end

return { draw=draw, update=update, input=on_input, win=win, name="My App" }
```

**Rules:**
- `draw()` must call `wm.focus(win)` / `wm.unfocus()` to scope drawing to the window
- `input(c)` receives one character at a time; return `"quit"` to close
- Return `nil` from `input` to keep running
- `update()` is called every frame even when not focused
- `name` is the string shown in the taskbar

## Game Framework (lib/game.lua)

For games, use the thin framework — it handles the boilerplate:

```lua
local game = dofile("/lib/game.lua")

function game._init()
  -- setup, called once
end

function game._update()
  if game.keypressed(game.KEY_LEFT) then x = x - 1 end
  if game.key(game.KEY_RIGHT) then x = x + 1 end  -- held
end

function game._draw()
  gfx.cls(0)
  gfx.rect(x, y, 8, 8, 7)
end

return game.run("My Game", 320, 240)
```

`game.keypressed(k)` — true only on the frame the key was first pressed  
`game.key(k)` — true while the key is held  
ESC automatically closes the window.

**Key constants:** `game.KEY_UP/DOWN/LEFT/RIGHT`, `game.KEY_ENTER`, `game.KEY_ESC`, `game.KEY_SPACE`, `game.KEY_Z`, `game.KEY_X`, `game.KEY_BACK`

## Core APIs

### gfx — Graphics

All drawing is clipped to the current window via `wm.focus(win)`.

```lua
gfx.cls(color)                        -- clear window to color
gfx.pset(x, y, color)                 -- draw pixel
gfx.pget(x, y)                        -- read pixel → color index
gfx.rect(x, y, w, h, color)           -- filled rectangle
gfx.rectb(x, y, w, h, color)          -- rectangle border only
gfx.line(x0, y0, x1, y1, color)       -- Bresenham line
gfx.circ(cx, cy, r, color)            -- circle outline
gfx.circfill(cx, cy, r, color)        -- filled circle
gfx.print(text, x, y, color)          -- draw text (8×8 font, fixed width)
gfx.set_pal(idx, r, g, b)             -- set palette entry (0–31)
gfx.get_pal(idx)                      -- get palette entry → r, g, b
```

Color indices 0–31. Color 0 = black/transparent in sprite editor. Default palette is 32-color.

`gfx.print` character width = 8px, height = 8px. No wrapping — handle manually.

### wm — Window Manager

```lua
local win = wm.open(title, x, y, w, h) -- create window, returns handle
wm.close(win)                           -- close/destroy window
wm.focus(win)                           -- scope drawing to this window
wm.unfocus()                            -- end scoped drawing
wm.raise(win)                           -- bring to front
wm.set_focused(win)                     -- give keyboard focus
wm.is_minimized(win)                    -- → bool
wm.minimize(win, bool)                  -- set minimized state
wm.rect(win)                            -- → x, y, w, h
wm.resize(win, w, h)                    -- resize window content area
wm.set_title(win, title)                -- update title bar text
```

Windows have a title bar (16px) and 1px border added automatically. `w`/`h` are the content area size.

### fs — Filesystem

```lua
fs.read(path)              -- → string (binary-safe) or nil
fs.write(path, data)       -- → bool; creates or overwrites
fs.list(path)              -- → array of {name, is_dir, size} or nil
fs.mkdir(path)             -- → bool
fs.delete(path)            -- → bool
fs.exists(path)            -- → bool
```

All paths are absolute from `/`. Files persist to disk only after `sys.save()`.

**Binary files** (`fs.read`/`fs.write`) handle null bytes correctly — safe for `.mpi`, `.msm`, `.mtm` data.

### input — Keyboard

```lua
input.key_down(name)   -- → bool; is named key currently held?
input.getchar()        -- → single char string or nil (non-blocking)
```

Key names: `"up"`, `"down"`, `"left"`, `"right"`, `"enter"`, `"backspace"`, `"escape"`, `"space"`, `"tab"`, letter/digit strings.

Arrow keys send byte sequences: up=`\x01`, down=`\x02`, left=`\x03`, right=`\x04`.

### mouse — Mouse

```lua
mouse.x()      -- cursor X in screen coords
mouse.y()      -- cursor Y in screen coords
mouse.btn(0)   -- left button held → bool
mouse.btn(1)   -- right button held → bool
```

To get mouse position relative to your window:
```lua
local wx, wy = wm.rect(win)
local mx, my = mouse.x() - wx, mouse.y() - wy
```

### audio — Sound

```lua
audio.set(ch, wave, freq, vol)   -- ch=0–3, wave 0–3, freq Hz, vol 0–255
audio.stop(ch)                   -- stop one channel
audio.stop_all()                 -- stop all channels
audio.beep(freq)                 -- PC speaker tone (0 = off)
audio.refill()                   -- pump DMA buffer (call each frame if using audio)
```

Wave types: 0=square, 1=sawtooth, 2=triangle, 3=noise.

### sys — System

```lua
sys.ticks()              -- uptime in PIT ticks (~60/s)
sys.mem()                -- free heap bytes
sys.save()               -- snapshot VFS to disk → bool, errmsg
sys.load()               -- reload VFS from disk → bool, errmsg
sys.shutdown()           -- power off (ACPI)
sys.reboot()             -- warm restart (kbd ctrl reset)
sys.spawn(path)          -- same as launch(path)
sys.kill(pid)            -- kill a process
sys.ps()                 -- list processes → array
sys.disk_ready()         -- → bool
```

### ipc — Inter-Process Communication

```lua
ipc.open(name)           -- register inbox named "name"
ipc.send(name, data)     -- send data table to named process
-- receive via _msg(from, data) callback on app table
```

Set `app._msg = function(from, data) ... end` on your returned app table.

## File Formats

| Extension | Editor | Description |
|-----------|--------|-------------|
| `.lua`    | Quill  | Lua source; run with `launch(path)` |
| `.mpi`    | Pixel  | Sprite/image (MPI1 binary, up to 128×128, 4 layers, 16 frames) |
| `.msm`    | Chirp  | Music tracker (4 channels, 64 patterns × 32 rows) |
| `.mtm`    | Terrain| Tile map (up to 256×256, 4 tile layers + object layer) |

## Global Handoff Pattern

To open a file in an app from another app (e.g. file manager → Pixel):

```lua
-- Sender (e.g. files.lua):
pixel_open_file = "/home/mysprite.mpi"
app_launch("/apps/pixel.lua")

-- Receiver (pixel.lua, module level before returning):
if pixel_open_file then
  local p = pixel_open_file
  pixel_open_file = nil
  cmd_open(p)
end
```

Each app uses a dedicated global name: `pixel_open_file`, `quill_open_file`, `chirp_open_file`, `terrain_open_file`.

## App Deployment

1. Put the `.lua` file in `initrd/apps/`
2. Optionally add a desktop icon in `initrd/sys/main.lua`:
   ```lua
   add("myapp", 5, function() launch("/apps/myapp.lua") end)
   ```
3. Run `make` (from MSYS2) to rebuild `initrd.lfs` and `kernel.bin`
4. Run `make run` to test in QEMU

Desktop icon numbers map to palette colors for the icon background.

## dofile

Load and run another Lua file, returning its return value:

```lua
local lib = dofile("/lib/something.lua")
```

## Additional Resources

- **`references/api-full.md`** — complete API with all parameters and edge cases
- **`references/patterns.md`** — UI patterns, save/load, IPC, file pickers
- **`examples/hello.lua`** — minimal window app
- **`examples/game.lua`** — game using lib/game.lua
