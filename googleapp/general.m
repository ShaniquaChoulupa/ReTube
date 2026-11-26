#import <objc/runtime.h>
#import "general.h"
#include <Foundation/Foundation.h>

@interface NSBundle (YouTube)
-(NSString*)localizedQuantityStringForKey:(NSString*)key quantity:(NSUInteger)quantity table:(NSString*)table;
@end

NSString* localizedStringForKey(NSString *key)
{
  NSBundle *v2 = [NSBundle mainBundle];
  return [v2 localizedStringForKey:key value:key table:0];
}

NSString* localizedStringForKey2(NSString *key, NSUInteger quantity) {
    NSBundle *bundle = [NSBundle mainBundle];
    return [bundle localizedQuantityStringForKey:key quantity:quantity table:@"Localizable"];
}

NSString* localizedStringForKey2UILib(NSString *key, NSUInteger quantity) {
    NSBundle *bundle = [NSBundle mainBundle];
    return [bundle localizedQuantityStringForKey:key quantity:quantity table:@"UILib"];
}

NSString* localizedStringForKeyUILib(NSString *key) {
    NSBundle *bundle = [NSBundle mainBundle];
    return [bundle localizedStringForKey:key value:key table:@"UILib"];
}



// youtube has a built in version checker... but they changed the version checker name between versions.... soooooooo
NSString* version() {
  return [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
}

// All 2.x releases we know about share the 2.0.0 code paths.
int majorVersion() {
  return (int)[version() integerValue];
}

bool isVersion1x() {
  return majorVersion() == 1;
}

bool isVersion2x() {
  NSString *v = version();
  return [v isEqualToString:@"2.0.0"] || [v isEqualToString:@"2.1.0"] || [v isEqualToString:@"2.2.0"];
}

bool ytVideoSubtitlesNoStreamsInit() {
  static int cached = -1;
  if (cached < 0) {
    SEL s = NSSelectorFromString(@"initWithID:title:description:uploaderDisplayName:uploaderChannelID:uploadedDate:publishedDate:duration:viewCount:likesCount:dislikesCount:ratingAllowed:state:thumbnailURLs:subtitlesTracksURL:commentsAllowed:commentsURL:commentsCountHint:relatedURL:claimed:monetized:monetizedCountries:listed:categoryLabel:categoryTerm:adultContent:editURL:paidContent:privateContent:videoPro:liveEventURL:currentViewers:");
    cached = [NSClassFromString(@"YTVideo") instancesRespondToSelector:s] ? 1 : 0;
  }
  return cached == 1;
}

bool ytVideoLacksStreamsInit() {
  static int cached = -1;
  if (cached < 0) {
    SEL s = NSSelectorFromString(@"initWithID:title:description:uploaderDisplayName:uploaderChannelID:uploadedDate:publishedDate:duration:viewCount:likesCount:dislikesCount:ratingAllowed:state:thumbnailURLs:commentsAllowed:commentsURL:commentsCountHint:relatedURL:claimed:monetized:monetizedCountries:listed:categoryLabel:categoryTerm:adultContent:editURL:paidContent:privateContent:videoPro:liveEventURL:currentViewers:");
    cached = [NSClassFromString(@"YTVideo") instancesRespondToSelector:s] ? 1 : 0;
  }
  return cached == 1;
}

bool TRHasIvar(id obj, NSString *name) {
  if (!obj || !name) return NO;
  return class_getInstanceVariable([obj class], [name UTF8String]) != NULL;
}

bool legacyScreensAvailable() {
  static int cached = -1;
  if (cached < 0) {
    cached = (NSClassFromString(@"YTVideosFeedController") != nil && NSClassFromString(@"YTGuideFeedController") != nil) ? 1 : 0;
  }
  return cached == 1;
}

bool usesNewPlayerPipeline() {
  static int cached = -1;
  if (cached < 0) {
    cached = (NSClassFromString(@"YTPlayerService") != nil && NSClassFromString(@"YTPBStreamingData") == nil) ? 1 : 0;
  }
  return cached == 1;
}

bool isSupportedVersion() {
  NSString *v = version();
  if (!v.length) return NO;
  if (isVersion1x() || isVersion2x()) return YES;
  // Versions covered by the InnerTube bridge (innertube.x). Version strings can carry a build
  // number (10.11 reports "10.11.11546"), so match on prefixes / major version.
  int major = majorVersion();
  return [v hasPrefix:@"2.3."] || [v hasPrefix:@"2.9."] || major == 10 || major == 11 || major == 12 || major == 13;
}

// i want to kill you youtube, or apple for this

// creates the local variable version (variable_), since the compiler or youtube changed this, and it's in too many places to do my normal checking of version.
NSString* l(NSString *local) {
  if ([version() isEqualToString:@"1.0.0"] || [version() isEqualToString:@"1.0.1"] || [version() isEqualToString:@"1.1.0"] || [version() isEqualToString:@"1.2.1"]) {
    return [NSString stringWithFormat:@"%@_", local];
  } else {
    return [NSString stringWithFormat:@"_%@", local];
  }
}

NSString *TRPackageVersion(NSString *packageID) {
    NSError *err = nil;
    NSString *status = [NSString stringWithContentsOfFile:@"/var/lib/dpkg/status"
                                                 encoding:NSUTF8StringEncoding
                                                    error:&err];
    if (!status.length) return nil;

    NSArray<NSString *> *blocks = [status componentsSeparatedByString:@"\n\n"];
    NSString *needle = [NSString stringWithFormat:@"Package: %@", packageID];

    for (NSString *block in blocks) {
        if ([block rangeOfString:needle].location != NSNotFound) {
            for (NSString *line in [block componentsSeparatedByString:@"\n"]) {
                if ([line hasPrefix:@"Version: "]) {
                    return [line substringFromIndex:@"Version: ".length];
                }
            }
        }
    }
    return nil;
}

bool PreferencesBoolValue(NSDictionary* preferences, NSString *key, bool defaultValue) {
    id value = [preferences objectForKey:key]; 
    
    if (value == nil || value == [NSNull null]) {
        return defaultValue;
    }
    
    return [value boolValue];
}


#undef NSLog
void TRLogf(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@", msg);
    @try {
        // Apps are sandboxed, so try every location we might be allowed to write to:
        // the app's own Documents folder (reachable with iFile/Filza under /var/mobile/Applications/<id>/Documents),
        // then the shared locations.
        static NSArray *paths = nil;
        static NSObject *lock = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            lock = [[NSObject alloc] init];
            NSMutableArray *p = [NSMutableArray array];
            NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            if ([docs count]) [p addObject:[docs[0] stringByAppendingPathComponent:@"TubeReplacer.log"]];
            [p addObject:@"/var/mobile/Documents/TubeReplacer.log"];
            [p addObject:@"/var/mobile/TubeReplacer.log"];
            [p addObject:@"/var/tmp/TubeReplacer.log"];
            [p addObject:[NSTemporaryDirectory() stringByAppendingPathComponent:@"TubeReplacer.log"]];
            paths = [p retain];
        });
        NSString *app = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"] ?: @"?";
        NSData *line = [[NSString stringWithFormat:@"%@ [%@] %@\n", [NSDate date], app, msg] dataUsingEncoding:NSUTF8StringEncoding];
        @synchronized (lock) {
            NSFileManager *fm = [NSFileManager defaultManager];
            for (NSString *path in paths) {
                NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
                if ([attrs fileSize] > 300000) [fm removeItemAtPath:path error:nil];
                if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
                NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
                if (!fh) continue;
                [fh seekToEndOfFile];
                [fh writeData:line];
                [fh closeFile];
            }
        }
    } @catch (NSException *e) {}
    [msg release];
}
