-- game.lua — game template using lib/game.lua framework
-- Drop in initrd/apps/game.lua

local game = dofile("/lib/game.lua")

local W, H = 320, 240
local x, y = W//2, H//2
local speed = 2

function game._init()
  x, y = W//2, H//2
end

function game._update()
  if game.key(game.KEY_LEFT)  then x = x - speed end
  if game.key(game.KEY_RIGHT) then x = x + speed end
  if game.key(game.KEY_UP)    then y = y - speed end
  if game.key(game.KEY_DOWN)  then y = y + speed end
  -- clamp to window
  x = math.max(0, math.min(W-8, x))
  y = math.max(0, math.min(H-8, y))
end

function game._draw()
  gfx.cls(0)
  gfx.print("Arrow keys to move. ESC to quit.", 4, 4, 8)
  gfx.rectb(0, 0, W, H, 9)          -- border
  gfx.rect(x, y, 8, 8, 7)           -- player
end

return game.run("Game Template", W, H)
