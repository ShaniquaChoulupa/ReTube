// iOS 5 has no object subscripting (objectForKeyedSubscript: and friends arrived in iOS 6), but the
// tweak is compiled with it. Add the methods to the class clusters' public base classes.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static id TRSubObjectForKeyed(id self, SEL _cmd, id key) { return [self objectForKey:key]; }
static void TRSubSetKeyed(id self, SEL _cmd, id obj, id key) { [self setObject:obj forKey:key]; }
static id TRSubObjectAtIndexed(id self, SEL _cmd, NSUInteger idx) { return [self objectAtIndex:idx]; }
static void TRSubSetIndexed(id self, SEL _cmd, id obj, NSUInteger idx) {
    if (idx == [(NSArray *)self count]) [(NSMutableArray *)self addObject:obj];
    else [(NSMutableArray *)self replaceObjectAtIndex:idx withObject:obj];
}

__attribute__((constructor)) static void TRInstallSubscripts(void) {
    if (![NSDictionary instancesRespondToSelector:@selector(objectForKeyedSubscript:)])
        class_addMethod([NSDictionary class], @selector(objectForKeyedSubscript:), (IMP)TRSubObjectForKeyed, "@@:@");
    if (![NSMutableDictionary instancesRespondToSelector:@selector(setObject:forKeyedSubscript:)])
        class_addMethod([NSMutableDictionary class], @selector(setObject:forKeyedSubscript:), (IMP)TRSubSetKeyed, "v@:@@");
    if (![NSArray instancesRespondToSelector:@selector(objectAtIndexedSubscript:)])
        class_addMethod([NSArray class], @selector(objectAtIndexedSubscript:), (IMP)TRSubObjectAtIndexed, "@@:I");
    if (![NSMutableArray instancesRespondToSelector:@selector(setObject:atIndexedSubscript:)])
        class_addMethod([NSMutableArray class], @selector(setObject:atIndexedSubscript:), (IMP)TRSubSetIndexed, "v@:@I");
}
