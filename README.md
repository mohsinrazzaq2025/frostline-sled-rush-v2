# Frostline: Sled Rush V2

### Roblox Luau Gameplay Portfolio

A published winter-themed Roblox sledding experience featuring physics-driven movement, two playable courses, server-authoritative results, and persistent progression. Built with Roblox Studio, Luau, Git, and Rojo.

**[▶ Play on Roblox](https://www.roblox.com/games/111635677952498/Frostline-Sled-Rush-V2)** · **[Desktop Gameplay](https://www.youtube.com/watch?v=F8EcIGPjlZA)** · **[Mobile Gameplay](https://www.youtube.com/watch?v=cO0ttRTRV5w)**

## Gameplay Preview

Click a video thumbnail to watch gameplay.

### Desktop

[![Frostline: Sled Rush V2 — desktop gameplay video thumbnail](https://i.ytimg.com/vi/F8EcIGPjlZA/hqdefault.jpg)](https://www.youtube.com/watch?v=F8EcIGPjlZA)

[Watch desktop gameplay →](https://www.youtube.com/watch?v=F8EcIGPjlZA)

### Mobile

[![Frostline Mobile Gameplay](https://i.ytimg.com/vi/cO0ttRTRV5w/hqdefault.jpg)](https://www.youtube.com/watch?v=cO0ttRTRV5w)

[Watch mobile gameplay →](https://www.youtube.com/watch?v=cO0ttRTRV5w)

## Highlights

- **Two playable courses:** Classic Distance and Frost Trail.
- **Physics-driven sledding:** downhill movement, ramp launches, and landing outcomes.
- **Hold-to-tuck mechanic:** input with visual and audio feedback.
- **Server authority:** run lifecycle, distance, outcomes, and rewards.
- **Progression:** Frost Coins, store purchases, upgrades, and persistent player data.
- **Results:** Clean Landing, Crashed, Stalled, and personal-best feedback.
- **Replay:** Play Again and Return to Start with lifecycle cleanup.
- **Cross-platform controls:** desktop, mobile, and gamepad input.
- **Winter presentation:** snowfall, runner trails, contact spray, and event-driven audio/VFX.

## Courses

| Course | Focus |
| --- | --- |
| Classic Distance | Downhill descent, ramp launch, and distance-based results |
| Frost Trail | An additional playable course with coin collection |

The current public release is **single-player**.

## Gameplay Flow

1. Choose a course and start a run.
2. Wait for the countdown.
3. Hold tuck during the descent.
4. Travel down the course and experience the physics-driven launch and landing.
5. Review the outcome, distance, and rewards.
6. Play again or return to the start to manage progression and upgrades.

### Tuck Controls

| Platform | Input |
| --- | --- |
| Keyboard | Hold **Shift** |
| Gamepad | Hold **L2 / left trigger** |
| Mobile | Hold the on-screen **Tuck** button |

The HUD indicates when tuck is active. Results also show whether tuck was used during the run.

## Core Architecture

| Layer | Responsibilities |
| --- | --- |
| Server | World generation, sled physics, run lifecycle, result calculation, rewards, persistent progression, purchase validation, and leaderboard logic |
| Client | Player input, HUD, tutorials, result presentation, audio, and visual effects |
| Shared | Gameplay configuration, types, and communication contracts |

### Server Authority and Validation

- Run actions are checked against the player, active run ID, and current phase.
- Duplicate and stale actions are rejected.
- Distance, outcomes, and rewards are calculated on the server.
- Client presentation uses server-authored result payloads.
- Replay and return-to-start actions follow the run cleanup lifecycle.

### Key Modules

| Module | Purpose |
| --- | --- |
| `RunManager` | Run phases, action validation, and lifecycle cleanup |
| `ResultService` | Authoritative results and rewards |
| `PlayerDataService` | Loading and saving persistent progression |
| `ResultController` | Result presentation and result-screen interactions |
| `AudioController` | Gameplay audio and phase-aware music levels |
| `VFXController` | Snowfall, trails, spray, and event effects |
| `GameConfig` | Centralized gameplay and presentation settings |

## Physics and Presentation

The sled follows a physics-driven course with visible collision geometry, snowy boundaries, ramps, and landing areas. Its decorative shell is attached to the physical assembly with massless, non-collidable parts.

- Runner trails and contact spray react to movement.
- Tuck activates additional feedback.
- Launch, landing, and crash events trigger dedicated effects.
- Music levels change with run phases.
- Mobile uses reduced particle budgets.
- Effects and audio are cleaned up across replay, respawn, and run replacement.

## Persistent Progression

Player progression is saved through `DataStoreService`, including best results, currency, and upgrade-related progression. Run-specific state resets separately during replay.

Live leave-and-rejoin testing verified that saved progression remained available across sessions.

## Technology

Roblox Studio · Luau · RemoteEvents · DataStoreService · Roblox physics and constraints · Particle effects and trails · Cross-platform input · Git/GitHub · Rojo 7.7.0

## Repository Overview

| Path | Contents |
| --- | --- |
| `src/` | Client, server, and shared Luau source |
| `default.project.json` | Rojo project mapping |
| `rokit.toml` | Development tool configuration |
| `README.md` | Project overview and setup instructions |

The Luau source and Rojo project configuration are the canonical project files.

## Running in Roblox Studio

1. Install **Rojo 7.7.0** and its matching Roblox Studio plugin.
2. Clone this repository:

   ```bash
   git clone https://github.com/mohsinrazzaq2025/frostline-sled-rush-v2.git
   cd frostline-sled-rush-v2
   ```

3. Open a fresh Baseplate in Roblox Studio.
4. Start Rojo from the repository directory:

   ```bash
   rojo serve
   ```

5. Connect the Rojo Studio plugin to `localhost:34872` and sync the project.
6. Press **Play** to initialize the world and gameplay systems.

The server bootstrap generates the world at runtime under `Workspace/FrostlineWorld`.

For Studio persistence testing, use a separate published test experience with Studio API access enabled. Keep test data separate from live player data.

## Validation

Completed development and live checks included:

- Full run lifecycle and countdown
- Tuck input and feedback
- Launch and result presentation
- Clean Landing, Crashed, and Stalled outcomes
- Play Again and Return to Start
- Respawn and run cleanup
- Course switching
- Desktop and mobile gameplay
- Persistent progression after leaving and rejoining
- New personal-best persistence
- Rojo build validation

Desktop and mobile recordings are linked above.

## Scope

This is a focused single-player gameplay project. Multiplayer racing is outside the current public release.

## Author

**Mohsin Ali Abdul Razzaq** — Roblox / Unity Gameplay Developer

[GitHub](https://github.com/mohsinrazzaq2025)

## Portfolio Note

Shared for portfolio and technical-review purposes. Referenced third-party Roblox assets remain subject to their respective owners' terms.
