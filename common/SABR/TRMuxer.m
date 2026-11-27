#import "TRMuxer.h"
#import "lib/cocoahttpserver/HTTPServer.h"
#import "lib/cocoahttpserver/HTTPConnection.h"
#import "lib/cocoahttpserver/HTTPResponse.h"
#include <stdarg.h>

#pragma mark - byte helpers

static uint32_t RD32(const uint8_t *p) { return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3]; }
static uint64_t RD64(const uint8_t *p) { return ((uint64_t)RD32(p) << 32) | RD32(p + 4); }
static void W16(NSMutableData *d, uint16_t v) { uint8_t b[2] = { v >> 8, v }; [d appendBytes:b length:2]; }
static void W32(NSMutableData *d, uint32_t v) { uint8_t b[4] = { v >> 24, v >> 16, v >> 8, v }; [d appendBytes:b length:4]; }
static void WZ(NSMutableData *d, NSUInteger n) { [d increaseLengthBy:n]; }

static NSData *MkBox(const char *type, NSData *payload) {
    NSMutableData *d = [NSMutableData dataWithCapacity:[payload length] + 8];
    W32(d, (uint32_t)([payload length] + 8));
    [d appendBytes:type length:4];
    if (payload) [d appendData:payload];
    return d;
}

static NSData *Cat(NSData *first, ...) {
    NSMutableData *d = [NSMutableData data];
    va_list ap; va_start(ap, first);
    for (NSData *x = first; x; x = va_arg(ap, NSData *)) [d appendData:x];
    va_end(ap);
    return d;
}

// payload of the first child box of that type
static NSData *FindBox(NSData *d, const char *type) {
    const uint8_t *p = [d bytes]; size_t n = [d length], pos = 0;
    while (pos + 8 <= n) {
        uint64_t s = RD32(p + pos); size_t hdr = 8;
        if (s == 1) { if (pos + 16 > n) break; s = RD64(p + pos + 8); hdr = 16; }
        else if (s == 0) s = n - pos;
        if (s < hdr || pos + s > n) break;
        if (!memcmp(p + pos + 4, type, 4)) return [d subdataWithRange:NSMakeRange(pos + hdr, (NSUInteger)(s - hdr))];
        pos += (size_t)s;
    }
    return nil;
}

static NSArray *FindBoxes(NSData *d, const char *type) {
    NSMutableArray *out = [NSMutableArray array];
    const uint8_t *p = [d bytes]; size_t n = [d length], pos = 0;
    while (pos + 8 <= n) {
        uint64_t s = RD32(p + pos); size_t hdr = 8;
        if (s == 1) { if (pos + 16 > n) break; s = RD64(p + pos + 8); hdr = 16; }
        else if (s == 0) s = n - pos;
        if (s < hdr || pos + s > n) break;
        if (!memcmp(p + pos + 4, type, 4)) [out addObject:[d subdataWithRange:NSMakeRange(pos + hdr, (NSUInteger)(s - hdr))]];
        pos += (size_t)s;
    }
    return out;
}

static NSData *RangeGET(NSString *url, NSString *ua, uint64_t start, uint64_t end, NSInteger *code) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20.0];
    if ([ua length]) [req setValue:ua forHTTPHeaderField:@"User-Agent"];
    [req setValue:[NSString stringWithFormat:@"bytes=%llu-%llu", start, end] forHTTPHeaderField:@"Range"];
    NSHTTPURLResponse *resp = nil;
    NSData *d = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:nil];
    if (code) *code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [resp statusCode] : 0;
    return d;
}

#pragma mark - model

typedef struct { uint64_t off; uint32_t size, dur; int32_t cto; uint8_t sync; } TRSample;
typedef struct { uint8_t track; uint32_t first, count; uint64_t src; uint32_t size; double start; uint64_t out; } TRChunk;

@interface TRMuxTrack : NSObject {
@public
    NSString *url, *path;
    NSData *tkhd, *hdlr, *mhd, *dinf, *stsd;
    const char *mhdType;
    uint32_t timescale;
    NSMutableData *samples;
    uint64_t nsamples, duration, srcEnd;
    BOOL hasCto, negCto, allSync;
    int32_t minCto;
    NSMutableData *chunkOffsets; // uint64 mdat-relative, per chunk of this track in order
    NSMutableData *chunkCounts;  // uint32 samples per chunk
}
@end
@implementation TRMuxTrack
- (void)dealloc { [url release]; [path release]; [tkhd release]; [hdlr release]; [mhd release]; [dinf release]; [stsd release]; [samples release]; [chunkOffsets release]; [chunkCounts release]; [super dealloc]; }
@end

@interface TRMuxPlan : NSObject {
@public
    NSData *header;
    TRChunk *chunks;
    NSUInteger nchunks;
    uint64_t total;
    NSString *urls[2];
    NSString *paths[2];
    NSString *ua;
    uint64_t srcEnd[2];
    NSDictionary *(^refresh)(void);   // optional: fresh @{ video, audio } links when YouTube cuts the old ones off
    int refreshes;
}
- (NSString *)urlForTrack:(int)t;
- (void)refreshTrack:(int)t staleURL:(NSString *)stale;
@end
@implementation TRMuxPlan
- (void)dealloc {
    for (int i = 0; i < 2; i++) if (paths[i]) [[NSFileManager defaultManager] removeItemAtPath:paths[i] error:nil];
    [header release]; free(chunks); [urls[0] release]; [urls[1] release]; [paths[0] release]; [paths[1] release]; [ua release]; [refresh release]; [super dealloc];
}
- (NSString *)urlForTrack:(int)t { @synchronized(self) { return [[urls[t] retain] autorelease]; } }
// Links without a PO token stop working after about a minute of data: ask for new ones (one caller at a time; a caller that
// finds the link already replaced by another one just retries).
- (void)refreshTrack:(int)t staleURL:(NSString *)stale {
    @synchronized(self) {
        if (!refresh || refreshes >= 20) return;
        if (![urls[t] isEqual:stale]) return;
        refreshes++;
        NSDictionary *r = refresh();
        NSString *nv = r[@"video"], *na = r[@"audio"];
        if ([nv length] && [na length]) {
            [urls[0] release]; urls[0] = [nv copy];
            [urls[1] release]; urls[1] = [na copy];
            NSLog(@"[TubeReplacer] mux: fresh stream links (refresh %d)", refreshes);
        } else NSLog(@"[TubeReplacer] mux: could not get fresh stream links");
    }
}
@end

#pragma mark - fragment header parsing

// Returns YES when parsed; *need is set to the number of bytes required when the header was cut off.
static BOOL ParseFragment(NSData *hdr, uint64_t fragOff, NSMutableData *out, uint64_t *need) {
    const uint8_t *p = [hdr bytes]; size_t n = [hdr length], pos = 0;
    while (pos + 8 <= n) {
        uint64_t s = RD32(p + pos);
        if (s < 8) return NO;
        if (!memcmp(p + pos + 4, "moof", 4)) {
            if (pos + s > n) { *need = pos + s; return NO; }
            NSData *moof = [hdr subdataWithRange:NSMakeRange(pos + 8, (NSUInteger)s - 8)];
            for (NSData *traf in FindBoxes(moof, "traf")) {
                NSData *tfhd = FindBox(traf, "tfhd");
                if ([tfhd length] < 8) return NO;
                const uint8_t *t = [tfhd bytes];
                uint32_t tf = RD32(t) & 0xFFFFFF;
                size_t q = 8;
                uint64_t base = fragOff + pos; // default-base-is-moof (moof starts the fragment)
                uint32_t defDur = 0, defSize = 0, defFlags = 0;
                if (tf & 1) { base = RD64(t + q); q += 8; }
                if (tf & 2) q += 4;
                if (tf & 8) { defDur = RD32(t + q); q += 4; }
                if (tf & 0x10) { defSize = RD32(t + q); q += 4; }
                if (tf & 0x20) { defFlags = RD32(t + q); q += 4; }
                uint64_t next = base;
                BOOL haveNext = NO;
                for (NSData *trun in FindBoxes(traf, "trun")) {
                    const uint8_t *r = [trun bytes];
                    if ([trun length] < 8) return NO;
                    uint32_t verFlags = RD32(r), rf = verFlags & 0xFFFFFF, ver = verFlags >> 24;
                    uint32_t count = RD32(r + 4);
                    size_t o = 8;
                    uint64_t cur = next;
                    if (rf & 1) { int32_t dof = (int32_t)RD32(r + o); o += 4; cur = base + (int64_t)dof; }
                    else if (!haveNext) cur = base;
                    uint32_t firstFlags = defFlags; BOOL hasFirst = NO;
                    if (rf & 4) { firstFlags = RD32(r + o); o += 4; hasFirst = YES; }
                    for (uint32_t i = 0; i < count; i++) {
                        TRSample s2; memset(&s2, 0, sizeof s2);
                        s2.dur = defDur; s2.size = defSize;
                        uint32_t fl = (i == 0 && hasFirst) ? firstFlags : defFlags;
                        if (rf & 0x100) { if (o + 4 > [trun length]) return NO; s2.dur = RD32(r + o); o += 4; }
                        if (rf & 0x200) { if (o + 4 > [trun length]) return NO; s2.size = RD32(r + o); o += 4; }
                        if (rf & 0x400) { if (o + 4 > [trun length]) return NO; fl = RD32(r + o); o += 4; }
                        if (rf & 0x800) { if (o + 4 > [trun length]) return NO; uint32_t c = RD32(r + o); o += 4; s2.cto = ver == 0 ? (int32_t)c : (int32_t)c; }
                        s2.sync = (fl & 0x10000) ? 0 : 1;
                        s2.off = cur;
                        cur += s2.size;
                        [out appendBytes:&s2 length:sizeof s2];
                    }
                    next = cur; haveNext = YES;
                }
            }
            return YES;
        }
        pos += (size_t)s;
    }
    *need = 0;
    return NO;
}

static TRMuxTrack *LoadTrack(NSDictionary *fmt, NSString *ua, NSString **why) {
    NSString *url = fmt[@"url"];
    NSDictionary *ir = fmt[@"initRange"], *xr = fmt[@"indexRange"];
    if (![url length] || ![ir isKindOfClass:[NSDictionary class]] || ![xr isKindOfClass:[NSDictionary class]]) { *why = @"no ranges"; return nil; }
    uint64_t is = [ir[@"start"] longLongValue], ie = [ir[@"end"] longLongValue], xs = [xr[@"start"] longLongValue], xe = [xr[@"end"] longLongValue];
    NSInteger code = 0;
    NSData *head = RangeGET(url, ua, is, xe, &code);
    if (code != 200 && code != 206) { *why = [NSString stringWithFormat:@"init http %ld", (long)code]; return nil; }
    if ([head length] < xe - is + 1) { *why = @"short init"; return nil; }
    NSData *initData = [head subdataWithRange:NSMakeRange(0, (NSUInteger)(ie - is + 1))];
    NSData *sidxData = [head subdataWithRange:NSMakeRange((NSUInteger)(xs - is), (NSUInteger)(xe - xs + 1))];

    TRMuxTrack *t = [[[TRMuxTrack alloc] init] autorelease];
    NSData *moov = FindBox(initData, "moov"), *trak = FindBox(moov, "trak"), *mdia = FindBox(trak, "mdia");
    NSData *mdhd = FindBox(mdia, "mdhd"), *minf = FindBox(mdia, "minf"), *stbl = FindBox(minf, "stbl");
    t->tkhd = [FindBox(trak, "tkhd") retain];
    t->hdlr = [FindBox(mdia, "hdlr") retain];
    t->dinf = [FindBox(minf, "dinf") retain];
    t->stsd = [FindBox(stbl, "stsd") retain];
    NSData *vmhd = FindBox(minf, "vmhd"), *smhd = FindBox(minf, "smhd");
    t->mhd = [(vmhd ?: smhd) retain];
    t->mhdType = vmhd ? "vmhd" : "smhd";
    if (!t->tkhd || !t->hdlr || !t->dinf || !t->stsd || !t->mhd || [mdhd length] < 20) { *why = @"unexpected moov"; return nil; }
    const uint8_t *mh = [mdhd bytes];
    t->timescale = mh[0] == 1 ? RD32(mh + 20) : RD32(mh + 12);
    if (!t->timescale) { *why = @"no timescale"; return nil; }
    t->url = [url copy];

    // sidx
    NSData *sidx = FindBox(sidxData, "sidx");
    if ([sidx length] < 24) { *why = @"no sidx"; return nil; }
    const uint8_t *sp = [sidx bytes];
    size_t o = 4 + 4 + 4; // ver/flags, ref id, timescale
    uint64_t firstOffset;
    if (sp[0] == 0) { o += 8; firstOffset = RD32(sp + o - 4); } else { o += 16; firstOffset = RD64(sp + o - 8); }
    o += 2; // reserved
    uint32_t refs = ((uint32_t)sp[o] << 8) | sp[o + 1]; o += 2;
    if (refs == 0 || refs > 1500 || o + (size_t)refs * 12 > [sidx length]) { *why = @"bad sidx"; return nil; }
    uint64_t pos = xe + 1 + firstOffset;
    NSMutableArray *offs = [NSMutableArray array], *sizes = [NSMutableArray array];
    for (uint32_t i = 0; i < refs; i++) {
        uint32_t sz = RD32(sp + o) & 0x7FFFFFFF; o += 12;
        [offs addObject:@(pos)]; [sizes addObject:@(sz)];
        pos += sz;
    }
    t->srcEnd = pos;

    // every fragment's header: its samples' sizes, durations and flags (parallel, small ranges)
    NSMutableArray *results = [NSMutableArray arrayWithCapacity:refs];
    for (uint32_t i = 0; i < refs; i++) [results addObject:[NSNull null]];
    __block NSString *failure = nil;
    dispatch_semaphore_t limit = dispatch_semaphore_create(6);
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t q = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    void (^fetchFrag)(uint32_t) = ^(uint32_t i) {
        uint64_t fo = [offs[i] unsignedLongLongValue]; uint32_t fs = [sizes[i] unsignedIntValue];
        uint64_t want = MIN((uint64_t)fs, 4096ULL);
        NSMutableData *out = [NSMutableData data];
        BOOL ok = NO;
        NSString *err = nil;
        for (int attempt = 0; attempt < 3 && !ok; attempt++) {
            NSInteger c = 0;
            NSData *h = RangeGET(url, ua, fo, fo + want - 1, &c);
            if ((c != 200 && c != 206) || ![h length]) { err = [NSString stringWithFormat:@"fragment %u http %ld", i, (long)c]; continue; }
            uint64_t need = 0;
            [out setLength:0];
            if (ParseFragment(h, fo, out, &need)) { ok = YES; break; }
            err = [NSString stringWithFormat:@"fragment %u unreadable", i];
            if (need > want && need <= fs) want = need;
        }
        @synchronized(results) { if (ok) results[i] = out; else if (!failure) failure = err; }
    };
    // the last fragment first: YouTube cuts links without a PO token off after about a minute
    fetchFrag(refs - 1);
    for (uint32_t i = 0; i + 1 < refs && !failure; i++) {
        dispatch_semaphore_wait(limit, DISPATCH_TIME_FOREVER);
        dispatch_group_async(group, q, ^{ if (!failure) fetchFrag(i); dispatch_semaphore_signal(limit); });
    }
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    dispatch_release(group); dispatch_release(limit);
    if (failure) { *why = failure; return nil; }

    t->samples = [[NSMutableData alloc] init];
    t->allSync = YES; t->minCto = INT32_MAX;
    for (id r in results) {
        if (![r isKindOfClass:[NSData class]]) { *why = @"missing fragment"; return nil; }
        [t->samples appendData:r];
    }
    t->nsamples = [t->samples length] / sizeof(TRSample);
    const TRSample *sm = [t->samples bytes];
    for (uint64_t i = 0; i < t->nsamples; i++) {
        t->duration += sm[i].dur;
        if (sm[i].cto) t->hasCto = YES;
        if (sm[i].cto < 0) t->negCto = YES;
        if (sm[i].cto < t->minCto) t->minCto = sm[i].cto;
        if (!sm[i].sync) t->allSync = NO;
    }
    if (!t->nsamples) { *why = @"no samples"; return nil; }
    return t;
}

#pragma mark - moov

static NSData *BuildTrak(TRMuxTrack *t, int trackID, BOOL video, uint64_t durMs) {
    // tkhd: same as the source but with our id, duration and flags
    NSMutableData *tk = [NSMutableData dataWithData:t->tkhd];
    uint8_t *tp = [tk mutableBytes];
    tp[1] = 0; tp[2] = 0; tp[3] = 3;
    if (tp[0] == 1) { tp[20] = trackID >> 24; tp[21] = trackID >> 16; tp[22] = trackID >> 8; tp[23] = trackID;
        for (int i = 0; i < 8; i++) tp[28 + i] = (uint8_t)(durMs >> (56 - 8 * i)); }
    else { tp[12] = trackID >> 24; tp[13] = trackID >> 16; tp[14] = trackID >> 8; tp[15] = trackID;
        tp[20] = durMs >> 24; tp[21] = durMs >> 16; tp[22] = durMs >> 8; tp[23] = durMs; }

    NSMutableData *mdhd = [NSMutableData data];
    W32(mdhd, 0); W32(mdhd, 0); W32(mdhd, 0); W32(mdhd, t->timescale); W32(mdhd, (uint32_t)t->duration); W16(mdhd, 0x55C4); W16(mdhd, 0);

    const TRSample *sm = [t->samples bytes];
    NSMutableData *stts = [NSMutableData data]; W32(stts, 0);
    { NSMutableData *e = [NSMutableData data]; uint32_t n = 0;
      for (uint64_t i = 0; i < t->nsamples;) { uint64_t j = i; while (j < t->nsamples && sm[j].dur == sm[i].dur) j++; W32(e, (uint32_t)(j - i)); W32(e, sm[i].dur); n++; i = j; }
      W32(stts, n); [stts appendData:e]; }
    NSData *ctts = nil;
    if (t->hasCto) {
        NSMutableData *c = [NSMutableData data]; W32(c, t->negCto ? 0x01000000 : 0);
        NSMutableData *e = [NSMutableData data]; uint32_t n = 0;
        for (uint64_t i = 0; i < t->nsamples;) { uint64_t j = i; while (j < t->nsamples && sm[j].cto == sm[i].cto) j++; W32(e, (uint32_t)(j - i)); W32(e, (uint32_t)sm[i].cto); n++; i = j; }
        W32(c, n); [c appendData:e]; ctts = MkBox("ctts", c);
    }
    NSData *stss = nil;
    if (!t->allSync) {
        NSMutableData *s = [NSMutableData data]; W32(s, 0);
        NSMutableData *e = [NSMutableData data]; uint32_t n = 0;
        for (uint64_t i = 0; i < t->nsamples; i++) if (sm[i].sync) { W32(e, (uint32_t)(i + 1)); n++; }
        W32(s, n); [s appendData:e]; stss = MkBox("stss", s);
    }
    NSMutableData *stsc = [NSMutableData data]; W32(stsc, 0);
    { NSMutableData *e = [NSMutableData data]; uint32_t n = 0, prev = 0;
      const uint32_t *cc = [t->chunkCounts bytes]; NSUInteger nc = [t->chunkCounts length] / 4;
      for (NSUInteger i = 0; i < nc; i++) { if (cc[i] != prev) { W32(e, (uint32_t)(i + 1)); W32(e, cc[i]); W32(e, 1); n++; prev = cc[i]; } }
      W32(stsc, n); [stsc appendData:e]; }
    NSMutableData *stsz = [NSMutableData data]; W32(stsz, 0); W32(stsz, 0); W32(stsz, (uint32_t)t->nsamples);
    for (uint64_t i = 0; i < t->nsamples; i++) W32(stsz, sm[i].size);
    NSMutableData *stco = [NSMutableData data]; W32(stco, 0);
    { NSUInteger nc = [t->chunkOffsets length] / 8; const uint64_t *co = [t->chunkOffsets bytes]; W32(stco, (uint32_t)nc);
      for (NSUInteger i = 0; i < nc; i++) W32(stco, (uint32_t)co[i]); }

    NSMutableData *stblp = [NSMutableData data];
    [stblp appendData:MkBox("stsd", t->stsd)]; [stblp appendData:MkBox("stts", stts)];
    if (ctts) [stblp appendData:ctts];
    if (stss) [stblp appendData:stss];
    [stblp appendData:MkBox("stsc", stsc)]; [stblp appendData:MkBox("stsz", stsz)]; [stblp appendData:MkBox("stco", stco)];
    NSData *minf = MkBox("minf", Cat(MkBox(t->mhdType, t->mhd), MkBox("dinf", t->dinf), MkBox("stbl", stblp), nil));
    NSData *mdia = MkBox("mdia", Cat(MkBox("mdhd", mdhd), MkBox("hdlr", t->hdlr), minf, nil));
    NSData *edts = nil;
    if (video && t->minCto > 0) {
        NSMutableData *el = [NSMutableData data]; W32(el, 0); W32(el, 1); W32(el, (uint32_t)durMs); W32(el, (uint32_t)t->minCto); W16(el, 1); W16(el, 0);
        edts = MkBox("edts", MkBox("elst", el));
    }
    return MkBox("trak", Cat(MkBox("tkhd", tk), edts ?: [NSData data], mdia, nil));
}

static NSData *BuildMoov(TRMuxTrack *v, TRMuxTrack *a, uint64_t durMs) {
    NSMutableData *mv = [NSMutableData data];
    W32(mv, 0); W32(mv, 0); W32(mv, 0); W32(mv, 1000); W32(mv, (uint32_t)durMs); W32(mv, 0x00010000); W16(mv, 0x0100); WZ(mv, 10);
    uint32_t m[9] = { 0x00010000, 0, 0, 0, 0x00010000, 0, 0, 0, 0x40000000 };
    for (int i = 0; i < 9; i++) W32(mv, m[i]);
    WZ(mv, 24); W32(mv, 3);
    return MkBox("moov", Cat(MkBox("mvhd", mv), BuildTrak(v, 1, YES, durMs), BuildTrak(a, 2, NO, durMs), nil));
}

#pragma mark - plan

static int ChunkCompare(const void *x, const void *y) {
    const TRChunk *a = x, *b = y;
    if (a->start < b->start) return -1;
    if (a->start > b->start) return 1;
    return (int)a->track - (int)b->track;
}

static void MakeChunks(TRMuxTrack *t, int index, NSMutableData *all) {
    const TRSample *sm = [t->samples bytes];
    t->chunkOffsets = [[NSMutableData alloc] init];
    t->chunkCounts = [[NSMutableData alloc] init];
    uint64_t time = 0;
    for (uint64_t i = 0; i < t->nsamples;) {
        uint64_t j = i, dur = 0, bytes = 0;
        while (j < t->nsamples && (j == i || (sm[j].off == sm[j - 1].off + sm[j - 1].size && dur < t->timescale / 2))) {
            dur += sm[j].dur; bytes += sm[j].size; j++;
        }
        TRChunk c; memset(&c, 0, sizeof c);
        c.track = index; c.first = (uint32_t)i; c.count = (uint32_t)(j - i); c.src = sm[i].off; c.size = (uint32_t)bytes;
        c.start = (double)time / t->timescale;
        [all appendBytes:&c length:sizeof c];
        time += dur; i = j;
    }
}

static TRMuxPlan *PlanFromTracks(TRMuxTrack *v, TRMuxTrack *a, NSString *ua, NSString **why) {
    NSMutableData *all = [NSMutableData data];
    MakeChunks(v, 0, all); MakeChunks(a, 1, all);
    NSUInteger n = [all length] / sizeof(TRChunk);
    TRChunk *chunks = malloc(n * sizeof(TRChunk));
    memcpy(chunks, [all bytes], n * sizeof(TRChunk));
    qsort(chunks, n, sizeof(TRChunk), ChunkCompare);
    uint64_t off = 0;
    TRMuxTrack *tr[2] = { v, a };
    // chunk lists in output order (indexes are per track, in the order of the sorted array = their own order)
    for (NSUInteger i = 0; i < n; i++) {
        chunks[i].out = off;
        TRMuxTrack *t = tr[chunks[i].track];
        [t->chunkOffsets appendBytes:&off length:8];
        uint32_t cnt = chunks[i].count; [t->chunkCounts appendBytes:&cnt length:4];
        off += chunks[i].size;
    }
    if (off + 4096ULL > 0xFFFFFFF0ULL) { free(chunks); *why = @"too large"; return nil; }
    uint64_t durMs = (uint64_t)MAX((double)v->duration / v->timescale, (double)a->duration / a->timescale) * 1000;

    NSData *ftyp = MkBox("ftyp", ({ NSMutableData *f = [NSMutableData data]; [f appendBytes:"isom" length:4]; W32(f, 512);
        [f appendBytes:"isomiso2avc1mp41" length:16]; f; }));
    // chunk offsets are relative to the mdat payload; the header size shifts them once it is known
    NSData *moov0 = BuildMoov(v, a, durMs);
    uint64_t base = [ftyp length] + [moov0 length] + 8;
    for (int k = 0; k < 2; k++) {
        uint64_t *co = [tr[k]->chunkOffsets mutableBytes]; NSUInteger nc = [tr[k]->chunkOffsets length] / 8;
        for (NSUInteger i = 0; i < nc; i++) co[i] += base;
    }
    NSData *moov = BuildMoov(v, a, durMs);
    NSMutableData *header = [NSMutableData dataWithData:ftyp];
    [header appendData:moov];
    W32(header, (uint32_t)(off + 8)); [header appendBytes:"mdat" length:4];

    TRMuxPlan *p = [[[TRMuxPlan alloc] init] autorelease];
    p->header = [header retain]; p->chunks = chunks; p->nchunks = n; p->total = [header length] + off;
    p->urls[0] = [v->url retain]; p->urls[1] = [a->url retain]; p->paths[0] = [v->path retain]; p->paths[1] = [a->path retain]; p->ua = [ua copy];
    p->srcEnd[0] = v->srcEnd; p->srcEnd[1] = a->srcEnd;
    return p;
}

static TRMuxPlan *BuildPlan(NSDictionary *video, NSDictionary *audio, NSString *ua, NSString **why) {
    TRMuxTrack *v = LoadTrack(video, ua, why);
    if (!v) { *why = [@"video: " stringByAppendingString:*why ?: @"?"]; return nil; }
    TRMuxTrack *a = LoadTrack(audio, ua, why);
    if (!a) { *why = [@"audio: " stringByAppendingString:*why ?: @"?"]; return nil; }
    return PlanFromTracks(v, a, ua, why);
}

// A track whose fragments were downloaded already (SABR): they are written to one file and read back from it.
static TRMuxTrack *LoadTrackLocal(NSData *initData, NSArray *frags, NSString *path, NSString **why) {
    TRMuxTrack *t = [[[TRMuxTrack alloc] init] autorelease];
    NSData *moov = FindBox(initData, "moov"), *trak = FindBox(moov, "trak"), *mdia = FindBox(trak, "mdia");
    NSData *mdhd = FindBox(mdia, "mdhd"), *minf = FindBox(mdia, "minf"), *stbl = FindBox(minf, "stbl");
    t->tkhd = [FindBox(trak, "tkhd") retain];
    t->hdlr = [FindBox(mdia, "hdlr") retain];
    t->dinf = [FindBox(minf, "dinf") retain];
    t->stsd = [FindBox(stbl, "stsd") retain];
    NSData *vmhd = FindBox(minf, "vmhd"), *smhd = FindBox(minf, "smhd");
    t->mhd = [(vmhd ?: smhd) retain];
    t->mhdType = vmhd ? "vmhd" : "smhd";
    if (!t->tkhd || !t->hdlr || !t->dinf || !t->stsd || !t->mhd || [mdhd length] < 20) { *why = @"unexpected moov"; return nil; }
    const uint8_t *mh = [mdhd bytes];
    t->timescale = mh[0] == 1 ? RD32(mh + 20) : RD32(mh + 12);
    if (!t->timescale) { *why = @"no timescale"; return nil; }
    t->path = [path copy];
    [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { *why = @"no temp file"; return nil; }
    t->samples = [[NSMutableData alloc] init];
    uint64_t pos = 0;
    for (NSData *f in frags) {
        uint64_t need = 0;
        NSMutableData *out = [NSMutableData data];
        if (!ParseFragment(f, pos, out, &need)) { [fh closeFile]; *why = @"unreadable fragment"; return nil; }
        [t->samples appendData:out];
        [fh writeData:f];
        pos += [f length];
    }
    [fh closeFile];
    t->srcEnd = pos;
    t->allSync = YES; t->minCto = INT32_MAX;
    t->nsamples = [t->samples length] / sizeof(TRSample);
    const TRSample *sm = [t->samples bytes];
    for (uint64_t i = 0; i < t->nsamples; i++) {
        t->duration += sm[i].dur;
        if (sm[i].cto) t->hasCto = YES;
        if (sm[i].cto < 0) t->negCto = YES;
        if (sm[i].cto < t->minCto) t->minCto = sm[i].cto;
        if (!sm[i].sync) t->allSync = NO;
    }
    if (!t->nsamples) { *why = @"no samples"; return nil; }
    return t;
}

#pragma mark - response / server

@interface TRMuxResponse : NSObject <TRHTTPResponse> {
    TRMuxPlan *plan;
    UInt64 offset;
    TRHTTPConnection *connection;
    NSThread *thread;
    NSData *buf[2];
    uint64_t bufStart[2];
    BOOL inflight[2], failed;
    int retries[2];
}
- (id)initWithPlan:(TRMuxPlan *)p connection:(TRHTTPConnection *)c;
@end

@implementation TRMuxResponse
- (id)initWithPlan:(TRMuxPlan *)p connection:(TRHTTPConnection *)c {
    if ((self = [super init])) { plan = [p retain]; connection = c; thread = [[NSThread currentThread] retain]; }
    return self;
}
- (void)dealloc { [plan release]; [thread release]; [buf[0] release]; [buf[1] release]; [super dealloc]; }
- (void)connectionDidClose { @synchronized(self) { connection = nil; } }
- (UInt64)contentLength { return plan->total; }
- (UInt64)offset { return offset; }
- (void)setOffset:(UInt64)o { offset = o; }
- (BOOL)isDone { return failed || offset >= plan->total; }

- (void)wake {
    TRHTTPConnection *c;
    @synchronized(self) { c = connection; }
    if (c) [c performSelector:@selector(responseHasAvailableData) onThread:thread withObject:nil waitUntilDone:NO];
}

- (void)fetchTrack:(int)t from:(uint64_t)src length:(uint64_t)len {
    inflight[t] = YES;
    uint64_t end = MIN(src + len, plan->srcEnd[t]);
    NSString *ua = plan->ua;
    [self retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger code = 0;
        NSData *d = nil;
        for (int attempt = 0; attempt < 3; attempt++) {
            NSString *url = [plan urlForTrack:t];
            d = RangeGET(url, ua, src, end - 1, &code);
            if ((code == 200 || code == 206) && [d length]) break;
            NSLog(@"[TubeReplacer] mux: track %d http %ld at byte %llu, attempt %d", t, (long)code, src, attempt + 1);
            if (plan->refresh && attempt < 2) [plan refreshTrack:t staleURL:url];
            else if (attempt < 2) [NSThread sleepForTimeInterval:0.5];
        }
        @synchronized(self) {
            inflight[t] = NO;
            if ((code == 200 || code == 206) && [d length]) {
                [buf[t] release]; buf[t] = [d retain]; bufStart[t] = src; retries[t] = 0;
            } else if (++retries[t] > 2) {
                NSLog(@"[TubeReplacer] mux: source http %ld at %llu, giving up", (long)code, src);
                failed = YES;
            }
        }
        [self wake];
        [self release];
    });
}

- (NSData *)readDataOfLength:(NSUInteger)length {
    @synchronized(self) {
        if (failed || offset >= plan->total) return nil;
        uint64_t hl = [plan->header length];
        if (offset < hl) {
            NSUInteger n = (NSUInteger)MIN((uint64_t)length, hl - offset);
            NSData *d = [plan->header subdataWithRange:NSMakeRange((NSUInteger)offset, n)];
            offset += n; return d;
        }
        uint64_t mo = offset - hl;
        NSUInteger lo = 0, hi = plan->nchunks;
        while (lo + 1 < hi) { NSUInteger mid = (lo + hi) / 2; if (plan->chunks[mid].out <= mo) lo = mid; else hi = mid; }
        const TRChunk *c = &plan->chunks[lo];
        uint64_t within = mo - c->out, src = c->src + within;
        uint64_t n = MIN((uint64_t)length, (uint64_t)c->size - within);
        int t = c->track;
        if (buf[t] && src >= bufStart[t] && src < bufStart[t] + [buf[t] length]) {
            n = MIN(n, bufStart[t] + [buf[t] length] - src);
            NSData *d = [buf[t] subdataWithRange:NSMakeRange((NSUInteger)(src - bufStart[t]), (NSUInteger)n)];
            offset += n; return d;
        }
        if (plan->paths[t]) {
            // downloaded already: read the window from the file
            NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:plan->paths[t]];
            uint64_t len = MIN(plan->srcEnd[t] - src, MAX((uint64_t)(c->size - within), 2048ULL * 1024));
            [fh seekToFileOffset:src];
            NSData *d = [fh readDataOfLength:(NSUInteger)len];
            [fh closeFile];
            if (![d length]) { failed = YES; return nil; }
            [buf[t] release]; buf[t] = [d retain]; bufStart[t] = src;
            NSUInteger k = (NSUInteger)MIN(n, (uint64_t)[d length]);
            offset += k;
            return [d subdataWithRange:NSMakeRange(0, k)];
        }
        if (!inflight[t]) [self fetchTrack:t from:src length:MAX((uint64_t)(c->size - within), t == 0 ? 1536ULL * 1024 : 256ULL * 1024)];
        return nil;
    }
}
@end

@interface TRMuxJob : NSObject { @public dispatch_semaphore_t done; TRMuxPlan *plan; NSString *why; BOOL finished; } @end
@implementation TRMuxJob
- (id)init { if ((self = [super init])) done = dispatch_semaphore_create(0); return self; }
- (void)dealloc { dispatch_release(done); [plan release]; [why release]; [super dealloc]; }
@end


@interface TRMuxTextResponse : NSObject <TRHTTPResponse> { NSData *data; NSString *mime; UInt64 offset; }
- (id)initWithText:(NSString *)t mime:(NSString *)m;
@end
@implementation TRMuxTextResponse
- (id)initWithText:(NSString *)t mime:(NSString *)m { if ((self = [super init])) { data = [[t dataUsingEncoding:NSUTF8StringEncoding] retain]; mime = [m copy]; } return self; }
- (void)dealloc { [data release]; [mime release]; [super dealloc]; }
- (UInt64)contentLength { return [data length]; }
- (UInt64)offset { return offset; }
- (void)setOffset:(UInt64)o { offset = o; }
- (BOOL)isDone { return offset >= [data length]; }
- (NSDictionary *)httpHeaders { return @{ @"Content-Type": mime ?: @"text/plain", @"Cache-Control": @"no-cache" }; }
- (NSData *)readDataOfLength:(NSUInteger)length {
    if (offset >= [data length]) return nil;
    NSUInteger n = MIN(length, (NSUInteger)([data length] - offset));
    NSData *d = [data subdataWithRange:NSMakeRange((NSUInteger)offset, n)]; offset += n; return d;
}
@end


#pragma mark - chunking proxy (plain progressive streams)

// One proxied stream: the app asks 127.0.0.1 for ranges; each is fetched from YouTube in small ranged requests, and
// when YouTube answers 403 / an error the stream URL is refreshed (refresh block) and the same range retried.
@interface TRProxySrc : NSObject {
@public
    NSString *url, *ua, *label;
    uint64_t total, served;
    NSString *(^refresh)(void);
    int refreshes;
}
@end
@implementation TRProxySrc
- (void)dealloc { [url release]; [ua release]; [label release]; [refresh release]; [super dealloc]; }
@end

#define TR_PROXY_CHUNK (1536ULL * 1024)

@interface TRProxyResponse : NSObject <TRHTTPResponse> {
    TRProxySrc *src;
    UInt64 offset;
    TRHTTPConnection *connection;
    NSThread *thread;
    NSData *buf, *nxt;
    uint64_t bufStart, nxtStart, inflightStart;
    BOOL inflight, failed;
    int retries;
}
- (id)initWithSrc:(TRProxySrc *)s connection:(TRHTTPConnection *)c;
@end

@implementation TRProxyResponse
- (id)initWithSrc:(TRProxySrc *)s connection:(TRHTTPConnection *)c {
    if ((self = [super init])) { src = [s retain]; connection = c; thread = [[NSThread currentThread] retain]; }
    return self;
}
- (void)dealloc { [src release]; [thread release]; [buf release]; [nxt release]; [super dealloc]; }
- (void)connectionDidClose { @synchronized(self) { connection = nil; } }
- (UInt64)contentLength { return src->total; }
- (UInt64)offset { return offset; }
- (void)setOffset:(UInt64)o { offset = o; }
- (BOOL)isDone { return failed || offset >= src->total; }
- (NSDictionary *)httpHeaders { return @{ @"Content-Type": @"video/mp4", @"Accept-Ranges": @"bytes" }; }

- (void)wake {
    TRHTTPConnection *c;
    @synchronized(self) { c = connection; }
    if (c) [c performSelector:@selector(responseHasAvailableData) onThread:thread withObject:nil waitUntilDone:NO];
}

- (void)fetchFrom:(uint64_t)from {
    inflight = YES; inflightStart = from;
    uint64_t end = MIN(from + TR_PROXY_CHUNK, src->total) - 1;
    [self retain];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSInteger code = 0;
        NSData *d = nil;
        for (int attempt = 0; attempt < 3; attempt++) {
            NSString *url, *ua;
            @synchronized(src) { url = [[src->url retain] autorelease]; ua = [[src->ua retain] autorelease]; }
            d = RangeGET(url, ua, from, end, &code);
            if ((code == 200 || code == 206) && [d length]) break;
            NSLog(@"[TubeReplacer] proxy: %@ http %ld at byte %llu (%llu served so far), attempt %d", src->label, (long)code, from, src->served, attempt + 1);
            if (src->refresh && attempt < 2) {
                NSString *nu = src->refresh();
                if ([nu length]) { @synchronized(src) { [src->url release]; src->url = [nu copy]; src->refreshes++; } NSLog(@"[TubeReplacer] proxy: %@ got a fresh stream URL", src->label); }
                else NSLog(@"[TubeReplacer] proxy: %@ could not refresh the stream URL", src->label);
            } else [NSThread sleepForTimeInterval:0.5];
        }
        @synchronized(self) {
            inflight = NO;
            if ((code == 200 || code == 206) && [d length]) {
                if (code == 200 && from > 0) { failed = YES; }   // the server ignored the range
                else {
                    retries = 0;
                    @synchronized(src) { src->served += [d length]; }
                    if (buf && from == bufStart + [buf length]) { [nxt release]; nxt = [d retain]; nxtStart = from; }
                    else { [buf release]; buf = [d retain]; bufStart = from; }
                }
            } else if (++retries > 1) {
                NSLog(@"[TubeReplacer] proxy: %@ giving up at byte %llu (http %ld)", src->label, from, (long)code);
                failed = YES;
            }
        }
        [self wake];
        [self release];
    });
}

- (NSData *)readDataOfLength:(NSUInteger)length {
    @synchronized(self) {
        if (failed || offset >= src->total) return nil;
        for (int pass = 0; pass < 2; pass++) {
            if (buf && offset >= bufStart && offset < bufStart + [buf length]) {
                uint64_t end = bufStart + [buf length];
                NSUInteger n = (NSUInteger)MIN((uint64_t)length, end - offset);
                NSData *d = [buf subdataWithRange:NSMakeRange((NSUInteger)(offset - bufStart), n)];
                offset += n;
                if (end - offset < 512 * 1024 && end < src->total && !inflight && !nxt) [self fetchFrom:end];
                return d;
            }
            if (nxt && offset >= nxtStart && offset < nxtStart + [nxt length]) {
                [buf release]; buf = nxt; bufStart = nxtStart; nxt = nil;
                continue;
            }
            break;
        }
        if (!inflight) { [nxt release]; nxt = nil; [self fetchFrom:offset]; }
        return nil;
    }
}
@end

// total length from Content-Range of a 1-byte probe
static uint64_t ProbeLength(NSString *url, NSString *ua) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    if ([ua length]) [req setValue:ua forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"bytes=0-0" forHTTPHeaderField:@"Range"];
    NSHTTPURLResponse *resp = nil;
    [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:nil];
    if (![resp isKindOfClass:[NSHTTPURLResponse class]]) return 0;
    NSString *cr = [[resp allHeaderFields] objectForKey:@"Content-Range"];
    NSRange r = [cr rangeOfString:@"/" options:NSBackwardsSearch];
    if (r.location != NSNotFound) return strtoull([[cr substringFromIndex:r.location + 1] UTF8String], NULL, 10);
    return 0;
}

@interface TRMuxConnection : TRHTTPConnection
@end

static NSMutableDictionary *gPlans = nil;
static NSMutableArray *gPlanOrder = nil;

@implementation TRMuxConnection
- (NSObject<TRHTTPResponse> *)httpResponseForMethod:(NSString *)method URI:(NSString *)path {
    NSString *p = [[path componentsSeparatedByString:@"?"] objectAtIndex:0];
    NSString *name = [[p lastPathComponent] stringByDeletingPathExtension];
    TRMuxPlan *plan = nil;
    id entry = nil;
    @synchronized([TRMuxConnection class]) { entry = [[gPlans[name] retain] autorelease]; }
    if ([entry isKindOfClass:[TRProxySrc class]]) {
        return [[[TRProxyResponse alloc] initWithSrc:entry connection:self] autorelease];
    } else if ([entry isKindOfClass:[TRMuxJob class]]) {
        TRMuxJob *job = (TRMuxJob *)entry;
        dispatch_semaphore_wait(job->done, dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_SEC));
        @synchronized (job) { plan = [[job->plan retain] autorelease]; }
        if (!plan) { NSLog(@"[TubeReplacer] mux: local job not ready / failed (%@)", job->why ?: @"timeout"); return nil; }
        @synchronized([TRMuxConnection class]) { for (NSString *k in [gPlans allKeys]) if (gPlans[k] == entry) gPlans[k] = plan; }
    } else if ([entry isKindOfClass:[NSDictionary class]] && entry[@"text"]) {
        return [[[TRMuxTextResponse alloc] initWithText:entry[@"text"] mime:entry[@"mime"]] autorelease];
    } else if ([entry isKindOfClass:[NSDictionary class]]) {
        // lazy entry: built on the first request (a few seconds), then kept
        NSString *why = nil;
        plan = BuildPlan(entry[@"video"], entry[@"audio"], entry[@"ua"], &why);
        if (!plan) { NSLog(@"[TubeReplacer] mux: lazy build failed: %@", why); return nil; }
        @synchronized([TRMuxConnection class]) { gPlans[name] = plan; }
    } else plan = entry;
    if (!plan) return nil;
    return [[[TRMuxResponse alloc] initWithPlan:plan connection:self] autorelease];
}
@end

static TRHTTPServer *gServer = nil;
static UInt16 gPort = 0;
static dispatch_semaphore_t gReady;

@interface TRMuxRunner : NSObject
+ (void)run:(id)unused;
@end
@implementation TRMuxRunner
+ (void)run:(id)unused {
    @autoreleasepool {
        gServer = [[TRHTTPServer alloc] init];
        [gServer setConnectionClass:[TRMuxConnection class]];
        NSError *err = nil;
        if (![gServer start:&err]) NSLog(@"[TubeReplacer] mux: server failed to start: %@", err);
        gPort = [gServer port];
        dispatch_semaphore_signal(gReady);
        NSRunLoop *rl = [NSRunLoop currentRunLoop];
        { Class mp = NSClassFromString(@"NSMachPort"); // iOS 8 CoreFoundation lacks the class symbol the SDK links against
            if (mp) [rl addPort:[mp performSelector:@selector(port)] forMode:NSDefaultRunLoopMode];
            else [NSTimer scheduledTimerWithTimeInterval:1e6 target:[NSNull null] selector:@selector(self) userInfo:nil repeats:YES]; }
        while ([rl runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]) {}
    }
}
@end

static BOOL EnsureServer(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gPlans = [[NSMutableDictionary alloc] init];
        gPlanOrder = [[NSMutableArray alloc] init];
        gReady = dispatch_semaphore_create(0);
        [NSThread detachNewThreadSelector:@selector(run:) toTarget:[TRMuxRunner class] withObject:nil];
        dispatch_semaphore_wait(gReady, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    });
    return gPort != 0;
}

NSDictionary *TRMuxCreate(NSDictionary *video, NSDictionary *audio, NSString *ua, NSString **why) {
    NSString *reason = nil;
    if (!EnsureServer()) { if (why) *why = @"no local server"; return nil; }
    TRMuxPlan *plan = BuildPlan(video, audio, ua, &reason);
    if (!plan) { if (why) *why = reason; return nil; }
    NSString *name = [NSString stringWithFormat:@"%08x%08x", arc4random(), arc4random()];
    @synchronized([TRMuxConnection class]) {
        gPlans[name] = plan; [gPlanOrder addObject:name];
        while ([gPlanOrder count] > 8) { [gPlans removeObjectForKey:gPlanOrder[0]]; [gPlanOrder removeObjectAtIndex:0]; }
    }
    return @{ @"url": [NSString stringWithFormat:@"http://127.0.0.1:%u/m/%@.mp4", gPort, name],
              @"length": @(plan->total) };
}

// Like TRMuxCreate, with a way to get new stream links when YouTube stops serving the old ones (blocking block, may be slow).
NSDictionary *TRMuxCreateRefreshing(NSDictionary *video, NSDictionary *audio, NSString *ua, NSDictionary *(^refresh)(void), NSString **why) {
    NSString *reason = nil;
    if (!EnsureServer()) { if (why) *why = @"no local server"; return nil; }
    TRMuxPlan *plan = BuildPlan(video, audio, ua, &reason);
    if (!plan) { if (why) *why = reason; return nil; }
    plan->refresh = [refresh copy];
    NSString *name = [NSString stringWithFormat:@"%08x%08x", arc4random(), arc4random()];
    @synchronized([TRMuxConnection class]) {
        gPlans[name] = plan; [gPlanOrder addObject:name];
        while ([gPlanOrder count] > 8) { [gPlans removeObjectForKey:gPlanOrder[0]]; [gPlanOrder removeObjectAtIndex:0]; }
    }
    return @{ @"url": [NSString stringWithFormat:@"http://127.0.0.1:%u/m/%@.mp4", gPort, name],
              @"length": @(plan->total) };
}

// Same file, built only when the player asks for it (the quality menu lists several heights; only the one picked is merged).
NSString *TRMuxLazyURL(NSDictionary *video, NSDictionary *audio, NSString *ua) {
    if (!EnsureServer()) return nil;
    NSString *name = [NSString stringWithFormat:@"%08x%08x", arc4random(), arc4random()];
    @synchronized([TRMuxConnection class]) {
        gPlans[name] = @{ @"video": video, @"audio": audio, @"ua": ua ?: @"" };
        [gPlanOrder addObject:name];
        while ([gPlanOrder count] > 12) { [gPlans removeObjectForKey:gPlanOrder[0]]; [gPlanOrder removeObjectAtIndex:0]; }
    }
    return [NSString stringWithFormat:@"http://127.0.0.1:%u/m/%@.mp4", gPort, name];
}

// Runs `job` in the background; the returned URL answers once it has finished (the file is merged from what it returns:
// @{ vinit, vsegs, ainit, asegs } = init segment + fragments of the video and of the audio track).
NSString *TRMuxStartLocalJob(NSString *label, NSDictionary *(^job)(NSString **why)) {
    if (!EnsureServer()) return nil;
    NSString *name = [NSString stringWithFormat:@"%08x%08x", arc4random(), arc4random()];
    TRMuxJob *j = [[[TRMuxJob alloc] init] autorelease];
    @synchronized([TRMuxConnection class]) {
        gPlans[name] = j; [gPlanOrder addObject:name];
        while ([gPlanOrder count] > 12) { [gPlans removeObjectForKey:gPlanOrder[0]]; [gPlanOrder removeObjectAtIndex:0]; }
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *why = nil;
        TRMuxPlan *plan = nil;
        @try {
            NSDictionary *r = job(&why);
            if (r) {
                NSString *dir = NSTemporaryDirectory();
                NSString *vp = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"trmux-%@-v.bin", name]];
                NSString *ap = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"trmux-%@-a.bin", name]];
                TRMuxTrack *v = LoadTrackLocal(r[@"vinit"], r[@"vsegs"], vp, &why);
                TRMuxTrack *a = v ? LoadTrackLocal(r[@"ainit"], r[@"asegs"], ap, &why) : nil;
                if (v && a) plan = PlanFromTracks(v, a, @"", &why);
                if (plan) NSLog(@"[TubeReplacer] mux: %@ merged locally (%llu bytes)", label, plan->total);
            }
        } @catch (NSException *e) { why = [e reason]; }
        @synchronized (j) { j->plan = [plan retain]; j->why = [why copy]; j->finished = YES; }
        if (!plan) NSLog(@"[TubeReplacer] mux: %@ local merge failed: %@", label, why ?: @"?");
        dispatch_semaphore_signal(j->done);
    });
    return [NSString stringWithFormat:@"http://127.0.0.1:%u/m/%@.mp4", gPort, name];
}

// Waits up to `seconds` for the job behind a local URL. 1 = merged and ready, -1 = failed, 0 = still running.
int TRMuxJobWait(NSString *url, double seconds) {
    NSString *name = [[[url lastPathComponent] stringByDeletingPathExtension] copy];
    TRMuxJob *job = nil;
    @synchronized([TRMuxConnection class]) { id e = gPlans[name]; job = [e isKindOfClass:[TRMuxJob class]] ? [[e retain] autorelease] : nil; if (!job && e) { [name release]; return 1; } }
    [name release];
    if (!job) return -1;
    NSTimeInterval end = [NSDate timeIntervalSinceReferenceDate] + seconds;
    while ([NSDate timeIntervalSinceReferenceDate] < end) {
        @synchronized (job) { if (job->finished) return job->plan ? 1 : -1; }
        [NSThread sleepForTimeInterval:0.25];
    }
    @synchronized (job) { if (job->finished) return job->plan ? 1 : -1; }
    return 0;
}

// Serves a small text (a rewritten HLS playlist) on 127.0.0.1.
NSString *TRServeText(NSString *ext, NSString *mime, NSString *text) {
    if (!EnsureServer() || !text) return nil;
    NSString *name = [NSString stringWithFormat:@"%08x%08x", arc4random(), arc4random()];
    @synchronized([TRMuxConnection class]) {
        gPlans[name] = @{ @"text": text, @"mime": mime ?: @"text/plain" }; [gPlanOrder addObject:name];
        while ([gPlanOrder count] > 12) { [gPlans removeObjectForKey:gPlanOrder[0]]; [gPlanOrder removeObjectAtIndex:0]; }
    }
    return [NSString stringWithFormat:@"http://127.0.0.1:%u/m/%@.%@", gPort, name, ext];
}

// Serves one plain progressive stream (url) on 127.0.0.1 and fetches it from YouTube in small ranged requests;
// refresh (optional, blocking) returns a fresh stream URL when the old one starts failing. Blocking: call off the main thread.
NSString *TRProxyStream(NSString *url, NSString *ua, long long length, NSString *label, NSString *(^refresh)(void)) {
    if (!EnsureServer() || ![url length]) return nil;
    uint64_t total = length > 0 ? (uint64_t)length : ProbeLength(url, ua);
    if (!total) { NSLog(@"[TubeReplacer] proxy: %@ unknown length, not proxied", label); return nil; }
    TRProxySrc *s = [[[TRProxySrc alloc] init] autorelease];
    s->url = [url copy]; s->ua = [ua copy]; s->label = [label copy]; s->total = total; s->refresh = [refresh copy];
    NSString *name = [NSString stringWithFormat:@"%08x%08x", arc4random(), arc4random()];
    @synchronized([TRMuxConnection class]) {
        gPlans[name] = s; [gPlanOrder addObject:name];
        while ([gPlanOrder count] > 12) { [gPlans removeObjectForKey:gPlanOrder[0]]; [gPlanOrder removeObjectAtIndex:0]; }
    }
    NSLog(@"[TubeReplacer] proxy: %@ serving %llu bytes locally", label, total);
    return [NSString stringWithFormat:@"http://127.0.0.1:%u/m/%@.mp4", gPort, name];
}
