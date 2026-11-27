#include <Foundation/Foundation.h>

NSString* localizedStringForKey(NSString *key);
NSString* localizedStringForKey2(NSString *key, NSUInteger quantity);
NSString* localizedStringForKeyUILib(NSString *key);
NSString* localizedStringForKey2UILib(NSString *key, NSUInteger quantity);
NSString* version();
int majorVersion();   // 1, 2, 10, 11 ... ("10.11" -> 10)
bool isVersion1x();   // major version 1 (NOT 10.x / 11.x)
bool isVersion2x(); // 2.0.0, 2.1.0, 2.2.0 (the "v2" code paths)
bool isSupportedVersion();
bool legacyScreensAvailable(); // the GData-era guide / video list controllers exist (<= 2.2.0)
bool usesNewPlayerPipeline(); // 2.1.0+: YTPlayerService -> YTIPlayerResponse -> MLStreamManifest (no YTPBStreamingData)
bool TRHasIvar(id obj, NSString *name); // YES if obj's class (or a superclass) declares that ivar
bool ytVideoSubtitlesNoStreamsInit(); // 2.1.0: subtitlesTracksURL: but no streams:
bool ytVideoLacksStreamsInit(); // YTVideo initializer without streams:/subtitlesTracksURL: (2.2.0+)
NSString* l(NSString *local);
NSString *TRPackageVersion(NSString *packageID);
bool PreferencesBoolValue(NSDictionary* preferences, NSString *key, bool defaultValue);

// File logging: everything the tweak NSLogs is also appended to
// /var/mobile/Documents/TubeReplacer.log (trimmed at ~400 KB) so failures can be sent back for diagnosis.
void TRLogf(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
#define NSLog(...) TRLogf(__VA_ARGS__)
