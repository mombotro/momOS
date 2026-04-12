-- p8.lua — PICO-8 cartridge player
-- Parses .p8 format, runs Lua code with PICO-8 API shim.
-- Viewport: 128×128 scaled to fit in window, letterboxed.
local WIN_W, WIN_H = 300, 320
local win = wm.open("p8", 100, 50, WIN_W, WIN_H)
if not win then return nil end

local CW, CH = 8, 8
local TB_H = CH + 4
local SB_H = CH + 4
local VIEW_W = WIN_W
local VIEW_H = WIN_H - TB_H - SB_H

-- Scale: fit 128×128 into VIEW_W × VIEW_H
local P8_W, P8_H = 128, 128
local SCALE = math.min(VIEW_W // P8_W, VIEW_H // P8_H)
local OX = (VIEW_W  - P8_W * SCALE) // 2
local OY = TB_H + (VIEW_H - P8_H * SCALE) // 2

-- ── PICO-8 state ──────────────────────────────────────────────────────────────
local p8_screen = {}   -- 128×128 color indices (0–15)
local p8_sprite = {}   -- 128×128 sprite sheet (4bpp, palette 0–15)
local p8_map    = {}   -- 128×64 tile indices
local p8_pal_map = {}  -- palette remap [0..15] → display index
local p8_camera = {x=0, y=0}
local p8_color  = 7

-- PICO-8 16-color palette mapped to momOS 32-color palette indices
-- (approximate nearest match)
local P8_PAL = {
  [0]=0,   -- black        → 0
  [1]=1,   -- dark navy    → 1
  [2]=2,   -- dark purple  → 2
  [3]=3,   -- dark green   → 3
  [4]=4,   -- brown        → 4
  [5]=5,   -- dark gray    → 5
  [6]=6,   -- light gray   → 6
  [7]=7,   -- white        → 7
  [8]=8,   -- red          → 8
  [9]=9,   -- orange       → 9
  [10]=10, -- yellow       → 10
  [11]=11, -- green        → 11
  [12]=12, -- blue         → 12
  [13]=13, -- lavender     → 13
  [14]=14, -- pink         → 14
  [15]=15, -- peach        → 15
}

local function p8_col(c)
  c = c & 15
  c = p8_pal_map[c] or c
  return P8_PAL[c] or 0
end

-- Init screen + palette map
for i = 0, 127*128 do p8_screen[i] = 0 end
for i = 0, 15 do p8_pal_map[i] = i end

-- ── PICO-8 API shim ───────────────────────────────────────────────────────────
local p8 = {}
local p8_cx, p8_cy = 0, 0      -- text cursor for print()
local p8_text_q   = {}          -- deferred text queue — flushed after blit_screen()

-- Graphics
function p8.pset(x, y, c)
  x = math.floor(x) - p8_camera.x
  y = math.floor(y) - p8_camera.y
  c = math.floor(c or p8_color) & 15
  if x >= 0 and x < 128 and y >= 0 and y < 128 then
    p8_screen[y*128+x] = c
  end
end

function p8.pget(x, y)
  x = math.floor(x); y = math.floor(y)
  if x < 0 or x >= 128 or y < 0 or y >= 128 then return 0 end
  return p8_screen[y*128+x] or 0
end

function p8.cls(c)
  c = math.floor(c or 0) & 15
  for i = 0, 128*128-1 do p8_screen[i] = c end
  p8_cx = 0; p8_cy = 0; p8_text_q = {}
end

function p8.color(c) p8_color = math.floor(c) & 15 end

function p8.camera(x, y)
  p8_camera.x = math.floor(x or 0)
  p8_camera.y = math.floor(y or 0)
end

function p8.line(x0, y0, x1, y1, c)
  c = math.floor(c or p8_color)
  x0=math.floor(x0); y0=math.floor(y0); x1=math.floor(x1); y1=math.floor(y1)
  local dx=math.abs(x1-x0); local dy=math.abs(y1-y0)
  local sx=x0<x1 and 1 or -1; local sy=y0<y1 and 1 or -1
  local err=dx-dy
  while true do
    p8.pset(x0,y0,c)
    if x0==x1 and y0==y1 then break end
    local e2=2*err
    if e2>-dy then err=err-dy; x0=x0+sx end
    if e2< dx then err=err+dx; y0=y0+sy end
  end
end

function p8.rect(x0, y0, x1, y1, c)
  c = math.floor(c or p8_color)
  for x=x0,x1 do p8.pset(x,y0,c); p8.pset(x,y1,c) end
  for y=y0+1,y1-1 do p8.pset(x0,y,c); p8.pset(x1,y,c) end
end

function p8.rectfill(x0, y0, x1, y1, c)
  c = math.floor(c or p8_color)
  if x0>x1 then x0,x1=x1,x0 end; if y0>y1 then y0,y1=y1,y0 end
  for y=y0,y1 do for x=x0,x1 do p8.pset(x,y,c) end end
end

function p8.circ(x, y, r, c)
  c = math.floor(c or p8_color)
  x=math.floor(x); y=math.floor(y); r=math.floor(r)
  local px,py,d = 0,r,1-r
  local function p8(a,b) p8.pset(x+a,y+b,c); p8.pset(x-a,y+b,c)
    p8.pset(x+a,y-b,c); p8.pset(x-a,y-b,c)
    p8.pset(x+b,y+a,c); p8.pset(x-b,y+a,c)
    p8.pset(x+b,y-a,c); p8.pset(x-b,y-a,c) end
  while px<=py do p8(px,py)
    if d<0 then d=d+2*px+3 else d=d+2*(px-py)+5; py=py-1 end; px=px+1 end
end

function p8.spr(n, x, y, w, h, flip_x, flip_y)
  w = w or 1; h = h or 1
  local cols = 16
  for sy = 0, h*8-1 do
    for sx = 0, w*8-1 do
      local src_x = (n % cols)*8 + sx
      local src_y = (n // cols)*8 + sy
      local src_px = flip_x and (w*8-1-sx) or sx
      local src_py = flip_y and (h*8-1-sy) or sy
      src_x = (n % cols)*8 + src_px
      src_y = (n // cols)*8 + src_py
      local c = 0
      local idx = src_y * 128 + src_x + 1
      if idx >= 1 and idx <= #p8_sprite then
        c = p8_sprite[idx] or 0
      end
      if c ~= 0 then p8.pset(x + sx, y + sy, c) end
    end
  end
end

function p8.map(mx, my, sx, sy, cw, ch, layer)
  for ty = 0, ch-1 do
    for tx = 0, cw-1 do
      local tile_idx = my*128 + mx + ty*128 + tx + 1
      local t = p8_map[tile_idx] or 0
      if t ~= 0 then p8.spr(t, sx + tx*8, sy + ty*8) end
    end
  end
end

function p8.mget(x, y)
  return p8_map[y*128+x+1] or 0
end

function p8.mset(x, y, t)
  p8_map[y*128+x+1] = t
end

function p8.pal(c0, c1, p_)
  if c0 == nil then
    for i=0,15 do p8_pal_map[i]=i end; return
  end
  p8_pal_map[c0 & 15] = c1 & 15
end

-- Input
local P8_BTN_MAP = { [0]="\x03",[1]="\x04",[2]="\x01",[3]="\x02",[4]="z",[5]="x" }
local p8_btn_state  = {}   -- held state (btn)
local p8_btnp_state = {}   -- just-pressed state (btnp), cleared after each update
for i=0,5 do p8_btn_state[i]=false; p8_btnp_state[i]=false end

function p8.btn(b, pl)
  return p8_btn_state[b] or false
end

function p8.btnp(b, pl)
  return p8_btnp_state[b] or false
end

-- Math
function p8.rnd(x) return math.random() * (x or 1) end
function p8.flr(x) return math.floor(x) end
function p8.ceil(x) return math.ceil(x) end
function p8.abs(x) return math.abs(x) end
function p8.max(a,b) return math.max(a,b) end
function p8.min(a,b) return math.min(a,b) end
function p8.mid(a,b,c) return math.max(a,math.min(b,c)) end
function p8.sqrt(x) return math.sqrt(x) end
function p8.cos(x) return math.cos(x * math.pi * 2) end
function p8.sin(x) return -math.sin(x * math.pi * 2) end
function p8.atan2(y,x) return math.atan(y,x) / (math.pi*2) end

-- String
function p8.tostr(v, hex) return tostring(v) end
function p8.tonum(s) return tonumber(s) or 0 end
function p8.sub(s,a,b) return string.sub(s,a,b) end
function p8.print(s, x, y, c)
  -- PICO-8 print(s), print(s,x,y) or print(s,x,y,col)
  if x ~= nil then p8_cx = math.floor(x); p8_cy = math.floor(y) end
  c = math.floor(c or p8_color) & 15
  s = tostring(s)
  -- Queue for rendering AFTER blit_screen so text sits on top of pixel graphics
  p8_text_q[#p8_text_q+1] = {s=s, x=p8_cx, y=p8_cy, c=c}
  -- Advance cursor (PICO-8: 4px per char, 6px per newline)
  for i = 1, #s do
    if s:sub(i,i) == "\n" then p8_cx = 0; p8_cy = p8_cy + 6
    else p8_cx = p8_cx + 4 end
  end
end

local function flush_text()
  for _, t in ipairs(p8_text_q) do
    -- At SCALE=2 each p8 px = 2 momOS px; momOS gfx.print uses 8px chars which
    -- matches PICO-8's 4px chars at SCALE=2 (4×2=8). Perfect fit.
    gfx.print(t.s, OX + t.x * SCALE, OY + t.y * SCALE, p8_col(t.c))
  end
  p8_text_q = {}
end

-- Audio stubs (no audio engine integration yet)
function p8.sfx(n, ch, off, len) end
function p8.music(n, fade, cmask) end

-- Misc
function p8.peek(a) return 0 end
function p8.poke(a, v) end
function p8.stat(x) return 0 end

-- ── Cartridge loader ──────────────────────────────────────────────────────────
local cart_name    = "untitled"
local cart_error   = nil
local cart_update  = nil
local cart_draw    = nil
local cart_init    = nil
local cart_loaded  = false

local function parse_p8(data)
  -- Split into sections
  local sections = {}
  local cur_sec = nil
  local cur_lines = {}
  for line in (data.."\n"):gmatch("([^\n]*)\n") do
    if line:sub(1,2) == "__" and line:sub(-2) == "__" then
      if cur_sec then sections[cur_sec] = table.concat(cur_lines, "\n") end
      cur_sec = line:sub(3,-3)
      cur_lines = {}
    elseif cur_sec then
      cur_lines[#cur_lines+1] = line
    end
  end
  if cur_sec then sections[cur_sec] = table.concat(cur_lines, "\n") end
  return sections
end

local function load_gfx(gfx_str)
  -- 128×128 sprite sheet, each char = one nibble (hex digit)
  -- 2 chars per byte = 2 pixels per char? Actually 1 char = 1 pixel (4bpp nibble)
  local row = 0; local col = 0
  for c in gfx_str:gmatch("[0-9a-fA-F]") do
    local v = tonumber(c, 16) or 0
    p8_sprite[row*128+col+1] = v
    col = col + 1
    if col >= 128 then col = 0; row = row + 1; if row >= 128 then break end end
  end
end

local function load_map_data(map_str)
  local col = 0; local row = 0
  -- map data: pairs of hex digits per tile
  for pair in map_str:gmatch("([0-9a-fA-F][0-9a-fA-F])") do
    p8_map[row*128+col+1] = tonumber(pair, 16) or 0
    col = col + 1
    if col >= 128 then col = 0; row = row + 1; if row >= 64 then break end end
  end
end

local function inject_p8_env(env)
  -- Inject PICO-8 globals into environment
  local api = { "pset","pget","cls","color","camera","line","rect","rectfill",
                "circ","spr","map","mget","mset","pal","btn","btnp",
                "rnd","flr","ceil","abs","max","min","mid","sqrt","cos","sin","atan2",
                "tostr","tonum","sub","print","sfx","music","peek","poke","stat" }
  for _, fn in ipairs(api) do
    env[fn] = p8[fn]
  end
  -- math aliases already provided above
  env.t   = function() return pit_ticks() / 60 end
  env.time = env.t
  -- PICO-8 table helpers
  env.add = function(t, v) table.insert(t, v) end
  env.del = function(t, v)
    for i = 1, #t do
      if t[i] == v then table.remove(t, i); return end
    end
  end
  env.all = function(t)
    local i = 0
    return function()
      i = i + 1
      return t[i]
    end
  end
  env.count = function(t) return #t end
  env.foreach = function(t, f) for _, v in ipairs(t) do f(v) end end
end

-- ── PICO-8 Lua preprocessor ───────────────────────────────────────────────────
-- PICO-8 saves special glyphs as UTF-8 in .p8 files.  Standard Lua rejects
-- them as unexpected symbols.  Map button glyphs to their numeric btn() index,
-- map != to ~=, then strip any remaining non-ASCII bytes (custom font glyphs
-- that appear in strings/comments) replacing each multi-byte sequence with a
-- single space so line numbers stay accurate.
local function preprocess_p8_lua(src)
  -- Button glyphs → btn() numeric constants
  -- (UTF-8 byte sequences for the Unicode code points PICO-8 uses)
  local btns = {
    -- Variants WITH emoji variation selector U+FE0F (\xef\xb8\x8f) — check these first
    {"\xe2\xac\x85\xef\xb8\x8f", "0"},    -- ⬅️ left
    {"\xe2\x9e\xa1\xef\xb8\x8f", "1"},    -- ➡️ right
    {"\xe2\xac\x86\xef\xb8\x8f", "2"},    -- ⬆️ up
    {"\xe2\xac\x87\xef\xb8\x8f", "3"},    -- ⬇️ down
    {"\xf0\x9f\x85\xbe\xef\xb8\x8f","4"}, -- 🅾️ O button
    {"\xe2\x9d\x8e\xef\xb8\x8f", "5"},    -- ❎️ X button
    -- Bare glyphs without variation selector
    {"\xe2\xac\x85", "0"},    -- ⬅  U+2B05  left
    {"\xe2\x9e\xa1", "1"},    -- ➡  U+27A1  right
    {"\xe2\xac\x86", "2"},    -- ⬆  U+2B06  up
    {"\xe2\xac\x87", "3"},    -- ⬇  U+2B07  down
    {"\xf0\x9f\x85\xbe","4"}, -- 🅾  U+1F17E O button
    {"\xe2\x9d\x8e", "5"},    -- ❎  U+274E  X button
    {"\xe2\x97\x8f", "4"},    -- ●  U+25CF  alt O glyph
  }
  for _, b in ipairs(btns) do
    -- Use plain=true (4th arg) so byte sequences aren't treated as patterns
    local pat, rep = b[1], b[2]
    local result = {}
    local pos = 1
    while pos <= #src do
      local s, e = src:find(pat, pos, true)
      if not s then result[#result+1] = src:sub(pos); break end
      result[#result+1] = src:sub(pos, s-1)
      result[#result+1] = rep
      pos = e + 1
    end
    src = table.concat(result)
  end
  -- PICO-8 also allows != as sugar for ~=
  src = src:gsub("!=", "~=")

  -- Strip PICO-8 print format escape codes that Lua 5.4 rejects as invalid escapes:
  --   \#N  = inline color change (N is hex digit)
  --   \^c  = formatting (wide, tab-stop, etc.)
  -- These appear literally as \#N in the source text inside string literals.
  src = src:gsub("\\#[0-9a-fA-F]", "")
  src = src:gsub("\\%^[a-z]", "")

  -- PICO-8 compound assignment operators: +=  -=  *=  /=  %=
  -- Process line by line so we don't cross statement boundaries.
  do
    local compound = {
      {"%+", "+"},  -- +=
      {"%-", "-"},  -- -=
      {"%*", "*"},  -- *=
      {"%/", "/"},  -- /=
      {"%%", "%"},  -- %=
    }
    local lines = {}
    for line in (src.."\n"):gmatch("([^\n]*)\n") do
      for _, op in ipairs(compound) do
        -- Match: var OP= rest-of-line
        -- var may be simple identifier or table/index access
        line = line:gsub(
          "([%w_%.%[%]]+)%s*("..op[1]..")=%s*(.+)",
          function(v, _, e) return v.."="..v..op[2]..e end)
      end
      lines[#lines+1] = line
    end
    src = table.concat(lines, "\n")
  end

  -- PICO-8 shorthand if: `if (cond) stmt [else stmt2]` → proper Lua
  -- This must run before UTF-8 stripping so %b() can see real chars.
  -- Strategy: process line by line; if a line has `if <balanced-parens>`
  -- and what follows is NOT "then", wrap with then/end.
  do
    local lines = {}
    for line in (src.."\n"):gmatch("([^\n]*)\n") do
      -- Match: optional indent + "if" + optional space + balanced parens + rest
      local indent, cond, rest = line:match("^(%s*)if%s*(%b())(.*)$")
      if indent and cond then
        local trimmed = rest:match("^%s*(.-)%s*$") or ""
        -- Only rewrite if there's no "then" keyword starting the rest
        if trimmed ~= "" and not trimmed:match("^then[%s%(]") and trimmed ~= "then" then
          local inner = cond:sub(2, -2)  -- strip outer parens
          -- Split on " else " to handle optional else clause
          local body, els = trimmed:match("^(.-)%s+else%s+(.+)$")
          if body and els then
            line = indent.."if "..inner.." then "..body.." else "..els.." end"
          else
            line = indent.."if "..inner.." then "..trimmed.." end"
          end
        end
      end
      lines[#lines+1] = line
    end
    src = table.concat(lines, "\n")
  end

  -- Strip remaining non-ASCII UTF-8 sequences byte-by-byte, replacing each
  -- full sequence with a single space to preserve column numbers.
  local out = {}
  local i = 1
  while i <= #src do
    local b = src:byte(i)
    if b < 128 then
      out[#out+1] = src:sub(i, i)
      i = i + 1
    elseif b >= 240 then   -- 4-byte lead
      out[#out+1] = " "; i = i + 4
    elseif b >= 224 then   -- 3-byte lead
      out[#out+1] = " "; i = i + 3
    elseif b >= 192 then   -- 2-byte lead
      out[#out+1] = " "; i = i + 2
    else                   -- stray continuation byte
      i = i + 1
    end
  end
  return table.concat(out)
end

local function load_cart(data, name)
  cart_loaded = false; cart_error = nil
  cart_name = name or "cart"

  -- Reset state
  for i = 0, 128*128-1 do p8_screen[i] = 0; p8_sprite[i] = 0 end
  for i = 0, 128*64-1  do p8_map[i] = 0 end
  for i = 0, 15 do p8_pal_map[i] = i end
  p8_cx = 0; p8_cy = 0; p8_text_q = {}

  local sections = parse_p8(data)
  if sections["gfx"] then load_gfx(sections["gfx"]) end
  if sections["map"] then load_map_data(sections["map"]) end

  local lua_src = preprocess_p8_lua(sections["lua"] or "")

  -- Build sandbox environment
  local env = {}
  inject_p8_env(env)
  -- Standard Lua safe subset
  env.math = math; env.string = string; env.table = table
  env.ipairs = ipairs; env.pairs = pairs; env.type = type
  env.tostring = tostring; env.tonumber = tonumber
  env.error = error; env.assert = assert; env.pcall = pcall

  -- Load the cartridge Lua
  local fn, err = load(lua_src, name, "t", env)
  if not fn then cart_error = "load: "..tostring(err); return false end
  local ok, res = pcall(fn)
  if not ok then cart_error = "init: "..tostring(res); return false end

  -- Grab _update/_draw/_init from env
  cart_update = env._update or env._update60
  cart_draw   = env._draw
  cart_init   = env._init

  if cart_init then
    local ok2, err2 = pcall(cart_init)
    if not ok2 then cart_error = "_init: "..tostring(err2); return false end
  end

  cart_loaded = true
  return true
end

-- consume global handoff
local function try_open_file(p)
  local data = fs.read(p)
  if not data then cart_error = "not found: "..p; return end
  local name = p:match("[^/]+$") or p
  load_cart(data, name)
end

if _G.p8_open_file then
  try_open_file(_G.p8_open_file); _G.p8_open_file = nil
end

-- ── Blit p8_screen to momOS window ───────────────────────────────────────────
local function blit_screen()
  for y = 0, P8_H-1 do
    for x = 0, P8_W-1 do
      local c = p8_screen[y*128+x] or 0
      local mc = p8_col(c)
      if mc ~= 0 then
        gfx.rect(OX + x*SCALE, OY + y*SCALE, SCALE, SCALE, mc)
      end
    end
  end
end

-- ── Command mode ─────────────────────────────────────────────────────────────
local cmd_mode = false; local cmd_buf = ""

-- ── Draw ─────────────────────────────────────────────────────────────────────
local function draw()
  wm.focus(win)
  gfx.cls(0)
  -- viewport background
  gfx.rect(OX, OY, P8_W*SCALE, P8_H*SCALE, 0)
  if cart_loaded then
    p8_text_q = {}
    if cart_draw then
      local ok, err = pcall(cart_draw)
      if not ok then cart_error = "_draw: "..tostring(err); cart_loaded = false end
    end
    blit_screen()     -- pixel graphics first
    flush_text()      -- text on top (deferred from print() calls in _draw)
  else
    -- show error or welcome
    local msg = cart_error or "open a .p8 file with :o <path>"
    local lines = {}
    for w in msg:gmatch(".") do lines[#lines+1] = w end
    -- word wrap
    gfx.print("P8 PLAYER", OX + 2, OY + 4, 8)
    gfx.print(msg:sub(1, 36), OX + 2, OY + 20, 4)
    if #msg > 36 then gfx.print(msg:sub(37, 72), OX + 2, OY + 30, 4) end
  end

  -- toolbar
  gfx.rect(0, 0, WIN_W, TB_H, 2)
  gfx.print(cart_name, 2, 2, cart_loaded and 7 or 4)

  -- status
  local sb_y = WIN_H - SB_H
  gfx.rect(0, sb_y, WIN_W, SB_H, 2)
  gfx.rect(0, sb_y, WIN_W, 1, 9)
  if cmd_mode then
    gfx.print(":"..cmd_buf.."_", 2, sb_y + 2, 15)
  end

  wm.unfocus()
end

-- ── Update ────────────────────────────────────────────────────────────────────
local key_queue = {}

local function update()
  if cart_loaded and cart_update then
    local ok, err = pcall(cart_update)
    if not ok then cart_error = "_update: "..tostring(err); cart_loaded = false end
  end
  -- btnp fires only once per press; clear after update sees it
  for i=0,5 do p8_btnp_state[i]=false end
end

-- ── Input ─────────────────────────────────────────────────────────────────────
local P8_KEY_MAP = {
  ["\x03"] = 0,   -- left
  ["\x04"] = 1,   -- right
  ["\x01"] = 2,   -- up
  ["\x02"] = 3,   -- down
  ["z"]=4, ["Z"]=4, ["n"]=4,
  ["x"]=5, ["X"]=5, ["m"]=5,
}

local function on_input(c)
  if cmd_mode then
    if c == "\n" then
      local line = cmd_buf:match("^%s*(.-)%s*$"); cmd_mode=false; cmd_buf=""
      if line == "q" then wm.close(win); return "quit"
      elseif line:sub(1,2) == "o " then try_open_file(line:sub(3))
      end
    elseif c == "\x1b" then cmd_mode=false; cmd_buf=""
    elseif c == "\b" then if #cmd_buf>0 then cmd_buf=cmd_buf:sub(1,-2) end
    elseif c >= " " then cmd_buf=cmd_buf..c end
    return
  end
  if c == "\x1b" then cmd_mode=true; return end
  -- update button state for p8.btn / p8.btnp
  local b = P8_KEY_MAP[c]
  if b then p8_btn_state[b] = true; p8_btnp_state[b] = true end
end

return { draw=draw, update=update, input=on_input, win=win, name="p8" }
