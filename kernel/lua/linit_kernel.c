/* Kernel replacement for lua/linit.c
   Loads only the libs that make sense without OS/file I/O. */

#define linit_c
#define LUA_LIB

#include "../lua/lprefix.h"
#include <stddef.h>
#include "../lua/lua.h"
#include "../lua/lualib.h"
#include "../lua/lauxlib.h"

static const luaL_Reg kernel_libs[] = {
    {LUA_GNAME,      luaopen_base},
    {LUA_COLIBNAME,  luaopen_coroutine},
    {LUA_TABLIBNAME, luaopen_table},
    {LUA_STRLIBNAME, luaopen_string},
    {LUA_MATHLIBNAME,luaopen_math},
    {LUA_UTF8LIBNAME,luaopen_utf8},
    {NULL, NULL}
};

LUALIB_API void luaL_openlibs(lua_State *L) {
    const luaL_Reg *lib;
    for (lib = kernel_libs; lib->func; lib++) {
        luaL_requiref(L, lib->name, lib->func, 1);
        lua_pop(L, 1);
    }
}
