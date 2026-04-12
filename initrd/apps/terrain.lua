-- terrain.lua — tile map editor
local WIN_W, WIN_H = 480, 360
local win = wm.open("terrain", 60, 30, WIN_W, WIN_H)
if not win then return nil end

local CW, CH = 8, 8

-- ── Layout ────────────────────────────────────────────────────────────────────
local TB_H   = CH + 4    -- top toolbar
local SB_H   = CH + 4    -- status bar
local PANEL_W = 80       -- right tile picker panel
local VIEW_W  = WIN_W - PANEL_W
local VIEW_H  = WIN_H - TB_H - SB_H

-- ── Map state ─────────────────────────────────────────────────────────────────
local map = {
  w = 20, h = 15,
  tile_w = 16, tile_h = 16,
  layers = 2,
  tileset_path = nil,
  tiles = {},    -- [layer][y*w+x+1] = tile_index (0=empty)
  objects = {},  -- { x, y, type, props={} }
}

local function map_init(w, h, tw, th, nl)
  map.w = w; map.h = h
  map.tile_w = tw; map.tile_h = th
  map.layers = nl
  map.tiles = {}
  for l = 1, nl do
    map.tiles[l] = {}
    for i = 1, w * h do map.tiles[l][i] = 0 end
  end
  map.objects = {}
end
map_init(20, 15, 16, 16, 2)

local function get_tile(l, x, y)
  if x < 0 or y < 0 or x >= map.w or y >= map.h then return 0 end
  return map.tiles[l][y * map.w + x + 1] or 0
end

local function set_tile(l, x, y, t)
  if x < 0 or y < 0 or x >= map.w or y >= map.h then return end
  map.tiles[l][y * map.w + x + 1] = t
end

-- ── Tileset ───────────────────────────────────────────────────────────────────
local tileset = nil   -- { w, h, nl, nf, pixels } from MPI
local tiles_per_row = 0

local function load_tileset(path)
  local data = fs.read(path)
  if not data or #data < 16 then return false end
  if data:sub(1,4) ~= "MPI1" then return false end
  local w  = data:byte(5); local h = data:byte(6)
  local nl = data:byte(7); local nf = data:byte(8)
  tileset = { w=w, h=h, nl=nl, nf=nf, data=data, path=path }
  tiles_per_row = math.max(1, w // map.tile_w)
  map.tileset_path = path
  return true
end

local function draw_tile_at(tile_idx, sx, sy, scale)
  if not tileset then return end
  scale = scale or 1
  local tw, th = map.tile_w, map.tile_h
  local tr = tiles_per_row
  local tx = (tile_idx % tr) * tw
  local ty = (tile_idx // tr) * th
  local dw, dh = tileset.w, tileset.h
  -- pixel data starts at byte 17 (first frame, first layer)
  local base = 17
  for py = 0, th-1 do
    for px = 0, tw-1 do
      local src_x = tx + px; local src_y = ty + py
      if src_x < dw and src_y < dh then
        local idx = src_y * dw + src_x + base
        if idx <= #tileset.data then
          local c = tileset.data:byte(idx)
          if c ~= 0 then
            gfx.rect(sx + px*scale, sy + py*scale, scale, scale, c)
          end
        end
      end
    end
  end
end

-- ── Viewport ──────────────────────────────────────────────────────────────────
local cam_x = 0; local cam_y = 0   -- scroll in tiles
local zoom   = 1

local function screen_to_tile(sx, sy)
  local tx = math.floor(sx / (map.tile_w * zoom) + cam_x)
  local ty = math.floor(sy / (map.tile_h * zoom) + cam_y)
  return tx, ty
end

-- ── State ─────────────────────────────────────────────────────────────────────
local cur_layer  = 1
local cur_tile   = 1    -- 0=eraser
local cur_tool   = "draw"   -- draw erase fill obj

local filepath = nil
local modified = false
local status   = ""
local status_t = 0
local function set_status(s) status = s; status_t = 60 end

-- ── Serialize / Deserialize ───────────────────────────────────────────────────
local function serialize()
  local parts = {}
  -- Header: MTM1 + w(2) + h(2) + tw(1) + th(1) + layers(1) + obj_count(2) + reserved(19)
  parts[#parts+1] = "MTM1"
  parts[#parts+1] = string.char(map.w % 256, map.w // 256)
  parts[#parts+1] = string.char(map.h % 256, map.h // 256)
  parts[#parts+1] = string.char(map.tile_w, map.tile_h, map.layers)
  local nc = #map.objects
  parts[#parts+1] = string.char(nc % 256, nc // 256)
  parts[#parts+1] = string.rep("\0", 19)  -- reserved
  -- Tileset reference (64 bytes, null-padded)
  local tpath = map.tileset_path or ""
  parts[#parts+1] = tpath:sub(1,63)..string.rep("\0", 64 - math.min(63, #tpath))
  -- Tile layers
  for l = 1, map.layers do
    local row = {}
    for i = 1, map.w * map.h do row[i] = string.char(map.tiles[l][i] or 0) end
    parts[#parts+1] = table.concat(row)
  end
  -- Objects
  for _, obj in ipairs(map.objects) do
    parts[#parts+1] = string.char(obj.x % 256, obj.x // 256,
                                   obj.y % 256, obj.y // 256,
                                   obj.type or 0, 0)  -- type + prop_count=0
  end
  return table.concat(parts)
end

local function deserialize(data)
  if #data < 32 then return false, "too short" end
  if data:sub(1,4) ~= "MTM1" then return false, "bad magic" end
  local w  = data:byte(5)  + data:byte(6)  * 256
  local h  = data:byte(7)  + data:byte(8)  * 256
  local tw = data:byte(9);  local th = data:byte(10)
  local nl = data:byte(11)
  local nc = data:byte(12) + data:byte(13) * 256
  -- tileset path at offset 32, 64 bytes
  local tpath = data:sub(33, 96):match("^([^\0]*)")
  map_init(w, h, tw, th, nl)
  if tpath ~= "" then load_tileset(tpath) end
  local pos = 97
  for l = 1, nl do
    for i = 1, w * h do
      map.tiles[l][i] = data:byte(pos); pos = pos + 1
    end
  end
  map.objects = {}
  for _ = 1, nc do
    if pos + 5 <= #data then
      local ox = data:byte(pos)   + data:byte(pos+1)*256
      local oy = data:byte(pos+2) + data:byte(pos+3)*256
      local ot = data:byte(pos+4)
      local pc = data:byte(pos+5)
      pos = pos + 6 + pc  -- skip properties for now
      map.objects[#map.objects+1] = { x=ox, y=oy, type=ot, props={} }
    end
  end
  return true
end

-- ── File ops ──────────────────────────────────────────────────────────────────
local function cmd_save(path2)
  path2 = path2 or filepath
  if not path2 then set_status("no filename — use :w <name>"); return end
  if not path2:match("%.%w+$") then path2 = path2..".mtm" end
  if fs.write(path2, serialize()) then
    filepath = path2; modified = false
    set_status("saved "..path2)
  else
    set_status("write failed")
  end
end

local function cmd_open(path2)
  if not path2 then set_status("usage: :o <file>"); return end
  if not path2:match("%.%w+$") then path2 = path2..".mtm" end
  local data = fs.read(path2)
  if not data then set_status("not found: "..path2); return end
  local ok, err = deserialize(data)
  if not ok then set_status("error: "..tostring(err)); return end
  filepath = path2; modified = false
  cam_x = 0; cam_y = 0
  set_status("opened "..path2)
end

-- consume global handoff
if _G.terrain_open_file then
  local p = _G.terrain_open_file; _G.terrain_open_file = nil
  cmd_open(p)
end

-- ── Command mode ──────────────────────────────────────────────────────────────
local cmd_mode = false; local cmd_buf = ""

-- ── Flood fill ────────────────────────────────────────────────────────────────
local function tile_fill(x, y, target, replacement, l)
  if target == replacement then return end
  if get_tile(l, x, y) ~= target then return end
  local stack = {{x, y}}
  while #stack > 0 do
    local p = table.remove(stack)
    local px, py = p[1], p[2]
    if get_tile(l, px, py) == target then
      set_tile(l, px, py, replacement)
      stack[#stack+1] = {px-1, py}; stack[#stack+1] = {px+1, py}
      stack[#stack+1] = {px, py-1}; stack[#stack+1] = {px, py+1}
    end
  end
end

-- ── Draw ──────────────────────────────────────────────────────────────────────
local function draw_map()
  local tw = map.tile_w * zoom
  local th = map.tile_h * zoom
  -- visible tile range
  local tx0 = math.floor(cam_x)
  local ty0 = math.floor(cam_y)
  local tx1 = math.min(tx0 + math.ceil(VIEW_W / tw), map.w - 1)
  local ty1 = math.min(ty0 + math.ceil(VIEW_H / th), map.h - 1)

  for l = 1, map.layers do
    for ty = ty0, ty1 do
      for tx = tx0, tx1 do
        local t = get_tile(l, tx, ty)
        local sx = math.floor((tx - cam_x) * tw)
        local sy = math.floor((ty - cam_y) * th) + TB_H
        if t ~= 0 then
          if tileset then
            draw_tile_at(t - 1, sx, sy, zoom)
          else
            gfx.rect(sx, sy, tw, th, t % 31 + 1)
          end
        elseif l == 1 then
          -- empty ground: checkerboard
          local c = ((tx + ty) % 2 == 0) and 2 or 1
          gfx.rect(sx, sy, tw, th, c)
        end
      end
    end
  end

  -- object markers
  for _, obj in ipairs(map.objects) do
    local sx = math.floor((obj.x - cam_x) * tw)
    local sy = math.floor((obj.y - cam_y) * th) + TB_H
    gfx.rect(sx, sy, tw, th, 4)
    gfx.print("O", sx + 4, sy + 4, 7)
  end

  -- grid lines
  if zoom >= 2 then
    for tx = tx0, tx1 + 1 do
      local sx = math.floor((tx - cam_x) * tw)
      gfx.rect(sx, TB_H, 1, VIEW_H, 0)
    end
    for ty = ty0, ty1 + 1 do
      local sy = math.floor((ty - cam_y) * th) + TB_H
      gfx.rect(0, sy, VIEW_W, 1, 0)
    end
  end

  -- layer fade: dim layers below current
  -- (omitted for performance — just draw all)
end

local function draw_tile_panel()
  gfx.rect(VIEW_W, TB_H, PANEL_W, VIEW_H + SB_H, 2)
  gfx.rect(VIEW_W, TB_H, 1, VIEW_H, 9)
  gfx.print("TILES", VIEW_W + 2, TB_H + 2, 8)

  local px0 = VIEW_W + 4
  local py0 = TB_H + CH + 4
  local cell = 14

  if tileset then
    local cols = math.max(1, (PANEL_W - 8) // cell)
    local num_tiles = (tileset.w // map.tile_w) * (tileset.h // map.tile_h)
    for i = 0, math.min(num_tiles - 1, 24) do
      local col = i % cols
      local row = i // cols
      local tx = px0 + col * cell
      local ty = py0 + row * cell
      gfx.rect(tx, ty, cell - 1, cell - 1, 1)
      draw_tile_at(i, tx, ty, 1)
      if i + 1 == cur_tile then
        gfx.rect(tx - 1, ty - 1, cell + 1, cell + 1, 15)
        gfx.rect(tx, ty, cell - 1, cell - 1, 1)
        draw_tile_at(i, tx, ty, 1)
      end
    end
  else
    -- color swatches as tile placeholders
    for i = 1, 20 do
      local col = (i-1) % 4
      local row = (i-1) // 4
      local tx = px0 + col * cell
      local ty = py0 + row * cell
      gfx.rect(tx, ty, cell - 1, cell - 1, i % 31 + 1)
      if i == cur_tile then
        gfx.rect(tx - 1, ty - 1, cell + 1, cell + 1, 15)
        gfx.rect(tx, ty, cell - 1, cell - 1, i % 31 + 1)
      end
    end
  end

  -- layer selector
  local ly2 = py0 + 6 * cell + 4
  gfx.print("LAYER", VIEW_W + 2, ly2, 8)
  for l = 1, map.layers do
    local bg = l == cur_layer and 3 or 1
    gfx.rect(VIEW_W + 4, ly2 + CH + (l-1)*(CH+2), PANEL_W - 8, CH, bg)
    gfx.print("L"..l, VIEW_W + 6, ly2 + CH + (l-1)*(CH+2), l==cur_layer and 15 or 7)
  end
end

local function draw_toolbar()
  gfx.rect(0, 0, WIN_W, TB_H, 2)
  local title = filepath and filepath:match("[^/]+$") or "untitled.mtm"
  if modified then title = "*"..title end
  gfx.print(title, 2, 2, 7)
  local tools_str = " D=draw E=erase F=fill O=obj"
  gfx.print(tools_str, WIN_W // 2 - #tools_str*CW//2, 2, 8)
end

local function draw_status_bar()
  local sy = WIN_H - SB_H
  gfx.rect(0, sy, WIN_W, SB_H, 2)
  gfx.rect(0, sy, WIN_W, 1, 9)
  if cmd_mode then
    gfx.print(":"..cmd_buf.."_", 2, sy + 2, 15)
  elseif status_t > 0 then
    gfx.print(status, 2, sy + 2, 8)
  else
    local mx, my = mouse.x(), mouse.y()
    local wx, wy = wm.rect(win)
    local lx, ly = mx - wx, my - wy - TB_H
    local tx, ty = screen_to_tile(lx, ly)
    if tx >= 0 and tx < map.w and ty >= 0 and ty < map.h then
      gfx.print(string.format("%d,%d  t%d  L%d  %dx%d",
        tx, ty, get_tile(cur_layer, tx, ty), cur_layer, map.w, map.h),
        2, sy + 2, 8)
    else
      gfx.print(string.format("%dx%d  L%d/%d  z%dx",
        map.w, map.h, cur_layer, map.layers, zoom), 2, sy + 2, 8)
    end
  end
end

local function draw()
  wm.focus(win)
  gfx.cls(1)
  gfx.rect(0, TB_H, VIEW_W, VIEW_H, 0)
  draw_map()
  draw_tile_panel()
  draw_toolbar()
  draw_status_bar()
  wm.unfocus()
end

-- ── Update ────────────────────────────────────────────────────────────────────
local prev_btn0 = false; local prev_btn1 = false
local panning = false
local pan_sx = 0; local pan_sy = 0
local pan_cx = 0; local pan_cy = 0

local function update()
  if status_t > 0 then status_t = status_t - 1 end

  local mx, my = mouse.x(), mouse.y()
  local wx, wy = wm.rect(win)
  local lx, ly = mx - wx, my - wy
  local btn0 = mouse.btn(0)
  local btn1 = mouse.btn(1)

  local view_lx = lx
  local view_ly = ly - TB_H
  local in_view = lx >= 0 and lx < VIEW_W and view_ly >= 0 and view_ly < VIEW_H

  -- right-drag pan
  if btn1 and not prev_btn1 and in_view then
    panning = true; pan_sx = mx; pan_sy = my; pan_cx = cam_x; pan_cy = cam_y
  end
  if panning then
    if btn1 then
      cam_x = pan_cx - (mx - pan_sx) / (map.tile_w * zoom)
      cam_y = pan_cy - (my - pan_sy) / (map.tile_h * zoom)
      cam_x = math.max(0, math.min(map.w - 1, cam_x))
      cam_y = math.max(0, math.min(map.h - 1, cam_y))
    else panning = false end
  end

  -- tile panel clicks (left side = tile picker, layer selector)
  if btn0 and not prev_btn0 and lx >= VIEW_W then
    local px0 = VIEW_W + 4; local py0 = TB_H + CH + 4; local cell = 14
    -- tile pick
    if ly >= py0 and ly < py0 + 6*cell then
      local col = (lx - px0) // cell
      local row = (ly - py0) // cell
      local cols = math.max(1, (PANEL_W - 8) // cell)
      local idx = row * cols + col + 1
      if idx >= 1 then cur_tile = idx end
    end
    -- layer pick
    local ly2 = py0 + 6*cell + 4
    if ly >= ly2 + CH and ly < ly2 + CH + map.layers*(CH+2) then
      cur_layer = math.floor((ly - ly2 - CH) / (CH+2)) + 1
      cur_layer = math.max(1, math.min(map.layers, cur_layer))
    end
  end

  -- draw / erase on map
  if btn0 and in_view and not cmd_mode then
    local tx, ty2 = screen_to_tile(view_lx, view_ly)
    if tx >= 0 and tx < map.w and ty2 >= 0 and ty2 < map.h then
      if cur_tool == "draw" then
        set_tile(cur_layer, tx, ty2, cur_tile); modified = true
      elseif cur_tool == "erase" then
        set_tile(cur_layer, tx, ty2, 0); modified = true
      elseif cur_tool == "fill" and not prev_btn0 then
        local target = get_tile(cur_layer, tx, ty2)
        tile_fill(tx, ty2, target, cur_tile, cur_layer); modified = true
      elseif cur_tool == "obj" and not prev_btn0 then
        map.objects[#map.objects+1] = { x=tx, y=ty2, type=0, props={} }
        modified = true
      end
    end
  end

  prev_btn0 = btn0; prev_btn1 = btn1
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local function exec_cmd(line)
  line = line:match("^%s*(.-)%s*$")
  if line == "w" then cmd_save()
  elseif line:sub(1,2) == "w " then cmd_save(line:sub(3))
  elseif line:sub(1,2) == "o " then cmd_open(line:sub(3))
  elseif line == "q" then
    if modified then set_status("unsaved — :w first") else return "quit" end
  elseif line == "wq" then cmd_save(); return "quit"
  elseif line:sub(1,2) == "ts" then
    local p = line:sub(4); if p ~= "" then load_tileset(p); set_status("tileset: "..p) end
  elseif line:sub(1,2) == "nw" then
    local args = {}; for v in line:sub(4):gmatch("%S+") do args[#args+1]=tonumber(v) end
    local nw = args[1] or 20; local nh = args[2] or 15
    local ntw = args[3] or 16; local nth = args[4] or 16
    map_init(nw, nh, ntw, nth, 2); modified=false; set_status("new "..nw.."x"..nh)
  else set_status("?: w  o <f>  q  wq  ts <tileset>  nw W H [TW TH]")
  end
end

local function on_input(c)
  if cmd_mode then
    if c == "\n" then
      local r = exec_cmd(cmd_buf); cmd_mode=false; cmd_buf=""
      if r == "quit" then wm.close(win); return "quit" end
    elseif c == "\x1b" then cmd_mode=false; cmd_buf=""
    elseif c == "\b" then if #cmd_buf>0 then cmd_buf=cmd_buf:sub(1,-2) end
    elseif c >= " " then cmd_buf=cmd_buf..c end
    return
  end
  if c == "\x1b" then cmd_mode=true; return end
  if c == "d" then cur_tool = "draw"
  elseif c == "e" then cur_tool = "erase"
  elseif c == "f" then cur_tool = "fill"
  elseif c == "o" then cur_tool = "obj"
  elseif c == "=" or c == "+" then zoom = math.min(4, zoom * 2)
  elseif c == "-" then zoom = math.max(1, zoom // 2)
  -- layer switch
  elseif c == "\x01" then cur_layer = math.max(1, cur_layer-1)
  elseif c == "\x02" then cur_layer = math.min(map.layers, cur_layer+1)
  -- camera pan with arrow keys
  elseif c == "\x03" then cam_x = math.max(0, cam_x-1)
  elseif c == "\x04" then cam_x = math.min(map.w-1, cam_x+1)
  elseif c == "s" then cmd_save()
  end
end

return { draw=draw, update=update, input=on_input, win=win, name="terrain" }
