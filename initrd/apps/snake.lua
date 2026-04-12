-- snake.lua — classic snake game for momOS
-- Uses lib/game.lua for the window/loop framework.

local game = dofile("/lib/game.lua")

-- ── Layout ────────────────────────────────────────────────────────────────────
local CELL  = 16          -- pixel size of each grid cell
local COLS  = 16          -- cells wide
local ROWS  = 14          -- cells tall (playfield)
local HUD   = 20          -- pixels for score bar at top
local W     = COLS * CELL -- 256
local H     = HUD + ROWS * CELL  -- 20 + 224 = 244

-- momOS palette indices used
local COL_BG    = 0   -- dark navy
local COL_HUD   = 1   -- darker navy
local COL_HEAD  = 16  -- bright green
local COL_BODY  = 17  -- teal green
local COL_FOOD  = 4   -- red/pink
local COL_DEAD  = 12  -- red flash
local COL_TEXT  = 7   -- white
local COL_DIM   = 8   -- grey

-- ── Game state ────────────────────────────────────────────────────────────────
local snake, dir, queued_dir, food
local score, hi_score, alive, timer
local SPEED = 8   -- frames per step (60fps → ~7.5 steps/sec)

hi_score = 0

local function rand_food()
  local used = {}
  for _, s in ipairs(snake) do
    used[s.y * COLS + s.x] = true
  end
  local attempts = 0
  local fx, fy
  repeat
    fx = math.random(0, COLS - 1)
    fy = math.random(0, ROWS - 1)
    attempts = attempts + 1
  until not used[fy * COLS + fx] or attempts > 500
  food = {x=fx, y=fy}
end

function game._init()
  local mx = COLS // 2
  local my = ROWS // 2
  snake = { {x=mx, y=my}, {x=mx-1, y=my}, {x=mx-2, y=my} }
  dir        = {x=1, y=0}
  queued_dir = {x=1, y=0}
  score = 0
  alive = true
  timer = 0
  math.randomseed(sys.ticks())
  rand_food()
end

-- ── Update ────────────────────────────────────────────────────────────────────
function game._update()
  -- direction input — only allow 90-degree turns
  if game.keypressed(game.KEY_UP)    and dir.y == 0 then queued_dir = {x=0,  y=-1} end
  if game.keypressed(game.KEY_DOWN)  and dir.y == 0 then queued_dir = {x=0,  y=1}  end
  if game.keypressed(game.KEY_LEFT)  and dir.x == 0 then queued_dir = {x=-1, y=0}  end
  if game.keypressed(game.KEY_RIGHT) and dir.x == 0 then queued_dir = {x=1,  y=0}  end

  -- restart on enter when dead
  if not alive and game.keypressed(game.KEY_ENTER) then
    game._init()
    return
  end

  if not alive then return end

  timer = timer + 1
  if timer < SPEED then return end
  timer = 0

  dir = queued_dir

  local head = snake[1]
  local nx   = (head.x + dir.x) % COLS
  local ny   = (head.y + dir.y) % ROWS

  -- self-collision check
  for i = 1, #snake do
    if snake[i].x == nx and snake[i].y == ny then
      alive = false
      if score > hi_score then hi_score = score end
      return
    end
  end

  table.insert(snake, 1, {x=nx, y=ny})

  if nx == food.x and ny == food.y then
    score = score + 1
    rand_food()
  else
    table.remove(snake)
  end
end

-- ── Draw ──────────────────────────────────────────────────────────────────────
function game._draw()
  -- HUD bar
  gfx.rect(0, 0, W, HUD, COL_HUD)
  gfx.print("SNAKE", 4, 4, COL_HEAD)
  gfx.print(string.format("score %d", score), 60, 4, COL_TEXT)
  if hi_score > 0 then
    gfx.print(string.format("best %d", hi_score), W - 56, 4, COL_DIM)
  end

  -- Playfield background
  gfx.rect(0, HUD, W, ROWS * CELL, COL_BG)

  -- Food
  local fx = food.x * CELL + 2
  local fy = HUD + food.y * CELL + 2
  gfx.rect(fx, fy, CELL - 4, CELL - 4, COL_FOOD)
  -- food shine dot
  gfx.pset(fx + 1, fy + 1, 6)

  -- Snake body
  for i = #snake, 2, -1 do
    local s  = snake[i]
    local sx = s.x * CELL + 1
    local sy = HUD + s.y * CELL + 1
    local c  = COL_BODY
    gfx.rect(sx, sy, CELL - 2, CELL - 2, c)
  end

  -- Snake head
  local h  = snake[1]
  local hx = h.x * CELL + 1
  local hy = HUD + h.y * CELL + 1
  local hc = alive and COL_HEAD or COL_DEAD
  gfx.rect(hx, hy, CELL - 2, CELL - 2, hc)
  -- eyes
  local ex = hx + (dir.x == 1 and 9 or dir.x == -1 and 2 or 3)
  local ey = hy + (dir.y == 1 and 9 or dir.y == -1 and 2 or 3)
  gfx.pset(ex,     ey,     11)
  gfx.pset(ex + (dir.y ~= 0 and 6 or 0),
           ey + (dir.x ~= 0 and 6 or 0), 11)

  -- Game over overlay
  if not alive then
    local bx = W // 2 - 52
    local by = H // 2 - 14
    gfx.rect(bx - 2, by - 2, 108, 30, 12)
    gfx.rect(bx - 1, by - 1, 106, 28, 2)
    gfx.print("GAME OVER", bx + 14, by + 2, COL_TEXT)
    gfx.print("ENTER to restart", bx, by + 13, COL_DIM)
  end
end

return game.run("Snake", W, H)
