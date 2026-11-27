# random notes

- ML stands for medialib
- the l(@"") function handles proper underscore placement between different versions.
- to find the callstack of a function w/o using a debugger, you can use
```objc
#import <execinfo.h>
#import <mach-o/dyld.h>

intptr_t slide = _dyld_get_image_vmaddr_slide(0);
NSLog(@"ASLR Slide Offset: 0x%lx\n", (unsigned long)slide);
void *callstack[128];
int frames = backtrace(callstack, 128);
char **symbols = backtrace_symbols(callstack, frames);
NSMutableString *callstackString = [NSMutableString stringWithFormat:@"uwu >_<"];
for (int i = 0; i < frames; i++) {
  [callstackString appendFormat:@"%s\n", symbols[i]];
}
NSLog(@"%@", callstackString);
```

## ReTube 1.4 notes (untested on a device when written)
- 720p: `TRStartHDJob` (innertube.x, started first thing in the 'player' endpoint) runs `TRHDRun` on a global queue: for spec 0 (android client, its own UA) then spec 1 (android VR client, UA
  `com.google.android.apps.youtube.vr.oculus/1.60.19 ...`, X-YouTube-Client-Name 28) it POSTs /player (`TRHDFetchPlayerSync`), `TRHDPick` takes the 720p `video/mp4` avc1 stream (30 fps before 60) and the AAC
  `audio/mp4` stream (itag 140 first) that have url + initRange + indexRange, `TRHDProbeURL` asks 2 bytes of each (200/206 needed), `TRMuxCreateRefreshing` (common/SABR/TRMuxer.m) builds the progressive MP4 plan
  (reads every fragment header; <= 1500 sidx refs) and serves it on 127.0.0.1; `TRHDMakeFormat` shapes an itag-22 entry like YouTube's itag 18 one. `TRFetchHDFormatsJSON` waits <= 15 s and the 'player' endpoint inserts it at
  the front of `streamingData.formats` (the `muxed` marker is removed there). The 360p entry stays behind it as the fallback.
- Link refresh: `TRMuxPlan refreshTrack:staleURL:` calls the refresh block (same client, same itags) on a non-200/206 range answer; max 20 refreshes per plan, 3 attempts per range.
- Skips: live, > 1500 s, off in settings / custom stream server / hd720 off, 3 failures in a row -> pause 5 min. Failure counts only when streams existed but probe/merge failed. Log prefix `hd:`, `mux:`.
- Unknowns: whether android / android VR adaptive links work without a PO token (the probe decides; `hd:` lines show the HTTP codes), whether the muxer output is accepted by the 12.11.6 player, whether the app picks the itag-22 entry.
- Related videos: `TRExtendRelatedSync` finds the last `continuationItemRenderer` token anywhere below `secondaryResults.secondaryResults` (signed-in answers nest it), follows it twice (blocking, on the bridge worker) and appends the items to `results`
  before `TRNormalizeResponse`; caps 90, dedup by videoId. Logs `related:` incl. why nothing was added.
- Tiles: v13fixes.x `TRBigTileIn` (cell or view -> `TRFindTileRow` finds the view with a thumbnail-shaped direct child -> `TRBigTile` enlarges it by up to 1.25 if the row is tall enough). Hooks: YTCompactVideoView, YTCompactSuggestedVideoCell,
  YTCompactVideoCell, YTSuggestedVideoCell (`sizeThatFits:` adds the height once, `gTRInSize`). Dump of the first 4 view trees (`tile #n (class)`).
