#import <Foundation/Foundation.h>
void TRLogf(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
#define NSLog(...) TRLogf(__VA_ARGS__)
