-- momOS desktop

local TB_H  = 20   -- taskbar height at bottom
local WM_TH = 16   -- must match WM_TITLE_H in wm.h
local WM_B  = 1    -- must match WM_BORDER  in wm.h

-- ── Terminal output buffer ────────────────────────────────────────────────────
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

-- ── App registry ──────────────────────────────────────────────────────────────
local app_list = {}
local focused_app = nil   -- nil = main terminal has focus

local function set_focus(app, win)
  focused_app = app
  if win then wm.raise(win); wm.set_focused(win) end
end

local function launch(path)
  local code = fs.read(path)
  if not code then push("launch: can't read "..path, COL_WARN); return end
  local fn, err = load(code, path)
  if not fn then push("launch: "..err, COL_WARN); return end
  local ok, app = pcall(fn)
  if not ok then push("launch: "..tostring(app), COL_WARN); return end
  if type(app) ~= "table" then push("launch: no app returned", COL_WARN); return end
  app_list[#app_list+1] = app
  set_focus(app, app.win)
end

-- ── Main terminal ─────────────────────────────────────────────────────────────
local WIN_W = SCREEN_W - 120
local WIN_H = SCREEN_H - 80 - TB_H
local WIN_X, WIN_Y = 60, 40
local term_win = wm.open("terminal", WIN_X, WIN_Y, WIN_W, WIN_H)
wm.set_focused(term_win)

local CW, CH = 8, 8
local COLS = math.floor(WIN_W / CW)
local ROWS = math.floor(WIN_H / CH)

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
  elseif type(result) == "table" then
    app_list[#app_list+1] = result
    set_focus(result, result.win)
  end
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

push("momOS v0.1", COL_PROMPT)
push("type 'help' for commands", COL_DIM)

-- ── Desktop icons ─────────────────────────────────────────────────────────────
local ICON_W, ICON_H = 48, 48
local icons = {
  { label="terminal", x=8, y=8,  col=3,
    action=function() launch("/apps/terminal.lua") end },
  { label="bouncer",  x=8, y=72, col=4,
    action=function() launch("/apps/bouncer.lua") end },
}

local mouse_prev  = false
local mbtn1_prev  = false
local icon_flash  = {}      -- icon label → flash countdown

-- ── Close / maximize helpers ──────────────────────────────────────────────────
local win_saved = {}   -- win userdata → {x,y,w,h} saved before maximize

local function close_app(app, win)
  for i, a in ipairs(app_list) do
    if a == app then table.remove(app_list, i); break end
  end
  win_saved[win] = nil
  wm.close(win)
  if focused_app == app then
    focused_app = nil
    if term_win then wm.set_focused(term_win) end
  end
end

local function close_terminal()
  if not term_win then return end
  win_saved[term_win] = nil
  wm.close(term_win)
  term_win = nil
  focused_app = nil
  -- focus topmost app if any
  if #app_list > 0 then
    local a = app_list[#app_list]
    if a.win then set_focus(a, a.win) end
  end
end

local function toggle_maximize(win, app)
  if not win then return end
  local saved = win_saved[win]
  if saved then
    -- restore
    wm.resize(win, saved.w, saved.h)
    wm.move(win, saved.x, saved.y)
    win_saved[win] = nil
  else
    -- maximize to fill screen minus taskbar
    local wx, wy, ww, wh = wm.rect(win)
    win_saved[win] = {x=wx, y=wy, w=ww, h=wh}
    wm.resize(win, SCREEN_W - 2*WM_B, SCREEN_H - TB_H - WM_TH - 2*WM_B)
    wm.move(win, WM_B, WM_TH + WM_B)
  end
  set_focus(app, win)
end

local function icon_at(mx, my)
  for _, ic in ipairs(icons) do
    if mx >= ic.x and mx < ic.x + ICON_W
    and my >= ic.y and my < ic.y + ICON_H + CH then
      return ic
    end
  end
end

-- ── Window hit detection ──────────────────────────────────────────────────────
local drag_win,   drag_ox,    drag_oy
local resize_win, resize_app, resize_edge
local resize_ox,  resize_oy,  resize_orig_w, resize_orig_h
local MIN_W, MIN_H = 80, 40

-- Returns "close", "restore", "minimize", or nil
-- Mirrors wm.c: btn_r = bx+bw-3, btn_y = by+(WM_TH-10)/2, buttons 12×10, gap 2
local function chrome_btn_hit(win, mx, my)
  local wx, wy, ww = wm.rect(win)
  -- bx = wx-WM_B, bw = ww+2*WM_B  →  bx+bw-3 = wx+ww-2
  local btn_r = wx + ww - 2
  -- by = wy-WM_TH-WM_B  →  by+(WM_TH-10)/2 = wy-WM_TH-WM_B+(WM_TH-10)/2
  local btn_y = wy - WM_TH - WM_B + (WM_TH - 10) // 2
  if my < btn_y or my >= btn_y + 10 then return nil end
  if mx >= btn_r - 12 and mx < btn_r      then return "close"   end
  if mx >= btn_r - 26 and mx < btn_r - 14 then return "restore" end
  if mx >= btn_r - 40 and mx < btn_r - 28 then return "minimize" end
  return nil
end

local function win_title_hit(win, mx, my)
  local wx, wy, ww = wm.rect(win)
  if chrome_btn_hit(win, mx, my) then return false end
  return mx >= wx - WM_B and mx < wx + ww + WM_B
     and my >= wy - WM_TH - WM_B and my < wy
end

local function win_any_hit(win, mx, my)
  local wx, wy, ww, wh = wm.rect(win)
  return mx >= wx - WM_B and mx < wx + ww + WM_B
     and my >= wy - WM_TH - WM_B and my < wy + wh + WM_B
end

-- Returns "right", "bottom", "corner", or nil
local RESIZE_GRAB = 5
local function resize_zone(win, mx, my)
  local wx, wy, ww, wh = wm.rect(win)
  local on_r = mx >= wx + ww - 1 and mx < wx + ww + RESIZE_GRAB
  local on_b = my >= wy + wh - 1 and my < wy + wh + RESIZE_GRAB
  if on_r and on_b then return "corner" end
  if on_r then return "right"  end
  if on_b then return "bottom" end
end

-- ── Taskbar ───────────────────────────────────────────────────────────────────
local BTN_W = 88
local function taskbar_btn_x(i) return 4 + (i - 1) * (BTN_W + 4) end

local function build_all_wins()
  local all = {}
  if term_win then all[#all+1] = {name="terminal", win=term_win, app=nil} end
  for _, a in ipairs(app_list) do
    if a.win then all[#all+1] = {name=(a.name or "app"), win=a.win, app=a} end
  end
  -- sort ascending by z so reverse iteration = topmost first
  table.sort(all, function(a, b) return wm.z(a.win) < wm.z(b.win) end)
  return all
end

local function taskbar_click(mx, my)
  local tb_y = SCREEN_H - TB_H
  if my < tb_y then return end
  local all = build_all_wins()
  for i, entry in ipairs(all) do
    local bx = taskbar_btn_x(i)
    if mx >= bx and mx < bx + BTN_W then
      if wm.is_minimized(entry.win) then
        wm.minimize(entry.win, false)
      end
      set_focus(entry.app, entry.win)
      return
    end
  end
end

-- ── Main update ───────────────────────────────────────────────────────────────
function _update()
  local mx, my = mouse.x(), mouse.y()
  local mbtn  = mouse.btn(0)
  local mbtn1 = mouse.btn(1)

  -- tick icon flash timers
  for k, v in pairs(icon_flash) do
    icon_flash[k] = v - 1
    if icon_flash[k] <= 0 then icon_flash[k] = nil end
  end

  if mbtn then
    if not drag_win and not resize_win then
      local all_wins = build_all_wins()
      -- check resize zones first (edges/corners) — topmost first
      for i = #all_wins, 1, -1 do
        local w = all_wins[i]
        if not wm.is_minimized(w.win) then
          local zone = resize_zone(w.win, mx, my)
          if zone then
            local wx, wy, ww, wh = wm.rect(w.win)
            resize_win    = w.win
            resize_app    = w.app
            resize_edge   = zone
            resize_ox     = mx; resize_oy = my
            resize_orig_w = ww; resize_orig_h = wh
            set_focus(w.app, w.win)
            break
          end
        end
      end
      -- then check title bar drag / Alt+drag — topmost first
      if not resize_win then
        for i = #all_wins, 1, -1 do
          local w = all_wins[i]
          if not wm.is_minimized(w.win) then
            local grab = win_title_hit(w.win, mx, my)
                      or (input.key_down("lalt") and win_any_hit(w.win, mx, my))
            if grab then
              local wx, wy = wm.rect(w.win)
              drag_win = w.win
              drag_ox  = mx - wx
              drag_oy  = my - wy
              set_focus(w.app, w.win)
              break
            end
          end
        end
      end
    end
    if resize_win then
      local dx = mx - resize_ox
      local dy = my - resize_oy
      local nw = resize_orig_w
      local nh = resize_orig_h
      if resize_edge == "right"  or resize_edge == "corner" then
        nw = math.max(MIN_W, resize_orig_w + dx)
      end
      if resize_edge == "bottom" or resize_edge == "corner" then
        nh = math.max(MIN_H, resize_orig_h + dy)
      end
      wm.resize(resize_win, nw, nh)
    end
    if drag_win then wm.move(drag_win, mx - drag_ox, my - drag_oy) end
  else
    drag_win   = nil
    resize_win = nil
  end

  -- left click
  if mbtn and not mouse_prev then
    taskbar_click(mx, my)
    if my < SCREEN_H - TB_H then
      if drag_win then
        -- focus already handled in drag block
      else
        local all_wins = build_all_wins()
        local hit = false
        for i = #all_wins, 1, -1 do
          local w = all_wins[i]
          if not wm.is_minimized(w.win) and win_any_hit(w.win, mx, my) then
            local btn = chrome_btn_hit(w.win, mx, my)
            if btn == "close" then
              if w.app then
                close_app(w.app, w.win)
              else
                close_terminal()
              end
            elseif btn == "minimize" then
              wm.minimize(w.win, true)
              if focused_app == w.app then
                focused_app = nil
                if term_win then wm.set_focused(term_win) end
              end
            elseif btn == "restore" then
              toggle_maximize(w.win, w.app)
            else
              set_focus(w.app, w.win)
            end
            hit = true
            break
          end
        end
        if not hit then
          local ic = icon_at(mx, my)
          if ic then
            icon_flash[ic.label] = 12
            ic.action()
          end
        end
      end
    end
  end

  -- right click — close app from taskbar
  if mbtn1 and not mbtn1_prev then
    local tb_y = SCREEN_H - TB_H
    if my >= tb_y then
      local all = build_all_wins()
      for i, entry in ipairs(all) do
        local bx = taskbar_btn_x(i)
        if mx >= bx and mx < bx + BTN_W then
          if entry.app then
            close_app(entry.app, entry.win)
          else
            close_terminal()
          end
          break
        end
      end
    end
  end

  mouse_prev  = mbtn
  mbtn1_prev  = mbtn1

  -- keyboard → focused app or main terminal
  local c = input.getchar()
  while c do
    if focused_app and focused_app.input then
      focused_app.input(c)
    elseif not focused_app and term_win then
      if c == "\n" then
        exec(input_line); input_line = ""
      elseif c == "\b" then
        if #input_line > 0 then input_line = input_line:sub(1,-2) end
      elseif c >= " " then
        if #input_line < COLS - 4 then input_line = input_line..c end
      end
    end
    c = input.getchar()
  end

  for _, a in ipairs(app_list) do
    if a.update then a.update() end
  end
end

-- ── Main draw ─────────────────────────────────────────────────────────────────
function _draw()
  gfx.cls(1)

  -- icons
  local hx, hy = mouse.x(), mouse.y()
  for _, ic in ipairs(icons) do
    local hover   = hx >= ic.x and hx < ic.x+ICON_W and hy >= ic.y and hy < ic.y+ICON_H
    local flashing = icon_flash[ic.label] and icon_flash[ic.label] > 0
    local bg_col  = flashing and 7 or (hover and (ic.col + 1) or ic.col)
    gfx.rect(ic.x, ic.y, ICON_W, ICON_H, bg_col)
    if hover or flashing then
      gfx.rect(ic.x,              ic.y,              ICON_W, 1, 7)
      gfx.rect(ic.x,              ic.y+ICON_H-1,     ICON_W, 1, 7)
      gfx.rect(ic.x,              ic.y,              1, ICON_H, 7)
      gfx.rect(ic.x+ICON_W-1,    ic.y,              1, ICON_H, 7)
    end
    gfx.rect(ic.x + ICON_W//2 - 1, ic.y + 4,         3, ICON_H - 8, flashing and 1 or 7)
    gfx.rect(ic.x + 4,             ic.y + ICON_H//2 - 1, ICON_W - 8, 3, flashing and 1 or 7)
    gfx.print(ic.label, ic.x, ic.y + ICON_H + 2, 7)
  end

  -- main terminal window (may have been closed)
  if term_win then
    wm.focus(term_win)
    gfx.cls(COL_BG)
    local _, _, tw, th = wm.rect(term_win)
    local cols = math.floor(tw / CW)
    local rows = math.floor(th / CH)
    local start = math.max(1, #lines - (rows - 2))
    for i = start, #lines do
      gfx.print(lines[i].text, 0, (i - start)*CH, lines[i].col)
    end
    local py = (rows-1)*CH
    local prompt = (cwd=="/" and "/" or cwd:match("[^/]+$").."/").."> "
    gfx.print(prompt..input_line, 0, py, COL_PROMPT)
    if focused_app == nil and (math.floor(pit_ticks()/30) % 2) == 0 then
      gfx.rect((#prompt + #input_line)*CW, py, 2, CH-1, COL_FG)
    end
    wm.unfocus()
  end

  -- app windows
  for _, a in ipairs(app_list) do
    if a.draw then a.draw() end
  end

  -- composite
  wm.present()

  -- taskbar (drawn after present so it's on top)
  local tb_y = SCREEN_H - TB_H
  gfx.rect(0, tb_y, SCREEN_W, TB_H, 2)
  gfx.rect(0, tb_y, SCREEN_W, 1, 9)

  local all = build_all_wins()
  for i, entry in ipairs(all) do
    local bx = taskbar_btn_x(i)
    local is_focused   = (focused_app == entry.app)
    local is_minimized = wm.is_minimized(entry.win)
    local is_maximized = win_saved[entry.win] ~= nil
    local btn_col = is_focused and 5 or (is_minimized and 2 or 3)
    gfx.rect(bx, tb_y + 3, BTN_W, TB_H - 5, btn_col)
    local label = entry.name .. (is_maximized and " ^" or "")
    gfx.print(label, bx + 4, tb_y + 6, is_minimized and 8 or 7)
  end

  -- cursor drawn last so it's always on top
  wm.draw_cursor()
end
