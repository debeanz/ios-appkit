// The Mac launcher's interface, for a client that has no launcher.
//
// steamui, steamclient and vgui2_s look these functions up by name — Valve's
// GetProcAddress(NULL, name), which on macOS is dlsym(RTLD_DEFAULT, name) — and on a Mac
// find them exported from steam_osx. iOS can't run steam_osx, so this library provides
// them; the host dlopens it RTLD_GLOBAL (so RTLD_DEFAULT reaches it even under
// LiveContainer, where the process's executable is LiveContainer) before any Steam library
// loads, since vgui2_s already asks during its own initialization.
//
// Behavior recovered from steam_osx's arm64 code with Ghidra: nearly every function asks
// the launcher's updater object, and with no updater returns a fixed default. Those
// defaults are what a client that must never update itself should hear — an update would
// replace the patched binaries with stock Mac ones — so they are returned here, except
// that beta switching is refused too.
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define LAUNCHER_API __attribute__((visibility("default"), used))

static char gInstallDir[1024];   // the client: steam_osx's own directory on a Mac
static char gLoggingDir[1024];
static char gBaseUserDir[1024];  // Steam's data root (~/Library/Application Support/Steam)
static char gRunOnExit[4096];

// Called by the host right after loading this library, before any Steam code runs.
LAUNCHER_API void SteamLauncher_Configure(const char *installDir, const char *loggingDir, const char *baseUserDir) {
  strlcpy(gInstallDir, installDir ? installDir : "", sizeof gInstallDir);
  strlcpy(gLoggingDir, loggingDir ? loggingDir : "", sizeof gLoggingDir);
  strlcpy(gBaseUserDir, baseUserDir ? baseUserDir : "", sizeof gBaseUserDir);
}

// What Steam asked to be relaunched with when it exits (an update, a restart); the host
// logs it, since relaunching isn't possible from inside the app.
LAUNCHER_API const char *SteamLauncher_CommandLineToRunOnExit(void) { return gRunOnExit; }

#pragma mark Paths and identity

LAUNCHER_API const char *SteamBootstrapper_GetInstallDir(void) { return gInstallDir; }
LAUNCHER_API const char *SteamBootstrapper_GetLoggingDir(void) { return gLoggingDir; }
LAUNCHER_API const char *SteamBootstrapper_GetBaseUserDir(void) { return gBaseUserDir; }
LAUNCHER_API int SteamBootstrapper_GetEUniverse(void) { return 1; }  // k_EUniversePublic
LAUNCHER_API int GetClientLauncherType(void) { return 0; }  // 7/8 are Steam China variants
LAUNCHER_API int GetClientActualLauncherType(void) { return 0; }
// steam_osx reads this from its manifest's "version" (or steam.cfg BootStrapperVersion=).
LAUNCHER_API uint64_t GetBootstrapperVersion(void) { return 1792618285ULL; }

// A second launcher passing its command line to the running one; there is never another.
LAUNCHER_API bool SteamBootstrapper_GetForwardedCommandLine(void (*callback)(void *, void *), void *context) {
  return false;
}
LAUNCHER_API void SteamBootstrapper_SetCommandLineToRunOnExit(const char *commandLine) {
  strlcpy(gRunOnExit, commandLine ? commandLine : "", sizeof gRunOnExit);
  fprintf(stderr, "[launcher] Steam asked to run on exit: %s\n", gRunOnExit);
}

#pragma mark Updates and betas: there are none

LAUNCHER_API const char *GetCurrentClientBeta(void) { return ""; }
LAUNCHER_API const char *GetStartupClientBeta(void) { return ""; }
LAUNCHER_API bool CanSetClientBeta(void) { return false; }
LAUNCHER_API void SetClientBeta(const char *beta) {}
LAUNCHER_API bool StartCheckingForUpdates(void *a, void *b) { return false; }
LAUNCHER_API bool IsCheckingForUpdates(void) { return false; }
LAUNCHER_API bool IsClientUpdateAvailable(void) { return false; }
LAUNCHER_API bool IsClientUpdateOutOfDiskSpace(void) { return false; }
LAUNCHER_API int GetClientUpdateBytesToDownload(void) { return 0; }
LAUNCHER_API int GetClientUpdateBytesDownloaded(void) { return 0; }
LAUNCHER_API void PermitDownloadClientUpdates(bool permit) {}
LAUNCHER_API void ForceUpdateNextRestart(void) {}
// steam_osx ticks its update UI and job queues here; there are none.
LAUNCHER_API void ClientUpdateRunFrame(void) {}
