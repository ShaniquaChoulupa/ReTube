#import <Foundation/Foundation.h>

// Merges YouTube's fragmented video-only and audio-only MP4 streams into one progressive MP4 (no transcoding),
// served on 127.0.0.1. The old apps then see an ordinary muxed stream. Blocking: call off the main thread.
// video / audio are player-JSON format dictionaries (url, mimeType, initRange, indexRange, ...).
// Returns @{ @"url": local URL, @"length": total bytes, @"seconds": duration } or nil with *why set.
NSDictionary *TRMuxCreate(NSDictionary *video, NSDictionary *audio, NSString *ua, NSString **why);

NSString *TRMuxLazyURL(NSDictionary *video, NSDictionary *audio, NSString *ua);

NSString *TRMuxStartLocalJob(NSString *label, NSDictionary *(^job)(NSString **why));

int TRMuxJobWait(NSString *url, double seconds);

NSString *TRServeText(NSString *ext, NSString *mime, NSString *text);

NSString *TRProxyStream(NSString *url, NSString *ua, long long length, NSString *label, NSString *(^refresh)(void));
