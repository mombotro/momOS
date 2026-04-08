-- terminal app — spawns a new terminal window
local WIN_W = 400
local WIN_H = 300
local win = wm.open("terminal", 80, 60, WIN_W, WIN_H)
if not win then return nil end

local CW, CH = 8, 8
local COLS = math.floor(WIN_W / CW)
local ROWS = math.floor(WIN_H / CH)

local COL_BG     = 1
local COL_FG     = 7
local COL_DIM    = 8
local COL_WARN   = 4
local COL_PROMPT = 15

local lines = {}
local function push(s, col)
  lines[#lines+1] = { text = s or "", col = col or COL_FG }
  if #lines > 200 then table.remove(lines, 1) end
end

local input_line = ""
local cwd = "/"

local function abspath(p)
  if p:sub(1,1) == "/" then return p end
  if cwd == "/" then return "/"..p else return cwd.."/"..p end
end

local cmds = {}
cmds.help  = function(_) push("commands: help ls cat cd run clear", COL_DIM) end
cmds.clear = function(_) lines = {} end

cmds.ls = function(args)
  local path = abspath(args[1] or cwd)
  local entries = fs.list(path)
  if not entries then push("ls: not found: "..path, COL_WARN); return end
  for _, e in ipairs(entries) do
    local tag = e.is_dir and "DIR  " or "FILE "
    push(tag..e.name..(e.is_dir and "" or " "..e.size.."b"),
         e.is_dir and COL_PROMPT or COL_FG)
  end
end

cmds.cd = function(args)
  if not args[1] then cwd = "/"; return end
  local t = abspath(args[1])
  if not fs.list(t) then push("cd: not a directory: "..t, COL_WARN); return end
  cwd = t
end

cmds.cat = function(args)
  if not args[1] then push("usage: cat <file>", COL_DIM); return end
  local data = fs.read(abspath(args[1]))
  if not data then push("cat: not found: "..args[1], COL_WARN); return end
  for line in (data.."\n"):gmatch("([^\n]*)\n") do push(line) end
end

cmds.run = function(args)
  if not args[1] then push("usage: run <file>", COL_DIM); return end
  local code = fs.read(abspath(args[1]))
  if not code then push("run: not found: "..args[1], COL_WARN); return end
  local fn, err = load(code, args[1])
  if not fn then push("run: "..err, COL_WARN); return end
  local ok, result = pcall(fn)
  if not ok then push("run: "..tostring(result), COL_WARN)
  elseif type(result) == "table" then return result end
end

local function exec(line)
  line = line:match("^%s*(.-)%s*$")
  if line == "" then return end
  push("> "..line, COL_DIM)
  local parts = {}
  for w in line:gmatch("%S+") do parts[#parts+1] = w end
  local cmd = table.remove(parts, 1)
  if cmds[cmd] then cmds[cmd](parts)
  else push(cmd..": unknown command", COL_WARN) end
end

push("terminal", COL_PROMPT)

local function update() end

local function on_input(c)
  if c == "\n" then
    exec(input_line); input_line = ""
  elseif c == "\b" then
    if #input_line > 0 then input_line = input_line:sub(1,-2) end
  elseif c >= " " then
    if #input_line < COLS - 4 then input_line = input_line..c end
  end
end

local function draw()
  wm.focus(win)
  gfx.cls(COL_BG)
  local start = math.max(1, #lines - (ROWS - 2))
  for i = start, #lines do
    gfx.print(lines[i].text, 0, (i - start)*CH, lines[i].col)
  end
  local py = (ROWS-1)*CH
  local prompt = (cwd=="/" and "/" or cwd:match("[^/]+$").."/").."> "
  gfx.print(prompt..input_line, 0, py, COL_PROMPT)
  local cx = (#prompt + #input_line)*CW
  if (math.floor(pit_ticks()/30) % 2) == 0 then
    gfx.rect(cx, py, 2, CH-1, COL_FG)
  end
  wm.unfocus()
end

return { update=update, draw=draw, input=on_input, win=win, name="terminal" }
