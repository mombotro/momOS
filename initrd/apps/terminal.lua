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
local cwd        = "/"
local history    = {}
local hist_idx   = 0

local write_mode = false
local write_file = nil
local write_buf  = {}

local function abspath(p)
  if p:sub(1,1) == "/" then return p end
  if cwd == "/" then return "/"..p else return cwd.."/"..p end
end

local cmds = {}
cmds.help  = function(_) push("commands: help ls cat cd run open write clear mkdir rm ps kill", COL_DIM) end
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
  elseif type(result) == "table" and app_launch then
    -- already launched by the script itself via wm.open; just register
  end
end

cmds.write = function(args)
  if not args[1] then push("usage: write <file>", COL_DIM); return end
  write_file = abspath(args[1])
  write_buf  = {}
  write_mode = true
  push("-- "..write_file.." --", COL_DIM)
  push("-- type lines, '.' alone to save, ESC to cancel --", COL_DIM)
end

cmds.mkdir = function(args)
  if not args[1] then push("usage: mkdir <dir>", COL_DIM); return end
  if not fs.mkdir(abspath(args[1])) then push("mkdir: failed", COL_WARN) end
end

cmds.rm = function(args)
  if not args[1] then push("usage: rm <path>", COL_DIM); return end
  if not fs.delete(abspath(args[1])) then push("rm: failed", COL_WARN) end
end

cmds.ps = function(_)
  local ps = (sys and sys.ps) or sys_ps
  if ps then
    for _, p in ipairs(ps()) do push(p.pid.." "..p.name, COL_FG) end
  end
end

cmds.kill = function(args)
  if not args[1] then push("usage: kill <name>", COL_DIM); return end
  local kill = (sys and sys.kill) or sys_kill
  if kill then
    if not kill(args[1]) then push("kill: not found: "..args[1], COL_WARN) end
  end
end

cmds.open = function(args)
  if not args[1] then push("usage: open <file>", COL_DIM); return end
  local path = abspath(args[1])
  if not fs.exists(path) then push("open: not found: "..path, COL_WARN); return end
  local ext = path:match("%.([^%.]+)$") or ""
  local launch = app_launch or (sys and sys.spawn)
  if not launch then push("open: no launcher", COL_WARN); return end
  if ext == "mpi" then
    pixel_open_file = path; launch("/apps/pixel.lua")
  elseif ext == "msm" then
    _G.chirp_open_file = path; launch("/apps/chirp.lua")
  elseif ext == "mtm" then
    _G.terrain_open_file = path; launch("/apps/terrain.lua")
  elseif ext == "p8" then
    _G.p8_open_file = path; launch("/apps/p8.lua")
  elseif ext == "lua" then
    cmds.run(args)
  else
    -- txt, md, and anything else → quill
    quill_open_file = path; launch("/apps/quill.lua")
  end
end

local function exec(line)
  line = line:match("^%s*(.-)%s*$")
  if line == "" then return end
  if #history == 0 or history[#history] ~= line then
    history[#history+1] = line
    if #history > 100 then table.remove(history, 1) end
  end
  hist_idx = 0
  push("> "..line, COL_DIM)
  local parts = {}
  for w in line:gmatch("%S+") do parts[#parts+1] = w end
  local cmd = table.remove(parts, 1)
  if cmds[cmd] then
    cmds[cmd](parts)
  else
    local src = line:sub(1,1) == "=" and ("return "..line:sub(2)) or line
    local fn, lerr = load(src)
    if fn then
      local ok, val = pcall(fn)
      if ok then
        if val ~= nil then push(tostring(val), COL_FG) end
      else push(tostring(val), COL_WARN) end
    else
      push(cmd..": unknown command", COL_WARN)
    end
  end
end

push("terminal", COL_PROMPT)

local function update() end

local function on_input(c)
  if write_mode then
    if c == "\x1b" then
      write_mode = false; write_file = nil; write_buf = {}
      input_line = ""
      push("-- cancelled --", COL_DIM)
    elseif c == "\n" then
      if input_line == "." then
        local content = table.concat(write_buf, "\n")
        if #write_buf > 0 then content = content.."\n" end
        if fs.write(write_file, content) then
          push("-- saved ("..#content.." bytes) --", COL_DIM)
        else
          push("-- write failed --", COL_WARN)
        end
        write_mode = false; write_file = nil; write_buf = {}
      else
        write_buf[#write_buf+1] = input_line
        push(input_line)
      end
      input_line = ""
    elseif c == "\b" then
      if #input_line > 0 then input_line = input_line:sub(1,-2) end
    elseif c >= " " then
      input_line = input_line..c
    end
  else
    if c == "\n" then
      exec(input_line); input_line = ""
    elseif c == "\b" then
      if #input_line > 0 then input_line = input_line:sub(1,-2) end
    elseif c == "\x01" then
      if #history > 0 then
        hist_idx = math.min(hist_idx + 1, #history)
        input_line = history[#history - hist_idx + 1]
      end
    elseif c == "\x02" then
      if hist_idx > 0 then
        hist_idx = hist_idx - 1
        input_line = hist_idx == 0 and "" or history[#history - hist_idx + 1]
      end
    elseif c >= " " then
      if #input_line < COLS - 4 then input_line = input_line..c end
    end
  end
end

local function draw()
  wm.focus(win)
  gfx.cls(COL_BG)
  local _, _, tw, th = wm.rect(win)
  local cols = math.floor(tw / CW)
  local rows = math.floor(th / CH)
  local start = math.max(1, #lines - (rows - 2))
  for i = start, #lines do
    gfx.print(lines[i].text, 0, (i - start)*CH, lines[i].col)
  end
  local py = (rows-1)*CH
  local prompt, prompt_col
  if write_mode then
    local fname = write_file and write_file:match("[^/]+$") or "?"
    prompt = "write:"..fname.."> "
    prompt_col = COL_WARN
  else
    prompt = (cwd=="/" and "/" or cwd:match("[^/]+$").."/").."> "
    prompt_col = COL_PROMPT
  end
  gfx.print(prompt..input_line, 0, py, prompt_col)
  if (math.floor(pit_ticks()/30) % 2) == 0 then
    gfx.rect((#prompt + #input_line)*CW, py, 2, CH-1, COL_FG)
  end
  wm.unfocus()
end

return { update=update, draw=draw, input=on_input, win=win, name="terminal" }
