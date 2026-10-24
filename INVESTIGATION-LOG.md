# Investigation log — getting CaptureAge (Windows build) running under Proton

Date: 2026-10-23/24 · Host: Ubuntu 24.04.5 LTS, X11 session on `DISPLAY=:1` (mutter compositor)
· Steam: `~/.local/share/Steam`, tools `Proton Hotfix` (Proton 11.0-100) + `SteamLinuxRuntime_4`

This is a lab notebook written so another agent (or a future me) can re-run every step, inspect
the same evidence, and understand why the final script looks the way it does. Every command below
was actually run. Where something is an inference rather than an observation, it says so.

Final artifacts:

* `capture-age.sh` — install + launch script (tested end-to-end from a clean prefix)
* `NOTES-option3-manual-payload.md` — dissection of the installer and the "unpack the payload
  yourself" alternative
* this file — step-by-step log, evidence, dead ends, verification recipes

Reading order for another agent: §1–§3 explain the binary and the payload, §4–§5 recreate the
install, §6–§9 are the Wine-addon debugging story, §10–§12 are the environment fixes and the
final script, §13–§15 are the summary/traps/verification recipes, and the appendices contain
copy-pasteable inspection snippets.

State left on this machine after the investigation:

| Path | What |
|---|---|
| `~/.local/share/capture-age/` | dedicated prefix (`pfx/`, 1.1 GB), installed CaptureAge 1.26.0 |
| `~/.local/share/capture-age/pfx/drive_c/users/steamuser/AppData/Local/Programs/CaptureAge/` | app tree, 406 MB |
| `~/.cache/capture-age/CaptureAge-latest-x64.nsis.7z` | 147 MB payload downloaded during research (option-3 material) |
| `~/.local/share/Steam/steamapps/compatdata/813780/...` | AoE2 DE prefix (untouched, game was running) |

---

## 0. Baseline: use the running Windows game as reference

The user said a Windows game was already running. It was:

```
$ ps aux | grep -i 266840 | head
... steam-launch-wrapper -- reaper SteamLaunch AppId=813780 -- \
    .../SteamLinuxRuntime_4/_v2-entry-point --verb=waitforexitandrun -- \
    .../'Proton Hotfix'/proton waitforexitandrun .../AoE2DE/AoE2DE_s.exe
```

From `/proc/<gamepid>/environ` the important reference variables were:

```
DISPLAY=:1
STEAM_COMPAT_CLIENT_INSTALL_PATH=~/.local/share/Steam
STEAM_COMPAT_DATA_PATH=~/.local/share/Steam/steamapps/compatdata/813780
STEAM_COMPAT_INSTALL_PATH=~/.local/share/Steam/steamapps/common/AoE2DE
STEAM_COMPAT_LIBRARY_PATHS=~/.local/share/Steam/steamapps
XDG_SESSION_TYPE=x11
```

Other useful facts:

* `~/.local/share/Steam/steamapps/compatdata/813780/pfx/dosdevices/s: -> ~/.local/share/Steam`
  — Steam/Proton gives each game an `S:` drive pointing at its library root.
* Prefix user is `steamuser`; `C:\users\steamuser\Games\Age of Empires 2 DE\<steamid>` is where
  AoE2 DE stores replays/mods.
* Only Proton version installed: `Proton Hotfix` (prefix upgrade message says `11.0-100`).
* CPU has `avx2 fma bmi1 bmi2 movbe fsgsbase`, no `avx512` (relevant later when judging
  whether an addon crash could be an instruction-set issue).

**Rule followed throughout:** never run `wineserver -k` without setting `WINEPREFIX` to *our* new
prefix; the AoE2 session has its own wineserver and must not be touched.

---

## 1. Identify the binary

```bash
$ file CaptureAgeSetup.exe
PE32 executable (GUI) Intel 80386, for MS Windows, Nullsoft Installer self-extracting archive, 5 sections
$ md5sum CaptureAgeSetup.exe
2027dede643612cd9137e33c31341911
```

PE parse (hand-rolled with `struct`, see §D):

```
sections 5, file 0x106858 (1,075,288 bytes)
.text va=0x1000  rsz=0x6800  off=0x400
.rdata            rsz=0x1600  off=0x6c00
.data             rsz=0x600   off=0x8200
.ndata            rsz=0
.rsrc  va=0x1bf000 rsz=0x50600 off=0x8800   -> ends at 0x58e00
cert table (PE dir #4) off=0x103978 size=0x2ee0
```

So the file has ~711 KB of NSIS overlay between `0x58e00` and the authenticode blob.
`strings` shows `NSIS Error`, `http://nsis.sf.net/NSIS_Error`, version resource
`CaptureAge for Age of Empires II: Definitive Edition`, `Copyright (c) 2020 CaptureAge`,
manifest `Nullsoft Install System v3.04`, signed by *CaptureAge BV*.

Conclusion: 32-bit NSIS 3.04 installer stub. Not the app.

---

## 2. Prove the app is not inside the installer

The NSIS overlay is zlib-compressed, so `strings` over it yields garbage. Layout:

```
0x058e00  u32 flags            = 0        (NSIS: 0 => zlib/deflate, 1 => bzip2, 2 => lzma)
0x058e04  sig                  = EF BE AD DE "NullsoftInst"
0x058e14  u32 header length    = 0x20966  (133,478 bytes uncompressed)
0x058e18  u32 following data   = 0xaab75  (698,741 bytes, header included)
0x058e1c  header stream        = u32 size prefix + raw deflate (zlib wbits=-15)
0x058e20  inflated header      -> 133,478 bytes of NSIS bytecode + UTF-16 strings
0x060a30  data section         = u32 size prefix + raw deflate, 10 streams
0x103978  authenticode table   (0x2ee0)
```

Decompress the header and read it as UTF-16LE:

```python
import zlib
d = open('CaptureAgeSetup.exe','rb').read()
h = zlib.decompressobj(-15).decompress(d[0x58e20:])
print('\n'.join(p for p in h.decode('utf-16le','replace').split('\0') if len(p) >= 6 and p.isprintable()))
```

The script strings are the smoking gun:

```
package-file      CaptureAge-1.16.1-x64.nsis.7z
https://captureage.com/api/cade/download/prod/latest
SHA2-512  F4A8512C42BE91D4AF5DCEABE40221A2008C4644ACD7C0CF1591589425CAFDDC
          F8F3A500E67B3F5A19332E8FBCB5E7F1739FEBFECF7B36C0E62C2DD8370C21D
Window 7 / 64-bit checks, IsWow64Process2
Software\Classes\.caderec, "Open with CaptureAge"
HKCU\Software\66a3e6fd-4cd4-454e-9ee9-6818fcbd13a6, InstallLocation
--installer, --installer --updated, --installer --no-download
inetc::get /END /RESUME /HEADER /USERAGENT /NOPROXY (downloader plugin)
electron-builder (Mozilla)          (the NSIS template's UA string)
```

Then decompress the data section (streams are back-to-back, each with a 4-byte size prefix):

```
0x60a30  12,288    MZ (plugin)
0x62547 102,400    MZ
0x6d773 101,376    MZ
0x79dca  12,698    <html …Terms and Conditions…>
0x7ad2a   9,216    MZ
0x7bf35   6,656    MZ
0x7cc1c 244,224    MZ  (contains "inetc")
0x9b5e5 434,176    MZ
0xd68b7 455,112    MZ
0x103535  3,072    MZ
total 1,381,218 bytes
```

~1.4 MB of installer plugins + a license page. **There is no application payload.** Conclusion:
this exe is a *web installer*; running it launches an installer that downloads ~150 MB, then
extracts it with the Nsis7z plugin. This is what the user suspected.

---

## 3. Probe the download API (so the script knows what "install" means)

```bash
curl -sI https://captureage.com/api/cade/download/prod/latest
# 302, Location: https://captureage.azureedge.net/cade/prod/CaptureAge-1.26.0-x64.nsis.7z?sv=…&se=…&sig=…
```

| Probe | Result |
|---|---|
| `…/prod/latest` | 302 → `CaptureAge-1.26.0-x64.nsis.7z` (147,260,820 bytes, Last-Modified 2026-09-22) |
| `…/prod/CaptureAge-1.26.0-x64.nsis.7z` | 302 → same blob (versions are pinnable) |
| `…/prod/CaptureAge-1.16.1-x64.nsis.7z` | 302 → old blob still hosted |
| `…/prod/CaptureAgeSetup.exe` | 302 → CDN stub, **md5-identical to the local 1.16.1 stub** |
| `…/prod/<anything else>` | 404 with 14-byte JSON body |

Payload SHA-512 (computed locally on the 147 MB download):

```
7B1C6A1F050B39F31CA7300F2378F6E1F1DE8B897AA73796FF9D7FCBE67DB61FE0E897E73A39F0313AF5F4180439C3C81A5DF57A3D5D459D50178681CA6A9476
```

Note this does **not** match the digest embedded in the 1.16.1 stub (`F4A8…`) yet the silent
install succeeded — so on this path the vendor's hash is not enforced (or is compared against
something else). Conclusions and extraction details are in
`NOTES-option3-manual-payload.md`.

---

## 4. Build the Proton invocation and smoke-test a prefix

The script mirrors the game's chain, but with a *dedicated* data dir:

```bash
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$HOME/.local/share/Steam"
export STEAM_COMPAT_DATA_PATH="$HOME/.local/share/capture-age"    # prefix will be …/capture-age/pfx

"$HOME/.local/share/Steam/steamapps/common/SteamLinuxRuntime_4/_v2-entry-point" \
  --verb=waitforexitandrun -- \
  "$HOME/.local/share/Steam/steamapps/common/Proton Hotfix/proton" run \
  cmd /c "echo hello"
```

Output:

```
Proton: Upgrading prefix from None to 11.0-100 (~/.local/share/capture-age/)
fsync: up and running.
```

`STEAM_COMPAT_DATA_PATH` points at the *compatdata* directory; Proton creates `pfx/` inside it.

---

## 5. Silent install (option 2, since option 3 was postponed)

```bash
WINEDEBUG=-all "$SLR/_v2-entry-point" --verb=waitforexitandrun -- \
  "$PROTON/proton" run ./CaptureAgeSetup.exe /S
```

`/S` is electron-builder's NSIS silent switch. Result: `/S` install worked, no UAC (per-user
install under `%LOCALAPPDATA%\Programs`), installed **1.26.0** (not 1.16.1), including:

* `CaptureAge.exe` (227,046,176 bytes)
* `resources/app/` (~42 MB, `electronMain.js` + hash-named asset files + `fx/*.fxc`)
* `resources/app-update.yml`, `resources/VC_redist.x64.exe`, `resources/elevate.exe`
* `Uninstall CaptureAge.exe`
* VC++ 2015-2019 14.28 redist installed into the prefix (`redistributables_installed*.log`)
* registry keys + `.caderec` association, Start Menu shortcut

Verification of the registry side (`pfx/user.reg`):

```
[Software\\66a3e6fd-4cd4-454e-9ee9-6818fcbd13a6]
"InstallLocation"="C:\\users\\steamuser\\AppData\\Local\\Programs\\CaptureAge"
[Software\\Classes\\.caderec]            -> "Open with CaptureAge"
[Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\66a3e6fd-…]
"DisplayName"="CaptureAge 1.16.1"
"DisplayVersion"="1.16.1"
```

Note the mismatch: the installed app is **1.26.0** (`resources/app/package.json`), but the
uninstall entry says 1.16.1 because that string comes from the stale installer stub. Another
confirmation that the vendor's stub was not rebuilt when the app moved on.

A stray `wine client error:140: write: Bad file descriptor` shows up when the installer's stdout
pipe is closed early (e.g. piped into `tail`); harmless.

Install dir: `pfx/drive_c/users/steamuser/AppData/Local/Programs/CaptureAge/`.

---

## 6. First launch fails — and how to read a window you cannot screenshot

Launching `CaptureAge.exe` produced a modal **Error** dialog, but the window was hidden behind the
fullscreen AoE2 window, so `ffmpeg -f x11grab` captured the game instead. Two tools solved this:

1. Attribute the window to a process:

   ```bash
   DISPLAY=:1 xwininfo -root -children | grep -i '"error"'
   DISPLAY=:1 xprop -id 0xbc00005 _NET_WM_PID WM_NAME
   # _NET_WM_PID = 55594 -> the CaptureAge.exe process
   ```

2. Read the *window's own* pixels via XComposite (mutter redirects windows to offscreen pixmaps,
   so the content exists even when occluded). `import`/`scrot`/`xwdtopnm` were not installed, so
   it was done with `ctypes` + Pillow — see §D for the reusable snippet. Result:

```
Error
A JavaScript error occurred in the main process
Uncaught Exception:
Error: No access to memory location.
\\?\C:\users\steamuser\AppData\Local\Programs\CaptureAge\…
  at process.func [as dlopen] (node:electron/js2c/node_init:2:2625)
  at Module._extensions..node (node:internal/modules/cjs/loader:1998:18)
  …
```

So a native `.node` addon failed to load, with Win32 error **998 = ERROR_NOACCESS**.

---

## 7. Trace the DLL load

```bash
WINEDEBUG=-all,+loaddll,+module "$SLR/_v2-entry-point" --verb=waitforexitandrun -- \
  "$PROTON/proton" run "$EXE" 2>&1 | rg 'cade|Initialization|RETURN 0'
```

Evidence:

```
trace:module:load_dll looking for L"\\?\C:\…\resources\app\cade.node" …
trace:module:map_image_into_view mapping … at 0x6ffffb8c0000-0x6ffffc7bd000
trace:module:build_module loaded L"…\cade.node" 0000000000971560 00006FFFFB8C0000
trace:module:MODULE_InitDLL (00006FFFFB8C0000 L"cade.node",PROCESS_ATTACH,…) - CALL
trace:module:MODULE_InitDLL (00006FFFFB8C0000,PROCESS_ATTACH,…) - RETURN 0
trace:module:process_attach (L"cade.node",…) - START
warn:module:process_attach Initialization of L"cade.node" failed
```

So: the file mapped and relocated fine; **DllMain returned FALSE**. That is a bug/refusal inside
the addon, not a missing DLL (`dbghelp`, `d3d11`, `d2d1`, `msvcp140`, … all loaded first).

`cade.node` facts: 15,642,400 bytes, PE32+ x64 DLL, 7 sections, entry RVA `0x8b7584`,
imports `ADVAPI32, IPHLPAPI, WSOCK32, WS2_32, dxgi, d3d11, d2d1, dbghelp, KERNEL32, USER32,
ole32, MSVCP140, CONCRT140, bcrypt, VCRUNTIME140(_1), api-ms-win-crt-*, CRYPT32, D3DCOMPILER_47`.
DLL characteristics `0x160` (ASLR + high-entropy, no CFG/CET). Authenticode table present.
Entry disassembly is the stock MSVC `_DllMainCRTStartup`:

```
call __security_init_cookie        (RVA 0x8b7c34)
jmp  dllmain_dispatch              (RVA 0x8b745c)
  -> _CRT_INIT (RVA 0x8b7270)
       -> _initterm_e / _initterm  (static initialisers)
```

---

## 8. Relay tracing (with two filter bugs worth knowing about)

`+relay` output is enormous (a 20 s run produced **1.6 GB** and 12 M call lines), so it must be
filtered *upstream*. Two mistakes cost time and are documented so nobody repeats them:

1. Filtering by thread id (`^0140:Call`) — Wine's debug log prints only the TID, and two processes
   in the same session had TID `0140`, so the filter mixed unrelated output. Also the TID differs
   between runs.
2. Filtering `ret=` with `{16}` hex digits — Wine prints addresses with *variable* digits
   (`ret=6ffffc177c69`). And the module base must be parsed from the **last** hex token of the
   `build_module loaded … <checksum> <base>` line, not the first (the first is the checksum,
   e.g. `0000000000971560`, which yields a nonsense range).

Working filter: remember the base when `cade.node`/`build_module loaded` is seen, then keep any
line whose `ret=` falls in `[base, base+0x1000000]` (the DLL is 15 MB, so a 0x300000 window is too
small — that was bug #3). With that, the tail of the addon's init is:

```
Call ucrtbase._initialize_onexit_table(…)        ret=…c176b93
Call ucrtbase._initterm_e(…)                     ret=…c17733a
Call ucrtbase._initterm(…)                       ret=…c17735a
Call ucrtbase.malloc(0x70)                       ret=…c17682b
…
Call ucrtbase._seh_filter_dll(c0000005, …)       ret=…c19d1ef
warn:module:process_attach Initialization of L"cade.node" failed
```

`_seh_filter_dll(c0000005, …)` proves an **access violation happened during C++ static
initialisation**, and that it was swallowed by the CRT → DllMain returns FALSE.

(Note: my first relay runs reported *zero* calls from the DLL. That was the filter bugs above, not
the addon — worth repeating because "no calls at all" looks like a totally different failure.)

---

## 9. Pinpoint the faulting instruction and fix it

```bash
WINEDEBUG=-all,+seh "$SLR/_v2-entry-point" --verb=waitforexitandrun -- \
  "$PROTON/proton" run "$EXE"
```

```
warn:seh:dispatch_exception backtrace: --- Exception 0xc0000005.
trace:seh:dispatch_exception code=c0000005 (EXCEPTION_ACCESS_VIOLATION) flags=0 addr=00006FFFFAC52EB0
trace:seh:dispatch_exception  info[0]=0000000000000000      (read)
trace:seh:dispatch_exception  info[1]=0000000000000000      (address 0)
warn:seh:virtual_unwind backtrace: 00006FFFFAC52EB0: L"MSVCP140.dll" + 0x12EB0
warn:seh:virtual_unwind backtrace: 00006FFFFBA75D8C: L"cade.node" + 0x1B5D8C
warn:seh:virtual_unwind backtrace: 00006FFFFBA968F5: L"cade.node" + 0x1D68F5
warn:seh:virtual_unwind backtrace: 00006FFFFBA83847: L"cade.node" + 0x1C3847
warn:seh:virtual_unwind backtrace: 00006FFFFBA83461: L"cade.node" + 0x1C3461
warn:seh:virtual_unwind backtrace: 00006FFFFF9DBECA: L"ucrtbase.dll" + 0x2BECA   (_initterm)
warn:seh:virtual_unwind backtrace: 00006FFFFC17735A: L"cade.node" + 0x8B735A     (_CRT_INIT)
```

So a static initialiser calls into **Microsoft's `MSVCP140.dll` (14.28, installed by the bundled
VC redist)**, which dereferences NULL. The mixing that breaks it is: Microsoft's native MSVCP140 +
Wine's builtin `ucrtbase`. Loading Wine's builtins for the C++ runtime instead makes the pair
consistent:

```bash
WINEDLLOVERRIDES="msvcp140=b;vcruntime140=b;vcruntime140_1=b;concrt140=b"
```

Result: the addon loads, Electron starts, and a full-screen "CaptureAge" window appears.
(This is now a permanent part of the launcher.)

Second result: the app showed a generic **"Unexpected error encountered in application"** dialog.
That is Electron's uncaught-exception dialog, and the addon was no longer the cause.

---

## 10. The game-directory / S: drive problem

The app writes a detailed log. Location:

```
pfx/drive_c/users/steamuser/AppData/Roaming/CaptureAge/logs/main.log
```

Relevant lines from the failing runs:

```
[info] Last Used Game Directory: C:\Program Files (x86)\Steam\steamapps\common\AoE2DE
[info] (worker) Creating renderer with directory: C:\Program Files (x86)\Steam\steamapps\common\AoE2DE
[warn] AK package or bank not found: Base.pck
[warn] AK package or bank not found: en\Base.pck                    (…~60 similar…)
[info] (worker) Capturing exception:
       da ComException:80070003 at renderer::helper::ImageLoader::LoadWic(…): Path not found.
[warn] (appDom) Unable to load resource manager for EMPIRES1.
       GameStringMap: Left, Palette: Left, CivData: Left, MapData: Left, ErasData: Left
[info] Capturing exception: MG Error: No matching file found
[info] app quit on global error handler, main
```

`C:\Program Files (x86)\Steam\steamapps\common\AoE2DE` is CaptureAge's built-in default and does
not exist in our prefix. Later in the same session the worker discovered the real path via Steam:

```
[info] (worker) Game install directory: S:\steamapps\common\AoE2DE
[info] (worker) Game user directory: C:\users\steamuser\Games\Age of Empires 2 DE\<steamid>
```

but `S:` was not mapped in our prefix (`pfx/dosdevices/` had only `c: d: e: z:`), so that attempt
failed too.

Experiments that clarify the mechanism:

```bash
ln -s ~/.local/share/Steam pfx/dosdevices/s:     # manually
WINEDEBUG=-all … proton run cmd /c "dir S:\" > Z:\tmp\out # empty -> S: gone
ls pfx/dosdevices/s:                                       # No such file or directory
```

Wine boot **removes** the hand-made link on the next start. Reading Proton's own script explains
why (`~/.local/share/Steam/steamapps/common/Proton Hotfix/proton`):

```python
def try_get_game_library_dir():
    if "STEAM_COMPAT_INSTALL_PATH" not in g_session.env or \
            "STEAM_COMPAT_LIBRARY_PATHS" not in g_session.env:
        return None
    # find library path which is a subset of the game path
def setup_dir_drive(compat_option, drive_name, dest_dir):   # creates OR removes the symlink
def setup_game_dir_drive():
        setup_dir_drive("gamedrive", "s:", try_get_game_library_dir())
```

So `S:` is created only when **both** `STEAM_COMPAT_INSTALL_PATH` (AoE2 dir) and
`STEAM_COMPAT_LIBRARY_PATHS` (library root) are exported — exactly what the running game has.
With both set:

```bash
WINEDEBUG=-all … proton run cmd /c "dir S:\steamapps\common\AoE2DE\resources\_common\dat > Z:\tmp\out"
# -> lists 05_buildings_babylon.pal, AIConsts.json, civilizations.json, …
```

The launcher sets both for every run/install.

---

## 11. First-run state: why it still failed with S: available

Even with `S:` mapped, a *fresh* prefix still failed: CaptureAge reads its stored game directory
from `persistedState_prod.json` and, when that file has no state version, it runs migrations which
reset `lastUsedGameDirectory` to the built-in C: default. Observed behaviour:

| Action | Result |
|---|---|
| no state file, run | uses `C:\Program Files (x86)\Steam\steamapps\common\AoE2DE`, error dialog |
| seed `{"lastUsedGameDirectory":"S:\\…"}` only, run | migrations saw no version → rewrote to C: default, error dialog |
| seed with `"__internal__":{"migrations":{"version":"0.0.46"}}` | uses `S:\…` immediately, no error |
| app-generated full state (86 keys, version 0.0.46) patched to `S:\…` | uses `S:\…`, no error |
| app started with C: first, then switched to S: mid-run | `std::runtime_error: Can't re-create sound system` (renderer re-created after a failed first init) |

Working seed for a fresh prefix:

```json
{"lastUsedGameDirectory":"S:\\steamapps\\common\\AoE2DE",
 "__internal__":{"migrations":{"version":"0.0.46"}}}
```

Full path: `pfx/drive_c/users/steamuser/AppData/Roaming/CaptureAge/persistedState_prod.json`.
The launcher patches this on every start (`seed_game_dir`), preserving whatever version the app
itself has written.

Additionally, CaptureAge reads replays and mods from
`%USERPROFILE%\Games\Age of Empires 2 DE\<steamid>`. That directory only exists in the AoE2
prefix, so the launcher symlinks it in:

```
pfx/drive_c/users/steamuser/Games/Age of Empires 2 DE
  -> ~/.local/share/Steam/steamapps/compatdata/813780/pfx/drive_c/users/steamuser/Games/Age of Empires 2 DE
```

With these in place the app reaches `openAppFinish`, lists recent replays, and the renderer loads
the AoE2 data from `S:\steamapps\common\AoE2DE` (the UI background is the AoE2 main-menu art).

Residual log noise on a *working* launch (do not chase these):

```
[warn] AK package or bank not found: …          (audio banks; app still works)
[warn] (appDom) Unable to load resource manager for EMPIRES1 … Left
[info] Update for version 1.26.0 is not available (latest version: 1.26.0, downgrade is disallowed)
```

---

## 12. Encode it in the script and verify on a clean prefix

`capture-age.sh` implements the above. Environment it exports for the Proton call:

```
STEAM_COMPAT_CLIENT_INSTALL_PATH=$CA_STEAM
STEAM_COMPAT_DATA_PATH=$CA_HOME
STEAM_COMPAT_INSTALL_PATH=<AoE2 DE dir>        # gives us S:
STEAM_COMPAT_LIBRARY_PATHS=$CA_STEAM/steamapps
WINEDEBUG=-all
WINEDLLOVERRIDES=msvcp140=b;vcruntime140=b;vcruntime140_1=b;concrt140=b   # launch only
```

Other behaviour:

* AoE2 dir auto-detected by parsing `libraryfolders.vdf` (`"path"` entries), overridable with
  `CA_AOE_DIR`.
* `seed_game_dir` writes `lastUsedGameDirectory` = `S:\…` (`Z:\…` fallback if the game is not in a
  Steam library) plus a migration version, only touching that key.
* `link_aoe_userdata` creates the `Games/Age of Empires 2 DE` symlink if missing.
* The vendor installer is cached as `$CA_HOME/CaptureAgeSetup.exe`; if absent it is downloaded
  from `…/prod/CaptureAgeSetup.exe`.
* `install` runs the stub with `/S`; `run` verifies the exe and launches it; `status` prints
  resolved paths/version.

Clean-prefix verification (deleted `/tmp/ca-test` afterwards):

```
$ CA_HOME=/tmp/ca-test ./capture-age.sh install
[install] running silent install (the stub downloads ~150 MB inside the prefix)
Proton: Upgrading prefix from None to 11.0-100 (/tmp/ca-test/)
[install] linked AoE2 user data: … -> …/compatdata/813780/…
[install] seeded game directory: S:\steamapps\common\AoE2DE
[install] installed CaptureAge 1.26.0 -> /tmp/ca-test/pfx/…/CaptureAge.exe
real 0m9.2s

$ CA_HOME=/tmp/ca-test ./capture-age.sh run      # 30s later
[launching CaptureAge 1.26.0 …]
main.log: Last Used Game Directory: S:\steamapps\common\AoE2DE
main.log: (worker) Creating renderer with directory: S:\steamapps\common\AoE2DE
main.log: App event: {"name":"openAppFinish", …}
xwininfo: "CaptureAge" 3440x1440        (no "Error" window)
```

Sizes: prefix 1.1 GB, app tree 406 MB, `CaptureAge.exe` 227 MB, payload 147 MB.

---

## 13. Findings summary

| # | Finding | Evidence |
|---|---|---|
| 1 | `CaptureAgeSetup.exe` is a 1 MB NSIS **web installer**, not the app | §1, §2; header strings `package-file`, download URL |
| 2 | It ships ~1.4 MB of plugins and no app payload | §2, 10 deflate streams |
| 3 | The payload is `CaptureAge-<ver>-x64.nsis.7z` from an API that 302s to Azure; latest is 1.26.0 / 147,260,820 B | §3 |
| 4 | The vendor still serves the 1.16.1 stub, byte-identical to the repo's copy | §3 |
| 5 | `cade.node` (native addon) fails `DllMain` under Wine with native MSVCP140 14.28 | §7–§9 |
| 6 | The failure is an AV (NULL read) inside `MSVCP140+0x12EB0` during `_initterm` | §9 |
| 7 | Wine-builtin VC runtime (`msvcp140/vcruntime140/…=b`) fixes it | §9 |
| 8 | CaptureAge needs `S:` → Proton only maps it when `STEAM_COMPAT_INSTALL_PATH` **and** `STEAM_COMPAT_LIBRARY_PATHS` are set | §10 |
| 9 | Hand-made `dosdevices/s:` links are deleted by Proton's `setup_game_dir_drive` | §10 |
| 10 | Fresh prefix needs `persistedState_prod.json` seeded with `lastUsedGameDirectory` **and** a migration version | §11 |
| 11 | Replays/mods come from the AoE2 prefix's `Games/Age of Empires 2 DE` dir (symlinked) | §11 |
| 12 | Everything works with `Proton Hotfix` + `SteamLinuxRuntime_4` in a dedicated compatdata dir | §12 |
| 13 | Uninstall entry says 1.16.1 while the app is 1.26.0 (stub version leakage) | §5, `pfx/user.reg` |

---

## 14. Dead ends, traps, and things not to repeat

* **Do not `strings` the NSIS overlay** expecting filenames; it is deflate-compressed. Decompress
  first (§2).
* **zlib, not LZMA**: `flags = 0` at `0x58e00`; raw deflate with `wbits = -15` and a 4-byte size
  prefix per stream. Bzip2 (`BZh`) and LZMA attempts find nothing.
* **`7z` is not installed** on this host, and Python lacks `py7zr`. libarchive `.so.13` exists.
  See the option-3 notes for the three extraction options.
* **Never run `wineserver -k` / `wineserver -w` without `WINEPREFIX`** — it would terminate the
  user's running AoE2 session. Use
  `WINEPREFIX=$CA_PREFIX "$PROTON/files/bin/wineserver" -k`.
* **Piping Proton output into `tail` hides the exit code**; also closing the pipe early produces
  `wine client error:… write: Bad file descriptor`. Log to a file instead.
* **Window ids change every run** (`0xbe00009` was a CaptureAge window in one run and a different
  process's dialog later). Always re-query `xwininfo`/`xprop`.
* **Screenshotting an occluded window**: `ffmpeg -f x11grab` grabs the screen (the fullscreen game),
  not the window. Use XComposite on the window pixmap (§D). `ffmpeg -f xcbgrab -window_id` is not
  available in this ffmpeg build.
* **Relay filtering**: variable-length hex, correct module base (last token), range > DLL size,
  and TIDs are not unique per process. Unfiltered `+relay` produced 1.6 GB in 20 s.
* **A minimal `persistedState_prod.json` is silently reset** unless it carries a migrations
  version; see §11.
* The generic popup **"Unexpected error encountered in application"** carries no detail — the
  actual error is in `main.log`. Always read the log before guessing.
* Do not create `C:\Program Files (x86)\Steam\steamapps` symlinks as a workaround for the game
  path: it makes the app start with the wrong dir first and then fail with
  `Can't re-create sound system` when it re-initialises the renderer. Seed the state instead.

---

## 15. How to inspect the current state (verification recipes)

```bash
# installed? version? paths?
cd /path/to/capture-age && ./capture-age.sh status

# app log (the single best debugging surface)
L=~/.local/share/capture-age/pfx/drive_c/users/steamuser/AppData/Roaming/CaptureAge/logs/main.log
rg -n 'Last Used Game Directory|Creating renderer|openAppFinish|Capturing exception|MG Error' "$L" | tail

# errors with context
rg -n -A3 'Capturing exception' "$L" | tail -20

# seeded state
python3 - <<'EOF'
import json, os
p = os.path.expanduser('~/.local/share/capture-age/pfx/drive_c/users/steamuser/'
                       'AppData/Roaming/CaptureAge/persistedState_prod.json')
d = json.load(open(p))
print(d['lastUsedGameDirectory'], d['__internal__'])
EOF

# our prefix's S: mapping (recreated by Proton on every start)
ls -la ~/.local/share/capture-age/pfx/dosdevices/s:

# stop only our prefix (never run this without WINEPREFIX while the game is running)
WINEPREFIX=~/.local/share/capture-age/pfx \
  ~/.local/share/Steam/steamapps/common/"Proton Hotfix"/files/bin/wineserver -k
```

To reproduce the crash-and-fix experiment, launch with and without:

```bash
WINEDLLOVERRIDES="msvcp140=b;vcruntime140=b;vcruntime140_1=b;concrt140=b"
```

Without it, the app's own `main.log` never appears; Electron shows the "No access to memory
location" dialog, and `WINEDEBUG=-all,+loaddll,+module` shows
`MODULE_InitDLL (cade.node) … RETURN 0`.

To re-check the vendor payload metadata (no full download):

```bash
curl -sI https://captureage.com/api/cade/download/prod/latest | grep -i '^location'
# then HEAD the Location URL for Content-Length / Last-Modified
```

---

## Appendix A — reusable PE/NSIS inspection snippets

```python
# PE section / certificate-directory dump
import struct
d = open('CaptureAgeSetup.exe','rb').read()
pe  = struct.unpack_from('<I', d, 0x3c)[0]
nsec = struct.unpack_from('<H', d, pe+6)[0]
optsz = struct.unpack_from('<H', d, pe+20)[0]
opt = pe+24
magic = struct.unpack_from('<H', d, opt)[0]
print('magic', hex(magic), 'sections', nsec)
for i in range(nsec):
    o = opt+optsz+i*40
    name = d[o:o+8].rstrip(b'\0').decode()
    vsz, va, rsz, roff = struct.unpack_from('<IIII', d, o+8)
    print(f'{name:10s} va={va:#x} rsz={rsz:#x} off={roff:#x}')
dd = opt+(96 if magic == 0x10b else 112)          # data directories
so, ss = struct.unpack_from('<II', d, dd+4*8)     # [4] = authenticode
print('cert dir', hex(so), hex(ss), 'file end', hex(len(d)))
```

```python
# NSIS header dump (offsets valid for this specific stub)
import zlib
d = open('CaptureAgeSetup.exe','rb').read()
h = zlib.decompressobj(-15).decompress(d[0x58e20:])
print('\n'.join(p for p in h.decode('utf-16le','replace').split('\0')
                if len(p) >= 6 and p.isprintable()))
```

```python
# NSIS data section: walk the consecutive raw-deflate streams
import zlib
d = open('CaptureAgeSetup.exe','rb').read()
pos, end = 0x60a30, 0x103978
while pos < end-16:
    for skip in (4, 0):
        try:
            o = zlib.decompressobj(-15)
            out = o.decompress(d[pos+skip:end])
            if len(out) >= 64:
                used = len(d[pos+skip:end]) - len(o.unused_data)
                print(hex(pos), len(out), out[:8])
                pos += skip + used
                break
        except zlib.error:
            continue
    else:
        print('stuck at', hex(pos)); break
```

## Appendix B — reading an occluded window's contents (used to read the error dialogs)

```python
# usage: python3 grabwindow.py 0xbe00009 out.png
import ctypes, re, subprocess, sys
from PIL import Image
wid = int(sys.argv[1], 16)
info = subprocess.run(['xwininfo', '-id', sys.argv[1]], capture_output=True, text=True).stdout
w = int(re.search(r'Width:\s+(\d+)', info).group(1))
h = int(re.search(r'Height:\s+(\d+)', info).group(1))
x11 = ctypes.CDLL('libX11.so.6'); comp = ctypes.CDLL('libXcomposite.so.1')
x11.XOpenDisplay.restype = ctypes.c_void_p
dpy = ctypes.c_void_p(x11.XOpenDisplay(b':1'))
comp.XCompositeNameWindowPixmap.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
class XImage(ctypes.Structure):
    _fields_ = [('width', ctypes.c_int), ('height', ctypes.c_int), ('xoffset', ctypes.c_int),
                ('format', ctypes.c_int), ('data', ctypes.c_void_p), ('byte_order', ctypes.c_int),
                ('bitmap_unit', ctypes.c_int), ('bitmap_bit_order', ctypes.c_int),
                ('bitmap_pad', ctypes.c_int), ('depth', ctypes.c_int),
                ('bytes_per_line', ctypes.c_int), ('bits_per_pixel', ctypes.c_int),
                ('red_mask', ctypes.c_ulong), ('green_mask', ctypes.c_ulong), ('blue_mask', ctypes.c_ulong)]
x11.XGetImage.restype = ctypes.POINTER(XImage)
pix = comp.XCompositeNameWindowPixmap(dpy, ctypes.c_ulong(wid))
img = x11.XGetImage(dpy, ctypes.c_ulong(pix), 0, 0, w, h, 0xFFFFFFFF, 2).contents
buf = ctypes.string_at(img.data, img.bytes_per_line * img.height)
Image.frombuffer('RGB', (img.width, img.height), buf, 'raw', 'BGRX', img.bytes_per_line, 1).save(sys.argv[2])
```

Companion commands:

```bash
DISPLAY=:1 xwininfo -root -children | grep -Ei '"captureage"|"error"'
DISPLAY=:1 xprop -id <WID> _NET_WM_PID WM_NAME WM_CLASS
DISPLAY=:1 xwininfo -id <WID> | grep -E 'Absolute|Width|Height|Map State'
```

## Appendix C — the one-liner that finally proved S: was missing

```bash
WINEDEBUG=-all "$SLR/_v2-entry-point" --verb=waitforexitandrun -- \
  "$PROTON/proton" run cmd /c "dir S:\steamapps\common\AoE2DE\resources\_common\dat > Z:\tmp\out 2>&1"
# empty file -> S: not mapped; after exporting STEAM_COMPAT_INSTALL_PATH + STEAM_COMPAT_LIBRARY_PATHS
# it lists the AoE2 dat files.
```

## Appendix D — open questions / possible follow-ups

* Does the vendor updater's `--installer --updated` flow (NSIS stub run by electron-updater)
  work inside this prefix? The registry keys and `app-update.yml` are present, but it has not been
  exercised with a real new release yet.
* Are the leftover `AK package or bank not found` warnings sign of a missing optional audio pack,
  or harmless? Audio was not tested.
* Would Wine's builtin CRT also work for other Electron/native-addon apps with a similar
  MSVCP140-under-Wine fault? Likely, but untested.
* Option 3 (manual payload) remains unimplemented; see the companion notes for the recipe and the
  same runtime requirements.
