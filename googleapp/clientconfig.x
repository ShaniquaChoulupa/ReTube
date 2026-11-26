// clientconfig.x
// TubeReplacer
//
// YouTube 2.1.0+ ships two parallel implementations of several screens:
//   - the legacy GData-style path (YTGDataService / YTGDataRequestFactory),
//     which TubeReplacer translates to InnerTube, and
//   - a newer "Apiary"/InnerTube-protobuf path (YTSearchService, YTGuideService,
//     YTWatchNextService, ...), which talks to the long-dead Google backend and
//     which TubeReplacer does not translate.
//
// Which path is used is decided at runtime from the server-provided
// YTClientConfiguration (use_innertube_*_probability etc). With the original
// servers gone the app lands on the dead path: the Guide never loads and search
// returns nothing.  We force every one of those switches to the legacy path.

#include <Foundation/Foundation.h>
#include "general.h"

// Where the legacy screens exist (<= 2.2.0) the app is pushed back onto them (YES would pick
// the dead Apiary path there). Where they don't (2.3.1+) the app is pushed onto the InnerTube
// screens, which innertube.x serves.
static BOOL TRInnerTubeScreens(void) { return legacyScreensAvailable() ? NO : YES; }

@interface YTClientConfiguration : NSObject
@end

@interface YTSettings : NSObject
@end

%hook YTClientConfiguration

- (BOOL)useInnerTubeSearch { return TRInnerTubeScreens(); }
- (BOOL)useInnerTubeWatchNext { return TRInnerTubeScreens(); }
- (BOOL)valueForUseInnerTubeGuideWithDefaultValue:(BOOL)defaultValue { return TRInnerTubeScreens(); }
- (BOOL)valueForUseApiaryWhatToWatchWithDefaultValue:(BOOL)defaultValue { return TRInnerTubeScreens(); }

%end

%hook YTSettings

- (BOOL)useInnerTubeGuide { return TRInnerTubeScreens(); }
- (BOOL)useInnerTubeGuideWithClientConfiguration:(id)configuration { return TRInnerTubeScreens(); }
- (BOOL)useInnerTubeSearch { return TRInnerTubeScreens(); }
- (BOOL)useInnerTubeSearchWithClientConfiguration:(id)configuration { return TRInnerTubeScreens(); }
- (BOOL)useInnerTubeWatchNext { return TRInnerTubeScreens(); }
- (BOOL)useInnerTubeWatchNextWithClientConfiguration:(id)configuration { return TRInnerTubeScreens(); }
- (BOOL)useApiaryWhatToWatch { return TRInnerTubeScreens(); }
- (BOOL)useApiaryWhatToWatchWithClientConfiguration:(id)configuration { return TRInnerTubeScreens(); }

%end
