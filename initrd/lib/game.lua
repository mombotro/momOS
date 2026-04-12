-- lib/game.lua — native Lua game framework for momOS
--
-- Usage:
--   local game = dofile("/lib/game.lua")
--
--   function game._init()   ... end   -- called once before first frame
--   function game._update() ... end   -- called every frame (logic)
--   function game._draw()   ... end   -- called every frame (rendering)
--
--   return game.run("My Game", 320, 240)
--
-- Input:
--   game.key(k)       → true while key k is held  (uses input.key_down)
--   game.keypressed(k)→ true on the frame k was first pressed
--
-- Common key constants are provided as game.KEY_* for convenience.
-- All momOS gfx.* / audio.* / sys.* APIs are available directly.

local M = {}

-- ── Key constants ─────────────────────────────────────────────────────────────
M.KEY_UP    = "\x01"
M.KEY_DOWN  = "\x02"
M.KEY_LEFT  = "\x03"
M.KEY_RIGHT = "\x04"
M.KEY_ENTER = "\n"
M.KEY_ESC   = "\x1b"
M.KEY_BACK  = "\x08"
M.KEY_Z     = "z"
M.KEY_X     = "x"
M.KEY_SPACE = " "

-- ── State ─────────────────────────────────────────────────────────────────────
M.W   = 0
M.H   = 0
M.win = nil
M._init   = nil
M._update = nil
M._draw   = nil

local _pressed  = {}   -- keys pressed this frame (cleared after _update)
local _err      = nil  -- fatal error string

-- ── Input helpers ─────────────────────────────────────────────────────────────
function M.key(k)
  return input.key_down(k)
end

function M.keypressed(k)
  return _pressed[k] == true
end

-- ── run(title, w, h) — open window, wire up callbacks, return app table ───────
function M.run(title, w, h)
  w = w or 320
  h = h or 240
  M.W = w
  M.H = h

  -- Center on 640×480 screen
  local sx = math.max(0, (640 - w) // 2)
  local sy = math.max(4, (480 - h) // 2 - 20)
  M.win = wm.open(title or "game", sx, sy, w, h)
  if not M.win then return nil end

  if M._init then
    local ok, err = pcall(M._init)
    if not ok then _err = "init: "..tostring(err) end
  end

  -- ── draw callback (registered with app scheduler) ──────────────────────────
  local function draw()
    wm.focus(M.win)
    if _err then
      gfx.cls(12)
      gfx.print("ERROR", 4, 4, 7)
      -- word-wrap the error across multiple lines
      local s = _err
      local y = 16
      while #s > 0 and y < M.H - 10 do
        gfx.print(s:sub(1, 38), 4, y, 15)
        s = s:sub(39)
        y = y + 10
      end
    elseif M._draw then
      local ok, err = pcall(M._draw)
      if not ok then
        _err = "_draw: "..tostring(err)
      end
    end
    wm.unfocus()
  end

  -- ── update callback ─────────────────────────────────────────────────────────
  local function update()
    if not _err and M._update then
      local ok, err = pcall(M._update)
      if not ok then _err = "_update: "..tostring(err) end
    end
    _pressed = {}   -- clear just-pressed state after update
  end

  -- ── input callback — fires on each keypress before update ───────────────────
  local function on_input(c)
    if c == M.KEY_ESC then
      wm.close(M.win)
      return "quit"
    end
    _pressed[c] = true
  end

  return { draw=draw, update=update, input=on_input, win=M.win, name=title or "game" }
end

return M
