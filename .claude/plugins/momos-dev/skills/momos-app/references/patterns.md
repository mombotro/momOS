# momOS App Patterns

## Save / Load a File

```lua
local PATH = "/home/myapp.dat"

local function save(data)
  local ok = fs.write(PATH, data)
  if ok then sys.save() end  -- persist to disk
  return ok
end

local function load_data()
  return fs.read(PATH)  -- nil if not found
end
```

## Extension-Safe Path Handling

Always check for any extension before appending a default:

```lua
local function ensure_ext(path, ext)
  if not path:match("%.%w+$") then
    return path .. ext
  end
  return path
end

local path = ensure_ext(input_path, ".myext")
```

## Status Bar Pattern

```lua
local status = ""
local status_t = 0

local function set_status(s)
  status = s
  status_t = 90  -- show for ~1.5 seconds
end

-- In draw():
if status_t > 0 then
  gfx.rect(0, WIN_H - 10, WIN_W, 10, 1)
  gfx.print(status, 2, WIN_H - 9, 7)
  status_t = status_t - 1
end
```

## Mouse Hit Testing

```lua
local function hit(mx, my, x, y, w, h)
  return mx >= x and mx < x+w and my >= y and my < y+h
end

-- Usage in update or input handler:
local wx, wy = wm.rect(win)
local lx, ly = mouse.x() - wx, mouse.y() - wy
if mouse.btn(0) and hit(lx, ly, btn_x, btn_y, btn_w, btn_h) then
  -- button clicked
end
```

## Click Detection (Rising Edge)

```lua
local prev_btn = false

local function update()
  local btn = mouse.btn(0)
  local clicked = btn and not prev_btn  -- true only on frame button goes down
  prev_btn = btn

  if clicked then
    -- handle click
  end
end
```

## Scrollable List

```lua
local items = { "Alpha", "Beta", "Gamma", "Delta" }
local scroll = 0
local VISIBLE = 8
local ROW_H = 12

local function draw_list(x, y, w)
  for i = 1, math.min(VISIBLE, #items - scroll) do
    local item = items[i + scroll]
    gfx.print(item, x+2, y + (i-1)*ROW_H + 2, 7)
  end
end

-- In on_input:
if c == "\x01" then scroll = math.max(0, scroll - 1) end  -- up
if c == "\x02" then scroll = math.min(#items - VISIBLE, scroll + 1) end  -- down
```

## Simple Serialization

For structured data, use a simple key=value text format:

```lua
local function serialize(t)
  local parts = {}
  for k, v in pairs(t) do
    parts[#parts+1] = k.."="..tostring(v)
  end
  return table.concat(parts, "\n")
end

local function deserialize(s)
  local t = {}
  for line in s:gmatch("[^\n]+") do
    local k, v = line:match("^(%w+)=(.*)$")
    if k then t[k] = v end
  end
  return t
end
```

## IPC: Send and Receive

App A sends a message to App B:
```lua
-- App A (sender):
ipc.send("myapp_b", { action="open", path="/home/file.dat" })

-- App B (receiver) — add to returned app table:
local app = { draw=draw, update=update, input=on_input, win=win, name="B" }
app._msg = function(from, data)
  if data.action == "open" then
    open_file(data.path)
  end
end
return app
```

## Popup / Modal Dialog

```lua
local modal = nil

local function show_confirm(msg, on_yes, on_no)
  modal = { msg=msg, on_yes=on_yes, on_no=on_no }
end

-- In draw():
if modal then
  local mw, mh = 200, 60
  local mx = (WIN_W - mw)//2
  local my = (WIN_H - mh)//2
  gfx.rect(mx, my, mw, mh, 2)
  gfx.rectb(mx, my, mw, mh, 9)
  gfx.print(modal.msg, mx+8, my+12, 7)
  gfx.rect(mx+20, my+38, 60, 14, 3)
  gfx.print("Yes", mx+33, my+41, 7)
  gfx.rect(mx+120, my+38, 60, 14, 1)
  gfx.print("No", mx+134, my+41, 7)
end

-- In on_input():
if modal then
  if c == "y" or c == "\n" then modal.on_yes(); modal = nil end
  if c == "n" or c == "\x1b" then modal.on_no(); modal = nil end
  return  -- block input to app while modal is up
end
```

## Text Input Field

```lua
local field = ""
local cursor = 0

local function field_input(c)
  if c == "\x08" then  -- backspace
    if #field > 0 then field = field:sub(1, -2) end
  elseif c == "\n" then
    -- submit field
  elseif #c == 1 and c:byte(1) >= 32 then
    field = field .. c
  end
end

-- In draw():
gfx.rect(fx, fy, fw, 12, 1)
gfx.print(field, fx+2, fy+2, 7)
-- cursor blink
if sys.ticks() % 60 < 30 then
  gfx.rect(fx + 2 + #field*8, fy+2, 1, 8, 7)
end
```

## Opening Files from the File Manager

Set a global before launching the app:

```lua
-- In the file manager or shelf:
myapp_open_file = "/home/file.ext"
app_launch("/apps/myapp.lua")

-- In myapp.lua (module level, before returning the app table):
if myapp_open_file then
  local p = myapp_open_file
  myapp_open_file = nil
  open_file(p)
end
```

Use a unique global name per app to avoid collisions.

## Timed Animation

```lua
local FRAMES = 4
local frame = 1
local frame_timer = 0
local FRAME_SPEED = 10  -- ticks per frame

function game._update()
  frame_timer = frame_timer + 1
  if frame_timer >= FRAME_SPEED then
    frame_timer = 0
    frame = frame % FRAMES + 1
  end
end
```

## Palette Swap Effect

```lua
-- Flash an entity red for 10 frames
local flash_timer = 0

function game._update()
  if hit_detected then flash_timer = 10 end
  if flash_timer > 0 then
    flash_timer = flash_timer - 1
    gfx.set_pal(7, 255, 50, 50)   -- white → red
  else
    gfx.set_pal(7, 255, 255, 255) -- restore
  end
end
```
