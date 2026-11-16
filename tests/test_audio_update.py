"""Compile the actual audren RequestUpdate path and feed synthetic REV11/REV15 voice records.

Why: unused client slots can be zeroed, including their ID; they must not reset active voice 0. The harness uses the
runtime's wire layouts and update parser, with only mixer/platform calls stubbed. No game or audio device required.
Usage: uv run --with ziglang pytest tests/test_audio_update.py (ziglang is optional with clang/cc/gcc installed).
"""

import importlib.util
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r"""
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "audren.h"

void rt_log(const char *fmt, ...) { (void)fmt; }
static void need(int ok, const char *what) { if (!ok) { fprintf(stderr, "%s\n", what); exit(3); } }
static int revision_number(uint32_t rev) { return (int)(rev >> 24) - '0'; }
void plat_mutex_lock(PlatMutex *m) { (void)m; }
void plat_mutex_unlock(PlatMutex *m) { (void)m; }
void audio_mixer_update_effects(AudioRenderer *r) { (void)r; }
void audio_mixer_update_routing(AudioRenderer *r, const uint8_t *s, uint32_t sn, const uint8_t *m, uint32_t mn, int mc) {
    (void)r; (void)s; (void)sn; (void)m; (void)mn; (void)mc;
}
void audio_mixer_effect_result(AudioRenderer *r, int i, void *p, unsigned n) { (void)r; (void)i; (void)p; (void)n; }
uint32_t audio_mixer_sink_written(AudioRenderer *r, int i) { (void)r; (void)i; return 0; }

#include "request.inc"

static void set_voice(uint8_t *p, int rev, const AudrenVoiceIn *v) {
    if (rev < 15) memcpy(p, v, sizeof *v);
    else {
        AudrenVoiceInV2 v2 = {0};
        memcpy(v2.prefix, v, sizeof v2.prefix);
        memcpy(v2.tail, (const uint8_t *)v + 0x3c, sizeof v2.tail);
        memcpy(p, &v2, sizeof v2);
    }
}

int main(int argc, char **argv) {
    int rev = argc > 1 ? atoi(argv[1]) : 11;
    AudioRenderer r = {0};
    r.param.voice_count = 3; r.param.sink_count = 1; r.logged = 1;
    ServerVoice voices[3] = {0}; AudrenPoolIn pools[12] = {0};
    AudrenMixIn mixes[1] = {0}; AudrenSinkIn sinks[1] = {0}; AudrenChannelIn channels[18] = {0};
    r.voices = voices; r.pools = pools; r.mixes = mixes; r.sinks = sinks; r.channels = channels;
    AudrenHeader h = {0};
    h.revision = AUDREN_REV(rev); h.behavior = 0x10; h.memory_pools = sizeof pools;
    size_t stride = rev >= 15 ? sizeof(AudrenVoiceInV2) : sizeof(AudrenVoiceIn);
    h.voices = 3 * stride; h.mixes = sizeof mixes; h.sinks = sizeof sinks;
    h.total = sizeof h + h.behavior + h.memory_pools + h.voices + h.mixes + h.sinks;
    uint8_t *input = calloc(h.total, 1), output[16384];
    memcpy(input, &h, sizeof h);
    uint8_t *vdata = input + sizeof h + h.behavior + h.memory_pools;
    AudrenVoiceIn active = {0};
    active.id = 0; active.in_use = 1; active.play_state = PLAY_STARTED; active.sample_rate = 48000;
    active.channel_count = 1; active.pitch = active.volume = 1;
    for (int i = 0; i < 4; i++) active.wave_buffers[i].sent = 1;
    set_voice(vdata, rev, &active);
    // Slot 1 was active previously, then the client freed/zeroed it; slot 2 has always been unused.
    voices[1].in.in_use = 1; voices[1].state = SV_STARTED; voices[1].valid[0] = 1;
    voices[0].played = 1234; voices[0].consumed = 7; voices[0].offset = 33; voices[0].valid[0] = 1;
    request_update(&r, input, h.total, output, sizeof output, 0);
    need(voices[0].in.in_use && voices[0].state == SV_STARTED, "unused record stopped active voice 0");
    need(voices[0].played == 1234 && voices[0].consumed == 7 && voices[0].offset == 33 && voices[0].valid[0],
         "unused record reset active voice 0 cursor/status");
    need(!voices[1].in.in_use && voices[1].state == SV_STOPPED && !voices[1].valid[0], "freed slot kept playing");
    AudrenHeader *out = (AudrenHeader *)output;
    AudrenVoiceOut status;
    memcpy(&status, output + sizeof *out + out->memory_pools, sizeof status);
    need(status.played_samples == 1234 && status.wave_buffers_consumed == 7, "wrong slot's status returned");
    // A new voice in a reused slot resets that slot, and clearing slot 0 itself must still stop it.
    active.id = 1; active.is_new = 1;
    set_voice(vdata + stride, rev, &active);
    voices[1].played = 999;
    memset(vdata, 0, stride);
    request_update(&r, input, h.total, output, sizeof output, 0);
    need(!voices[0].in.in_use && voices[0].state == SV_STOPPED, "cleared slot 0 kept playing");
    need(voices[1].in.in_use && voices[1].state == SV_STARTED && !voices[1].played, "new voice slot was not reset");
    free(input);
    puts("voice slots passed");
    return 0;
}
"""


@pytest.fixture(scope="module")
def renderer_update(tmp_path_factory: pytest.TempPathFactory) -> Path:
    cc = shutil.which("clang") or shutil.which("cc") or shutil.which("gcc")
    command = [cc] if cc else []
    if not command:
        spec = importlib.util.find_spec("ziglang")
        zig = shutil.which("zig")
        if not zig and spec and spec.origin:
            zig = str(Path(spec.origin).parent / ("zig.exe" if os.name == "nt" else "zig"))
        if not zig:
            pytest.skip("no C compiler; use uv run --with ziglang pytest tests/test_audio_update.py")
        command = [zig, "cc"]
    src = (ROOT / "runtime/audio/audren.c").read_text(encoding="utf-8")
    begin = src.index("// ---- RequestUpdate")
    end = src.index("// ---- render tick:")
    d = tmp_path_factory.mktemp("audren-update")
    (d / "request.inc").write_text(src[begin:end], encoding="utf-8")
    (d / "main.c").write_text(HARNESS, encoding="utf-8")
    includes = [f"-I{ROOT / 'runtime' / folder}" for folder in ("audio", "core/base", "cpu", "platform")]
    includes += [f"-I{ROOT / 'runtime'}", f"-I{d}"]
    exe = d / "update.exe"
    subprocess.run([*command, "-O1", *includes, str(d / "main.c"), "-o", str(exe)], check=True)
    return exe


@pytest.mark.parametrize("revision", [11, 15])
def test_unused_voice_records_cannot_reset_voice_zero(renderer_update: Path, revision: int) -> None:
    out = subprocess.run([str(renderer_update), str(revision)], capture_output=True, text=True)
    assert out.returncode == 0, out.stdout + out.stderr
