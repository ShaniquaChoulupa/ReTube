#import <Foundation/Foundation.h>
#include <stdarg.h>
#import "trlog.h"

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
