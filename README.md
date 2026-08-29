# Frostline: Sled Rush

A polished Christmas downhill-sledding technical trial built with Roblox Studio,
Luau, Git, and Rojo.

## Milestone 1

This checkpoint contains the clean Rojo project and a generated V2 world:

- 580-stud continuous downhill course
- extended launch ramp
- visible, collidable snowbanks instead of invisible correction forces
- frozen-lake landing field with distance zones
- Christmas start arch and low-poly pine dressing
- server-generated, consistently named world geometry

Gameplay is intentionally not included in this checkpoint. The geometry must be
verified first because gravity, speed, launch, and landing all depend on it.

## Setup

1. Install Rojo 7.7.0 and its matching Roblox Studio plugin.
2. Open a fresh Baseplate in Roblox Studio.
3. From this directory run `rojo serve`.
4. Open the Rojo plugin in Studio and connect to `localhost:34872`.
5. Press **Play**. `ServerScriptService/FrostlineServer/Bootstrap` builds the V2
   world at runtime.

The generated world is placed in `Workspace/FrostlineWorld`. The builder only
replaces that specifically named model, leaving unrelated Workspace content
untouched.

## First Git checkpoint

```bash
git init
git add .
git commit -m "Initialize Frostline V2 world"
```

Do not commit Roblox place binaries. The Luau source and Rojo project are the
canonical project files.

## Current test checklist

- The course is one continuous surface with no large gaps.
- The descent feels long enough before the launch ramp begins.
- The launch ramp is visibly larger than the prototype.
- Snowbanks and rails are visible everywhere they can affect the sled.
- The landing lake is broad enough for a natural physics trajectory.
- Output contains `Frostline V2 world generated` and no red errors.
