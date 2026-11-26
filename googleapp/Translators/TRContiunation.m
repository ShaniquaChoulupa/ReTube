#include <Foundation/Foundation.h>
#include "TRContinuation.h"

@implementation TRContinuation
+(TRContinuation*)initWithToken:(NSString*)token {
    TRContinuation *continuation = [[TRContinuation alloc] init];
    if (token) {
        [continuation setToken:token];
    }
    return [continuation autorelease];
}
// Old apps treat nextURL as a real NSURL (absoluteString, host, ...). Stand in with a fake URL.
-(NSURL *)trFakeURL {
    NSString *t = [self token] ?: @"";
    NSString *esc = [t stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: @"";
    return [NSURL URLWithString:[@"https://www.youtube.com/?trcont=" stringByAppendingString:esc]];
}
-(NSString *)absoluteString { return [[self trFakeURL] absoluteString]; }
-(NSString *)description { return [[self trFakeURL] absoluteString]; }
-(id)forwardingTargetForSelector:(SEL)sel {
    if ([NSURL instancesRespondToSelector:sel]) return [self trFakeURL];
    return [super forwardingTargetForSelector:sel];
}
-(id)copyWithZone:(NSZone *)z { return [self retain]; }
-(NSUInteger)hash { return [[self token] hash]; }
-(BOOL)isEqual:(id)o { return [o isKindOfClass:[TRContinuation class]] && [[(TRContinuation*)o token] isEqual:[self token]]; }
@end
