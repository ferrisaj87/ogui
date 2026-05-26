# OGui — Original Game UI Control

An [Ashita v4](https://www.ashitaxi.com/) addon for **HorizonXI** (FFXI private server) that gives you granular per-element control over the native FFXI UI — hide only what you want, leave everything else alone.

## Features

- **Hide party frames** (A / B / C) independently
- **Hide target UI** (target bar, subtarget bar, selection cursors, conquest / imperial standing)
- **Hide chat windows** (main and secondary) independently
- **Fishing HP bar workaround** — the fishing bar lives inside the party container; it auto-shows when a fish is hooked and re-hides when the session ends
- **Target bar stays pinned** — when party frames are hidden the target bar no longer shifts when members join or leave, even on auto-targeting events from combat or incoming buffs
- **Clean ImGui settings window** — status indicator, per-element checkboxes with tooltips, Turn On / Turn Off button
- **Settings persist per-character** via Ashita's settings library
- **Diagnostic tools** — `/ogui scan`, `/ogui test N`, `/ogui dumpptr <name>` for future pointer discovery

## Installation

1. Copy the `ogui` folder into your Ashita `addons` directory:
   ```
   HorizonXI/Game/addons/ogui/
   ```
2. Load in-game:
   ```
   /addon load ogui
   ```
   Or add `addon load ogui` to your Ashita startup script.

## Commands

| Command | Description |
|---|---|
| `/ogui` | Open / close the settings window |
| `/ogui on` | Enable hiding (applies your saved choices) |
| `/ogui off` | Disable hiding (all elements restored) |
| `/ogui info` | Print pointer addresses and current state |
| `/ogui scan` | Scan for primitive pointers (debug) |
| `/ogui test <N>` | Toggle visibility of Nth scanned pointer (debug) |
| `/ogui testall` | Restore all debug-toggled pointers |
| `/ogui dumpptr <name>` | Dump prim struct for a named pointer (debug) |

## Notes

- The fishing HP bar is bundled inside the same memory container as the party list and cannot be addressed independently. The workaround detects hook messages via chat and forces the party container visible until the fishing session ends.
- Derived from the original [hideparty](https://github.com/AshitaXI/Example-AddOns) addon by atom0s / Ashita Development Team. Extended significantly with independent per-element control, layout pinning, fishing detection, ImGui UI, and settings persistence.

## License

GNU General Public License v3 — see [LICENSE](LICENSE).
