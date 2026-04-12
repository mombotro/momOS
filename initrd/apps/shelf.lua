-- shelf.lua — asset browser
local WIN_W, WIN_H = 400, 300
local win = wm.open("shelf", 80, 40, WIN_W, WIN_H)
if not win then return nil end

local CW, CH = 8, 8
local GRID_W  = 64   -- cell width
local GRID_H  = 72   -- cell height (64 thumb + 8 label)
local COLS    = math.floor(WIN_W / GRID_W)
local TB_H    = 12
local SB_H    = CH + 2

local path    = "/"
local entries = {}
local sel_idx = nil
local scroll  = 0

local ROWS_VIS = math.floor((WIN_H - TB_H - SB_H) / GRID_H)
local PAGE     = ROWS_VIS * COLS

-- ── File type helpers ─────────────────────────────────────────────────────────
local function ext(name)
  return name:match("%.([^%.]+)$") or ""
end

local function type_col(e)
  if e.is_dir     then return 3  end
  local x = ext(e.name)
  if x == "mpi"   then return 14 end
  if x == "msm"   then return 12 end
  if x == "mtm"   then return 11 end
  if x == "lua"   then return 5  end
  if x == "txt"   then return 6  end
  return 8
end

local function type_icon(e)
  if e.is_dir     then return "DIR" end
  local x = ext(e.name)
  if x == "mpi"   then return "SPR" end
  if x == "msm"   then return "MUS" end
  if x == "mtm"   then return "MAP" end
  if x == "lua"   then return "LUA" end
  if x == "txt"   then return "TXT" end
  return "???"
end

-- ── MPI thumbnail renderer ───────────────────────────────────────────────────
-- Parse minimal MPI header for preview (first frame, first layer)
local function draw_mpi_thumb(data, dx, dy, tw, th)
  if not data or #data < 16 then return false end
  if data:sub(1,4) ~= "MPI1" then return false end
  local w  = data:byte(5)
  local h  = data:byte(6)
  if w < 1 or h < 1 then return false end
  -- first frame, first layer starts at byte 17
  local px_off = 17
  -- scale to tw×th
  local sx = w / tw
  local sy = h / th
  for py = 0, th-1 do
    for px = 0, tw-1 do
      local spx = math.floor(px * sx)
      local spy = math.floor(py * sy)
      local idx = spy * w + spx + px_off
      if idx <= #data then
        local c = data:byte(idx)
        if c ~= 0 then
          gfx.rect(dx + px, dy + py, 1, 1, c)
        end
      end
    end
  end
  return true
end

local function refresh()
  entries = {}
  if path ~= "/" then
    entries[1] = { name="..", is_dir=true }
  end
  local list = fs.list(path)
  if list then
    table.sort(list, function(a,b)
      if a.is_dir ~= b.is_dir then return a.is_dir end
      return a.name < b.name
    end)
    for _, e in ipairs(list) do entries[#entries+1] = e end
  end
  sel_idx = nil; scroll = 0
end
refresh()

-- ── Mouse ─────────────────────────────────────────────────────────────────────
local prev_btn0   = false
local dbl_timer   = 0
local dbl_idx     = nil

local function cell_at(lx, ly)
  local gy = ly - TB_H
  if gy < 0 then return nil end
  local col = math.floor(lx / GRID_W)
  local row = math.floor(gy / GRID_H) + scroll // COLS
  -- convert flat index
  local row2 = math.floor(gy / GRID_H)
  local flat = (math.floor(scroll) + row2) * COLS + col + 1
  if col < 0 or col >= COLS then return nil end
  if flat < 1 or flat > #entries then return nil end
  return flat
end

local function open_entry(e)
  local full = path == "/" and "/"..e.name or path.."/"..e.name
  if e.is_dir then
    path = full; refresh(); return
  end
  local x = ext(e.name)
  if x == "mpi" then
    pixel_open_file = full
    if app_launch then app_launch("/apps/pixel.lua") end
  elseif x == "msm" then
    if app_launch then
      -- pass via global
      _G.chirp_open_file = full
      app_launch("/apps/chirp.lua")
    end
  elseif x == "mtm" then
    _G.terrain_open_file = full
    if app_launch then app_launch("/apps/terrain.lua") end
  else
    quill_open_file = full
    if app_launch then app_launch("/apps/quill.lua") end
  end
end

-- ── Draw ──────────────────────────────────────────────────────────────────────
local function draw()
  wm.focus(win)
  gfx.cls(1)

  -- toolbar
  gfx.rect(0, 0, WIN_W, TB_H, 2)
  local disp_path = #path > 46 and "..."..path:sub(-43) or path
  gfx.print(disp_path, 2, 2, 7)

  -- grid
  local start = scroll * COLS
  for idx = start + 1, math.min(start + PAGE, #entries) do
    local e   = entries[idx]
    local pos = idx - 1 - start
    local col = pos % COLS
    local row = pos // COLS
    local gx  = col * GRID_W
    local gy  = TB_H + row * GRID_H
    local col2 = type_col(e)

    -- background
    local is_sel = (idx == sel_idx)
    gfx.rect(gx + 2, gy + 2, GRID_W - 4, GRID_H - 4, is_sel and 3 or 1)

    -- thumbnail / icon area (48×48)
    local tx = gx + (GRID_W - 48) // 2
    local ty = gy + 2
    gfx.rect(tx, ty, 48, 48, is_sel and 3 or 2)

    if e.is_dir then
      -- folder icon
      gfx.rect(tx + 4,  ty + 8,  20, 3, col2)
      gfx.rect(tx + 4,  ty + 8,  40, 32, col2)
      gfx.rect(tx + 6,  ty + 12, 36, 26, 1)
      gfx.print("DIR", tx + 16, ty + 22, col2)
    else
      local x2 = ext(e.name)
      local full = path == "/" and "/"..e.name or path.."/"..e.name
      local drawn = false
      if x2 == "mpi" then
        local data = fs.read(full)
        drawn = draw_mpi_thumb(data, tx, ty, 48, 48)
      end
      if not drawn then
        gfx.rect(tx + 8, ty + 6,  32, 36, col2)
        gfx.print(type_icon(e), tx + 12, ty + 20, 7)
      end
      -- .msm play button badge (bottom-right of thumbnail)
      if x2 == "msm" then
        gfx.rect(tx + 30, ty + 33, 14, 10, col2)
        gfx.print(">", tx + 33, ty + 35, 7)
      end
    end

    -- label
    local label = e.name
    if #label > 7 then label = label:sub(1,6)..".." end
    gfx.print(label, gx + (GRID_W - #label*CW) // 2, gy + GRID_H - CH - 1, 7)
  end

  -- scrollbar
  if #entries > PAGE then
    local total_rows = math.ceil(#entries / COLS)
    local vis_rows   = ROWS_VIS
    local sb_h   = math.max(8, math.floor(vis_rows / total_rows * (WIN_H - TB_H - SB_H)))
    local sb_y   = TB_H + math.floor(scroll / (total_rows - vis_rows) * (WIN_H - TB_H - SB_H - sb_h))
    gfx.rect(WIN_W - 4, TB_H, 4, WIN_H - TB_H - SB_H, 2)
    gfx.rect(WIN_W - 4, sb_y, 4, sb_h, 9)
  end

  -- status bar
  local sb_y2 = WIN_H - SB_H
  gfx.rect(0, sb_y2, WIN_W, SB_H, 2)
  gfx.rect(0, sb_y2, WIN_W, 1, 9)
  if sel_idx and entries[sel_idx] then
    local e = entries[sel_idx]
    local s = e.name..(e.is_dir and "/" or (e.size and " "..e.size.."b" or ""))
    gfx.print(s, 2, sb_y2 + 2, 7)
  else
    gfx.print(#entries.." items", 2, sb_y2 + 2, 8)
  end

  wm.unfocus()
end

-- ── Update ────────────────────────────────────────────────────────────────────
local function update()
  local mx, my = mouse.x(), mouse.y()
  local wx, wy = wm.rect(win)
  local lx, ly = mx - wx, my - wy
  local btn0   = mouse.btn(0)

  if dbl_timer > 0 then dbl_timer = dbl_timer - 1 end

  -- compute play-badge rect for a visible entry index
  local function play_badge_hit(idx2, lx2, ly2)
    local e2 = entries[idx2]
    if e2.is_dir or ext(e2.name) ~= "msm" then return false end
    local pos2 = idx2 - 1 - scroll * COLS
    if pos2 < 0 or pos2 >= PAGE then return false end
    local c2 = pos2 % COLS
    local r2 = pos2 // COLS
    local gx2 = c2 * GRID_W
    local gy2 = TB_H + r2 * GRID_H
    local tx2 = gx2 + (GRID_W - 48) // 2
    local ty2 = gy2 + 2
    return lx2 >= tx2+30 and lx2 < tx2+44 and ly2 >= ty2+33 and ly2 < ty2+43
  end

  if btn0 and not prev_btn0 then
    local idx = cell_at(lx, ly)
    if idx then
      if play_badge_hit(idx, lx, ly) then
        -- single-click ▶ on .msm → open in chirp
        local e2 = entries[idx]
        _G.chirp_open_file = path == "/" and "/"..e2.name or path.."/"..e2.name
        if app_launch then app_launch("/apps/chirp.lua") end
      elseif idx == dbl_idx and dbl_timer > 0 then
        -- double click
        open_entry(entries[idx])
        dbl_idx = nil; dbl_timer = 0
      else
        sel_idx  = idx
        dbl_idx  = idx
        dbl_timer = 30
      end
    end
  end

  prev_btn0 = btn0
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local function on_input(c)
  if c == "\x1b" then wm.close(win); return "quit" end
  if c == "\n" then
    if sel_idx and entries[sel_idx] then open_entry(entries[sel_idx]) end
    return
  end
  -- scroll
  if c == "\x02" then -- down
    local max_scroll = math.max(0, math.ceil(#entries / COLS) - ROWS_VIS)
    scroll = math.min(scroll + 1, max_scroll)
  elseif c == "\x01" then -- up
    scroll = math.max(scroll - 1, 0)
  end
  -- navigate
  if sel_idx then
    if c == "\x04" then sel_idx = math.min(sel_idx + 1, #entries)
    elseif c == "\x03" then sel_idx = math.max(sel_idx - 1, 1) end
  end
end

return { draw=draw, update=update, input=on_input, win=win, name="shelf" }
