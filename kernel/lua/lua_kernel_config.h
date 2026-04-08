/* Injected before every Lua source file via -include.
   Overrides macros that lauxlib.h defines conditionally. */

/* Redirect Lua print output to serial */
extern void serial_puts(const char *s);
extern void serial_putc(char c);

/* These are checked with #if !defined(...) in lauxlib.h, so defining
   them here prevents the stdio-based versions from being used. */
#define lua_writestring(s,l)    do { \
    const char *_s = (s); int _l = (int)(l); \
    for (int _i = 0; _i < _l; _i++) serial_putc(_s[_i]); } while(0)
#define lua_writeline()         serial_putc('\n')
#define lua_writestringerror(s,p) do { serial_puts(s); } while(0)

/* Always use '.' as decimal separator — avoids locale.h in luaconf.h */
#define lua_getlocaledecpoint() '.'
