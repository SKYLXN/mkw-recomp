// The command buffer being recorded by the draw replay (vk_draw_internal.h): per command buffer the replay keeps
// transient memory (support buffers, copied uniform ranges, generated indices), descriptor pools and the storage-buffer
// ranges the GPU may write; all of it is freed, and the ranges are reported with vk_gpu_written, from one completion
// callback once the submission's fence is done (the write watch does not see GPU writes). And the state recorded into it
// outside descriptors: pipeline, fixed-function state, vertex buffers, feedback barriers.
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cfg.h"
#include "host.h"
#include "nvn_api.h"
#include "nvn_hmap.h"
#include "tex.h"
#include "vk.h"
#include "vk_draw_internal.h"
#include "vk_exec.h"
#include "platform/platform.h"

#define CHUNK_BYTES (4u << 20)

static void *grow(void *p, int *cap, size_t elem) {
    *cap = *cap ? *cap * 2 : 8;
    p = realloc(p, elem * (size_t)*cap);
    if (!p) rt_fatal("vk: out of memory");
    return p;
}

// ---- resources of one command buffer, freed by its completion callback

typedef struct { VkBuffer buf; VmaAllocation alloc; uint8_t *map; uint64_t size, used; } Chunk;
// part: the newest part writing it (0 without MKW_WB_EARLY); done: written back before the fence (vk_exec_cb_early);
// hold: not in the pass at hand
typedef struct { uint64_t addr, size, part; uint8_t done, hold; } Range;
struct CbRes {
    Chunk *chunks;
    int nchunks, cchunks;
    VkDescriptorPool *pools;
    int npools, cpools;
    Range *written;
    int nwritten, cwritten;
    int32_t *wslot;    // open-addressing index of written (-1 empty), 2 * cwritten slots: note_written's lookup
    uint64_t fence;
    struct CbRes *next;   // live
};

_Thread_local CbRes *cur;
_Thread_local uint64_t cur_fence;

// Descriptor pools and full-size transient chunks go back to these lists when their command buffer completes, instead
// of being destroyed and created again for the next one: each creation is a driver memory allocation (on Windows an
// allocation, a map and a paging-fence wait on the CPU), about ten of them per frame inside the replay.
#define SPARE_POOLS 64
#define SPARE_CHUNKS 16
static PlatMutex spare_lock = PLAT_MUTEX_INIT;
static VkDescriptorPool spare_pool[SPARE_POOLS];
static Chunk spare_chunk[SPARE_CHUNKS];
static int nspare_pool, nspare_chunk;

// MKW_WB_EARLY (default 0; "ab" in the B blocks only): a range whose GPU writes are finished goes back to guest memory
// before its submission's fence. On the Deck cb_done's ~267 vk_gpu_written (merge compares of 11 MiB for ~90 KiB
// changed) took 3.0-3.2 ms a frame between the fence being reached and its waiters released, 1:1 on the race frame,
// while from the submission's last vkQueueSubmit2 to the GPU's end (2.4-3.7 ms) this thread only slept in
// vkWaitSemaphores (deck6 base.log, MKW_TRACE_TL). The same calls on the same thread, earlier; the value is done only
// after cb_done, as before.
// A range may go once its submission is recorded in full and is the oldest not done (vk_sync.c calls vk_exec_cb_early
// then; spend_oldest finds the same entry as at the fence) and every GPU write of the submission on its guest pages is
// finished and goes back in the same pass. Every writer, not only the range's own: A written back while a later part
// still writes overlapping B stays wrong after the fence too (a clear, then adds ending on B's base: B's merge copies
// nothing and A's half-done copy stays). And by pages, not bytes: vk_gpu_written acts on whole pages. Its thaw lifts
// MKW_EARLY_READ's watch of the page and fills a read-trapped one whole from the live shadow, and its write stamp is
// a page's. With another range of the page still to come, the game would read that one's bytes without the wait for
// this submission, a frame old (the Deck watches ~133 pages; counters and data share one, tdiff1), and a trapped page
// filled around a half-done write would keep it for good (at the fence the merge takes guest memory away from the
// base for the CPU's). So a range is held to the fence while a page of it also holds:
// - a write in a part the GPU has not finished: note_written keeps the newest part of each range (a part's first build
//   notes it again: vk_exec_draw_new_cb clears B.res_valid at each split), and what a chunk records (MKW_REPLAY_PAR)
//   has part UINT64_MAX;
// - a copy, clear or counter (note_gpu_write, listed in xw), finished or not: their own write-backs stay at the fence;
// - a range over the merge's limit: it has no base, so it is trapped or copied whole, at the fence;
// - a range held for any of these.
// A later submission's writes of the page wait for this one's value as before (MKW_WB_ORDER, by pages too). Inside a
// pass a page's watch is lifted at its first range, as inside cb_done.
// The range's pending entry leaves with its write-back, so from there to the fence the shadow syncs copy the CPU's
// bytes of it in plainly while the submission's last parts may still read it. With the byte merge and
// MKW_SHADOW_CPU_WINS on (the Deck's defaults) the merge let those bytes in already, all but a CPU write of the base's
// value over a byte the GPU changed; without either it kept every byte the GPU changed, or the whole range, out until
// the fence. So the switch is off unless both are on (vk_mem_wb_early_max).
// Off with VRAM mirrors (MKW_MEMORY=mirror, the default on a discrete GPU): there a shader writes the mirror and the
// bytes reach the shadow in the submission's last part (vk_mem_mirror_end), whatever part wrote them.
// Unset, the replay thread only tests the switch (an atomic load per note_written and per submission that draws). Set,
// "ab" too and then in A as in B: one call with an atomic load per note_written (~2,300 a frame, ~5-7 us in all) and
// one uncontended lock pair per submission that draws and per copy, clear or counter.
typedef struct { uint64_t fence, addr, size; } XWrite;
static PlatMutex live_lock = PLAT_MUTEX_INIT;
static CbRes *live;      // live_lock: those whose cb_done has not run
static XWrite *xw;       // live_lock: the GPU writes outside note_written, of values vk_exec_cb_early has not passed
static int nxw, cxw;
static Range *blk;       // completion thread: the page spans no write-back of the pass may touch
static Range **wbr;      // completion thread: the ranges of the value at hand
static int cblk, cwbr;
static uint64_t wb_early_max;   // the largest range that may go early (vk_mem_wb_early_max); set before the mode
// completion thread, since the last census line: ranges and bytes written back before the fence and the time it took,
// those left to the fence, and of these the ones finished and under the limit but on a page with one that had to wait
static uint64_t wbe_n, wbe_bytes, wbe_ns, wbf_n, wbf_bytes, wbe_held, wb_subs;

static int wb_early_mode(void) {
    static int m = -1;
    int v = __atomic_load_n(&m, __ATOMIC_ACQUIRE);
    if (v >= 0) return v;
    int asked = rt_knob("WB_EARLY", "0");
    uint64_t max = asked ? vk_mem_wb_early_max() : 0;
    v = vk_mirror_on || !max ? 0 : asked;
    __atomic_store_n(&wb_early_max, max, __ATOMIC_RELEASE);
    if (__atomic_exchange_n(&m, v, __ATOMIC_ACQ_REL) < 0 && asked) {
        if (v) rt_log("vk: write-backs of ranges the GPU has finished writing run before the fence%s (MKW_WB_EARLY)",
                      v == 2 ? " in the B blocks" : "");
        else if (vk_mirror_on)
            rt_log("vk: MKW_WB_EARLY is off with VRAM mirrors: GPU writes reach the shadow in a submission's last part");
        else rt_log("vk: write-backs before the fence are off: they need MKW_SHADOW_MERGE and MKW_SHADOW_CPU_WINS both on "
                    "(not ab), or the CPU's next bytes reach the shadow before the fence (MKW_WB_EARLY)");
    }
    return v;
}

void note_gpu_writer(const VkExec *ex, uint64_t addr, uint64_t size) {
    if (!wb_early_mode()) return;
    plat_mutex_lock(&live_lock);
    if (nxw == cxw) xw = grow(xw, &cxw, sizeof *xw);
    xw[nxw++] = (XWrite){ex->fence, addr, size};
    plat_mutex_unlock(&live_lock);
}

static void blk_add(uint64_t addr, uint64_t size, int *n) {   // the guest pages of [addr, addr + size)
    if (*n == cblk) blk = grow(blk, &cblk, sizeof *blk);
    uint64_t lo = addr & ~0xfffull;
    blk[(*n)++] = (Range){lo, ((addr + size + 0xfff) & ~0xfffull) - lo, 0, 0, 0};
}

static int blk_hit(const Range *w, int n) {   // a page of w is in blk[0, n)
    uint64_t lo = w->addr & ~0xfffull, hi = (w->addr + w->size + 0xfff) & ~0xfffull;
    for (int b = 0; b < n; b++)
        if (lo < blk[b].addr + blk[b].size && blk[b].addr < hi) return 1;
    return 0;
}

void vk_exec_cb_early(uint64_t fence) {   // completion thread
    int mode = wb_early_mode();
    if (!mode) return;
    CbRes *rs[16];
    int nrs = 0, nx = 0, nw = 0, keep = 0;
    plat_mutex_lock(&live_lock);
    for (int i = 0; i < nxw; i++) {
        if (xw[i].fence < fence) continue;   // done, or passed here
        if (xw[i].fence == fence) blk_add(xw[i].addr, xw[i].size, &nx);   // whatever its part: it goes back at the fence
        xw[keep++] = xw[i];
    }
    nxw = keep;
    for (CbRes *r = live; r && nrs <= 16; r = r->next)
        if (r->fence == fence) {
            if (nrs < 16) rs[nrs] = r;
            nrs++;
        }
    plat_mutex_unlock(&live_lock);
    // rs[] stay: this thread frees them (cb_done), and nothing notes into them once the value is recorded in full
    if (!RT_KNOB_ON(mode) || !nrs || nrs > 16) return;   // more than 16 recording threads: all at the fence
    uint64_t t0 = kern_now_ns(), held = 0, max = __atomic_load_n(&wb_early_max, __ATOMIC_ACQUIRE);
    for (int j = 0; j < nrs; j++)
        for (int i = 0; i < rs[j]->nwritten; i++) {
            if (nw == cwbr) wbr = grow(wbr, &cwbr, sizeof *wbr);
            wbr[nw++] = &rs[j]->written[i];
        }
    for (int wrote = 1; wrote;) {   // again while it wrote: parts ended meanwhile
        uint64_t pd = vk_sync_part_done();
        int nb = nx;   // blk[0, nx): the copies, clears and counters
        wrote = 0, held = 0;
        for (int i = 0; i < nw; i++) {
            Range *w = wbr[i];
            if (w->done) continue;
            w->hold = w->part > pd || w->size > max;
            if (w->hold) blk_add(w->addr, w->size, &nb);
        }
        for (int more = 1; more;) {   // a range on a page of a held one is held too, until none is added
            more = 0;
            for (int i = 0; i < nw; i++) {
                Range *w = wbr[i];
                if (w->done || w->hold || !blk_hit(w, nb)) continue;
                w->hold = 1, more = 1, held++;
                blk_add(w->addr, w->size, &nb);
            }
        }
        for (int i = 0; i < nw; i++) {
            Range *w = wbr[i];
            if (w->done || w->hold) continue;
            vk_gpu_written(w->addr, w->size);   // live_lock not held
            w->done = 1, wrote = 1, wbe_n++, wbe_bytes += w->size;
        }
    }
    wbe_held += held, wbe_ns += kern_now_ns() - t0;
}

static void cb_done(void *arg) {   // completion thread
    CbRes *r = arg;
    VkCtx *c = vk_ctx();
    if (wb_early_mode()) {   // on live only then (cb_res_new)
        plat_mutex_lock(&live_lock);
        for (CbRes **p = &live; *p; p = &(*p)->next)
            if (*p == r) {
                *p = r->next;
                break;
            }
        plat_mutex_unlock(&live_lock);
    }
    for (int i = 0; i < r->nwritten; i++) {
        if (r->written[i].done) continue;
        vk_gpu_written(r->written[i].addr, r->written[i].size);
        wbf_n++, wbf_bytes += r->written[i].size;
    }
    if (wb_early_mode() && ++wb_subs == 600) {
        rt_log("vk: write-backs over 600 submissions: %llu ranges (%.1f MiB) before the fence in %.2f ms a submission, "
               "%llu (%.1f MiB) at the fence, %llu held back by another write of their pages (MKW_WB_EARLY)",
               (unsigned long long)wbe_n, wbe_bytes / 1048576.0, wbe_ns / 1e6 / 600, (unsigned long long)wbf_n,
               wbf_bytes / 1048576.0, (unsigned long long)wbe_held);
        wbe_n = wbe_bytes = wbe_ns = wbf_n = wbf_bytes = wbe_held = wb_subs = 0;
    }
    for (int i = 0; i < r->npools; i++) {
        vkResetDescriptorPool(c->device, r->pools[i], 0);
        plat_mutex_lock(&spare_lock);
        int kept = nspare_pool < SPARE_POOLS;
        if (kept) spare_pool[nspare_pool++] = r->pools[i];
        plat_mutex_unlock(&spare_lock);
        if (!kept) vkDestroyDescriptorPool(c->device, r->pools[i], NULL);
    }
    for (int i = 0; i < r->nchunks; i++) {
        plat_mutex_lock(&spare_lock);
        int kept = r->chunks[i].size == CHUNK_BYTES && nspare_chunk < SPARE_CHUNKS;
        if (kept) spare_chunk[nspare_chunk++] = r->chunks[i];
        plat_mutex_unlock(&spare_lock);
        if (!kept) vmaDestroyBuffer(c->vma, r->chunks[i].buf, r->chunks[i].alloc);
    }
    free(r->written), free(r->wslot), free(r->pools), free(r->chunks), free(r);
}

CbRes *cb_res_new(VkExec *ex) {
    cur = calloc(1, sizeof *cur);
    if (!cur) rt_fatal("vk: out of memory");
    cur_fence = cur->fence = ex->fence;
    if (wb_early_mode()) {   // unset: no lock on the recording thread
        plat_mutex_lock(&live_lock);
        cur->next = live, live = cur;
        plat_mutex_unlock(&live_lock);
    }
    memset(&B, 0, sizeof B);
    vk_completion_add(ex->fence, cb_done, cur);
    return cur;
}

uint8_t *scratch(VkExec *ex, uint64_t size, VkBuffer *buf, VkDeviceSize *off) {
    CbRes *r = cb_res(ex);
    size = (size + 255) & ~255ull;
    Chunk *c = r->nchunks ? &r->chunks[r->nchunks - 1] : NULL;
    if (!c || c->used + size > c->size) {
        if (r->nchunks == r->cchunks) r->chunks = grow(r->chunks, &r->cchunks, sizeof *r->chunks);
        c = &r->chunks[r->nchunks];
        uint64_t n = size > CHUNK_BYTES ? size : CHUNK_BYTES;
        int reused = 0;
        if (n == CHUNK_BYTES) {
            plat_mutex_lock(&spare_lock);
            if (nspare_chunk) *c = spare_chunk[--nspare_chunk], reused = 1;
            plat_mutex_unlock(&spare_lock);
        }
        if (reused) {
            c->used = 0;
            r->nchunks++;
            *buf = c->buf;
            *off = 0;
            c->used = size;
            return c->map;
        }
        VkBufferCreateInfo bi = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = n,
                                 .usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT |
                                          VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT |
                                          VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT};
        VmaAllocationCreateInfo ai = {.usage = VMA_MEMORY_USAGE_AUTO_PREFER_HOST,
                                      .flags = VMA_ALLOCATION_CREATE_HOST_ACCESS_RANDOM_BIT | VMA_ALLOCATION_CREATE_MAPPED_BIT};
        VmaAllocationInfo info;
        VkResult res = vmaCreateBuffer(vk_ctx()->vma, &bi, &ai, &c->buf, &c->alloc, &info);
        if (res != VK_SUCCESS) {   // new.log, 09/11/2026: a 4 MiB chunk ended a capture replay at MKW_GPU_MEM_LIMIT=2048
            vk_mem_relieve(2 * n + (8ull << 20), "a transient buffer");
            res = vmaCreateBuffer(vk_ctx()->vma, &bi, &ai, &c->buf, &c->alloc, &info);
        }
        if (res != VK_SUCCESS) rt_fatal("vk: transient buffer of %llu bytes failed (%d)", (unsigned long long)n, (int)res);
        c->map = info.pMappedData, c->size = n, c->used = 0;
        r->nchunks++;
    }
    *buf = c->buf;
    *off = c->used;
    uint8_t *p = c->map + c->used;
    c->used += size;
    return p;
}

// A submission writes ~330 distinct ranges (rt-z5) and a race frame binds a written storage buffer on most of its
// 2,300 draws: a linear search here was 1.4 % of the replay (rt-y1). A hash of the ranges, rebuilt when the list grows.
static uint32_t wslot_of(uint64_t addr, uint64_t size, int cap) {
    return (uint32_t)(((addr ^ size * 0x9E3779B97F4A7C15ull) * 0xBF58476D1CE4E5B9ull) >> 32) & (uint32_t)(2 * cap - 1);
}

static void wslot_put(CbRes *r, int i) {
    uint32_t k = wslot_of(r->written[i].addr, r->written[i].size, r->cwritten);
    while (r->wslot[k] >= 0) k = (k + 1) & (uint32_t)(2 * r->cwritten - 1);
    r->wslot[k] = i;
}

// MKW_TRACE_WPAGE=<hex> (diagnosis): each GPU write (a written storage buffer's binding, a copy, a clear, a counter)
// covering that guest page, with the program and the submission, the first 64: which shader writes what the game
// reads early (ht2: page 0x2a9bdc000, read by main+0x56b520 every ~68 frames, a 6-13 ms wait each). An address off
// the page start: only the writes covering that byte (the page's every-frame writers would use the 64 up).
void wpage_note(const VkExec *ex, uint64_t addr, uint64_t size, const char *what) {
    static uint64_t page = 1, at;
    static int n;
    if (page == 1) {
        const char *e = cfg_get("MKW_TRACE_WPAGE");
        at = e ? strtoull(e, NULL, 16) : 0;
        page = at & ~0xfffull;
    }
    if (!page || addr >= page + 0x1000 || addr + size <= page) return;
    if ((at & 0xfff) && (at < addr || at >= addr + size)) return;
    if (__atomic_fetch_add(&n, 1, __ATOMIC_RELAXED) >= 64) return;
    const prog_t *p = ex->prog;
    rt_log("vk: written page %#llx: %s %#llx+%#llx by program %llu (stage 0 code %#llx, %u stages), submission %llu, "
           "frame %llu", (unsigned long long)page, what, (unsigned long long)addr, (unsigned long long)size,
           p ? (unsigned long long)p->serial : 0ull, p ? (unsigned long long)p->sd[0].data : 0ull, p ? p->nstage : 0u,
           (unsigned long long)ex->fence, (unsigned long long)vk_exec_presented);
}

void note_written(VkExec *ex, uint64_t addr, uint64_t size) {
    uint64_t part = wb_early_mode() ? vk_sync_part_recording() : 0;   // MKW_WB_EARLY
    wpage_note(ex, addr, size, "storage");
    CbRes *r = cb_res(ex);
    if (r->cwritten)
        for (uint32_t k = wslot_of(addr, size, r->cwritten); r->wslot[k] >= 0; k = (k + 1) & (uint32_t)(2 * r->cwritten - 1)) {
            Range *w = &r->written[r->wslot[k]];
            if (w->addr != addr || w->size != size) continue;
            if (part > w->part) w->part = part;   // the newest writer; a chunk's UINT64_MAX stays
            return;
        }
    if (r->nwritten == r->cwritten) {
        r->written = grow(r->written, &r->cwritten, sizeof *r->written);   // powers of two from 8: a mask indexes wslot
        free(r->wslot);
        if (!(r->wslot = malloc(sizeof *r->wslot * 2 * (size_t)r->cwritten))) rt_fatal("vk: out of memory");
        memset(r->wslot, 0xff, sizeof *r->wslot * 2 * (size_t)r->cwritten);
        for (int i = 0; i < r->nwritten; i++) wslot_put(r, i);
    }
    r->written[r->nwritten++] = (Range){addr, size, part, 0, 0};
    wslot_put(r, r->nwritten - 1);
    vk_mem_gpu_pending(addr, size);
}

VkDescriptorSet alloc_set(VkExec *ex, VkDescriptorSetLayout layout) {
    CbRes *r = cb_res(ex);
    VkCtx *c = vk_ctx();
    for (int attempt = 0; attempt < 2; attempt++) {
        if (r->npools) {
            VkDescriptorSetAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                                              .descriptorPool = r->pools[r->npools - 1], .descriptorSetCount = 1,
                                              .pSetLayouts = &layout};
            VkDescriptorSet set;
            VkResult res = vkAllocateDescriptorSets(c->device, &ai, &set);
            if (res == VK_SUCCESS) return set;
            if (res != VK_ERROR_OUT_OF_POOL_MEMORY && res != VK_ERROR_FRAGMENTED_POOL) rt_fatal("vk: descriptor set allocation failed (%d)", (int)res);
        }
        static const VkDescriptorPoolSize sizes[] = {
            {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 4096}, {VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2048},
            {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 4096}, {VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1024},
            {VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1024}, {VK_DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER, 256},
            {VK_DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER, 256}};
        VkDescriptorPoolCreateInfo pi = {.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 256,
                                         .poolSizeCount = sizeof sizes / sizeof sizes[0], .pPoolSizes = sizes};
        if (r->npools == r->cpools) r->pools = grow(r->pools, &r->cpools, sizeof *r->pools);
        VkDescriptorPool pool = VK_NULL_HANDLE;
        plat_mutex_lock(&spare_lock);
        if (nspare_pool) pool = spare_pool[--nspare_pool];
        plat_mutex_unlock(&spare_lock);
        if (!pool && vkCreateDescriptorPool(c->device, &pi, NULL, &pool) != VK_SUCCESS) rt_fatal("vk: descriptor pool failed");
        r->pools[r->npools++] = pool;
    }
    rt_fatal("vk: descriptor set allocation failed twice");
    return VK_NULL_HANDLE;
}

// Releases the spare pools and chunks (vk_exec_draw_shutdown).
void vk_exec_cb_shutdown(void) {
    VkCtx *c = vk_ctx();
    for (int i = 0; i < nspare_pool; i++) vkDestroyDescriptorPool(c->device, spare_pool[i], NULL);
    for (int i = 0; i < nspare_chunk; i++) vmaDestroyBuffer(c->vma, spare_chunk[i].buf, spare_chunk[i].alloc);
    nspare_pool = nspare_chunk = 0;
}

// ---- state recorded outside descriptors

void record_fixed(VkExec *ex) {
    VkCommandBuffer cb = ex->cb;
    if (ex->dirty & VK_EXEC_DIRTY_VIEWPORT) {
        float x = 0, y = 0, w = (float)ex->pass_w, h = (float)ex->pass_h;
        if (ex->has_vp) x = ex->vp[0][0], y = ex->vp[0][1], w = ex->vp[0][2], h = ex->vp[0][3];
        if (w < 1) w = 1;
        if (h < 1) h = 1;
        VkViewport v = {x, y + h, w, -h, ex->depth_range[0], ex->depth_range[1]};   // the y flip: negative height
        vkCmdSetViewportWithCount(cb, 1, &v);
        ex->recorded++;
    }
    if (ex->dirty & VK_EXEC_DIRTY_SCISSOR) {
        VkRect2D r = vk_exec_scissor(ex);
        vkCmdSetScissorWithCount(cb, 1, &r);
        ex->recorded++;
    }
    if (ex->dirty & VK_EXEC_DIRTY_DEPTH_BIAS) {
        vkCmdSetDepthBias(cb, ex->poly_offset.units, ex->poly_offset.clamp, ex->poly_offset.factor);
        ex->recorded++;
    }
    if (ex->dirty & VK_EXEC_DIRTY_BLEND_CONST) {
        vkCmdSetBlendConstants(cb, ex->blend_color);
        ex->recorded++;
    }
    if (ex->dirty & VK_EXEC_DIRTY_STENCIL) {
        for (int f = 0; f < 2; f++) {
            VkStencilFaceFlags face = f ? VK_STENCIL_FACE_BACK_BIT : VK_STENCIL_FACE_FRONT_BIT;
            vkCmdSetStencilCompareMask(cb, face, ex->st_vmask[f]);
            vkCmdSetStencilWriteMask(cb, face, ex->st_wmask[f]);
            vkCmdSetStencilReference(cb, face, ex->st_ref[f]);
            ex->recorded += 3;
        }
    }
    ex->dirty = 0;
}

uint32_t vk_exec_streams(const VkExec *ex, const VkPipeInfo *info) {
    if (!info) return 0xffff;
    uint32_t m = 0;
    for (int i = 0; i < 16; i++)
        if (info->vs_inputs >> i & 1) {
            va_st a;
            memcpy(&a, &ex->pipe.vattr[i], sizeof a);
            m |= 1u << (a.stream & 15);
        }
    return m;
}

// streams: the ones the draw's attributes read (vk_exec_streams). The others get the zero buffer: they hold whatever an
// earlier draw bound, which made two recordings of the same draw differ (MKW_REUSE check, ru15).
void bind_vertex_buffers(VkExec *ex, uint32_t streams) {
    VkBuffer vb[17];
    VkDeviceSize vo[17], vsz[17], vstr[17];
    int vcls[17] = {0};
    void *vpool[17] = {0};
    int dyn = vk_pipeline_vertex_input_dynamic();
    // A stream whose range is the one its bound buffer was resolved from, with no pool or mirror change since
    // (vk_mem_gen, read before any resolve), resolves to that buffer again: most draws change one stream or none.
    uint64_t gen = vk_mem_gen();
    int same_gen = B.vb_valid && B.vgen == gen;
    for (int b = 0; b < 17; b++) {
        vb[b] = Z.zbuf, vo[b] = 0, vsz[b] = ZERO_BYTES, vstr[b] = b < 16 ? ex->pipe.vstream[b].stride : 0;
        if (b == VK_PIPE_ZERO_BINDING || !(streams >> b & 1)) continue;
        const NVNbufferRange *r = &ex->vbuf[b];
        if (same_gen && B.vin_used >> b & 1 && B.vin[b].address == r->address && B.vin[b].size == r->size) {
            vb[b] = B.vb[b], vo[b] = B.vo[b], vsz[b] = B.vsz[b], vcls[b] = B.vcls[b], vpool[b] = B.vpool[b];
            continue;
        }
        VkMemSpan sp;
        if (!r->address || !vk_mem_resolve(r->address, 1, &sp)) continue;
        VK_MEM_USE(sp);
        uint64_t n = r->size && r->size < sp.avail ? r->size : sp.avail;
        vb[b] = sp.buffer, vo[b] = sp.offset, vsz[b] = n, vcls[b] = sp.cls, vpool[b] = sp.pool;
    }
    memcpy(B.vcls, vcls, sizeof vcls), memcpy(B.vpool, vpool, sizeof vpool);
    memcpy(B.vin, ex->vbuf, sizeof B.vin);
    B.vin_used = streams;
    B.vgen = gen;
    if (B.vb_valid && !memcmp(B.vb, vb, sizeof vb) && !memcmp(B.vo, vo, sizeof vo) && !memcmp(B.vsz, vsz, sizeof vsz) &&
        (dyn || !memcmp(B.vstr, vstr, sizeof vstr)))
        return;
    vkCmdBindVertexBuffers2(ex->cb, 0, 17, vb, vo, vsz, dyn ? NULL : vstr);
    ex->recorded++;
    for (int b = 0; b < 17; b++)
        if (vcls[b]) vk_mem_count(vcls[b], VK_MUSE_VB, vsz[b]);
    if (vk_dirty_census)
        for (int b = 0; b < 17; b++)
            if (vpool[b]) vk_mem_bound_note(vpool[b]);
    memcpy(B.vb, vb, sizeof vb), memcpy(B.vo, vo, sizeof vo), memcpy(B.vsz, vsz, sizeof vsz), memcpy(B.vstr, vstr, sizeof vstr);
    B.vb_valid = 1;
}

// ---- feedback loops (vk_exec_draw.c feedback_prepare)

// By-region barrier inside the pass: earlier attachment writes become visible to this draw's fragment shader reads.
void feedback_barrier(VkExec *ex) {
    VkMemoryBarrier2 mb = {.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER_2,
                           .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT |
                                           VK_PIPELINE_STAGE_2_EARLY_FRAGMENT_TESTS_BIT | VK_PIPELINE_STAGE_2_LATE_FRAGMENT_TESTS_BIT,
                           .srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_2_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
                           .dstStageMask = VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
                           .dstAccessMask = VK_ACCESS_2_SHADER_SAMPLED_READ_BIT};
    VkDependencyInfo di = {.sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO, .dependencyFlags = VK_DEPENDENCY_BY_REGION_BIT,
                           .memoryBarrierCount = 1, .pMemoryBarriers = &mb};
    vkCmdPipelineBarrier2(ex->cb, &di);
    ex->recorded++;
    ex->fb_dirty = 0;
    vk_exec_frame.fb_barriers++;
}

// Marks the attachments the draw with state s writes: colour targets with a nonzero effective write mask, depth with
// depth writes or the stencil test on.
void feedback_written(VkExec *ex, const VkPipeState *s) {
    if (vk_ctx()->feedback == VK_FEEDBACK_OFF) return;
    if (ex->depth.image && !(ex->fb_dirty & 0x100) && ((s->ds.dt && s->ds.dw) || s->ds.st)) ex->fb_dirty |= 0x100;
    for (uint32_t i = 0; i < ex->pass_ncolor; i++)
        if (ex->color[i].image && !(ex->fb_dirty >> i & 1) && vk_pipeline_target_wmask(s, (int)i)) ex->fb_dirty |= 1u << i;
}
