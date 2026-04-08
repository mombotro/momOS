-- bouncer app — returns {update, draw, win}
local W, H = 200, 160
local win = wm.open("bouncer", 200, 80, W, H)
if not win then return nil end

local bx, by = 10, 10
local vx, vy = 3, 2
local bw, bh = 40, 40

local function update()
  bx = bx + vx; by = by + vy
  if bx < 0 then bx = 0; vx = -vx end
  if bx + bw > W then bx = W - bw; vx = -vx end
  if by < 0 then by = 0; vy = -vy end
  if by + bh > H then by = H - bh; vy = -vy end
end

local function draw()
  wm.focus(win)
  gfx.cls(0)
  gfx.rect(bx, by, bw, bh, 4)
  gfx.rect(bx + bw//2 - 1, by + 4,        3, bh - 8, 7)
  gfx.rect(bx + 4,         by + bh//2 - 1, bw - 8, 3, 7)
  wm.unfocus()
end

return { update=update, draw=draw, win=win, name="bouncer" }
