-- hello.lua — minimal momOS window app
-- Drop in initrd/apps/hello.lua and run with launch("/apps/hello.lua")

local WIN_W, WIN_H = 200, 80
local win = wm.open("Hello", (640-WIN_W)//2, (480-WIN_H)//2, WIN_W, WIN_H)

local ticks = 0

local function draw()
  wm.focus(win)
  gfx.cls(2)
  gfx.print("Hello, momOS!", 20, 20, 7)
  gfx.print("ticks: "..ticks, 20, 36, 8)
  wm.unfocus()
end

local function update()
  ticks = sys.ticks()
end

local function on_input(c)
  if c == "\x1b" then wm.close(win); return "quit" end
end

return { draw=draw, update=update, input=on_input, win=win, name="Hello" }
