# momOS Full Lua API Reference

## Screen & Coordinates

- Screen: 640×480, 32-bit color mapped through a 32-entry palette
- All window drawing is in window-local coords (0,0 = top-left of content area)
- `SCREEN_W`, `SCREEN_H` globals available (640, 480)

## gfx — Graphics API

```lua
gfx.cls(color)
```
Clear the current window to `color` (palette index 0–31).

```lua
gfx.pset(x, y, color)
```
Draw a single pixel at `x,y`.

```lua
gfx.pget(x, y) → number
```
Read the palette index of the pixel at `x,y`.

```lua
gfx.rect(x, y, w, h, color)
```
Draw a solid filled rectangle. Width and height in pixels.

```lua
gfx.rectb(x, y, w, h, color)
```
Draw a hollow rectangle (border only, 1px thick).

```lua
gfx.line(x0, y0, x1, y1, color)
```
Draw a Bresenham line from `(x0,y0)` to `(x1,y1)`.

```lua
gfx.circ(cx, cy, r, color)
```
Draw a circle outline with centre `cx,cy` and radius `r`.

```lua
gfx.circfill(cx, cy, r, color)
```
Draw a filled circle.

```lua
gfx.print(text, x, y, color)
```
Draw `text` at `x,y` in `color`. Uses built-in 8×8 monospace font. No automatic wrapping. Returns nothing.

```lua
gfx.set_pal(idx, r, g, b)
```
Set palette entry `idx` (0–31) to the RGB color `r,g,b` (0–255 each). Changes take effect immediately for all pixels using that index.

```lua
gfx.get_pal(idx) → r, g, b
```
Read current palette entry `idx`. Returns three integers 0–255.

## wm — Window Manager API

```lua
wm.open(title, x, y, w, h) → win
```
Create a new window. `x,y` is screen position of content top-left. `w,h` is content size. The title bar (16px) and border (1px) are added automatically. Returns a window handle or nil on failure.

```lua
wm.close(win)
```
Destroy window and free its pixel buffer.

```lua
wm.focus(win)
```
Direct all subsequent `gfx.*` calls to this window. Must be called at the start of every `draw()`.

```lua
wm.unfocus()
```
End window-scoped drawing. Must be called at the end of every `draw()`.

```lua
wm.raise(win)
```
Bring window to the top of the z-order.

```lua
wm.set_focused(win)
```
Give keyboard focus to this window (affects which process receives input).

```lua
wm.is_minimized(win) → bool
```

```lua
wm.minimize(win, bool)
```
Set minimized state. `true` = hide, `false` = restore.

```lua
wm.rect(win) → x, y, w, h
```
Get current content area position and size.

```lua
wm.resize(win, w, h)
```
Resize content area. Resets the pixel buffer.

```lua
wm.set_title(win, title)
```
Update the title bar string.

## fs — Filesystem API

All paths are absolute UNIX-style from `/`. The VFS is in-memory; write to disk with `sys.save()`.

```lua
fs.read(path) → string or nil
```
Read entire file contents as a binary-safe Lua string. Returns nil if not found.

```lua
fs.write(path, data) → bool
```
Write `data` (string, may contain null bytes) to `path`. Creates or overwrites. Returns true on success.

```lua
fs.list(path) → array or nil
```
List directory. Returns array of `{name:string, is_dir:bool, size:number}` or nil if not a directory.

```lua
fs.mkdir(path) → bool
```
Create directory (and any missing parents). Returns true on success.

```lua
fs.delete(path) → bool
```
Delete file or empty directory.

```lua
fs.exists(path) → bool
```
Check if path exists (file or directory).

## input — Keyboard API

```lua
input.key_down(name) → bool
```
Returns true if the named key is currently held. Key names (case-insensitive):
`"up"`, `"down"`, `"left"`, `"right"`, `"enter"`, `"backspace"`, `"escape"`, `"space"`, `"tab"`, `"a"`–`"z"`, `"0"`–`"9"`, `"f1"`–`"f12"`.

```lua
input.getchar() → string or nil
```
Non-blocking. Returns a single-character string for the next queued keypress, or nil if the queue is empty. Arrow keys return `\x01`–`\x04`.

**Character codes:**
| Key | Code |
|-----|------|
| Up arrow | `\x01` |
| Down arrow | `\x02` |
| Left arrow | `\x03` |
| Right arrow | `\x04` |
| Escape | `\x1b` |
| Backspace | `\x08` |
| Enter | `\n` |
| Space | `" "` |

## mouse — Mouse API

```lua
mouse.x() → number
mouse.y() → number
```
Current cursor position in screen coordinates.

```lua
mouse.btn(n) → bool
```
Button state: `n=0` left button, `n=1` right button. True while held.

To convert to window-local coordinates:
```lua
local wx, wy = wm.rect(win)
local lx, ly = mouse.x() - wx, mouse.y() - wy
local in_window = lx >= 0 and ly >= 0 and lx < WIN_W and ly < WIN_H
```

## audio — Audio API

```lua
audio.play_note(ch, freq, vol, wave)
```
Play a tone on channel `ch` (0–3). `freq` in Hz, `vol` 0–255, `wave`: 0=square, 1=sine, 2=triangle, 3=noise.

```lua
audio.stop(ch)
```
Stop channel `ch`.

```lua
audio.play_msm(path)
```
Load and play a `.msm` tracker file from the VFS.

```lua
audio.stop_msm()
```
Stop tracker playback.

## sys — System API

```lua
sys.ticks() → number
```
Uptime in PIT ticks (~60 per second).

```lua
sys.mem() → number
```
Free heap bytes.

```lua
sys.save() → bool, errmsg
```
Snapshot in-memory VFS to the LFS partition on disk. Returns true on success, or false + error string.

```lua
sys.load() → bool, errmsg
```
Reload VFS from disk (replaces current in-memory state).

```lua
sys.shutdown()
```
Power off via ACPI. Does not return.

```lua
sys.reboot()
```
Warm restart via keyboard controller reset. Does not return.

```lua
sys.spawn(path)  -- alias: launch(path)
```
Spawn a new Lua app from `path`.

```lua
sys.kill(pid)
```
Kill process by PID.

```lua
sys.ps() → array
```
List running processes: `{pid, name}` entries.

```lua
sys.disk_ready() → bool
```
True if an ATA disk with an LFS partition is detected.

## ipc — Inter-Process Communication

```lua
ipc.open(name)
```
Register a named message queue for this process. Call once on app startup with a unique name.

```lua
ipc.send(name, data)
```
Send `data` (any Lua value) to the process registered as `name`. Delivered via `_msg` callback.

To receive messages, add a `_msg` function to your returned app table:
```lua
app._msg = function(from, data)
  -- from: sender name string
  -- data: value sent
end
```

## Global Helpers

```lua
launch(path)         -- spawn app (alias for sys.spawn)
app_launch(path)     -- same as launch
dofile(path)         -- load+run a Lua file from VFS, return its value
```

## Timing

```lua
local t = sys.ticks()     -- ~60 per second
```

Pattern for frame-rate-independent timers:
```lua
local timer = 0
local INTERVAL = 30  -- every 0.5s

function game._update()
  timer = timer + 1
  if timer >= INTERVAL then
    timer = 0
    -- do something
  end
end
```
