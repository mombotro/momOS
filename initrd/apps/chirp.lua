-- chirp.lua — music tracker
local WIN_W, WIN_H = 480, 360
local win = wm.open("chirp", 60, 30, WIN_W, WIN_H)
if not win then return nil end

local CW, CH = 8, 8

-- ── Layout ────────────────────────────────────────────────────────────────────
local TB_H    = CH + 4    -- top toolbar
local SB_H    = CH + 4    -- status bar
local INST_W  = 80        -- right instrument panel
local SONG_H  = 44        -- song order strip at top of editor
local ROW_H   = CH + 1
local CHAN_W  = (WIN_W - INST_W) // 4   -- column width per channel
local ROWS_VIS = (WIN_H - TB_H - SB_H - SONG_H) // ROW_H
local ROWS_PER_PAT = 32

-- ── Song data ─────────────────────────────────────────────────────────────────
local BPM_DEFAULT    = 120
local TICKS_PER_ROW  = 6

local song = {
  bpm           = BPM_DEFAULT,
  ticks_per_row = TICKS_PER_ROW,
  pattern_count = 1,
  song_length   = 1,
  order         = {},   -- [1..64] = pattern index (1-based)
  patterns      = {},   -- [1..64][row][ch] = {note, inst, vol, fx}
  instruments   = {},   -- [1..16] = {wave, attack, decay, sustain, release, volume, vibrato, vibspeed}
}

local function default_inst()
  return { wave=0, attack=0, decay=0, sustain=255, release=10, volume=200, vibrato=0, vibspeed=4 }
end

local function make_pattern()
  local pat = {}
  for r = 1, ROWS_PER_PAT do
    pat[r] = {}
    for ch = 1, 4 do
      pat[r][ch] = { note=0, inst=0, vol=0, fx=0 }
    end
  end
  return pat
end

local function song_init()
  song.bpm = BPM_DEFAULT; song.ticks_per_row = TICKS_PER_ROW
  song.pattern_count = 1; song.song_length = 1
  song.order = {1}; for i=2,64 do song.order[i]=0 end
  song.patterns = { make_pattern() }
  song.instruments = {}
  for i=1,16 do song.instruments[i] = default_inst() end
end
song_init()

local NOTE_NAMES = {"C-","C#","D-","D#","E-","F-","F#","G-","G#","A-","A#","B-"}
local function note_str(n)
  if n == 0 then return "---" end
  local semi = (n - 1) % 12
  local oct  = (n - 1) // 12
  return NOTE_NAMES[semi+1]..oct
end

-- ── Playback state ────────────────────────────────────────────────────────────
local playing    = false
local play_order = 1    -- current position in song order
local play_row   = 1    -- current row in pattern
local tick_timer = 0    -- ticks until next row

-- Ticks per second = bpm * ticks_per_row / 60
-- At 60 Hz PIT: ticks_per_second = 60
local function ticks_per_row_frames()
  return math.max(1, math.floor(60 * song.ticks_per_row / (song.bpm * song.ticks_per_row / 60)))
end

local NOTE_FREQ = {}
-- Build frequency table: C-0 = 16.35 Hz
do
  local base = 16.35
  for n = 1, 96 do
    NOTE_FREQ[n] = math.floor(base * 2 ^ ((n-1)/12) + 0.5)
  end
end

local function play_row_audio(row_data)
  for ch = 0, 3 do
    local cell = row_data[ch+1]
    if cell.note > 0 then
      local inst = cell.inst > 0 and cell.inst or 1
      local ins  = song.instruments[inst] or default_inst()
      local freq = NOTE_FREQ[cell.note] or 440
      local vol  = cell.vol > 0 and cell.vol or ins.volume
      if audio then
        audio.set(ch, ins.wave, freq, vol)
      else
        -- PC speaker fallback (ch 0 only)
        if ch == 0 and audio then audio.beep(freq) end
      end
    elseif cell.note == 255 then  -- note-off
      if audio then audio.stop(ch) end
    end
  end
end

local function advance_play()
  if not playing then return end
  tick_timer = tick_timer - 1
  if tick_timer > 0 then return end
  tick_timer = ticks_per_row_frames()

  -- play current row
  local pat_idx = song.order[play_order] or 1
  local pat = song.patterns[pat_idx]
  if pat then
    play_row_audio(pat[play_row])
  end

  play_row = play_row + 1
  if play_row > ROWS_PER_PAT then
    play_row = 1
    play_order = play_order + 1
    if play_order > song.song_length then
      play_order = 1
    end
  end
end

local function stop_play()
  playing = false
  if audio then audio.stop_all() end
end

-- ── Editor state ──────────────────────────────────────────────────────────────
local cur_pat   = 1     -- pattern being edited
local cur_row   = 1     -- cursor row
local cur_ch    = 1     -- cursor channel (1-4)
local cur_field = 1     -- 1=note 2=inst 3=vol 4=fx
local cur_inst  = 1     -- selected instrument
local scroll    = 0     -- first visible row
local view_mode = "pattern"  -- "pattern", "song", "instrument"

local filepath  = nil; local modified = false
local status    = ""; local status_t = 0
local function set_status(s) status=s; status_t=90 end

-- ── Serialize ─────────────────────────────────────────────────────────────────
local function serialize()
  local parts = {}
  -- Header (32 bytes)
  parts[#parts+1] = "MSM1"
  parts[#parts+1] = string.char(song.bpm & 0xFF)
  parts[#parts+1] = string.char(song.ticks_per_row & 0xFF)
  parts[#parts+1] = string.char(song.pattern_count & 0xFF)
  parts[#parts+1] = string.char(song.song_length & 0xFF)
  parts[#parts+1] = string.rep("\0", 24)  -- reserved
  -- Instruments (16 × 16 = 256 bytes)
  for i = 1, 16 do
    local ins = song.instruments[i] or default_inst()
    parts[#parts+1] = string.char(ins.wave, ins.attack, ins.decay, ins.sustain,
                                   ins.release, ins.volume, ins.vibrato, ins.vibspeed,
                                   0,0,0,0,0,0,0,0)
  end
  -- Song order (64 bytes)
  for i = 1, 64 do
    parts[#parts+1] = string.char((song.order[i] or 0) & 0xFF)
  end
  -- Pattern data
  for p = 1, song.pattern_count do
    local pat = song.patterns[p] or make_pattern()
    for r = 1, ROWS_PER_PAT do
      for ch = 1, 4 do
        local cell = pat[r] and pat[r][ch] or {note=0,inst=0,vol=0,fx=0}
        parts[#parts+1] = string.char(cell.note & 0xFF, cell.inst & 0xFF,
                                       cell.vol & 0xFF, cell.fx & 0xFF)
      end
    end
  end
  return table.concat(parts)
end

local function deserialize(data)
  if #data < 32 then return false,"too short" end
  if data:sub(1,4) ~= "MSM1" then return false,"bad magic" end
  song.bpm           = data:byte(5)
  song.ticks_per_row = data:byte(6)
  song.pattern_count = data:byte(7)
  song.song_length   = data:byte(8)
  song.instruments = {}
  local pos = 33
  for i = 1, 16 do
    song.instruments[i] = {
      wave=data:byte(pos), attack=data:byte(pos+1), decay=data:byte(pos+2),
      sustain=data:byte(pos+3), release=data:byte(pos+4), volume=data:byte(pos+5),
      vibrato=data:byte(pos+6), vibspeed=data:byte(pos+7)
    }
    pos = pos + 16
  end
  -- order
  song.order = {}
  for i = 1, 64 do song.order[i] = data:byte(pos); pos=pos+1 end
  -- patterns
  song.patterns = {}
  for p = 1, song.pattern_count do
    local pat = make_pattern()
    for r = 1, ROWS_PER_PAT do
      for ch = 1, 4 do
        if pos + 3 <= #data then
          pat[r][ch] = { note=data:byte(pos), inst=data:byte(pos+1),
                         vol=data:byte(pos+2), fx=data:byte(pos+3) }
          pos = pos + 4
        end
      end
    end
    song.patterns[p] = pat
  end
  return true
end

local function cmd_save(path2)
  path2 = path2 or filepath
  if not path2 then set_status("no filename"); return end
  if not path2:match("%.%w+$") then path2=path2..".msm" end
  if fs.write(path2, serialize()) then
    filepath=path2; modified=false; set_status("saved "..path2)
  else set_status("write failed") end
end

local function cmd_open(path2)
  if not path2:match("%.%w+$") then path2=path2..".msm" end
  local data = fs.read(path2)
  if not data then set_status("not found: "..path2); return end
  local ok,err = deserialize(data)
  if not ok then set_status("error: "..tostring(err)); return end
  filepath=path2; modified=false; cur_pat=1; cur_row=1; scroll=0
  set_status("opened "..path2)
end

if _G.chirp_open_file then
  cmd_open(_G.chirp_open_file); _G.chirp_open_file=nil
end

-- ── Command mode ──────────────────────────────────────────────────────────────
local cmd_mode = false; local cmd_buf = ""

-- ── Draw ──────────────────────────────────────────────────────────────────────
local COL_BG     = 0
local COL_PANEL  = 2
local COL_FG     = 7
local COL_DIM    = 8
local COL_SEL    = 3
local COL_BORDER = 9
local COL_ACTIVE = 15
local COL_NOTE   = 11
local COL_INST   = 12
local COL_VOL    = 10
local COL_FX     = 4

local WAVE_NAMES = {"SQR","SAW","TRI","NSE"}
local EDITOR_W   = WIN_W - INST_W

local function draw_pattern_editor()
  -- Channel headers
  for ch = 1, 4 do
    local x = (ch-1)*CHAN_W
    local is_sel = (ch == cur_ch)
    gfx.rect(x, TB_H, CHAN_W-1, CH+2, is_sel and COL_SEL or COL_PANEL)
    gfx.print("CH"..ch, x+2, TB_H+1, is_sel and COL_ACTIVE or COL_DIM)
  end

  -- Rows
  local pat = song.patterns[cur_pat]
  for i = 0, ROWS_VIS-1 do
    local row = scroll + i + 1
    if row > ROWS_PER_PAT then break end
    local y = TB_H + (CH+2) + SONG_H + i*ROW_H

    -- row number
    local is_cur = (row == cur_row) and (view_mode == "pattern")
    local row_bg = is_cur and COL_SEL or (row % 4 == 1 and COL_PANEL or COL_BG)
    gfx.rect(0, y, EDITOR_W, ROW_H, row_bg)
    gfx.print(string.format("%02d", row-1), 0, y, row % 4 == 1 and 9 or COL_DIM)

    for ch = 1, 4 do
      local cx = (ch-1)*CHAN_W + CW*2 + 2
      local cell = pat and pat[row] and pat[row][ch] or {note=0,inst=0,vol=0,fx=0}

      -- highlight cursor cell
      if is_cur and ch == cur_ch then
        gfx.rect(cx - 2, y, CHAN_W - 3, ROW_H, 5)
      end

      -- note
      local ns = note_str(cell.note)
      gfx.print(ns, cx, y, cell.note>0 and COL_NOTE or COL_DIM)
      -- inst
      local is_str = cell.inst > 0 and string.format("%02d", cell.inst) or ".."
      gfx.print(is_str, cx + 4*CW, y, cell.inst>0 and COL_INST or COL_DIM)
      -- vol
      local vs = cell.vol > 0 and string.format("%02X", cell.vol) or ".."
      gfx.print(vs, cx + 7*CW, y, cell.vol>0 and COL_VOL or COL_DIM)
      -- fx
      local fs2 = cell.fx > 0 and string.format("%02X", cell.fx) or ".."
      gfx.print(fs2, cx + 10*CW, y, cell.fx>0 and COL_FX or COL_DIM)
    end
  end
end

local function draw_song_strip()
  local base_y = TB_H + (CH+2)
  gfx.rect(0, base_y, EDITOR_W, SONG_H, COL_PANEL)
  gfx.print("ORDER", 2, base_y+2, COL_DIM)
  for i = 1, math.min(song.song_length, 14) do
    local x = 2 + (i-1)*CW*3
    local is_cur = (i == (playing and play_order or 1))
    gfx.rect(x, base_y+CH+2, CW*2+2, CH+2, is_cur and COL_SEL or COL_BG)
    gfx.print(string.format("%02d", (song.order[i] or 1)-1), x+1, base_y+CH+3,
              is_cur and COL_ACTIVE or COL_FG)
  end
  -- BPM
  gfx.print(string.format("BPM:%d TPR:%d", song.bpm, song.ticks_per_row),
            2, base_y + SONG_H - CH - 2, COL_DIM)
end

local function draw_instrument_panel()
  local x0 = EDITOR_W
  gfx.rect(x0, TB_H, INST_W, WIN_H-TB_H, COL_PANEL)
  gfx.rect(x0, TB_H, 1, WIN_H-TB_H, COL_BORDER)
  gfx.print("INST", x0+2, TB_H+2, COL_DIM)

  -- Instrument list
  for i = 1, 16 do
    local y = TB_H + CH + 2 + (i-1)*CH
    local bg = i==cur_inst and COL_SEL or COL_BG
    gfx.rect(x0+2, y, INST_W-4, CH, bg)
    local ins = song.instruments[i] or default_inst()
    gfx.print(string.format("%02d%s", i, WAVE_NAMES[ins.wave+1] or "???"),
              x0+4, y, i==cur_inst and COL_ACTIVE or COL_FG)
  end

  -- Selected instrument details
  local ins = song.instruments[cur_inst] or default_inst()
  local dy = TB_H + CH + 2 + 16*CH + 4
  gfx.print("WAV:"..WAVE_NAMES[ins.wave+1], x0+2, dy, COL_FG); dy=dy+CH
  gfx.print("VOL:"..ins.volume,             x0+2, dy, COL_VOL); dy=dy+CH
  gfx.print("ATK:"..ins.attack,             x0+2, dy, COL_DIM); dy=dy+CH
  gfx.print("SUS:"..ins.sustain,            x0+2, dy, COL_DIM); dy=dy+CH
  gfx.print("REL:"..ins.release,            x0+2, dy, COL_DIM)
end

local function draw_toolbar()
  gfx.rect(0, 0, WIN_W, TB_H, COL_PANEL)
  local title = filepath and filepath:match("[^/]+$") or "untitled.msm"
  if modified then title="*"..title end
  gfx.print(title, 2, 2, COL_FG)
  local status_r = (playing and "> PLAY" or "  STOP").."  P"..string.format("%02d",cur_pat)
  gfx.print(status_r, WIN_W - INST_W - #status_r*CW - 4, 2, playing and 11 or COL_DIM)
end

local function draw_status_bar()
  local sy = WIN_H - SB_H
  gfx.rect(0, sy, WIN_W, SB_H, COL_PANEL)
  gfx.rect(0, sy, WIN_W, 1, COL_BORDER)
  if cmd_mode then
    gfx.print(":"..cmd_buf.."_", 2, sy+2, COL_ACTIVE)
  elseif status_t > 0 then
    gfx.print(status, 2, sy+2, COL_DIM)
  else
    gfx.print("ESC=cmd  SPC=play  tab=channel  ins/del=row  F1-F4=wave", 2, sy+2, COL_DIM)
  end
end

local function draw()
  wm.focus(win)
  gfx.cls(COL_BG)
  draw_song_strip()
  draw_pattern_editor()
  draw_instrument_panel()
  draw_toolbar()
  draw_status_bar()
  wm.unfocus()
end

-- ── Update ────────────────────────────────────────────────────────────────────
local prev_btn0 = false

local function update()
  if status_t > 0 then status_t=status_t-1 end
  if playing then advance_play() end
  -- refill audio DMA buffer if available
  if audio then audio.refill() end

  -- mouse click in instrument panel (select instrument)
  local mx,my = mouse.x(),mouse.y()
  local wx,wy = wm.rect(win)
  local lx,ly = mx-wx, my-wy
  local btn0  = mouse.btn(0)

  if btn0 and not prev_btn0 then
    if lx >= EDITOR_W then
      local rel_y = ly - TB_H - CH - 2
      if rel_y >= 0 then
        local idx = rel_y // CH + 1
        if idx >= 1 and idx <= 16 then cur_inst = idx end
      end
    end
  end
  prev_btn0 = btn0
end

-- ── Note entry keyboard map ──────────────────────────────────────────��────────
-- White keys: a s d f g h j k  → C D E F G A B C (octave)
-- Black keys: w e   t y u
local NOTE_KEYS = {
  a=1, w=2, s=3, e=4, d=5, f=6, t=7, g=8, y=9, h=10, u=11, j=12,  -- octave 4
  k=13, o=14, l=15, p=16, [";"]= 17,  -- next octave
}
local cur_octave = 4

local function enter_note(c)
  local base = NOTE_KEYS[c]
  if not base then return false end
  local note = (cur_octave - 1) * 12 + base
  note = math.max(1, math.min(96, note))
  local pat = song.patterns[cur_pat]
  if not pat then return false end
  pat[cur_row][cur_ch].note = note
  pat[cur_row][cur_ch].inst = pat[cur_row][cur_ch].inst > 0 and pat[cur_row][cur_ch].inst or cur_inst
  modified = true
  -- preview note
  local ins = song.instruments[cur_inst] or default_inst()
  if audio then audio.set(0, ins.wave, NOTE_FREQ[note] or 440, ins.volume) end
  -- advance cursor
  cur_row = math.min(cur_row + 1, ROWS_PER_PAT)
  if cur_row > scroll + ROWS_VIS then scroll = cur_row - ROWS_VIS end
  return true
end

local function on_input(c)
  if cmd_mode then
    if c == "\n" then
      local line = cmd_buf:match("^%s*(.-)%s*$"); cmd_mode=false; cmd_buf=""
      if line == "q" then stop_play(); wm.close(win); return "quit"
      elseif line == "wq" then cmd_save(); stop_play(); wm.close(win); return "quit"
      elseif line == "w" then cmd_save()
      elseif line:sub(1,2)=="w " then cmd_save(line:sub(3))
      elseif line:sub(1,2)=="o " then cmd_open(line:sub(3))
      elseif line:sub(1,4)=="bpm" then
        local v=tonumber(line:sub(5)); if v then song.bpm=math.max(1,math.min(255,math.floor(v))); modified=true end
      elseif line:sub(1,3)=="tpr" then
        local v=tonumber(line:sub(5)); if v then song.ticks_per_row=math.max(1,math.min(16,math.floor(v))); modified=true end
      end
    elseif c=="\x1b" then cmd_mode=false; cmd_buf=""
    elseif c=="\b" then if #cmd_buf>0 then cmd_buf=cmd_buf:sub(1,-2) end
    elseif c>=" " then cmd_buf=cmd_buf..c end
    return
  end

  if c=="\x1b" then cmd_mode=true; return end

  -- playback
  if c==" " then
    if playing then stop_play() else
      playing=true; play_order=1; play_row=1; tick_timer=1
      set_status("playing")
    end
    return
  end

  -- cursor movement
  if c=="\x01" then  -- up
    cur_row=math.max(1, cur_row-1)
    if cur_row < scroll+1 then scroll=cur_row-1 end
  elseif c=="\x02" then  -- down
    cur_row=math.min(ROWS_PER_PAT, cur_row+1)
    if cur_row > scroll+ROWS_VIS then scroll=cur_row-ROWS_VIS end
  elseif c=="\t" then  -- tab = next channel
    cur_ch = cur_ch % 4 + 1
  elseif c=="\x03" then  -- left = prev channel
    cur_ch = ((cur_ch-2) % 4) + 1
  elseif c=="\x04" then  -- right = next channel
    cur_ch = cur_ch % 4 + 1
  end

  -- delete note
  if c=="\x7f" or c=="\b" then
    local pat = song.patterns[cur_pat]
    if pat then pat[cur_row][cur_ch] = {note=0,inst=0,vol=0,fx=0}; modified=true end
    return
  end

  -- pattern navigation
  if c=="[" then cur_pat=math.max(1,cur_pat-1); cur_row=1; scroll=0
  elseif c=="]" then
    if cur_pat >= song.pattern_count and song.pattern_count < 64 then
      song.pattern_count=song.pattern_count+1
      song.patterns[song.pattern_count]=make_pattern(); modified=true
    end
    cur_pat=math.min(song.pattern_count, cur_pat+1); cur_row=1; scroll=0
  end

  -- octave
  if c==">" or c=="." then cur_octave=math.min(7, cur_octave+1)
  elseif c=="<" or c=="," then cur_octave=math.max(0, cur_octave-1) end

  -- instrument select (number keys)
  local n = tonumber(c)
  if n and n >= 1 and n <= 9 then cur_inst=n end

  -- wave preset for current instrument (F1-F4 are sent as special chars)
  -- Using 1-4 prefix shortcut instead: just change wave for cur_inst
  if c=="!" then song.instruments[cur_inst].wave=0; modified=true end  -- square
  if c=="@" then song.instruments[cur_inst].wave=1; modified=true end  -- saw
  if c=="#" then song.instruments[cur_inst].wave=2; modified=true end  -- tri
  if c=="$" then song.instruments[cur_inst].wave=3; modified=true end  -- noise

  -- note entry
  enter_note(c)
end

return { draw=draw, update=update, input=on_input, win=win, name="chirp" }
