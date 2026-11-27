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

## ReTube 1.3 notes (untested on a device when written)
- 720p: `TRStartHDJob` (innertube.x) POSTs /player as the iOS client (clientName IOS 21.08.3, deviceModel iPhone16,2, no auth) in parallel with the android request,
  downloads `streamingData.hlsManifestUrl`, `TRSanitizeMasterH` keeps avc1+mp4a steps 240p..cap (cap 720; hd720 off -> 480; <=360 -> HD off), one step per height (<=30 fps first),
  best first, one default audio rendition per group; `TRHDProbe` fetches the video list, then 2 bytes of its first segment (and the audio list); on success `TRServeText` serves the
  cleaned master and the 'player' endpoint sets `hlsManifestUrl` and removes `formats/adaptiveFormats/dashManifestUrl`. Failures count; 3 in a row pause HD for 5 minutes. Log prefix `hd:`.
- Unknowns: whether the iOS client list needs a PO token for segments (the probe answers it), and whether the old apps' own player/proxy accepts a VOD HLS master (live streams already use the same path).
- Related videos: `TRExtendRelatedSync` follows the secondaryResults continuation twice (blocking, on the bridge worker) before `TRNormalizeResponse`; caps raised to 90, dedup by videoId. Log prefix `related:`.
- Tiles: v13fixes.x `TRBigTile` enlarges the thumbnail-shaped direct child of YTCompactVideoView by up to 1.25 when the row is tall enough; `sizeThatFits:` asks for more height. Dump of the first 3 rows in the log (`tile #n`).
