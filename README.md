# Stealth-Phantom-Roblox

A highly optimized stealth system with NPC pathfinding and detection system.

**[Play Stealth Phantom](https://www.roblox.com/games/78118105284105/Stealth-Phantom)**

---

# Guard AI System

A server-side stealth AI framework for Roblox Studio. It handles guard patrolling, field-of-view sight lines, pathfinding around obstacles, and reacting to environmental sounds.

## Features

- **State Machine:** Manages behavior loops for Idle, Investigate, and Chase states.
- **Sound Reactions:** Uses a `BindableEvent` so environmental triggers, such as a thrown rock, can alert nearby guards within a certain radius.
- **Server Control:** Locks network ownership to the server to prevent movement jitter.

> **Note:** System inspired by MGSV, the best stealth game ever.
