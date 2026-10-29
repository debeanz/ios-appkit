// Games on LuaJIT (LÖVE's engine, and others that embed it): its interpreter runs them; its
// compiler stays off. LuaJIT compiles hot Lua code to machine code and then maps that memory
// executable, which iOS refuses this app; LuaJIT takes the refusal as fatal and exits (its
// mcode_protfail), so the first loop a game runs often would end it. The interpreter is LuaJIT's
// own static arm64 code, the same that runs whenever its compiler isn't, so nothing is emulated.
//
// Every Lua state a game makes gets the compiler turned off as it is made (luaJIT_setmode), and
// the Lua-side jit.on is made to do nothing once the standard libraries are open; a game's own C
// calls asking for the compiler back are refused. Its FFI callbacks need machine code too and
// aren't covered (rare in games).
#import "AKShimPrivate.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>

typedef struct lua_State lua_State;
typedef void *(*ak_lua_Alloc)(void *ud, void *ptr, size_t osize, size_t nsize);
typedef int (*ak_lua_CFunction)(lua_State *L);

enum {
  kLuaGlobalsIndex = -10002,   // LUA_GLOBALSINDEX (Lua 5.1, LuaJIT's API)
  kLuaTypeTable = 5,           // LUA_TTABLE
  kLuaJITModeOn = 0x0100,      // LUAJIT_MODE_ON; LUAJIT_MODE_ENGINE | LUAJIT_MODE_OFF is 0
};

// The game's LuaJIT, found by what only LuaJIT exports: the newest game image that has it.
static void *luaJIT(const char *name) {
  for (uint32_t i = _dyld_image_count(); i-- > 0;) {
    const struct mach_header *h = _dyld_get_image_header(i);
    const char *path = _dyld_get_image_name(i);
    if (!h || !path || !AKHeaderIsGameImage(h)) continue;
    void *lib = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
    if (!lib) continue;
    void *sym = dlsym(lib, "luaJIT_setmode") ? dlsym(lib, name) : NULL;
    dlclose(lib);
    if (sym) return sym;
  }
  return NULL;
}

// Looked up at every call, never kept: the next game may bring its own LuaJIT.
static void compilerOff(lua_State *L) {
  static dispatch_once_t once;
  int (*setmode)(lua_State *, int, int) = (int (*)(lua_State *, int, int))luaJIT("luaJIT_setmode");
  if (!L || !setmode) return;
  setmode(L, 0, 0);
  dispatch_once(&once, ^{
    fprintf(stderr, "[AppKitShim] game: LuaJIT: its compiler is off (iOS won't run code made at run time); its interpreter runs the game\n");
  });
}

static lua_State *gameNewState(void) {
  lua_State *(*real)(void) = (lua_State *(*)(void))luaJIT("luaL_newstate");
  lua_State *L = real ? real() : NULL;
  compilerOff(L);
  return L;
}

static lua_State *gameLuaNewState(ak_lua_Alloc f, void *ud) {
  lua_State *(*real)(ak_lua_Alloc, void *) = (lua_State *(*)(ak_lua_Alloc, void *))luaJIT("lua_newstate");
  lua_State *L = real ? real(f, ud) : NULL;
  compilerOff(L);
  return L;
}

static int jitOnRefused(lua_State *L) { return 0; }

// The standard libraries open, among them the jit module: jit.on becomes a no-op.
static void gameOpenLibs(lua_State *L) {
  void (*real)(lua_State *) = (void (*)(lua_State *))luaJIT("luaL_openlibs");
  if (real) real(L);
  void (*getfield)(lua_State *, int, const char *) = (void (*)(lua_State *, int, const char *))luaJIT("lua_getfield");
  void (*setfield)(lua_State *, int, const char *) = (void (*)(lua_State *, int, const char *))luaJIT("lua_setfield");
  int (*type)(lua_State *, int) = (int (*)(lua_State *, int))luaJIT("lua_type");
  void (*pushclosure)(lua_State *, ak_lua_CFunction, int) = (void (*)(lua_State *, ak_lua_CFunction, int))luaJIT("lua_pushcclosure");
  void (*settop)(lua_State *, int) = (void (*)(lua_State *, int))luaJIT("lua_settop");
  if (!L || !getfield || !setfield || !type || !pushclosure || !settop) return;
  getfield(L, kLuaGlobalsIndex, "jit");
  if (type(L, -1) == kLuaTypeTable) {
    pushclosure(L, jitOnRefused, 0);
    setfield(L, -2, "on");
  }
  settop(L, -2);   // the jit table (or nil) off the stack
}

static int gameSetMode(lua_State *L, int idx, int mode) {
  int (*real)(lua_State *, int, int) = (int (*)(lua_State *, int, int))luaJIT("luaJIT_setmode");
  if (mode & kLuaJITModeOn) {
    fprintf(stderr, "[AppKitShim] game: LuaJIT: the game asked for its compiler (mode 0x%x); it stays off\n", mode);
    return 1;
  }
  return real ? real(L, idx, mode) : 0;
}

void AKGameBindLuaJIT(const struct mach_header *header, intptr_t slide) {
  AKRebindImports(header, slide, ^void *(const char *symbol) {
    if (strcmp(symbol, "_luaL_newstate") == 0) return (void *)gameNewState;
    if (strcmp(symbol, "_lua_newstate") == 0) return (void *)gameLuaNewState;
    if (strcmp(symbol, "_luaL_openlibs") == 0) return (void *)gameOpenLibs;
    if (strcmp(symbol, "_luaJIT_setmode") == 0) return (void *)gameSetMode;
    return NULL;
  });
}
