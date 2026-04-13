-- asteroid.lua — asteroids clone
local WIN_W, WIN_H = 400, 300
local win = wm.open("asteroid", 80, 40, WIN_W, WIN_H)
if not win then return nil end

-- ── Math helpers ──────────────────────────────────────────────────────────────
local sin, cos, pi = math.sin, math.cos, math.pi
local function rnd(n) return math.random() * n end
local function rnd_range(a, b) return a + math.random() * (b - a) end
local function wrap(v, mn, mx)
  local r = mx - mn
  while v < mn do v = v + r end
  while v >= mx do v = v - r end
  return v
end
local function dist(ax, ay, bx, by)
  local dx, dy = ax - bx, ay - by
  return math.sqrt(dx*dx + dy*dy)
end

-- ── Game state ────────────────────────────────────────────────────────────────
local STATE_PLAY  = 1
local STATE_DEAD  = 2
local STATE_WIN   = 3
local STATE_OVER  = 4

local ship        = {}
local bullets     = {}
local asteroids   = {}
local particles   = {}
local score       = 0
local lives       = 3
local level       = 1
local state       = STATE_DEAD   -- start on title/respawn
local respawn_t   = 0
local flash_t     = 0            -- ship flash after respawn
local BULLET_SPD  = 180          -- px/sec
local BULLET_LIFE = 0.8          -- seconds
local SHIP_ACCEL  = 220
local SHIP_DRAG   = 0.97
local SHIP_ROT    = 3.5          -- rad/sec
local DT          = 1/60

-- ── Ship ──────────────────────────────────────────────────────────────────────
local function spawn_ship()
  ship = { x=WIN_W/2, y=WIN_H/2, vx=0, vy=0, angle=0, alive=true, invuln=90 }
  flash_t = 90
end

-- ── Asteroids ─────────────────────────────────────────────────────────────────
local AST_SIZES = { big=22, med=13, small=7 }
local AST_SPEED = { big=25, med=45, small=75 }
local AST_PTS   = { big=20, med=50, small=100 }
-- unique polygon per asteroid (offsets from radius)
local function make_verts(n, r)
  local v = {}
  for i = 1, n do
    local a = (i-1) / n * 2 * pi + rnd(0.4)
    local rr = r * rnd_range(0.7, 1.3)
    v[i] = { a=a, r=rr }
  end
  return v
end

local function new_ast(x, y, sz, vx, vy)
  local r  = AST_SIZES[sz]
  local sp = AST_SPEED[sz]
  if not vx then
    local a = rnd(2*pi)
    vx = cos(a) * sp
    vy = sin(a) * sp
  end
  return { x=x, y=y, vx=vx, vy=vy, sz=sz, r=r,
           verts=make_verts(10, r), angle=0, rot=rnd_range(-1.2, 1.2) }
end

local function spawn_level(lv)
  asteroids = {}
  local n = 2 + lv
  for _ = 1, n do
    -- spawn away from ship
    local x, y
    repeat
      x = math.random(WIN_W)
      y = math.random(WIN_H)
    until dist(x, y, WIN_W/2, WIN_H/2) > 80
    asteroids[#asteroids+1] = new_ast(x, y, "big")
  end
end

-- ── Bullets ───────────────────────────────────────────────────────────────────
local function fire_bullet()
  local bx = ship.x + cos(ship.angle) * 12
  local by = ship.y + sin(ship.angle) * 12
  bullets[#bullets+1] = {
    x=bx, y=by,
    vx = ship.vx + cos(ship.angle)*BULLET_SPD,
    vy = ship.vy + sin(ship.angle)*BULLET_SPD,
    life = BULLET_LIFE
  }
end

-- ── Particles ─────────────────────────────────────────────────────────────────
local function explode(x, y, n, col)
  for _ = 1, n do
    local a = rnd(2*pi)
    local sp = rnd_range(20, 80)
    particles[#particles+1] = {
      x=x, y=y,
      vx=cos(a)*sp, vy=sin(a)*sp,
      life=rnd_range(0.3, 0.9),
      maxlife=1, col=col or 7
    }
  end
end

-- ── Polygon collision (circle-circle for speed) ───────────────────────────────
local function ast_hit(ast, bx, by, brad)
  return dist(ast.x, ast.y, bx, by) < ast.r + brad
end

-- ── Input state ───────────────────────────────────────────────────────────────
local KEY_LEFT  = false
local KEY_RIGHT = false
local KEY_UP    = false
local KEY_FIRE  = false
local KEY_FIRE_PREV = false
local fire_cooldown = 0

local function poll_keys()
  KEY_UP    = input.key_down("up")    or input.key_down("w")
  KEY_LEFT  = input.key_down("left")  or input.key_down("a")
  KEY_RIGHT = input.key_down("right") or input.key_down("d")
  KEY_FIRE  = input.key_down("space") or input.key_down("z")
end

-- ── Start / restart ───────────────────────────────────────────────────────────
local function start_game()
  score=0; lives=3; level=1
  spawn_ship()
  spawn_level(level)
  bullets={}; particles={}
  state=STATE_PLAY
end

-- ── Update ────────────────────────────────────────────────────────────────────
local function update()
  if state == STATE_DEAD then
    respawn_t = respawn_t - 1
    if respawn_t <= 0 and lives > 0 then
      spawn_ship(); state=STATE_PLAY
    elseif respawn_t <= 0 then
      state = STATE_OVER
    end
    -- particles still update
  end

  if state == STATE_PLAY then
    -- ship
    if ship.invuln > 0 then ship.invuln = ship.invuln - 1 end
    if flash_t > 0 then flash_t = flash_t - 1 end

    if KEY_LEFT  then ship.angle = ship.angle - SHIP_ROT * DT end
    if KEY_RIGHT then ship.angle = ship.angle + SHIP_ROT * DT end
    if KEY_UP then
      ship.vx = ship.vx + cos(ship.angle) * SHIP_ACCEL * DT
      ship.vy = ship.vy + sin(ship.angle) * SHIP_ACCEL * DT
    end
    ship.vx = ship.vx * SHIP_DRAG
    ship.vy = ship.vy * SHIP_DRAG
    ship.x  = wrap(ship.x + ship.vx * DT, 0, WIN_W)
    ship.y  = wrap(ship.y + ship.vy * DT, 0, WIN_H)

    -- fire
    if fire_cooldown > 0 then fire_cooldown = fire_cooldown - 1 end
    if KEY_FIRE and not KEY_FIRE_PREV and fire_cooldown == 0 then
      fire_bullet(); fire_cooldown = 8
    end
    KEY_FIRE_PREV = KEY_FIRE
  end

  -- bullets
  for i = #bullets, 1, -1 do
    local b = bullets[i]
    b.x = wrap(b.x + b.vx * DT, 0, WIN_W)
    b.y = wrap(b.y + b.vy * DT, 0, WIN_H)
    b.life = b.life - DT
    if b.life <= 0 then table.remove(bullets, i) end
  end

  -- asteroids
  for _, a in ipairs(asteroids) do
    a.x     = wrap(a.x + a.vx * DT, 0, WIN_W)
    a.y     = wrap(a.y + a.vy * DT, 0, WIN_H)
    a.angle = a.angle + a.rot * DT
  end

  -- particles
  for i = #particles, 1, -1 do
    local p = particles[i]
    p.x    = p.x + p.vx * DT
    p.y    = p.y + p.vy * DT
    p.vx   = p.vx * 0.97
    p.vy   = p.vy * 0.97
    p.life = p.life - DT
    if p.life <= 0 then table.remove(particles, i) end
  end

  -- bullet × asteroid collisions
  for bi = #bullets, 1, -1 do
    local b = bullets[bi]
    for ai = #asteroids, 1, -1 do
      local a = asteroids[ai]
      if ast_hit(a, b.x, b.y, 2) then
        -- score
        score = score + AST_PTS[a.sz]
        -- split
        explode(a.x, a.y, a.sz == "big" and 12 or (a.sz == "med" and 8 or 5),
                a.sz == "big" and 6 or (a.sz == "med" and 10 or 14))
        local children = { big="med", med="small", small=nil }
        local child = children[a.sz]
        if child then
          for _ = 1, 2 do
            local speed = AST_SPEED[child]
            local ang   = rnd(2*pi)
            asteroids[#asteroids+1] = new_ast(a.x, a.y, child,
              cos(ang)*speed, sin(ang)*speed)
          end
        end
        table.remove(asteroids, ai)
        table.remove(bullets,   bi)
        break
      end
    end
  end

  -- ship × asteroid collisions
  if state == STATE_PLAY and ship.invuln == 0 then
    for _, a in ipairs(asteroids) do
      if ast_hit(a, ship.x, ship.y, 7) then
        explode(ship.x, ship.y, 20, 15)
        lives = lives - 1
        state = STATE_DEAD
        respawn_t = 90
        break
      end
    end
  end

  -- level clear
  if state == STATE_PLAY and #asteroids == 0 then
    level = level + 1
    spawn_level(level)
    spawn_ship()
    state = STATE_PLAY
  end
end

-- ── Draw asteroid polygon ─────────────────────────────────────────────────────
local function draw_ast(a)
  local vv = a.verts
  local n  = #vv
  for i = 1, n do
    local j  = i % n + 1
    local a1 = vv[i].a + a.angle
    local a2 = vv[j].a + a.angle
    local x1 = a.x + cos(a1) * vv[i].r
    local y1 = a.y + sin(a1) * vv[i].r
    local x2 = a.x + cos(a2) * vv[j].r
    local y2 = a.y + sin(a2) * vv[j].r
    gfx.line(math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2), 7)
  end
end

local function draw_ship()
  if flash_t > 0 and flash_t % 6 < 3 then return end  -- blink when invulnerable
  local a = ship.angle
  -- nose
  local nx = ship.x + cos(a) * 11
  local ny = ship.y + sin(a) * 11
  -- left wing
  local lx = ship.x + cos(a + 2.5) * 8
  local ly = ship.y + sin(a + 2.5) * 8
  -- right wing
  local rx = ship.x + cos(a - 2.5) * 8
  local ry = ship.y + sin(a - 2.5) * 8
  -- back center (concave)
  local bx = ship.x + cos(a + pi) * 5
  local by = ship.y + sin(a + pi) * 5

  gfx.line(math.floor(nx), math.floor(ny), math.floor(lx), math.floor(ly), 7)
  gfx.line(math.floor(nx), math.floor(ny), math.floor(rx), math.floor(ry), 7)
  gfx.line(math.floor(lx), math.floor(ly), math.floor(bx), math.floor(by), 7)
  gfx.line(math.floor(rx), math.floor(ry), math.floor(bx), math.floor(by), 7)

  -- thrust flame
  if KEY_UP and math.random(2) == 1 then
    local fa = a + pi
    local fx  = ship.x + cos(fa) * (7 + math.random(5))
    local fy  = ship.y + sin(fa) * (7 + math.random(5))
    gfx.line(math.floor(bx), math.floor(by), math.floor(fx), math.floor(fy), 10)
  end
end

-- ── Draw ──────────────────────────────────────────────────────────────────────
local function draw()
  wm.focus(win)
  gfx.cls(0)

  -- particles
  for _, p in ipairs(particles) do
    local alpha = p.life / p.maxlife
    local c = alpha > 0.6 and 7 or (alpha > 0.3 and 9 or 8)
    gfx.pset(math.floor(p.x), math.floor(p.y), c)
  end

  -- asteroids
  for _, a in ipairs(asteroids) do draw_ast(a) end

  -- bullets
  for _, b in ipairs(bullets) do
    gfx.pset(math.floor(b.x), math.floor(b.y), 15)
    gfx.pset(math.floor(b.x)+1, math.floor(b.y), 15)
  end

  -- ship
  if state == STATE_PLAY then draw_ship() end

  -- HUD
  gfx.print("SCORE "..score, 2, 2, 7)
  gfx.print("LV "..level, WIN_W//2 - 16, 2, 9)
  for i = 1, lives do
    local lx = WIN_W - 2 - i * 12
    gfx.line(lx+4, 2, lx,   8, 7)
    gfx.line(lx+4, 2, lx+8, 8, 7)
    gfx.line(lx+2, 6, lx+6, 6, 7)
  end

  if state == STATE_DEAD and lives > 0 then
    gfx.print("-- RESPAWNING --", WIN_W//2 - 64, WIN_H//2 - 4, 9)
  end
  if state == STATE_OVER then
    gfx.print("GAME OVER", WIN_W//2 - 36, WIN_H//2 - 12, 4)
    gfx.print("SCORE "..score, WIN_W//2 - 28, WIN_H//2, 7)
    gfx.print("SPACE to play again", WIN_W//2 - 76, WIN_H//2 + 12, 8)
  end
  if state == STATE_DEAD and lives <= 0 then
    -- handled above
  end

  -- title screen (before first game)
  wm.unfocus()
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local function on_input(c)
  if (state == STATE_OVER or (state == STATE_DEAD and lives <= 0)) then
    if c == " " or c == "r" or c == "R" then start_game() end
    return
  end
end

-- start immediately
start_game()

return { draw=draw, update=function()
  poll_keys()
  update()
end, input=on_input, win=win, name="asteroid" }
