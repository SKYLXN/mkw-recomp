# Roadmap

What is being worked on, in order of priority: nothing may hang the GPU, then the picture as on the console (menus
before races), then the frame rate, then the player's side. Updated 09/11/2026.

## 1. 60 fps in races: the serial frame

A race frame takes 31-33 ms\* on the Radeon 660M at 720p, against the 16.7 ms the game asks for. The time does not go
to one slow piece but to a chain where each step waits for the previous one (measured with `MKW_TRACE_TL`):

| Step | Time\* |
|---|---|
| The game runs its frame, from the release of the previous frame's fence to its last submit | ~3.4 ms |
| The Vulkan back end records that submit into command buffers, on the replay thread | ~19 ms |
| The GPU runs what was submitted last | ~9.7 ms |
| Completion work before the game is released for the next frame | ~1.5 ms |

The game's big submit only reaches the back end at the end of its frame, and the GPU cannot start until it is
recorded, so recording is on the critical path: every millisecond saved there is a millisecond off the frame, down to
~21 ms, where the GPU (busy ~20 ms) takes over. Spreading the same CPU work over more threads does not help by
itself; recording with less CPU does. Already done: recordings reused across frames (−4.3 ms), recording overlapped
with the game (−2.4 ms), submits on their own thread (−1.2 to −1.6 ms), the shadow copies off the replay thread
(−0.8 ms), the replay thread on its own core (−1.1 ms), dynamic state recorded only when it changes (idea from
totk-pc-recomp, MIT; −10.6 % recorder instructions on Steam Deck; no measurable frame-time change). Next:

- **Threads on hybrid CPUs**: on an Intel i7-14700F (8 P-cores, 12 E-cores) with an RX 6700 XT, game 1.8.0 at its
  2560x1440 internal resolution, a race frame took 37.7-39.4 ms median when the scheduler was free to put threads on
  the E-cores, and 19.2-20.3 ms with the whole process on the P-cores (`taskset -c 0-15`; sl-player, sl-nocap,
  sl-pcore, sl-pcore2, 16/11/2026). Nothing was saturated: 3.3 CPUs busy of 28 and 2-10 % run-queue wait
  (`rqwait.py`). What slowed down is the chain itself: the game blocks ~22 ms a frame on a fence value the replay
  has not recorded yet, and in the race's first, heavier seconds the replay's walk took 3x and the chunks 2x as long
  as later for the same ~3 100 draws a submission. The replay thread is already on
  a P-core (#480); the game's threads, the recording chunks, the recorder and the completion thread are not.
  `plat_cpu_fast` and `plat_process_affinity` are already in the runtime.
- **Less work per draw**: descriptor sets kept across frames by their contents (`MKW_DRAW_CACHE`). On a fast CPU
  (i7-14700F, RADV) it changes nothing measurable: a race capture's recording thread ran the same instructions with
  it on and off, and its binds made ~20 % more descriptor work (sets are allocated) (16/11/2026); left for slower CPUs.
- **Recording in parallel**: chunks of a submit on several threads; today they fight over the texture lock, which has
  to be split first.
- **The kernel's global lock**: waits by address are done (−1.3 ms\*); the rest of the lock remains.
- **The game thread**: the generated C at `-O1`, with profile-guided optimization next (12-15 % in totk-pc-recomp).

\* Our numbers (not the ones said to come from totk-pc-recomp) were measured on 07-09/11/2026 on our test machine:
Radeon 660M APU (Ryzen 5 7535HS), Linux, 720p internal resolution.

Two defaults of the test runs mislead on another machine (16/11/2026): `run_perf.sh` caps the GPU heap at 4096 MiB
(`MKW_GPU_MEM_LIMIT`, set for the 660M), and on a 12 GB RX 6700 XT the race then took 59 ms a frame against 39-43 ms
without the cap (sl-base, sl-nocap); and `race.sh`'s 720p needs the RomFS overlay `build/romfs-res`
(`tools/romfs/resolution.py`): without it the log says "RomFS overlay: none" and a 1.8.0 race renders at 2560x1440
with a 3840x2160 output. Players have neither: no cap, the game's resolution.

## 2. The picture as on the console

- Shader translator bugs found by comparing with another Switch 2 port: three of six fixed, three to go, each
  reapplied alone and checked on a race capture.
- The kart's shadow misses a frame now and then; two fixes from Ryujinx (MIT) to try.
- Push constants of constant bank 24 are not passed yet: five programs read zeros.
- Zero Vulkan validation errors (25 left, 9 kinds), which may be rendering bugs or hangs on other GPUs.
- Task/mesh shaders as compute: a race on the first thread in the scene lists (bushes and grass).

## 3. Menus

From the title to the race everything is right; the mode, character and vehicle select screens still need checking
screen by screen against the console.

## 4. Stability and memory

- GPU hangs on AMD: upload batches already split; next, breadcrumbs and `VK_EXT_device_fault` to find the cause of the
  remaining ones.
- GPU memory: races run in 4 GiB with every texture; the sparse tiles above 768 MiB (the asphalt) are next.
- Five kernel and platform bugs inherited from totk-pc-recomp (the fiber stack alignment can crash a run).

## 5. Loading and the player's side

- The stutter right after a race starts: block-linear deswizzle on the GPU (totk-pc-recomp, MIT: texture waits from
  900 to 270 ms in that game), VMA reservations on Windows. Measured on an i7-14700F (16/11/2026), the CPU deswizzle
  (`tex_bl_copy`) runs at memcpy speed (16-25 GB/s, 9.6 for a 16 MiB BC7 level), so on the GPU it only pays if the
  GPU reads the storage from its mirror without a CPU copy. In the course load's peak (1.5 s, user call graphs of the
  replay thread, tl-fp1) the replay spent ~66 ms in the BC1/BC7 choice for ASTC textures (`astc_alpha_one`, at image
  creation) and ~44 ms in the deswizzle, both serial on the critical path; spreading them over worker threads is the
  cheaper step.
- A Linux package that starts on non-rolling distributions (glibc 2.31 through zig), and the launcher tested on real
  Windows machines.
- Windows with a dedicated GPU: memory the GPU wrote is not uploaded again to its mirror.
- "Detect" in the graphics settings: a preset picked from the GPU.
- Audio: two known SDK bugs (splitters, voice 0) and cuts in the movies' audio.

## 6. Later game versions

- Updates (issue #19): each version is a different executable, so the recompilation (function list, patches, the
  runtime's addresses) is redone for it; the game cannot be shared, so this needs someone who owns that version to run
  the tools on their own dump and contribute the result.
- 1.8.0 (11/11/2026): recognised by the setup (`recomp/versions.py`), its own patch table
  (`recomp/patches-mkw-180.txt`: spin waits, zstd, output size and every set of 1.0.0 — aspect, vertplus (the tall
  Window's race FOV), shadow, seed and LAN play) and runtime row (`runtime/core/boot/version.c`: frame update and game
  clock, zstd, NVN2 proc table and `nvnDeviceGetInteger` answers, boot checkpoint, the new `subsdk1` module's
  constructors). Still to find in its
  executable: the menu focus probe; to check in a run: the 30 NVN2 procs new in its sdk (weak stubs but three
  scheduling hints), its 43 new shader stages and the button icon sheet's hash.
