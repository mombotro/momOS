-- maze3d.lua — 3D first-person raycasting maze
-- Controls: Arrow keys or WASD to move/turn, R to regenerate

local WIN_W, WIN_H = 480, 300
local win = wm.open("maze3d", 50, 30, WIN_W, WIN_H)
if not win then return nil end

local sin, cos, pi, floor, abs, max, min = math.sin, math.cos, math.pi,
  math.floor, math.abs, math.max, math.min

-- ── View config ───────────────────────────────────────────────────────────────
local HUD_H    = 20             -- top bar
local VIEW_H   = WIN_H - HUD_H -- usable 3D viewport height
local HALF_H   = VIEW_H / 2
local STRIPE_W = 2              -- pixel columns per ray
local RAYS     = WIN_W // STRIPE_W  -- 240 rays
local FOV      = pi / 3         -- 60° horizontal fov

-- ── Map config ────────────────────────────────────────────────────────────────
local MAP_W, MAP_H = 19, 19     -- odd dimensions for DFS maze

-- minimap placement (bottom-right)
local MM_S  = 3                 -- scale: pixels per cell
local MM_X  = WIN_W - MAP_W * MM_S - 2
local MM_Y  = HUD_H + 2

-- ── Wall colour — tuned for 1-unit-cell maze ──────────────────────────────────
-- Palette reference: 0=dark navy, 7=white, 8=lt gray, 9=mid gray, 10=dk gray
-- EW walls (side=0, vertical face) slightly brighter than NS walls
local function wall_col(perp, side)
  local c
  if   perp < 0.6  then c = side == 0 and 7  or 8
  elseif perp < 1.2 then c = side == 0 and 8  or 9
  elseif perp < 2.0 then c = side == 0 and 9  or 10
  elseif perp < 3.5 then c = side == 0 and 10 or 0
  else                   c = 0
  end
  return c
end

local CEIL_COL  = 2    -- dark blue ceiling
local FLOOR_COL = 10   -- dark gray floor
local EXIT_NEAR = 16   -- bright green exit portal
local EXIT_FAR  = 15   -- lime at distance

-- ── Map ───────────────────────────────────────────────────────────────────────
local map = {}   -- map[y][x]: 0=open, 1=wall, 2=exit

local function map_get(x, y)
  if y < 0 or y >= MAP_H or x < 0 or x >= MAP_W then return 1 end
  return map[y][x] or 1
end

local function is_solid(x, y)
  return map_get(x, y) == 1
end

local function generate()
  for y = 0, MAP_H-1 do
    map[y] = {}
    for x = 0, MAP_W-1 do map[y][x] = 1 end
  end

  local visited = {}
  for y = 0, MAP_H-1 do visited[y] = {} end

  local function shuffle(t)
    for i = #t, 2, -1 do
      local j = math.random(i)
      t[i], t[j] = t[j], t[i]
    end
  end

  local function carve(x, y)
    visited[y][x] = true
    map[y][x] = 0
    local dirs = { {0,-2}, {2,0}, {0,2}, {-2,0} }
    shuffle(dirs)
    for _, d in ipairs(dirs) do
      local nx, ny = x + d[1], y + d[2]
      if nx >= 1 and nx < MAP_W-1 and ny >= 1 and ny < MAP_H-1
         and not visited[ny][nx] then
        map[y + d[2]//2][x + d[1]//2] = 0   -- knock down wall between
        carve(nx, ny)
      end
    end
  end

  carve(1, 1)

  -- guarantee a path to exit corner
  map[MAP_H-2][MAP_W-2] = 2   -- exit cell
  map[MAP_H-2][MAP_W-3] = 0   -- ensure adjacent cells open
  map[MAP_H-3][MAP_W-2] = 0
end

-- ── Player ────────────────────────────────────────────────────────────────────
local px, py  = 1.5, 1.5
local pangle  = 0.0
local SPEED   = 3.2
local ROTSPD  = 2.4
local DT      = 1/60
local MARGIN  = 0.28

-- ── Game state ────────────────────────────────────────────────────────────────
local won      = false
local win_t    = 0
local level    = 1

-- ── Input flags ───────────────────────────────────────────────────────────────
local K = { fwd=false, back=false, left=false, right=false }

local function poll_keys()
  K.fwd   = input.key_down("up")    or input.key_down("w")
  K.back  = input.key_down("down")  or input.key_down("s")
  K.left  = input.key_down("left")  or input.key_down("a")
  K.right = input.key_down("right") or input.key_down("d")
end

-- ── DDA raycast ───────────────────────────────────────────────────────────────
local function cast(angle)
  local rdx = cos(angle)
  local rdy = sin(angle)

  local mx, my = floor(px), floor(py)

  local ddx = rdx == 0 and 1e30 or abs(1 / rdx)
  local ddy = rdy == 0 and 1e30 or abs(1 / rdy)

  local sx, sy
  local side_x, side_y

  if rdx < 0 then sx = -1; side_x = (px - mx) * ddx
  else            sx =  1; side_x = (mx + 1 - px) * ddx end
  if rdy < 0 then sy = -1; side_y = (py - my) * ddy
  else            sy =  1; side_y = (my + 1 - py) * ddy end

  local side = 0
  local cell = 0

  for _ = 1, 40 do
    if side_x < side_y then
      side_x = side_x + ddx; mx = mx + sx; side = 0
    else
      side_y = side_y + ddy; my = my + sy; side = 1
    end
    cell = map_get(mx, my)
    if cell ~= 0 then break end
  end

  -- perpendicular (fisheye-corrected) distance
  local dist
  if side == 0 then
    dist = (mx - px + (1 - sx) * 0.5) / rdx
  else
    dist = (my - py + (1 - sy) * 0.5) / rdy
  end

  return max(0.02, dist), side, cell
end

-- ── Update ────────────────────────────────────────────────────────────────────
local function update()
  poll_keys()

  if won then
    win_t = win_t + 1
    return
  end

  -- rotate
  if K.left  then pangle = pangle - ROTSPD * DT end
  if K.right then pangle = pangle + ROTSPD * DT end

  -- move with per-axis collision
  local function try_move(dx, dy)
    local nx, ny = px + dx, py + dy
    if not is_solid(floor(nx + (dx >= 0 and MARGIN or -MARGIN)), floor(py)) then
      px = nx
    end
    if not is_solid(floor(px), floor(ny + (dy >= 0 and MARGIN or -MARGIN))) then
      py = ny
    end
  end

  if K.fwd  then try_move( cos(pangle)*SPEED*DT,  sin(pangle)*SPEED*DT) end
  if K.back then try_move(-cos(pangle)*SPEED*DT, -sin(pangle)*SPEED*DT) end

  -- win trigger
  local ex, ey = MAP_W - 1.5, MAP_H - 1.5
  local ddx, ddy = px - ex, py - ey
  if ddx*ddx + ddy*ddy < 0.6*0.6 then
    won = true
  end
end

-- ── Draw ──────────────────────────────────────────────────────────────────────
local function draw()
  wm.focus(win)
  gfx.cls(0)

  -- Ceiling + floor solid fills
  gfx.rect(0, HUD_H,          WIN_W, HALF_H, CEIL_COL)
  gfx.rect(0, HUD_H + HALF_H, WIN_W, HALF_H, FLOOR_COL)

  -- Raycasted walls
  for i = 0, RAYS - 1 do
    local a     = pangle - FOV * 0.5 + (i / (RAYS - 1)) * FOV
    local dist, side, cell = cast(a)
    -- perp dist = dist corrected for fisheye
    local perp  = dist * cos(a - pangle)

    local h    = floor(VIEW_H / max(0.01, perp))
    local top  = max(HUD_H, HUD_H + floor(HALF_H - h * 0.5))
    local bot  = min(WIN_H, HUD_H + floor(HALF_H + h * 0.5))

    local c
    if cell == 2 then
      -- exit portal: bright pulse
      c = perp < 1.5 and EXIT_NEAR or EXIT_FAR
    else
      c = wall_col(perp, side)
    end
    gfx.rect(i * STRIPE_W, top, STRIPE_W, bot - top, c)
  end

  -- ── Minimap ───────────────────────────────────────────────────────────────
  -- background
  gfx.rect(MM_X - 1, MM_Y - 1, MAP_W * MM_S + 2, MAP_H * MM_S + 2, 11)
  for y = 0, MAP_H-1 do
    for x = 0, MAP_W-1 do
      local v = map[y][x]
      local c = v == 1 and 9 or (v == 2 and EXIT_NEAR or 0)
      if v ~= 1 then
        gfx.rect(MM_X + x*MM_S, MM_Y + y*MM_S, MM_S, MM_S, c)
      end
    end
  end
  -- player dot + direction arrow
  local mpx = MM_X + floor(px * MM_S)
  local mpy = MM_Y + floor(py * MM_S)
  gfx.rect(mpx - 1, mpy - 1, 3, 3, 15)
  gfx.line(mpx, mpy,
    mpx + floor(cos(pangle) * 5),
    mpy + floor(sin(pangle) * 5), 4)

  -- ── Crosshair ─────────────────────────────────────────────────────────────
  local cx = WIN_W // 2
  local cy = HUD_H + VIEW_H // 2
  gfx.pset(cx,   cy,   7)
  gfx.pset(cx+2, cy,   7)
  gfx.pset(cx-2, cy,   7)
  gfx.pset(cx,   cy+2, 7)
  gfx.pset(cx,   cy-2, 7)

  -- ── HUD bar ───────────────────────────────────────────────────────────────
  gfx.rect(0, 0, WIN_W, HUD_H, 2)
  gfx.print("MAZE 3D", 2, 6, 7)

  -- compass
  local compass_labels = { "E", "SE", "S", "SW", "W", "NW", "N", "NE" }
  local ci = floor(((pangle % (2*pi)) / (2*pi)) * 8 + 0.5) % 8 + 1
  gfx.print(compass_labels[ci], WIN_W - 24, 6, 9)

  -- level indicator
  gfx.print("LV "..level, WIN_W//2 - 16, 6, 9)

  -- ── Win screen ────────────────────────────────────────────────────────────
  if won then
    local flash = (win_t // 6) % 2 == 0
    gfx.rect(WIN_W//2 - 90, WIN_H//2 - 24, 180, 48, 0)
    gfx.rect(WIN_W//2 - 91, WIN_H//2 - 25, 182, 50, flash and 10 or 9)
    if flash then
      gfx.print("ESCAPED!", WIN_W//2 - 32, WIN_H//2 - 12, 15)
    end
    gfx.print("WASD/arrows = move  R = next maze", WIN_W//2 - 128, WIN_H//2 + 6, 8)
  end

  wm.unfocus()
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local function on_input(c)
  if won and (c == "r" or c == "R") then
    level = level + 1
    math.randomseed(sys.ticks())
    generate()
    px, py = 1.5, 1.5; pangle = 0; won = false; win_t = 0
  end
end

-- ── Init ──────────────────────────────────────────────────────────────────────
math.randomseed(sys.ticks())
generate()

return { draw=draw, update=update, input=on_input, win=win, name="maze3d" }
