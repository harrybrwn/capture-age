# capture-age

> ⚠️ Warning: This script was generated using deepseek-v4.1-flash-1017. The
> agent investigation process was written to `INVESTIGATION-LOG.md`.

Run **CaptureAge** 1.26.0 (Windows/Electron app) for AoE2 DE on Linux via Steam's Proton
container, without touching Steam's own game prefixes.

```bash
./capture-age.sh install   # silent-install into a dedicated prefix (~150 MB download)
./capture-age.sh           # launch
./capture-age.sh status    # paths + installed version
```

Optional: install it as a command with a desktop entry (menu icon):

```bash
make install                        # ~/.local/bin/capture-age + desktop entry + icon
sudo make install PREFIX=/usr/local # system-wide
```

Installs to `~/.local/share/capture-age` (prefix + app). Auto-finds AoE2 DE via
`libraryfolders.vdf`; override with `CA_HOME`, `CA_STEAM`, `CA_AOE_DIR`, `CA_PROTON`,
`CA_RUNTIME` (see `--help`).

Requires: Steam, `Proton Hotfix`, `SteamLinuxRuntime_4`, AoE2 DE, `python3` (state seeding).

| File | What |
|---|---|
| `capture-age.sh` | installer + launcher |
| `INVESTIGATION-LOG.md` | step-by-step findings, evidence, debugging recipes |

Why it isn't trivial: the vendor `.exe` is only a downloader, `cade.node` needs Wine's builtin
VC++ runtime, and the app requires an `S:` drive plus a pre-seeded game directory. Details in
`INVESTIGATION-LOG.md` §9–§11.

