-- pixel.lua — sprite / pixel-art editor
local WIN_W, WIN_H = 480, 360
local win = wm.open("pixel", 60, 30, WIN_W, WIN_H)
if not win then return nil end

local CW, CH = 8, 8

-- ── Layout ────────────────────────────────────────────────────────────────────
local SB_H   = CH + 2          -- status bar height at bottom
local TB_H   = CH + 2          -- top toolbar height
local TOOL_W = 24              -- left tool panel width
local RP_W   = 88              -- right panel (palette + frames)
local CANV_X = TOOL_W
local CANV_Y = TB_H
local CANV_W = WIN_W - TOOL_W - RP_W
local CANV_H = WIN_H - TB_H - SB_H

-- ── Colors ────────────────────────────────────────────────────────────────────
local C_BG      = 1
local C_PANEL   = 2
local C_FG      = 7
local C_DIM     = 8
local C_SEL     = 3
local C_BORDER  = 9
local C_WARN    = 4
local C_ACTIVE  = 15

-- ── Sprite data ───────────────────────────────────────────────────────────────
local spr = {
  w = 16, h = 16,
  num_frames = 1,
  num_layers = 1,
  pixels = {},    -- [frame][layer] = flat array of w*h palette indices (0=transparent)
}

local function make_frame(w, h)
  local layers = {}
  for l = 1, spr.num_layers do
    local px = {}
    for i = 1, w * h do px[i] = 0 end
    layers[l] = px
  end
  return layers
end

local function init_sprite(w, h, nf, nl)
  spr.w = w; spr.h = h
  spr.num_frames = nf or 1
  spr.num_layers = nl or 1
  spr.pixels = {}
  for f = 1, spr.num_frames do
    spr.pixels[f] = make_frame(w, h)
  end
end

init_sprite(16, 16, 1, 1)

-- ── Viewport ──────────────────────────────────────────────────────────────────
local zoom   = 8       -- pixels per cell
local pan_x  = 0       -- canvas offset (screen coords relative to CANV_X/Y)
local pan_y  = 0

local function fit_zoom()
  local zx = math.floor(CANV_W / spr.w)
  local zy = math.floor(CANV_H / spr.h)
  zoom = math.max(1, math.min(zx, zy))
  pan_x = math.floor((CANV_W - spr.w * zoom) / 2)
  pan_y = math.floor((CANV_H - spr.h * zoom) / 2)
end
fit_zoom()

local function canvas_to_pixel(cx, cy)
  -- cx/cy relative to CANV_X, CANV_Y
  local px = math.floor((cx - pan_x) / zoom)
  local py = math.floor((cy - pan_y) / zoom)
  if px < 0 or py < 0 or px >= spr.w or py >= spr.h then return nil, nil end
  return px, py
end

-- ── State ─────────────────────────────────────────────────────────────────────
local cur_frame  = 1
local cur_layer  = 1
local cur_color  = 1    -- palette index (1-31; 0=transparent eraser)
local cur_tool   = "pencil"   -- pencil eraser fill line rect eyedropper
local onion      = false
local playing    = false
local play_timer = 0
local PLAY_SPEED = 8    -- ticks per frame

-- line/rect preview state
local drag_start_px = nil
local drag_start_py = nil

-- undo: single level
local undo_data = nil   -- copy of pixels[cur_frame][cur_layer] before stroke

-- ── File ──────────────────────────────────────────────────────────────────────
local filepath = nil
local modified = false
local status   = ""
local status_t = 0

local function set_status(s) status = s; status_t = 60 end

-- ── Command bar ───────────────────────────────────────────────────────────────
local cmd_mode = false
local cmd_buf  = ""

-- ── .mpi serialise / parse ───────────────────────────────────────────────────
-- Header: "MPI1" (4) + w(1) + h(1) + layers(1) + frames(1) + reserved(8) = 16 bytes
-- Then pixel data: for each frame, for each layer: w*h bytes (palette index)

local function serialize()
  local parts = { "MPI1",
    string.char(spr.w), string.char(spr.h),
    string.char(spr.num_layers), string.char(spr.num_frames),
    string.rep("\0", 8) }
  for f = 1, spr.num_frames do
    for l = 1, spr.num_layers do
      local px = spr.pixels[f][l]
      local chunk = {}
      for i = 1, spr.w * spr.h do chunk[i] = string.char(px[i] or 0) end
      parts[#parts+1] = table.concat(chunk)
    end
  end
  return table.concat(parts)
end

local function deserialize(data)
  if #data < 16 then return false, "too short" end
  if data:sub(1,4) ~= "MPI1" then return false, "bad magic" end
  local w  = data:byte(5)
  local h  = data:byte(6)
  local nl = data:byte(7)
  local nf = data:byte(8)
  if w < 1 or h < 1 or nl < 1 or nf < 1 then return false, "bad dims" end
  local expected = 16 + w * h * nl * nf
  if #data < expected then return false, "truncated" end
  spr.w = w; spr.h = h; spr.num_layers = nl; spr.num_frames = nf
  spr.pixels = {}
  local pos = 17
  for f = 1, nf do
    spr.pixels[f] = {}
    for l = 1, nl do
      local px = {}
      for i = 1, w * h do
        px[i] = data:byte(pos); pos = pos + 1
      end
      spr.pixels[f][l] = px
    end
  end
  return true
end

-- ── Pixel ops ─────────────────────────────────────────────────────────────────
local function get_px(f, l, x, y)
  if x < 0 or y < 0 or x >= spr.w or y >= spr.h then return 0 end
  return spr.pixels[f][l][y * spr.w + x + 1] or 0
end

local function set_px(f, l, x, y, c)
  if x < 0 or y < 0 or x >= spr.w or y >= spr.h then return end
  spr.pixels[f][l][y * spr.w + x + 1] = c
  modified = true
end

local function copy_layer(f, l)
  local src = spr.pixels[f][l]
  local dst = {}
  for i = 1, #src do dst[i] = src[i] end
  return dst
end

local function save_undo()
  undo_data = { f=cur_frame, l=cur_layer, px=copy_layer(cur_frame, cur_layer) }
end

local function do_undo()
  if not undo_data then set_status("nothing to undo"); return end
  local d = undo_data
  spr.pixels[d.f][d.l] = d.px
  undo_data = nil
  modified = true
  set_status("undone")
end

-- ── Flood fill ────────────────────────────────────────────────────────────────
local function fill(x, y, target, replacement)
  if target == replacement then return end
  if get_px(cur_frame, cur_layer, x, y) ~= target then return end
  local stack = { {x, y} }
  while #stack > 0 do
    local p = table.remove(stack)
    local px, py = p[1], p[2]
    if get_px(cur_frame, cur_layer, px, py) == target then
      set_px(cur_frame, cur_layer, px, py, replacement)
      stack[#stack+1] = {px-1, py}
      stack[#stack+1] = {px+1, py}
      stack[#stack+1] = {px, py-1}
      stack[#stack+1] = {px, py+1}
    end
  end
end

-- ── Line / rect helpers ───────────────────────────────────────────────────────
local function draw_line_px(x0, y0, x1, y1, c, f, l)
  local dx = math.abs(x1-x0); local dy = math.abs(y1-y0)
  local sx = x0 < x1 and 1 or -1
  local sy = y0 < y1 and 1 or -1
  local err = dx - dy
  while true do
    set_px(f, l, x0, y0, c)
    if x0 == x1 and y0 == y1 then break end
    local e2 = 2 * err
    if e2 > -dy then err = err - dy; x0 = x0 + sx end
    if e2 <  dx then err = err + dx; y0 = y0 + sy end
  end
end

local function draw_rect_px(x0, y0, x1, y1, c, f, l)
  if x0 > x1 then x0, x1 = x1, x0 end
  if y0 > y1 then y0, y1 = y1, y0 end
  for x = x0, x1 do
    set_px(f, l, x, y0, c)
    set_px(f, l, x, y1, c)
  end
  for y = y0+1, y1-1 do
    set_px(f, l, x0, y, c)
    set_px(f, l, x1, y, c)
  end
end

-- Bresenham circle outline
local function draw_circle_px(cx, cy, r, c, f, l)
  if r < 0 then return end
  local x, y, d = 0, r, 1 - r
  local function plot8(px, py)
    set_px(f, l, cx+px, cy+py, c); set_px(f, l, cx-px, cy+py, c)
    set_px(f, l, cx+px, cy-py, c); set_px(f, l, cx-px, cy-py, c)
    set_px(f, l, cx+py, cy+px, c); set_px(f, l, cx-py, cy+px, c)
    set_px(f, l, cx+py, cy-px, c); set_px(f, l, cx-py, cy-px, c)
  end
  while x <= y do
    plot8(x, y)
    if d < 0 then d = d + 2*x + 3 else d = d + 2*(x-y) + 5; y = y - 1 end
    x = x + 1
  end
end

-- ── File open/save ────────────────────────────────────────────────────────────
local function cmd_save(path)
  path = path or filepath
  if not path then set_status("no filename — use :w <name>"); return end
  if not path:match("%.%w+$") then path = path..".mpi" end
  if fs.write(path, serialize()) then
    filepath = path; modified = false
    set_status("saved "..path)
  else
    set_status("write failed")
  end
end

local function cmd_open(path)
  if not path then set_status("usage: :o <file>"); return end
  if not path:match("%.%w+$") then path = path..".mpi" end
  local data = fs.read(path)
  if not data then set_status("not found: "..path); return end
  local ok, err = deserialize(data)
  if not ok then set_status("parse error: "..tostring(err)); return end
  filepath = path; modified = false
  cur_frame = 1; cur_layer = 1
  undo_data = nil
  fit_zoom()
  set_status("opened "..path)
end

local function cmd_new(arg)
  local w, h = 16, 16
  if arg then
    local a, b = arg:match("^(%d+)x(%d+)$")
    if a then w, h = tonumber(a), tonumber(b) end
  end
  w = math.max(1, math.min(128, w))
  h = math.max(1, math.min(128, h))
  init_sprite(w, h, 1, 1)
  filepath = nil; modified = false
  cur_frame = 1; cur_layer = 1
  undo_data = nil
  fit_zoom()
  set_status("new "..w.."x"..h)
end

-- consume global handoff — reuse cmd_open so errors are visible
if pixel_open_file then
  local p = pixel_open_file
  pixel_open_file = nil
  cmd_open(p)
end

-- ── Mouse state ───────────────────────────────────────────────────────────────
local prev_btn0    = false
local prev_btn1    = false
local drawing      = false   -- mid-stroke for pencil/eraser
local panning      = false
local pan_start_mx = 0
local pan_start_my = 0
local pan_start_ox = 0
local pan_start_oy = 0

-- ── Palette panel ─────────────────────────────────────────────────────────────
-- 32 colors, 8 cols × 4 rows in right panel
local PAL_CELL  = 10
local PAL_COLS  = 8
local PAL_ROWS  = 4
local PAL_X     = WIN_W - RP_W + 2
local PAL_Y     = TB_H + 2

-- ── Frame strip ───────────────────────────────────────────────────────────────
local FSTRIP_Y  = PAL_Y + PAL_ROWS * PAL_CELL + 6
local FTHUMB_W  = (RP_W - 6) // 4   -- up to 4 visible
local FTHUMB_H  = 24

-- ── Layer strip ───────────────────────────────────────────────────────────────
local LSTRIP_Y  = FSTRIP_Y + FTHUMB_H + 4 + CH + 2
local LROW_H    = CH + 2

-- ── Tool list ─────────────────────────────────────────────────────────────────
local tools = {
  { id="pencil",     label="P", key="p" },
  { id="eraser",     label="E", key="e" },
  { id="fill",       label="F", key="f" },
  { id="line",       label="L", key="l" },
  { id="rect",       label="R", key="r" },
  { id="circle",     label="O", key="c" },
  { id="select",     label="S", key="m" },
  { id="eyedrop",    label="K", key="k" },
}

-- ── Selection state ───────────────────────────────────────────────────────────
local sel = {
  active   = false,
  x1=0, y1=0, x2=0, y2=0,   -- canvas pixel coords (inclusive)
  dragging = false,           -- dragging to resize selection
  moving   = false,           -- dragging the selection contents
  move_sx  = 0, move_sy = 0, -- screen mouse coords at move start
  move_ox  = 0, move_oy = 0, -- selection origin at move start
  buf      = nil,             -- copied pixel data {w,h,px[]}
  buf_ox   = 0, buf_oy = 0,  -- where buf is currently placed
}

local function sel_clear()
  sel.active = false; sel.buf = nil
  sel.dragging = false; sel.moving = false
end

local function sel_copy()
  -- copy pixels from current layer into sel.buf
  local x1 = math.min(sel.x1, sel.x2)
  local y1 = math.min(sel.y1, sel.y2)
  local x2 = math.max(sel.x1, sel.x2)
  local y2 = math.max(sel.y1, sel.y2)
  local w  = x2 - x1 + 1
  local h  = y2 - y1 + 1
  local px = {}
  for dy = 0, h-1 do
    for dx = 0, w-1 do
      px[dy*w+dx+1] = get_px(cur_frame, cur_layer, x1+dx, y1+dy)
    end
  end
  sel.buf    = { w=w, h=h, px=px }
  sel.buf_ox = x1; sel.buf_oy = y1
end

local function sel_lift()
  -- erase from canvas, keep in buf
  if not sel.buf then sel_copy() end
  local x1 = math.min(sel.x1, sel.x2)
  local y1 = math.min(sel.y1, sel.y2)
  local x2 = math.max(sel.x1, sel.x2)
  local y2 = math.max(sel.y1, sel.y2)
  for dy = y1, y2 do
    for dx = x1, x2 do
      set_px(cur_frame, cur_layer, dx, dy, 0)
    end
  end
end

local function sel_stamp()
  -- paint sel.buf onto canvas at buf_ox/buf_oy
  if not sel.buf then return end
  local b = sel.buf
  for dy = 0, b.h-1 do
    for dx = 0, b.w-1 do
      local c = b.px[dy*b.w+dx+1]
      if c ~= 0 then
        set_px(cur_frame, cur_layer, sel.buf_ox+dx, sel.buf_oy+dy, c)
      end
    end
  end
end

-- ── Palette editor state ──────────────────────────────────────────────────────
local pal_edit = {
  open    = false,
  idx     = 0,       -- which palette entry is being edited
  h       = 0,       -- hue 0–359
  s       = 100,     -- saturation 0–100
  v       = 100,     -- value 0–100
  drag    = nil,     -- "h", "s", "v", or nil
}

local function hsv_to_rgb(h, s, v)
  s = s / 100; v = v / 100
  local c = v * s
  local x = c * (1 - math.abs((h/60) % 2 - 1))
  local m = v - c
  local r, g, b = 0, 0, 0
  if     h < 60  then r,g,b = c,x,0
  elseif h < 120 then r,g,b = x,c,0
  elseif h < 180 then r,g,b = 0,c,x
  elseif h < 240 then r,g,b = 0,x,c
  elseif h < 300 then r,g,b = x,0,c
  else                r,g,b = c,0,x end
  return math.floor((r+m)*255+0.5), math.floor((g+m)*255+0.5), math.floor((b+m)*255+0.5)
end

local function rgb_to_hsv(r, g, b)
  r,g,b = r/255, g/255, b/255
  local mx = math.max(r,g,b); local mn = math.min(r,g,b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then h = 60 * (((g-b)/d) % 6)
    elseif mx == g then h = 60 * ((b-r)/d + 2)
    else h = 60 * ((r-g)/d + 4) end
  end
  local s = mx > 0 and (d/mx)*100 or 0
  return math.floor(h+0.5), math.floor(s+0.5), math.floor(mx*100+0.5)
end

local function pal_edit_open(idx)
  pal_edit.open = true; pal_edit.idx = idx
  local r, g, b = gfx.get_pal(idx)
  pal_edit.h, pal_edit.s, pal_edit.v = rgb_to_hsv(r, g, b)
end

local function pal_edit_apply()
  local r, g, b = hsv_to_rgb(pal_edit.h, pal_edit.s, pal_edit.v)
  gfx.set_pal(pal_edit.idx, r, g, b)
end

-- ── Zoom helpers ──────────────────────────────────────────────────────────────
local ZOOM_LEVELS = {1,2,4,8,16,32}
local function zoom_in()
  for _, z in ipairs(ZOOM_LEVELS) do
    if z > zoom then zoom = z; return end
  end
end
local function zoom_out()
  for i = #ZOOM_LEVELS, 1, -1 do
    if ZOOM_LEVELS[i] < zoom then zoom = ZOOM_LEVELS[i]; return end
  end
end

-- ── Draw functions ────────────────────────────────────────────────────────────
local function draw_checkerboard(x, y, w, h)
  for cy = 0, h-1 do
    for cx = 0, w-1 do
      local c = ((cx + cy) % 2 == 0) and 8 or 1
      gfx.rect(x + cx, y + cy, 1, 1, c)
    end
  end
end

local function draw_canvas()
  -- clip canvas area
  local cw = spr.w * zoom
  local ch = spr.h * zoom
  local ox = CANV_X + pan_x
  local oy = CANV_Y + pan_y

  -- checkerboard background (transparent fill)
  for py = 0, spr.h - 1 do
    for px = 0, spr.w - 1 do
      local sx = ox + px * zoom
      local sy = oy + py * zoom
      if sx >= CANV_X and sy >= CANV_Y and
         sx + zoom <= CANV_X + CANV_W and sy + zoom <= CANV_Y + CANV_H then
        local checker = ((px + py) % 2 == 0) and 8 or 1
        gfx.rect(sx, sy, zoom, zoom, checker)
      end
    end
  end

  -- onion skin: previous frame, semi-visible
  if onion and cur_frame > 1 then
    for l = 1, spr.num_layers do
      local opx = spr.pixels[cur_frame - 1][l]
      for i = 1, spr.w * spr.h do
        local c = opx[i]
        if c ~= 0 then
          local px = (i-1) % spr.w
          local py = (i-1) // spr.w
          local sx = ox + px * zoom
          local sy = oy + py * zoom
          if sx >= CANV_X and sy >= CANV_Y then
            -- draw every other pixel as a dim version (onion effect)
            if (px + py) % 2 == 0 then
              gfx.rect(sx, sy, zoom, zoom, c)
            end
          end
        end
      end
    end
  end

  -- layers bottom to top
  for l = 1, spr.num_layers do
    local lpx = spr.pixels[cur_frame][l]
    for i = 1, spr.w * spr.h do
      local c = lpx[i]
      if c ~= 0 then
        local px = (i-1) % spr.w
        local py = (i-1) // spr.w
        local sx = ox + px * zoom
        local sy = oy + py * zoom
        if sx >= CANV_X and sy >= CANV_Y and
           sx + zoom <= CANV_X + CANV_W and sy + zoom <= CANV_Y + CANV_H then
          gfx.rect(sx, sy, zoom, zoom, c)
        end
      end
    end
  end

  -- pixel grid at zoom >= 4
  if zoom >= 4 then
    for px = 0, spr.w do
      local sx = ox + px * zoom
      if sx >= CANV_X and sx <= CANV_X + CANV_W then
        gfx.rect(sx, oy, 1, math.min(ch, CANV_H - pan_y), 0)
      end
    end
    for py = 0, spr.h do
      local sy = oy + py * zoom
      if sy >= CANV_Y and sy <= CANV_Y + CANV_H then
        gfx.rect(ox, sy, math.min(cw, CANV_W - pan_x), 1, 0)
      end
    end
  end

  -- selection overlay
  if sel.active then
    local sx1 = math.min(sel.x1, sel.x2)
    local sy1 = math.min(sel.y1, sel.y2)
    local sx2 = math.max(sel.x1, sel.x2)
    local sy2 = math.max(sel.y1, sel.y2)
    -- draw sel.buf contents (floating pixels)
    if sel.buf then
      local b = sel.buf
      for dy = 0, b.h-1 do
        for dx = 0, b.w-1 do
          local c = b.px[dy*b.w+dx+1]
          if c ~= 0 then
            local sx = ox + (sel.buf_ox+dx) * zoom
            local sy = oy + (sel.buf_oy+dy) * zoom
            if sx >= CANV_X and sy >= CANV_Y then
              gfx.rect(sx, sy, zoom, zoom, c)
            end
          end
        end
      end
    end
    -- marching-ants border (dashed)
    local tick = pit_ticks() // 8
    local bx0 = ox + sx1 * zoom; local by0 = oy + sy1 * zoom
    local bx1 = ox + (sx2+1) * zoom; local by1 = oy + (sy2+1) * zoom
    for sx = bx0, bx1-1 do
      local on = ((sx - tick) % 4) < 2
      gfx.rect(sx, by0, 1, 1, on and 7 or 0)
      gfx.rect(sx, by1, 1, 1, on and 7 or 0)
    end
    for sy = by0, by1 do
      local on = ((sy - tick) % 4) < 2
      gfx.rect(bx0, sy, 1, 1, on and 7 or 0)
      gfx.rect(bx1, sy, 1, 1, on and 7 or 0)
    end
  end

  -- line/rect/circle preview
  if drag_start_px and (cur_tool == "line" or cur_tool == "rect" or cur_tool == "circle") then
    local mx, my = mouse.x(), mouse.y()
    local wx, wy = wm.rect(win)
    local lx, ly = mx - wx - CANV_X, my - wy - CANV_Y
    local epx, epy = canvas_to_pixel(lx, ly)
    if epx and epy then
      -- draw preview pixels directly
      if cur_tool == "line" then
        local x0, y0 = drag_start_px, drag_start_py
        local x1, y1 = epx, epy
        local dx = math.abs(x1-x0); local dy = math.abs(y1-y0)
        local sx2 = x0 < x1 and 1 or -1
        local sy2 = y0 < y1 and 1 or -1
        local err2 = dx - dy
        local cx2, cy2 = x0, y0
        for _ = 1, 512 do
          local scx = ox + cx2 * zoom
          local scy = oy + cy2 * zoom
          if scx >= CANV_X and scy >= CANV_Y then
            gfx.rect(scx, scy, zoom, zoom, cur_color)
          end
          if cx2 == x1 and cy2 == y1 then break end
          local e2 = 2 * err2
          if e2 > -dy then err2 = err2 - dy; cx2 = cx2 + sx2 end
          if e2 <  dx then err2 = err2 + dx; cy2 = cy2 + sy2 end
        end
      elseif cur_tool == "rect" then
        local x0 = math.min(drag_start_px, epx)
        local x1 = math.max(drag_start_px, epx)
        local y0 = math.min(drag_start_py, epy)
        local y1 = math.max(drag_start_py, epy)
        for xi = x0, x1 do
          for yi = y0, y1 do
            if xi == x0 or xi == x1 or yi == y0 or yi == y1 then
              local scx = ox + xi * zoom
              local scy = oy + yi * zoom
              if scx >= CANV_X and scy >= CANV_Y then
                gfx.rect(scx, scy, zoom, zoom, cur_color)
              end
            end
          end
        end
      else -- circle preview
        local rcx = drag_start_px
        local rcy = drag_start_py
        local r   = math.floor(math.sqrt((epx-rcx)^2 + (epy-rcy)^2) + 0.5)
        -- sample Bresenham circle for preview
        local x2, y2, d2 = 0, r, 1 - r
        local function pplot8(px, py)
          for _, pp in ipairs({{rcx+px,rcy+py},{rcx-px,rcy+py},{rcx+px,rcy-py},
                                {rcx-px,rcy-py},{rcx+py,rcy+px},{rcx-py,rcy+px},
                                {rcx+py,rcy-px},{rcx-py,rcy-px}}) do
            local scx2 = ox + pp[1] * zoom
            local scy2 = oy + pp[2] * zoom
            if scx2 >= CANV_X and scy2 >= CANV_Y then
              gfx.rect(scx2, scy2, zoom, zoom, cur_color)
            end
          end
        end
        while x2 <= y2 do
          pplot8(x2, y2)
          if d2 < 0 then d2 = d2 + 2*x2 + 3 else d2 = d2 + 2*(x2-y2) + 5; y2 = y2 - 1 end
          x2 = x2 + 1
        end
      end
    end
  end

  -- canvas border
  gfx.rect(ox - 1, oy - 1, cw + 2, 1, C_BORDER)
  gfx.rect(ox - 1, oy - 1, 1, ch + 2, C_BORDER)
  gfx.rect(ox - 1, oy + ch, cw + 2, 1, C_BORDER)
  gfx.rect(ox + cw, oy - 1, 1, ch + 2, C_BORDER)
end

local function draw_tools()
  gfx.rect(0, TB_H, TOOL_W, CANV_H + SB_H, C_PANEL)
  for i, t in ipairs(tools) do
    local ty = TB_H + (i-1) * (CH + 4) + 2
    local bg = (t.id == cur_tool) and C_SEL or C_PANEL
    gfx.rect(2, ty, TOOL_W - 4, CH + 2, bg)
    gfx.print(t.label, 2 + (TOOL_W-4-CW)//2, ty + 1,
              t.id == cur_tool and C_ACTIVE or C_FG)
  end
  -- zoom indicator
  local zstr = zoom.."x"
  gfx.print(zstr, 2, WIN_H - SB_H - CH - 2, C_DIM)
end

local function draw_palette()
  gfx.rect(WIN_W - RP_W, TB_H, RP_W, WIN_H - TB_H, C_PANEL)
  gfx.print("PAL", PAL_X, TB_H + 1, C_DIM)
  for i = 0, 31 do
    local col = i % PAL_COLS
    local row = i // PAL_COLS
    local px = PAL_X + col * PAL_CELL
    local py = PAL_Y + CH + row * PAL_CELL
    gfx.rect(px, py, PAL_CELL - 1, PAL_CELL - 1, i)
    if i == cur_color then
      gfx.rect(px - 1, py - 1, PAL_CELL + 1, PAL_CELL + 1, C_ACTIVE)
      gfx.rect(px, py, PAL_CELL - 1, PAL_CELL - 1, i)
    end
  end
  -- current color swatch
  local sw_y = PAL_Y + CH + PAL_ROWS * PAL_CELL + 2
  gfx.rect(PAL_X, sw_y, 14, 14, cur_color)
  gfx.rect(PAL_X - 1, sw_y - 1, 16, 16, C_FG)
  gfx.rect(PAL_X, sw_y, 14, 14, cur_color)
  gfx.print(string.format("c%02d", cur_color), PAL_X + 17, sw_y + 3, C_DIM)
end

-- ── Palette editor overlay ────────────────────────────────────────────────────
local PE_W, PE_H = 200, 120
local PE_X = (WIN_W - PE_W) // 2
local PE_Y = (WIN_H - PE_H) // 2

local function draw_pal_editor()
  if not pal_edit.open then return end
  -- background
  gfx.rect(PE_X - 1, PE_Y - 1, PE_W + 2, PE_H + 2, C_BORDER)
  gfx.rect(PE_X, PE_Y, PE_W, PE_H, C_PANEL)
  gfx.print("PALETTE "..pal_edit.idx, PE_X + 4, PE_Y + 3, C_ACTIVE)

  local SLX = PE_X + 4
  local SL_W = PE_W - 60
  local COL_R, COL_G, COL_B = hsv_to_rgb(pal_edit.h, pal_edit.s, pal_edit.v)

  -- color preview swatch
  gfx.set_pal(pal_edit.idx, COL_R, COL_G, COL_B)
  gfx.rect(PE_X + SL_W + 12, PE_Y + 16, 32, 32, pal_edit.idx)
  gfx.rect(PE_X + SL_W + 11, PE_Y + 15, 34, 34, C_FG)
  gfx.rect(PE_X + SL_W + 12, PE_Y + 16, 32, 32, pal_edit.idx)

  -- RGB readout
  gfx.print(string.format("R%3d", COL_R), PE_X + SL_W + 12, PE_Y + 52, 8)
  gfx.print(string.format("G%3d", COL_G), PE_X + SL_W + 12, PE_Y + 62, 11)
  gfx.print(string.format("B%3d", COL_B), PE_X + SL_W + 12, PE_Y + 72, 12)

  -- H slider
  local H_Y = PE_Y + 18
  gfx.rect(SLX, H_Y, SL_W, 10, 0)
  for i = 0, SL_W-1 do
    local hr, hg, hb = hsv_to_rgb(math.floor(i / SL_W * 360), 100, 100)
    -- approximate with palette color; just show gradient ticks
    local hue_col = (math.floor(i / SL_W * 30)) % 30 + 1
    gfx.rect(SLX + i, H_Y + 1, 1, 8, hue_col)
  end
  local hx = SLX + math.floor(pal_edit.h / 360 * (SL_W - 1))
  gfx.rect(hx - 1, H_Y, 3, 10, C_FG)
  gfx.print("H", SLX + SL_W + 3, H_Y + 1, C_DIM)

  -- S slider
  local S_Y = PE_Y + 34
  gfx.rect(SLX, S_Y, SL_W, 10, 0)
  for i = 0, SL_W-1 do
    local sc = math.floor(i / SL_W * 15)
    gfx.rect(SLX + i, S_Y + 1, 1, 8, sc)
  end
  local sx2 = SLX + math.floor(pal_edit.s / 100 * (SL_W - 1))
  gfx.rect(sx2 - 1, S_Y, 3, 10, C_FG)
  gfx.print("S", SLX + SL_W + 3, S_Y + 1, C_DIM)

  -- V slider
  local V_Y = PE_Y + 50
  gfx.rect(SLX, V_Y, SL_W, 10, 0)
  for i = 0, SL_W-1 do
    local vc = math.floor(i / SL_W * 8) + 8  -- grays 8–15
    gfx.rect(SLX + i, V_Y + 1, 1, 8, vc)
  end
  local vx = SLX + math.floor(pal_edit.v / 100 * (SL_W - 1))
  gfx.rect(vx - 1, V_Y, 3, 10, C_FG)
  gfx.print("V", SLX + SL_W + 3, V_Y + 1, C_DIM)

  -- Instructions
  gfx.print("click sliders  ESC close", PE_X + 4, PE_Y + PE_H - CH - 4, C_DIM)
end

local function pal_editor_mouse(lx, ly, clicked)
  if not pal_edit.open then return false end
  -- check if click is inside pal editor
  if lx < PE_X or lx >= PE_X+PE_W or ly < PE_Y or ly >= PE_Y+PE_H then
    if clicked then pal_edit.open = false end
    return clicked
  end
  local SLX = PE_X + 4
  local SL_W = PE_W - 60
  -- H slider hit
  local H_Y = PE_Y + 18
  local S_Y = PE_Y + 34
  local V_Y = PE_Y + 50
  local function in_slider(sy) return lx >= SLX and lx < SLX+SL_W and ly >= sy and ly < sy+10 end
  if mouse.btn(0) then
    if in_slider(H_Y) or pal_edit.drag == "h" then
      pal_edit.drag = "h"
      pal_edit.h = math.floor((lx - SLX) / SL_W * 360)
      pal_edit.h = math.max(0, math.min(359, pal_edit.h))
      pal_edit_apply()
    elseif in_slider(S_Y) or pal_edit.drag == "s" then
      pal_edit.drag = "s"
      pal_edit.s = math.floor((lx - SLX) / SL_W * 100)
      pal_edit.s = math.max(0, math.min(100, pal_edit.s))
      pal_edit_apply()
    elseif in_slider(V_Y) or pal_edit.drag == "v" then
      pal_edit.drag = "v"
      pal_edit.v = math.floor((lx - SLX) / SL_W * 100)
      pal_edit.v = math.max(0, math.min(100, pal_edit.v))
      pal_edit_apply()
    end
  else
    pal_edit.drag = nil
  end
  return true
end

local function draw_frames()
  local fy = FSTRIP_Y
  gfx.print("FRM "..cur_frame.."/"..spr.num_frames, PAL_X, fy, C_DIM)
  fy = fy + CH + 1
  local visible = math.min(spr.num_frames, 4)
  for i = 1, visible do
    local fx = PAL_X + (i-1) * (FTHUMB_W + 1)
    local bg = (i == cur_frame) and C_SEL or C_PANEL
    gfx.rect(fx, fy, FTHUMB_W, FTHUMB_H, bg)
    -- mini thumbnail: sample top-left area only (cheap)
    local tw = math.min(spr.w, math.floor(FTHUMB_W) - 2)
    local th = math.min(spr.h, FTHUMB_H - 4)
    local scale_x = tw / spr.w
    local scale_y = th / spr.h
    -- draw 2×2 blocks to give a sense of the frame
    for ly2 = 0, th - 1 do
      for lx2 = 0, tw - 1 do
        local spx = math.floor(lx2 / scale_x)
        local spy = math.floor(ly2 / scale_y)
        local c = get_px(i, cur_layer, spx, spy)
        if c ~= 0 then
          gfx.rect(fx + 1 + lx2, fy + 2 + ly2, 1, 1, c)
        end
      end
    end
    gfx.print(tostring(i), fx + 2, fy + FTHUMB_H - CH - 1, C_DIM)
  end
end

local function draw_layers()
  local ly = LSTRIP_Y
  gfx.print("LYR "..cur_layer.."/"..spr.num_layers, PAL_X, ly, C_DIM)
  ly = ly + CH + 1
  for l = 1, spr.num_layers do
    local bg = (l == cur_layer) and C_SEL or C_PANEL
    gfx.rect(PAL_X, ly, RP_W - 4, LROW_H, bg)
    gfx.print("L"..l, PAL_X + 2, ly + 1, l == cur_layer and C_ACTIVE or C_FG)
    ly = ly + LROW_H + 1
  end
end

local function draw_toolbar()
  gfx.rect(0, 0, WIN_W, TB_H, C_PANEL)
  local title = filepath and filepath:match("[^/]+$") or "untitled.mpi"
  if modified then title = "*"..title end
  gfx.print(title, CANV_X + 2, 1, C_FG)
  local rinfo = (onion and "O " or "  ")..(playing and ">" or " ")
  gfx.print(rinfo, WIN_W - RP_W - #rinfo * CW - 2, 1, C_DIM)
  gfx.rect(0, TB_H - 1, WIN_W, 1, C_BORDER)
end

local function draw_status()
  gfx.rect(0, WIN_H - SB_H, WIN_W, SB_H, C_PANEL)
  gfx.rect(0, WIN_H - SB_H, WIN_W, 1, C_BORDER)
  local s
  if cmd_mode then
    s = ":"..cmd_buf.."_"
    gfx.print(s, 2, WIN_H - SB_H + 2, C_ACTIVE)
  else
    if status_t > 0 then
      gfx.print(status, 2, WIN_H - SB_H + 2, C_DIM)
    else
      -- show cursor pixel position
      local mx, my = mouse.x(), mouse.y()
      local wx, wy = wm.rect(win)
      local lx, ly = mx - wx - CANV_X, my - wy - CANV_Y
      local ppx, ppy = canvas_to_pixel(lx, ly)
      if ppx then
        gfx.print(string.format("%d,%d  z%dx  f%d/%d l%d/%d",
          ppx, ppy, zoom, cur_frame, spr.num_frames,
          cur_layer, spr.num_layers), 2, WIN_H - SB_H + 2, C_DIM)
      else
        gfx.print(string.format("z%dx  f%d/%d l%d/%d",
          zoom, cur_frame, spr.num_frames, cur_layer, spr.num_layers),
          2, WIN_H - SB_H + 2, C_DIM)
      end
    end
  end
end

local function draw()
  wm.focus(win)
  gfx.cls(C_BG)

  -- canvas background
  gfx.rect(CANV_X, CANV_Y, CANV_W, CANV_H, 0)

  draw_canvas()
  draw_tools()
  draw_palette()
  draw_frames()
  draw_layers()
  draw_toolbar()
  draw_status()
  draw_pal_editor()  -- modal overlay, draws on top if open

  wm.unfocus()
end

-- ── Command execution ─────────────────────────────────────────────────────────
local function exec_cmd(line)
  line = line:match("^%s*(.-)%s*$")
  if line == "w" then
    cmd_save()
  elseif line:sub(1,2) == "w " then
    cmd_save(line:sub(3))
  elseif line == "q" then
    if modified then set_status("unsaved changes — :w first") else return "quit" end
  elseif line == "wq" then
    cmd_save(); return "quit"
  elseif line == "help" then
    quill_open_file = "/docs/pixel.txt"
    if app_launch then app_launch("/apps/quill.lua") end
  elseif line:sub(1,2) == "o " then
    cmd_open(line:sub(3))
  elseif line:sub(1,2) == "n " then
    cmd_new(line:sub(3))
  elseif line == "n" then
    cmd_new()
  elseif line == "+f" then
    if spr.num_frames < 16 then
      spr.num_frames = spr.num_frames + 1
      spr.pixels[spr.num_frames] = make_frame(spr.w, spr.h)
      set_status("frame "..spr.num_frames.." added")
    else set_status("max 16 frames") end
  elseif line == "-f" then
    if spr.num_frames > 1 then
      spr.pixels[spr.num_frames] = nil
      spr.num_frames = spr.num_frames - 1
      if cur_frame > spr.num_frames then cur_frame = spr.num_frames end
      set_status("frame removed")
    else set_status("need at least 1 frame") end
  elseif line == "+l" then
    if spr.num_layers < 4 then
      spr.num_layers = spr.num_layers + 1
      for f = 1, spr.num_frames do
        spr.pixels[f][spr.num_layers] = {}
        for i = 1, spr.w * spr.h do spr.pixels[f][spr.num_layers][i] = 0 end
      end
      set_status("layer "..spr.num_layers.." added")
    else set_status("max 4 layers") end
  elseif line == "-l" then
    if spr.num_layers > 1 then
      for f = 1, spr.num_frames do spr.pixels[f][spr.num_layers] = nil end
      spr.num_layers = spr.num_layers - 1
      if cur_layer > spr.num_layers then cur_layer = spr.num_layers end
      set_status("layer removed")
    else set_status("need at least 1 layer") end
  else
    set_status("unknown: "..line)
  end
  return nil
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local function on_input(c)
  if cmd_mode then
    if c == "\n" then
      local result = exec_cmd(cmd_buf)
      cmd_mode = false; cmd_buf = ""
      if result == "quit" then
        wm.close(win); return "quit"
      end
    elseif c == "\x1b" then
      cmd_mode = false; cmd_buf = ""
    elseif c == "\b" then
      if #cmd_buf > 0 then cmd_buf = cmd_buf:sub(1, -2) end
    elseif c >= " " then
      cmd_buf = cmd_buf .. c
    end
    return
  end

  -- tool shortcuts
  for _, t in ipairs(tools) do
    if c == t.key then cur_tool = t.id; return end
  end

  if c == "\x1b" then
    if pal_edit.open then pal_edit.open = false; return end
    if sel.active then
      if sel.buf then save_undo(); sel_stamp() end
      sel_clear()
      return
    end
    cmd_mode = true; return
  end

  -- help
  if c == "?" then
    quill_open_file = "/docs/pixel.txt"
    if app_launch then app_launch("/apps/quill.lua") end
    return
  end

  -- zoom
  if c == "=" or c == "+" then zoom_in(); return end
  if c == "-" then zoom_out(); return end
  if c == "0" then fit_zoom(); return end

  -- undo
  if c == "z" then do_undo(); return end

  -- onion toggle
  if c == "o" then onion = not onion; set_status(onion and "onion on" or "onion off"); return end

  -- play toggle
  if c == " " then
    playing = not playing
    if spr.num_frames < 2 then playing = false; set_status("need >1 frame") end
    return
  end

  -- frame navigation
  if c == "\x03" then  -- left
    if cur_frame > 1 then cur_frame = cur_frame - 1 end
    return
  end
  if c == "\x04" then  -- right
    if cur_frame < spr.num_frames then cur_frame = cur_frame + 1 end
    return
  end

  -- layer navigation
  if c == "\x01" then  -- up
    if cur_layer > 1 then cur_layer = cur_layer - 1 end
    return
  end
  if c == "\x02" then  -- down
    if cur_layer < spr.num_layers then cur_layer = cur_layer + 1 end
    return
  end

  -- save shortcut
  if c == "s" then cmd_save(); return end
end

-- ── Mouse palette click ────────────────────────────────────────────────────────
local function try_palette_click(lx, ly)
  -- palette cells
  local py_base = PAL_Y + CH
  if lx >= PAL_X and lx < PAL_X + PAL_COLS * PAL_CELL and
     ly >= py_base and ly < py_base + PAL_ROWS * PAL_CELL then
    local col = math.floor((lx - PAL_X) / PAL_CELL)
    local row = math.floor((ly - py_base) / PAL_CELL)
    local idx = row * PAL_COLS + col
    if idx >= 0 and idx <= 31 then cur_color = idx; return true end
  end
  return false
end

local function try_palette_rclick(lx, ly)
  local py_base = PAL_Y + CH
  if lx >= PAL_X and lx < PAL_X + PAL_COLS * PAL_CELL and
     ly >= py_base and ly < py_base + PAL_ROWS * PAL_CELL then
    local col = math.floor((lx - PAL_X) / PAL_CELL)
    local row = math.floor((ly - py_base) / PAL_CELL)
    local idx = row * PAL_COLS + col
    if idx >= 0 and idx <= 31 then pal_edit_open(idx); return true end
  end
  return false
end

local function try_frame_click(lx, ly)
  local fy = FSTRIP_Y + CH + 1
  if ly >= fy and ly < fy + FTHUMB_H then
    for i = 1, math.min(spr.num_frames, 4) do
      local fx = PAL_X + (i-1) * (FTHUMB_W + 1)
      if lx >= fx and lx < fx + FTHUMB_W then
        cur_frame = i; return true
      end
    end
  end
  return false
end

local function try_layer_click(lx, ly)
  local start_y = LSTRIP_Y + CH + 1
  for l = 1, spr.num_layers do
    local row_y = start_y + (l-1) * (LROW_H + 1)
    if ly >= row_y and ly < row_y + LROW_H and
       lx >= PAL_X and lx < PAL_X + RP_W - 4 then
      cur_layer = l; return true
    end
  end
  return false
end

local function try_tool_click(lx, ly)
  if lx < 0 or lx >= TOOL_W then return false end
  for i, t in ipairs(tools) do
    local ty = TB_H + (i-1) * (CH + 4) + 2
    if ly >= ty and ly < ty + CH + 2 then
      cur_tool = t.id; return true
    end
  end
  return false
end

-- ── Update ────────────────────────────────────────────────────────────────────
local function update()
  if status_t > 0 then status_t = status_t - 1 end

  -- animation playback
  if playing then
    play_timer = play_timer + 1
    if play_timer >= PLAY_SPEED then
      play_timer = 0
      cur_frame = cur_frame % spr.num_frames + 1
    end
  end

  local mx, my = mouse.x(), mouse.y()
  local wx, wy = wm.rect(win)
  local btn0   = mouse.btn(0)   -- left
  local btn1   = mouse.btn(1)   -- right

  -- local coords inside our window
  local lx, ly = mx - wx, my - wy
  -- canvas-relative
  local cx, cy = lx - CANV_X, ly - CANV_Y

  -- ── right-click pan ────────────────────────────────────────────────────────
  if btn1 and not prev_btn1 then
    -- right-click on palette = open editor
    if lx >= WIN_W - RP_W then
      if not try_palette_rclick(lx, ly) then end
    -- right-click on canvas = pan
    elseif lx >= CANV_X and lx < CANV_X + CANV_W and
       ly >= CANV_Y and ly < CANV_Y + CANV_H then
      panning = true
      pan_start_mx = mx; pan_start_my = my
      pan_start_ox = pan_x; pan_start_oy = pan_y
    end
  end
  if panning then
    if btn1 then
      pan_x = pan_start_ox + (mx - pan_start_mx)
      pan_y = pan_start_oy + (my - pan_start_my)
    else
      panning = false
    end
  end
  prev_btn1 = btn1

  -- ── palette editor (modal — intercepts all input when open) ──────────────────
  if pal_edit.open then
    pal_editor_mouse(lx, ly, btn0 and not prev_btn0)
    prev_btn0 = btn0; prev_btn1 = btn1
    return
  end

  -- ── left-click actions ─────────────────────────────────────────────────────
  local in_canvas = (lx >= CANV_X and lx < CANV_X + CANV_W and
                     ly >= CANV_Y and ly < CANV_Y + CANV_H)

  if btn0 and not prev_btn0 then
    -- UI panel clicks first
    if lx >= WIN_W - RP_W then
      if not try_palette_click(lx, ly) and not try_frame_click(lx, ly) then
        try_layer_click(lx, ly)
      end
    elseif lx < CANV_X then
      try_tool_click(lx, ly)
    elseif in_canvas then
      local ppx, ppy = canvas_to_pixel(cx, cy)
      if ppx then
        if cur_tool == "pencil" then
          save_undo(); drawing = true
          set_px(cur_frame, cur_layer, ppx, ppy, cur_color)
        elseif cur_tool == "eraser" then
          save_undo(); drawing = true
          set_px(cur_frame, cur_layer, ppx, ppy, 0)
        elseif cur_tool == "fill" then
          save_undo()
          local target = get_px(cur_frame, cur_layer, ppx, ppy)
          fill(ppx, ppy, target, cur_color)
        elseif cur_tool == "eyedrop" then
          local c = get_px(cur_frame, cur_layer, ppx, ppy)
          if c ~= 0 then cur_color = c end
        elseif cur_tool == "line" or cur_tool == "rect" or cur_tool == "circle" then
          save_undo()
          drag_start_px = ppx; drag_start_py = ppy
        elseif cur_tool == "select" then
          if sel.active and sel.buf and
             ppx >= sel.buf_ox and ppx < sel.buf_ox + sel.buf.w and
             ppy >= sel.buf_oy and ppy < sel.buf_oy + sel.buf.h then
            sel.moving   = true
            sel.move_sx  = mx; sel.move_sy = my
            sel.move_ox  = sel.buf_ox; sel.move_oy = sel.buf_oy
          else
            if sel.active and sel.buf then save_undo(); sel_stamp() end
            sel_clear()
            sel.active = true; sel.dragging = true
            sel.x1 = ppx; sel.y1 = ppy; sel.x2 = ppx; sel.y2 = ppy
          end
        end
      end
    end
  end

  -- continue drawing stroke
  if btn0 and drawing and in_canvas then
    local ppx, ppy = canvas_to_pixel(cx, cy)
    if ppx then
      if cur_tool == "pencil" then
        set_px(cur_frame, cur_layer, ppx, ppy, cur_color)
      elseif cur_tool == "eraser" then
        set_px(cur_frame, cur_layer, ppx, ppy, 0)
      end
    end
  end

  -- drag select resize
  if btn0 and sel.dragging then
    local ppx, ppy = canvas_to_pixel(cx, cy)
    if ppx then sel.x2 = ppx; sel.y2 = ppy end
  end

  -- drag select move
  if btn0 and sel.moving then
    local dx = math.floor((mx - sel.move_sx) / zoom)
    local dy = math.floor((my - sel.move_sy) / zoom)
    sel.buf_ox = sel.move_ox + dx
    sel.buf_oy = sel.move_oy + dy
  end

  -- commit line/rect/circle on release
  if not btn0 and prev_btn0 then
    if drag_start_px and cur_tool == "line" then
      local ppx, ppy = canvas_to_pixel(cx, cy)
      if ppx then
        draw_line_px(drag_start_px, drag_start_py, ppx, ppy,
                     cur_color, cur_frame, cur_layer)
      end
      drag_start_px = nil; drag_start_py = nil
    elseif drag_start_px and cur_tool == "rect" then
      local ppx, ppy = canvas_to_pixel(cx, cy)
      if ppx then
        draw_rect_px(drag_start_px, drag_start_py, ppx, ppy,
                     cur_color, cur_frame, cur_layer)
      end
      drag_start_px = nil; drag_start_py = nil
    elseif drag_start_px and cur_tool == "circle" then
      local ppx, ppy = canvas_to_pixel(cx, cy)
      if ppx then
        local r = math.floor(math.sqrt((ppx-drag_start_px)^2 + (ppy-drag_start_py)^2) + 0.5)
        draw_circle_px(drag_start_px, drag_start_py, r, cur_color, cur_frame, cur_layer)
      end
      drag_start_px = nil; drag_start_py = nil
    end
    -- finalize selection drag
    if sel.dragging then
      sel.dragging = false
      -- lift pixels into buffer
      sel_copy(); sel_lift()
    end
    if sel.moving then
      sel.moving = false
      -- update selection bounds to match moved buffer
      sel.x1 = sel.buf_ox; sel.y1 = sel.buf_oy
      sel.x2 = sel.buf_ox + sel.buf.w - 1; sel.y2 = sel.buf_oy + sel.buf.h - 1
    end
    drawing = false
  end

  prev_btn0 = btn0
end

return { draw=draw, update=update, input=on_input, win=win, name="pixel" }
