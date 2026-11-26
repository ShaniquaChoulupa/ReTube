// innertube.x
// TubeReplacer - InnerTube bridge for YouTube 2.3.1, 2.9.3, 10.11, 11.19.7 (and any
// version that has the Apiary/InnerTube layer but no legacy GData screens).
//
// These apps talk to YouTube in *protobuf* ("Apiary"): each service builds a request
// message (YTIBrowseRequest, YTISearchRequest, ...), posts its bytes to
// <base>/youtubei/v1/<endpoint> and parses the reply into a response message with a
// parser that knows the response class.  The original servers and the device
// authentication in front of them are gone, so nothing loads.
//
// This file replaces the *transport*, in one place, for every service:
//
//   request bytes --(descriptor-driven decode)--> JSON --> real InnerTube
//   InnerTube JSON --(descriptor-driven encode)--> protobuf bytes --> the app's own parser
//
// InnerTube's JSON is protobuf-JSON of the same schema family the old apps were built
// from, so fields line up by name.  The app's own protobuf runtime exposes complete
// reflection (+descriptor -> fields: name, number, type, repeated, message class,
// enum), identical in every version, so one implementation serves all of them and
// nothing here depends on per-version generated classes or builders.
//
// Field "type" numbers are this runtime's (GPB-style) numbering, read from the binary:
//   0 bool, 1 fixed32, 2 sfixed32, 3 float, 4 fixed64, 5 sfixed64, 6 double,
//   7 int32, 8 int64, 9 sint32, 10 sint64, 11 uint32, 12 uint64, 13 bytes,
//   14 string, 15 message, 16 group, 17 enum.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <substrate.h>
#include <ctype.h>
#include <string.h>
#include "general.h"
#import "common/SABR/TRMuxer.h"
#include "Translators/TRRequestBuilder.h"
#include "Translators/TRJSONUtils.h"
#include "common/YoutubeClientType.h"
#import "base64/NSData+Base64.h"

extern void TRFetchPlayerJSON(NSString *videoID, void (^done)(NSDictionary *json, NSString *failure));
extern BOOL TRHDOnlyMode(void);
extern void TRFetchHDFormatsJSON(NSString *videoID, NSDictionary *primary, void (^done)(NSArray *adaptive, NSString *hls));
extern void TRCacheCaptionTracks(NSString *videoID, NSArray *tracks); // captions.x
extern BOOL TRHasCaptionTracks(NSString *videoID);
extern NSString *TRCaptionBaseURL(NSString *videoID);
extern NSArray *TRCaptionTrackJSON(NSString *videoID, NSArray *origTracks); // captions.x
extern BOOL TRHasTranscript(NSString *videoID);

enum { TRT_Bool = 0, TRT_Fixed32, TRT_SFixed32, TRT_Float, TRT_Fixed64, TRT_SFixed64, TRT_Double,
       TRT_Int32, TRT_Int64, TRT_SInt32, TRT_SInt64, TRT_UInt32, TRT_UInt64, TRT_Bytes, TRT_String,
       TRT_Message, TRT_Group, TRT_Enum };

#pragma mark - Schema reflection

@interface TRPBField : NSObject {
@public
    NSString *name;
    int number;
    int type;
    BOOL repeated;
    Class msgClass;
    id enumDesc;
    NSString *jsonName;
}
@end
@implementation TRPBField
- (void)dealloc { [name release]; [jsonName release]; [enumDesc release]; [super dealloc]; }
@end

@interface TRPBSchema : NSObject {
@public
    NSMutableDictionary *byName;   // normalized name -> TRPBField
    NSMutableDictionary *byNumber; // @(number) -> TRPBField
}
@end
@implementation TRPBSchema
- (void)dealloc { [byName release]; [byNumber release]; [super dealloc]; }
@end

// "playabilityStatus" == "playability_status" == "PlayabilityStatus"
static NSString *TRNorm(NSString *s) {
    NSMutableString *m = [NSMutableString stringWithCapacity:[s length]];
    for (NSUInteger i = 0; i < [s length]; i++) {
        unichar c = [s characterAtIndex:i];
        if (c == '_' || c == '-') continue;
        if (c >= 'A' && c <= 'Z') c += 32;
        [m appendFormat:@"%C", c];
    }
    return m;
}

// snake_case -> camelCase (JSON name used when decoding requests)
static NSString *TRCamel(NSString *s) {
    if ([s rangeOfString:@"_"].location == NSNotFound) return s;
    NSArray *parts = [s componentsSeparatedByString:@"_"];
    NSMutableString *m = [NSMutableString stringWithString:parts[0]];
    for (NSUInteger i = 1; i < [parts count]; i++) {
        NSString *p = parts[i];
        if ([p length]) [m appendString:[[[p substringToIndex:1] uppercaseString] stringByAppendingString:[p substringFromIndex:1]]];
    }
    return m;
}

static TRPBSchema *TRSchema(Class cls) {
    if (!cls) return nil;
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [[NSMutableDictionary alloc] init]; });
    NSString *key = NSStringFromClass(cls);
    @synchronized (cache) {
        TRPBSchema *hit = cache[key];
        if (hit) return hit;
    }
    if (![cls respondsToSelector:@selector(descriptor)]) return nil;
    id desc = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(descriptor));
    NSArray *fields = [desc respondsToSelector:@selector(fields)] ? ((id (*)(id, SEL))objc_msgSend)(desc, @selector(fields)) : nil;
    if (!fields) return nil;

    TRPBSchema *schema = [[[TRPBSchema alloc] init] autorelease];
    schema->byName = [[NSMutableDictionary alloc] init];
    schema->byNumber = [[NSMutableDictionary alloc] init];
    for (id f in fields) {
        TRPBField *rec = [[[TRPBField alloc] init] autorelease];
        rec->name = [((id (*)(id, SEL))objc_msgSend)(f, @selector(name)) copy];
        rec->number = ((int (*)(id, SEL))objc_msgSend)(f, @selector(number));
        if ([f respondsToSelector:@selector(dataType)]) {
            // 13.x ships Google's stock protobuf runtime (GPBFieldDescriptor): same type numbering,
            // repeated/map is the fieldType (0 single, 1 repeated, 2 map)
            rec->type = (int)((unsigned char (*)(id, SEL))objc_msgSend)(f, @selector(dataType));
            unsigned char ft = [f respondsToSelector:@selector(fieldType)] ? ((unsigned char (*)(id, SEL))objc_msgSend)(f, @selector(fieldType)) : 0;
            if (ft == 2) continue; // maps are not used by the InnerTube messages we translate
            rec->repeated = (ft == 1);
        } else {
            rec->type = ((int (*)(id, SEL))objc_msgSend)(f, @selector(type));
            rec->repeated = ((BOOL (*)(id, SEL))objc_msgSend)(f, @selector(isRepeated));
        }
        if (rec->type == TRT_Message || rec->type == TRT_Group)
            rec->msgClass = ((Class (*)(id, SEL))objc_msgSend)(f, @selector(msgClass));
        if (rec->type == TRT_Enum)
            rec->enumDesc = [((id (*)(id, SEL))objc_msgSend)(f, @selector(enumDescriptor)) retain];
        if (!rec->name) continue;
        NSString *base = rec->name;
        if ([base hasSuffix:@"Array"] && [base length] > 5) base = [base substringToIndex:[base length] - 5];
        NSString *n0 = TRNorm(rec->name), *n1 = TRNorm(base);
        schema->byName[n0] = rec;
        if (!schema->byName[n1] || rec->repeated) schema->byName[n1] = rec;
        // old protos name repeated fields in the singular ("item"), JSON uses the plural ("items")
        if (rec->repeated) {
            NSString *alt = [n1 hasSuffix:@"s"] ? [n1 substringToIndex:[n1 length] - 1] : [n1 stringByAppendingString:@"s"];
            if (!schema->byName[alt]) schema->byName[alt] = rec;
        }
        schema->byNumber[@(rec->number)] = rec;
        rec->jsonName = [base copy];
    }
    @synchronized (cache) { cache[key] = schema; }
    return schema;
}

#pragma mark - Encoder: JSON -> protobuf wire bytes

@interface TRStats : NSObject {
@public
    NSUInteger fieldsSet;
    NSMutableDictionary *unknown; // JSON key -> count
}
@end
@implementation TRStats
- (id)init { if ((self = [super init])) unknown = [[NSMutableDictionary alloc] init]; return self; }
- (void)dealloc { [unknown release]; [super dealloc]; }
@end

static void TRPutVarint(NSMutableData *d, uint64_t v) {
    uint8_t buf[10]; int n = 0;
    while (v >= 0x80) { buf[n++] = (uint8_t)((v & 0x7f) | 0x80); v >>= 7; }
    buf[n++] = (uint8_t)v;
    [d appendBytes:buf length:n];
}
static void TRPutTag(NSMutableData *d, int number, int wire) { TRPutVarint(d, ((uint64_t)(uint32_t)number << 3) | (uint64_t)wire); }
static void TRPutFixed32(NSMutableData *d, uint32_t v) { [d appendBytes:&v length:4]; } // little endian on ARM
static void TRPutFixed64(NSMutableData *d, uint64_t v) { [d appendBytes:&v length:8]; }

static BOOL TRTruthy(id v) {
    if ([v isKindOfClass:[NSString class]]) return [v isEqualToString:@"true"] || [v isEqualToString:@"1"];
    return [v boolValue];
}

static void TREncodeMessage(NSDictionary *json, Class cls, NSMutableData *out, TRStats *st, int depth);

static BOOL TREncodeValue(NSMutableData *out, TRPBField *f, id v, TRStats *st, int depth) {
    if (!v || v == [NSNull null]) return NO;
    switch (f->type) {
        case TRT_Bool:
            TRPutTag(out, f->number, 0); TRPutVarint(out, TRTruthy(v) ? 1 : 0); return YES;
        case TRT_Int32: case TRT_Int64:
            TRPutTag(out, f->number, 0); TRPutVarint(out, (uint64_t)(int64_t)[v longLongValue]); return YES;
        case TRT_UInt32: case TRT_UInt64: {
            unsigned long long n = [v isKindOfClass:[NSString class]] ? strtoull([v UTF8String], NULL, 10) : [v unsignedLongLongValue];
            if (f->type == TRT_UInt32) n &= 0xffffffffULL;
            TRPutTag(out, f->number, 0); TRPutVarint(out, n); return YES;
        }
        case TRT_SInt32: case TRT_SInt64: {
            int64_t n = [v longLongValue];
            TRPutTag(out, f->number, 0); TRPutVarint(out, ((uint64_t)n << 1) ^ (uint64_t)(n >> 63)); return YES;
        }
        case TRT_Enum: {
            int64_t n = 0; BOOL ok = NO;
            if ([v isKindOfClass:[NSNumber class]]) { n = [v longLongValue]; ok = YES; }
            else if ([v isKindOfClass:[NSString class]] && f->enumDesc) {
                if ([f->enumDesc respondsToSelector:@selector(getValue:forEnumName:)]) {
                    // GPBEnumDescriptor: names may carry the enum's prefix, so also match on the suffix
                    int out = 0;
                    BOOL found = ((BOOL (*)(id, SEL, int *, id))objc_msgSend)(f->enumDesc, @selector(getValue:forEnumName:), &out, v);
                    if (!found) found = ((BOOL (*)(id, SEL, int *, id))objc_msgSend)(f->enumDesc, @selector(getValue:forEnumName:), &out, [v uppercaseString]);
                    if (!found && [f->enumDesc respondsToSelector:@selector(enumNameCount)]) {
                        unsigned cnt = ((unsigned (*)(id, SEL))objc_msgSend)(f->enumDesc, @selector(enumNameCount));
                        for (unsigned i = 0; i < cnt && !found; i++) {
                            NSString *nm = ((id (*)(id, SEL, unsigned))objc_msgSend)(f->enumDesc, @selector(getEnumNameForIndex:), i);
                            if ([nm isEqualToString:v] || [nm hasSuffix:[@"_" stringByAppendingString:v]]) {
                                found = ((BOOL (*)(id, SEL, int *, id))objc_msgSend)(f->enumDesc, @selector(getValue:forEnumName:), &out, nm);
                            }
                        }
                    }
                    if (found) { n = out; ok = YES; }
                    else if ([v length] && isdigit([v characterAtIndex:0])) { n = [v longLongValue]; ok = YES; }
                } else {
                    id ev = ((id (*)(id, SEL, id))objc_msgSend)(f->enumDesc, @selector(enumValueWithName:), v);
                    if (!ev) ev = ((id (*)(id, SEL, id))objc_msgSend)(f->enumDesc, @selector(enumValueWithName:), [v uppercaseString]);
                    if (ev) { n = ((int (*)(id, SEL))objc_msgSend)(ev, @selector(number)); ok = YES; }
                    else if ([v length] && isdigit([v characterAtIndex:0])) { n = [v longLongValue]; ok = YES; }
                }
            }
            if (!ok) return NO;
            TRPutTag(out, f->number, 0); TRPutVarint(out, (uint64_t)n); return YES;
        }
        case TRT_Fixed32: case TRT_SFixed32:
            TRPutTag(out, f->number, 5); TRPutFixed32(out, (uint32_t)[v longLongValue]); return YES;
        case TRT_Fixed64: case TRT_SFixed64:
            TRPutTag(out, f->number, 1); TRPutFixed64(out, (uint64_t)[v longLongValue]); return YES;
        case TRT_Float: {
            float x = [v floatValue]; uint32_t bits; memcpy(&bits, &x, 4);
            TRPutTag(out, f->number, 5); TRPutFixed32(out, bits); return YES;
        }
        case TRT_Double: {
            double x = [v doubleValue]; uint64_t bits; memcpy(&bits, &x, 8);
            TRPutTag(out, f->number, 1); TRPutFixed64(out, bits); return YES;
        }
        case TRT_String: {
            NSString *s = [v isKindOfClass:[NSString class]] ? v : [v description];
            NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
            TRPutTag(out, f->number, 2); TRPutVarint(out, [d length]); [out appendData:d]; return YES;
        }
        case TRT_Bytes: {
            NSData *d = [v isKindOfClass:[NSString class]] ? [NSData dataWithBase64EncodedString:v] : nil;
            if (!d) return NO;
            TRPutTag(out, f->number, 2); TRPutVarint(out, [d length]); [out appendData:d]; return YES;
        }
        case TRT_Message: {
            if (![v isKindOfClass:[NSDictionary class]] || !f->msgClass) return NO;
            NSMutableData *sub = [NSMutableData data];
            TREncodeMessage(v, f->msgClass, sub, st, depth + 1);
            if (f->repeated && [sub length] == 0) return NO; // wrapper whose renderer this app version does not know
            TRPutTag(out, f->number, 2); TRPutVarint(out, [sub length]); [out appendData:sub]; return YES;
        }
        default: return NO; // groups are not used by InnerTube
    }
}

static void TREncodeMessage(NSDictionary *json, Class cls, NSMutableData *out, TRStats *st, int depth) {
    if (depth > 48 || ![json isKindOfClass:[NSDictionary class]]) return;
    TRPBSchema *schema = TRSchema(cls);
    if (!schema) return;
    for (NSString *key in json) {
        TRPBField *f = schema->byName[TRNorm(key)];
        if (!f) {
            NSNumber *c = st->unknown[key];
            st->unknown[key] = @(c ? [c intValue] + 1 : 1);
            continue;
        }
        id v = json[key];
        if (f->repeated) {
            NSArray *items = [v isKindOfClass:[NSArray class]] ? v : (v ? @[v] : @[]);
            for (id item in items) if (TREncodeValue(out, f, item, st, depth)) st->fieldsSet++;
        } else {
            if (TREncodeValue(out, f, v, st, depth)) st->fieldsSet++;
        }
    }
}

#pragma mark - Decoder: protobuf wire bytes -> JSON (used for requests)

static BOOL TRReadVarint(const uint8_t *b, NSUInteger n, NSUInteger *pos, uint64_t *out) {
    uint64_t r = 0; int shift = 0;
    while (*pos < n && shift < 70) {
        uint8_t c = b[(*pos)++];
        r |= (uint64_t)(c & 0x7f) << shift;
        if (!(c & 0x80)) { *out = r; return YES; }
        shift += 7;
    }
    return NO;
}

static id TRScalarJSON(TRPBField *f, uint64_t raw) {
    switch (f->type) {
        case TRT_Bool: return @(raw != 0);
        case TRT_Int32: return @((int32_t)raw);
        case TRT_Int64: return @((int64_t)raw);
        case TRT_UInt32: return @((uint32_t)raw);
        case TRT_UInt64: return @((unsigned long long)raw);
        case TRT_SInt32: case TRT_SInt64: { int64_t n = (int64_t)(raw >> 1) ^ -(int64_t)(raw & 1); return @(n); }
        case TRT_Enum: {
            return @((int)raw);
        }
        default: return @(raw);
    }
}

static NSDictionary *TRDecodeMessage(NSData *data, Class cls, int depth) {
    TRPBSchema *schema = TRSchema(cls);
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (!schema || depth > 32) return out;
    const uint8_t *b = [data bytes]; NSUInteger n = [data length], pos = 0;
    while (pos < n) {
        uint64_t tag;
        if (!TRReadVarint(b, n, &pos, &tag)) break;
        int number = (int)(tag >> 3), wire = (int)(tag & 7);
        TRPBField *f = schema->byNumber[@(number)];
        id value = nil;
        if (wire == 0) {
            uint64_t v; if (!TRReadVarint(b, n, &pos, &v)) break;
            if (f) value = TRScalarJSON(f, v);
        } else if (wire == 1) {
            if (pos + 8 > n) break;
            uint64_t v; memcpy(&v, b + pos, 8); pos += 8;
            if (f) { if (f->type == TRT_Double) { double x; memcpy(&x, &v, 8); value = @(x); } else value = @((long long)v); }
        } else if (wire == 5) {
            if (pos + 4 > n) break;
            uint32_t v; memcpy(&v, b + pos, 4); pos += 4;
            if (f) { if (f->type == TRT_Float) { float x; memcpy(&x, &v, 4); value = @(x); } else value = @((int32_t)v); }
        } else if (wire == 2) {
            uint64_t len; if (!TRReadVarint(b, n, &pos, &len) || pos + len > n) break;
            NSData *chunk = [NSData dataWithBytes:b + pos length:(NSUInteger)len]; pos += (NSUInteger)len;
            if (f) {
                if (f->type == TRT_Message && f->msgClass) value = TRDecodeMessage(chunk, f->msgClass, depth + 1);
                else if (f->type == TRT_String) value = [[[NSString alloc] initWithData:chunk encoding:NSUTF8StringEncoding] autorelease] ?: @"";
                else if (f->type == TRT_Bytes) value = [chunk base64EncodedString];
                else if (f->repeated) { // packed scalars (proto3 packs every numeric type, fixed-width included)
                    NSMutableArray *packed = [NSMutableArray array];
                    const uint8_t *cb = [chunk bytes]; NSUInteger cn = [chunk length], cp = 0;
                    if (f->type == TRT_Fixed32 || f->type == TRT_SFixed32 || f->type == TRT_Float) {
                        while (cp + 4 <= cn) {
                            uint32_t v; memcpy(&v, cb + cp, 4); cp += 4;
                            if (f->type == TRT_Float) { float x; memcpy(&x, &v, 4); [packed addObject:@(x)]; }
                            else [packed addObject:@((int32_t)v)];
                        }
                    } else if (f->type == TRT_Fixed64 || f->type == TRT_SFixed64 || f->type == TRT_Double) {
                        while (cp + 8 <= cn) {
                            uint64_t v; memcpy(&v, cb + cp, 8); cp += 8;
                            if (f->type == TRT_Double) { double x; memcpy(&x, &v, 8); [packed addObject:@(x)]; }
                            else [packed addObject:@((long long)v)];
                        }
                    } else {
                        while (cp < cn) { uint64_t v; if (!TRReadVarint(cb, cn, &cp, &v)) break; [packed addObject:TRScalarJSON(f, v)]; }
                    }
                    value = packed;
                }
            }
        } else break; // groups / garbage
        if (f && value) {
            NSString *key = TRCamel(f->jsonName ?: f->name);
            if (f->repeated && ![value isKindOfClass:[NSArray class]]) {
                NSMutableArray *arr = out[key]; if (!arr) { arr = [NSMutableArray array]; out[key] = arr; }
                [arr addObject:value];
            } else if (f->repeated) {
                NSMutableArray *arr = out[key]; if (!arr) { arr = [NSMutableArray array]; out[key] = arr; }
                [arr addObjectsFromArray:value];
            } else out[key] = value;
        }
    }
    return out;
}


#pragma mark - Response normalization (today's InnerTube JSON -> the renderers these apps know)

static id TRDig(id node, NSArray *path) {
    for (id k in path) {
        if ([k isKindOfClass:[NSNumber class]]) {
            if (![node isKindOfClass:[NSArray class]] || [node count] <= [k unsignedIntegerValue]) return nil;
            node = [node objectAtIndex:[k unsignedIntegerValue]];
        } else {
            if (![node isKindOfClass:[NSDictionary class]]) return nil;
            node = node[k];
        }
    }
    return node;
}

static void TRCollectAll(id n, NSString *key, NSMutableArray *out, int depth);
static NSString *TRFindSubscriberText(id n, int depth);
static NSDictionary *TRSimpleText(NSString *s) { return s ? @{ @"runs": @[ @{ @"text": s } ] } : nil; }


// description text with tappable timestamps (0:42, 1:02:03): runs carrying a watch endpoint that seeks there
static NSDictionary *TRDescriptionRuns(NSString *text, NSString *vid) {
    if (![text length]) return nil;
    if (![vid length] || majorVersion() < 12) return TRSimpleText(text);
    static NSRegularExpression *re = nil;
    if (!re) re = [[NSRegularExpression alloc] initWithPattern:@"(?<![\\d:])(?:(\\d{1,2}):)?(\\d{1,2}):(\\d{2})(?![\\d:])" options:0 error:nil];
    NSMutableArray *runs = [NSMutableArray array];
    __block NSUInteger last = 0;
    [re enumerateMatchesInString:text options:0 range:NSMakeRange(0, [text length]) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        NSRange r = m.range;
        int h = [m rangeAtIndex:1].location != NSNotFound ? [[text substringWithRange:[m rangeAtIndex:1]] intValue] : 0;
        int mi = [[text substringWithRange:[m rangeAtIndex:2]] intValue];
        int se = [[text substringWithRange:[m rangeAtIndex:3]] intValue];
        if (se > 59 || mi > 59) return;
        if (r.location > last) [runs addObject:@{ @"text": [text substringWithRange:NSMakeRange(last, r.location - last)] }];
        [runs addObject:@{ @"text": [text substringWithRange:r],
            @"navigationEndpoint": @{ @"watchEndpoint": @{ @"videoId": vid, @"startTimeSeconds": @(h * 3600 + mi * 60 + se) } } }];
        last = r.location + r.length;
    }];
    if (last < [text length]) [runs addObject:@{ @"text": [text substringFromIndex:last] }];
    return [runs count] ? @{ @"runs": runs } : TRSimpleText(text);
}

static id TRFindKey(id n, NSString *key, int depth);
static NSString *TRTextOf(id t) { // {simpleText} | {runs:[{text}]} | {content} | NSString
    if ([t isKindOfClass:[NSString class]]) return t;
    if (![t isKindOfClass:[NSDictionary class]]) return nil;
    if ([t[@"simpleText"] isKindOfClass:[NSString class]]) return t[@"simpleText"];
    if ([t[@"content"] isKindOfClass:[NSString class]]) return t[@"content"];
    NSMutableString *m = [NSMutableString string];
    for (id r in ([t[@"runs"] isKindOfClass:[NSArray class]] ? t[@"runs"] : @[]))
        if ([r[@"text"] isKindOfClass:[NSString class]]) [m appendString:r[@"text"]];
    return [m length] ? m : nil;
}


// v11+ apps draw subscribeButtonRenderer; the web only has buttonRenderer / view-model buttons now

// channels the signed-in user subscribes to (from the guide), so every subscribe button shows the right state
static NSMutableSet *gTRSubs = nil;
static NSTimeInterval gTRSubsAt = 0;
static BOOL gTRSubsBusy = NO;
static void TRPostInnerTube(NSString *endpoint, NSDictionary *body, void (^cb)(NSDictionary *json, NSInteger code, NSError *err));
static void TRCollectKey(id n, NSString *key, NSMutableArray *out, int depth);
static NSString *gTRMyChannel = nil;
BOOL gTRHeaderIsOwn = NO; // the channel page being shown is the signed-in account's own (channelheader.x hides the subscribe switch)
NSString *gTRProfileName = nil, *gTRProfilePhoto = nil, *gTRProfileHandle = nil; // the YouTube (channel) identity, set from the profile request (myprofile.x)
static BOOL TRIsOwnChannel(NSString *cid) {
    return [cid length] && [gTRMyChannel isEqualToString:cid];
}
static BOOL TRIsSubscribed(NSString *cid) {
    if (![cid length]) return NO;
    @synchronized ([NSProcessInfo processInfo]) { return [gTRSubs containsObject:cid]; }
}
static void TRRefreshSubs(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (gTRSubsBusy || (gTRSubs && now - gTRSubsAt < 90)) return;
    gTRSubsBusy = YES;
    TRPostInnerTube(@"guide", @{}, ^(NSDictionary *gj, NSInteger gc, NSError *ge) {
        @try {
            if (gj && gc < 400) {
                NSMutableArray *entries = [NSMutableArray array];
                TRCollectKey(gj, @"guideEntryRenderer", entries, 0);
                NSMutableSet *set = [NSMutableSet set];
                for (id en in entries) {
                    NSString *cid = [en isKindOfClass:[NSDictionary class]] ? TRDig(en, @[@"navigationEndpoint", @"browseEndpoint", @"browseId"]) : nil;
                    if ([cid hasPrefix:@"UC"]) [set addObject:cid];
                }
                @synchronized ([NSProcessInfo processInfo]) { [gTRSubs release]; gTRSubs = [set retain]; }
                gTRSubsAt = [NSDate timeIntervalSinceReferenceDate];
                NSLog(@"[TubeReplacer] subscriptions known: %lu", (unsigned long)[set count]);
            }
        } @catch (NSException *e) {}
        gTRSubsBusy = NO;
    });
    static NSTimeInterval lastMenu = 0;
    NSTimeInterval nowM = [NSDate timeIntervalSinceReferenceDate];
    BOOL needId = !gTRMyChannel || ![gTRProfileName length] || ![gTRProfilePhoto length];
    if (needId && nowM - lastMenu > 4) { lastMenu = nowM; TRPostInnerTube(@"account/account_menu", @{}, ^(NSDictionary *aj, NSInteger ac, NSError *ae) {
        @try {
            NSMutableArray *links = [NSMutableArray array];
            if (aj && ac < 400) TRCollectKey(aj, @"compactLinkRenderer", links, 0);
            for (id l in links) {
                NSString *cid = [l isKindOfClass:[NSDictionary class]] ? TRDig(l, @[@"navigationEndpoint", @"browseEndpoint", @"browseId"]) : nil;
                if ([cid hasPrefix:@"UC"]) { gTRMyChannel = [cid copy]; break; }
            }
            if (!gTRMyChannel && aj && ac < 400) {
                // the current menu keeps the channel link elsewhere: the first channel id in it is the account's own
                NSMutableArray *ids = [NSMutableArray array];
                TRCollectKey(aj, @"browseId", ids, 0);
                for (id i in ids) if ([i isKindOfClass:[NSString class]] && [i hasPrefix:@"UC"] && [i length] > 20) { gTRMyChannel = [i copy]; break; }
            }
            if (aj && ac < 400) {
                // the YouTube identity (channel name + photo) of the signed-in account
                id an = TRFindKey(aj, @"accountName", 0), ap = TRFindKey(aj, @"accountPhoto", 0);
                NSString *nm = TRTextOf(an);
                NSArray *th = [ap isKindOfClass:[NSDictionary class]] ? ap[@"thumbnails"] : nil;
                NSString *pu = [th isKindOfClass:[NSArray class]] && [th count] ? th[0][@"url"] : nil;
                if ([nm length]) gTRProfileName = [nm copy];
                if ([pu length]) gTRProfilePhoto = [pu copy];
                id hh = TRFindKey(aj, @"channelHandle", 0);
                NSString *hs = TRTextOf(hh);
                if ([hs length] && !gTRProfileHandle) gTRProfileHandle = [hs copy];
                NSLog(@"[TubeReplacer] account menu identity: name=%@ photo=%@ handle=%@", nm ?: @"-", [pu length] ? @"yes" : @"no", hs ?: @"-");
            }
            NSLog(@"[TubeReplacer] own channel: %@ (account menu http=%ld)", gTRMyChannel ?: @"unknown", (long)ac);
            { NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
              if ([gTRProfileName length]) [ud setObject:gTRProfileName forKey:@"TRIdName"];
              if ([gTRProfilePhoto length]) [ud setObject:gTRProfilePhoto forKey:@"TRIdPhoto"];
              if ([gTRMyChannel length]) [ud setObject:gTRMyChannel forKey:@"TRIdChannel"]; }
        } @catch (NSException *e) {}
    }); }
}
// myprofile.x hands over the account's YouTube identity (name, @handle, photo); the channel id is resolved from the handle
void TRNoteProfile(NSString *name, NSString *handle, NSString *photo) {
    if ([name length]) gTRProfileName = [name copy];
    if ([photo length]) gTRProfilePhoto = [photo copy];
    if ([handle length]) gTRProfileHandle = [handle copy];
    if (gTRMyChannel || ![handle length] || [handle isEqualToString:@"1"]) return;
    NSString *h = [handle hasPrefix:@"@"] ? handle : [@"@" stringByAppendingString:handle];
    TRPostInnerTube(@"navigation/resolve_url", @{ @"url": [@"https://www.youtube.com/" stringByAppendingString:h] }, ^(NSDictionary *rj, NSInteger rc, NSError *re) {
        NSString *cid = rj ? TRDig(rj, @[@"endpoint", @"browseEndpoint", @"browseId"]) : nil;
        if ([cid hasPrefix:@"UC"]) gTRMyChannel = [cid copy];
        NSLog(@"[TubeReplacer] own channel from handle %@: %@ (http=%ld)", h, gTRMyChannel ?: @"unknown", (long)rc);
    });
}
static NSDictionary *TRSubscribeButtonFor(NSString *cid, BOOL subscribed) {
    if (![cid length] || TRIsOwnChannel(cid)) return nil; // no subscribe button on your own channel
    NSMutableDictionary *b = [NSMutableDictionary dictionaryWithDictionary:@{
        @"channelId": cid, @"enabled": @YES, @"subscribed": @(subscribed || TRIsSubscribed(cid)), @"type": @"FREE", @"showPreferences": @NO,
        @"buttonText": @{ @"runs": @[ @{ @"text": @"Subscribe" } ] },
        @"subscribedButtonText": @{ @"runs": @[ @{ @"text": @"Subscribed" } ] },
        @"unsubscribedButtonText": @{ @"runs": @[ @{ @"text": @"Subscribe" } ] },
        @"unsubscribeButtonText": @{ @"runs": @[ @{ @"text": @"Unsubscribe" } ] },
        // the app picks subscribe/unsubscribe out of this list
        @"serviceEndpoints": @[ @{ @"subscribeEndpoint": @{ @"channelIds": @[cid] } },
                                @{ @"unsubscribeEndpoint": @{ @"channelIds": @[cid] } } ] }];
    // 11.x+ draws its switch in the newer look for style type 4 (10.x has no such style)
    return @{ @"subscribeButtonRenderer": b };
}

// Dislike count from the Return YouTube Dislike API (the web no longer exposes it).
static NSString *TRFormatShortCount(long long n) {
    if (n < 1000) return [NSString stringWithFormat:@"%lld", n];
    double v; NSString *suf;
    if (n < 1000000) { v = n / 1000.0; suf = @"K"; } else if (n < 1000000000LL) { v = n / 1000000.0; suf = @"M"; } else { v = n / 1000000000.0; suf = @"B"; }
    NSString *f = v < 10 ? [NSString stringWithFormat:@"%.1f", v] : [NSString stringWithFormat:@"%.0f", v];
    if ([f hasSuffix:@".0"]) f = [f substringToIndex:[f length] - 2];
    return [f stringByAppendingString:suf];
}
static NSString *TRRYDDislikeText(NSString *vid) {
    if (![vid length]) return nil;
    static NSMutableDictionary *cache = nil;
    @synchronized ([NSProcessInfo processInfo]) {
        if (!cache) cache = [[NSMutableDictionary alloc] init];
        if (cache[vid]) return [cache[vid] length] ? cache[vid] : nil;
    }
    NSString *res = @"";
    @try {
        NSURLRequest *rq = [NSURLRequest requestWithURL:[NSURL URLWithString:[@"https://returnyoutubedislikeapi.com/votes?videoId=" stringByAppendingString:vid]] cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:4];
        NSURLResponse *resp = nil; NSError *err = nil;
        NSData *dt = [NSURLConnection sendSynchronousRequest:rq returningResponse:&resp error:&err];
        id j = [dt length] ? [NSJSONSerialization JSONObjectWithData:dt options:0 error:nil] : nil;
        id dl = [j isKindOfClass:[NSDictionary class]] ? j[@"dislikes"] : nil;
        if ([dl respondsToSelector:@selector(longLongValue)]) res = TRFormatShortCount([dl longLongValue]);
        NSLog(@"[TubeReplacer] RYD %@ -> %@ err=%@", vid, res, err);
        if (!dt) return nil; // network failure: do not cache
    } @catch (NSException *e) {}
    @synchronized ([NSProcessInfo processInfo]) { cache[vid] = res; }
    return [res length] ? res : nil;
}
// channel lists: the v11-v13 look (style type 4); the header and watch page keep the classic button
static NSDictionary *TRSubscribeButtonNewLook(NSString *cid) {
    // exactly what the channel header uses: the plain renderer without the FREE type or a style
    NSDictionary *sb = TRSubscribeButtonFor(cid, NO);
    if (!sb) return nil;
    NSMutableDictionary *b = [[sb[@"subscribeButtonRenderer"] mutableCopy] autorelease];
    [b removeObjectForKey:@"type"];
    return @{ @"subscribeButtonRenderer": b };
}
static NSArray *TRImageSources(id sources) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *x in ([sources isKindOfClass:[NSArray class]] ? sources : @[]))
        if ([x[@"url"] isKindOfClass:[NSString class]]) [a addObject:@{ @"url": x[@"url"], @"width": x[@"width"] ?: @0, @"height": x[@"height"] ?: @0 }];
    return a;
}

// lockupViewModel (current web/mweb lists) -> compactVideoRenderer / compactPlaylistRenderer
static NSDictionary *TRFromLockup(NSDictionary *l) {
    NSString *cid = l[@"contentId"], *type = l[@"contentType"] ?: @"";
    if (![cid length]) return nil;
    NSString *title = TRTextOf(TRDig(l, @[@"metadata", @"lockupMetadataViewModel", @"title"]));
    NSArray *sources = TRDig(l, @[@"contentImage", @"thumbnailViewModel", @"image", @"sources"]);
    if (![sources isKindOfClass:[NSArray class]]) sources = TRDig(l, @[@"contentImage", @"collectionThumbnailViewModel", @"primaryThumbnail", @"thumbnailViewModel", @"image", @"sources"]);
    NSMutableArray *thumbs = [NSMutableArray array];
    for (NSDictionary *s in ([sources isKindOfClass:[NSArray class]] ? sources : @[]))
        if ([s[@"url"] isKindOfClass:[NSString class]]) [thumbs addObject:@{ @"url": s[@"url"], @"width": s[@"width"] ?: @0, @"height": s[@"height"] ?: @0 }];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *row in ([TRDig(l, @[@"metadata", @"lockupMetadataViewModel", @"metadata", @"contentMetadataViewModel", @"metadataRows"]) isKindOfClass:[NSArray class]] ? TRDig(l, @[@"metadata", @"lockupMetadataViewModel", @"metadata", @"contentMetadataViewModel", @"metadataRows"]) : @[]))
        for (NSDictionary *p in ([row[@"metadataParts"] isKindOfClass:[NSArray class]] ? row[@"metadataParts"] : @[])) {
            NSString *s = TRTextOf(p[@"text"]); if ([s length]) [parts addObject:s];
        }
    NSString *length = nil;
    NSArray *overlays = TRDig(l, @[@"contentImage", @"thumbnailViewModel", @"overlays"]);
    if (![overlays isKindOfClass:[NSArray class]]) overlays = TRDig(l, @[@"contentImage", @"collectionThumbnailViewModel", @"primaryThumbnail", @"thumbnailViewModel", @"overlays"]);
    for (NSDictionary *o in ([overlays isKindOfClass:[NSArray class]] ? overlays : @[])) {
        NSArray *badges = TRDig(o, @[@"thumbnailOverlayBadgeViewModel", @"thumbnailBadges"]);
        for (NSDictionary *b in ([badges isKindOfClass:[NSArray class]] ? badges : @[])) {
            NSString *s = TRTextOf(TRDig(b, @[@"thumbnailBadgeViewModel", @"text"]));
            if ([s length]) length = s;
        }
    }
    if (![length length]) {
        NSArray *bo = TRDig(l, @[@"contentImage", @"thumbnailViewModel", @"overlays"]);
        if (![bo isKindOfClass:[NSArray class]]) bo = @[];
        for (NSDictionary *o in bo) {
            NSArray *bb = TRDig(o, @[@"thumbnailBottomOverlayViewModel", @"badges"]);
            for (NSDictionary *b in ([bb isKindOfClass:[NSArray class]] ? bb : @[])) {
                NSString *s = TRTextOf(TRDig(b, @[@"thumbnailBadgeViewModel", @"text"]));
                if ([s length]) length = s;
            }
        }
    }
    // inside a channel the author part is missing, so classify the parts instead of trusting positions
    NSString *channel = nil, *views = nil, *when = nil;
    for (NSString *p in parts) {
        NSString *lp = [p lowercaseString];
        if (!views && ([lp rangeOfString:@"view"].location != NSNotFound || [lp rangeOfString:@"watching"].location != NSNotFound || [lp rangeOfString:@"waiting"].location != NSNotFound || [lp hasSuffix:@"subscribers"] || [lp hasSuffix:@"subscriber"])) views = p;
        else if (!when && ([lp rangeOfString:@" ago"].location != NSNotFound || [lp hasPrefix:@"streamed"] || [lp hasPrefix:@"premiered"] || [lp hasPrefix:@"updated"] || [lp hasPrefix:@"scheduled"] || [lp hasPrefix:@"live"])) when = p;
        else if (!channel && !views && !when) channel = p;
        else if (!channel) channel = p;
    }
    if ([type rangeOfString:@"CHANNEL"].location != NSNotFound) {
        NSMutableDictionary *c = [NSMutableDictionary dictionary];
        c[@"channelId"] = cid;
        if (title) { c[@"title"] = TRSimpleText(title); c[@"displayName"] = TRSimpleText(title); }
        NSArray *avs = TRDig(l, @[@"contentImage", @"decoratedAvatarViewModel", @"avatar", @"avatarViewModel", @"image", @"sources"]);
        if (![avs isKindOfClass:[NSArray class]]) avs = sources;
        if ([TRImageSources(avs) count]) c[@"thumbnail"] = @{ @"thumbnails": TRImageSources(avs) };
        if (views) c[@"subscriberCountText"] = TRSimpleText(views);
        c[@"navigationEndpoint"] = @{ @"browseEndpoint": @{ @"browseId": cid } };
        { NSDictionary *csb = TRSubscribeButtonNewLook(cid); if (csb) c[@"subscribeButton"] = csb; else [c removeObjectForKey:@"subscribeButton"]; } // v11-13 style switch; none for your own channel
        return @{ @"compactChannelRenderer": c };
    }
    if ([type rangeOfString:@"PLAYLIST"].location != NSNotFound || [type rangeOfString:@"PODCAST"].location != NSNotFound) {
        NSMutableDictionary *p = [NSMutableDictionary dictionary];
        p[@"playlistId"] = cid;
        if (title) p[@"title"] = TRSimpleText(title);
        if ([thumbs count]) {
            p[@"thumbnail"] = @{ @"thumbnails": thumbs };
            p[@"thumbnailRenderer"] = @{ @"playlistVideoThumbnailRenderer": @{ @"thumbnail": @{ @"thumbnails": thumbs } } };
        }
        if (channel) p[@"shortBylineText"] = TRSimpleText(channel);
        if (length) { p[@"videoCountText"] = TRSimpleText(length); p[@"videoCountShortText"] = TRSimpleText(length); }
        p[@"navigationEndpoint"] = @{ @"browseEndpoint": @{ @"browseId": [@"VL" stringByAppendingString:cid] } };
        return @{ @"compactPlaylistRenderer": p };
    }
    if ([type rangeOfString:@"VIDEO"].location == NSNotFound && [type length]) return nil;
    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    v[@"videoId"] = cid;
    if (title) v[@"title"] = TRSimpleText(title);
    if ([thumbs count]) v[@"thumbnail"] = @{ @"thumbnails": thumbs };
    if (channel) {
        // the lockup keeps the channel's id in the avatar/name tap commands: put it on the byline like the old renderers had it
        NSString *chanId = nil;
        NSMutableArray *bids = [NSMutableArray array];
        TRCollectAll(TRDig(l, @[@"metadata"]), @"browseEndpoint", bids, 0);
        for (id be in bids) { NSString *b = [be isKindOfClass:[NSDictionary class]] ? be[@"browseId"] : nil; if ([b hasPrefix:@"UC"] && [b length] > 10) { chanId = b; break; } }
        if (chanId) {
            NSDictionary *by = @{ @"runs": @[ @{ @"text": channel, @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": chanId } } } ] };
            v[@"longBylineText"] = by; v[@"shortBylineText"] = by;
        } else { v[@"longBylineText"] = TRSimpleText(channel); v[@"shortBylineText"] = TRSimpleText(channel); }
    }
    if (views) { v[@"viewCountText"] = TRSimpleText(views); v[@"shortViewCountText"] = TRSimpleText(views); }
    if (when) v[@"publishedTimeText"] = TRSimpleText(when);
    {   // the channel's picture sits next to the title in the lockup metadata
        NSArray *cav = TRDig(l, @[@"metadata", @"lockupMetadataViewModel", @"image", @"decoratedAvatarViewModel", @"avatar", @"avatarViewModel", @"image", @"sources"]);
        if (![TRImageSources(cav) count]) cav = TRDig(l, @[@"metadata", @"lockupMetadataViewModel", @"image", @"avatarViewModel", @"image", @"sources"]);
        if ([TRImageSources(cav) count]) v[@"channelThumbnail"] = @{ @"thumbnails": TRImageSources(cav) };
    }
    if (length) {
        v[@"lengthText"] = TRSimpleText(length);
        // the cells draw the duration badge from the time-status overlay
        v[@"thumbnailOverlays"] = @[ @{ @"thumbnailOverlayTimeStatusRenderer": @{ @"text": TRSimpleText(length), @"style": @"DEFAULT" } } ];
    }
    // inside a playlist the tap command carries the playlist id and position: keep them, or /next
    // would be requested for the lone video instead of the playlist
    NSMutableDictionary *we = [NSMutableDictionary dictionaryWithObject:cid forKey:@"videoId"];
    NSDictionary *tapWE = TRDig(l, @[@"rendererContext", @"commandContext", @"onTap", @"innertubeCommand", @"watchEndpoint"]);
    if ([tapWE isKindOfClass:[NSDictionary class]]) {
        for (NSString *k in @[@"playlistId", @"index", @"params", @"playerParams", @"startTimeSeconds"])
            if (tapWE[k]) we[k] = tapWE[k];
    }
    v[@"navigationEndpoint"] = @{ @"watchEndpoint": we };
    return @{ @"compactVideoRenderer": v };
}

// videoWithContextRenderer (mobile web) -> compactVideoRenderer
static NSDictionary *TRFromVideoWithContext(NSDictionary *r) {
    NSString *vid = r[@"videoId"];
    if (![vid length]) return nil;
    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    v[@"videoId"] = vid;
    if (r[@"headline"]) v[@"title"] = r[@"headline"];
    if (r[@"thumbnail"]) v[@"thumbnail"] = r[@"thumbnail"];
    if (r[@"shortBylineText"]) { v[@"shortBylineText"] = r[@"shortBylineText"]; v[@"longBylineText"] = r[@"shortBylineText"]; }
    if (r[@"lengthText"]) v[@"lengthText"] = r[@"lengthText"];
    if (r[@"shortViewCountText"]) { v[@"viewCountText"] = r[@"shortViewCountText"]; v[@"shortViewCountText"] = r[@"shortViewCountText"]; }
    if (r[@"publishedTimeText"]) v[@"publishedTimeText"] = r[@"publishedTimeText"];
    return @{ @"compactVideoRenderer": v };
}

static NSString *TRContinuationToken(id element) { // continuationItemRenderer -> token
    return TRDig(element, @[@"continuationItemRenderer", @"continuationEndpoint", @"continuationCommand", @"token"]);
}

static id TRFix(id node);

// The apps only register cells for the "compact" renderers (checked in each binary's cell factory).
static NSString *TRCompactKeyFor(NSString *key) {
    static NSDictionary *m = nil;
    if (!m) m = [@{ @"videoRenderer": @"compactVideoRenderer", @"gridVideoRenderer": @"compactVideoRenderer",
                    @"channelRenderer": @"compactChannelRenderer", @"gridChannelRenderer": @"compactChannelRenderer",
                    @"playlistRenderer": @"compactPlaylistRenderer", @"gridPlaylistRenderer": @"compactPlaylistRenderer" } retain];
    return m[key];
}

// Fix an array of renderers; collects continuation tokens found in it.
static NSArray *TRFixArray(NSArray *in, NSString **token) {
    NSMutableArray *out = [NSMutableArray array];
    for (id e in in) {
        NSString *tk = TRContinuationToken(e);
        if (tk) { if (token) *token = tk; continue; }
        id f = TRFix(e);
        if ([f isKindOfClass:[NSDictionary class]] && [(NSDictionary *)f count] == 0) continue;
        // the apps draw compact renderers directly inside a section, not inside a grid
        NSDictionary *grid = [f isKindOfClass:[NSDictionary class]] ? f[@"gridRenderer"] : nil;
        if ([grid isKindOfClass:[NSDictionary class]] && [grid[@"items"] isKindOfClass:[NSArray class]]) {
            [out addObjectsFromArray:grid[@"items"]];
            NSArray *orig = TRDig(e, @[@"gridRenderer", @"items"]);
            for (id oi in ([orig isKindOfClass:[NSArray class]] ? orig : @[])) { NSString *t2 = TRContinuationToken(oi); if (t2 && token) *token = t2; }
            continue;
        }
        if (f) [out addObject:f];
    }
    return out;
}

static NSArray *TRContinuations(NSString *token) {
    return token ? @[ @{ @"nextContinuationData": @{ @"continuation": token } } ] : nil;
}

static NSDictionary *TRCommentToggle2(int icon, NSString *text, NSString *on, NSString *off, NSString *count);
// A web community post -> the apps' comment cell in its "post" layout (12.x/13.x: attachments + like/dislike/comments toolbar)
static NSDictionary *TRPostThread(NSDictionary *post);
static id TRFix(id node) {
    if ([node isKindOfClass:[NSArray class]]) return TRFixArray(node, NULL);
    if (![node isKindOfClass:[NSDictionary class]]) return node;
    NSDictionary *d = node;

    if (d[@"richItemRenderer"]) { id c = TRFix(TRDig(d, @[@"richItemRenderer", @"content"])); return c ?: @{}; }
    if (d[@"lockupViewModel"]) { id c = TRFromLockup(d[@"lockupViewModel"]); return c ?: @{}; }
    if (d[@"videoWithContextRenderer"]) { id c = TRFromVideoWithContext(d[@"videoWithContextRenderer"]); return c ?: @{}; }
    if (d[@"backstagePostThreadRenderer"] && majorVersion() >= 12) {
        NSDictionary *pp = TRDig(d, @[@"backstagePostThreadRenderer", @"post", @"backstagePostRenderer"]) ?: TRDig(d, @[@"backstagePostThreadRenderer", @"post", @"postRenderer"]);
        NSDictionary *t = [pp isKindOfClass:[NSDictionary class]] ? TRPostThread(pp) : nil;
        return t ?: @{};
    }
    if (d[@"backstagePostThreadRenderer"]) {
        // community post: the apps have no post cell, so show it as a text message
        NSDictionary *post = TRDig(d, @[@"backstagePostThreadRenderer", @"post", @"backstagePostRenderer"]) ?: TRDig(d, @[@"backstagePostThreadRenderer", @"post", @"postRenderer"]);
        if (![post isKindOfClass:[NSDictionary class]]) return @{};
        NSString *author = TRTextOf(post[@"authorText"]) ?: @"";
        NSString *when = TRTextOf(post[@"publishedTimeText"]) ?: @"";
        NSString *body = TRTextOf(post[@"contentText"]) ?: @"";
        NSString *likes = TRTextOf(post[@"voteCount"]) ?: @"";
        NSArray *pimgs = TRImageSources(TRDig(post, @[@"backstageAttachment", @"backstageImageRenderer", @"image", @"thumbnails"]) ?: TRDig(post, @[@"attachment", @"backstageImageRenderer", @"image", @"thumbnails"]));
        if ([pimgs count]) {
            // the apps have no post cell with a picture: draw it as a video-style row whose thumbnail is the image
            NSMutableString *tt = [NSMutableString stringWithString:[body length] ? body : @"(image post)"];
            if ([likes length]) [tt appendFormat:@"  \U0001F44D %@", likes];
            return @{ @"compactVideoRenderer": @{ @"title": TRSimpleText(tt),
                @"thumbnail": @{ @"thumbnails": pimgs },
                @"longBylineText": TRSimpleText([NSString stringWithFormat:@"%@%@%@", author, ([author length] && [when length]) ? @" \u00b7 " : @"", when]),
                @"shortBylineText": TRSimpleText(author) } };
        }
        if (![body length] && post[@"attachment"]) body = @"(video post)";
        NSMutableString *t = [NSMutableString string];
        if ([author length] || [when length]) [t appendFormat:@"%@%@%@\n", author, ([author length] && [when length]) ? @" \u00b7 " : @"", when];
        [t appendString:body];
        if ([likes length]) [t appendFormat:@"\n\U0001F44D %@", likes];
        return @{ @"messageRenderer": @{ @"text": @{ @"runs": @[ @{ @"text": t } ] } } };
    }
    if (d[@"richSectionRenderer"]) {
        // library/home shelves: flatten to a titled run of items (TRFixArray unpacks the grid)
        NSDictionary *shelf = TRDig(d, @[@"richSectionRenderer", @"content", @"richShelfRenderer"]);
        if (![shelf isKindOfClass:[NSDictionary class]]) return @{};
        NSMutableArray *its = [NSMutableArray array];
        NSString *ttl = TRTextOf(shelf[@"title"]);
        if ([ttl length]) [its addObject:@{ @"messageRenderer": @{ @"text": @{ @"runs": @[ @{ @"text": ttl } ] } } }];
        id inner = shelf[@"contents"];
        if ([inner isKindOfClass:[NSArray class]]) [its addObjectsFromArray:TRFixArray(inner, NULL)];
        return [its count] > 1 ? @{ @"gridRenderer": @{ @"items": its } } : @{};
    }
    if (d[@"adSlotRenderer"] || d[@"shortsLockupViewModel"] || d[@"reelShelfRenderer"]) return @{};

    if ([d[@"simpleText"] isKindOfClass:[NSString class]] && [d count] <= 2) // YTIFormattedString has runs only
        return @{ @"runs": @[ @{ @"text": d[@"simpleText"] } ] };
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in d) {
        id v = d[key];
        if ([key isEqualToString:@"richGridRenderer"] && [v isKindOfClass:[NSDictionary class]]) {
            NSString *token = nil;
            NSArray *items = TRFixArray(v[@"contents"] ?: @[], &token);
            NSMutableDictionary *sl = [NSMutableDictionary dictionary];
            sl[@"contents"] = [items count] ? @[ @{ @"itemSectionRenderer": @{ @"contents": items } } ] : @[];
            if (token) sl[@"continuations"] = TRContinuations(token);
            out[@"sectionListRenderer"] = sl;
            continue;
        }
        if ([v isKindOfClass:[NSArray class]] && ([key isEqualToString:@"contents"] || [key isEqualToString:@"continuationItems"])) {
            NSString *token = nil;
            NSArray *items = TRFixArray(v, &token);
            out[key] = items;
            if (token && !d[@"continuations"]) out[@"continuations"] = TRContinuations(token);
            continue;
        }
        NSString *ck = TRCompactKeyFor(key);
        if (ck && [v isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *c = [[TRFix(v) mutableCopy] autorelease];
            if ([ck isEqualToString:@"compactVideoRenderer"]) {
                if (!c[@"longBylineText"] && c[@"ownerText"]) c[@"longBylineText"] = c[@"ownerText"];
                if (!c[@"shortBylineText"] && c[@"ownerText"]) c[@"shortBylineText"] = c[@"ownerText"];
                if (!c[@"lengthText"]) {
                    for (id o in ([c[@"thumbnailOverlays"] isKindOfClass:[NSArray class]] ? c[@"thumbnailOverlays"] : @[])) {
                        id tx = TRDig(o, @[@"thumbnailOverlayTimeStatusRenderer", @"text"]);
                        if (tx) { c[@"lengthText"] = tx; break; }
                    }
                }
                if (!c[@"navigationEndpoint"] && [c[@"videoId"] length]) c[@"navigationEndpoint"] = @{ @"watchEndpoint": @{ @"videoId": c[@"videoId"] } };
                if (!c[@"channelThumbnail"]) {
                    id ct = TRDig(c, @[@"channelThumbnailSupportedRenderers", @"channelThumbnailWithLinkRenderer", @"thumbnail"]) ?: c[@"channelThumbnail"];
                    if ([ct isKindOfClass:[NSDictionary class]]) c[@"channelThumbnail"] = ct;
                }
            } else if ([ck isEqualToString:@"compactChannelRenderer"]) {
                if (!c[@"displayName"] && c[@"title"]) c[@"displayName"] = c[@"title"];
                if ([c[@"channelId"] length]) {
                    NSDictionary *sb = TRSubscribeButtonNewLook(c[@"channelId"]);
                    if (sb) c[@"subscribeButton"] = sb; else { [c removeObjectForKey:@"subscribeButton"]; [c removeObjectForKey:@"subscribeButtonRenderer"]; } // your own channel
                    if (!c[@"navigationEndpoint"]) c[@"navigationEndpoint"] = @{ @"browseEndpoint": @{ @"browseId": c[@"channelId"] } };
                }
            } else if ([ck isEqualToString:@"compactPlaylistRenderer"]) {
                id tl = c[@"thumbnails"] ?: c[@"thumbnailsArray"];
                if (!c[@"thumbnail"] && [tl isKindOfClass:[NSArray class]] && [tl count]) c[@"thumbnail"] = tl[0];
                if (!c[@"thumbnailRenderer"] && [c[@"thumbnail"] isKindOfClass:[NSDictionary class]])
                    c[@"thumbnailRenderer"] = @{ @"playlistVideoThumbnailRenderer": @{ @"thumbnail": c[@"thumbnail"] } };
                NSString *vc = [c[@"videoCount"] isKindOfClass:[NSString class]] ? c[@"videoCount"] : nil;
                if (!c[@"videoCountText"] && vc) c[@"videoCountText"] = TRSimpleText([vc stringByAppendingString:@" videos"]);
                if (!c[@"navigationEndpoint"] && [c[@"playlistId"] length])
                    c[@"navigationEndpoint"] = @{ @"browseEndpoint": @{ @"browseId": [@"VL" stringByAppendingString:c[@"playlistId"]] } };
            }
            out[ck] = c;
            continue;
        }
        if ([key isEqualToString:@"shareEntityServiceEndpoint"] && [v isKindOfClass:[NSDictionary class]] && [v[@"serializedShareEntity"] length]) {
            // the apps' own share sheet (UIActivityViewController) opens from a video endpoint; the entity
            // endpoint wants a share panel the web no longer describes in a form they understand
            NSString *ent = [v[@"serializedShareEntity"] stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
            ent = [ent stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
            while ([ent length] % 4) ent = [ent stringByAppendingString:@"="];
            NSData *ed = [[NSData dataWithBase64EncodedString:ent] retain];
            NSString *evid = nil;
            if ([ed length] > 2) { const uint8_t *eb = [ed bytes]; if (eb[0] == 0x0a && (NSUInteger)eb[1] + 2 <= [ed length]) evid = [[[NSString alloc] initWithBytes:eb + 2 length:eb[1] encoding:NSUTF8StringEncoding] autorelease]; }
            [ed release];
            if ([evid length]) out[@"shareVideoEndpoint"] = @{ @"videoId": evid };
            else out[@"shareEntityEndpoint"] = @{ @"serializedShareEntity": v[@"serializedShareEntity"] };
            continue;
        }
        out[key] = TRFix(v);
        if ([key isEqualToString:@"sectionListRenderer"] && [out[key] isKindOfClass:[NSDictionary class]]) {
            // loose items directly in a section list crash/stall the apps: wrap them in item sections
            NSArray *cs = out[key][@"contents"];
            if ([cs isKindOfClass:[NSArray class]]) {
                NSMutableArray *wrapped = [NSMutableArray array]; NSMutableArray *run = nil; BOOL changed = NO;
                NSSet *ok = [NSSet setWithObjects:@"itemSectionRenderer", @"shelfRenderer", @"continuationItemRenderer", @"searchPyvRenderer", nil];
                for (id e in cs) {
                    BOOL good = ![e isKindOfClass:[NSDictionary class]];
                    for (NSString *k in ([e isKindOfClass:[NSDictionary class]] ? [e allKeys] : @[])) if ([ok containsObject:k]) good = YES;
                    if (good) { run = nil; [wrapped addObject:e]; }
                    else { if (!run) { run = [NSMutableArray array]; [wrapped addObject:@{ @"itemSectionRenderer": @{ @"contents": run } }]; } [run addObject:e]; changed = YES; }
                }
                if (changed) { NSMutableDictionary *m = [[out[key] mutableCopy] autorelease]; m[@"contents"] = wrapped; out[key] = m; }
            }
        }
    }
    return out;
}


static id TRFindKey(id n, NSString *key, int depth) {
    if (depth > 30) return nil;
    if ([n isKindOfClass:[NSDictionary class]]) {
        if (n[key]) return n[key];
        for (id v in [n allValues]) { id f = TRFindKey(v, key, depth + 1); if (f) return f; }
    } else if ([n isKindOfClass:[NSArray class]]) {
        for (id v in n) { id f = TRFindKey(v, key, depth + 1); if (f) return f; }
    }
    return nil;
}

// 13.x replaced videoMetadataRenderer's cell by the "slim" one
static BOOL TRUsesSlimWatch(void) {
    static int c = -1;
    if (c < 0) c = (NSClassFromString(@"YTSlimVideoMetadataCellController") && (!NSClassFromString(@"YTVideoMetadataCellController") || majorVersion() == 12)) ? 1 : 0;
    return c == 1;
}

static long long TRParseCount(NSString *s);
// videoPrimaryInfo/videoSecondaryInfo (current web) -> videoMetadataRenderer/videoOwnerRenderer (what the apps draw)
static void TRTranslateWatchNextModern(NSMutableDictionary *r) {
    id tcol = TRDig(r, @[@"contents", @"twoColumnWatchNextResults"]);
    if (![tcol isKindOfClass:[NSDictionary class]]) return;
    id primary = TRFindKey(tcol[@"results"], @"videoPrimaryInfoRenderer", 0);
    id secondary = TRFindKey(tcol[@"results"], @"videoSecondaryInfoRenderer", 0);
    NSString *vid = TRDig(r, @[@"currentVideoEndpoint", @"watchEndpoint", @"videoId"]);
    if (![vid isKindOfClass:[NSString class]]) { id v2 = TRFindKey(primary, @"videoId", 0); vid = [v2 isKindOfClass:[NSString class]] ? v2 : nil; }
    NSMutableArray *top = [NSMutableArray array];
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    if ([primary isKindOfClass:[NSDictionary class]]) {
        if (primary[@"title"]) meta[@"title"] = primary[@"title"];
        id vc = TRDig(primary, @[@"viewCount", @"videoViewCountRenderer", @"viewCount"]);
        if (vc) meta[@"viewCountText"] = vc;
        id sv = TRDig(primary, @[@"viewCount", @"videoViewCountRenderer", @"shortViewCount"]);
        if (sv) meta[@"shortViewCountText"] = sv;
        if (primary[@"dateText"]) meta[@"dateText"] = primary[@"dateText"];
    }
    if ([secondary isKindOfClass:[NSDictionary class]]) {
        id d = secondary[@"attributedDescription"];
        NSString *content = [d isKindOfClass:[NSDictionary class]] ? d[@"content"] : nil;
        if ([content length]) meta[@"description"] = TRDescriptionRuns(content, vid);
    }
    if (!meta[@"description"]) {
        // the current web page keeps the description elsewhere: the description engagement panel, or the microformat
        NSString *dc = nil;
        id body = TRFindKey(r, @"attributedDescriptionBodyText", 0);
        if ([body isKindOfClass:[NSDictionary class]] && [body[@"content"] isKindOfClass:[NSString class]]) dc = body[@"content"];
        if (![dc length]) {
            id md = TRFindKey(r, @"microformatDataRenderer", 0);
            id dd = [md isKindOfClass:[NSDictionary class]] ? md[@"description"] : nil;
            if ([dd isKindOfClass:[NSString class]]) dc = dd;
            else if ([dd isKindOfClass:[NSDictionary class]]) dc = dd[@"simpleText"];
        }
        if (![dc length]) {
            id pm = TRFindKey(r, @"playerMicroformatRenderer", 0);
            id dd = [pm isKindOfClass:[NSDictionary class]] ? pm[@"description"] : nil;
            if ([dd isKindOfClass:[NSDictionary class]]) dc = dd[@"simpleText"];
        }
        if ([dc length]) meta[@"description"] = TRDescriptionRuns(dc, vid);
    }
    if (meta[@"description"]) { meta[@"description_p"] = meta[@"description"]; }
    // like count: the current web UI only keeps it as the like button's label ("12K")
    id lvm = [primary isKindOfClass:[NSDictionary class]] ? TRFindKey(primary, @"likeButtonViewModel", 0) : nil;
    while ([lvm isKindOfClass:[NSDictionary class]] && lvm[@"likeButtonViewModel"]) lvm = lvm[@"likeButtonViewModel"];
    NSString *likeText = nil;
    if ([lvm isKindOfClass:[NSDictionary class]]) {
        id t = TRFindKey(lvm, @"title", 0);
        if ([t isKindOfClass:[NSString class]]) likeText = t;
    }
    if (![likeText length] && [primary isKindOfClass:[NSDictionary class]]) {
        id lc = TRFindKey(primary, @"likeCountText", 0); // older layout
        if ([lc isKindOfClass:[NSString class]]) likeText = lc;
    }
    if ([likeText length]) { meta[@"likesCount"] = TRSimpleText(likeText); meta[@"likesCountWithLike"] = TRSimpleText(likeText); }
    meta[@"allowRatings"] = @YES; meta[@"allowActions"] = @YES;
    if (vid) meta[@"videoId"] = vid;
    if ([vid length]) {
        // like / dislike buttons: the apps toggle them through like/like, like/dislike and like/removelike
        NSString *status = @"INDIFFERENT";
        id lv2 = [primary isKindOfClass:[NSDictionary class]] ? TRFindKey(primary, @"likeButtonViewModel", 0) : nil;
        id tg = [lv2 isKindOfClass:[NSDictionary class]] ? TRFindKey(lv2, @"toggleButtonViewModel", 0) : nil;
        if ([tg isKindOfClass:[NSDictionary class]] && [tg[@"isToggled"] boolValue]) status = @"LIKE";
        id dv = [primary isKindOfClass:[NSDictionary class]] ? TRFindKey(primary, @"dislikeButtonViewModel", 0) : nil;
        id dtg = [dv isKindOfClass:[NSDictionary class]] ? TRFindKey(dv, @"toggleButtonViewModel", 0) : nil;
        if ([dtg isKindOfClass:[NSDictionary class]] && [dtg[@"isToggled"] boolValue]) status = @"DISLIKE";
        NSMutableDictionary *lb = [NSMutableDictionary dictionaryWithDictionary:@{
            @"target": @{ @"videoId": vid }, @"likeStatus": status, @"likesAllowed": @YES,
            @"dislikeCountText": TRSimpleText(TRRYDDislikeText(vid) ?: @"Dislike") }];
        if ([likeText length]) {
            lb[@"likeCountText"] = TRSimpleText(likeText); lb[@"likeCountWithLikeText"] = TRSimpleText(likeText); lb[@"likeCountWithUnlikeText"] = TRSimpleText(likeText);
            lb[@"likeCount"] = @(TRParseCount(likeText));
        }
        meta[@"likeButton"] = @{ @"likeButtonRenderer": lb };
        meta[@"likeStatus"] = status;
        {   // share button: the app opens the share panel from the entity endpoint (no endpoint = "please try again")
            NSMutableData *pb = [NSMutableData data]; uint8_t hdr[2] = { 0x0a, (uint8_t)[vid length] };
            [pb appendBytes:hdr length:2]; [pb appendData:[vid dataUsingEncoding:NSUTF8StringEncoding]];
            NSString *ent = [pb base64EncodedString];
            meta[@"shareButton"] = @{ @"buttonRenderer": @{ @"style": @"STYLE_DEFAULT", @"size": @"SIZE_DEFAULT", @"isDisabled": @NO,
                @"text": TRSimpleText(@"Share"),
                @"navigationEndpoint": @{ @"shareEntityEndpoint": @{ @"serializedShareEntity": ent } },
                @"serviceEndpoint": @{ @"shareEntityEndpoint": @{ @"serializedShareEntity": ent } } } };
            meta[@"shareUrl"] = [@"https://youtu.be/" stringByAppendingString:vid];
        }
    }
    [top addObject:@{ @"videoMetadataRenderer": meta }];
    id owner = [secondary isKindOfClass:[NSDictionary class]] ? TRDig(secondary, @[@"owner", @"videoOwnerRenderer"]) : nil;
    if ([owner isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *mo = [[owner mutableCopy] autorelease];
        if (![TRDig(mo, @[@"subscribeButton", @"subscribeButtonRenderer"]) isKindOfClass:[NSDictionary class]]) {
            NSString *ocid = TRDig(mo, @[@"navigationEndpoint", @"browseEndpoint", @"browseId"]);
            NSDictionary *sb = TRSubscribeButtonFor(ocid, NO);
            if (sb) mo[@"subscribeButton"] = sb;
        }
        [top addObject:@{ @"videoOwnerRenderer": mo }];
    }
    if (TRUsesSlimWatch()) {
        // 13.x draws the watch header from slimVideoMetadataRenderer (title, subtitle, owner, like buttons)
        NSString *views = TRTextOf(meta[@"viewCountText"]) ?: TRTextOf(meta[@"shortViewCountText"]) ?: @"";
        NSString *date = TRTextOf(meta[@"dateText"]) ?: @"";
        NSString *sub = [views length] ? views : date; // views only (no date next to them)
        NSMutableDictionary *slim = [NSMutableDictionary dictionary];
        if (meta[@"videoId"]) slim[@"videoId"] = meta[@"videoId"];
        if (meta[@"title"]) slim[@"title"] = meta[@"title"];
        if ([sub length]) { slim[@"collapsedSubtitle"] = TRSimpleText(sub); slim[@"expandedSubtitle"] = TRSimpleText(sub); }
        if (meta[@"dateText"]) slim[@"dateText"] = meta[@"dateText"];
        if (meta[@"description"]) { slim[@"description"] = meta[@"description"]; slim[@"description_p"] = meta[@"description"]; }
        NSDictionary *own = [owner isKindOfClass:[NSDictionary class]] ? owner : nil;
        if (own) {
            NSMutableDictionary *so = [NSMutableDictionary dictionary];
            if (own[@"thumbnail"]) so[@"thumbnail"] = own[@"thumbnail"];
            if (own[@"title"]) so[@"title"] = own[@"title"];
            if (own[@"navigationEndpoint"]) so[@"navigationEndpoint"] = own[@"navigationEndpoint"];
            NSString *ocid = TRDig(own, @[@"navigationEndpoint", @"browseEndpoint", @"browseId"]);
            NSDictionary *sb = TRSubscribeButtonFor(ocid, NO);
            if (sb) {
                NSMutableDictionary *sbr = [[sb[@"subscribeButtonRenderer"] mutableCopy] autorelease];
                id cnt = own[@"subscriberCountText"];
                if (cnt) { sbr[@"shortSubscriberCountText"] = cnt; sbr[@"longSubscriberCountText"] = cnt; }
                so[@"subscribeButton"] = @{ @"subscribeButtonRenderer": sbr };
            }
            slim[@"owner"] = @{ @"slimOwnerRenderer": so };
        }
        NSString *svid = meta[@"videoId"];
        if ([svid length]) {
            NSString *lt = TRTextOf(meta[@"likesCount"]) ?: @"Like";
            NSDictionary *likeBtn = @{ @"slimMetadataToggleButtonRenderer": @{
                @"target": @{ @"videoId": svid }, @"likeStatus": @"INDIFFERENT", @"isLike": @YES,
                @"button": @{ @"toggleButtonRenderer": @{
                    @"isToggled": @NO, @"defaultIcon": @{ @"iconType": @16 }, @"toggledIcon": @{ @"iconType": @16 },
                    @"defaultText": TRSimpleText(lt), @"toggledText": TRSimpleText(lt),
                    @"defaultServiceEndpoint": @{ @"likeEndpoint": @{ @"status": @"LIKE", @"target": @{ @"videoId": svid } } },
                    @"toggledServiceEndpoint": @{ @"likeEndpoint": @{ @"status": @"INDIFFERENT", @"target": @{ @"videoId": svid } } } } } } };
            NSDictionary *dislikeBtn = @{ @"slimMetadataToggleButtonRenderer": @{
                @"target": @{ @"videoId": svid }, @"likeStatus": @"INDIFFERENT", @"isDislike": @YES,
                @"button": @{ @"toggleButtonRenderer": @{
                    @"isToggled": @NO, @"defaultIcon": @{ @"iconType": @51 }, @"toggledIcon": @{ @"iconType": @51 },
                    @"defaultText": TRSimpleText(TRRYDDislikeText(svid) ?: @"Dislike"), @"toggledText": TRSimpleText(TRRYDDislikeText(svid) ?: @"Dislike"),
                    @"defaultServiceEndpoint": @{ @"likeEndpoint": @{ @"status": @"DISLIKE", @"target": @{ @"videoId": svid } } },
                    @"toggledServiceEndpoint": @{ @"likeEndpoint": @{ @"status": @"INDIFFERENT", @"target": @{ @"videoId": svid } } } } } } };
            NSMutableArray *btns = [NSMutableArray arrayWithObjects:likeBtn, dislikeBtn, nil];
            NSDictionary *shareEp = meta[@"shareButton"][@"buttonRenderer"][@"navigationEndpoint"];
            if (shareEp) [btns addObject:@{ @"slimMetadataButtonRenderer": @{ @"button": @{ @"buttonRenderer": @{
                @"style": @"STYLE_DEFAULT", @"size": @"SIZE_DEFAULT", @"isDisabled": @NO, @"text": TRSimpleText(@"Share"),
                @"icon": @{ @"iconType": @48 }, @"navigationEndpoint": shareEp, @"serviceEndpoint": shareEp } } } }];
            // Save: the app's own download button (placeholder until it knows the video can be saved)
            [btns addObject:@{ @"slimMetadataButtonRenderer": @{ @"isOfflineButtonPlaceholder": @YES, @"button": @{ @"buttonRenderer": @{
                @"style": @"STYLE_DEFAULT", @"size": @"SIZE_DEFAULT", @"isDisabled": @NO, @"text": TRSimpleText(@"Save"),
                @"icon": @{ @"iconType": @57 },
                @"serviceEndpoint": @{ @"offlineVideoEndpoint": @{ @"videoId": svid } } } } } }];
            [btns addObject:@{ @"slimMetadataButtonRenderer": @{ @"button": @{ @"buttonRenderer": @{
                @"style": @"STYLE_DEFAULT", @"size": @"SIZE_DEFAULT", @"isDisabled": @NO, @"text": TRSimpleText(@"Add to"),
                @"icon": @{ @"iconType": @46 }, @"navigationEndpoint": @{ @"addToPlaylistEndpoint": @{ @"videoId": svid } } } } } }];
            slim[@"buttons"] = btns;
        }
        [top removeAllObjects];
        [top addObject:@{ @"slimVideoMetadataRenderer": slim }];
    }
    // related videos
    NSMutableArray *related = [NSMutableArray array];
    id sec = tcol[@"secondaryResults"];
    NSMutableArray *stack = sec ? [NSMutableArray arrayWithObject:sec] : [NSMutableArray array];
    while ([stack count] && [related count] < 40) {
        id n = [stack objectAtIndex:0]; [stack removeObjectAtIndex:0];
        if ([n isKindOfClass:[NSDictionary class]]) {
            if (n[@"compactVideoRenderer"]) { [related addObject:@{ @"compactVideoRenderer": n[@"compactVideoRenderer"] }]; continue; }
            [stack addObjectsFromArray:[n allValues]];
        } else if ([n isKindOfClass:[NSArray class]]) [stack addObjectsFromArray:n];
    }
    NSMutableArray *sections = [NSMutableArray arrayWithObject:@{ @"itemSectionRenderer": @{ @"contents": top } }];
    if (NSClassFromString(@"YTDistillerCommentsFeedSectionController") && !NSClassFromString(@"YTCommentThreadCellController") && [vid length]) {
        // 2.3.1 - 10.x draw comments from a section controller that is created for a commentsRenderer (it then asks the distiller service, see below)
        NSString *chan = TRDig(owner, @[@"navigationEndpoint", @"browseEndpoint", @"browseId"]) ?: @"";
        // the section list accepts commentsRenderer directly (YTISectionListSupportedRenderers); inside an item section it is ignored
        [sections addObject:@{ @"commentsRenderer": @{
            @"videoId": vid, @"channelId": chan, @"ownerId": chan, @"isDistiller": @YES, @"privacyStatus": @0 } }];
    }
    // 13.x draws compactVideoRenderer rows with the same cell as the other versions; the old "Up next" shelf with a vertical list never showed any rows
    if ([related count] && TRUsesSlimWatch()) {
        // 13.x: "Up next" header with the autoplay switch (a shelf must sit directly in the section list, like on 10.2x)
        NSDictionary *tb = @{ @"isToggled": @YES, @"defaultText": TRSimpleText(@"Autoplay"), @"toggledText": TRSimpleText(@"Autoplay") };
        [sections addObject:@{ @"shelfRenderer": @{ @"title": TRSimpleText(@"Up next"),
            @"autonavToggle": @{ @"toggleButtonRenderer": tb },
            @"content": @{ @"verticalListRenderer": @{ @"items": related } } } }];
        NSLog(@"[TubeReplacer] 13.x watch: Up next shelf with %lu video(s)", (unsigned long)[related count]);
    } else if ([related count]) [sections addObject:@{ @"itemSectionRenderer": @{ @"contents": related } }];
    NSMutableDictionary *single = [NSMutableDictionary dictionaryWithObject:@{ @"results": @{ @"contents": sections } } forKey:@"results"];
    id pl = TRDig(tcol, @[@"playlist", @"playlist"]);
    if ([pl isKindOfClass:[NSDictionary class]]) single[@"playlist"] = @{ @"playlist": pl };
    if (TRUsesSlimWatch() && [tcol[@"autoplay"] isKindOfClass:[NSDictionary class]]) single[@"autoplay"] = tcol[@"autoplay"];
    if (majorVersion() >= 11 && !single[@"autoplay"] && [related count] && related[0][@"compactVideoRenderer"]) {
        // 11.x plays the next video from autoplay.sets[].autoplayVideo: use the first suggestion
        single[@"autoplay"] = @{ @"autoplay": @{ @"countDownSecs": @8,
            @"sets": @[ @{ @"autoplayVideo": @{ @"compactVideoRenderer": related[0][@"compactVideoRenderer"] },
                           @"nextButtonVideo": @{ @"compactVideoRenderer": related[0][@"compactVideoRenderer"] } } ] } };
        NSLog(@"[TubeReplacer] %d.x watch: autoplay set from the first suggestion", (int)majorVersion());
    }
    r[@"contents"] = @{ @"singleColumnWatchNextResults": single };
}

static void TRTranslateWatchNextLegacy(NSMutableDictionary *r) {
    id tcol = TRDig(r, @[@"contents", @"twoColumnWatchNextResults"]);
    if (![tcol isKindOfClass:[NSDictionary class]]) return;
    id primary = TRFindKey(tcol[@"results"], @"videoPrimaryInfoRenderer", 0);
    id secondary = TRFindKey(tcol[@"results"], @"videoSecondaryInfoRenderer", 0);
    NSMutableArray *top = [NSMutableArray array];
    NSMutableDictionary *meta = [NSMutableDictionary dictionary];
    if ([primary isKindOfClass:[NSDictionary class]]) {
        if (primary[@"title"]) meta[@"title"] = primary[@"title"];
        id vc = TRDig(primary, @[@"viewCount", @"videoViewCountRenderer", @"viewCount"]);
        if (vc) meta[@"viewCountText"] = vc;
        id sv = TRDig(primary, @[@"viewCount", @"videoViewCountRenderer", @"shortViewCount"]);
        if (sv) meta[@"shortViewCountText"] = sv;
        if (primary[@"dateText"]) meta[@"dateText"] = primary[@"dateText"];
    }
    if ([secondary isKindOfClass:[NSDictionary class]]) {
        id d = secondary[@"attributedDescription"];
        NSString *content = [d isKindOfClass:[NSDictionary class]] ? d[@"content"] : nil;
        if ([content length]) meta[@"description"] = TRSimpleText(content);
    }
    meta[@"allowRatings"] = @YES; meta[@"allowActions"] = @YES;
    id vid = TRDig(r, @[@"currentVideoEndpoint", @"watchEndpoint", @"videoId"]);
    if (vid) meta[@"videoId"] = vid;
    [top addObject:@{ @"videoMetadataRenderer": meta }];
    id owner = [secondary isKindOfClass:[NSDictionary class]] ? TRDig(secondary, @[@"owner", @"videoOwnerRenderer"]) : nil;
    if ([owner isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *mo = [[owner mutableCopy] autorelease];
        if (![TRDig(mo, @[@"subscribeButton", @"subscribeButtonRenderer"]) isKindOfClass:[NSDictionary class]]) {
            NSString *ocid = TRDig(mo, @[@"navigationEndpoint", @"browseEndpoint", @"browseId"]);
            NSDictionary *sb = TRSubscribeButtonFor(ocid, NO);
            if (sb) mo[@"subscribeButton"] = sb;
        }
        [top addObject:@{ @"videoOwnerRenderer": mo }];
    }
    // related videos
    NSMutableArray *related = [NSMutableArray array];
    id sec = tcol[@"secondaryResults"];
    NSMutableArray *stack = sec ? [NSMutableArray arrayWithObject:sec] : [NSMutableArray array];
    while ([stack count] && [related count] < 40) {
        id n = [stack objectAtIndex:0]; [stack removeObjectAtIndex:0];
        if ([n isKindOfClass:[NSDictionary class]]) {
            if (n[@"compactVideoRenderer"]) { [related addObject:@{ @"compactVideoRenderer": n[@"compactVideoRenderer"] }]; continue; }
            [stack addObjectsFromArray:[n allValues]];
        } else if ([n isKindOfClass:[NSArray class]]) [stack addObjectsFromArray:n];
    }
    NSMutableArray *sections = [NSMutableArray arrayWithObject:@{ @"itemSectionRenderer": @{ @"contents": top } }];
    if ([related count]) [sections addObject:@{ @"itemSectionRenderer": @{ @"contents": related } }];
    r[@"contents"] = @{ @"twoColumnWatchNextResults": @{ @"results": @{ @"results": @{ @"contents": sections } } } };
}

// 2.1.x / 2.2.x read twoColumnWatchNextResults; 2.3.1+ read singleColumnWatchNextResults
static void TRTranslateWatchNext(NSMutableDictionary *r) {
    NSString *v = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    if ([v hasPrefix:@"2.1."] || [v hasPrefix:@"2.2."]) TRTranslateWatchNextLegacy(r);
    else TRTranslateWatchNextModern(r);
}

// Channel tabs: the apps lay shelves out as carousels that need data this bridge can't give them
// (they render as empty lines), so flatten shelves into plain compact-renderer lists.
static NSDictionary *TRFlattenChannelTab(NSDictionary *tab) {
    if (![tab isKindOfClass:[NSDictionary class]]) return tab;
    NSDictionary *tr = tab[@"tabRenderer"];
    NSDictionary *sl = TRDig(tr, @[@"content", @"sectionListRenderer"]);
    if (![sl isKindOfClass:[NSDictionary class]]) return tab;
    NSMutableArray *outSecs = [NSMutableArray array];
    NSMutableArray *flat = [NSMutableArray array];
    for (NSDictionary *sec in ([sl[@"contents"] isKindOfClass:[NSArray class]] ? sl[@"contents"] : @[])) {
        NSArray *cs = TRDig(sec, @[@"itemSectionRenderer", @"contents"]);
        if (![cs isKindOfClass:[NSArray class]]) { [outSecs addObject:sec]; continue; }
        for (NSDictionary *c in cs) {
            NSDictionary *shelf = c[@"shelfRenderer"];
            if (!shelf) {
                if (c[@"channelVideoPlayerRenderer"]) continue;
                [flat addObject:c]; continue;
            }
            for (NSString *k in @[@"horizontalListRenderer", @"verticalListRenderer", @"gridRenderer", @"expandedShelfContentsRenderer"]) {
                NSArray *items = TRDig(shelf, @[@"content", k, @"items"]);
                if ([items isKindOfClass:[NSArray class]]) { [flat addObjectsFromArray:items]; break; }
            }
        }
    }
    if ([flat count]) [outSecs insertObject:@{ @"itemSectionRenderer": @{ @"contents": flat } } atIndex:0];
    NSMutableDictionary *ns = [[sl mutableCopy] autorelease];
    ns[@"contents"] = outSecs;
    NSMutableDictionary *ntr = [[tr mutableCopy] autorelease];
    ntr[@"content"] = @{ @"sectionListRenderer": ns };
    return @{ @"tabRenderer": ntr };
}


static NSDictionary *TRAccountParams(void);
static void TRCollectKey(id n, NSString *key, NSMutableArray *out, int depth);
static void TRPostInnerTube(NSString *endpoint, NSDictionary *body, void (^cb)(NSDictionary *json, NSInteger code, NSError *err));
static void TRCacheTranscriptParamsFrom(NSString *videoID, id json);
// ---- comments (2.3.1+): the web's comment threads -> the apps' commentThreadRenderer ----
static NSDictionary *TRCommentEntity(NSDictionary *json, NSString *cid) {
    NSArray *muts = TRDig(json, @[@"frameworkUpdates", @"entityBatchUpdate", @"mutations"]);
    if (![muts isKindOfClass:[NSArray class]] || ![cid length]) return nil;
    for (NSDictionary *m in muts) {
        NSDictionary *p = TRDig(m, @[@"payload", @"commentEntityPayload"]);
        if ([p isKindOfClass:[NSDictionary class]] && [TRDig(p, @[@"properties", @"commentId"]) isEqual:cid]) return p;
    }
    return nil;
}

// createReplyParams per comment (only present for signed-in requests); scanned once per response
static NSDictionary *TRReplyParamMap(NSDictionary *json) {
    static NSDictionary *lastJSON = nil; static NSDictionary *lastMap = nil;
    @synchronized ([NSNull null]) {
        if (lastJSON == json && lastMap) return lastMap;
    }
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    NSArray *muts = TRDig(json, @[@"frameworkUpdates", @"entityBatchUpdate", @"mutations"]);
    for (NSDictionary *m in ([muts isKindOfClass:[NSArray class]] ? muts : @[])) {
        id pl = m[@"payload"];
        id rp = TRFindKey(pl, @"createReplyParams", 0);
        if (![rp isKindOfClass:[NSString class]]) continue;
        id mid = TRFindKey(pl, @"commentId", 0);
        if ([mid isKindOfClass:[NSString class]]) map[mid] = rp;
    }
    @synchronized ([NSNull null]) { lastJSON = json; lastMap = [map retain]; }
    return map;
}
static NSArray *TRAllReplyParams(NSDictionary *json) { // [{p: params, d: decoded bytes as latin1}]
    static NSDictionary *lastJSON = nil; static NSArray *lastList = nil;
    @synchronized ([NSNull null]) { if (lastJSON == json && lastList) return lastList; }
    NSMutableArray *found = [NSMutableArray array], *list = [NSMutableArray array];
    TRCollectKey(json, @"createReplyParams", found, 0);
    for (id pstr in found) {
        if (![pstr isKindOfClass:[NSString class]]) continue;
        NSString *b64 = [[[pstr stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"] stringByReplacingOccurrencesOfString:@"%3D" withString:@"="];
        while ([b64 length] % 4) b64 = [b64 stringByAppendingString:@"="];
        NSData *raw = [NSData dataWithBase64EncodedString:b64];
        NSString *rs = raw ? [[[NSString alloc] initWithData:raw encoding:NSISOLatin1StringEncoding] autorelease] : @"";
        [list addObject:@{ @"p": pstr, @"d": rs ?: @"" }];
    }
    NSLog(@"[TubeReplacer] comment reply params in response: %lu", (unsigned long)[list count]);
    @synchronized ([NSNull null]) { lastJSON = json; lastList = [list retain]; }
    return list;
}
static NSString *TRReplyParamsFor(NSDictionary *json, id vm, NSString *cid) {
    id v = vm ? TRFindKey(vm, @"createReplyParams", 0) : nil;
    if ([v isKindOfClass:[NSString class]] && [v length]) return v;
    if (![cid length]) return nil;
    NSString *m = TRReplyParamMap(json)[cid];
    if ([m length]) return m;
    for (NSDictionary *e in TRAllReplyParams(json)) if ([e[@"d"] rangeOfString:cid].location != NSNotFound) return e[@"p"];
    return nil;
}
// like / dislike tokens of every comment (performCommentActionEndpoint.action), found by walking the whole response
static void TRWalkCommentActions(id n, NSString *path, NSMutableArray *out, int depth) {
    if (depth > 40 || [out count] > 400) return;
    if ([n isKindOfClass:[NSArray class]]) { for (id e in n) TRWalkCommentActions(e, path, out, depth + 1); return; }
    if (![n isKindOfClass:[NSDictionary class]]) return;
    for (NSString *k in n) {
        id v = n[k];
        NSString *np = [path stringByAppendingFormat:@"/%@", k];
        if ([k isEqualToString:@"performCommentActionEndpoint"] && [v isKindOfClass:[NSDictionary class]] && [v[@"action"] isKindOfClass:[NSString class]]) {
            [out addObject:@[ np, v[@"action"] ]];
            continue;
        }
        TRWalkCommentActions(v, np, out, depth + 1);
    }
}
static NSDictionary *TRCommentActionMap(NSDictionary *json) {
    static NSDictionary *lastJSON = nil; static NSDictionary *lastMap = nil;
    @synchronized ([NSNull null]) { if (lastJSON == json && lastMap) return lastMap; }
    NSMutableArray *found = [NSMutableArray array];
    TRWalkCommentActions(json, @"", found, 0);
    NSMutableDictionary *map = [NSMutableDictionary dictionary];   // cid -> {like,unlike,dislike,undislike}
    NSArray *muts = TRDig(json, @[@"frameworkUpdates", @"entityBatchUpdate", @"mutations"]);
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *m in ([muts isKindOfClass:[NSArray class]] ? muts : @[])) {
        id mid = TRFindKey(m[@"payload"], @"commentId", 0);
        if ([mid isKindOfClass:[NSString class]]) [ids addObject:mid];
    }
    int logged = 0;
    for (NSArray *f in found) {
        NSString *path = f[0], *tok = f[1];
        NSString *b64 = [[tok stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
        b64 = [b64 stringByReplacingOccurrencesOfString:@"%3D" withString:@"="];
        while ([b64 length] % 4) b64 = [b64 stringByAppendingString:@"="];
        NSData *raw = [NSData dataWithBase64EncodedString:b64]; // iOS 6 has no -initWithBase64EncodedString:options:
        NSString *rs = raw ? [[[NSString alloc] initWithData:raw encoding:NSISOLatin1StringEncoding] autorelease] : nil;
        NSString *owner = nil;
        for (NSString *cid in ids) if ([rs rangeOfString:cid].location != NSNotFound) { owner = cid; break; }
        NSString *lp = [path lowercaseString];
        NSString *kind = [lp rangeOfString:@"dislike"].location != NSNotFound ? @"dislike" : ([lp rangeOfString:@"like"].location != NSNotFound ? @"like" : nil);
        BOOL toggled = [lp rangeOfString:@"toggled"].location != NSNotFound || [lp rangeOfString:@"unlike"].location != NSNotFound || [lp rangeOfString:@"undislike"].location != NSNotFound || [lp rangeOfString:@"undo"].location != NSNotFound;
        if (logged++ < 6) NSLog(@"[TubeReplacer] comment action: %@ owner=%@ -> %@%@", path, owner ? @"yes" : @"no", kind, toggled ? @"_off" : @"_on");
        if (!owner || !kind) continue;
        NSMutableDictionary *e = map[owner]; if (!e) map[owner] = e = [NSMutableDictionary dictionary];
        e[[kind stringByAppendingString:(toggled ? @"_off" : @"_on")]] = tok;
    }
    @synchronized ([NSNull null]) { lastJSON = json; lastMap = [map retain]; }
    return map;
}
static NSString *TRBumpCount(NSString *c, int d) {
    NSString *plain = [c stringByReplacingOccurrencesOfString:@"," withString:@""];
    NSScanner *sc = [NSScanner scannerWithString:plain]; int n = 0;
    if ([plain length] && [sc scanInt:&n] && [sc isAtEnd]) { n += d; if (n < 0) n = 0; return n ? [NSString stringWithFormat:@"%d", n] : @""; }
    return c ?: @"";
}
// icon 16 = like, 51 = dislike. v11+ updates the heart/thumb from the endpoint's clientActions (updateCommentVoteAction), so each side carries one.
static NSDictionary *TRCommentToggle2(int icon, NSString *text, NSString *on, NSString *off, NSString *count) {
    BOOL isLike = icon == 16;
    NSString *onCount = isLike ? TRBumpCount(count, 1) : (count ?: @"");
    NSString *offCount = count ?: @"";
    NSMutableDictionary *t = [NSMutableDictionary dictionaryWithDictionary:@{ @"isToggled": @NO, @"defaultIcon": @{ @"iconType": @(icon) }, @"toggledIcon": @{ @"iconType": @(icon) },
                                          @"defaultText": TRSimpleText(text ?: @""), @"toggledText": TRSimpleText(text ?: @"") }];
    NSMutableDictionary *onE = [NSMutableDictionary dictionary], *offE = [NSMutableDictionary dictionary];
    if (on) onE[@"action"] = on;
    if (off) offE[@"action"] = off;
    onE[@"clientActions"] = @[ @{ @"updateCommentVoteAction": @{ @"voteStatus": @(isLike ? 0 : 1), @"voteCount": TRSimpleText(onCount) } } ];
    offE[@"clientActions"] = @[ @{ @"updateCommentVoteAction": @{ @"voteStatus": @2, @"voteCount": TRSimpleText(offCount) } } ];
    t[@"defaultServiceEndpoint"] = @{ @"performCommentActionEndpoint": onE };
    t[@"toggledServiceEndpoint"] = @{ @"performCommentActionEndpoint": offE };
    return @{ @"toggleButtonRenderer": t };
}

static NSDictionary *TRPostThread(NSDictionary *post) {
    NSMutableDictionary *cr = [NSMutableDictionary dictionary];
    NSString *pid = post[@"postId"];
    cr[@"commentId"] = [pid length] ? pid : @"post";
    cr[@"authorText"] = post[@"authorText"] ? TRSimpleText(TRTextOf(post[@"authorText"]) ?: @"") : TRSimpleText(@"");
    if ([post[@"authorThumbnail"] isKindOfClass:[NSDictionary class]]) cr[@"authorThumbnail"] = post[@"authorThumbnail"];
    if ([post[@"authorEndpoint"] isKindOfClass:[NSDictionary class]]) cr[@"authorEndpoint"] = post[@"authorEndpoint"];
    NSString *body = TRTextOf(post[@"contentText"]);
    cr[@"contentText"] = TRSimpleText([body length] ? body : @" ");
    if (post[@"publishedTimeText"]) cr[@"publishedTimeText"] = TRSimpleText(TRTextOf(post[@"publishedTimeText"]) ?: @"");
    NSString *likes = TRTextOf(post[@"voteCount"]) ?: @"";
    if ([likes length]) cr[@"voteCount"] = TRSimpleText(likes);
    cr[@"likeCount"] = @([[likes stringByReplacingOccurrencesOfString:@"," withString:@""] intValue]);
    cr[@"isLiked"] = @NO; cr[@"voteStatus"] = @2;
    cr[@"isTopLevelComment"] = @YES;
    cr[@"enablePostsV2"] = @YES; cr[@"iosEnablePostsV2"] = @YES;
    cr[@"engagementToolbarStyle"] = @{ @"value": @1 };
    NSDictionary *ab = TRDig(post, @[@"actionButtons", @"commentActionButtonsRenderer"]);
    NSString *(^act)(NSString *, NSString *) = ^NSString *(NSString *btn, NSString *ep) {
        id a = TRDig(ab, @[btn, @"toggleButtonRenderer", ep, @"performCommentActionEndpoint", @"action"]);
        return [a isKindOfClass:[NSString class]] ? a : nil;
    };
    NSString *rc = TRTextOf(TRDig(ab, @[@"replyButton", @"buttonRenderer", @"text"])) ?: @"";
    NSMutableDictionary *reply = [NSMutableDictionary dictionaryWithObject:TRSimpleText(rc) forKey:@"text"];
    NSDictionary *rbr = TRDig(ab, @[@"replyButton", @"buttonRenderer"]);
    if ([rbr[@"navigationEndpoint"] isKindOfClass:[NSDictionary class]]) reply[@"navigationEndpoint"] = rbr[@"navigationEndpoint"];
    if ([rbr[@"serviceEndpoint"] isKindOfClass:[NSDictionary class]]) reply[@"serviceEndpoint"] = rbr[@"serviceEndpoint"];
    // no guessed fallback: a made-up FEpost_detail params gives "error loading" (HTTP 400)
    NSLog(@"[TubeReplacer] community post reply button: nav=%@ service=%@", reply[@"navigationEndpoint"] ? [[reply[@"navigationEndpoint"] allKeys] componentsJoinedByString:@","] : @"none", reply[@"serviceEndpoint"] ? @"yes" : @"no");
    cr[@"actionButtons"] = @{ @"commentActionButtonsRenderer": @{
        @"likeButton": TRCommentToggle2(16, likes, act(@"likeButton", @"defaultServiceEndpoint"), act(@"likeButton", @"toggledServiceEndpoint"), likes),
        @"dislikeButton": TRCommentToggle2(51, @"Dislike", act(@"dislikeButton", @"defaultServiceEndpoint"), act(@"dislikeButton", @"toggledServiceEndpoint"), likes),
        @"replyButton": @{ @"buttonRenderer": reply } } };
    id att = post[@"backstageAttachment"] ?: post[@"attachment"];
    if ([att isKindOfClass:[NSDictionary class]]) {
        id fx = TRFix(@{ @"backstageAttachment": att });
        id fa = [fx isKindOfClass:[NSDictionary class]] ? fx[@"backstageAttachment"] : nil;
        if ([fa isKindOfClass:[NSDictionary class]] && [fa count]) cr[@"backstageAttachment"] = fa;
    }
    static int logged = 0;
    if (logged++ < 4) NSLog(@"[TubeReplacer] community post %@: attachment=%@ likes=%@ comments=%@", cr[@"commentId"], cr[@"backstageAttachment"] ? [[cr[@"backstageAttachment"] allKeys] componentsJoinedByString:@","] : @"none", likes, rc);
    return @{ @"commentThreadRenderer": @{ @"comment": @{ @"commentRenderer": cr } } };
}

static NSDictionary *TRCommentToggle(int icon, NSString *text) {
    return @{ @"toggleButtonRenderer": @{ @"isToggled": @NO, @"defaultIcon": @{ @"iconType": @(icon) }, @"toggledIcon": @{ @"iconType": @(icon) },
                                          @"defaultText": TRSimpleText(text ?: @""), @"toggledText": TRSimpleText(text ?: @"") } };
}
// One web comment (view-model + entity, or an old commentRenderer) -> the apps' commentRenderer.
static NSMutableDictionary *TRCommentRendererFrom(id item, NSDictionary *json, NSString **replyToken, NSString **replyCount) {
    if (![item isKindOfClass:[NSDictionary class]]) return nil;
    id vm = TRDig(item, @[@"commentViewModel", @"commentViewModel"]) ?: item[@"commentViewModel"];
    NSString *cid = [vm isKindOfClass:[NSDictionary class]] ? vm[@"commentId"] : nil;
    NSDictionary *e = TRCommentEntity(json, cid);
    if (!e) return nil;
    NSDictionary *props = e[@"properties"], *au = e[@"author"], *tb = e[@"toolbar"];
    NSString *text = TRDig(props, @[@"content", @"content"]);
    NSMutableDictionary *cr = [NSMutableDictionary dictionary];
    cr[@"commentId"] = cid;
    NSString *name = [au isKindOfClass:[NSDictionary class]] ? au[@"displayName"] : nil;
    if (![name length]) { // newer entities carry only the handle in the channel endpoint
        NSString *base = TRDig(au, @[@"channelCommand", @"innertubeCommand", @"browseEndpoint", @"canonicalBaseUrl"]);
        if ([base hasPrefix:@"/@"]) name = [base substringFromIndex:1];
    }
    if (![name length]) name = @"YouTube user";
    cr[@"authorText"] = TRSimpleText(name);
    NSString *av = [au isKindOfClass:[NSDictionary class]] ? au[@"avatarThumbnailUrl"] : nil;
    if (![av length]) av = TRDig(e, @[@"avatar", @"image", @"sources", @0, @"url"]);
    if ([av length]) cr[@"authorThumbnail"] = @{ @"thumbnails": @[ @{ @"url": av, @"width": @48, @"height": @48 } ] };
    if ([text length]) cr[@"contentText"] = TRSimpleText(text);
    NSString *when = [props isKindOfClass:[NSDictionary class]] ? props[@"publishedTime"] : nil;
    if ([when length]) cr[@"publishedTimeText"] = TRSimpleText(when);
    NSString *likes = [tb isKindOfClass:[NSDictionary class]] ? tb[@"likeCountNotliked"] : nil;
    if ([likes length]) cr[@"voteCount"] = TRSimpleText(likes);
    cr[@"likeCount"] = @([[likes stringByReplacingOccurrencesOfString:@"," withString:@""] intValue]);
    cr[@"isLiked"] = @NO;
    cr[@"voteStatus"] = @2; // LikeStatus: LIKE 0, DISLIKE 1, INDIFFERENT 2 (unset would read as "liked")
    NSString *chan = [au isKindOfClass:[NSDictionary class]] ? au[@"channelId"] : nil;
    if ([chan length]) cr[@"authorEndpoint"] = @{ @"browseEndpoint": @{ @"browseId": chan } };
    if ([au isKindOfClass:[NSDictionary class]] && [au[@"isCreator"] boolValue]) cr[@"authorIsChannelOwner"] = @YES;
    // explicit "not liked / not disliked" buttons (without them the cells draw every comment as liked)
    NSMutableDictionary *reply = [NSMutableDictionary dictionaryWithObject:TRSimpleText(@"Reply") forKey:@"text"];
    if (majorVersion() == 11) reply[@"icon"] = @{ @"iconType": @243 }; // 11.x draws the reply button from its icon (iconType 243 = comment image)
    NSString *rparams = TRReplyParamsFor(json, vm, cid);
    { static int logged = 0; if (logged < 6) { logged++; NSLog(@"[TubeReplacer] comment reply params for %@: %@", cid, [rparams length] ? @"found" : @"MISSING"); } }
    if ([rparams length]) {
        NSString *me = TRAccountParams()[@"fullName"] ?: @"";
        // the dialog endpoint is a *service* endpoint in the apps' schema (a navigation endpoint drops it)
        reply[@"serviceEndpoint"] = reply[@"navigationEndpoint"] = @{ @"createCommentReplyDialogEndpoint": @{ @"dialog": @{ @"commentReplyDialogRenderer": @{
            @"replyToText": TRSimpleText([NSString stringWithFormat:@"Reply to %@", name ?: @""]), // a formatted string, not plain text
            @"replyButton": @{ @"buttonRenderer": @{ @"text": TRSimpleText(@"Reply"),
                @"serviceEndpoint": @{ @"createCommentReplyEndpoint": @{ @"createReplyParams": rparams } } } },
            @"cancelButton": @{ @"buttonRenderer": @{ @"text": TRSimpleText(@"Cancel") } },
            @"placeholderText": TRSimpleText(@"Add a public reply..."),
            @"replyHint": TRSimpleText(@"Add a public reply...") } } } };
        (void)me;
    }
    cr[@"actionButtons"] = @{ @"commentActionButtonsRenderer": @{
        @"likeButton": TRCommentToggle2(16, likes, TRCommentActionMap(json)[cid][@"like_on"], TRCommentActionMap(json)[cid][@"like_off"], likes),
        @"dislikeButton": TRCommentToggle2(51, @"Dislike", TRCommentActionMap(json)[cid][@"dislike_on"], TRCommentActionMap(json)[cid][@"dislike_off"], likes),
        @"replyButton": @{ @"buttonRenderer": reply } } };
    NSString *rc = [tb isKindOfClass:[NSDictionary class]] ? tb[@"replyCount"] : nil;
    if (replyCount) *replyCount = [rc length] ? rc : nil;
    return cr;
}

static NSMutableDictionary *TRReplyTokenByComment(void) {
    static NSMutableDictionary *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [[NSMutableDictionary alloc] init]; });
    return m;
}
static NSDictionary *TRCommentThread(NSDictionary *item, NSDictionary *json) {
    NSDictionary *t = [item isKindOfClass:[NSDictionary class]] ? item[@"commentThreadRenderer"] : nil;
    if (![t isKindOfClass:[NSDictionary class]]) return nil;
    if (TRDig(t, @[@"comment", @"commentRenderer"])) return @{ @"commentThreadRenderer": @{ @"comment": t[@"comment"] } };
    NSString *rcount = nil;
    NSMutableDictionary *cr = TRCommentRendererFrom(t, json, NULL, &rcount);
    if (!cr) return nil;
    NSMutableDictionary *th = [NSMutableDictionary dictionaryWithObject:@{ @"commentRenderer": cr } forKey:@"comment"];
    NSArray *rc = TRDig(t, @[@"replies", @"commentRepliesRenderer", @"contents"]);
    NSString *rtoken = [rc isKindOfClass:[NSArray class]] && [rc count] ? TRContinuationToken(rc[0]) : nil;
    if (rtoken) {
        if (cr[@"commentId"]) @synchronized (TRReplyTokenByComment()) { TRReplyTokenByComment()[cr[@"commentId"]] = rtoken; }
        NSString *more = [rcount length] ? ([rcount isEqualToString:@"1"] ? @"View 1 reply" : [NSString stringWithFormat:@"View %@ replies", rcount]) : @"View replies";
        th[@"replies"] = @{ @"commentRepliesRenderer": @{
            @"moreText": TRSimpleText(more), @"lessText": TRSimpleText(@"Hide replies"),
            @"_replyToken": rtoken,
            @"continuations": TRContinuations(rtoken) } };
        if ([rcount length]) th[@"totalRepliesCountLabel"] = TRSimpleText(rcount);
    }
    return @{ @"commentThreadRenderer": th };
}

// All comment threads found in a continuation response, plus the token for the next page.
static NSArray *TRCommentThreadsIn(NSDictionary *json, NSString **next) {
    NSMutableArray *threads = [NSMutableArray array];
    NSArray *cmds = json[@"onResponseReceivedEndpoints"] ?: json[@"onResponseReceivedCommands"] ?: json[@"onResponseReceivedActions"];
    for (NSDictionary *c in ([cmds isKindOfClass:[NSArray class]] ? cmds : @[])) {
        NSArray *items = TRDig(c, @[@"reloadContinuationItemsCommand", @"continuationItems"]);
        if (![items isKindOfClass:[NSArray class]]) items = TRDig(c, @[@"appendContinuationItemsAction", @"continuationItems"]);
        if (![items isKindOfClass:[NSArray class]]) continue;
        for (id it in items) {
            NSString *tk = TRContinuationToken(it);
            if (tk) { if (next) *next = tk; continue; }
            NSDictionary *th = TRCommentThread(it, json);
            if (th) [threads addObject:th];
        }
    }
    return threads;
}

static NSDictionary *TRCommentsHeaderIn(NSDictionary *json) {
    NSArray *cmds = json[@"onResponseReceivedEndpoints"] ?: json[@"onResponseReceivedCommands"] ?: json[@"onResponseReceivedActions"];
    for (NSDictionary *c in ([cmds isKindOfClass:[NSArray class]] ? cmds : @[])) {
        NSArray *items = TRDig(c, @[@"reloadContinuationItemsCommand", @"continuationItems"]);
        if (![items isKindOfClass:[NSArray class]]) continue;
        for (id it in items) {
            NSDictionary *h = [it isKindOfClass:[NSDictionary class]] ? it[@"commentsHeaderRenderer"] : nil;
            if ([h isKindOfClass:[NSDictionary class]]) return h;
        }
    }
    return nil;
}

static NSDictionary *TRBuildCommentsHeader(NSDictionary *web, int fallbackCount) {
    NSString *count = TRTextOf(web[@"countText"]) ?: TRTextOf(web[@"titleText"]);
    NSString *params = TRFindKey(web, @"createCommentParams", 0);
    if (![params isKindOfClass:[NSString class]] || ![params length]) params = nil;
    NSMutableDictionary *box = [NSMutableDictionary dictionary];
    box[@"placeholderText"] = TRSimpleText(@"Add a public comment...");
    NSDictionary *prm = TRAccountParams();
    NSString *myPhoto = [gTRProfilePhoto length] ? gTRProfilePhoto : prm[@"avatar"];
    if ([myPhoto length]) box[@"authorThumbnail"] = @{ @"thumbnails": @[ @{ @"url": myPhoto, @"width": @48, @"height": @48 } ] };
    NSMutableDictionary *submit = [NSMutableDictionary dictionaryWithObject:TRSimpleText(@"Comment") forKey:@"text"];
    if (params) submit[@"serviceEndpoint"] = @{ @"createCommentEndpoint": @{ @"createCommentParams": params } };
    box[@"submitButton"] = @{ @"buttonRenderer": submit };
    box[@"cancelButton"] = @{ @"buttonRenderer": @{ @"text": TRSimpleText(@"Cancel") } };
    NSLog(@"[TubeReplacer] comments header: web=%@ count=%@ createParams=%@", web ? @"yes" : @"no", count, params ? @"yes" : @"no");
    return @{ @"commentsHeaderRenderer": @{ @"countText": TRSimpleText(count ?: @"Comments"),
                                             @"createRenderer": @{ @"commentSimpleboxRenderer": box } } };
}

static NSString *TRFindCommentsToken(id n, int depth) {
    if (depth > 24) return nil;
    if ([n isKindOfClass:[NSDictionary class]]) {
        NSString *sid = n[@"sectionIdentifier"], *pid = n[@"panelIdentifier"] ?: n[@"targetId"];
        BOOL hit = [sid isEqual:@"comment-item-section"] || ([pid isKindOfClass:[NSString class]] && [pid rangeOfString:@"comments-section"].location != NSNotFound);
        if (hit) {
            id cc = TRFindKey(n, @"continuationCommand", 0);
            if ([cc isKindOfClass:[NSDictionary class]] && [cc[@"token"] length]) return cc[@"token"];
        }
        for (id v in [n allValues]) { NSString *t = TRFindCommentsToken(v, depth + 1); if (t) return t; }
    } else if ([n isKindOfClass:[NSArray class]]) {
        for (id v in n) { NSString *t = TRFindCommentsToken(v, depth + 1); if (t) return t; }
    }
    return nil;
}


// The cells only draw a "replies" strip when it has teaser comments: load the first two replies of the first threads.
static void TRFillTeasers(NSDictionary *page, void (^done)(NSDictionary *page)) {
    NSArray *threads = page[@"contents"];
    NSMutableArray *newThreads = [NSMutableArray arrayWithArray:threads];
    dispatch_group_t g = dispatch_group_create();
    NSLock *lock = [[NSLock alloc] init];
    int fetched = 0;
    for (NSUInteger i = 0; i < [threads count] && fetched < 8; i++) {
        NSDictionary *rr = TRDig(threads[i], @[@"commentThreadRenderer", @"replies", @"commentRepliesRenderer"]);
        NSString *tok = [rr isKindOfClass:[NSDictionary class]] ? rr[@"_replyToken"] : nil;
        if (!tok) continue;
        fetched++;
        dispatch_group_enter(g);
        TRPostInnerTube(@"next", @{ @"continuation": tok }, ^(NSDictionary *rj, NSInteger rc, NSError *re) {
            @try {
                NSMutableArray *list = [NSMutableArray array];
                NSArray *cmds = rj[@"onResponseReceivedEndpoints"] ?: rj[@"onResponseReceivedCommands"] ?: rj[@"onResponseReceivedActions"];
                for (NSDictionary *c in ([cmds isKindOfClass:[NSArray class]] ? cmds : @[])) {
                    NSArray *items = TRDig(c, @[@"appendContinuationItemsAction", @"continuationItems"]) ?: TRDig(c, @[@"reloadContinuationItemsCommand", @"continuationItems"]);
                    for (id it in ([items isKindOfClass:[NSArray class]] ? items : @[])) {
                        if ([list count] >= 2) break;
                        NSMutableDictionary *cr = TRCommentRendererFrom(it, rj, NULL, NULL);
                        if (cr) { cr[@"avatarSize"] = @2; cr[@"isTopLevelComment"] = @NO; [list addObject:@{ @"commentRenderer": cr }]; }
                    }
                }
                if ([list count]) {
                    NSMutableDictionary *th = [[threads[i][@"commentThreadRenderer"] mutableCopy] autorelease];
                    NSMutableDictionary *rep = [[rr mutableCopy] autorelease];
                    rep[@"contents"] = list;
                    NSString *vt = TRTextOf(rep[@"moreText"]) ?: @"View all replies";
                    rep[@"detailViewButton"] = @{ @"buttonRenderer": @{ @"text": TRSimpleText([vt hasPrefix:@"View all"] ? vt : [@"View all" stringByAppendingString:[vt substringFromIndex:MIN((NSUInteger)4, [vt length])]]) } };
                    th[@"replies"] = @{ @"commentRepliesRenderer": rep };
                    NSLog(@"[TubeReplacer] replies strip for %@: %lu teaser(s), view-all button %@", TRDig(th, @[@"comment", @"commentRenderer", @"commentId"]), (unsigned long)[list count], rep[@"detailViewButton"] ? @"yes" : @"no");
                    [lock lock]; newThreads[i] = @{ @"commentThreadRenderer": th }; [lock unlock];
                }
            } @catch (NSException *e) {}
            dispatch_group_leave(g);
        });
    }
    dispatch_group_notify(g, dispatch_get_global_queue(0, 0), ^{
        NSMutableDictionary *np = [[page mutableCopy] autorelease];
        [lock lock]; np[@"contents"] = [[newThreads copy] autorelease]; [lock unlock];
        done(np);
        dispatch_release(g); [lock release];
    });
}

// Adds a comments section (first page already loaded) after the related videos.
static NSDictionary *TRWithComments(NSDictionary *norm, NSDictionary *page) {
    NSArray *threads = page[@"contents"];
    if (![threads count]) return norm;
    NSMutableDictionary *r = [[norm mutableCopy] autorelease];
    NSMutableDictionary *contents = [[r[@"contents"] mutableCopy] autorelease];
    NSMutableDictionary *single = [[contents[@"singleColumnWatchNextResults"] mutableCopy] autorelease];
    NSMutableDictionary *res1 = [[single[@"results"] mutableCopy] autorelease];
    NSMutableDictionary *res2 = [[res1[@"results"] mutableCopy] autorelease];
    NSMutableArray *secs = [[res2[@"contents"] mutableCopy] autorelease];
    if (!secs) return norm;
    NSMutableDictionary *sec = [NSMutableDictionary dictionaryWithObject:threads forKey:@"contents"];
    if (page[@"continuations"]) sec[@"continuations"] = page[@"continuations"];
    if (page[@"header"]) sec[@"header"] = page[@"header"];
    [secs addObject:@{ @"itemSectionRenderer": sec }];
    res2[@"contents"] = secs; res1[@"results"] = res2; single[@"results"] = res1;
    contents[@"singleColumnWatchNextResults"] = single; r[@"contents"] = contents;
    return r;
}

// Whole-response rewrite. `isContinuation` responses carry onResponseReceivedCommands.
static NSDictionary *TRNormalizeResponse(NSDictionary *json) {
    NSMutableDictionary *r = [[TRFix(json) mutableCopy] autorelease];
    if (![r isKindOfClass:[NSMutableDictionary class]]) return json;
    NSArray *cmds = json[@"onResponseReceivedCommands"] ?: json[@"onResponseReceivedActions"] ?: json[@"onResponseReceivedEndpoints"];
    {
        NSString *cnext = nil;
        NSArray *threads = TRCommentThreadsIn(json, &cnext);
        if ([threads count]) {
            NSMutableDictionary *cont = [NSMutableDictionary dictionaryWithObject:threads forKey:@"contents"];
            if (cnext) cont[@"continuations"] = TRContinuations(cnext);
            cont[@"header"] = TRBuildCommentsHeader(TRCommentsHeaderIn(json), (int)[threads count]);
            r[@"continuationContents"] = @{ @"itemSectionContinuation": cont };
            cmds = nil;
        }
    }
    for (NSDictionary *c in ([cmds isKindOfClass:[NSArray class]] ? cmds : @[])) {
        NSArray *items = TRDig(c, @[@"appendContinuationItemsAction", @"continuationItems"]);
        if (![items isKindOfClass:[NSArray class]]) items = TRDig(c, @[@"reloadContinuationItemsCommand", @"continuationItems"]);
        if (![items isKindOfClass:[NSArray class]]) continue;
        NSString *token = nil;
        NSArray *fixed = TRFixArray(items, &token);
        BOOL sections = NO;
        for (NSDictionary *e in fixed) if (e[@"itemSectionRenderer"]) sections = YES;
        NSMutableDictionary *cont = [NSMutableDictionary dictionaryWithObject:fixed forKey:@"contents"];
        if (token) cont[@"continuations"] = TRContinuations(token);
        r[@"continuationContents"] = sections ? @{ @"sectionListContinuation": cont }
                                              : @{ @"itemSectionContinuation": cont };
        break;
    }
    // The apps read contents.sectionListRenderer directly (search) or single-column tabs; the
    // desktop layout wraps the same content in twoColumn*Renderer, which they never look at.
    TRTranslateWatchNext(r);
    NSDictionary *contents = r[@"contents"];
    if ([contents isKindOfClass:[NSDictionary class]]) {
        id sl = TRDig(contents, @[@"twoColumnSearchResultsRenderer", @"primaryContents", @"sectionListRenderer"]);
        if ([sl isKindOfClass:[NSDictionary class]]) {
            r[@"contents"] = @{ @"sectionListRenderer": sl };
        } else {
            NSArray *tabs = TRDig(contents, @[@"twoColumnBrowseResultsRenderer", @"tabs"]);
            if ([tabs isKindOfClass:[NSArray class]] && [tabs count]) {
                NSDictionary *hdr = r[@"header"];
                BOOL channel = [hdr isKindOfClass:[NSDictionary class]] && (hdr[@"c4TabbedHeaderRenderer"] || hdr[@"pageHeaderRenderer"]);
                id first = nil;
                for (id t in tabs) { id c = TRDig(t, @[@"tabRenderer", @"content", @"sectionListRenderer"]); if (c) { first = c; break; } }
                if (!channel && first) r[@"contents"] = @{ @"sectionListRenderer": first };
                else {
                    if (channel) {
                        NSMutableArray *nt = [NSMutableArray array];
                        NSDictionary *template = nil; BOOL hasChannelsTab = NO;
                        for (id t in tabs) {
                            NSDictionary *tr = [t isKindOfClass:[NSDictionary class]] ? (t[@"tabRenderer"] ?: t[@"expandableTabRenderer"]) : nil;
                            NSLog(@"[TubeReplacer] channel tab: %@ title=%@ content=%d", t[@"tabRenderer"] ? @"tab" : (t[@"expandableTabRenderer"] ? @"expandable" : @"?"), tr[@"title"], tr[@"content"] != nil);
                            // 12.x walks the tab list as plain tabs (the expandable "Search" entry crashes it)
                            if (![t isKindOfClass:[NSDictionary class]] || !t[@"tabRenderer"]) continue;
                            if ([tr[@"title"] isEqual:@"Channels"]) hasChannelsTab = YES;
                            if (!template && tr[@"endpoint"] && ![tr[@"content"] isKindOfClass:[NSDictionary class]]) template = tr;
                            NSDictionary *ft = TRFlattenChannelTab(t);
                            if ([tr[@"title"] isEqual:@"Posts"] && majorVersion() < 12) continue; // 11.x and older have no community post cell
                            if ([tr[@"title"] isEqual:@"Posts"]) { // the web's "Posts" tab is the community tab
                                NSMutableDictionary *ftm = [[ft mutableCopy] autorelease];
                                NSMutableDictionary *ftr = [[ftm[@"tabRenderer"] mutableCopy] autorelease];
                                if (ftr) { ftr[@"title"] = @"Community"; ftm[@"tabRenderer"] = ftr; ft = ftm; }
                            }
                            [nt addObject:ft];
                        }
                        if (!hasChannelsTab && template && [TRDig(template, @[@"endpoint", @"browseEndpoint", @"browseId"]) length]) {
                            NSMutableDictionary *ct = [[template mutableCopy] autorelease];
                            NSMutableDictionary *ep = [[template[@"endpoint"] mutableCopy] autorelease];
                            NSMutableDictionary *be = [[ep[@"browseEndpoint"] mutableCopy] autorelease];
                            be[@"params"] = @"EghjaGFubmVscw=="; // the "channels" tab
                            ep[@"browseEndpoint"] = be;
                            ct[@"endpoint"] = ep; ct[@"title"] = @"Channels"; ct[@"selected"] = @NO;
                            [ct removeObjectForKey:@"content"];
                            NSUInteger at = [nt count];
                            // the real apps order the tabs Home, Videos, Playlists, Community, Channels, About
                            for (NSUInteger i = 0; i < [nt count]; i++) if ([TRDig(nt[i], @[@"tabRenderer", @"title"]) isEqual:@"Playlists"]) { at = i + 1; break; }
                            for (NSUInteger i = 0; i < [nt count]; i++) if ([TRDig(nt[i], @[@"tabRenderer", @"title"]) isEqual:@"Community"]) { at = i + 1; break; }
                            [nt insertObject:@{ @"tabRenderer": ct } atIndex:at];
                        }
                        if (majorVersion() >= 12) {
                            // the web has no About tab any more; 12.x/13.x still draw channelAboutFullMetadataRenderer
                            NSDictionary *cm = TRDig(r, @[@"metadata", @"channelMetadataRenderer"]);
                            NSString *desc = [cm isKindOfClass:[NSDictionary class]] ? cm[@"description"] : nil;
                            NSString *cttl = [cm isKindOfClass:[NSDictionary class]] ? cm[@"title"] : nil;
                            NSString *curl = [cm isKindOfClass:[NSDictionary class]] ? (cm[@"vanityChannelUrl"] ?: cm[@"channelUrl"]) : nil;
                            if ([desc length] || [curl length]) {
                                NSMutableDictionary *ab = [NSMutableDictionary dictionary];
                                if ([cttl length]) ab[@"title"] = TRSimpleText(cttl);
                                if ([desc length]) { ab[@"description"] = TRSimpleText(desc); ab[@"description_p"] = TRSimpleText(desc); }
                                if ([curl length]) { ab[@"canonicalChannelUrl"] = curl; ab[@"canonicalChannelURL"] = curl; }
                                ab[@"showDescription"] = @YES;
                                ab[@"descriptionLabel"] = TRSimpleText(@"Description");
                                ab[@"detailsLabel"] = TRSimpleText(@"Details");
                                ab[@"statsLabel"] = TRSimpleText(@"Stats");
                                ab[@"primaryLinksLabel"] = TRSimpleText(@"Links");
                                NSString *subsT = TRTextOf(TRDig(hdr, @[@"pageHeaderRenderer", @"content", @"pageHeaderViewModel", @"metadata", @"contentMetadataViewModel", @"metadataRows"]));
                                (void)subsT;
                                NSMutableDictionary *aboutTab = [NSMutableDictionary dictionaryWithDictionary:@{ @"title": @"About", @"selected": @NO,
                                    @"content": @{ @"sectionListRenderer": @{ @"contents": @[ @{ @"itemSectionRenderer": @{ @"contents": @[ @{ @"channelAboutMetadataRenderer": ab } ] } } ] } } }];
                                [nt addObject:@{ @"tabRenderer": aboutTab }];
                                NSLog(@"[TubeReplacer] channel About tab added (description %lu chars)", (unsigned long)[desc length]);
                            }
                        }
                        tabs = nt;
                        NSDictionary *ph = TRDig(hdr, @[@"pageHeaderRenderer", @"content", @"pageHeaderViewModel"]);
                        NSString *hcid = TRDig(r, @[@"metadata", @"channelMetadataRenderer", @"externalId"]);
                        if ([ph isKindOfClass:[NSDictionary class]] && [hcid length]) {
                            NSMutableDictionary *c4 = [NSMutableDictionary dictionary];
                            c4[@"channelId"] = hcid;
                            NSString *ht = TRTextOf(TRDig(ph, @[@"title", @"dynamicTextViewModel", @"text"])) ?: TRDig(r, @[@"metadata", @"channelMetadataRenderer", @"title"]);
                            if ([ht length]) c4[@"title"] = ht;
                            NSArray *av = TRImageSources(TRDig(ph, @[@"image", @"decoratedAvatarViewModel", @"avatar", @"avatarViewModel", @"image", @"sources"]));
                            if (![av count]) av = TRImageSources(TRDig(r, @[@"metadata", @"channelMetadataRenderer", @"avatar", @"thumbnails"]));
                            if ([av count]) c4[@"avatar"] = @{ @"thumbnails": av };
                            NSArray *bn = TRImageSources(TRDig(ph, @[@"banner", @"imageBannerViewModel", @"image", @"sources"]));
                            // phones (compact layout) read mobileBanner, tablets banner
                            if ([bn count]) { c4[@"banner"] = @{ @"thumbnails": bn }; c4[@"mobileBanner"] = @{ @"thumbnails": bn }; }
                            for (NSDictionary *row in ([TRDig(ph, @[@"metadata", @"contentMetadataViewModel", @"metadataRows"]) isKindOfClass:[NSArray class]] ? TRDig(ph, @[@"metadata", @"contentMetadataViewModel", @"metadataRows"]) : @[]))
                                for (NSDictionary *p in ([row[@"metadataParts"] isKindOfClass:[NSArray class]] ? row[@"metadataParts"] : @[])) {
                                    NSString *pt = TRTextOf(p[@"text"]);
                                    if ([pt rangeOfString:@"subscriber"].location != NSNotFound) c4[@"subscriberCountText"] = TRSimpleText(pt);
                                    
                                }
                            if (!c4[@"subscriberCountText"]) {
                                NSString *st = TRFindSubscriberText(ph, 0) ?: TRFindSubscriberText(TRDig(r, @[@"header"]), 0) ?: TRFindSubscriberText(TRDig(r, @[@"metadata"]), 0);
                                if (st) c4[@"subscriberCountText"] = TRSimpleText(st);
                            }
                            NSLog(@"[TubeReplacer] channel header: subscribers=%@", TRTextOf(c4[@"subscriberCountText"]) ?: @"(none found)");
                            c4[@"navigationEndpoint"] = @{ @"browseEndpoint": @{ @"browseId": hcid } };
                            BOOL isSub = NO;
                            { // the web keeps the signed-in user's state in a subscriptionStateEntity mutation
                                NSMutableArray *sse = [NSMutableArray array];
                                TRCollectKey(json, @"subscriptionStateEntity", sse, 0);
                                for (id se in sse) if ([se isKindOfClass:[NSDictionary class]] && [se[@"subscribed"] respondsToSelector:@selector(boolValue)] && [se[@"subscribed"] boolValue]) { isSub = YES; break; }
                                if (!isSub) { // older shape: a toggled subscribeButtonRenderer / unsubscribe endpoint on the header
                                    NSMutableArray *sbs = [NSMutableArray array];
                                    TRCollectKey(hdr, @"subscribeButtonRenderer", sbs, 0);
                                    for (id sbr in sbs) if ([sbr isKindOfClass:[NSDictionary class]] && [sbr[@"subscribed"] boolValue]) { isSub = YES; break; }
                                }
                                NSLog(@"[TubeReplacer] channel header: subscriptionStateEntity=%lu subscribed=%d", (unsigned long)[sse count], isSub);
                            }
                            gTRHeaderIsOwn = [hcid length] && TRIsOwnChannel(hcid);
                            NSDictionary *sb = TRSubscribeButtonFor(hcid, isSub);
                            if (sb) { // plain button: the FREE type draws a red outline in the tablet header
                                NSMutableDictionary *hb = [[sb[@"subscribeButtonRenderer"] mutableCopy] autorelease];
                                [hb removeObjectForKey:@"type"];
                                c4[@"subscribeButton"] = @{ @"subscribeButtonRenderer": hb };
                            }
                            r[@"header"] = @{ @"c4TabbedHeaderRenderer": c4 };
                            NSLog(@"[TubeReplacer] channel header built: %@ avatar=%lu banner=%lu", ht, (unsigned long)[av count], (unsigned long)[bn count]);
                        }
                    }
                    r[@"contents"] = @{ @"singleColumnBrowseResultsRenderer": @{ @"tabs": tabs } };
                }
            }
        }
    }
    [r removeObjectForKey:@"onResponseReceivedCommands"];
    [r removeObjectForKey:@"onResponseReceivedActions"];
    return r;
}

// forward declaration
static void TRPostInnerTube(NSString *endpoint, NSDictionary *body, void (^cb)(NSDictionary *json, NSInteger code, NSError *err));

// 12.x never asks for the content of a channel tab it was given without content (the spinner just
// stays), so fetch each tab up front and hand them all over in the channel response.


// first string anywhere in a JSON tree that mentions subscribers ("1.2M subscribers")
static NSString *TRFindSubscriberText(id n, int depth) {
    if (depth > 14) return nil;
    if ([n isKindOfClass:[NSString class]]) {
        NSString *t = n;
        return ([t length] < 60 && [t rangeOfString:@"subscriber" options:NSCaseInsensitiveSearch].location != NSNotFound && [t rangeOfCharacterFromSet:[NSCharacterSet decimalDigitCharacterSet]].location != NSNotFound) ? t : nil;
    }
    if ([n isKindOfClass:[NSArray class]]) { for (id e in n) { NSString *r = TRFindSubscriberText(e, depth + 1); if (r) return r; } return nil; }
    if ([n isKindOfClass:[NSDictionary class]]) { for (id k in n) { NSString *r = TRFindSubscriberText(n[k], depth + 1); if (r) return r; } }
    return nil;
}


// Home-style video cards (big thumbnail, channel avatar, title, "channel . views . age"): the apps draw
// videoWithContextRenderer that way, the compact list renderer as a thumbnail/title row.
static void TRBigCardsIn(id n, int depth) {
    if (depth > 30) return;
    if ([n isKindOfClass:[NSMutableArray class]]) {
        NSMutableArray *a = n;
        for (NSUInteger i = 0; i < [a count]; i++) {
            id e = a[i];
            NSDictionary *cv = [e isKindOfClass:[NSDictionary class]] ? e[@"compactVideoRenderer"] : nil;
            if ([cv isKindOfClass:[NSDictionary class]] && [cv[@"videoId"] length] && cv[@"thumbnail"]) {
                NSMutableDictionary *w = [NSMutableDictionary dictionary];
                w[@"videoId"] = cv[@"videoId"];
                if (cv[@"title"]) w[@"headline"] = cv[@"title"];
                w[@"thumbnail"] = cv[@"thumbnail"];
                id by = cv[@"shortBylineText"] ?: cv[@"longBylineText"];
                if (by) w[@"shortBylineText"] = by;
                if (cv[@"lengthText"]) w[@"lengthText"] = cv[@"lengthText"];
                id vc = cv[@"shortViewCountText"] ?: cv[@"viewCountText"];
                if (vc) w[@"shortViewCountText"] = vc;
                if (cv[@"publishedTimeText"]) w[@"publishedTimeText"] = cv[@"publishedTimeText"];
                if (cv[@"channelThumbnail"]) w[@"channelThumbnail"] = cv[@"channelThumbnail"];
                if (cv[@"navigationEndpoint"]) w[@"navigationEndpoint"] = cv[@"navigationEndpoint"];
                if (cv[@"thumbnailOverlays"]) w[@"thumbnailOverlays"] = cv[@"thumbnailOverlays"];
                a[i] = @{ @"videoWithContextRenderer": w };
            } else TRBigCardsIn(e, depth + 1);
        }
        return;
    }
    if ([n isKindOfClass:[NSMutableDictionary class]]) for (id k in [(NSDictionary *)n allKeys]) TRBigCardsIn(n[k], depth + 1);
}
static NSDictionary *TRBigCardsOnly(NSDictionary *norm) {
    @try {
        NSData *jd = [NSJSONSerialization dataWithJSONObject:norm options:0 error:nil];
        id mn = jd ? [NSJSONSerialization JSONObjectWithData:jd options:NSJSONReadingMutableContainers error:nil] : nil;
        if (!mn) return norm;
        TRBigCardsIn(mn, 0);
        return mn;
    } @catch (NSException *e) { return norm; }
}
static BOOL TRIsPad(void) { return [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad; }
// iPad v11/v12 draw the home feed as titled shelves holding a 3-column grid of video cards (shelfRenderer > gridRenderer > gridVideoRenderer)
// iPad v11-v13 home: horizontal shelves (see TRHShelfHome); the other feeds keep the titled grid
static BOOL TRWantsGridShelves(void) { return TRIsPad() && majorVersion() >= 11; }
static BOOL TRWantsHShelves(void) { return TRIsPad() && majorVersion() >= 11 && majorVersion() <= 13; }
static BOOL TRWantsBigCards(void) {
    if (majorVersion() < 11) return NO;
    if (TRIsPad()) return TRWantsGridShelves(); // other tablets keep their own list layout
    return YES;
}
static NSString *gTRGridTitle = nil; // title of the first grid shelf (Recommended on home, New videos on subscriptions)
static NSDictionary *TRGridShelves(NSDictionary *norm) {
    @try {
        NSData *jd = [NSJSONSerialization dataWithJSONObject:norm options:0 error:nil];
        id mn = jd ? [NSJSONSerialization JSONObjectWithData:jd options:NSJSONReadingMutableContainers error:nil] : nil;
        if (!mn) return norm;
        NSMutableArray *secs = [NSMutableArray array];
        TRCollectKey(mn, @"sectionListRenderer", secs, 0);
        int made = 0;
        for (id sl in secs) {
            NSMutableArray *cs = [sl isKindOfClass:[NSMutableDictionary class]] && [sl[@"contents"] isKindOfClass:[NSMutableArray class]] ? sl[@"contents"] : nil;
            if (!cs) continue;
            NSMutableArray *outSecs = [NSMutableArray array];
            for (id sec in cs) {
                NSArray *items = [sec isKindOfClass:[NSDictionary class]] ? TRDig(sec, @[@"itemSectionRenderer", @"contents"]) : nil;
                NSMutableArray *vids = [NSMutableArray array], *rest = [NSMutableArray array];
                for (id it in ([items isKindOfClass:[NSArray class]] ? items : @[])) {
                    NSMutableDictionary *cv = [it isKindOfClass:[NSDictionary class]] ? it[@"compactVideoRenderer"] : nil;
                    if ([cv isKindOfClass:[NSMutableDictionary class]]) {
                        if (!cv[@"shortBylineText"] && cv[@"longBylineText"]) cv[@"shortBylineText"] = cv[@"longBylineText"];
                        if (!cv[@"viewCountText"] && cv[@"shortViewCountText"]) cv[@"viewCountText"] = cv[@"shortViewCountText"];
                        // keep only 16:9 thumbnails (hqdefault is 4:3 with black bars); fall back to mqdefault
                        NSArray *th = TRDig(cv, @[@"thumbnail", @"thumbnails"]);
                        if ([th isKindOfClass:[NSArray class]]) {
                            NSMutableArray *wide = [NSMutableArray array];
                            for (id t in th) {
                                double w = [t[@"width"] doubleValue], h = [t[@"height"] doubleValue];
                                if (w > 0 && h > 0 && fabs(w / h - 16.0 / 9.0) < 0.05) [wide addObject:t];
                            }
                            if (![wide count] && [cv[@"videoId"] length])
                                [wide addObject:@{ @"url": [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", cv[@"videoId"]], @"width": @320, @"height": @180 }];
                            if ([wide count]) cv[@"thumbnail"] = @{ @"thumbnails": wide };
                        }
                        if (majorVersion() == 12) { cv[@"isNarrow"] = @YES; [vids addObject:@{ @"gridNarrowVideoRenderer": cv }]; } // v12's narrow card: smaller thumbnails, more columns
                        else [vids addObject:@{ @"gridVideoRenderer": cv }];
                    } else [rest addObject:it];
                }
                if ([vids count] < 3) { [outSecs addObject:sec]; continue; }
                NSUInteger per = 12, n = 0;
                for (NSUInteger i = 0; i < [vids count]; i += per, n++) {
                    NSArray *chunk = [vids subarrayWithRange:NSMakeRange(i, MIN(per, [vids count] - i))];
                    NSDictionary *shelf = @{ @"title": TRSimpleText(n == 0 ? (gTRGridTitle ?: @"Recommended") : @"More videos"),
                        @"content": @{ @"gridRenderer": @{ @"items": chunk } } };
                    // the shelf must be a section of its own: YTShelfSectionController (v11/v12) lays a gridRenderer out in columns and draws the title header.
                    // Inside an item section it is only a cell, which draws no grid (v12 showed nothing).
                    [outSecs addObject:@{ @"shelfRenderer": shelf }];
                    made++;
                }
                if ([rest count]) [outSecs addObject:@{ @"itemSectionRenderer": @{ @"contents": rest } }];
            }
            sl[@"contents"] = outSecs;
        }
        NSLog(@"[TubeReplacer] iPad grid shelves (section-level): %d", made);
        return made ? mn : norm;
    } @catch (NSException *e) { return norm; }
}
static NSDictionary *TRBigCards(NSDictionary *norm) { return TRWantsGridShelves() ? TRGridShelves(norm) : TRBigCardsOnly(norm); }

// ---- v11/v12 iPad home: titled shelves with one row of cards each (like the 2016 iPad app): a few subscription channels,
// "#PopularOnYouTube" and "Recommended for you". The shelf's chevron expands it into the whole list.
static NSArray *gTRShelfSubs = nil, *gTRShelfTrend = nil;
static NSMutableDictionary *TRHCard(NSDictionary *cv0) {
    NSMutableDictionary *cv = [[cv0 mutableCopy] autorelease];
    if (!cv[@"shortBylineText"] && cv[@"longBylineText"]) cv[@"shortBylineText"] = cv[@"longBylineText"];
    if (!cv[@"longBylineText"] && cv[@"shortBylineText"]) cv[@"longBylineText"] = cv[@"shortBylineText"];
    if (!cv[@"viewCountText"] && cv[@"shortViewCountText"]) cv[@"viewCountText"] = cv[@"shortViewCountText"];
    NSArray *th = TRDig(cv, @[@"thumbnail", @"thumbnails"]);
    if ([th isKindOfClass:[NSArray class]]) {
        NSMutableArray *wide = [NSMutableArray array];
        for (id t in th) { double w = [t[@"width"] doubleValue], h = [t[@"height"] doubleValue]; if (w > 0 && h > 0 && fabs(w / h - 16.0 / 9.0) < 0.05) [wide addObject:t]; }
        if (![wide count] && [cv[@"videoId"] length]) [wide addObject:@{ @"url": [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", cv[@"videoId"]], @"width": @320, @"height": @180 }];
        if ([wide count]) cv[@"thumbnail"] = @{ @"thumbnails": wide };
    }
    return cv;
}
static NSDictionary *TRHShelf(NSString *title, NSString *subtitle, id thumb, NSDictionary *endpoint, NSArray *videos) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *v in videos) [items addObject:@{ @"gridVideoRenderer": TRHCard(v) }];
    NSMutableDictionary *shelf = [NSMutableDictionary dictionaryWithDictionary:@{ @"title": TRSimpleText(title),
        @"content": @{ @"horizontalListRenderer": @{ @"items": items, @"viewAllText": TRSimpleText(@"Show more") } } }];
    if ([subtitle length]) shelf[@"subtitle"] = TRSimpleText(subtitle);
    if ([thumb isKindOfClass:[NSDictionary class]]) shelf[@"thumbnail"] = thumb;
    if (endpoint) shelf[@"endpoint"] = endpoint;
    return @{ @"shelfRenderer": shelf };
}
static NSArray *TRVideosOf(NSDictionary *tn) {
    NSMutableArray *vs = [NSMutableArray array], *out = [NSMutableArray array];
    TRCollectKey(tn, @"compactVideoRenderer", vs, 0);
    for (id v in vs) if ([v isKindOfClass:[NSDictionary class]] && [v[@"videoId"] length]) [out addObject:v];
    return out;
}
static void TRFetchShelfFeeds(void) {
    dispatch_group_t g = dispatch_group_create();
    NSArray *ids = @[ @"FEsubscriptions", @"FEtrending" ];
    for (NSString *bid in ids) {
        dispatch_group_enter(g);
        TRPostInnerTube(@"browse", @{ @"browseId": bid }, ^(NSDictionary *tj, NSInteger tc, NSError *te) {
            @try {
                if (tj && tc < 400) {
                    NSArray *vs = TRVideosOf(TRNormalizeResponse(tj));
                    if ([vs count]) { if ([bid isEqual:@"FEsubscriptions"]) gTRShelfSubs = [vs copy]; else gTRShelfTrend = [vs copy]; }
                }
            } @catch (NSException *e) {}
            dispatch_group_leave(g);
        });
    }
    if (![NSThread isMainThread] && !(gTRShelfSubs && gTRShelfTrend)) dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
    dispatch_release(g);
}
static NSDictionary *TRHShelfHome(NSDictionary *norm) {
    @try {
        TRFetchShelfFeeds();
        NSData *jd = [NSJSONSerialization dataWithJSONObject:norm options:0 error:nil];
        id mn = jd ? [NSJSONSerialization JSONObjectWithData:jd options:NSJSONReadingMutableContainers error:nil] : nil;
        if (!mn) return norm;
        NSMutableArray *secs = [NSMutableArray array];
        TRCollectKey(mn, @"sectionListRenderer", secs, 0);
        int made = 0;
        for (id sl in secs) {
            NSMutableArray *cs = [sl isKindOfClass:[NSMutableDictionary class]] && [sl[@"contents"] isKindOfClass:[NSMutableArray class]] ? sl[@"contents"] : nil;
            if (!cs) continue;
            NSMutableArray *outSecs = [NSMutableArray array];
            BOOL first = YES;
            for (id sec in cs) {
                NSArray *items = [sec isKindOfClass:[NSDictionary class]] ? TRDig(sec, @[@"itemSectionRenderer", @"contents"]) : nil;
                NSMutableArray *vids = [NSMutableArray array], *rest = [NSMutableArray array];
                for (id it in ([items isKindOfClass:[NSArray class]] ? items : @[])) {
                    NSDictionary *cv = [it isKindOfClass:[NSDictionary class]] ? it[@"compactVideoRenderer"] : nil;
                    if ([cv isKindOfClass:[NSDictionary class]]) [vids addObject:cv]; else [rest addObject:it];
                }
                if ([vids count] < 4) { [outSecs addObject:sec]; continue; }
                if (first) {
                    first = NO;
                    // subscriptions: one shelf per channel with its newest videos
                    NSMutableArray *order = [NSMutableArray array]; NSMutableDictionary *by = [NSMutableDictionary dictionary];
                    for (NSDictionary *v in gTRShelfSubs) {
                        NSString *chan = TRTextOf(v[@"shortBylineText"]) ?: TRTextOf(v[@"longBylineText"]);
                        if (![chan length]) continue;
                        NSMutableArray *l = by[chan]; if (!l) { l = [NSMutableArray array]; by[chan] = l; [order addObject:chan]; }
                        [l addObject:v];
                    }
                    int ch = 0;
                    for (NSString *chan in order) {
                        NSArray *l = by[chan]; if ([l count] < 2) continue;
                        NSDictionary *f = l[0];
                        id runs = TRDig(f, @[@"shortBylineText", @"runs"]) ?: TRDig(f, @[@"longBylineText", @"runs"]);
                        NSString *cid = ([runs isKindOfClass:[NSArray class]] && [runs count]) ? TRDig(runs[0], @[@"navigationEndpoint", @"browseEndpoint", @"browseId"]) : nil;
                        [outSecs addObject:TRHShelf(chan, nil, f[@"channelThumbnail"], [cid length] ? @{ @"browseEndpoint": @{ @"browseId": cid } } : nil, [l subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, [l count]))])];
                        made++; if (++ch >= 2) break;
                    }
                    if ([gTRShelfTrend count] >= 4) {
                        [outSecs addObject:TRHShelf(@"#PopularOnYouTube", @"Recommended channel for you", nil, nil, [gTRShelfTrend subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, [gTRShelfTrend count]))])];
                        made++;
                    }
                }
                NSUInteger n = 0;
                for (NSUInteger i = 0; i < [vids count]; i += 12, n++) {
                    [outSecs addObject:TRHShelf(n == 0 ? @"Recommended for you" : @"More videos", nil, nil, nil, [vids subarrayWithRange:NSMakeRange(i, MIN((NSUInteger)12, [vids count] - i))])];
                    made++;
                }
                if ([rest count]) [outSecs addObject:@{ @"itemSectionRenderer": @{ @"contents": rest } }];
            }
            sl[@"contents"] = outSecs;
        }
        NSLog(@"[TubeReplacer] iPad horizontal shelves: %d (subs %lu, trending %lu)", made, (unsigned long)[gTRShelfSubs count], (unsigned long)[gTRShelfTrend count]);
        return made ? mn : norm;
    } @catch (NSException *e) { return norm; }
}
// the home feed only: v11/v12 iPad get horizontal shelves, everything else (trending, subscriptions, v13) the grid
static NSDictionary *TRBigCardsHome(NSDictionary *norm) { return TRWantsHShelves() ? TRHShelfHome(norm) : TRBigCards(norm); }


// v10.x home: white cards with a title and a row of video cards that scrolls sideways (shelf + horizontal list)
static BOOL TRWantsShelves(void) {
    if (majorVersion() == 10) return YES;
    // v2.3 and later 2.x apps have the shelf classes too; 2.2.0 and older do not
    if (majorVersion() == 2) return [version() compare:@"2.3" options:NSNumericSearch] != NSOrderedAscending;
    return NO;
}
// history videos for the v10 "Watch it again" shelf (filled before TRShelvesHome runs)
static NSArray *gTRHistoryItems = nil;
static void TRFetchHistoryItems(void (^done)(void)) {
    TRPostInnerTube(@"browse", @{ @"browseId": @"FEhistory" }, ^(NSDictionary *tj, NSInteger tc, NSError *te) {
        @try {
            if (tj && tc < 400) {
                NSDictionary *tn = TRNormalizeResponse(tj);
                NSMutableArray *vs = [NSMutableArray array];
                TRCollectKey(tn, @"compactVideoRenderer", vs, 0);
                NSMutableArray *items = [NSMutableArray array];
                for (id v in vs) {
                    if (![v isKindOfClass:[NSDictionary class]] || ![v[@"videoId"] length]) continue;
                    NSMutableDictionary *cv = [[v mutableCopy] autorelease];
                    if (!cv[@"shortBylineText"] && cv[@"longBylineText"]) cv[@"shortBylineText"] = cv[@"longBylineText"];
                    [items addObject:@{ @"compactVideoRenderer": cv }];
                    if ([items count] >= 8) break;
                }
                if ([items count]) gTRHistoryItems = [items copy];
            }
        } @catch (NSException *e) {}
        if (done) done();
    });
}


static NSDictionary *TRVerticalShelfSection(NSString *title, NSString *subtitle, NSArray *shown, NSArray *expanded) {
    NSMutableDictionary *shelf = [NSMutableDictionary dictionaryWithDictionary:@{ @"title": TRSimpleText(title),
        @"content": @{ @"verticalListRenderer": @{ @"items": shown } } }];
    if ([subtitle length]) shelf[@"subtitle"] = TRSimpleText(subtitle);
    if ([expanded count]) {
        // the chevron under the shelf: the app expands into these
        NSMutableArray *ex = [NSMutableArray array];
        for (NSDictionary *e in expanded) {
            NSDictionary *cv = e[@"compactVideoRenderer"];
            if ([cv isKindOfClass:[NSDictionary class]]) [ex addObject:@{ @"videoRenderer": cv }];
            else [ex addObject:e];
        }
        shelf[@"expandedShelfContentsRenderer"] = @{ @"itemsArray": ex };
    }
    return @{ @"itemSectionRenderer": @{ @"header": @{ @"itemSectionHeaderRenderer": @{ @"title": TRSimpleText(title), @"subtitle": subtitle ? TRSimpleText(subtitle) : (id)[NSNull null] } },
                                         @"contents": @[ @{ @"shelfRenderer": shelf } ] } };
}


// 10.2x draws a shelf only as a section of its own (YTShelfSectionController: header, rows, show-all); inside an item section it is a
// bare cell that draws nothing (blank white cards). 10.11 draws the wrapped form, so only newer apps get the hoisted one.
static BOOL TRShelfAsSection(void) { return majorVersion() == 10 && [version() compare:@"10.2" options:NSNumericSearch] != NSOrderedAscending; }
static NSDictionary *TRHoistShelves(NSDictionary *mn) {
    if (!TRShelfAsSection()) return mn;
    NSMutableArray *secs = [NSMutableArray array];
    TRCollectKey(mn, @"sectionListRenderer", secs, 0);
    int hoisted = 0;
    for (id sl in secs) {
        NSMutableArray *cs = [sl isKindOfClass:[NSMutableDictionary class]] && [sl[@"contents"] isKindOfClass:[NSMutableArray class]] ? sl[@"contents"] : nil;
        for (NSUInteger i = 0; i < [cs count]; i++) {
            NSArray *in = TRDig(cs[i], @[@"itemSectionRenderer", @"contents"]);
            if ([in isKindOfClass:[NSArray class]] && [in count] == 1 && [in[0] isKindOfClass:[NSDictionary class]] && in[0][@"shelfRenderer"]) { cs[i] = in[0]; hoisted++; }
        }
    }
    NSLog(@"[TubeReplacer] v10 shelves hoisted to sections: %d", hoisted);
    return mn;
}

static NSDictionary *TRShelvesHome(NSDictionary *norm) {
    @try {
        BOOL vertical = majorVersion() == 10; // the real 10.x app draws shelves as vertical thumbnail/title rows
        BOOL hasGrid = !vertical && NSClassFromString(@"YTIGridVideoRenderer") != nil; // v2.3.1 has none: its horizontal list takes compact videos
        NSData *jd = [NSJSONSerialization dataWithJSONObject:norm options:0 error:nil];
        id mn = jd ? [NSJSONSerialization JSONObjectWithData:jd options:NSJSONReadingMutableContainers error:nil] : nil;
        NSMutableArray *secs = [NSMutableArray array];
        TRCollectKey(mn, @"sectionListRenderer", secs, 0);
        int made = 0;
        NSMutableArray *mixes = [NSMutableArray array];
        for (id sl in secs) {
            NSMutableArray *cs = [sl isKindOfClass:[NSMutableDictionary class]] && [sl[@"contents"] isKindOfClass:[NSMutableArray class]] ? sl[@"contents"] : nil;
            if (!cs) continue;
            NSMutableArray *outSecs = [NSMutableArray array];
            for (id sec in cs) {
                NSArray *items = [sec isKindOfClass:[NSDictionary class]] ? TRDig(sec, @[@"itemSectionRenderer", @"contents"]) : nil;
                NSMutableArray *vids = [NSMutableArray array], *rest = [NSMutableArray array];
                for (id it in ([items isKindOfClass:[NSArray class]] ? items : @[])) {
                    NSMutableDictionary *cv = [it isKindOfClass:[NSDictionary class]] ? it[@"compactVideoRenderer"] : nil;
                    if ([cv isKindOfClass:[NSMutableDictionary class]]) {
                        if (!cv[@"shortBylineText"] && cv[@"longBylineText"]) cv[@"shortBylineText"] = cv[@"longBylineText"];
                        if (!cv[@"longBylineText"] && cv[@"shortBylineText"]) cv[@"longBylineText"] = cv[@"shortBylineText"];
                        // the v10 grid cell reads these (YTIGridVideoRenderer): view count, length, owner avatar
                        if (!cv[@"viewCountText"] && cv[@"shortViewCountText"]) cv[@"viewCountText"] = cv[@"shortViewCountText"];
                        if (!cv[@"shortViewCountText"] && cv[@"viewCountText"]) cv[@"shortViewCountText"] = cv[@"viewCountText"];
                        [vids addObject:hasGrid ? @{ @"gridVideoRenderer": cv } : @{ @"compactVideoRenderer": cv }];
                    } else {
                        NSDictionary *pl = [it isKindOfClass:[NSDictionary class]] ? (it[@"compactPlaylistRenderer"] ?: it[@"compactRadioRenderer"]) : nil;
                        if (vertical && [pl isKindOfClass:[NSDictionary class]] && [pl[@"playlistId"] hasPrefix:@"RD"]) [mixes addObject:it];
                        else [rest addObject:it];
                    }
                }
                if ([vids count] < 4) { [outSecs addObject:sec]; continue; }
                NSUInteger per = vertical ? 5 : 10, n = 0;
                for (NSUInteger i = 0; i < [vids count]; i += per, n++) {
                    NSArray *chunk = [vids subarrayWithRange:NSMakeRange(i, MIN(per, [vids count] - i))];
                    NSString *ttl = n == 0 ? (vertical ? @"Recommended" : @"Recommended videos") : @"More videos";
                    NSDictionary *shelf = @{ @"title": TRSimpleText(ttl),
                        @"content": vertical ? @{ @"verticalListRenderer": @{ @"items": chunk } } : @{ @"horizontalListRenderer": @{ @"items": chunk } } };
                    // the shelf cell draws no title itself; the item section header does (itemSectionHeaderRenderer.title)
                    [outSecs addObject:@{ @"itemSectionRenderer": @{ @"header": @{ @"itemSectionHeaderRenderer": @{ @"title": TRSimpleText(ttl) } },
                                                                      @"contents": @[ @{ @"shelfRenderer": shelf } ] } }];
                    made++;
                }
                if ([rest count]) [outSecs addObject:@{ @"itemSectionRenderer": @{ @"contents": rest } }];
            }
            if (vertical && made) {
                if ([gTRHistoryItems count]) {
                    NSArray *h = gTRHistoryItems;
                    [outSecs addObject:TRVerticalShelfSection(@"Watch it again", nil, [h subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)2, [h count]))],
                        [h count] > 2 ? [h subarrayWithRange:NSMakeRange(2, [h count] - 2)] : nil)];
                }
                if ([mixes count]) [outSecs addObject:TRVerticalShelfSection(@"YouTube Mixes", @"Nonstop playlists based on a song or artist", mixes, nil)];
            }
            sl[@"contents"] = outSecs;
        }
        NSLog(@"[TubeReplacer] v10 home shelves: %d (mixes %lu, history %lu)", made, (unsigned long)[mixes count], (unsigned long)[gTRHistoryItems count]);
        return made ? TRHoistShelves(mn) : norm;
    } @catch (NSException *e) { return norm; }
}

// v10 Subscriptions: one card per channel (avatar + name, its newest video, SHOW ALL), like the real app
static NSDictionary *TRSubsShelves(NSDictionary *norm) {
    @try {
        NSData *jd = [NSJSONSerialization dataWithJSONObject:norm options:0 error:nil];
        id mn = jd ? [NSJSONSerialization JSONObjectWithData:jd options:NSJSONReadingMutableContainers error:nil] : nil;
        NSMutableArray *secs = [NSMutableArray array];
        TRCollectKey(mn, @"sectionListRenderer", secs, 0);
        int made = 0;
        for (id sl in secs) {
            NSMutableArray *cs = [sl isKindOfClass:[NSMutableDictionary class]] && [sl[@"contents"] isKindOfClass:[NSMutableArray class]] ? sl[@"contents"] : nil;
            if (!cs) continue;
            NSMutableArray *order = [NSMutableArray array];
            NSMutableDictionary *byChan = [NSMutableDictionary dictionary], *rest = nil;
            NSMutableArray *others = [NSMutableArray array];
            for (id sec in cs) {
                NSArray *items = [sec isKindOfClass:[NSDictionary class]] ? TRDig(sec, @[@"itemSectionRenderer", @"contents"]) : nil;
                if (![items isKindOfClass:[NSArray class]]) { [others addObject:sec]; continue; }
                for (id it in items) {
                    NSMutableDictionary *cv = [it isKindOfClass:[NSDictionary class]] ? it[@"compactVideoRenderer"] : nil;
                    NSString *chan = [cv isKindOfClass:[NSMutableDictionary class]] ? (TRTextOf(cv[@"shortBylineText"]) ?: TRTextOf(cv[@"longBylineText"])) : nil;
                    if (![chan length]) { [others addObject:@{ @"itemSectionRenderer": @{ @"contents": @[ it ] } }]; continue; }
                    if (!cv[@"shortBylineText"] && cv[@"longBylineText"]) cv[@"shortBylineText"] = cv[@"longBylineText"];
                    NSMutableArray *list = byChan[chan];
                    if (!list) { list = [NSMutableArray array]; byChan[chan] = list; [order addObject:chan]; }
                    [list addObject:@{ @"compactVideoRenderer": cv }];
                }
            }
            (void)rest;
            if ([order count] < 2) continue;
            NSMutableArray *outSecs = [NSMutableArray array];
            for (NSString *chan in order) {
                NSArray *list = byChan[chan];
                NSDictionary *first = list[0][@"compactVideoRenderer"];
                NSMutableDictionary *shelf = [NSMutableDictionary dictionaryWithDictionary:@{ @"title": TRSimpleText(chan),
                    @"content": @{ @"verticalListRenderer": @{ @"items": [list subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)2, [list count]))] } } }];
                id ct = first[@"channelThumbnail"];
                if ([ct isKindOfClass:[NSDictionary class]]) shelf[@"thumbnail"] = ct;
                NSString *cid = TRDig(first, @[@"shortBylineText", @"runs", @"0", @"navigationEndpoint", @"browseEndpoint", @"browseId"]);
                id runs = TRDig(first, @[@"shortBylineText", @"runs"]);
                if ([runs isKindOfClass:[NSArray class]] && [runs count]) cid = TRDig(runs[0], @[@"navigationEndpoint", @"browseEndpoint", @"browseId"]);
                if ([cid length]) shelf[@"endpoint"] = @{ @"browseEndpoint": @{ @"browseId": cid } };
                [outSecs addObject:@{ @"itemSectionRenderer": @{ @"contents": @[ @{ @"shelfRenderer": shelf } ] } }];
                made++;
            }
            [outSecs addObjectsFromArray:others];
            sl[@"contents"] = outSecs;
        }
        NSLog(@"[TubeReplacer] v10 subscription shelves: %d", made);
        return made ? TRHoistShelves(mn) : norm;
    } @catch (NSException *e) { return norm; }
}

// iPad channel pages draw uploads as a square grid (gridVideoRenderer inside a gridRenderer), not a list
static NSDictionary *TRGridifyChannel(NSDictionary *norm) {
    if (majorVersion() < 12 || [[UIDevice currentDevice] userInterfaceIdiom] != UIUserInterfaceIdiomPad) return norm;
    // experimental and off by default: the app drew nothing for the grid. Create /var/mobile/tr_grid to try it.
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/var/mobile/tr_grid"]) return norm;
    @try {
        NSData *jd = [NSJSONSerialization dataWithJSONObject:norm options:0 error:nil];
        id mn = jd ? [NSJSONSerialization JSONObjectWithData:jd options:NSJSONReadingMutableContainers error:nil] : nil;
        if (!mn) return norm;
        NSMutableArray *tabs = TRDig(mn, @[@"contents", @"singleColumnBrowseResultsRenderer", @"tabs"]);
        if (![tabs isKindOfClass:[NSArray class]]) return norm;
        int changed = 0;
        for (id t in tabs) {
            NSString *title = TRDig(t, @[@"tabRenderer", @"title"]);
            if (!([title isEqual:@"Home"] || [title isEqual:@"Videos"] || [title isEqual:@"Live"])) continue;
            NSMutableArray *secs = [NSMutableArray array];
            TRCollectKey(t, @"itemSectionRenderer", secs, 0);
            for (id sec in secs) {
                NSMutableArray *cs = [sec isKindOfClass:[NSMutableDictionary class]] && [sec[@"contents"] isKindOfClass:[NSMutableArray class]] ? sec[@"contents"] : nil;
                if (!cs) continue;
                NSMutableArray *vids = [NSMutableArray array], *rest = [NSMutableArray array];
                for (id c in cs) {
                    NSMutableDictionary *cv = [c isKindOfClass:[NSDictionary class]] ? c[@"compactVideoRenderer"] : nil;
                    if ([cv isKindOfClass:[NSMutableDictionary class]]) {
                        if (!cv[@"shortBylineText"] && cv[@"longBylineText"]) cv[@"shortBylineText"] = cv[@"longBylineText"];
                        if (!cv[@"longBylineText"] && cv[@"shortBylineText"]) cv[@"longBylineText"] = cv[@"shortBylineText"];
                        // the v10 grid cell reads these (YTIGridVideoRenderer): view count, length, owner avatar
                        if (!cv[@"viewCountText"] && cv[@"shortViewCountText"]) cv[@"viewCountText"] = cv[@"shortViewCountText"];
                        if (!cv[@"shortViewCountText"] && cv[@"viewCountText"]) cv[@"shortViewCountText"] = cv[@"viewCountText"];
                        [vids addObject:@{ @"gridVideoRenderer": cv }];
                    } else [rest addObject:c];
                }
                if ([vids count] < 3) continue;
                [rest insertObject:@{ @"gridRenderer": @{ @"items": vids } } atIndex:0]; // bare gridVideoRenderers in a section are dropped by the schema
                sec[@"contents"] = rest; changed++;
            }
        }
        NSLog(@"[TubeReplacer] channel grid: %d section(s)", changed);
        return changed ? mn : norm;
    } @catch (NSException *e) { return norm; }
}


static id TRDeepKey(id n, NSString *key, int depth) {
    if (depth > 24) return nil;
    if ([n isKindOfClass:[NSDictionary class]]) {
        id v = n[key]; if (v) return v;
        for (id c in [n allValues]) { id r = TRDeepKey(c, key, depth + 1); if (r) return r; }
    } else if ([n isKindOfClass:[NSArray class]]) {
        for (id c in n) { id r = TRDeepKey(c, key, depth + 1); if (r) return r; }
    }
    return nil;
}
static NSString *TRVMText(id v) { // a view-model string: "text" or {content:"text"}
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSDictionary class]]) { id c = v[@"content"]; if ([c isKindOfClass:[NSString class]]) return c; return TRTextOf(v); }
    return nil;
}
// The web puts views / join date / links behind the channel's description panel (a continuation).
static void TRFetchAboutStats(NSDictionary *rawJson, void (^done)(NSDictionary *vm)) {
    NSString *token = nil;
    id panels = rawJson[@"engagementPanels"];
    id ct = TRDeepKey(panels, @"continuationCommand", 0);
    if (!ct) { id se = TRDeepKey(rawJson[@"header"], @"showEngagementPanelEndpoint", 0); if (se) ct = TRDeepKey(se, @"continuationCommand", 0); }
    if (!ct) { id se = TRDeepKey(rawJson, @"showEngagementPanelEndpoint", 0); if (se) ct = TRDeepKey(se, @"continuationCommand", 0); }
    if ([ct isKindOfClass:[NSDictionary class]] && [ct[@"token"] isKindOfClass:[NSString class]]) token = ct[@"token"];
    if (![token length]) { NSLog(@"[TubeReplacer] channel About: no description panel token"); done(nil); return; }
    TRPostInnerTube(@"browse", @{ @"continuation": token }, ^(NSDictionary *j, NSInteger code, NSError *err) {
        NSDictionary *vm = nil;
        @try { id f = j ? TRDeepKey(j, @"aboutChannelViewModel", 0) : nil; if ([f isKindOfClass:[NSDictionary class]]) vm = f; } @catch (NSException *e) {}
        NSLog(@"[TubeReplacer] channel About: stats http=%ld %@", (long)code, vm ? [[vm allKeys] componentsJoinedByString:@","] : @"not found");
        done(vm);
    });
}
static void TRPatchAbout(NSMutableDictionary *tr, NSDictionary *vm, NSString *subs) {
    NSDictionary *sl = TRDig(tr, @[@"content", @"sectionListRenderer", @"contents"]) ? nil : nil; (void)sl;
    NSArray *sc = TRDig(tr, @[@"content", @"sectionListRenderer", @"contents"]);
    NSDictionary *is = [sc count] ? sc[0][@"itemSectionRenderer"] : nil;
    NSDictionary *ab0 = [is[@"contents"] count] ? is[@"contents"][0][@"channelAboutMetadataRenderer"] : nil;
    if (![ab0 isKindOfClass:[NSDictionary class]]) return;
    NSMutableDictionary *ab = [[ab0 mutableCopy] autorelease];
    NSString *d = TRVMText(vm[@"description"]); if ([d length]) { ab[@"description"] = TRSimpleText(d); ab[@"description_p"] = TRSimpleText(d); }
    NSString *sub = TRVMText(vm[@"subscriberCountText"]); if (![sub length]) sub = subs;
    if ([sub length]) ab[@"subscriberCountText"] = TRSimpleText(sub);
    NSString *vw = TRVMText(vm[@"viewCountText"]); if ([vw length]) ab[@"viewCountText"] = TRSimpleText(vw);
    NSString *jd = TRVMText(vm[@"joinedDateText"]); if ([jd length]) ab[@"joinedDateText"] = TRSimpleText(jd);
    NSString *co = TRVMText(vm[@"country"]); if ([co length]) ab[@"country"] = TRSimpleText(co);
    NSString *cu = TRVMText(vm[@"canonicalChannelUrl"]); if ([cu length]) { ab[@"canonicalChannelUrl"] = cu; ab[@"canonicalChannelURL"] = cu; }
    NSMutableArray *links = [NSMutableArray array];
    for (id l in ([vm[@"links"] isKindOfClass:[NSArray class]] ? vm[@"links"] : @[])) {
        NSDictionary *lv = [l isKindOfClass:[NSDictionary class]] ? (l[@"channelExternalLinkViewModel"] ?: l) : nil;
        NSString *ttl = TRVMText(lv[@"title"]), *lk = TRVMText(lv[@"link"]);
        if (![lk length]) continue;
        NSString *url = [lk hasPrefix:@"http"] ? lk : [@"https://" stringByAppendingString:lk];
        [links addObject:@{ @"title": TRSimpleText([ttl length] ? ttl : lk), @"navigationEndpoint": @{ @"urlEndpoint": @{ @"url": url } } }];
    }
    if ([links count]) ab[@"primaryLinks"] = links;
    ab[@"showDescription"] = @YES;
    tr[@"content"] = @{ @"sectionListRenderer": @{ @"contents": @[ @{ @"itemSectionRenderer": @{ @"contents": @[ @{ @"channelAboutMetadataRenderer": ab } ] } } ] } };
}
static void TRInlineChannelTabs(NSDictionary *norm, NSDictionary *aboutVM, void (^done)(NSDictionary *)) {
    NSArray *tabs = TRDig(norm, @[@"contents", @"singleColumnBrowseResultsRenderer", @"tabs"]);
    if (![tabs isKindOfClass:[NSArray class]] || [tabs count] < 2) { done(norm); return; }
    NSMutableArray *work = [NSMutableArray arrayWithCapacity:[tabs count]];
    dispatch_group_t g = dispatch_group_create();
    for (NSDictionary *t in tabs) {
        NSMutableDictionary *tr = [[t[@"tabRenderer"] mutableCopy] autorelease];
        if (![tr isKindOfClass:[NSMutableDictionary class]]) continue;
        NSString *title = [tr[@"title"] isKindOfClass:[NSString class]] ? tr[@"title"] : @"";
        if ([title isEqualToString:@"Shorts"]) continue; // short-form items can't be shown by these apps
        [work addObject:tr];
        if ([tr[@"content"] isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *be = TRDig(tr, @[@"endpoint", @"browseEndpoint"]);
        if (![be[@"browseId"] length] || ![be[@"params"] length]) continue;
        dispatch_group_enter(g);
        TRPostInnerTube(@"browse", @{ @"browseId": be[@"browseId"], @"params": be[@"params"] }, ^(NSDictionary *tj, NSInteger code, NSError *err) {
            @try {
                if (tj && code < 400) {
                    NSDictionary *tn = TRNormalizeResponse(tj);
                    id content = nil;
                    for (NSDictionary *tt in ([TRDig(tn, @[@"contents", @"singleColumnBrowseResultsRenderer", @"tabs"]) isKindOfClass:[NSArray class]] ? TRDig(tn, @[@"contents", @"singleColumnBrowseResultsRenderer", @"tabs"]) : @[])) {
                        id c = TRDig(tt, @[@"tabRenderer", @"content"]);
                        if ([c isKindOfClass:[NSDictionary class]] && [TRDig(tt, @[@"tabRenderer", @"title"]) isEqual:title]) { content = c; break; }
                    }
                    if (!content && ![title isEqualToString:@"Home"] && ![title isEqualToString:@"Channels"]) { id sl = TRDig(tn, @[@"contents", @"sectionListRenderer"]); if (sl) content = @{ @"sectionListRenderer": sl }; }
                    if (content) @synchronized (tr) { tr[@"content"] = content; }
                    NSLog(@"[TubeReplacer] channel tab %@: %@ (http=%ld)", title, content ? @"loaded" : @"no content", (long)code);
                } else NSLog(@"[TubeReplacer] channel tab %@: failed http=%ld %@", title, (long)code, err);
            } @catch (NSException *e) { NSLog(@"[TubeReplacer] channel tab %@: %@", title, e); }
            dispatch_group_leave(g);
        });
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        NSMutableArray *nt = [NSMutableArray array];
        for (NSMutableDictionary *tr in work) { // "Channels" the web won't serve: use the channels the other tabs feature
            if (![tr[@"title"] isEqual:@"Channels"] || [tr[@"content"] isKindOfClass:[NSDictionary class]]) continue;
            NSMutableArray *found = [NSMutableArray array];
            NSMutableSet *seen = [NSMutableSet set];
            NSMutableArray *stack = [NSMutableArray arrayWithObject:work];
            while ([stack count]) {
                id n = [stack lastObject]; [stack removeLastObject];
                if ([n isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *cc = n[@"compactChannelRenderer"];
                    if ([cc isKindOfClass:[NSDictionary class]]) { NSString *i = cc[@"channelId"]; if (i && ![seen containsObject:i]) { [seen addObject:i]; { NSMutableDictionary *ccm = [[cc mutableCopy] autorelease]; NSDictionary *fsb = TRSubscribeButtonNewLook(i); if (fsb) ccm[@"subscribeButton"] = fsb; [found addObject:@{ @"compactChannelRenderer": ccm }]; } } continue; }
                    [stack addObjectsFromArray:[n allValues]];
                } else if ([n isKindOfClass:[NSArray class]]) [stack addObjectsFromArray:n];
            }
            NSLog(@"[TubeReplacer] channel tab Channels: fallback found %lu channel(s)", (unsigned long)[found count]);
            if ([found count]) tr[@"content"] = @{ @"sectionListRenderer": @{ @"contents": @[ @{ @"itemSectionRenderer": @{ @"contents": found } } ] } };
        }
        for (NSMutableDictionary *tr in work) {
            if ([tr[@"title"] isEqual:@"About"]) { @try { TRPatchAbout(tr, aboutVM ?: @{}, TRFindSubscriberText(norm[@"header"], 0)); } @catch (NSException *e) {} }
            // a tab with nothing in it (no content, or a list without any item) would show up as an empty tab
            if (![tr[@"title"] isEqual:@"Home"]) {
                NSMutableArray *st = [NSMutableArray arrayWithObject:tr[@"content"] ?: @{}];
                BOOL hasItem = NO;
                while ([st count] && !hasItem) {
                    id n = [st lastObject]; [st removeLastObject];
                    if ([n isKindOfClass:[NSDictionary class]]) {
                        for (NSString *k in n) {
                            if ([k hasPrefix:@"compact"] || [k isEqualToString:@"messageRenderer"] || [k isEqualToString:@"commentThreadRenderer"] || [k isEqualToString:@"channelAboutMetadataRenderer"]) { hasItem = YES; break; }
                            [st addObject:n[k]];
                        }
                    } else if ([n isKindOfClass:[NSArray class]]) [st addObjectsFromArray:n];
                }
                if (!hasItem) { NSLog(@"[TubeReplacer] channel tab %@: empty, dropped", tr[@"title"]); continue; }
            }
            [nt addObject:@{ @"tabRenderer": tr }];
        }
        NSMutableDictionary *r = [[norm mutableCopy] autorelease];
        r[@"contents"] = @{ @"singleColumnBrowseResultsRenderer": @{ @"tabs": nt } };
        dispatch_release(g);
        done(r);
    });
}

// The guide endpoint no longer exists for these clients: build the drawer locally.
static NSString *TRTrendingBrowseId(void);
// ---- subscriptions "new videos" dot: remember the newest video the person has seen in the Subscriptions feed
static int gTRSubsUnseen = 0;
static NSTimeInterval gTRUnseenAt = 0;
static NSString *TRSeenKey(void) { return @"TRSubsSeenTopVideo"; }
static void TRNoteSubsFeed(NSArray *videos, BOOL opened) {
    @try {
        NSString *top = [videos count] ? videos[0][@"videoId"] : nil;
        if (![top length]) return;
        NSString *seen = [[NSUserDefaults standardUserDefaults] stringForKey:TRSeenKey()];
        if (opened || !seen) { [[NSUserDefaults standardUserDefaults] setObject:top forKey:TRSeenKey()]; gTRSubsUnseen = 0; return; }
        int n = 0;
        for (NSDictionary *v in videos) { if ([v[@"videoId"] isEqualToString:seen]) break; n++; }
        gTRSubsUnseen = n >= (int)[videos count] ? 0 : MIN(n, 99); // the seen video fell out of the list: don't guess
    } @catch (NSException *e) {}
}
static void TRRefreshUnseen(void) {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gTRUnseenAt < 300) return;
    gTRUnseenAt = now;
    TRPostInnerTube(@"browse", @{ @"browseId": @"FEsubscriptions" }, ^(NSDictionary *tj, NSInteger tc, NSError *te) {
        @try { if (tj && tc < 400) TRNoteSubsFeed(TRVideosOf(TRNormalizeResponse(tj)), NO); } @catch (NSException *e) {}
        NSLog(@"[TubeReplacer] subscriptions unseen: %d", gTRSubsUnseen);
    });
}
// The guide endpoint no longer exists for these clients: build the drawer, the bottom tab bar and the account button locally.

// the account menu answers a moment after launch; the guide / library are built earlier: use what was saved last time, else wait a little
static void TRWaitIdentity(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![gTRProfileName length]) { NSString *v = [ud stringForKey:@"TRIdName"]; if ([v length]) gTRProfileName = [v copy]; }
    if (![gTRProfilePhoto length]) { NSString *v = [ud stringForKey:@"TRIdPhoto"]; if ([v length]) gTRProfilePhoto = [v copy]; }
    if (!gTRMyChannel) { NSString *v = [ud stringForKey:@"TRIdChannel"]; if ([v length]) gTRMyChannel = [v copy]; }
    if ([gTRProfileName length] && gTRMyChannel) return;
    TRRefreshSubs();
    if ([NSThread isMainThread]) return;
    for (int i = 0; i < 30 && !([gTRProfileName length] && gTRMyChannel); i++) [NSThread sleepForTimeInterval:0.1];
}
static BOOL gTRGuideLite = NO; // set when the app rejected the tab bar / account button: fall back to the drawer only
static NSDictionary *TRSyntheticGuide(void) {
    // iconType values from YTIIcon's icon switch (2=history 3=watch later 5=what to watch 6=subscriptions 7=playlists 16=likes)
    NSArray *spec = @[ @[@"What to Watch", @"FEwhat_to_watch", @5], @[@"Trending", @"FEtrending", @17],
                       @[@"Subscriptions", @"FEsubscriptions", @6], @[@"History", @"FEhistory", @2],
                       @[@"Library", @"FElibrary", @7], @[@"Liked videos", @"VLLL", @16], @[@"Watch later", @"VLWL", @3] ];
    NSMutableArray *entries = [NSMutableArray array];
    for (NSArray *s in spec)
        [entries addObject:@{ @"guideEntryRenderer": @{
            @"title": s[0], @"icon": @{ @"iconType": s[2] }, @"formattedTitle": @{ @"runs": @[ @{ @"text": s[0] } ] },
            @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": s[1] } } } }];
    NSMutableArray *items = [NSMutableArray arrayWithObject:@{ @"guideSectionRenderer": @{ @"items": entries } }];
    if (majorVersion() >= 12 && !gTRGuideLite) {
        TRRefreshUnseen();
        TRWaitIdentity();
        NSLog(@"[TubeReplacer] guide identity: name=%@ photo=%@ channel=%@", gTRProfileName ?: @"-", [gTRProfilePhoto length] ? @"yes" : @"no", gTRMyChannel ?: @"-");
        // bottom tab bar (YTPivotBarRenderer): icons 65 home, 66 subscriptions, 67 trending, 68 library, 355 activity from the app's pivot icon switch;
        // pivotBarItemStyle 1 = the little red dot
        NSMutableArray *piv = [NSMutableArray array];
        void (^addPivot)(NSString *, NSString *, int, BOOL) = ^(NSString *title, NSString *bid, int icon, BOOL dot) {
            NSMutableDictionary *it = [NSMutableDictionary dictionaryWithDictionary:@{ @"pivotIdentifier": bid, @"title": TRSimpleText(title),
                @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": bid } }, @"icon": @{ @"iconType": @(icon) },
                @"accessibility": @{ @"accessibilityData": @{ @"label": title } } }];
            if (dot) it[@"presentationStyle"] = @{ @"pivotBarItemStyle": @1 };
            [piv addObject:@{ @"pivotBarItemRenderer": it }];
        };
        addPivot(@"Home", @"FEwhat_to_watch", 65, NO);
        addPivot(@"Trending", TRTrendingBrowseId(), 67, NO);
        addPivot(@"Subscriptions", @"FEsubscriptions", 66, gTRSubsUnseen > 0);
        if (majorVersion() >= 13) addPivot(@"Activity", @"FEactivity", 355, NO);
        addPivot(@"Library", @"FElibrary", 68, NO);
        [items addObject:@{ @"pivotBarRenderer": @{ @"items": piv } }];
        // account button: opens the "Your account" panel (multiPageMenuRenderer: header with the person, then links)
        NSString *name = [gTRProfileName length] ? gTRProfileName : @"Your account";
        NSMutableDictionary *hdr = [NSMutableDictionary dictionaryWithObject:TRSimpleText(name) forKey:@"accountName"];
        NSDictionary *photo = [gTRProfilePhoto length] ? @{ @"thumbnails": @[ @{ @"url": gTRProfilePhoto, @"width": @96, @"height": @96 } ] } : nil;
        if (photo) hdr[@"accountPhoto"] = photo;
        if ([gTRProfileHandle length]) hdr[@"email"] = TRSimpleText(gTRProfileHandle);
        if ([gTRMyChannel length]) hdr[@"channelEndpoint"] = @{ @"browseEndpoint": @{ @"browseId": gTRMyChannel } };
        NSDictionary *(^lk)(NSString *, int, NSDictionary *) = ^NSDictionary *(NSString *t, int icon, NSDictionary *ep) {
            NSMutableDictionary *c = [NSMutableDictionary dictionaryWithDictionary:@{ @"title": TRSimpleText(t), @"navigationEndpoint": ep }];
            if (icon) c[@"icon"] = @{ @"iconType": @(icon) };
            return @{ @"compactLinkRenderer": c };
        };
        NSDictionary *(^be)(NSString *) = ^NSDictionary *(NSString *b) { return @{ @"browseEndpoint": @{ @"browseId": b } }; };
        NSDictionary *(^ue)(NSString *) = ^NSDictionary *(NSString *u) { return @{ @"urlEndpoint": @{ @"url": u } }; };
        NSMutableArray *s1 = [NSMutableArray array];
        if ([gTRMyChannel length]) [s1 addObject:lk(@"My channel", 1, be(gTRMyChannel))];
        [s1 addObject:lk(@"Notifications", 29, be(@"FEnotifications_inbox"))];
        [s1 addObject:lk(@"History", 2, be(@"FEhistory"))];
        [s1 addObject:lk(@"Watch Later", 3, be(@"VLWL"))];
        NSArray *s2 = @[ lk(@"Terms & privacy policy", 49, ue(@"https://www.youtube.com/t/terms")), lk(@"Help", 80, ue(@"https://support.google.com/youtube")) ];
        NSMutableDictionary *btn = [NSMutableDictionary dictionaryWithDictionary:@{
            @"tooltip": name,
            @"menuRenderer": @{ @"multiPageMenuRenderer": @{ @"header": @{ @"activeAccountHeaderRenderer": hdr },
                @"sections": @[ @{ @"multiPageMenuSectionRenderer": @{ @"items": s1 } }, @{ @"multiPageMenuSectionRenderer": @{ @"items": s2 } } ] } } }];
        if (photo) btn[@"avatar"] = photo;
        // the record/upload camera: the app's top bar turns a buttonRenderer with a cameraEndpoint into its camera button (icon 141 = cameraIconWithColor:)
        NSDictionary *cam = @{ @"buttonRenderer": @{ @"icon": @{ @"iconType": @141 }, @"navigationEndpoint": @{ @"cameraEndpoint": @{ @"hack": @YES } },
            @"accessibility": @{ @"label": @"Record" }, @"accessibilityData": @{ @"accessibilityData": @{ @"label": @"Record" } } } };
        [items addObject:@{ @"mobileTopbarRenderer": @{ @"buttons": @[ cam, @{ @"topbarMenuButtonRenderer": btn } ] } }];
    }
    return @{ @"items": items };
}


// v10/v11 drawer, laid out like the real app's guide: account header, Home / My Channel / Subscriptions / History / Watch Later,
// a collapsible PLAYLISTS section and the SUBSCRIPTIONS channel list (guide entries from the web guide)
static NSDictionary *TRDrawerGuide(NSDictionary *web, NSInteger wlCount) {
    NSMutableArray *subs = [NSMutableArray array], *lists = [NSMutableArray array], *extra = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *entries = [NSMutableArray array];
    @try { if (web) TRCollectKey(web, @"guideEntryRenderer", entries, 0); } @catch (NSException *e) {}
    for (id en in entries) {
        if (![en isKindOfClass:[NSDictionary class]]) continue;
        NSString *bid = TRDig(en, @[@"navigationEndpoint", @"browseEndpoint", @"browseId"]);
        if (![bid length] || [seen containsObject:bid]) continue;
        NSString *t = TRTextOf(en[@"formattedTitle"]); if (![t length]) t = TRTextOf(en[@"title"]);
        if (![t length]) continue;
        if ([bid hasPrefix:@"UC"] && [bid length] > 20) {
            if ([bid isEqualToString:gTRMyChannel] || [t isEqualToString:@"Your channel"] || [t isEqualToString:@"My channel"]) { [seen addObject:bid]; continue; } // My Channel is already in the top section
            NSString *xi = nil; // YouTube's own channels, shown apart from the user's subscriptions
            if ([bid isEqualToString:@"UC-9-kyTW8ZkZNDHQJ6FgpwQ"]) xi = @"Music";
            else if ([bid isEqualToString:@"UC4R8DWoMoI7CAwX8_LjQHig"]) xi = @"Live";
            else if ([bid isEqualToString:@"UCOpNcN46UbXVtpKMrmU4Abg"]) xi = @"Gaming";
            if (xi) {
                // only Music has a guide icon in the app (21); the others keep their channel picture
                NSMutableDictionary *e = [NSMutableDictionary dictionaryWithDictionary:@{ @"title": xi, @"formattedTitle": TRSimpleText(xi),
                    @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": bid } } }];
                NSArray *th = TRDig(en, @[@"thumbnail", @"thumbnails"]);
                NSString *tu = [th isKindOfClass:[NSArray class]] && [th count] ? th[0][@"url"] : nil;
                if ([xi isEqualToString:@"Music"]) e[@"icon"] = @{ @"iconType": @21 };
                else if ([tu length]) e[@"thumbnail"] = @{ @"thumbnails": @[ @{ @"url": tu, @"width": @88, @"height": @88 } ] };
                [seen addObject:bid]; [extra addObject:@{ @"guideEntryRenderer": e }];
                continue;
            }
            NSMutableDictionary *e = [NSMutableDictionary dictionaryWithDictionary:@{ @"title": t, @"formattedTitle": TRSimpleText(t),
                @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": bid } } }];
            NSArray *th = TRDig(en, @[@"thumbnail", @"thumbnails"]);
            NSString *tu = [th isKindOfClass:[NSArray class]] && [th count] ? th[0][@"url"] : nil;
            if ([tu length]) e[@"thumbnail"] = @{ @"thumbnails": @[ @{ @"url": tu, @"width": @88, @"height": @88 } ] };
            [seen addObject:bid]; [subs addObject:@{ @"guideEntryRenderer": e }];
        } else if ([bid hasPrefix:@"VL"] && ![bid isEqualToString:@"VLWL"] && ![bid isEqualToString:@"VLLL"] && [bid length] > 6) {
            [seen addObject:bid];
            [lists addObject:@{ @"guideEntryRenderer": @{ @"title": t, @"formattedTitle": TRSimpleText(t), @"icon": @{ @"iconType": @7 },
                @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": bid } } } }];
        }
    }
    NSDictionary *(^ent)(NSString *, int, NSString *, NSInteger) = ^NSDictionary *(NSString *t, int icon, NSString *bid, NSInteger count) {
        NSMutableDictionary *e = [NSMutableDictionary dictionaryWithDictionary:@{ @"title": t, @"formattedTitle": TRSimpleText(t), @"icon": @{ @"iconType": @(icon) } }];
        if ([bid length]) e[@"navigationEndpoint"] = @{ @"browseEndpoint": @{ @"browseId": bid } };
        if (count > 0) e[@"count"] = @(count);
        return @{ @"guideEntryRenderer": e };
    };
    NSMutableArray *top = [NSMutableArray array];
    [top addObject:ent(@"Home", 5, @"FEwhat_to_watch", 0)];
    if ([gTRMyChannel length]) {
        // My Channel carries the upload button as its secondary action
        NSString *t = @"My Channel";
        [top addObject:@{ @"guideEntryWithSecondaryActionRenderer": @{ @"title": t, @"formattedTitle": TRSimpleText(t), @"icon": @{ @"iconType": @1 },
            @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": gTRMyChannel } },
            @"secondaryIcon": @{ @"iconType": @10 }, @"secondaryNavigationEndpoint": @{ @"uploadEndpoint": @{ @"hack": @YES } } } }];
    }
    [top addObject:ent(@"Subscriptions", 6, @"FEsubscriptions", 0)];
    if (majorVersion() >= 11) [top addObject:ent(@"Trending", 17, TRTrendingBrowseId(), 0)];
    [top addObject:ent(@"History", 2, @"FEhistory", 0)];
    [top addObject:ent(@"Watch Later", 3, @"VLWL", wlCount)];
    NSMutableArray *sections = [NSMutableArray arrayWithObject:@{ @"guideSectionRenderer": @{ @"items": top } }];
    if ([lists count]) {
        NSMutableArray *pl = [NSMutableArray array];
        NSUInteger vis = MIN((NSUInteger)3, [lists count]);
        for (NSUInteger i = 0; i < vis; i++) [pl addObject:lists[i]];
        if ([lists count] > vis) {
            NSDictionary *(^plain)(NSString *, int) = ^NSDictionary *(NSString *t, int icon) {
                return @{ @"guideEntryRenderer": @{ @"title": t, @"formattedTitle": TRSimpleText(t), @"icon": @{ @"iconType": @(icon) } } };
            };
            [pl addObject:@{ @"guideCollapsibleEntryRenderer": @{
                @"expanderItem": plain(@"Show more", 19), @"collapserItem": plain(@"Show less", 20),
                @"expandableItems": [lists subarrayWithRange:NSMakeRange(vis, [lists count] - vis)] } }];
        }
        [sections addObject:@{ @"guideSectionRenderer": @{ @"title": @"Playlists", @"formattedTitle": TRSimpleText(@"Playlists"), @"items": pl } }];
    }
    if ([subs count])
        [sections addObject:@{ @"guideSubscriptionsSectionRenderer": @{ @"title": @"Subscriptions", @"formattedTitle": TRSimpleText(@"Subscriptions"), @"items": subs } }];
    if ([extra count]) [sections addObject:@{ @"guideSectionRenderer": @{ @"title": @"More from YouTube", @"formattedTitle": TRSimpleText(@"More from YouTube"), @"items": extra } }];
    NSMutableDictionary *res = [NSMutableDictionary dictionaryWithObject:sections forKey:@"items"];
    if ([gTRProfileName length]) {
        NSMutableDictionary *hdr = [NSMutableDictionary dictionaryWithObject:TRSimpleText(gTRProfileName) forKey:@"accountName"];
        if ([gTRProfilePhoto length]) hdr[@"accountPhoto"] = @{ @"thumbnails": @[ @{ @"url": gTRProfilePhoto, @"width": @96, @"height": @96 } ] };
        if ([gTRMyChannel length]) hdr[@"channelEndpoint"] = @{ @"browseEndpoint": @{ @"browseId": gTRMyChannel } };
        hdr[@"settingsEndpoint"] = @{ @"applicationSettingsEndpoint": @{ @"hack": @YES } };
        res[@"accountListHeader"] = @{ @"activeAccountHeaderRenderer": hdr };
    }
    NSLog(@"[TubeReplacer] drawer guide: %lu playlist(s), %lu subscription(s), watch later=%ld", (unsigned long)[lists count], (unsigned long)[subs count], (long)wlCount);
    return res;
}

#pragma mark - InnerTube plumbing

static BOOL TRBridgeEnabled(void) {
    static int cached = -1;
    if (cached < 0) {
        // Versions that still carry the legacy GData screens are handled by the legacy path
        // (clientconfig.x forces them), so only take over where those screens are gone.
        // 12.x replaced YTBaseApiaryService with YTBaseInnerTubeService (-> TRBridgeIsV12)
        BOOL apiary = NSClassFromString(@"YTBaseApiaryService") != nil || NSClassFromString(@"YTBaseInnerTubeService") != nil;
        cached = (apiary && NSClassFromString(@"YTVideosFeedController") == nil) ? 1 : 0;
    }
    return cached == 1;
}

static NSString *TREndpointFromURL(NSURL *url) {
    NSString *path = [url path];
    NSRange r = [path rangeOfString:@"/youtubei/v1/"];
    if (r.location == NSNotFound) return nil;
    NSString *e = [path substringFromIndex:r.location + r.length];
    return [e length] ? e : nil;
}

static NSDictionary *TRUploadClassMap(void) { // endpoint -> message class stem (the stems do not follow the path names)
    return @{ @"upload/register": @"RegisterVideo", @"upload/create": @"CreateDraftVideo", @"upload/commit": @"CommitVideo",
              @"upload/process": @"ProcessVideo", @"upload/replace": @"ReplaceDraftVideo", @"upload/feedback": @"GetUploadFeedback",
              @"upload/get_upload_video_form": @"GetUploadVideoForm", @"video_manager/metadata_editor": @"GetMetadataEditor",
              @"video_manager/metadata_update": @"MetadataUpdate" };
}
static Class TRResponseClassFor(id service, NSString *endpoint) {
    SEL s = NSSelectorFromString(@"responseClass");
    if ([service respondsToSelector:s]) {
        id c = [service performSelector:s];
        if (c && class_isMetaClass(object_getClass(c))) return (Class)c;
    }
    { NSString *us = TRUploadClassMap()[endpoint]; if (us) return NSClassFromString([NSString stringWithFormat:@"YTI%@Response", us]); }
    if ([[endpoint lastPathComponent] isEqualToString:@"next"]) return NSClassFromString(@"YTIWatchNextResponse");
    if ([endpoint isEqualToString:@"like/removelike"]) return NSClassFromString(@"YTIRemoveLikeResponse");
    if ([endpoint isEqualToString:@"browse/edit_playlist"]) return NSClassFromString(@"YTIPlaylistEditActionResponse");
    NSMutableString *m = [NSMutableString stringWithString:@"YTI"];
    for (NSString *p in [[endpoint lastPathComponent] componentsSeparatedByString:@"_"])
        if ([p length]) [m appendString:[[[p substringToIndex:1] uppercaseString] stringByAppendingString:[p substringFromIndex:1]]];
    [m appendString:@"Response"];
    return NSClassFromString(m);
}

static Class TRProtoClassOfParser(id parser) {
    if (!parser || !TRHasIvar(parser, @"_protoClass")) return nil;
    id c = [parser valueForKey:@"_protoClass"];
    return (c && class_isMetaClass(object_getClass(c))) ? (Class)c : nil;
}

// endpoint -> request message class (services that expose -requestClass are preferred)
static Class TRRequestClassFor(id service, NSString *endpoint) {
    SEL requestClassSel = NSSelectorFromString(@"requestClass");
    if ([service respondsToSelector:requestClassSel]) {
        id c = [service performSelector:requestClassSel];
        if (c && class_isMetaClass(object_getClass(c))) return (Class)c;
    }
    NSDictionary *special = @{ @"next": @"YTIWatchNextRequest", @"like/removelike": @"YTIRemoveLikeRequest", @"browse/edit_playlist": @"YTIPlaylistEditActionRequest" };
    NSString *name = special[endpoint];
    { NSString *us = TRUploadClassMap()[endpoint]; if (us) name = [NSString stringWithFormat:@"YTI%@Request", us]; }
    if (!name) {
        NSMutableString *m = [NSMutableString stringWithString:@"YTI"];
        for (NSString *p in [[endpoint lastPathComponent] componentsSeparatedByString:@"_"])
            if ([p length]) [m appendString:[[[p substringToIndex:1] uppercaseString] stringByAppendingString:[p substringFromIndex:1]]];
        [m appendString:@"Request"];
        name = m;
    }
    return NSClassFromString(name);
}

// Read-only endpoints that exist as plain InnerTube JSON calls.
static BOOL TRIsReadEndpoint(NSString *e) {
    static NSSet *s = nil;
    if (!s) s = [[NSSet setWithObjects:@"browse", @"search", @"next", @"guide", @"get_search_suggestions", @"share/get_share_panel", nil] retain];
    return [s containsObject:e];
}

static NSOperationQueue *TRBridgeQueue(void) {
    static NSOperationQueue *q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = [[NSOperationQueue alloc] init]; [q setMaxConcurrentOperationCount:4]; });
    return q;
}

static NSError *TRError(NSInteger code, NSString *msg) {
    return [NSError errorWithDomain:@"TubeReplacer" code:code userInfo:@{ NSLocalizedDescriptionKey: msg ?: @"Request failed." }];
}

// JSON -> message through the app's own parser


static NSOperationQueue *TRBridgeQueue(void);
// Signed-in support: the app's own (web-cookie based) sign-in keeps a GTMOAuth2Authentication
// whose authorizeNSRequest: adds Cookie + SAPISIDHASH headers, which is exactly what the web
// InnerTube client wants. Remember the service's userAuth so every bridged call can use it.
static id gTRUserAuth = nil;
static void TRRememberUserAuth(id service) {
    @try {
        if ([service respondsToSelector:@selector(userAuth)]) {
            id ua = [service performSelector:@selector(userAuth)];
            if (ua) gTRUserAuth = [ua retain];
        }
    } @catch (NSException *e) {}
}
// 12.x hands the active YTIdentity to the service on every call: identity.authorization.identity.auth
static id gTRGauth = nil;
static NSString *gTRAccountName = nil;
// the account the sign-in just finished with (set by signin12.x), used until the app has an active identity
NSDictionary *gTRLastAccountParams = nil;
static void TRRememberIdentity(id service, id identity) {
    @try {
        if (!identity) {
            Ivar iv = class_getInstanceVariable([service class], "_identityProvider");
            id ip = iv ? object_getIvar(service, iv) : nil;
            if ([ip respondsToSelector:@selector(activeIdentity)]) identity = [ip performSelector:@selector(activeIdentity)];
        }
        id az = [identity respondsToSelector:@selector(authorization)] ? [identity performSelector:@selector(authorization)] : nil;
        id sso = [az respondsToSelector:@selector(identity)] ? [az performSelector:@selector(identity)] : nil;
        id g = [sso respondsToSelector:@selector(auth)] ? [sso performSelector:@selector(auth)] : nil;
        id old = gTRGauth; gTRGauth = [g retain]; [old release];
    } @catch (NSException *e) {}
}
// the signed-in account's parameters: 12.x identity, else the 10.x/11.x user auth, else what the sign-in just produced
static NSDictionary *TRAccountParams(void) {
    @try {
        id g = gTRGauth;
        if (!g && gTRUserAuth) {
            id ua = gTRUserAuth;
            id authn = [ua respondsToSelector:@selector(authentication)] ? [ua performSelector:@selector(authentication)] : nil;
            id ident = [authn respondsToSelector:@selector(identity)] ? [authn performSelector:@selector(identity)] : nil;
            g = [ident respondsToSelector:@selector(auth)] ? [ident performSelector:@selector(auth)] : nil;
            if (!g) { id i2 = [ua respondsToSelector:@selector(identity)] ? [ua performSelector:@selector(identity)] : nil; g = [i2 respondsToSelector:@selector(auth)] ? [i2 performSelector:@selector(auth)] : nil; }
            if (!g && [authn respondsToSelector:@selector(parameters)]) g = authn;
            if (!g && [ua respondsToSelector:@selector(auth)]) g = [ua performSelector:@selector(auth)];
            NSLog(@"[TubeReplacer] account params: userAuth=%@ authentication=%@ identity=%@ auth=%@", [ua class], [authn class], [ident class], [g class]);
        }
        if ([g respondsToSelector:@selector(parameters)]) {
            id p = [g performSelector:@selector(parameters)];
            if ([p isKindOfClass:[NSDictionary class]] && [p count]) return p;
        }
    } @catch (NSException *e) {}
    return gTRLastAccountParams;
}
static BOOL TRAuthorizeRequest(NSMutableURLRequest *req) {
    @try {
        id gauth = gTRGauth;
        if (!gauth) {
        id ua = gTRUserAuth;
        if (!ua) return NO;
        if ([ua respondsToSelector:@selector(isAuthenticated)] && ![ua performSelector:@selector(isAuthenticated)]) return NO;
        id authn = [ua respondsToSelector:@selector(authentication)] ? [ua performSelector:@selector(authentication)] : nil;
        id ident = [authn respondsToSelector:@selector(identity)] ? [authn performSelector:@selector(identity)] : nil;
        gauth = [ident respondsToSelector:@selector(auth)] ? [ident performSelector:@selector(auth)] : nil;
        }
        if (![gauth respondsToSelector:@selector(authorizeNSRequest:)]) return NO;
        NSMutableURLRequest *r = req;
        BOOL ok = ((BOOL (*)(id, SEL, NSMutableURLRequest **))objc_msgSend)(gauth, @selector(authorizeNSRequest:), &r);
        return ok;
    } @catch (NSException *e) {
        NSLog(@"[TubeReplacer] authorize failed: %@", e);
        return NO;
    }
}
BOOL TRAuthorizeRequestExt(NSMutableURLRequest *req) { return TRAuthorizeRequest(req); }
static void TRPostInnerTube(NSString *endpoint, NSDictionary *body, void (^cb)(NSDictionary *json, NSInteger code, NSError *err));
// the signed-in web player answer (the bridge's own web client), for the HD merge
void TRFetchWebPlayerSigned(NSString *videoID, NSNumber *sts, void (^cb)(NSDictionary *json, NSInteger code)) {
    NSMutableDictionary *b = [NSMutableDictionary dictionaryWithDictionary:@{ @"videoId": videoID, @"contentCheckOk": @YES, @"racyCheckOk": @YES }];
    if (sts) b[@"playbackContext"] = @{ @"contentPlaybackContext": @{ @"signatureTimestamp": sts } };
    TRPostInnerTube(@"player", b, ^(NSDictionary *wj, NSInteger c, NSError *e) { cb(wj, c); });
}

static void TRPostInnerTube(NSString *endpoint, NSDictionary *body, void (^cb)(NSDictionary *json, NSInteger code, NSError *err)) {
    YoutubeClientType *client = [YoutubeClientType webClient];
    NSMutableDictionary *full = [NSMutableDictionary dictionaryWithObject:[client makeContext] forKey:@"context"];
    [full addEntriesFromDictionary:body];
    NSString *u = [NSString stringWithFormat:@"https://www.youtube.com/youtubei/v1/%@?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false", endpoint];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
    [req setHTTPMethod:@"POST"];
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:full options:0 error:nil]];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if ([client.useragent length]) [req setValue:client.useragent forHTTPHeaderField:@"User-Agent"];
    BOOL signedIn = TRAuthorizeRequest(req);
    NSLog(@"[TubeReplacer] innertube %@: %@", endpoint, signedIn ? @"signed in" : @"anonymous");
    [NSURLConnection sendAsynchronousRequest:req queue:TRBridgeQueue() completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        cb([json isKindOfClass:[NSDictionary class]] ? json : nil, code, err);
    }];
}


// Watch history sync: the old apps' own stats pings never reach the account, so report the playback the way the web player
// does (signed-in web player answer -> videostats playback + watchtime URLs). The real position is unknown here, so the
// watch time follows the wall clock while this video is the latest one asked for.
static NSString *gTRWatchVideo = nil; static int gTRWatchGen = 0;
static void TRWatchPing(NSString *base, NSDictionary *extra, NSString *ua) {
    if (![base length]) return;
    NSMutableString *u = [NSMutableString stringWithString:base];
    for (NSString *k in extra) [u appendFormat:@"%@%@=%@", [u rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&", k, extra[k]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    if ([ua length]) [r setValue:ua forHTTPHeaderField:@"User-Agent"];
    [r setValue:@"https://m.youtube.com/" forHTTPHeaderField:@"Referer"];
    TRAuthorizeRequest(r);
    [NSURLConnection sendAsynchronousRequest:r queue:TRBridgeQueue() completionHandler:^(NSURLResponse *resp, NSData *d, NSError *e) {
        NSLog(@"[TubeReplacer] watch sync: ping http=%ld", (long)([resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0));
    }];
}
static void TRReportWatch(NSString *videoID, NSNumber *lengthSec, NSDictionary *fallbackJSON) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/dev.preloading.tubereplacer.preferences.plist"];
    if (prefs[@"EnableVideoStats"] && ![prefs[@"EnableVideoStats"] boolValue]) return;
    int gen;
    @synchronized ([NSNumber class]) {
        if ([gTRWatchVideo isEqualToString:videoID]) return; // retries of the same video
        [gTRWatchVideo release]; gTRWatchVideo = [videoID copy]; gen = ++gTRWatchGen;
    }
    TRFetchWebPlayerSigned(videoID, nil, ^(NSDictionary *wj, NSInteger code) {
        NSString *pb = TRDig(wj, @[@"playbackTracking", @"videostatsPlaybackUrl", @"baseUrl"]);
        NSString *wt = TRDig(wj, @[@"playbackTracking", @"videostatsWatchtimeUrl", @"baseUrl"]);
        NSLog(@"[TubeReplacer] watch sync: %@ web player http=%ld playback=%d watchtime=%d", videoID, (long)code, [pb length] > 0, [wt length] > 0);
        if (![pb length]) { // the web answer carries no tracking URLs: use the ones of the player response the app got (sent signed)
            pb = TRDig(fallbackJSON, @[@"playbackTracking", @"videostatsPlaybackUrl", @"baseUrl"]);
            wt = TRDig(fallbackJSON, @[@"playbackTracking", @"videostatsWatchtimeUrl", @"baseUrl"]);
            NSLog(@"[TubeReplacer] watch sync: fallback urls playback=%d watchtime=%d", [pb length] > 0, [wt length] > 0);
        }
        if (![pb length]) return;
        NSString *ua = [[YoutubeClientType webClient] useragent];
        static const char *abc = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_";
        NSMutableString *cpn = [NSMutableString string];
        for (int i = 0; i < 16; i++) [cpn appendFormat:@"%c", abc[arc4random_uniform(64)]];
        TRWatchPing(pb, @{ @"ver": @"2", @"cpn": cpn, @"cmt": @"0", @"el": @"detailpage", @"fmt": @"18" }, ua);
        if (![wt length]) return;
        double total = [lengthSec doubleValue] > 0 ? [lengthSec doubleValue] : 600;
        __block double pos = 0; __block int n = 0;
        __block void (^step)(void) = nil;
        step = [^{
            @synchronized ([NSNumber class]) { if (gen != gTRWatchGen) { [step release]; step = nil; return; } }
            double inc = n == 0 ? 10 : 30; double prev = pos; pos = MIN(total, pos + inc); n++;
            BOOL last = pos >= total || n >= 14;
            NSString *p = [NSString stringWithFormat:@"%.3f", pos], *st = [NSString stringWithFormat:@"%.3f", prev];
            NSMutableDictionary *ex = [NSMutableDictionary dictionaryWithDictionary:@{ @"ver": @"2", @"cpn": cpn, @"cmt": p, @"st": st, @"et": p, @"state": @"playing", @"el": @"detailpage", @"fmt": @"18" }];
            if (last) { ex[@"final"] = @"1"; ex[@"state"] = @"paused"; }
            TRWatchPing(wt, ex, ua);
            if (last) { [step release]; step = nil; return; }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), step);
        } copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), step);
    });
}


// Live streams on 11.x+: the app's own HLS proxy parser refuses the modern master playlist (no stream at all). Fetch it, keep
// only the plain H.264/AAC variants with the tags the old parser knows, and hand the app a local copy.
static NSString *TRSplitAttr(NSString *attrs, NSString *key) {
    BOOL q = NO; NSMutableString *cur = [NSMutableString string];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < [attrs length]; i++) {
        unichar c = [attrs characterAtIndex:i];
        if (c == '"') q = !q;
        if (c == ',' && !q) { [parts addObject:[[cur copy] autorelease]]; [cur setString:@""]; } else [cur appendFormat:@"%C", c];
    }
    [parts addObject:cur];
    for (NSString *p in parts) if ([p hasPrefix:[key stringByAppendingString:@"="]]) return [[p substringFromIndex:[key length] + 1] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
    return nil;
}
static NSString *TRAbsURL(NSString *u, NSURL *base) { NSURL *a = [NSURL URLWithString:u relativeToURL:base]; return [[a absoluteURL] absoluteString] ?: u; }
static NSString *TRSanitizeMaster(NSString *text, NSURL *base, int *kept) {
    NSMutableString *out = [NSMutableString stringWithString:@"#EXTM3U\n"];
    NSArray *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSString *pending = nil; int n = 0;
    for (NSString *raw in lines) {
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (![l length] || [l hasPrefix:@"#EXTM3U"]) continue;
        if ([l hasPrefix:@"#EXT-X-STREAM-INF:"]) {
            NSString *attrs = [l substringFromIndex:18];
            NSString *codecs = TRSplitAttr(attrs, @"CODECS") ?: @"";
            NSString *res = TRSplitAttr(attrs, @"RESOLUTION");
            int h = [[[res componentsSeparatedByString:@"x"] lastObject] intValue];
            BOOL ok = [codecs rangeOfString:@"avc1"].location != NSNotFound && [codecs rangeOfString:@"vp09"].location == NSNotFound && [codecs rangeOfString:@"av01"].location == NSNotFound && h <= 1080;
            if (ok) {
                NSMutableString *a = [NSMutableString stringWithFormat:@"BANDWIDTH=%@", TRSplitAttr(attrs, @"BANDWIDTH") ?: @"1000000"];
                if (res) [a appendFormat:@",RESOLUTION=%@", res];
                [a appendFormat:@",CODECS=\"%@\"", codecs];
                NSString *fr = TRSplitAttr(attrs, @"FRAME-RATE"); if (fr) [a appendFormat:@",FRAME-RATE=%@", fr];
                NSString *au = TRSplitAttr(attrs, @"AUDIO"); if (au) [a appendFormat:@",AUDIO=\"%@\"", au];
                pending = [NSString stringWithFormat:@"#EXT-X-STREAM-INF:%@", a];
            } else pending = @"";
            continue;
        }
        if ([l hasPrefix:@"#"]) {
            if ([l hasPrefix:@"#EXT-X-MEDIA:"]) {
                NSString *uri = TRSplitAttr([l substringFromIndex:13], @"URI");
                [out appendFormat:@"%@\n", uri ? [l stringByReplacingOccurrencesOfString:uri withString:TRAbsURL(uri, base)] : l];
            }
            continue; // session data / keys / i-frame lists / independent-segments are dropped
        }
        if (pending) { if ([pending length]) { [out appendFormat:@"%@\n%@\n", pending, TRAbsURL(l, base)]; n++; } pending = nil; }
    }
    if (kept) *kept = n;
    return n ? out : nil;
}
static void TRPrepareLive(NSDictionary *json0, void (^proceed)(NSDictionary *)) {
    NSString *hls = TRDig(json0, @[@"streamingData", @"hlsManifestUrl"]);
    if (!json0 || ![hls length] || ![TRDig(json0, @[@"videoDetails", @"isLive"]) boolValue] || [TRDig(json0, @[@"streamingData", @"formats"]) count]) { proceed(json0); return; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:hls] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    [NSURLConnection sendAsynchronousRequest:r queue:TRBridgeQueue() completionHandler:^(NSURLResponse *resp, NSData *d, NSError *e) {
        NSString *txt = d ? [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] autorelease] : nil;
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        NSLog(@"[TubeReplacer] live: master http=%ld bytes=%lu", (long)code, (unsigned long)[d length]);
        NSLog(@"[TubeReplacer] live: master head: %@", [txt length] > 1800 ? [txt substringToIndex:1800] : txt);
        int kept = 0;
        NSString *clean = txt ? TRSanitizeMaster(txt, [resp URL] ?: [NSURL URLWithString:hls], &kept) : nil;
        NSString *local = clean ? TRServeText(@"m3u8", @"application/vnd.apple.mpegurl", clean) : nil;
        NSLog(@"[TubeReplacer] live: kept %d variant(s) -> %@", kept, local ?: @"(original manifest)");
        if (clean) NSLog(@"[TubeReplacer] live: clean master: %@", [clean length] > 1500 ? [clean substringToIndex:1500] : clean);
        // for the log: what the media playlist looks like (TS or fMP4 segments)
        for (NSString *ln in [clean componentsSeparatedByString:@"\n"]) {
            if (![ln hasPrefix:@"http"]) continue;
            NSMutableURLRequest *mr = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:ln] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
            [NSURLConnection sendAsynchronousRequest:mr queue:TRBridgeQueue() completionHandler:^(NSURLResponse *r2, NSData *d2, NSError *e2) {
                NSString *t2 = d2 ? [[[NSString alloc] initWithData:d2 encoding:NSUTF8StringEncoding] autorelease] : nil;
                NSLog(@"[TubeReplacer] live: media playlist head: %@", [t2 length] > 900 ? [t2 substringToIndex:900] : t2);
            }];
            break;
        }
        NSMutableDictionary *mj = [[json0 mutableCopy] autorelease];
        NSMutableDictionary *sd = [[json0[@"streamingData"] mutableCopy] autorelease];
        if (local) { sd[@"hlsManifestUrl"] = local; [sd removeObjectForKey:@"adaptiveFormats"]; [sd removeObjectForKey:@"dashManifestUrl"]; }
        mj[@"streamingData"] = sd;
        proceed(mj);
    }];
}

// Channel info (avatar etc.) for 2.3.x: the app asks for one channel per video, so share fetches.
void TRFetchChannelJSON(NSString *channelID, void (^cb)(NSDictionary *json)) {
    static NSMutableDictionary *done = nil, *waiting = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ done = [[NSMutableDictionary alloc] init]; waiting = [[NSMutableDictionary alloc] init]; });
    if (![channelID length]) { cb(nil); return; }
    NSDictionary *hit = nil; BOOL start = NO;
    @synchronized (done) {
        hit = done[channelID];
        if (!hit) {
            NSMutableArray *w = waiting[channelID];
            if (!w) { w = [NSMutableArray array]; waiting[channelID] = w; start = YES; }
            [w addObject:[[cb copy] autorelease]];
        }
    }
    if (hit) { cb(hit); return; }
    if (!start) return;
    TRPostInnerTube(@"browse", @{ @"browseId": channelID, @"params": @"EgZzaG9ydHPyBgUKA5oBAA%3D%3D" }, ^(NSDictionary *j, NSInteger code, NSError *err) {
        NSArray *cbs;
        @synchronized (done) {
            if (j) done[channelID] = j;
            cbs = [[waiting[channelID] copy] autorelease];
            [waiting removeObjectForKey:channelID];
        }
        NSLog(@"[TubeReplacer] channel %@: http=%ld %@", channelID, (long)code, j ? @"ok" : @"failed");
        for (void (^c)(NSDictionary *) in cbs) c(j);
    });
}

// ---- captions for the old apps -------------------------------------------------------------
// The timedtext URLs of the player response need a proof-of-origin token these apps cannot make,
// so the caption file would come back empty. The web client's transcript (get_transcript) needs no
// token; it is turned into the "format 3" XML the apps' own parser reads (see captions.x).
static NSMutableDictionary *TRTranscriptParams(void) {
    static NSMutableDictionary *d; static dispatch_once_t once;
    dispatch_once(&once, ^{ d = [[NSMutableDictionary alloc] init]; });
    return d;
}
static void TRCacheTranscriptParamsFrom(NSString *videoID, id json) {
    id ep = TRFindKey(json, @"getTranscriptEndpoint", 0);
    NSString *params = [ep isKindOfClass:[NSDictionary class]] ? ep[@"params"] : nil;
    if ([videoID length]) @synchronized (TRTranscriptParams()) { TRTranscriptParams()[videoID] = params ?: @""; } // "" = looked, none
}
// the player and next requests run side by side: wait (briefly) until /next told whether there is a transcript
static void TRAwaitTranscriptInfo(NSString *videoID, int tries, void (^done)(void)) {
    BOOL seen; @synchronized (TRTranscriptParams()) { seen = TRTranscriptParams()[videoID] != nil; }
    if (seen || tries <= 0) { done(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{ TRAwaitTranscriptInfo(videoID, tries - 1, done); });
}
BOOL TRHasTranscript(NSString *videoID) { @synchronized (TRTranscriptParams()) { return [TRTranscriptParams()[videoID] length] > 0; } }
static void TRCollectAll(id n, NSString *key, NSMutableArray *out, int depth) { // like TRCollectKey, without the 200 cap
    if (depth > 60) return;
    if ([n isKindOfClass:[NSArray class]]) { for (id e in n) TRCollectAll(e, key, out, depth + 1); return; }
    if (![n isKindOfClass:[NSDictionary class]]) return;
    if (n[key]) { [out addObject:n[key]]; return; }
    for (id v in [n allValues]) TRCollectAll(v, key, out, depth + 1);
}
static NSString *TRXMLEscape(NSString *t) {
    t = [t stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    t = [t stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    t = [t stringByReplacingOccurrencesOfString:@">" withString:@"&gt;"];
    return t;
}
void TRFetchTranscriptXML(NSString *videoID, void (^cb)(NSString *xml)) {
    void (^go)(NSString *) = ^(NSString *params) {
        if (![params length]) { cb(nil); return; }
        TRPostInnerTube(@"get_transcript", @{ @"params": params }, ^(NSDictionary *tj, NSInteger tc, NSError *te) {
            NSMutableArray *segs = [NSMutableArray array];
            if (tj) TRCollectAll(tj, @"transcriptSegmentRenderer", segs, 0);
            NSMutableString *xml = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"utf-8\" ?><timedtext format=\"3\"><body>"];
            NSUInteger n = 0;
            for (NSDictionary *sg in segs) {
                if (![sg isKindOfClass:[NSDictionary class]]) continue;
                NSString *text = TRTextOf(sg[@"snippet"]);
                if (![text length]) continue;
                long long st = [sg[@"startMs"] longLongValue], en = [sg[@"endMs"] longLongValue];
                if (en <= st) en = st + 2000;
                [xml appendFormat:@"<p t=\"%lld\" d=\"%lld\">%@</p>", st, en - st, TRXMLEscape(text)];
                n++;
            }
            [xml appendString:@"</body></timedtext>"];
            NSLog(@"[TubeReplacer] transcript %@: http=%ld %lu line(s)", videoID, (long)tc, (unsigned long)n);
            cb(n ? xml : nil);
        });
    };
    NSString *params; @synchronized (TRTranscriptParams()) { params = TRTranscriptParams()[videoID]; }
    if ([params length]) { go(params); return; }
    if (![videoID length]) { cb(nil); return; }
    TRPostInnerTube(@"next", @{ @"videoId": videoID }, ^(NSDictionary *nj, NSInteger nc, NSError *ne) {
        if (nj) TRCacheTranscriptParamsFrom(videoID, nj);
        NSString *p; @synchronized (TRTranscriptParams()) { p = TRTranscriptParams()[videoID]; }
        go(p);
    });
}

static BOOL TRHasVideos(id n, int depth) {
    if (depth > 60) return NO;
    if ([n isKindOfClass:[NSArray class]]) { for (id e in n) if (TRHasVideos(e, depth + 1)) return YES; return NO; }
    if (![n isKindOfClass:[NSDictionary class]]) return NO;
    if (n[@"compactVideoRenderer"] || n[@"videoRenderer"]) return YES;
    for (id v in [n allValues]) if (TRHasVideos(v, depth + 1)) return YES;
    return NO;
}


static NSDictionary *TRLibraryPage(NSDictionary *norm) {
    @try {
        TRWaitIdentity();
        NSData *jd = [NSJSONSerialization dataWithJSONObject:norm options:0 error:nil];
        NSMutableDictionary *mn = jd ? [NSJSONSerialization JSONObjectWithData:jd options:NSJSONReadingMutableContainers error:nil] : nil;
        if (![mn isKindOfClass:[NSMutableDictionary class]]) return norm;
        NSMutableArray *tabs = TRDig(mn, @[@"contents", @"singleColumnBrowseResultsRenderer", @"tabs"]);
        NSMutableDictionary *tab = nil;
        if ([tabs isKindOfClass:[NSMutableArray class]] && [tabs count] && [tabs[0][@"tabRenderer"] isKindOfClass:[NSMutableDictionary class]]) tab = tabs[0][@"tabRenderer"];
        else {
            id sl = TRDig(mn, @[@"contents", @"sectionListRenderer"]);
            if (!sl) { NSMutableArray *f = [NSMutableArray array]; TRCollectKey(mn, @"sectionListRenderer", f, 0); sl = [f count] ? f[0] : nil; }
            if (!sl) return norm;
            tab = [NSMutableDictionary dictionaryWithObjectsAndKeys:@{ @"sectionListRenderer": sl }, @"content", @YES, @"selected", nil];
            mn[@"contents"] = @{ @"singleColumnBrowseResultsRenderer": @{ @"tabs": @[ @{ @"tabRenderer": tab } ] } };
        }
        NSMutableDictionary *hdr = [NSMutableDictionary dictionaryWithObject:TRSimpleText([gTRProfileName length] ? gTRProfileName : @"Library") forKey:@"accountName"];
        if ([gTRProfilePhoto length]) hdr[@"accountPhoto"] = @{ @"thumbnails": @[ @{ @"url": gTRProfilePhoto, @"width": @96, @"height": @96 } ] };
        if ([gTRMyChannel length]) hdr[@"channelEndpoint"] = @{ @"browseEndpoint": @{ @"browseId": gTRMyChannel } };
        tab[@"header"] = @{ @"activeAccountHeaderRenderer": hdr };
        NSDictionary *(^link)(NSString *, int, NSString *) = ^NSDictionary *(NSString *t, int icon, NSString *bid) {
            return @{ @"compactLinkRenderer": @{ @"title": TRSimpleText(t), @"icon": @{ @"iconType": @(icon) },
                @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": bid } } } };
        };
        NSMutableArray *secs = [NSMutableArray array];
        NSMutableArray *lks = [NSMutableArray arrayWithObject:link(@"History", 2, @"FEhistory")];
        if ([gTRMyChannel length]) // the channel's Videos tab
            [lks addObject:@{ @"compactLinkRenderer": @{ @"title": TRSimpleText(@"My videos"), @"icon": @{ @"iconType": @7 },
                @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": gTRMyChannel, @"params": @"EgZ2aWRlb3PyBgQKAjoA" } } } }];
        [lks addObject:link(@"Watch Later", 3, @"VLWL")]; [lks addObject:link(@"Liked videos", 16, @"VLLL")];
        [secs addObject:@{ @"itemSectionRenderer": @{ @"contents": lks } }];
        NSArray *old = TRDig(tab, @[@"content", @"sectionListRenderer", @"contents"]);
        if ([old isKindOfClass:[NSArray class]]) [secs addObjectsFromArray:old];
        tab[@"content"] = @{ @"sectionListRenderer": @{ @"contents": secs } };
        return mn;
    } @catch (NSException *e) { return norm; }
}
static BOOL TRIsHomeFeedId(NSString *b) { return [b isEqualToString:@"FEwhat_to_watch"] || [b isEqualToString:@"FEtrending"]; }

static void TRCountRenderers(id n, NSMutableDictionary *c, int depth) {
    if (depth > 60) return;
    if ([n isKindOfClass:[NSArray class]]) { for (id e in n) TRCountRenderers(e, c, depth + 1); return; }
    if (![n isKindOfClass:[NSDictionary class]]) return;
    for (NSString *k in n) {
        if ([k hasSuffix:@"Renderer"] || [k hasSuffix:@"ViewModel"] || [k isEqualToString:@"continuations"] || [k hasSuffix:@"Endpoint"])
            c[k] = @([c[k] intValue] + 1);
        TRCountRenderers(n[k], c, depth + 1);
    }
}
static NSString *TRRendererSummary(id n) {
    NSMutableDictionary *c = [NSMutableDictionary dictionary];
    TRCountRenderers(n, c, 0);
    NSMutableArray *p = [NSMutableArray array];
    for (NSString *k in [c keysSortedByValueUsingComparator:^NSComparisonResult(id a, id b) { return [b compare:a]; }]) {
        if ([p count] >= 24) break;
        [p addObject:[NSString stringWithFormat:@"%@=%@", k, c[k]]];
    }
    return [p componentsJoinedByString:@" "];
}

// 2.3.x routes navigation through mobileV2 channel/playlist/feed endpoints (its router has no
// browseEndpoint handler, so browse taps end in "unable to perform action"). Rewrite them.
static BOOL TRNeedsMobileV2Nav(void) {
    static int c = -1;
    if (c < 0) c = (NSClassFromString(@"YTPBActivityListResponse") != nil) ? 1 : 0;
    return c == 1;
}
static id TRConvertNav(id n) {
    if ([n isKindOfClass:[NSArray class]]) {
        NSMutableArray *o = [NSMutableArray arrayWithCapacity:[n count]];
        for (id e in n) [o addObject:TRConvertNav(e)];
        return o;
    }
    if (![n isKindOfClass:[NSDictionary class]]) return n;
    NSDictionary *be = n[@"browseEndpoint"];
    NSMutableDictionary *o = [NSMutableDictionary dictionaryWithCapacity:[n count] + 1];
    for (NSString *k in n) o[k] = TRConvertNav(n[k]);
    if ([be isKindOfClass:[NSDictionary class]] && [be[@"browseId"] isKindOfClass:[NSString class]]) {
        NSString *b = be[@"browseId"];
        NSDictionary *rep = nil;
        if ([b hasPrefix:@"UC"] && [b length] > 10) rep = @{ @"mobileV2ChannelEndpoint": @{ @"channelId": b } };
        else if ([b isEqualToString:@"VLWL"]) rep = @{ @"mobileV2UserFeedEndpoint": @{ @"feedName": @"watch_later" } };
        else if ([b isEqualToString:@"VLLL"]) rep = @{ @"mobileV2UserFeedEndpoint": @{ @"feedName": @"favorites" } };
        else if ([b hasPrefix:@"VL"] && [b length] > 4) rep = @{ @"mobileV2PlaylistEndpoint": @{ @"playlistId": [b substringFromIndex:2] } };
        else {
            NSDictionary *feeds = @{ @"FEwhat_to_watch": @"what_to_watch", @"FEtrending": @"popular", @"FEsubscriptions": @"subscriptions",
                                     @"FEhistory": @"history", @"FElibrary": @"playlists" };
            if (feeds[b]) rep = @{ @"mobileV2UserFeedEndpoint": @{ @"feedName": feeds[b] } };
        }
        if (rep) { [o removeObjectForKey:@"browseEndpoint"]; [o addEntriesFromDictionary:rep]; }
    }
    return o;
}

static id TRParseJSONInto(NSDictionary *json, Class respClass, id parser, NSString *tag, NSError **error) {
    if (TRNeedsMobileV2Nav()) json = TRConvertNav(json);
    BOOL raw = (parser == nil); // no parser given: the caller parses the bytes itself (10.x InnerTube services)
    TRStats *st = [[[TRStats alloc] init] autorelease];
    NSMutableData *bytes = [NSMutableData data];
    TREncodeMessage(json, respClass, bytes, st, 0);
    NSArray *top = [[st->unknown keysSortedByValueUsingComparator:^NSComparisonResult(id a, id b) { return [b compare:a]; }]
                    subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)10, [st->unknown count]))];
    NSLog(@"[TubeReplacer] bridge %@: %lu field(s) set, %lu unknown key(s) dropped (top: %@) -> %lu proto bytes as %@",
          tag, (unsigned long)st->fieldsSet, (unsigned long)[st->unknown count], [top componentsJoinedByString:@","],
          (unsigned long)[bytes length], NSStringFromClass(respClass));
    @try {
        NSLog(@"[TubeReplacer] bridge %@: in : %@", tag, TRRendererSummary(json));
        NSLog(@"[TubeReplacer] bridge %@: out: %@", tag, TRRendererSummary(TRDecodeMessage(bytes, respClass, 0)));
    } @catch (NSException *e) {}
    id result = nil;
    if (raw) return [NSData dataWithData:bytes];
    @try {
        result = [parser performSelector:@selector(parse:) withObject:bytes];
    } @catch (NSException *e) {
        NSLog(@"[TubeReplacer] bridge %@: parse threw %@", tag, e);
    }
    if (!result && error) *error = TRError(301, @"The response could not be understood.");
    @try { NSString *ds = [result description]; NSLog(@"[TubeReplacer] bridge %@: parsed %@: %@", tag, NSStringFromClass([result class]), [ds length] > 700 ? [ds substringToIndex:700] : ds); } @catch (NSException *e) {}
    return result;
}

// Do the whole round trip; completion is called on a background queue.

// ---- signed-out home feed: the curated "trending" playlist (same one the upstream tweak uses) ----
static NSMutableSet *gTRFeedTokens = nil;   // continuation tokens that belong to that playlist
static NSString *TRTrendingBrowseId(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/dev.preloading.tubereplacer.preferences.plist"];
    NSString *b = [prefs[@"TrendingBrowseId"] isKindOfClass:[NSString class]] ? prefs[@"TrendingBrowseId"] : nil;
    return [b length] ? b : @"VLPLbgMm37FwiYk";
}
static NSDictionary *TRVideoRendererFromPlaylistItem(NSDictionary *pv) {
    if (![pv isKindOfClass:[NSDictionary class]] || ![pv[@"videoId"] length]) return nil;
    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    v[@"videoId"] = pv[@"videoId"];
    if (pv[@"title"]) v[@"title"] = pv[@"title"];
    if (pv[@"thumbnail"]) v[@"thumbnail"] = pv[@"thumbnail"];
    if (pv[@"shortBylineText"]) { v[@"ownerText"] = pv[@"shortBylineText"]; v[@"longBylineText"] = pv[@"shortBylineText"]; }
    if (pv[@"lengthText"]) v[@"lengthText"] = pv[@"lengthText"];
    if (pv[@"navigationEndpoint"]) v[@"navigationEndpoint"] = pv[@"navigationEndpoint"];
    NSArray *info = TRDig(pv, @[@"videoInfo", @"runs"]);
    if ([info isKindOfClass:[NSArray class]]) {
        if ([info count] > 0) v[@"viewCountText"] = @{ @"simpleText": info[0][@"text"] ?: @"" };
        if ([info count] > 2) v[@"publishedTimeText"] = @{ @"simpleText": info[2][@"text"] ?: @"" };
    }
    return @{ @"videoRenderer": v };
}
// Items of a playlist page / continuation -> web search-style items (+ the next token).
static NSArray *TRFeedItemsFromPlaylistItems(NSArray *items) {
    NSMutableArray *out = [NSMutableArray array];
    for (id it in items) {
        NSString *tk = TRContinuationToken(it);
        if (tk) {
            @synchronized (gTRFeedTokens ?: (gTRFeedTokens = [[NSMutableSet alloc] init])) { [gTRFeedTokens addObject:tk]; }
            [out addObject:it]; continue;
        }
        NSDictionary *v = TRVideoRendererFromPlaylistItem(it[@"playlistVideoRenderer"]);
        if (v) [out addObject:v];
    }
    return out;
}
static void TRCollectPlaylistItems(id n, NSMutableArray *out, int depth) {
    if (depth > 30 || [out count] > 300) return;
    if ([n isKindOfClass:[NSArray class]]) { for (id e in n) TRCollectPlaylistItems(e, out, depth + 1); return; }
    if (![n isKindOfClass:[NSDictionary class]]) return;
    if (n[@"playlistVideoRenderer"] || n[@"continuationItemRenderer"]) { [out addObject:n]; return; }
    for (id v in [n allValues]) TRCollectPlaylistItems(v, out, depth + 1);
}
static NSDictionary *TRFeedFromPlaylistJSON(NSDictionary *pj) {
    NSMutableArray *found = [NSMutableArray array];
    TRCollectPlaylistItems(pj[@"contents"] ?: pj, found, 0);
    NSLog(@"[TubeReplacer] trending playlist: %lu item(s); %@", (unsigned long)[found count], TRRendererSummary(pj));
    if (![found count]) return nil;
    NSArray *conv = TRFeedItemsFromPlaylistItems(found);
    return @{ @"contents": @{ @"twoColumnSearchResultsRenderer": @{ @"primaryContents": @{ @"sectionListRenderer": @{
        @"contents": @[ @{ @"itemSectionRenderer": @{ @"contents": conv } } ] } } } } };
}
static NSDictionary *TRFeedContinuationFromPlaylist(NSDictionary *pj) {
    NSArray *cmds = pj[@"onResponseReceivedActions"] ?: pj[@"onResponseReceivedCommands"];
    NSMutableArray *outCmds = [NSMutableArray array];
    for (NSDictionary *c in ([cmds isKindOfClass:[NSArray class]] ? cmds : @[])) {
        NSArray *items = TRDig(c, @[@"appendContinuationItemsAction", @"continuationItems"]);
        if (![items isKindOfClass:[NSArray class]]) continue;
        [outCmds addObject:@{ @"appendContinuationItemsAction": @{ @"continuationItems": TRFeedItemsFromPlaylistItems(items) } }];
    }
    return [outCmds count] ? @{ @"onResponseReceivedActions": outCmds } : pj;
}



// ---- Trending tab: the old curated playlist is down to a single video, so build the feed from search ----
// "New videos with 1M+ views": search sorted by view count, uploaded this week (then this month if that is too
// thin), keep only videos whose view count text is >= 1,000,000. A custom TrendingBrowseId set in the settings
// is still honoured; only the old default (or none) switches to this.
static const double kTRTrendingMinViews = 1000000.0;
static BOOL TRTrendingIsAuto(void) {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/dev.preloading.tubereplacer.preferences.plist"];
    NSString *b = [prefs[@"TrendingBrowseId"] isKindOfClass:[NSString class]] ? prefs[@"TrendingBrowseId"] : nil;
    return ![b length] || [b isEqualToString:@"VLPLbgMm37FwiYk"];
}
// "1.2M views" / "345K views" / "2,345,678 views" / "1.2 million views" -> number (0 when unknown)
static double TRParseViewCount(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || ![text length]) return 0;
    NSString *t = [[text lowercaseString] stringByReplacingOccurrencesOfString:@"," withString:@""];
    NSScanner *sc = [NSScanner scannerWithString:t];
    [sc scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
    double n = 0;
    if (![sc scanDouble:&n]) return 0;
    NSString *rest = [[t substringFromIndex:[sc scanLocation]] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([rest hasPrefix:@"k"]) n *= 1e3;
    else if ([rest hasPrefix:@"m"]) n *= 1e6;
    else if ([rest hasPrefix:@"b"]) n *= 1e9;
    return n;
}
static void TRSearchMany(NSArray *queries, NSString *params, void (^done)(NSArray *renderers)) {
    NSMutableArray *all = [NSMutableArray array];
    __block NSUInteger remaining = [queries count];
    if (!remaining) { done(@[]); return; }
    for (NSString *q in queries) {
        TRPostInnerTube(@"search", @{ @"query": q, @"params": params }, ^(NSDictionary *sj, NSInteger sc, NSError *se) {
            NSMutableArray *found = [NSMutableArray array];
            if (sj && sc < 400) { @try { TRCollectAll(sj, @"videoRenderer", found, 0); } @catch (NSException *e) {} }
            NSArray *finished = nil;
            @synchronized (all) {
                [all addObjectsFromArray:found];
                if (--remaining == 0) finished = [NSArray arrayWithArray:all];
            }
            if (finished) done(finished);
        });
    }
}
// keep unseen videos with >= minViews, most viewed first; adds their ids to `seen`
static NSArray *TRPickPopular(NSArray *renderers, NSMutableSet *seen, double minViews) {
    NSMutableArray *kept = [NSMutableArray array];
    for (id r in renderers) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        NSString *vid = r[@"videoId"];
        if (![vid length] || [seen containsObject:vid]) continue;
        double views = TRParseViewCount(TRTextOf(r[@"viewCountText"]));
        if (views < minViews) continue;
        [seen addObject:vid];
        [kept addObject:@[ @(views), r ]];
    }
    [kept sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [b[0] compare:a[0]];
    }];
    NSMutableArray *out = [NSMutableArray array];
    for (NSArray *k in kept) [out addObject:@{ @"videoRenderer": k[1] }];
    return out;
}
static void TRTrendingFromSearch(void (^done)(NSArray *items)) {
    NSArray *queries = @[ @"official video", @"trailer", @"highlights", @"gameplay", @"news" ];
    TRSearchMany(queries, @"CAMSBAgDEAE=" /* most viewed, this week, videos */, ^(NSArray *week) {
        NSMutableSet *seen = [NSMutableSet set];
        NSArray *picked = TRPickPopular(week, seen, kTRTrendingMinViews);
        NSLog(@"[TubeReplacer] trending: %lu video(s) >= 1M views this week", (unsigned long)[picked count]);
        if ([picked count] >= 15) { done(picked); return; }
        TRSearchMany(queries, @"CAMSBAgEEAE=" /* most viewed, this month, videos */, ^(NSArray *month) {
            NSMutableArray *merged = [NSMutableArray arrayWithArray:picked];
            [merged addObjectsFromArray:TRPickPopular(month, seen, kTRTrendingMinViews)];
            NSLog(@"[TubeReplacer] trending: %lu video(s) after adding this month", (unsigned long)[merged count]);
            done(merged);
        });
    });
}

// The web's share panel has no counterpart in the apps, so share with the system sheet: close the
// (empty) panel the app opens and present a UIActivityViewController with the video link instead.
static UIViewController *TRTopVC(void) {
    UIWindow *w = [[UIApplication sharedApplication] keyWindow];
    UIViewController *vc = [w rootViewController];
    while ([vc presentedViewController]) vc = [vc presentedViewController];
    return vc;
}
static void TRPresentSystemShare(NSString *vid) {
    if (![vid length]) return;
    NSURL *url = [NSURL URLWithString:[@"https://youtu.be/" stringByAppendingString:vid]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            UIViewController *top = TRTopVC();
            NSString *cn = NSStringFromClass([top class]);
            NSLog(@"[TubeReplacer] share: top controller %@", cn);
            void (^present)(UIViewController *) = ^(UIViewController *host) {
                UIActivityViewController *av = [[[UIActivityViewController alloc] initWithActivityItems:@[ url ] applicationActivities:nil] autorelease];
                if ([av respondsToSelector:@selector(popoverPresentationController)] && [av popoverPresentationController]) {
                    [[av popoverPresentationController] setSourceView:[host view]];
                    CGRect b = [[host view] bounds];
                    [[av popoverPresentationController] setSourceRect:CGRectMake(CGRectGetMidX(b), CGRectGetMidY(b), 1, 1)];
                }
                [host presentViewController:av animated:YES completion:nil];
            };
            if ([cn rangeOfString:@"Share" options:NSCaseInsensitiveSearch].location != NSNotFound && [top presentingViewController]) {
                UIViewController *host = [top presentingViewController];
                [host dismissViewControllerAnimated:NO completion:^{ present(host); }];
            } else present(top);
        } @catch (NSException *e) { NSLog(@"[TubeReplacer] share: %@", e); }
    });
}


// Upload creation: the web InnerTube answers upload/create with 501, so emulate what YouTube Studio does (studio.youtube.com).
static NSMutableDictionary *gTRUploadVideos = nil; // frontendUploadId -> videoId
static void TRPostStudio(NSString *endpoint, NSDictionary *body, void (^cb)(NSDictionary *json, NSInteger code, NSError *err)) {
    NSMutableDictionary *full = [NSMutableDictionary dictionaryWithObject:@{ @"client": @{ @"clientName": @"62", @"clientVersion": @"1.20240820.01.00", @"hl": @"en", @"gl": @"US" } } forKey:@"context"];
    [full addEntriesFromDictionary:body];
    NSString *u = [NSString stringWithFormat:@"https://studio.youtube.com/youtubei/v1/%@?alt=json&key=AIzaSyBUPetSUmoZL-OhlxA7wSac5XinrygCqMo", endpoint];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:40.0];
    [req setHTTPMethod:@"POST"];
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:full options:0 error:nil]];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"https://studio.youtube.com" forHTTPHeaderField:@"Origin"];
    [req setValue:@"https://studio.youtube.com" forHTTPHeaderField:@"X-Origin"];
    [req setValue:@"https://studio.youtube.com/" forHTTPHeaderField:@"Referer"];
    [req setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
    BOOL signedIn = TRAuthorizeRequest(req);
    [req setValue:@"https://studio.youtube.com" forHTTPHeaderField:@"Origin"];
    NSLog(@"[TubeReplacer] studio %@: %@ body=%@", endpoint, signedIn ? @"signed in" : @"anonymous", body);
    [NSURLConnection sendAsynchronousRequest:req queue:TRBridgeQueue() completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSLog(@"[TubeReplacer] studio %@: http=%ld bytes=%lu reply=%@", endpoint, (long)code, (unsigned long)[data length], [json isKindOfClass:[NSDictionary class]] ? [json description] : [[[NSString alloc] initWithData:data ?: [NSData data] encoding:NSUTF8StringEncoding] autorelease]);
        cb([json isKindOfClass:[NSDictionary class]] ? json : nil, code, err);
    }];
}
static NSString *TRStr(id v) { if ([v isKindOfClass:[NSString class]]) return v; if ([v isKindOfClass:[NSDictionary class]]) { id t = v[@"newTitle"] ?: v[@"newDescription"] ?: v[@"text"]; if ([t isKindOfClass:[NSString class]]) return t; } return nil; }
static void TRBridgeRun(id service, NSURLRequest *httpReq, id parser, NSString *endpoint, void (^completion)(id result, NSError *error)) {
    if (![endpoint isEqualToString:@"guide"]) TRRefreshSubs();
    Class respClass = parser ? TRProtoClassOfParser(parser) : TRResponseClassFor(service, endpoint);
    if (!respClass) { completion(nil, TRError(300, @"No response class.")); return; }

    // Decode the app's request message into a JSON dictionary.
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    Class reqClass = TRRequestClassFor(service, endpoint);
    NSData *reqBytes = [httpReq HTTPBody];
    if (reqClass && [reqBytes length]) {
        @try { [body addEntriesFromDictionary:TRDecodeMessage(reqBytes, reqClass, 0)]; }
        @catch (NSException *e) { NSLog(@"[TubeReplacer] bridge %@: request decode failed: %@", endpoint, e); }
    }
    if ([endpoint isEqualToString:@"browse"] && [body[@"browseId"] isEqualToString:@"FEtrending"] && !TRTrendingIsAuto())
        body[@"browseId"] = @"FEwhat_to_watch"; // FEtrending is gone (HTTP 400); closest live equivalent (auto mode builds Trending from search below)
    [body removeObjectForKey:@"context"]; // the old client context is meaningless to today's server
    if ([endpoint hasPrefix:@"upload/"] || [endpoint hasPrefix:@"video_manager/"]) NSLog(@"[TubeReplacer] bridge %@: app body %@", endpoint, body);
    if ([endpoint isEqualToString:@"upload/create"]) {
        TRWaitIdentity();
        NSString *sid = TRDig(body, @[@"resourceId", @"scottyResourceId", @"idP"]) ?: TRDig(body, @[@"resourceId", @"scottyResourceId", @"id"]);
        NSString *fid = body[@"frontendUploadId"] ?: @"";
        NSMutableDictionary *sb = [NSMutableDictionary dictionary];
        if ([gTRMyChannel length]) sb[@"channelId"] = gTRMyChannel;
        if ([sid length]) sb[@"resourceId"] = @{ @"scottyResourceId": @{ @"id": sid } };
        if ([fid length]) sb[@"frontendUploadId"] = fid;
        sb[@"initialMetadata"] = @{ @"title": @{ @"newTitle": @"New video" }, @"description": @{ @"newDescription": @"" }, @"privacy": @{ @"newPrivacy": @"PRIVATE" }, @"draftState": @{ @"isMultiplexDraft": @NO } };
        TRPostStudio(@"upload/createvideo", sb, ^(NSDictionary *wj, NSInteger wc, NSError *we) {
            NSString *vid = wj[@"videoId"] ?: TRFindKey(wj, @"videoId", 0);
            if (![vid isKindOfClass:[NSString class]] || ![vid length] || wc >= 400) { completion(nil, we ?: TRError(320, @"Could not create the video.")); return; }
            @synchronized ([NSNumber class]) { if (!gTRUploadVideos) gTRUploadVideos = [[NSMutableDictionary alloc] init]; if ([fid length]) gTRUploadVideos[fid] = vid; gTRUploadVideos[@"last"] = vid; }
            NSDictionary *idd = @{ @"frontendUploadId": fid, @"videoId": vid };
            NSDictionary *out = @{ @"contents": @[ @{ @"uploadFeedbackItem": @{ @"id": idd, @"id_p": idd, @"idP": idd } } ] };
            NSError *pe = nil; id res = TRParseJSONInto(out, respClass, parser, endpoint, &pe);
            NSLog(@"[TubeReplacer] bridge upload/create: video %@ parse=%@ err=%@", vid, res ? @"ok" : @"nil", pe);
            completion(res, pe);
        });
        return;
    }
    if ([endpoint isEqualToString:@"video_manager/metadata_update"]) {
        NSString *vid = body[@"encryptedVideoId"];
        if (![vid length]) @synchronized ([NSNumber class]) { vid = gTRUploadVideos[@"last"]; }
        NSMutableDictionary *sb = [NSMutableDictionary dictionaryWithObject:vid ?: @"" forKey:@"encryptedVideoId"];
        NSString *t = TRStr(body[@"title"]); NSString *d = TRStr(body[@"description_p"]) ?: TRStr(body[@"description"]);
        if (t) sb[@"title"] = @{ @"newTitle": t };
        if (d) sb[@"description"] = @{ @"newDescription": d };
        sb[@"privacy"] = @{ @"newPrivacy": @"PRIVATE" };
        sb[@"tags"] = @{ @"newTags": body[@"tags"] ?: @[] , @"operation": @"UPDATE_TAGS_OPERATION_REPLACE" };
        TRPostStudio(@"video_manager/metadata_update", sb, ^(NSDictionary *wj, NSInteger wc, NSError *we) {
            NSDictionary *out = @{ @"overallResult": @{ @"resultCode": @(wc < 400 ? 1 : 2) } };
            NSError *pe = nil; id res = TRParseJSONInto(out, respClass, parser, endpoint, &pe);
            completion(res, pe);
        });
        return;
    }
    if ([endpoint isEqualToString:@"browse"] && [body[@"browseId"] isEqualToString:@"FEmy_videos"]) {
        // the upload / "my videos" page of the old app: the web has no such browse id (HTTP 400), use the channel's Videos tab
        TRWaitIdentity();
        if ([gTRMyChannel length]) { body[@"browseId"] = gTRMyChannel; body[@"params"] = @"EgZ2aWRlb3PyBgQKAjoA"; NSLog(@"[TubeReplacer] bridge: FEmy_videos -> own channel videos"); }
    }
    if ([endpoint hasPrefix:@"share/"]) {
        NSLog(@"[TubeReplacer] bridge %@ (%@): app body %@", endpoint, NSStringFromClass(respClass), body);
        NSString *svid = body[@"videoId"] ?: TRDig(body, @[@"target", @"videoId"]) ?: TRDig(body, @[@"serializedSharedEntity"]);
        if (![body[@"serializedSharedEntity"] length] && [svid length] < 100 && [svid length]) {
            NSMutableData *pb = [NSMutableData data]; uint8_t hdr[2] = { 0x0a, (uint8_t)[svid length] };
            [pb appendBytes:hdr length:2]; [pb appendData:[svid dataUsingEncoding:NSUTF8StringEncoding]];
            body[@"serializedSharedEntity"] = [pb base64EncodedString];
            body[@"commands"] = @[ @{ @"clickTrackingParams": @"", @"copyLinkCommand": @{} } ];
        }
        NSString *sent = body[@"serializedSharedEntity"];
        NSString *pvid = nil;
        { NSString *e2 = [sent stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: sent;
          e2 = [[e2 stringByReplacingOccurrencesOfString:@"-" withString:@"+"] stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
          while ([e2 length] % 4) e2 = [e2 stringByAppendingString:@"="];
          NSData *d2 = [[NSData dataWithBase64EncodedString:e2] retain];
          if ([d2 length] > 2) { const uint8_t *b2 = [d2 bytes]; if (b2[0] == 0x0a && (NSUInteger)b2[1] + 2 <= [d2 length]) pvid = [[[NSString alloc] initWithBytes:b2 + 2 length:b2[1] encoding:NSUTF8StringEncoding] autorelease]; }
          [d2 release]; }
        if ([pvid length]) {
            TRPresentSystemShare(pvid);
            id empty = nil;
            if (!parser) empty = [NSData data];
            else @try { empty = [parser performSelector:@selector(parse:) withObject:[NSData data]]; } @catch (NSException *e) {}
            completion(empty, empty ? nil : TRError(306, @"Unsupported request."));
            return;
        }
    }

    if ([endpoint hasPrefix:@"comment/"] || [endpoint hasPrefix:@"comments/"] || [NSStringFromClass(respClass) hasPrefix:@"YTIComment"] || [NSStringFromClass(respClass) hasPrefix:@"YTICreateComment"]) {
        NSString *cls = NSStringFromClass(respClass);
        NSLog(@"[TubeReplacer] bridge comment endpoint %@ (%@): %@", endpoint, cls, body);
        // replies of a comment: the app sends the reply token as `continuation`
        if ([cls isEqualToString:@"YTICommentRepliesResponse"] && [body[@"continuation"] length]) {
            TRPostInnerTube(@"next", @{ @"continuation": body[@"continuation"] }, ^(NSDictionary *rj, NSInteger rc, NSError *re) {
                NSMutableArray *list = [NSMutableArray array];
                NSString *next = nil;
                NSArray *cmds = rj[@"onResponseReceivedEndpoints"] ?: rj[@"onResponseReceivedCommands"] ?: rj[@"onResponseReceivedActions"];
                for (NSDictionary *c in ([cmds isKindOfClass:[NSArray class]] ? cmds : @[])) {
                    NSArray *items = TRDig(c, @[@"appendContinuationItemsAction", @"continuationItems"]) ?: TRDig(c, @[@"reloadContinuationItemsCommand", @"continuationItems"]);
                    for (id it in ([items isKindOfClass:[NSArray class]] ? items : @[])) {
                        NSString *tk = TRContinuationToken(it);
                        if (tk) { next = tk; continue; }
                        NSMutableDictionary *cr = TRCommentRendererFrom(it, rj, NULL, NULL);
                        if (cr) { cr[@"avatarSize"] = @2; cr[@"isTopLevelComment"] = @NO; [list addObject:@{ @"commentRenderer": cr }]; }
                    }
                }
                NSLog(@"[TubeReplacer] bridge replies: http=%ld replies=%lu", (long)rc, (unsigned long)[list count]);
                NSMutableDictionary *rr = [NSMutableDictionary dictionaryWithObject:list forKey:@"contents"];
                if (next) rr[@"continuations"] = TRContinuations(next);
                NSError *pe = nil;
                id res = TRParseJSONInto(@{ @"contents": @{ @"commentRepliesRenderer": rr } }, respClass, parser, endpoint, &pe);
                completion(res, pe);
            });
            return;
        }
        // writes (new comment / reply / vote): replay on the web, answer with the comment as it now exists
        NSMutableDictionary *wb = [body mutableCopy];
        NSString *text = body[@"commentText"];
        NSString *webEndpoint = endpoint;
        TRPostInnerTube(webEndpoint, wb, ^(NSDictionary *wj, NSInteger wc, NSError *we) {
            NSLog(@"[TubeReplacer] bridge %@: http=%ld err=%@ keys=%@", endpoint, (long)wc, we, [wj allKeys]);
            if (!wj || wc >= 400) { completion(nil, we ?: TRError(308, @"Could not post the comment.")); return; }
            NSMutableDictionary *real = nil;
            id vmv = TRFindKey(wj, @"commentViewModel", 0);
            if ([vmv isKindOfClass:[NSDictionary class]]) real = TRCommentRendererFrom(@{ @"commentViewModel": vmv }, wj, NULL, NULL);
            NSLog(@"[TubeReplacer] bridge %@: server comment entity %@", endpoint, real ? @"found" : @"missing");
            NSString *newId = nil;
            id idv = TRFindKey(wj, @"commentId", 0);
            if ([idv isKindOfClass:[NSString class]]) newId = idv;
            NSDictionary *prm = TRAccountParams();
            NSMutableDictionary *cr = [NSMutableDictionary dictionary];
            if ([newId length]) cr[@"commentId"] = newId;
            if ([text length]) cr[@"contentText"] = TRSimpleText(text);
            cr[@"authorText"] = TRSimpleText(prm[@"fullName"] ?: prm[@"userEmail"] ?: @"You");
            NSString *myPh = [gTRProfilePhoto length] ? gTRProfilePhoto : prm[@"avatar"];
            if ([myPh length]) cr[@"authorThumbnail"] = @{ @"thumbnails": @[ @{ @"url": myPh, @"width": @48, @"height": @48 } ] };
            cr[@"publishedTimeText"] = TRSimpleText(@"Just now");
            cr[@"isLiked"] = @NO; cr[@"likeCount"] = @0; cr[@"voteStatus"] = @2;
            cr[@"actionButtons"] = @{ @"commentActionButtonsRenderer": @{ @"likeButton": TRCommentToggle(16, @""), @"dislikeButton": TRCommentToggle(51, @"Dislike"),
                                                                             @"replyButton": @{ @"buttonRenderer": @{ @"text": TRSimpleText(@"Reply") } } } };
            if (real) cr = real;
            NSDictionary *out;
            if ([cls isEqualToString:@"YTICreateCommentReplyResponse"]) out = @{ @"contents": @{ @"commentRenderer": cr } };
            else if ([cls isEqualToString:@"YTICreateCommentResponse"]) out = @{ @"contents": @{ @"commentThreadRenderer": @{ @"comment": @{ @"commentRenderer": cr } } } };
            else out = @{};
            NSError *pe = nil;
            id res = TRParseJSONInto(out, respClass, parser, endpoint, &pe);
            completion(res, pe);
        });
        return;
    }

    if ([endpoint isEqualToString:@"player"]) {
        NSString *videoID = body[@"videoId"];
        if (![videoID length]) { completion(nil, TRError(302, @"No video id.")); return; }
        TRFetchPlayerJSON(videoID, ^(NSDictionary *json00, NSString *failure) {
            if (!json00) { completion(nil, TRError(303, failure ?: @"No playable stream.")); return; }
            TRPrepareLive(json00, ^(NSDictionary *json0) {
            @try { TRReportWatch(videoID, @([[TRDig(json0, @[@"videoDetails", @"lengthSeconds"]) description] intValue]), json0); } @catch (NSException *wex) {}
            // HD (2.3+ ... 13.x): add separate video/audio streams that play, the app merges them; muxed 360p stays as the fallback
            TRFetchHDFormatsJSON(videoID, json0, ^(NSArray *adaptive, NSString *hls) {
            NSDictionary *json = json0;
            if ([adaptive count] && [adaptive[0][@"muxed"] boolValue] && [TRDig(json0, @[@"streamingData", @"formats"]) count]) {
                NSMutableDictionary *mj = [[json0 mutableCopy] autorelease];
                NSMutableDictionary *sd = [[json0[@"streamingData"] mutableCopy] autorelease];
                NSMutableArray *fm = [NSMutableArray arrayWithArray:sd[@"formats"]];
                NSUInteger at = 0;
                for (NSDictionary *a0 in adaptive) { NSMutableDictionary *mf = [NSMutableDictionary dictionaryWithDictionary:a0]; [mf removeObjectForKey:@"muxed"]; [fm insertObject:mf atIndex:at++]; }
                sd[@"formats"] = fm;
                mj[@"streamingData"] = sd;
                json = mj;
                NSLog(@"[TubeReplacer] bridge player: HD for %@: %lu muxed HD format(s)", videoID, (unsigned long)[adaptive count]);
            } else if ([adaptive count] && [TRDig(json0, @[@"streamingData", @"formats"]) count]) {
                NSMutableDictionary *mj = [[json0 mutableCopy] autorelease];
                NSMutableDictionary *sd = [[json0[@"streamingData"] mutableCopy] autorelease];
                sd[@"adaptiveFormats"] = adaptive;
                if (TRHDOnlyMode()) [sd removeObjectForKey:@"formats"]; // explicit HD quality: HD streams only
                mj[@"streamingData"] = sd;
                json = mj;
                NSLog(@"[TubeReplacer] bridge player: HD for %@: %lu adaptive streams", videoID, (unsigned long)[adaptive count]);
            } else if ([hls length] && [TRDig(json0, @[@"streamingData", @"formats"]) count]) {
                NSMutableDictionary *mj = [[json0 mutableCopy] autorelease];
                NSMutableDictionary *sd = [[json0[@"streamingData"] mutableCopy] autorelease];
                sd[@"hlsManifestUrl"] = hls;
                [sd removeObjectForKey:@"formats"]; // the apps take a listed muxed 360p stream before the HLS one
                mj[@"streamingData"] = sd;
                json = mj;
                NSLog(@"[TubeReplacer] bridge player: HD for %@ via HLS", videoID);
            }
            {
                NSDictionary *sdl = [json[@"streamingData"] isKindOfClass:[NSDictionary class]] ? json[@"streamingData"] : @{};
                NSLog(@"[TubeReplacer] bridge player: streamingData for %@: formats=%lu adaptive=%lu hls=%@ dash=%@ live=%d", videoID,
                      (unsigned long)[sdl[@"formats"] count], (unsigned long)[sdl[@"adaptiveFormats"] count],
                      [sdl[@"hlsManifestUrl"] length] ? @"yes" : @"no", [sdl[@"dashManifestUrl"] length] ? @"yes" : @"no",
                      TRDig(json, @[@"videoDetails", @"isLive"]) ? 1 : 0);
            }
            // captions.x answers the app's track requests from this cache. The plain-URL
            // clients (android/ios) hand out no caption list, so ask the web client for it.
            void (^finishNow)(NSDictionary *) = ^(NSDictionary *pj) {
                NSDictionary *outJSON = pj;
                // the apps that read the track list from the player response (10.x: ...TrackListRenderer, 11.x+: ...TracklistRenderer)
                Class ctl = NSClassFromString(@"YTIPlayerCaptionsTracklistRenderer") ?: NSClassFromString(@"YTIPlayerCaptionsTrackListRenderer");
                BOOL native = ctl != nil &&
                              NSClassFromString(@"YTICaptionService") == nil && NSClassFromString(@"YTCaptionService") != nil &&
                              ([NSClassFromString(@"YTCaptionTrack") instancesRespondToSelector:NSSelectorFromString(@"initWithLanguageCode:trackName:VSSID:URL:trackType:")] ||
                               [NSClassFromString(@"YTCaptionTrack") instancesRespondToSelector:NSSelectorFromString(@"initWithID:languageCode:languageName:trackName:VSSID:URL:trackDisplayName:trackType:")]);
                if (!TRHasCaptionTracks(videoID) && TRHasTranscript(videoID)) {
                    // no usable track list: offer the transcript as a single track
                    TRCacheCaptionTracks(videoID, @[ @{ @"baseUrl": @"https://www.youtube.com/api/timedtext?tr=1", @"languageCode": @"en", @"name": @{ @"simpleText": @"Captions" }, @"vssId": @".en" } ]);
                }
                if (TRHasCaptionTracks(videoID) && !native) {
                    // older apps expect captions.playerCaptionsRenderer.baseUrl (the old timedtext "list" URL)
                    NSMutableDictionary *mj = [[pj mutableCopy] autorelease];
                    mj[@"captions"] = @{ @"playerCaptionsRenderer": @{ @"baseUrl": TRCaptionBaseURL(videoID) ?: @"" } };
                    outJSON = mj;
                } else if (native && TRHasCaptionTracks(videoID)) {
                    NSMutableDictionary *mj = [[pj mutableCopy] autorelease];
                    // keep the player's own list (audio tracks, default audio track, translation languages decide whether captions show up) and swap the URLs
                    NSDictionary *origTl = TRDig(json, @[@"captions", @"playerCaptionsTracklistRenderer"]) ?: TRDig(pj, @[@"captions", @"playerCaptionsTracklistRenderer"]);
                    NSMutableDictionary *tl = [NSMutableDictionary dictionaryWithDictionary:[origTl isKindOfClass:[NSDictionary class]] ? origTl : @{}];
                    tl[@"captionTracks"] = TRCaptionTrackJSON(videoID, [origTl isKindOfClass:[NSDictionary class]] ? origTl[@"captionTracks"] : nil);
                    mj[@"captions"] = @{ @"playerCaptionsTracklistRenderer": tl };
                    outJSON = mj;
                }
                NSLog(@"[TubeReplacer] bridge player: captions for %@: %@ (native=%d)", videoID, TRHasCaptionTracks(videoID) ? @"yes" : @"none", native);
                NSError *err2 = nil;
                id res2 = TRParseJSONInto(outJSON, respClass, parser, @"player", &err2);
                completion(res2, err2);
            };
            void (^finish)(NSDictionary *) = ^(NSDictionary *pj) { TRAwaitTranscriptInfo(videoID, 25, ^{ finishNow(pj); }); };
            NSArray *tracks0 = [TRJSONUtils arrayFromJSON:json keyPath:@"captions.playerCaptionsTracklistRenderer.captionTracks"];
            TRCacheCaptionTracks(videoID, tracks0);
            if (![tracks0 count]) {
                TRPostInnerTube(@"player", @{ @"videoId": videoID, @"contentCheckOk": @YES, @"racyCheckOk": @YES }, ^(NSDictionary *wj, NSInteger wc, NSError *we) {
                    NSArray *wt = [TRJSONUtils arrayFromJSON:wj keyPath:@"captions.playerCaptionsTracklistRenderer.captionTracks"];
                    NSLog(@"[TubeReplacer] bridge player: web client caption lookup http=%ld tracks=%lu", (long)wc, (unsigned long)[wt count]);
                    TRCacheCaptionTracks(videoID, wt);
                    NSMutableDictionary *merged = [[json mutableCopy] autorelease];
                    id tl = TRDig(wj, @[@"captions", @"playerCaptionsTracklistRenderer"]);
                    if (tl) merged[@"captions"] = @{ @"playerCaptionsTracklistRenderer": tl };
                    finish(merged);
                });
            } else finish(json);
            });
            return;
            });
        });
        return;
    }

    if ([endpoint isEqualToString:@"guide"]) {
        if (majorVersion() <= 11) {
            // old drawer: needs the playlists, channels and Watch Later count, so ask the web first
            TRWaitIdentity();
            TRPostInnerTube(@"guide", @{}, ^(NSDictionary *wj, NSInteger wc, NSError *we) {
                NSInteger cnt = [[NSUserDefaults standardUserDefaults] integerForKey:@"TRWLCount"];
                NSError *derr = nil;
                id dres = TRParseJSONInto(TRDrawerGuide(wc < 400 ? wj : nil, cnt), respClass, parser, @"guide(drawer)", &derr);
                if (!dres) { NSLog(@"[TubeReplacer] drawer guide rejected (%@), plain drawer", derr); derr = nil; dres = TRParseJSONInto(TRSyntheticGuide(), respClass, parser, @"guide(local)", &derr); }
                completion(dres, derr);
                TRPostInnerTube(@"browse", @{ @"browseId": @"VLWL" }, ^(NSDictionary *lj, NSInteger lc, NSError *le) {
                    if (!lj || lc >= 400) return;
                    NSMutableArray *v = [NSMutableArray array]; TRCollectKey(lj, @"playlistVideoRenderer", v, 0);
                    [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)[v count] forKey:@"TRWLCount"];
                });
            });
            return;
        }
        NSError *gerr = nil;
        id gres = TRParseJSONInto(TRSyntheticGuide(), respClass, parser, @"guide(local)", &gerr);
        if (!gres && !gTRGuideLite) { NSLog(@"[TubeReplacer] guide with tab bar rejected (%@), drawer only", gerr); gTRGuideLite = YES; gerr = nil; gres = TRParseJSONInto(TRSyntheticGuide(), respClass, parser, @"guide(local)", &gerr); }
        completion(gres, gerr);
        return;
    }

    // Activity (v13 tab) / notification inbox: the web has no such browse page, build it from the notification menu
    if ([endpoint isEqualToString:@"browse"] && ([body[@"browseId"] isEqualToString:@"FEactivity"] || [body[@"browseId"] isEqualToString:@"FEnotifications_inbox"]) && ![body[@"continuation"] length]) {
        TRPostInnerTube(@"notification/get_notification_menu", @{ @"notificationsMenuRequestType": @"NOTIFICATIONS_MENU_REQUEST_TYPE_INBOX" }, ^(NSDictionary *nj, NSInteger nc, NSError *ne) {
            NSMutableArray *found = [NSMutableArray array], *items = [NSMutableArray array];
            @try { TRCollectKey(nj, @"notificationRenderer", found, 0); } @catch (NSException *e) {}
            for (id n in found) {
                if (![n isKindOfClass:[NSDictionary class]]) continue;
                NSMutableDictionary *nm = [[n mutableCopy] autorelease];
                // tapping a row first sent notification/record_interactions, which these apps can't parse ("error, please try again")
                [nm removeObjectForKey:@"recordClickEndpoint"]; [nm removeObjectForKey:@"recordDismissedEndpoint"];
                NSDictionary *nav = nm[@"navigationEndpoint"];
                if (![nav[@"watchEndpoint"] isKindOfClass:[NSDictionary class]]) {
                    NSString *vid = nil;
                    NSString *url = TRDig(nav, @[@"commandMetadata", @"webCommandMetadata", @"url"]);
                    NSRange vr = [url rangeOfString:@"v="];
                    if (vr.location != NSNotFound) { vid = [url substringFromIndex:vr.location + 2]; NSRange e = [vid rangeOfString:@"&"]; if (e.location != NSNotFound) vid = [vid substringToIndex:e.location]; }
                    if (![vid length]) {
                        NSString *tu = TRDig(nm, @[@"videoThumbnail", @"thumbnails", @0, @"url"]);
                        NSArray *tp = [tu componentsSeparatedByString:@"/vi/"];
                        if ([tp count] > 1) vid = [[tp[1] componentsSeparatedByString:@"/"] firstObject];
                    }
                    if ([vid length] == 11) nm[@"navigationEndpoint"] = @{ @"watchEndpoint": @{ @"videoId": vid } };
                }
                [items addObject:@{ @"notificationRenderer": nm }];
            }
            NSLog(@"[TubeReplacer] activity: http=%ld %lu notification(s)", (long)nc, (unsigned long)[items count]);
            if (![items count]) [items addObject:@{ @"messageRenderer": @{ @"text": TRSimpleText(@"No notifications") } }];
            NSDictionary *raw = @{ @"contents": @{ @"singleColumnBrowseResultsRenderer": @{ @"tabs": @[ @{ @"tabRenderer": @{ @"selected": @YES,
                @"content": @{ @"sectionListRenderer": @{ @"contents": @[ @{ @"itemSectionRenderer": @{ @"contents": items } } ] } } } } ] } } };
            NSError *ae = nil;
            id ares = nil;
            @try { ares = TRParseJSONInto(TRNormalizeResponse(raw), respClass, parser, endpoint, &ae); } @catch (NSException *e) { NSLog(@"[TubeReplacer] activity: %@", e); }
            if (!ares) NSLog(@"[TubeReplacer] activity: page rejected %@", ae);
            completion(ares, ae);
        });
        return;
    }

    // Trending tab: build it from search (new videos with 1M+ views) instead of the near-empty curated playlist
    if ([endpoint isEqualToString:@"browse"] && ![body[@"continuation"] length] && TRTrendingIsAuto()
        && ([body[@"browseId"] isEqualToString:TRTrendingBrowseId()] || [body[@"browseId"] isEqualToString:@"FEtrending"])) {
        TRTrendingFromSearch(^(NSArray *items) {
            if (![items count]) { completion(nil, TRError(304, @"Couldn't load trending videos.")); return; }
            NSDictionary *fake = @{ @"contents": @{ @"twoColumnSearchResultsRenderer": @{ @"primaryContents": @{ @"sectionListRenderer": @{
                @"contents": @[ @{ @"itemSectionRenderer": @{ @"contents": items } } ] } } } } };
            NSDictionary *tn = TRNormalizeResponse(fake);
            NSError *te = nil;
            id tres = tn ? TRParseJSONInto(tn, respClass, parser, endpoint, &te) : nil;
            if (!tres) { completion(nil, te ?: TRError(304, @"Couldn't load trending videos.")); return; }
            completion(tres, te);
        });
        return;
    }

    // Mix playlists (RD...) have no playlist page: build one from the watch-next playlist panel
    if ([endpoint isEqualToString:@"browse"] && [body[@"browseId"] hasPrefix:@"VLRD"] && ![body[@"continuation"] length]) {
        NSString *pid = [body[@"browseId"] substringFromIndex:2];
        NSMutableDictionary *nb = [NSMutableDictionary dictionaryWithObject:pid forKey:@"playlistId"];
        if ([pid length] == 13) nb[@"videoId"] = [pid substringFromIndex:2]; // RD<videoId>
        TRPostInnerTube(@"next", nb, ^(NSDictionary *nj, NSInteger nc, NSError *ne) {
            NSDictionary *panel = TRDig(nj, @[@"contents", @"twoColumnWatchNextResults", @"playlist", @"playlist"]);
            NSArray *pc = [panel isKindOfClass:[NSDictionary class]] ? panel[@"contents"] : nil;
            NSMutableArray *items = [NSMutableArray array];
            for (NSDictionary *e in ([pc isKindOfClass:[NSArray class]] ? pc : @[])) {
                NSDictionary *r = e[@"playlistPanelVideoRenderer"];
                if (![r isKindOfClass:[NSDictionary class]] || ![r[@"videoId"] length]) continue;
                NSMutableDictionary *v = [NSMutableDictionary dictionary];
                for (NSString *k in @[@"videoId", @"title", @"thumbnail", @"longBylineText", @"shortBylineText", @"lengthText", @"navigationEndpoint"])
                    if (r[k]) v[k] = r[k];
                [items addObject:@{ @"compactVideoRenderer": v }];
            }
            if (![items count]) { completion(nil, ne ?: TRError(308, @"This mix can't be loaded.")); return; }
            NSDictionary *fixed = @{ @"contents": @{ @"singleColumnBrowseResultsRenderer": @{ @"tabs": @[ @{ @"tabRenderer": @{ @"content": @{ @"sectionListRenderer": @{ @"contents": @[ @{ @"itemSectionRenderer": @{ @"contents": items } } ] } } } } ] } },
                                     @"metadata": @{ @"playlistMetadataRenderer": @{ @"title": panel[@"title"] ?: @"Mix" } } };
            NSError *me = nil;
            id mres = TRParseJSONInto(TRFix(fixed), respClass, parser, @"mix", &me);
            completion(mres, me);
        });
        return;
    }

    // Everything else: a normal InnerTube call. The desktop web client still answers with the
    // classic renderers (videoRenderer, itemSectionRenderer, ...) these app versions understand.
    YoutubeClientType *client = [YoutubeClientType webClient];
    NSMutableDictionary *full = [NSMutableDictionary dictionaryWithObject:[client makeContext] forKey:@"context"];
    [full addEntriesFromDictionary:body];
    NSData *postBody = [NSJSONSerialization dataWithJSONObject:full options:0 error:nil];

    NSString *urlString = [NSString stringWithFormat:@"https://www.youtube.com/youtubei/v1/%@?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false", endpoint];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
    [req setHTTPMethod:@"POST"];
    [req setHTTPBody:postBody];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if ([client.useragent length]) [req setValue:client.useragent forHTTPHeaderField:@"User-Agent"];
    BOOL signedInReq = TRAuthorizeRequest(req);

    NSLog(@"[TubeReplacer] bridge %@: (%@) -> %@", endpoint, signedInReq ? @"signed in" : @"anonymous",
          [[[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:body options:0 error:nil] encoding:NSUTF8StringEncoding] autorelease]);
    [NSURLConnection sendAsynchronousRequest:req queue:TRBridgeQueue() completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSLog(@"[TubeReplacer] bridge %@: http=%ld bytes=%lu keys=%@ err=%@", endpoint, (long)code, (unsigned long)[data length],
              [json isKindOfClass:[NSDictionary class]] ? [[(NSDictionary *)json allKeys] componentsJoinedByString:@","] : @"-", err);
        if ([endpoint isEqualToString:@"next"] && [body[@"videoId"] length] && [json isKindOfClass:[NSDictionary class]]) TRCacheTranscriptParamsFrom(body[@"videoId"], json);
        if (code == 400 && [endpoint isEqualToString:@"browse"] && body[@"continuation"]) {
            // a continuation token from the "trending" search fallback belongs to the search endpoint
            TRPostInnerTube(@"search", @{ @"continuation": body[@"continuation"] }, ^(NSDictionary *sj, NSInteger sc, NSError *se) {
                if (!sj || sc >= 400) { completion(nil, se ?: TRError(304, @"Server error.")); return; }
                NSError *e3 = nil;
                id r3 = TRParseJSONInto(TRNormalizeResponse(sj), respClass, parser, endpoint, &e3);
                completion(r3, e3);
            });
            return;
        }
        if (![json isKindOfClass:[NSDictionary class]] || code >= 400) {
            completion(nil, err ?: TRError(304, [NSString stringWithFormat:@"Server error %ld.", (long)code]));
            return;
        }
        NSError *perr = nil;
        @try { NSLog(@"[TubeReplacer] bridge %@: raw: %@", endpoint, TRRendererSummary(json)); } @catch (NSException *e) {}
        if ([endpoint isEqualToString:@"browse"] && [body[@"continuation"] length] && gTRFeedTokens) {
            BOOL mine; @synchronized (gTRFeedTokens) { mine = [gTRFeedTokens containsObject:body[@"continuation"]]; }
            if (mine) json = TRFeedContinuationFromPlaylist(json);
        }
        NSDictionary *norm = TRNormalizeResponse(json);
        if ([endpoint isEqualToString:@"browse"] && TRIsHomeFeedId(body[@"browseId"]) && !body[@"continuation"] && !TRHasVideos(norm, 0)) {
            // Signed-out YouTube no longer serves a home feed: show the curated trending playlist instead (search as a last resort).
            NSLog(@"[TubeReplacer] bridge browse: home feed is empty when signed out, using the trending playlist");
            void (^searchFallback)(void) = ^{
                TRPostInnerTube(@"search", @{ @"query": @"trending" }, ^(NSDictionary *sj, NSInteger sc, NSError *se) {
                    NSDictionary *sn = sj ? TRNormalizeResponse(sj) : nil;
                    NSError *e2 = nil;
                    id r2 = TRParseJSONInto(sn ?: norm, respClass, parser, endpoint, &e2);
                    completion(r2, e2);
                });
            };
            TRPostInnerTube(@"browse", @{ @"browseId": TRTrendingBrowseId() }, ^(NSDictionary *pj, NSInteger pc, NSError *pe) {
                NSDictionary *fake = (pj && pc < 400) ? TRFeedFromPlaylistJSON(pj) : nil;
                NSDictionary *tn = fake ? TRNormalizeResponse(fake) : nil;
                if (tn && TRHasVideos(tn, 0)) {
                    NSError *e2 = nil;
                    id r2 = TRParseJSONInto(tn, respClass, parser, endpoint, &e2);
                    if (r2) { completion(r2, e2); return; }
                }
                NSLog(@"[TubeReplacer] bridge browse: trending playlist page unusable (http=%ld), trying the playlist panel", (long)pc);
                NSString *plid = [TRTrendingBrowseId() hasPrefix:@"VL"] ? [TRTrendingBrowseId() substringFromIndex:2] : TRTrendingBrowseId();
                TRPostInnerTube(@"next", @{ @"playlistId": plid }, ^(NSDictionary *nj, NSInteger nc, NSError *ne) {
                    NSMutableArray *vids = [NSMutableArray array];
                    @try {
                        NSMutableArray *panel = [NSMutableArray array];
                        TRCollectKey(nj, @"playlistPanelVideoRenderer", panel, 0);
                        for (NSDictionary *pv in panel) {
                            if (![pv isKindOfClass:[NSDictionary class]] || ![pv[@"videoId"] length]) continue;
                            NSMutableDictionary *v = [NSMutableDictionary dictionary];
                            v[@"videoId"] = pv[@"videoId"];
                            if (pv[@"title"]) v[@"title"] = pv[@"title"];
                            if (pv[@"thumbnail"]) v[@"thumbnail"] = pv[@"thumbnail"];
                            if (pv[@"lengthText"]) v[@"lengthText"] = pv[@"lengthText"];
                            id by = pv[@"longBylineText"] ?: pv[@"shortBylineText"];
                            if (by) { v[@"ownerText"] = by; v[@"longBylineText"] = by; }
                            [vids addObject:@{ @"videoRenderer": v }];
                        }
                    } @catch (NSException *e) {}
                    NSLog(@"[TubeReplacer] bridge browse: playlist panel http=%ld videos=%lu", (long)nc, (unsigned long)[vids count]);
                    if ([vids count]) {
                        NSDictionary *fake2 = @{ @"contents": @{ @"twoColumnSearchResultsRenderer": @{ @"primaryContents": @{ @"sectionListRenderer": @{
                            @"contents": @[ @{ @"itemSectionRenderer": @{ @"contents": vids } } ] } } } } };
                        NSDictionary *tn2 = TRNormalizeResponse(fake2);
                        NSError *e2 = nil;
                        id r2 = tn2 ? TRParseJSONInto(tn2, respClass, parser, endpoint, &e2) : nil;
                        if (r2) { completion(r2, e2); return; }
                    }
                    searchFallback();
                });
            });
            return;
        }
        if ([endpoint isEqualToString:@"browse"] && [body[@"browseId"] hasPrefix:@"UC"] && ![body[@"params"] length] && ![body[@"continuation"] length]
            && TRDig(norm, @[@"contents", @"singleColumnBrowseResultsRenderer", @"tabs"])) {
            TRFetchAboutStats(json, ^(NSDictionary *aboutVM) {
            TRInlineChannelTabs(norm, aboutVM, ^(NSDictionary *full) {
                NSError *ie = nil;
                NSDictionary *gfull = TRGridifyChannel(full);
                id ires = TRParseJSONInto(gfull, respClass, parser, endpoint, &ie);
                if (!ires && gfull != full) { NSLog(@"[TubeReplacer] channel grid rejected, using list: %@", ie); ie = nil; ires = TRParseJSONInto(full, respClass, parser, endpoint, &ie); }
                completion(ires, ie);
            });
            });
            return;
        }
        if ([endpoint isEqualToString:@"next"] && ![body[@"continuation"] length] && TRDig(norm, @[@"contents", @"singleColumnWatchNextResults"])) {
            NSString *ctoken = TRFindCommentsToken(json, 0);
            NSLog(@"[TubeReplacer] bridge next: comments token %@", ctoken ? @"found" : @"not found");
            if (ctoken && NSClassFromString(@"YTCommentThreadCellController")) {
                TRPostInnerTube(@"next", @{ @"continuation": ctoken }, ^(NSDictionary *cj, NSInteger cc, NSError *ce) {
                    NSDictionary *n2 = norm;
                    @try {
                        NSDictionary *cn = cj ? TRNormalizeResponse(cj) : nil;
                        NSDictionary *pg = TRDig(cn, @[@"continuationContents", @"itemSectionContinuation"]);
                        NSLog(@"[TubeReplacer] bridge next: comments page http=%ld threads=%lu", (long)cc, (unsigned long)[[pg isKindOfClass:[NSDictionary class]] ? pg[@"contents"] : nil count]);
                        if ([pg isKindOfClass:[NSDictionary class]]) {
                            TRFillTeasers(pg, ^(NSDictionary *pg2) {
                                NSDictionary *n3 = norm;
                                @try { n3 = TRWithComments(norm, pg2); } @catch (NSException *ex) { NSLog(@"[TubeReplacer] bridge next: comments failed %@", ex); }
                                NSError *e4 = nil;
                                id r4 = TRParseJSONInto(n3, respClass, parser, endpoint, &e4);
                                if (!r4 && n3 != norm) r4 = TRParseJSONInto(norm, respClass, parser, endpoint, &e4);
                                completion(r4, e4);
                            });
                            return;
                        }
                    } @catch (NSException *ex) { NSLog(@"[TubeReplacer] bridge next: comments failed %@", ex); }
                    NSError *e3 = nil;
                    id r3 = TRParseJSONInto(n2, respClass, parser, endpoint, &e3);
                    if (!r3 && n2 != norm) r3 = TRParseJSONInto(norm, respClass, parser, endpoint, &e3); // never lose the video over comments
                    completion(r3, e3);
                });
                return;
            }
        }
        if ([endpoint isEqualToString:@"browse"] && [body[@"browseId"] isEqualToString:@"FEsubscriptions"] && ![body[@"continuation"] length] && majorVersion() >= 11) {
            // the subscriptions page of 11.x - 13.x opens with a strip of channel icons (a channelListSubMenu);
            // the web no longer sends one, so build it from the guide's subscription list
            TRPostInnerTube(@"guide", @{}, ^(NSDictionary *gj, NSInteger gc, NSError *ge) {
                NSDictionary *n2 = norm;
                @try {
                    NSMutableArray *entries = [NSMutableArray array];
                    TRCollectKey(gj, @"guideEntryRenderer", entries, 0);
                    NSMutableArray *avs = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
                    for (NSDictionary *en in entries) {
                        if (![en isKindOfClass:[NSDictionary class]]) continue;
                        NSString *cid = TRDig(en, @[@"navigationEndpoint", @"browseEndpoint", @"browseId"]);
                        NSArray *th = TRDig(en, @[@"thumbnail", @"thumbnails"]);
                        if (![cid hasPrefix:@"UC"] || ![th isKindOfClass:[NSArray class]] || ![th count] || [seen containsObject:cid]) continue;
                        [seen addObject:cid];
                        NSString *nm = TRTextOf(en[@"formattedTitle"]) ?: TRTextOf(en[@"title"]) ?: @"";
                        [avs addObject:@{ @"channelListSubMenuAvatarRenderer": @{
                            @"thumbnail": @{ @"thumbnails": th },
                            @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": cid } },
                            @"accessibility": @{ @"accessibilityData": @{ @"label": nm } } } }];
                        if ([avs count] >= 25) break;
                    }
                    NSLog(@"[TubeReplacer] bridge browse: subscriptions strip http=%ld channels=%lu", (long)gc, (unsigned long)[avs count]);
                    if ([avs count]) {
                        NSData *jd = [NSJSONSerialization dataWithJSONObject:norm options:0 error:nil];
                        NSMutableDictionary *mn = jd ? [NSJSONSerialization JSONObjectWithData:jd options:NSJSONReadingMutableContainers error:nil] : nil;
                        id sl = mn ? TRFindKey(mn, @"sectionListRenderer", 0) : nil;
                        if ([sl isKindOfClass:[NSMutableDictionary class]]) {
                            ((NSMutableDictionary *)sl)[@"subMenu"] = @{ @"channelListSubMenuRenderer": @{ @"contents": avs } };
                            n2 = mn;
                        }
                    }
                } @catch (NSException *ex) { NSLog(@"[TubeReplacer] bridge browse: subscriptions strip failed %@", ex); }
                NSError *e5 = nil;
                id r5 = TRParseJSONInto(n2, respClass, parser, endpoint, &e5);
                if (!r5 && n2 != norm) r5 = TRParseJSONInto(norm, respClass, parser, endpoint, &e5);
                completion(r5, e5);
            });
            return;
        }
        if ([endpoint isEqualToString:@"browse"] && ([body[@"browseId"] isEqualToString:@"VLWL"] || [body[@"browseId"] isEqualToString:@"VLLL"]) && ![body[@"continuation"] length] && majorVersion() >= 10) {
            // the list page of 10.2x/11.x only reads rows inside a one-tab wrapper (like the playlists that work)
            id wsl = TRDig(norm, @[@"contents", @"sectionListRenderer"]);
            if ([wsl isKindOfClass:[NSDictionary class]] && !TRDig(norm, @[@"contents", @"singleColumnBrowseResultsRenderer"])) {
                NSMutableDictionary *wn = [[norm mutableCopy] autorelease];
                wn[@"contents"] = @{ @"singleColumnBrowseResultsRenderer": @{ @"tabs": @[ @{ @"tabRenderer": @{ @"content": @{ @"sectionListRenderer": wsl } } } ] } };
                NSError *we = nil;
                id wres = TRParseJSONInto(wn, respClass, parser, endpoint, &we);
                NSLog(@"[TubeReplacer] bridge browse: %@ wrapped in a tab: %@", body[@"browseId"], wres ? @"ok" : @"rejected");
                if (wres) { completion(wres, we); return; }
            }
        }
        if ([endpoint isEqualToString:@"browse"] && [body[@"browseId"] isEqualToString:@"FEwhat_to_watch"] && ![body[@"continuation"] length] && majorVersion() == 11) {
            // 11.x's front page is a tabbed browse: Home, Trending, Subscriptions and Account as icon tabs
            @try {
                NSArray *t0 = TRDig(norm, @[@"contents", @"singleColumnBrowseResultsRenderer", @"tabs"]);
                id slr = TRDig(norm, @[@"contents", @"sectionListRenderer"]);
                NSLog(@"[TubeReplacer] v11 home tabs: tabs=%lu sectionList=%d", (unsigned long)([t0 isKindOfClass:[NSArray class]] ? [t0 count] : 0), [slr isKindOfClass:[NSDictionary class]]);
                if (TRWantsBigCards()) { norm = TRBigCardsHome(norm); t0 = TRDig(norm, @[@"contents", @"singleColumnBrowseResultsRenderer", @"tabs"]); slr = TRDig(norm, @[@"contents", @"sectionListRenderer"]); }
                NSMutableDictionary *home = nil;
                if ([t0 isKindOfClass:[NSArray class]] && [t0 count] == 1 && [TRDig(t0[0], @[@"tabRenderer", @"content"]) isKindOfClass:[NSDictionary class]])
                    home = [[t0[0][@"tabRenderer"] mutableCopy] autorelease];
                else if ([slr isKindOfClass:[NSDictionary class]]) // the web's home feed is a bare section list: it becomes the Home tab
                    home = [NSMutableDictionary dictionaryWithObject:@{ @"sectionListRenderer": slr } forKey:@"content"];
                if (home) {
                    home[@"title"] = @"Home"; home[@"selected"] = @YES; home[@"icon"] = @{ @"iconType": @65 }; home[@"tabIdentifier"] = @"FEwhat_to_watch"; // 65 = the tab-bar house (5 is the drawer one)
                    home[@"endpoint"] = @{ @"browseEndpoint": @{ @"browseId": @"FEwhat_to_watch" } };
                    NSMutableArray *nt = [NSMutableArray arrayWithObject:@{ @"tabRenderer": home }];
                    // icon numbers come from the v11 tab-icon switch: 65 home, 66 subscriptions, 67 trending, 68 library, 69 account
                    NSArray *more = @[ @[@"Trending", TRTrendingBrowseId(), @67], @[@"Subscriptions", @"FEsubscriptions", @66], @[@"Account", @"FElibrary", @69] ];
                    dispatch_group_t tg = dispatch_group_create();
                    for (NSArray *m in more) {
                        NSMutableDictionary *tab = [NSMutableDictionary dictionaryWithDictionary:@{ @"title": m[0], @"selected": @NO,
                            @"tabIdentifier": m[1], @"endpoint": @{ @"browseEndpoint": @{ @"browseId": m[1] } } }];
                        if ([m[2] intValue]) tab[@"icon"] = @{ @"iconType": m[2] };
                        [nt addObject:@{ @"tabRenderer": tab }];
                        // the app never asks for a tab's page itself (no request in the logs): put every tab's content in the reply
                        dispatch_group_enter(tg);
                        NSString *bid = m[1], *ttl = m[0]; NSMutableDictionary *tabRef = tab;
                        TRPostInnerTube(@"browse", @{ @"browseId": bid }, ^(NSDictionary *tj, NSInteger tc, NSError *te2) {
                            @try {
                                if (tj && tc < 400) {
                                    NSDictionary *tn = TRNormalizeResponse(tj);
                                    id content = nil;
                                    id tsl = TRDig(tn, @[@"contents", @"sectionListRenderer"]);
                                    if ([tsl isKindOfClass:[NSDictionary class]]) content = @{ @"sectionListRenderer": tsl };
                                    if (!content) for (NSDictionary *tt in ([TRDig(tn, @[@"contents", @"singleColumnBrowseResultsRenderer", @"tabs"]) isKindOfClass:[NSArray class]] ? TRDig(tn, @[@"contents", @"singleColumnBrowseResultsRenderer", @"tabs"]) : @[])) {
                                        id c = TRDig(tt, @[@"tabRenderer", @"content"]);
                                        if ([c isKindOfClass:[NSDictionary class]]) { content = c; break; }
                                    }
                                    if (content && [ttl isEqualToString:@"Subscriptions"]) {
                                        // the strip of channel icons above the feed (built from the guide's subscription list)
                                        id contentIn = content;
                                        TRPostInnerTube(@"guide", @{}, ^(NSDictionary *gj, NSInteger gc, NSError *ge) {
                                            id c2 = contentIn;
                                            @try {
                                                NSMutableArray *avs = [NSMutableArray array]; NSMutableSet *seen = [NSMutableSet set];
                                                NSMutableArray *entries = [NSMutableArray array];
                                                if (gj) TRCollectKey(gj, @"guideEntryRenderer", entries, 0);
                                                for (NSDictionary *en in entries) {
                                                    if (![en isKindOfClass:[NSDictionary class]]) continue;
                                                    NSString *cid = TRDig(en, @[@"navigationEndpoint", @"browseEndpoint", @"browseId"]);
                                                    NSArray *th = TRDig(en, @[@"thumbnail", @"thumbnails"]);
                                                    if (![cid hasPrefix:@"UC"] || ![th isKindOfClass:[NSArray class]] || ![th count] || [seen containsObject:cid]) continue;
                                                    [seen addObject:cid];
                                                    NSString *nm = TRTextOf(en[@"formattedTitle"]) ?: TRTextOf(en[@"title"]) ?: @"";
                                                    [avs addObject:@{ @"channelListSubMenuAvatarRenderer": @{ @"thumbnail": @{ @"thumbnails": th },
                                                        @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": cid } },
                                                        @"accessibility": @{ @"accessibilityData": @{ @"label": nm } } } }];
                                                    if ([avs count] >= 25) break;
                                                }
                                                NSLog(@"[TubeReplacer] v11 subscriptions strip: %lu channel(s) (http=%ld)", (unsigned long)[avs count], (long)gc);
                                                id csl = c2[@"sectionListRenderer"];
                                                if ([avs count] && [csl isKindOfClass:[NSDictionary class]]) {
                                                    NSMutableDictionary *ms = [[csl mutableCopy] autorelease];
                                                    ms[@"subMenu"] = @{ @"channelListSubMenuRenderer": @{ @"contents": avs } };
                                                    c2 = @{ @"sectionListRenderer": ms };
                                                }
                                            } @catch (NSException *e4) { NSLog(@"[TubeReplacer] v11 subscriptions strip: %@", e4); }
                                            @synchronized (tabRef) { tabRef[@"content"] = c2; }
                                            NSLog(@"[TubeReplacer] v11 tab %@: loaded (http=%ld)", ttl, (long)tc);
                                            dispatch_group_leave(tg);
                                        });
                                        return;
                                    }
                                    if (content && ![ttl isEqualToString:@"Account"] && !([ttl isEqualToString:@"Subscriptions"] && TRIsPad()) && TRWantsBigCards()) { NSDictionary *bc = TRBigCards(@{ @"c": content }); content = bc[@"c"] ?: content; }
                                    if (content) @synchronized (tabRef) { tabRef[@"content"] = content; }
                                    NSLog(@"[TubeReplacer] v11 tab %@: %@ (http=%ld)", ttl, content ? @"loaded" : @"no content", (long)tc);
                                } else NSLog(@"[TubeReplacer] v11 tab %@: failed http=%ld", ttl, (long)tc);
                            } @catch (NSException *e3) { NSLog(@"[TubeReplacer] v11 tab %@: %@", ttl, e3); }
                            dispatch_group_leave(tg);
                        });
                    }
                    NSDictionary *baseNorm = norm;
                    dispatch_group_notify(tg, dispatch_get_main_queue(), ^{
                        for (NSDictionary *tw in nt) {
                            NSMutableDictionary *tabD = tw[@"tabRenderer"];
                            if (![tabD[@"title"] isEqual:@"Account"]) continue;
                            // Account tab like the official app: account header (photo, name), then History / My videos / Watch Later, then Liked videos
                            NSDictionary *prm = TRAccountParams();
                            NSString *nm = gTRProfileName ?: prm[@"fullName"] ?: prm[@"userEmail"] ?: @"Account";
                            NSMutableDictionary *hdr = [NSMutableDictionary dictionaryWithObject:TRSimpleText(nm) forKey:@"accountName"];
                            NSString *ph = [gTRProfilePhoto length] ? gTRProfilePhoto : prm[@"avatar"];
                            if ([ph length]) hdr[@"accountPhoto"] = @{ @"thumbnails": @[ @{ @"url": ph, @"width": @96, @"height": @96 } ] };
                            if ([gTRMyChannel length]) hdr[@"channelEndpoint"] = @{ @"browseEndpoint": @{ @"browseId": gTRMyChannel } };
                            tabD[@"header"] = @{ @"activeAccountHeaderRenderer": hdr };
                            NSDictionary *(^link)(NSString *, int, NSString *) = ^NSDictionary *(NSString *t, int icon, NSString *bid) {
                                return @{ @"compactLinkRenderer": @{ @"title": TRSimpleText(t), @"icon": @{ @"iconType": @(icon) },
                                    @"navigationEndpoint": @{ @"browseEndpoint": @{ @"browseId": bid } } } };
                            };
                            NSMutableArray *secs = [NSMutableArray array];
                            [secs addObject:@{ @"itemSectionRenderer": @{ @"contents": @[ link(@"History", 2, @"FEhistory"),
                                link(@"My videos", 7, [gTRMyChannel length] ? gTRMyChannel : @"FElibrary"), link(@"Watch Later", 3, @"VLWL") ] } }];
                            [secs addObject:@{ @"itemSectionRenderer": @{ @"contents": @[ link(@"Liked videos", 16, @"VLLL") ] } }];
                            NSArray *old = TRDig(tabD, @[@"content", @"sectionListRenderer", @"contents"]);
                            if ([old isKindOfClass:[NSArray class]]) [secs addObjectsFromArray:old]; // keep the library's own playlists below
                            tabD[@"content"] = @{ @"sectionListRenderer": @{ @"contents": secs } };
                        }
                        NSMutableDictionary *r2 = [[baseNorm mutableCopy] autorelease];
                        r2[@"contents"] = @{ @"singleColumnBrowseResultsRenderer": @{ @"tabs": nt } };
                        NSError *te = nil;
                        id tres = TRParseJSONInto(r2, respClass, parser, endpoint, &te);
                        NSLog(@"[TubeReplacer] v11 home tabs: %@", tres ? @"ok" : @"rejected");
                        if (!tres) { te = nil; tres = TRParseJSONInto(baseNorm, respClass, parser, endpoint, &te); }
                        completion(tres, te);
                    });
                    dispatch_release(tg);
                    return;
                }
            } @catch (NSException *ex) { NSLog(@"[TubeReplacer] v11 home tabs failed %@", ex); }
        }
        if ([endpoint isEqualToString:@"browse"] && majorVersion() == 10 && [body[@"browseId"] isEqualToString:@"FEsubscriptions"] && ![body[@"continuation"] length]) {
            NSDictionary *ssn = TRSubsShelves(norm);
            NSError *sse = nil;
            id ssres = ssn != norm ? TRParseJSONInto(ssn, respClass, parser, endpoint, &sse) : nil;
            NSLog(@"[TubeReplacer] v10 subscription shelves: %@", ssres ? @"ok" : @"not used");
            if (ssres) { completion(ssres, sse); return; }
        }
        if ([endpoint isEqualToString:@"browse"] && TRWantsShelves() && TRIsHomeFeedId(body[@"browseId"]) && ![body[@"continuation"] length]) {
            if (majorVersion() == 10) {
                // "Watch it again" needs the watch history: wait briefly for it (off the main thread), else it appears on the next refresh
                dispatch_semaphore_t hs = dispatch_semaphore_create(0);
                BOOL main = [NSThread isMainThread];
                TRFetchHistoryItems(^{ dispatch_semaphore_signal(hs); });
                if (!main) dispatch_semaphore_wait(hs, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
                dispatch_release(hs);
            }
            NSDictionary *sn = TRShelvesHome(norm);
            NSError *se = nil;
            id sres = sn != norm ? TRParseJSONInto(sn, respClass, parser, endpoint, &se) : nil;
            NSLog(@"[TubeReplacer] v10 home shelves: %@", sres ? @"ok" : @"not used");
            if (sres) { completion(sres, se); return; }
        }
        BOOL isSubsFeed = [body[@"browseId"] isEqualToString:@"FEsubscriptions"];
        if ([endpoint isEqualToString:@"browse"] && TRWantsBigCards() && TRIsHomeFeedId(body[@"browseId"]) && ![body[@"continuation"] length]) {
            gTRGridTitle = isSubsFeed ? @"New videos" : nil;
            NSDictionary *bn = [body[@"browseId"] isEqualToString:@"FEwhat_to_watch"] ? TRBigCardsHome(norm) : TRBigCards(norm);
            gTRGridTitle = nil;
            NSError *be = nil;
            id bres = bn != norm ? TRParseJSONInto(bn, respClass, parser, endpoint, &be) : nil;
            NSLog(@"[TubeReplacer] big video cards: %@", bres ? @"ok" : @"not used");
            if (bres) { completion(bres, be); return; }
        }
        if ([endpoint isEqualToString:@"browse"] && [body[@"browseId"] isEqualToString:@"FEsubscriptions"] && ![body[@"continuation"] length]) {
            @try { TRNoteSubsFeed(TRVideosOf(norm), YES); } @catch (NSException *e) {}
        }
        if ([endpoint isEqualToString:@"browse"] && majorVersion() >= 12 && [body[@"browseId"] isEqualToString:@"FElibrary"] && ![body[@"continuation"] length]) {
            // the app's Library page: the account header on top, then History / Watch later / Liked videos, then the playlists
            NSDictionary *ln = TRLibraryPage(norm);
            NSError *le = nil;
            id lres = ln != norm ? TRParseJSONInto(ln, respClass, parser, endpoint, &le) : nil;
            NSLog(@"[TubeReplacer] library page: %@", lres ? @"ok" : @"not used");
            if (lres) { completion(lres, le); return; }
        }
        id res = TRParseJSONInto(norm, respClass, parser, endpoint, &perr);
        completion(res, perr);
    }];
}


#pragma mark - v3 (youtube/v3, alt=proto) feeds built from InnerTube

static void TRDumpSchema(Class cls, int depth, NSString *indent, NSMutableSet *seen) {
    TRPBSchema *sc = TRSchema(cls);
    if (!sc || depth > 4 || [seen containsObject:NSStringFromClass(cls)]) return;
    [seen addObject:NSStringFromClass(cls)];
    NSMutableString *line = [NSMutableString string];
    for (NSNumber *n in [[sc->byNumber allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        TRPBField *f = sc->byNumber[n];
        [line appendFormat:@"%@%@(t%d)%@ ", f->name, f->repeated ? @"[]" : @"", f->type, f->msgClass ? [@"=" stringByAppendingString:NSStringFromClass(f->msgClass)] : @""];
    }
    NSLog(@"[TubeReplacer] schema %@%@: %@", indent, NSStringFromClass(cls), line);
    for (TRPBField *f in [sc->byNumber allValues]) if (f->msgClass) TRDumpSchema(f->msgClass, depth + 1, [indent stringByAppendingString:@" "], seen);
}

static void TRCollectVideos(id node, NSMutableArray *out, NSMutableSet *ids, int depth) {
    if (depth > 40 || [out count] >= 60) return;
    if ([node isKindOfClass:[NSArray class]]) { for (id e in node) TRCollectVideos(e, out, ids, depth + 1); return; }
    if (![node isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *d = node;
    NSString *vid = [d[@"videoId"] isKindOfClass:[NSString class]] ? d[@"videoId"] : nil;
    NSString *title = TRTextOf(d[@"title"]);
    if ([vid length] && [title length] && ![ids containsObject:vid] && (d[@"thumbnail"] || d[@"lengthText"] || d[@"shortBylineText"] || d[@"ownerText"])) {
        [ids addObject:vid];
        NSString *chan = TRTextOf(d[@"shortBylineText"] ?: d[@"ownerText"] ?: d[@"longBylineText"]) ?: @"";
        NSString *cid = TRDig(d, @[@"shortBylineText", @"runs", @0, @"navigationEndpoint", @"browseEndpoint", @"browseId"]);
        NSArray *thumbs = TRDig(d, @[@"thumbnail", @"thumbnails"]);
        NSString *turl = [[thumbs lastObject] isKindOfClass:[NSDictionary class]] ? [thumbs lastObject][@"url"] : [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", vid];
        NSDictionary *tn = @{ @"url": turl ?: @"" };
        [out addObject:@{ @"kind": @"youtube#activity",
            @"snippet": @{ @"title": title, @"channelTitle": chan, @"channelId": cid ?: @"", @"type": @"upload",
                           @"thumbnails": @{ @"default": tn, @"medium": tn, @"high": tn, @"standard": tn } },
            @"contentDetails": @{ @"upload": @{ @"videoId": vid } } }];
        return;
    }
    for (id v in [d allValues]) TRCollectVideos(v, out, ids, depth + 1);
}

// activities?home=true (the 2.3.1 home feed) -> youtubei browse FEwhat_to_watch -> activityListResponse
static void TRRunV3Activities(Class respClass, id parser, void (^completion)(id, NSError *)) {
    static BOOL dumped = NO;
    if (!dumped) { dumped = YES; TRDumpSchema(respClass, 0, @"", [NSMutableSet set]); }
    YoutubeClientType *client = [YoutubeClientType webClient];
    NSDictionary *full = @{ @"context": [client makeContext], @"browseId": @"FEwhat_to_watch" };
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://www.youtube.com/youtubei/v1/browse?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false"]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25.0];
    [req setHTTPMethod:@"POST"];
    [req setHTTPBody:[NSJSONSerialization dataWithJSONObject:full options:0 error:nil]];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if ([client.useragent length]) [req setValue:client.useragent forHTTPHeaderField:@"User-Agent"];
    TRAuthorizeRequest(req);
    [NSURLConnection sendAsynchronousRequest:req queue:TRBridgeQueue() completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) { completion(nil, err ?: TRError(304, @"Server error.")); return; }
        NSMutableArray *items = [NSMutableArray array];
        TRCollectVideos(TRNormalizeResponse(json), items, [NSMutableSet set], 0);
        NSLog(@"[TubeReplacer] bridge activities: %lu video(s) from home feed", (unsigned long)[items count]);
        void (^finishWith)(NSArray *) = ^(NSArray *its) {
            NSDictionary *res = @{ @"kind": @"youtube#activityListResponse", @"items": its };
            NSError *perr = nil;
            id out = TRParseJSONInto(res, respClass, parser, @"activities", &perr);
            completion(out, perr);
        };
        if ([items count]) { finishWith(items); return; }
        TRPostInnerTube(@"search", @{ @"query": @"trending" }, ^(NSDictionary *sj, NSInteger sc, NSError *se) {
            NSMutableArray *its = [NSMutableArray array];
            if (sj) TRCollectVideos(TRNormalizeResponse(sj), its, [NSMutableSet set], 0);
            NSLog(@"[TubeReplacer] bridge activities: %lu video(s) from search fallback", (unsigned long)[its count]);
            finishWith(its);
        });
    }];
}


#pragma mark - youtube/v3 playlistItems / playlists / channels via InnerTube (2.3.x apps)

static NSDictionary *TRQueryDict(NSURL *u) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *pair in [[u query] componentsSeparatedByString:@"&"]) {
        NSRange r = [pair rangeOfString:@"="];
        if (r.location == NSNotFound) continue;
        NSString *k = [pair substringToIndex:r.location];
        NSString *v = [[pair substringFromIndex:r.location + 1] stringByReplacingOccurrencesOfString:@"+" withString:@" "];
        d[k] = [v stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: v;
    }
    return d;
}

static void TRCollectKey(id n, NSString *key, NSMutableArray *out, int depth) {
    if (depth > 40 || [out count] >= 200) return;
    if ([n isKindOfClass:[NSArray class]]) { for (id e in n) TRCollectKey(e, key, out, depth + 1); return; }
    if (![n isKindOfClass:[NSDictionary class]]) return;
    if (n[key]) { [out addObject:n[key]]; return; }
    for (id v in [n allValues]) TRCollectKey(v, key, out, depth + 1);
}

static NSDictionary *TRThumbSet(NSArray *thumbs, NSString *fallbackVideoId) {
    NSString *url = [[thumbs lastObject] isKindOfClass:[NSDictionary class]] ? [thumbs lastObject][@"url"] : nil;
    if (!url && fallbackVideoId) url = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", fallbackVideoId];
    if (!url) return @{};
    NSDictionary *t = @{ @"url": url };
    return @{ @"default": t, @"medium": t, @"high": t, @"standard": t };
}

static long long TRParseCount(NSString *s) {
    if (![s length]) return 0;
    double v = 0; NSScanner *sc = [NSScanner scannerWithString:[s stringByReplacingOccurrencesOfString:@"," withString:@""]];
    if (![sc scanDouble:&v]) return 0;
    NSString *rest = [[[s substringFromIndex:MIN([s length], [sc scanLocation])] lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([rest hasPrefix:@"k"]) v *= 1e3; else if ([rest hasPrefix:@"m"]) v *= 1e6; else if ([rest hasPrefix:@"b"]) v *= 1e9;
    return (long long)v;
}

static BOOL TRBridgeV3(NSURL *u, Class rc, id parser, void (^completion)(id, NSError *)) {
    NSString *path = [u path];
    NSDictionary *q = TRQueryDict(u);
    NSString *resource = [path lastPathComponent];
    static NSMutableSet *dumped = nil; if (!dumped) dumped = [[NSMutableSet alloc] init];
    if (![dumped containsObject:NSStringFromClass(rc)]) { [dumped addObject:NSStringFromClass(rc)]; TRDumpSchema(rc, 0, @"v3 ", [NSMutableSet set]); }

    void (^finish)(NSDictionary *) = ^(NSDictionary *res) {
        NSError *perr = nil;
        id out = TRParseJSONInto(res, rc, parser, [@"v3 " stringByAppendingString:resource], &perr);
        completion(out, perr);
    };

    if ([resource isEqualToString:@"playlistItems"] && ([q[@"playlistId"] length] || [q[@"pageToken"] length])) {
        NSString *pid = q[@"playlistId"] ?: @"";
        NSDictionary *body = [q[@"pageToken"] length] ? @{ @"continuation": q[@"pageToken"] } : @{ @"browseId": [@"VL" stringByAppendingString:pid] };
        NSLog(@"[TubeReplacer] bridge v3 playlistItems: -> %@", body);
        TRPostInnerTube(@"browse", body, ^(NSDictionary *j, NSInteger code, NSError *err) {
            if (!j || code >= 400) { completion(nil, err ?: TRError(304, @"Server error.")); return; }
            NSMutableArray *vids = [NSMutableArray array];
            TRCollectKey(j, @"playlistVideoRenderer", vids, 0);
            NSMutableArray *conts = [NSMutableArray array];
            TRCollectKey(j, @"continuationCommand", conts, 0);
            NSString *next = [conts count] ? conts[0][@"token"] : nil;
            NSMutableArray *items = [NSMutableArray array];
            int pos = 0;
            for (NSDictionary *v in vids) {
                NSString *vid = v[@"videoId"]; if (![vid length]) continue;
                NSString *title = TRTextOf(v[@"title"]) ?: @"";
                NSString *chan = TRTextOf(v[@"shortBylineText"]) ?: @"";
                NSString *cid = TRDig(v, @[@"shortBylineText", @"runs", @0, @"navigationEndpoint", @"browseEndpoint", @"browseId"]) ?: @"";
                [items addObject:@{ @"kind": @"youtube#playlistItem",
                    @"snippet": @{ @"title": title, @"channelTitle": chan, @"channelId": cid, @"playlistId": pid, @"position": @(pos++),
                                   @"resourceId": @{ @"kind": @"youtube#video", @"videoId": vid },
                                   @"thumbnails": TRThumbSet(TRDig(v, @[@"thumbnail", @"thumbnails"]), vid) },
                    @"contentDetails": @{ @"videoId": vid } }];
            }
            NSLog(@"[TubeReplacer] bridge v3 playlistItems: %lu item(s), next=%@", (unsigned long)[items count], next ? @"yes" : @"no");
            NSMutableDictionary *res = [@{ @"kind": @"youtube#playlistItemListResponse", @"items": items,
                                           @"pageInfo": @{ @"totalResults": @([items count]), @"resultsPerPage": @([items count]) } } mutableCopy];
            if (next) res[@"nextPageToken"] = next;
            finish([res autorelease]);
        });
        return YES;
    }

    if (([resource isEqualToString:@"playlists"] && [q[@"id"] length]) || ([resource isEqualToString:@"channels"] && [q[@"id"] length])) {
        BOOL isPlaylist = [resource isEqualToString:@"playlists"];
        NSArray *ids = [q[@"id"] componentsSeparatedByString:@","];
        NSMutableArray *items = [NSMutableArray array];
        dispatch_group_t g = dispatch_group_create();
        NSObject *lock = [[[NSObject alloc] init] autorelease];
        for (NSString *rid in ids) {
            dispatch_group_enter(g);
            NSString *bid = isPlaylist ? [rid hasPrefix:@"VL"] ? rid : [@"VL" stringByAppendingString:rid] : rid;
            TRPostInnerTube(@"browse", @{ @"browseId": bid }, ^(NSDictionary *j, NSInteger code, NSError *err) {
                if (j && code < 400) {
                    NSDictionary *item = nil;
                    if (isPlaylist) {
                        id md = TRDig(j, @[@"metadata", @"playlistMetadataRenderer"]);
                        NSString *title = [md isKindOfClass:[NSDictionary class]] ? md[@"title"] : nil;
                        NSString *desc = [md isKindOfClass:[NSDictionary class]] ? md[@"description"] : nil;
                        NSMutableArray *vids = [NSMutableArray array]; TRCollectKey(j, @"playlistVideoRenderer", vids, 0);
                        NSString *thumbVid = [vids count] ? vids[0][@"videoId"] : nil;
                        id header = TRFindKey(j, @"playlistHeaderRenderer", 0);
                        NSString *count = header ? TRTextOf(header[@"numVideosText"]) : nil;
                        if (!count) { id st = TRFindKey(j, @"stats", 0); if ([st isKindOfClass:[NSArray class]] && [st count]) count = TRTextOf(st[0]); }
                        NSString *owner = header ? TRTextOf(header[@"ownerText"]) : nil;
                        item = @{ @"kind": @"youtube#playlist", @"id": rid,
                                  @"snippet": @{ @"title": title ?: @"", @"description": desc ?: @"", @"channelTitle": owner ?: @"",
                                                 @"thumbnails": TRThumbSet(nil, thumbVid) },
                                  @"contentDetails": @{ @"itemCount": @(TRParseCount(count) ?: (long long)[vids count]) } };
                    } else {
                        id md = TRDig(j, @[@"metadata", @"channelMetadataRenderer"]);
                        NSString *title = [md isKindOfClass:[NSDictionary class]] ? md[@"title"] : nil;
                        NSString *desc = [md isKindOfClass:[NSDictionary class]] ? md[@"description"] : nil;
                        NSArray *av = [md isKindOfClass:[NSDictionary class]] ? TRDig(md, @[@"avatar", @"thumbnails"]) : nil;
                        id subs = TRFindKey(j, @"subscriberCountText", 0);
                        NSString *subText = subs ? TRTextOf(subs) : nil;
                        if (!subText) {
                            NSMutableArray *rows = [NSMutableArray array]; TRCollectKey(j, @"metadataParts", rows, 0);
                            for (id parts in rows) for (id p in ([parts isKindOfClass:[NSArray class]] ? parts : @[])) {
                                NSString *t = TRTextOf(p[@"text"]);
                                if ([t rangeOfString:@"subscriber"].location != NSNotFound) subText = t;
                            }
                        }
                        NSString *uploads = [rid hasPrefix:@"UC"] ? [@"UU" stringByAppendingString:[rid substringFromIndex:2]] : @"";
                        item = @{ @"kind": @"youtube#channel", @"id": rid,
                                  @"snippet": @{ @"title": title ?: @"", @"description": desc ?: @"", @"thumbnails": TRThumbSet(av, nil) },
                                  @"statistics": @{ @"subscriberCount": @(TRParseCount(subText)) },
                                  @"contentDetails": @{ @"relatedPlaylists": @{ @"uploads": uploads } } };
                    }
                    @synchronized (lock) { [items addObject:item]; }
                }
                dispatch_group_leave(g);
            });
        }
        dispatch_group_notify(g, dispatch_get_global_queue(0, 0), ^{
            NSLog(@"[TubeReplacer] bridge v3 %@: %lu item(s) for %@", resource, (unsigned long)[items count], q[@"id"]);
            finish(@{ @"kind": isPlaylist ? @"youtube#playlistListResponse" : @"youtube#channelListResponse", @"items": items,
                      @"pageInfo": @{ @"totalResults": @([items count]), @"resultsPerPage": @([items count]) } });
            dispatch_release(g);
        });
        return YES;
    }

    if ([resource isEqualToString:@"subscriptions"] || ([resource isEqualToString:@"activities"] && ![q[@"home"] isEqualToString:@"true"])
        || ([resource isEqualToString:@"playlists"] && [q[@"mine"] length]) || ([resource isEqualToString:@"channels"] && ([q[@"mine"] length] || [q[@"forUsername"] length]))) {
        NSLog(@"[TubeReplacer] bridge v3 %@: not available signed-out -> empty list", resource);
        finish(@{ @"kind": @"youtube#listResponse", @"items": @[] });
        return YES;
    }
    return NO;
}

// strings (printable, 16+ chars) of a protobuf message, searched through nested messages
static void TRProtoStrings(NSData *d, NSMutableArray *out, int depth) {
    const uint8_t *b = [d bytes]; NSUInteger n = [d length], i = 0;
    while (i < n) {
        uint64_t key = 0; int sh = 0;
        while (i < n) { uint8_t c = b[i++]; key |= (uint64_t)(c & 0x7f) << sh; sh += 7; if (!(c & 0x80)) break; }
        int wt = key & 7;
        if (wt == 0) { while (i < n && (b[i++] & 0x80)); }
        else if (wt == 1) i += 8;
        else if (wt == 5) i += 4;
        else if (wt == 2) {
            uint64_t len = 0; sh = 0;
            while (i < n) { uint8_t c = b[i++]; len |= (uint64_t)(c & 0x7f) << sh; sh += 7; if (!(c & 0x80)) break; }
            if (i + len > n) return;
            BOOL printable = len >= 16;
            for (uint64_t k = 0; k < len && printable; k++) if (b[i + k] < 0x20 || b[i + k] > 0x7e) printable = NO;
            if (printable) { NSString *t = [[[NSString alloc] initWithBytes:b + i length:(NSUInteger)len encoding:NSASCIIStringEncoding] autorelease]; if (t) [out addObject:t]; }
            else if (depth < 4 && len > 2) TRProtoStrings([d subdataWithRange:NSMakeRange(i, (NSUInteger)len)], out, depth + 1);
            i += len;
        } else return;
    }
}
// Returns YES if handled (the original must then NOT be called).
static BOOL TRBridgeIntercept(id service, NSURLRequest *httpReq, id parser, void (^deliver)(id), void (^fail)(NSError *)) {
    TRRememberUserAuth(service);
    if (!TRBridgeEnabled()) return NO;
    NSString *endpoint = TREndpointFromURL([httpReq URL]);
    if (!endpoint) {
        NSURL *u = [httpReq URL];
        if ([[u path] hasSuffix:@"/youtube/v3/activities"] && [[u query] rangeOfString:@"home=true"].location != NSNotFound && parser) {
            Class rc = TRProtoClassOfParser(parser);
            if (rc) {
                NSLog(@"[TubeReplacer] bridge: v3 home activities -> InnerTube (%@)", NSStringFromClass(rc));
                void (^d1)(id) = [deliver copy]; void (^f1)(NSError *) = [fail copy]; id p1 = [parser retain];
                TRRunV3Activities(rc, p1, ^(id result, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{ if (result) d1(result); else f1(error ?: TRError(305, @"Request failed.")); [d1 release]; [f1 release]; [p1 release]; });
                });
                return YES;
            }
        }
        if ([[u path] rangeOfString:@"/youtube/v3/"].location != NSNotFound && parser) {
            Class rc0 = TRProtoClassOfParser(parser);
            if (rc0) {
                void (^d2)(id) = [deliver copy]; void (^f2)(NSError *) = [fail copy]; id p2 = [parser retain];
                BOOL took = TRBridgeV3(u, rc0, p2, ^(id result, NSError *error) {
                    dispatch_async(dispatch_get_main_queue(), ^{ if (result) d2(result); else f2(error ?: TRError(305, @"Request failed.")); [d2 release]; [f2 release]; [p2 release]; });
                });
                if (took) return YES;
                [d2 release]; [f2 release]; [p2 release];
            }
            Class rc = TRProtoClassOfParser(parser);
            static NSMutableSet *dumpedClasses = nil;
            if (!dumpedClasses) dumpedClasses = [[NSMutableSet alloc] init];
            if (rc && ![dumpedClasses containsObject:NSStringFromClass(rc)]) {
                [dumpedClasses addObject:NSStringFromClass(rc)];
                TRDumpSchema(rc, 0, @"v3 ", [NSMutableSet set]);
            }
        }
        NSLog(@"[TubeReplacer] bridge: not InnerTube, passing through: %@", u); return NO;
    }
    if ([endpoint isEqualToString:@"browse/edit_playlist"]) {
        // add to / remove from a playlist or Watch later: replay on the web, answer with its result
        Class rq = NSClassFromString(@"YTIPlaylistEditActionRequest");
        Class rs = NSClassFromString(@"YTIPlaylistEditActionResponse");
        NSMutableDictionary *wb = [NSMutableDictionary dictionary];
        NSData *rb = [httpReq HTTPBody];
        if (rq && [rb length]) @try { [wb addEntriesFromDictionary:TRDecodeMessage(rb, rq, 0)]; } @catch (NSException *e) {}
        [wb removeObjectForKey:@"context"];
        NSLog(@"[TubeReplacer] bridge edit_playlist: app request %@", wb);
        NSMutableArray *wacts = [NSMutableArray array];
        for (id a in ([wb[@"actions"] isKindOfClass:[NSArray class]] ? wb[@"actions"] : @[])) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *m = [NSMutableDictionary dictionaryWithDictionary:a];
            NSString *an = nil;
            if ([a[@"addedVideoId"] length]) an = @"ACTION_ADD_VIDEO";
            else if ([a[@"removedVideoId"] length] && [a[@"setVideoId"] length]) an = @"ACTION_REMOVE_VIDEO";
            else if ([a[@"removedVideoId"] length]) an = @"ACTION_REMOVE_VIDEO_BY_VIDEO_ID";
            else if ([a[@"movedSetVideoIdSuccessor"] length] || ([a[@"setVideoId"] length])) an = @"ACTION_MOVE_VIDEO_AFTER";
            else if ([a[@"playlistName"] length]) an = @"ACTION_SET_PLAYLIST_NAME";
            else if ([a[@"playlistDescription"] length]) an = @"ACTION_SET_PLAYLIST_DESCRIPTION";
            if (an) m[@"action"] = an;
            [wacts addObject:m];
        }
        if ([wacts count]) wb[@"actions"] = wacts;
        void (^d3)(id) = [deliver copy]; void (^f3)(NSError *) = [fail copy]; id p3 = [parser retain];
        TRPostInnerTube(@"browse/edit_playlist", wb, ^(NSDictionary *wj, NSInteger wc, NSError *we) {
            NSLog(@"[TubeReplacer] bridge edit_playlist: http=%ld err=%@ keys=%@ status=%@", (long)wc, we, [wj allKeys], wj[@"status"]);
            id res = nil; NSError *pe = nil;
            if (wj && wc < 400 && rs) {
                // the web now answers with a snackbar command; the apps want the old success status
                NSMutableDictionary *wm = [[wj mutableCopy] autorelease];
                if (!wm[@"status"]) wm[@"status"] = @"STATUS_SUCCEEDED";
                res = TRParseJSONInto(wm, rs, p3, @"edit_playlist", &pe);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (res) d3(res);
                else f3((wc >= 400 || !wj) ? (we ?: TRError(309, @"Could not update the playlist.")) : (pe ?: TRError(309, @"Could not update the playlist.")));
                [d3 release]; [f3 release]; [p3 release];
            });
        });
        return YES;
    }
    Class respClass = parser ? TRProtoClassOfParser(parser) : TRResponseClassFor(service, endpoint);
    if (!respClass && !parser && [endpoint isEqualToString:@"comment/perform_comment_action"]) {
        // 11.x has no response class for votes: replay the like / dislike token on the web, answer with an empty message
        NSMutableArray *toks = [NSMutableArray array];
        TRProtoStrings([httpReq HTTPBody], toks, 0);
        NSLog(@"[TubeReplacer] bridge %@: %lu action token(s)", endpoint, (unsigned long)[toks count]);
        void (^dv)(id) = [deliver copy];
        NSString *key = [toks componentsJoinedByString:@"|"];
        static NSString *lastKey = nil; static NSDate *lastAt = nil;
        BOOL dup = [key isEqualToString:lastKey ?: @""] && lastAt && [[NSDate date] timeIntervalSinceDate:lastAt] < 1.5; // the app fires each tap twice
        [lastKey release]; lastKey = [key copy]; [lastAt release]; lastAt = [[NSDate date] retain];
        if ([toks count] && !dup) {
            TRPostInnerTube(@"comment/perform_comment_action", @{ @"actions": toks }, ^(NSDictionary *wj, NSInteger wc, NSError *we) {
                NSLog(@"[TubeReplacer] bridge comment vote: http=%ld err=%@", (long)wc, we);
            });
        }
        dispatch_async(dispatch_get_main_queue(), ^{ dv([NSData data]); [dv release]; });
        return YES;
    }
    if (!respClass && !parser) {
        // e.g. config: the app parses the bytes itself; an empty message means "no changes"
        NSLog(@"[TubeReplacer] bridge %@: no response class, answering with an empty message", endpoint);
        void (^d0)(id) = [deliver copy];
        dispatch_async(dispatch_get_main_queue(), ^{ d0([NSData data]); [d0 release]; });
        return YES;
    }
    if (!respClass) { NSLog(@"[TubeReplacer] bridge %@: no response class (parser %@), passing through", endpoint, [parser class]); return NO; }
    NSLog(@"[TubeReplacer] bridge %@: intercepted (%@)", endpoint, NSStringFromClass(respClass));

    void (^d)(id) = [deliver copy];
    void (^f)(NSError *) = [fail copy];
    id svc = [service retain];
    id par = [parser retain];
    NSURLRequest *hr = [httpReq retain];

    void (^finish)(id, NSError *) = ^(id result, NSError *error) {
        if (result) d(result); else f(error ?: TRError(305, @"Request failed."));
        [d release]; [f release]; [svc release]; [par release]; [hr release];
    };

    TRRememberUserAuth(svc); if (!gTRGauth) TRRememberIdentity(svc, nil);
    if ([endpoint isEqualToString:@"account/accounts_list"] && !TRAccountParams()) {
        // nothing to answer with: an error is safe, an empty list crashes the app (it reads item 0)
        NSLog(@"[TubeReplacer] bridge accounts_list: no signed-in account found (gauth=%@ userAuth=%@)", gTRGauth, gTRUserAuth);
        dispatch_async(dispatch_get_main_queue(), ^{ finish(nil, TRError(307, @"Accounts unavailable.")); });
        return YES;
    }
    if ([endpoint isEqualToString:@"account/accounts_list"] && TRAccountParams()) {
        // the signed-in account, answered locally: an empty list crashes the app (it reads item 0)
        NSDictionary *p = TRAccountParams();
        NSLog(@"[TubeReplacer] accounts_list: account parameter keys: %@", [p allKeys]);
        TRPostInnerTube(@"account/accounts_list", @{}, ^(NSDictionary *aj, NSInteger ac, NSError *ae) {
        NSString *wName = nil, *wByline = nil, *wPhoto = nil;
        @try {
            NSMutableArray *items = [NSMutableArray array];
            TRCollectKey(aj, @"accountItem", items, 0);
            NSLog(@"[TubeReplacer] accounts_list: web http=%ld accountItems=%lu", (long)ac, (unsigned long)[items count]);
            NSDictionary *pick = nil;
            for (NSDictionary *it in items) if ([it isKindOfClass:[NSDictionary class]] && [it[@"isSelected"] boolValue]) { pick = it; break; }
            if (!pick && [items count]) pick = items[0];
            wName = TRTextOf(pick[@"accountName"]); wByline = TRTextOf(pick[@"accountByline"]);
            NSArray *th = TRDig(pick, @[@"accountPhoto", @"thumbnails"]);
            if ([th isKindOfClass:[NSArray class]] && [th count]) wPhoto = [th lastObject][@"url"];
        } @catch (NSException *e) {}
        if ([wName length] && !gTRAccountName) gTRAccountName = [wName copy];
        NSString *name = wName ?: p[@"fullName"] ?: p[@"userEmail"] ?: @"Account";
        NSMutableDictionary *item = [@{
            @"accountName": @{ @"simpleText": name },
            @"accountByline": @{ @"simpleText": wByline ?: p[@"userEmail"] ?: @"" },
            @"isSelected": @YES,
            @"serviceEndpoint": @{ @"selectActiveIdentityEndpoint": @{ @"supportedTokens": @[] } }
        } mutableCopy];
        NSString *photo = wPhoto ?: p[@"avatar"];
        if ([photo length]) item[@"accountPhoto"] = @{ @"thumbnails": @[ @{ @"url": photo, @"width": @88, @"height": @88 } ] };
        if ([p[@"PAGE_ID"] length]) item[@"serviceEndpoint"] = @{ @"selectActiveIdentityEndpoint": @{ @"supportedTokens": @[ @{ @"pageIdToken": @{ @"pageId": p[@"PAGE_ID"] } } ] } };
        NSDictionary *json = @{ @"contents": @[ @{ @"accountSectionListRenderer": @{ @"contents": @[ @{ @"accountItemSectionRenderer": @{ @"contents": @[ @{ @"accountItem": item } ] } } ] } } ] };
        NSError *aerr = nil;
        id ares = TRParseJSONInto(json, respClass, par, @"accounts_list(local)", &aerr);
        if ([ares isKindOfClass:[NSData class]]) @try {
            NSError *pe = nil;
            id back = [respClass performSelector:NSSelectorFromString(@"parseFromData:error:") withObject:ares withObject:(id)&pe];
            id sec = [back respondsToSelector:@selector(itemSection)] ? [back performSelector:@selector(itemSection)] : nil;
            NSUInteger n = [[back performSelector:@selector(accountItemRenderers)] count];
            NSLog(@"[TubeReplacer] bridge accounts_list(local): self-check parse=%@ err=%@ itemSection=%@ items=%lu", back ? @"ok" : @"nil", pe, sec ? NSStringFromClass([sec class]) : @"nil", (unsigned long)n);
            // the app reads item 0 of this list unguarded, so never hand over one without it
            if (!back || !sec || !n) { ares = nil; aerr = TRError(307, @"Accounts unavailable."); }
        } @catch (NSException *e) { NSLog(@"[TubeReplacer] bridge accounts_list(local): self-check threw %@", e); }
        dispatch_async(dispatch_get_main_queue(), ^{ finish(ares, aerr); });
        });
        return YES;
    }

    if (TRIsReadEndpoint(endpoint) || ([endpoint hasPrefix:@"upload/"] && ![endpoint isEqualToString:@"upload/feedback"]) || [endpoint hasPrefix:@"video_manager/"] || [endpoint isEqualToString:@"player"] || [endpoint hasPrefix:@"comment/"] || [endpoint hasPrefix:@"comments/"]) {
        TRBridgeRun(svc, hr, par, endpoint, [[finish copy] autorelease]);
    } else if ([endpoint hasPrefix:@"subscription/"] || [endpoint hasPrefix:@"like/"]) {
        // real writes: replay them against the web InnerTube, then answer the app with an empty message
        NSMutableDictionary *wb = [NSMutableDictionary dictionary];
        Class rq = TRRequestClassFor(svc, endpoint);
        NSData *rb = [hr HTTPBody];
        if (rq && [rb length]) @try { [wb addEntriesFromDictionary:TRDecodeMessage(rb, rq, 0)]; } @catch (NSException *e) {}
        [wb removeObjectForKey:@"context"];
        NSLog(@"[TubeReplacer] bridge %@: forwarding %@", endpoint, wb);
        TRPostInnerTube(endpoint, wb, ^(NSDictionary *wj, NSInteger wc, NSError *we) {
            NSLog(@"[TubeReplacer] bridge %@: http=%ld err=%@ keys=%@", endpoint, (long)wc, we, [wj allKeys]);
            id empty = nil;
            if (!par) empty = [NSData data];
            else @try { empty = [par performSelector:@selector(parse:) withObject:[NSData data]]; } @catch (NSException *e) {}
            dispatch_async(dispatch_get_main_queue(), ^{ finish(empty, empty ? nil : TRError(306, @"Unsupported request.")); });
        });
    } else if ([endpoint isEqualToString:@"navigation/resolve_url"] && ({
        // the upload flow checks the account's identity by resolving youtube.com/upload?local_path=...; the server used to answer with
        // the upload endpoint (or the channel creation form). An empty answer shows "could not load channel information".
        NSMutableDictionary *rb2 = [NSMutableDictionary dictionary];
        Class rq2 = TRRequestClassFor(svc, endpoint);
        NSData *rd2 = [hr HTTPBody];
        if (rq2 && [rd2 length]) @try { [rb2 addEntriesFromDictionary:TRDecodeMessage(rd2, rq2, 0)]; } @catch (NSException *e) {}
        NSString *ru = rb2[@"url"] ?: rb2[@"URL"];
        NSLog(@"[TubeReplacer] bridge navigation/resolve_url: %@", ru);
        [ru rangeOfString:@"youtube.com/upload"].location != NSNotFound;
    })) {
        NSError *rerr = nil;
        // upload/metadata?client_video_id=<asset url> -> the metadata editor for that new video; anything else keeps the upload picker
        NSString *ru2 = nil;
        { NSMutableDictionary *rb3 = [NSMutableDictionary dictionary]; Class rq3 = TRRequestClassFor(svc, endpoint); NSData *rd3 = [hr HTTPBody];
          if (rq3 && [rd3 length]) @try { [rb3 addEntriesFromDictionary:TRDecodeMessage(rd3, rq3, 0)]; } @catch (NSException *e) {}
          ru2 = rb3[@"url"] ?: rb3[@"URL"]; }
        NSRange cr = [ru2 rangeOfString:@"client_video_id="];
        NSDictionary *rep = cr.location != NSNotFound
            ? @{ @"endpoint": @{ @"editVideoMetadataEndpoint": @{ @"clientVideoId": [ru2 substringFromIndex:cr.location + cr.length] } } }
            : @{ @"endpoint": @{ @"uploadEndpoint": @{ @"hack": @YES } } };
        id rres = TRParseJSONInto(rep, respClass, par, @"resolve_url(upload)", &rerr);
        NSLog(@"[TubeReplacer] bridge navigation/resolve_url: upload identity check answered locally (%@)", rres ? @"ok" : rerr);
        dispatch_async(dispatch_get_main_queue(), ^{ finish(rres, rres ? nil : rerr); });
    } else {
        // telemetry, configuration, account writes, ...: nothing to fetch. Answer with an
        // empty message so the app carries on instead of waiting on a dead server.
        NSLog(@"[TubeReplacer] bridge %@: not an InnerTube read endpoint -> empty response", endpoint);
        id empty = nil;
        if (!par) empty = [NSData data];
        else @try { empty = [par performSelector:@selector(parse:) withObject:[NSData data]]; } @catch (NSException *e) {}
        dispatch_async(dispatch_get_main_queue(), ^{ finish(empty, empty ? nil : TRError(306, @"Unsupported request.")); });
    }
    return YES;
}

#pragma mark - Hooks (installed only for the methods that exist)

static void (*orig_data)(id, SEL, id, id, id, id, id, BOOL);          // ...parser:dataBlock:errorBlock:retryEnabled:   (10.x / 11.x)
static void (*orig_resp_retry)(id, SEL, id, id, id, id, id, BOOL);    // ...parser:responseBlock:errorBlock:retryEnabled: (2.9.3)
static void (*orig_resp)(id, SEL, id, id, id, id, id);                // ...parser:responseBlock:errorBlock:   (2.3.1)

// IMPORTANT: the block parameters are declared `id`, so capturing them in another block only
// *retains* them, and retaining a stack block does nothing: it would be gone by the time the
// network reply arrives (the callback would then message freed stack memory). Every block that
// must outlive the hooked call is therefore explicitly copied to the heap first. The copies are
// then retained by the blocks that capture them (and released with them).
static id TRHeapBlock(id block) { return block ? [[block copy] autorelease] : nil; }

static void TRDeliverViaService(id svc, NSString *sel, id block, id obj) {
    ((void (*)(id, SEL, id, id))objc_msgSend)(svc, NSSelectorFromString(sel), block, obj);
}

static void tr_data(id self_, SEL _cmd, id httpReq, id apiaryReq, id parser, id dataBlock, id errorBlock, BOOL retry) {
    id db = TRHeapBlock(dataBlock), eb = TRHeapBlock(errorBlock);
    BOOL handled = TRBridgeIntercept(self_, httpReq, parser,
        ^(id result) { if (db) ((void (^)(id))db)(result); },
        ^(NSError *e) { if (eb) ((void (^)(id))eb)(e); });
    if (!handled) orig_data(self_, _cmd, httpReq, apiaryReq, parser, dataBlock, errorBlock, retry);
}

static void tr_resp_retry(id self_, SEL _cmd, id httpReq, id apiaryReq, id parser, id responseBlock, id errorBlock, BOOL retry) {
    id rb = TRHeapBlock(responseBlock), eb = TRHeapBlock(errorBlock);
    BOOL handled = TRBridgeIntercept(self_, httpReq, parser,
        ^(id result) { TRDeliverViaService(self_, @"performResponseBlock:response:", rb, result); },
        ^(NSError *e) { TRDeliverViaService(self_, @"performErrorBlock:error:", eb, e); });
    if (!handled) orig_resp_retry(self_, _cmd, httpReq, apiaryReq, parser, responseBlock, errorBlock, retry);
}

// 12.x: YTBaseInnerTubeService hands the app's protobuf request over as a plain NSURLRequest and
// wants the raw response bytes back through the dataBlock (its parser runs afterwards).
static void (*orig_v12)(id, SEL, id, id, id, id, BOOL);
static void tr_v12(id self_, SEL _cmd, id httpReq, id identity, id dataBlock, id errorBlock, BOOL retry) {
    id db = TRHeapBlock(dataBlock), eb = TRHeapBlock(errorBlock);
    TRRememberIdentity(self_, identity);
    BOOL handled = TRBridgeIntercept(self_, httpReq, nil,
        ^(id result) { if (db) ((void (^)(id))db)(result); },
        ^(NSError *e) { if (eb) ((void (^)(id))eb)(e); });
    if (!handled) orig_v12(self_, _cmd, httpReq, identity, dataBlock, errorBlock, retry);
}

static void tr_resp(id self_, SEL _cmd, id httpReq, id apiaryReq, id parser, id responseBlock, id errorBlock) {
    id rb = TRHeapBlock(responseBlock), eb = TRHeapBlock(errorBlock);
    BOOL handled = TRBridgeIntercept(self_, httpReq, parser,
        ^(id result) { TRDeliverViaService(self_, @"performResponseBlock:response:", rb, result); },
        ^(NSError *e) { TRDeliverViaService(self_, @"performErrorBlock:error:", eb, e); });
    if (!handled) orig_resp(self_, _cmd, httpReq, apiaryReq, parser, responseBlock, errorBlock);
}

// 11.x: any YTIdentity whose authorization gets read is a candidate account (the active one is read on every request)
static id (*orig_ytid_authorization)(id, SEL);
static id tr_ytid_authorization(id self_, SEL _cmd) {
    id az = orig_ytid_authorization(self_, _cmd);
    @try {
        id sso = [az respondsToSelector:@selector(identity)] ? [az performSelector:@selector(identity)] : nil;
        id g = [sso respondsToSelector:@selector(auth)] ? [sso performSelector:@selector(auth)] : nil;
        if (g && g != gTRGauth && [g respondsToSelector:@selector(parameters)]) {
            id old = gTRGauth; gTRGauth = [g retain]; [old release];
            NSLog(@"[TubeReplacer] auth captured from %@", [self_ class]);
        }
    } @catch (NSException *e) {}
    return az;
}

// 11.x: the identity the app signs its own requests with is read through SSOIdentityPrivate.auth on every call
static id (*orig_sso_auth)(id, SEL);
static id tr_sso_auth(id self_, SEL _cmd) {
    id g = orig_sso_auth(self_, _cmd);
    @try {
        if (g && g != gTRGauth && [g respondsToSelector:@selector(parameters)] && [[g performSelector:@selector(parameters)] count]) {
            id old = gTRGauth; gTRGauth = [g retain]; [old release];
            NSLog(@"[TubeReplacer] auth captured from SSOIdentityPrivate (%@)", [self_ respondsToSelector:@selector(userEmail)] ? [self_ performSelector:@selector(userEmail)] : @"?");
        }
    } @catch (NSException *e) {}
    return g;
}
static BOOL gTRFetchingName = NO;
static void TRFetchAccountName(void) {
    if (gTRAccountName || gTRFetchingName) return;
    gTRFetchingName = YES;
    TRPostInnerTube(@"account/accounts_list", @{}, ^(NSDictionary *aj, NSInteger ac, NSError *ae) {
        @try {
            NSMutableArray *items = [NSMutableArray array];
            TRCollectKey(aj, @"accountItem", items, 0);
            NSDictionary *pick = nil;
            for (NSDictionary *it in items) if ([it isKindOfClass:[NSDictionary class]] && [it[@"isSelected"] boolValue]) { pick = it; break; }
            if (!pick && [items count]) pick = items[0];
            NSString *n = TRTextOf(pick[@"accountName"]);
            if ([n length]) { gTRAccountName = [n copy]; NSLog(@"[TubeReplacer] account name: %@", n); }
        } @catch (NSException *e) {}
        gTRFetchingName = NO;
    });
}
static id (*orig_sso_fullName)(id, SEL);
static id tr_sso_fullName(id self_, SEL _cmd) {
    id n = orig_sso_fullName(self_, _cmd);
    if ([n isKindOfClass:[NSString class]] && [n length]) return n;
    if (gTRAccountName) return gTRAccountName;
    dispatch_async(dispatch_get_main_queue(), ^{ TRFetchAccountName(); });
    return n;
}
static void (*orig_sso_setAuth)(id, SEL, id);
static void tr_sso_setAuth(id self_, SEL _cmd, id g) {
    orig_sso_setAuth(self_, _cmd, g);
    @try {
        if (g && [g respondsToSelector:@selector(parameters)] && [[g performSelector:@selector(parameters)] count] && !gTRGauth) {
            gTRGauth = [g retain];
            NSLog(@"[TubeReplacer] auth captured from SSOIdentityPrivate setAuth");
        }
    } @catch (NSException *e) {}
}


// ======================================================================================================
// Comments for 2.3.1 - 10.x: those apps read comments from the (long gone) "distiller" service. Intercept its list
// requests and answer them with YTDistillerPage objects built from the web's comments.
// ======================================================================================================
static const char kDistillerTag;

static NSDate *TRDateFromAgo(NSString *t) {
    NSString *l = [[t lowercaseString] stringByReplacingOccurrencesOfString:@"(edited)" withString:@""];
    NSScanner *sc = [NSScanner scannerWithString:l]; int n = 0;
    [sc scanUpToCharactersFromSet:[NSCharacterSet decimalDigitCharacterSet] intoString:NULL];
    if (![sc scanInt:&n]) n = 1;
    double unit = 86400;
    if ([l rangeOfString:@"second"].location != NSNotFound) unit = 1;
    else if ([l rangeOfString:@"minute"].location != NSNotFound) unit = 60;
    else if ([l rangeOfString:@"hour"].location != NSNotFound) unit = 3600;
    else if ([l rangeOfString:@"week"].location != NSNotFound) unit = 7 * 86400;
    else if ([l rangeOfString:@"month"].location != NSNotFound) unit = 30 * 86400;
    else if ([l rangeOfString:@"year"].location != NSNotFound) unit = 365 * 86400;
    return [NSDate dateWithTimeIntervalSinceNow:-(double)n * unit];
}
static NSMutableDictionary *TRDistillerReplyTokens(void) {
    static NSMutableDictionary *m; static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [[NSMutableDictionary alloc] init]; });
    return m;
}

static id TRDistillerSegments(NSString *text) {
    Class seg = NSClassFromString(@"YTDistillerCommentSegment");
    id s0 = [seg alloc];
    s0 = ((id (*)(id, SEL, int, id, id))objc_msgSend)(s0, @selector(initWithType:URL:text:), 0, nil, text ?: @"");
    return s0 ? @[ [s0 autorelease] ] : @[];
}
// one web comment renderer (as built by TRCommentRendererFrom) -> a distiller comment / top comment
static id TRDistillerComment(NSDictionary *cr, BOOL top, NSArray *replies, unsigned nrep) {
    NSString *cid = cr[@"commentId"] ?: @"";
    NSString *name = TRTextOf(cr[@"authorText"]) ?: @"";
    NSString *text = TRTextOf(cr[@"contentText"]) ?: @"";
    NSString *when = TRTextOf(cr[@"publishedTimeText"]) ?: @"";
    NSString *av = TRDig(cr, @[@"authorThumbnail", @"thumbnails", @0, @"url"]);
    NSURL *avURL = [av length] ? [NSURL URLWithString:av] : nil;
    NSString *chan = TRDig(cr, @[@"authorEndpoint", @"browseEndpoint", @"browseId"]);
    NSURL *authURL = [chan length] ? [NSURL URLWithString:[@"https://www.youtube.com/channel/" stringByAppendingString:chan]] : nil;
    NSDate *date = TRDateFromAgo(when);
    unsigned likes = (unsigned)[cr[@"likeCount"] intValue];
    Class topCls = NSClassFromString(@"YTDistillerTopComment"), cls = NSClassFromString(@"YTDistillerComment");
    id o = nil;
    if (top) {
        SEL full = @selector(initWithCommentID:authorName:authorURL:accessText:accessType:commentSegments:publishTime:avatarURL:canEdit:canLike:liked:likeCount:canReply:replies:numReplies:resharedComment:);
        SEL full2 = @selector(initWithCommentID:authorName:authorURL:authorID:accessText:accessType:commentSegments:publishTime:avatarURL:canEdit:canLike:liked:likeCount:canReply:replies:numReplies:resharedComment:); // 10.2x
        SEL old = @selector(initWithCommentID:authorName:commentText:publishTime:avatarURL:canLike:replies:numReplies:);
        if ([topCls instancesRespondToSelector:full2]) {
            o = ((id (*)(id, SEL, id, id, id, id, id, int, id, id, id, BOOL, BOOL, BOOL, unsigned, BOOL, id, unsigned, id))objc_msgSend)(
                [topCls alloc], full2, cid, name, authURL, chan ?: @"", @"", 0, TRDistillerSegments(text), date, avURL, NO, NO, NO, likes, NO, replies ?: @[], nrep, nil);
        } else if ([topCls instancesRespondToSelector:full]) {
            o = ((id (*)(id, SEL, id, id, id, id, int, id, id, id, BOOL, BOOL, BOOL, unsigned, BOOL, id, unsigned, id))objc_msgSend)(
                [topCls alloc], full, cid, name, authURL, @"", 0, TRDistillerSegments(text), date, avURL, NO, NO, NO, likes, NO, replies ?: @[], nrep, nil);
        } else if ([topCls instancesRespondToSelector:old]) {
            o = ((id (*)(id, SEL, id, id, id, id, id, BOOL, id, unsigned))objc_msgSend)(
                [topCls alloc], old, cid, name, text, date, avURL, NO, replies ?: @[], nrep);
        }
    } else {
        SEL full = @selector(initWithCommentID:commentType:authorName:authorURL:accessText:commentSegments:publishTime:avatarURL:canEdit:liked:likeCount:canReply:);
        SEL full2 = @selector(initWithCommentID:commentType:authorName:authorURL:authorID:accessText:commentSegments:publishTime:avatarURL:canEdit:liked:likeCount:canReply:); // 10.2x
        SEL old = @selector(initWithCommentID:authorName:commentText:publishTime:avatarURL:canLike:);
        if ([cls instancesRespondToSelector:full2]) {
            o = ((id (*)(id, SEL, id, int, id, id, id, id, id, id, id, BOOL, BOOL, unsigned, BOOL))objc_msgSend)(
                [cls alloc], full2, cid, 1, name, authURL, chan ?: @"", @"", TRDistillerSegments(text), date, avURL, NO, NO, likes, NO);
        } else if ([cls instancesRespondToSelector:full]) {
            o = ((id (*)(id, SEL, id, int, id, id, id, id, id, id, BOOL, BOOL, unsigned, BOOL))objc_msgSend)(
                [cls alloc], full, cid, 1, name, authURL, @"", TRDistillerSegments(text), date, avURL, NO, NO, likes, NO);
        } else if ([cls instancesRespondToSelector:old]) {
            o = ((id (*)(id, SEL, id, id, id, id, id, BOOL))objc_msgSend)([cls alloc], old, cid, name, text, date, avURL, NO);
        }
    }
    return [o autorelease];
}
static id TRDistillerPage(NSArray *entries, NSString *next) {
    Class pc = NSClassFromString(@"YTDistillerPage");
    id pg = [pc alloc];
    pg = ((id (*)(id, SEL, id, unsigned, unsigned, id, id, BOOL))objc_msgSend)(pg, @selector(initWithEntries:totalResults:entriesPerPage:nextToken:previousToken:canInsert:),
            entries, (unsigned)[entries count], (unsigned)[entries count], next, nil, NO);
    return [pg autorelease];
}

static void TRDistillerFetch(NSDictionary *tag, void (^ok)(id page), void (^fail)(NSError *err)) {
    NSString *kind = tag[@"kind"];
    if ([kind isEqualToString:@"replies"]) {
        NSString *tok = tag[@"token"] ?: TRDistillerReplyTokens()[tag[@"commentId"] ?: @""];
        if (![tok length]) { ok(TRDistillerPage(@[], nil)); return; }
        TRPostInnerTube(@"next", @{ @"continuation": tok }, ^(NSDictionary *rj, NSInteger rc, NSError *re) {
            if (!rj || rc >= 400) { fail(re ?: TRError(309, @"Could not load replies.")); return; }
            NSMutableArray *list = [NSMutableArray array]; NSString *next = nil;
            NSArray *cmds = rj[@"onResponseReceivedEndpoints"] ?: rj[@"onResponseReceivedCommands"] ?: rj[@"onResponseReceivedActions"];
            for (NSDictionary *c in ([cmds isKindOfClass:[NSArray class]] ? cmds : @[])) {
                NSArray *items = TRDig(c, @[@"appendContinuationItemsAction", @"continuationItems"]) ?: TRDig(c, @[@"reloadContinuationItemsCommand", @"continuationItems"]);
                for (id it in ([items isKindOfClass:[NSArray class]] ? items : @[])) {
                    NSString *tk = TRContinuationToken(it);
                    if (tk) { next = tk; continue; }
                    NSMutableDictionary *cr = TRCommentRendererFrom(it, rj, NULL, NULL);
                    id c2 = cr ? TRDistillerComment(cr, NO, nil, 0) : nil;
                    if (c2) [list addObject:c2];
                }
            }
            NSLog(@"[TubeReplacer] distiller replies: %lu", (unsigned long)[list count]);
            ok(TRDistillerPage(list, next));
        });
        return;
    }
    void (^page)(NSString *) = ^(NSString *tok) {
        TRPostInnerTube(@"next", @{ @"continuation": tok }, ^(NSDictionary *cj, NSInteger cc, NSError *ce) {
            if (!cj || cc >= 400) { fail(ce ?: TRError(309, @"Could not load comments.")); return; }
            NSString *next = nil;
            NSArray *threads = TRCommentThreadsIn(cj, &next);
            NSMutableArray *list = [NSMutableArray array];
            for (NSDictionary *th in threads) {
                NSDictionary *t = th[@"commentThreadRenderer"];
                NSDictionary *cr = TRDig(t, @[@"comment", @"commentRenderer"]);
                if (!cr) continue;
                NSString *rtok = TRDig(t, @[@"replies", @"commentRepliesRenderer", @"_replyToken"]);
                unsigned nrep = [TRTextOf(t[@"totalRepliesCountLabel"]) intValue];
                if ([rtok length] && cr[@"commentId"]) { @synchronized (TRDistillerReplyTokens()) { TRDistillerReplyTokens()[cr[@"commentId"]] = rtok; } if (!nrep) nrep = 1; }
                id o = TRDistillerComment(cr, YES, @[], nrep);
                if (o) [list addObject:o];
            }
            NSLog(@"[TubeReplacer] distiller comments: %lu threads, next=%@", (unsigned long)[list count], next ? @"yes" : @"no");
            ok(TRDistillerPage(list, next));
        });
    };
    if ([tag[@"token"] length]) { page(tag[@"token"]); return; }
    NSString *vid = tag[@"videoId"];
    if (![vid length]) { ok(TRDistillerPage(@[], nil)); return; }
    TRPostInnerTube(@"next", @{ @"videoId": vid }, ^(NSDictionary *nj, NSInteger nc, NSError *ne) {
        NSString *tok = nj ? TRFindCommentsToken(nj, 0) : nil;
        NSLog(@"[TubeReplacer] distiller: comments token %@ (http=%ld)", tok ? @"found" : @"missing", (long)nc);
        if (!tok) { ok(TRDistillerPage(@[], nil)); return; }
        page(tok);
    });
}


// Writes (like / unlike / playlist edits / subscriptions) that reach the lower network layer without
// passing the InnerTube service hook: replay them on the web the same way.
static BOOL TRWriteEndpoint(NSURLRequest *req) {
    NSString *e = TREndpointFromURL([req URL]);
    if (!e) return NO;
    NSLog(@"[TubeReplacer] network layer: %@", e);
    return [e hasPrefix:@"like/"] || [e hasPrefix:@"subscription/"] || [e isEqualToString:@"browse/edit_playlist"];
}
%hook YTBaseNetworkService
- (void)performHTTPRequest:(id)request parser:(id)parser responseBlock:(id)responseBlock errorBlock:(id)errorBlock retryConfig:(id)retryConfig {
    if (majorVersion() >= 11 && TRWriteEndpoint(request)) {
        id rb = TRHeapBlock(responseBlock), eb = TRHeapBlock(errorBlock); id svc = self;
        if (TRBridgeIntercept(svc, request, parser, ^(id r) { TRDeliverViaService(svc, @"performResponseBlock:response:", rb, r); }, ^(NSError *e) { TRDeliverViaService(svc, @"performErrorBlock:error:", eb, e); })) return;
    }
    %orig;
}
- (void)performHTTPRequest:(id)request parser:(id)parser responseBlock:(id)responseBlock errorBlock:(id)errorBlock {
    if (majorVersion() >= 11 && TRWriteEndpoint(request)) {
        id rb = TRHeapBlock(responseBlock), eb = TRHeapBlock(errorBlock); id svc = self;
        if (TRBridgeIntercept(svc, request, parser, ^(id r) { TRDeliverViaService(svc, @"performResponseBlock:response:", rb, r); }, ^(NSError *e) { TRDeliverViaService(svc, @"performErrorBlock:error:", eb, e); })) return;
    }
    %orig;
}
- (void)performHTTPRequest:(id)request dataBlock:(id)dataBlock errorBlock:(id)errorBlock retryConfig:(id)retryConfig {
    if (majorVersion() >= 11 && TRWriteEndpoint(request)) {
        id db = TRHeapBlock(dataBlock), eb = TRHeapBlock(errorBlock);
        if (TRBridgeIntercept(self, request, nil, ^(id r) { if (db) ((void (^)(id))db)(r); }, ^(NSError *e) { if (eb) ((void (^)(id))eb)(e); })) return;
    }
    %orig;
}
- (void)performHTTPRequest:(id)request dataBlock:(id)dataBlock errorBlock:(id)errorBlock {
    if (majorVersion() >= 11 && TRWriteEndpoint(request)) {
        id db = TRHeapBlock(dataBlock), eb = TRHeapBlock(errorBlock);
        if (TRBridgeIntercept(self, request, nil, ^(id r) { if (db) ((void (^)(id))db)(r); }, ^(NSError *e) { if (eb) ((void (^)(id))eb)(e); })) return;
    }
    %orig;
}
%end

%group Distiller
%hook YTApiaryRequestFactory
// 10.x
- (id)requestForDistillerCommentsWithVideoID:(id)vid authentication:(id)auth sortBy:(int)sort linkedCommentID:(id)linked {
    id r = %orig;
    if (r) objc_setAssociatedObject(r, &kDistillerTag, @{ @"kind": @"comments", @"videoId": vid ?: @"" }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return r;
}
// 2.9.x
- (id)requestForDistillerCommentsWithVideoID:(id)vid authentication:(id)auth sortBy:(int)sort {
    id r = %orig;
    if (r) objc_setAssociatedObject(r, &kDistillerTag, @{ @"kind": @"comments", @"videoId": vid ?: @"" }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return r;
}
- (id)requestForDistillerRepliesWithCommentID:(id)cid authentication:(id)auth {
    id r = %orig;
    if (r) objc_setAssociatedObject(r, &kDistillerTag, @{ @"kind": @"replies", @"commentId": cid ?: @"" }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return r;
}
%end

%hook YTDistillerDataSource
- (id)generateNextRequestFromRequest:(id)req page:(id)page {
    NSDictionary *prev = req ? objc_getAssociatedObject(req, &kDistillerTag) : nil;
    id r = %orig;
    NSString *tok = nil;
    @try { tok = [page respondsToSelector:@selector(nextToken)] ? [page performSelector:@selector(nextToken)] : nil; } @catch (NSException *e) {}
    if (r && prev && [tok length]) {
        NSMutableDictionary *t = [NSMutableDictionary dictionaryWithDictionary:prev];
        t[@"token"] = tok;
        objc_setAssociatedObject(r, &kDistillerTag, t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return r;
}
%end

// diagnostics for posting a comment on 10.x: what the app calls, and any alert it shows
%hook UIAlertView
- (void)show {
    NSLog(@"[TubeReplacer] alert: title='%@' message='%@' buttons=%@/%@", [self title], [self message], [self buttonTitleAtIndex:0], [self numberOfButtons] > 1 ? [self buttonTitleAtIndex:1] : @"-");
    %orig;
}
%end

%hook YTDistillerCommentsFeedSectionController
- (void)addCommentWithAuth:(id)auth {
    NSLog(@"[TubeReplacer] distiller addCommentWithAuth: %@", auth ? @"auth" : @"nil auth");
    %orig;
}
- (void)loadWithModel:(id)model {
    NSLog(@"[TubeReplacer] distiller section loadWithModel: %@ (video=%@ channel=%@ privacy=%@)", NSStringFromClass([model class]),
          [model respondsToSelector:@selector(videoId)] ? [model performSelector:@selector(videoId)] : @"?",
          [model respondsToSelector:@selector(channelId)] ? [model performSelector:@selector(channelId)] : @"?",
          [model respondsToSelector:@selector(privacyStatus)] ? @"y" : @"?");
    %orig;
}
%end

%hook YTInnerTubeCollectionViewController
- (id)sectionControllersForSectionRenderers:(id)renderers {
    @try {
        NSMutableArray *names = [NSMutableArray array];
        for (id r in renderers) [names addObject:NSStringFromClass([r class])];
        NSLog(@"[TubeReplacer] sections: %@", [names componentsJoinedByString:@","]);
    } @catch (NSException *e) {}
    return %orig;
}
%end

%hook YTDistillerService
// 10.2x builds the comment / reply requests on the service itself (older apps: the request factory)
- (id)requestForDistillerCommentsWithVideoID:(id)vid authentication:(id)auth sortBy:(int)sort linkedCommentID:(id)linked {
    id r = %orig;
    if (r) objc_setAssociatedObject(r, &kDistillerTag, @{ @"kind": @"comments", @"videoId": vid ?: @"" }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[TubeReplacer] distiller comments request built for %@ (%@)", vid, r ? @"ok" : @"nil");
    return r;
}
- (id)requestForDistillerRepliesWithCommentID:(id)cid authentication:(id)auth {
    id r = %orig;
    if (r) objc_setAssociatedObject(r, &kDistillerTag, @{ @"kind": @"replies", @"commentId": cid ?: @"" }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return r;
}
// 10.x asks for permissions (canInsert) before it requests any comments
- (void)makeDistillerPermissionsRequest:(id)request responseBlock:(void (^)(id))responseBlock errorBlock:(void (^)(NSError *))errorBlock {
    NSLog(@"[TubeReplacer] distiller permissions request answered locally");
    void (^rb)(id) = [responseBlock copy];
    BOOL can = gTRGauth != nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        Class pc = NSClassFromString(@"YTDistillerPage");
        id pg = [pc alloc];
        pg = ((id (*)(id, SEL, id, unsigned, unsigned, id, id, BOOL))objc_msgSend)(pg, @selector(initWithEntries:totalResults:entriesPerPage:nextToken:previousToken:canInsert:), @[], 0, 0, nil, nil, can);
        if (rb) rb(pg);
        [pg release]; [rb release];
    });
}
- (void)makeListRequest:(id)request responseBlock:(void (^)(id))responseBlock errorBlock:(void (^)(NSError *))errorBlock {
    NSDictionary *tag = request ? objc_getAssociatedObject(request, &kDistillerTag) : nil;
    if (!tag) { %orig; return; }
    NSLog(@"[TubeReplacer] distiller request: %@", tag);
    void (^rb)(id) = [responseBlock copy]; void (^eb)(NSError *) = [errorBlock copy];
    TRDistillerFetch(tag, ^(id pg) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (rb) rb(pg); [rb release]; [eb release]; });
    }, ^(NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (eb) eb(err); [rb release]; [eb release]; });
    });
}
%end
%end

// ---- "View all replies" (v11/12 thread cells): the app has no replies page for these threads, so show the replies in a list ----
@interface TRRepliesController : UITableViewController
@property (nonatomic, retain) NSArray *items;
@end
@implementation TRRepliesController
@synthesize items = _items;
- (void)dealloc { [_items release]; [super dealloc]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Replies";
    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)] autorelease];
}
- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return [_items count]; }
- (CGFloat)tableView:(UITableView *)tv heightForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *t = _items[ip.row][@"text"];
    CGSize sz = [t sizeWithFont:[UIFont systemFontOfSize:15] constrainedToSize:CGSizeMake(tv.bounds.size.width - 32, 4000) lineBreakMode:NSLineBreakByWordWrapping];
    return 36 + sz.height + 12;
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:@"r"];
    if (!c) {
        c = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"r"] autorelease];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        c.textLabel.font = [UIFont boldSystemFontOfSize:13];
        c.detailTextLabel.font = [UIFont systemFontOfSize:15];
        c.detailTextLabel.textColor = [UIColor blackColor];
        c.detailTextLabel.numberOfLines = 0;
    }
    NSDictionary *d = _items[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"%@  %@", d[@"author"], d[@"when"]];
    c.detailTextLabel.text = d[@"text"];
    return c;
}
@end

%group Replies11
%hook YTCommentThreadCellController
- (void)didPressViewAllReplies:(id)sender buttonRenderer:(id)br {
    NSString *cid = nil;
    @try {
        id e = [self respondsToSelector:@selector(entry)] ? [self performSelector:@selector(entry)] : nil;
        id c = [e respondsToSelector:@selector(comment)] ? [e performSelector:@selector(comment)] : nil;
        id cr = [c respondsToSelector:@selector(commentRenderer)] ? [c performSelector:@selector(commentRenderer)] : nil;
        cid = [cr respondsToSelector:@selector(commentId)] ? [cr performSelector:@selector(commentId)] : nil;
    } @catch (NSException *ex) {}
    NSString *tok = nil;
    if ([cid length]) @synchronized (TRReplyTokenByComment()) { tok = TRReplyTokenByComment()[cid]; }
    NSLog(@"[TubeReplacer] view all replies: comment=%@ token=%@", cid, [tok length] ? @"yes" : @"no");
    if (![tok length]) { %orig; return; }
    TRPostInnerTube(@"next", @{ @"continuation": tok }, ^(NSDictionary *rj, NSInteger rc, NSError *re) {
        NSMutableArray *items = [NSMutableArray array];
        NSArray *cmds = rj[@"onResponseReceivedEndpoints"] ?: rj[@"onResponseReceivedCommands"] ?: rj[@"onResponseReceivedActions"];
        for (NSDictionary *c in ([cmds isKindOfClass:[NSArray class]] ? cmds : @[])) {
            NSArray *its = TRDig(c, @[@"appendContinuationItemsAction", @"continuationItems"]) ?: TRDig(c, @[@"reloadContinuationItemsCommand", @"continuationItems"]);
            for (id it in ([its isKindOfClass:[NSArray class]] ? its : @[])) {
                NSMutableDictionary *r = TRCommentRendererFrom(it, rj, NULL, NULL);
                if (!r) continue;
                [items addObject:@{ @"author": TRTextOf(r[@"authorText"]) ?: @"", @"when": TRTextOf(r[@"publishedTimeText"]) ?: @"", @"text": TRTextOf(r[@"contentText"]) ?: @"" }];
            }
        }
        NSLog(@"[TubeReplacer] view all replies: %lu loaded (http=%ld)", (unsigned long)[items count], (long)rc);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![items count]) return;
            TRRepliesController *vc = [[[TRRepliesController alloc] initWithStyle:UITableViewStylePlain] autorelease];
            vc.items = items;
            UINavigationController *nav = [[[UINavigationController alloc] initWithRootViewController:vc] autorelease];
            nav.modalPresentationStyle = UIModalPresentationFormSheet;
            UIViewController *top = [[[UIApplication sharedApplication] keyWindow] rootViewController];
            while (top.presentedViewController) top = top.presentedViewController;
            [top presentViewController:nav animated:YES completion:nil];
        });
    });
}
%end
%end

%ctor {
    @autoreleasepool {
        if (!TRBridgeEnabled()) return;
        %init;
        if (NSClassFromString(@"YTDistillerService") && !NSClassFromString(@"YTCommentThreadCellController")) { %init(Distiller); }
        if (NSClassFromString(@"YTCommentThreadCellController")) { %init(Replies11); }
        Class ssoid = NSClassFromString(@"SSOIdentityPrivate");
        if (ssoid && class_getInstanceMethod(ssoid, @selector(auth))) {
            MSHookMessageEx(ssoid, @selector(auth), (IMP)tr_sso_auth, (IMP *)&orig_sso_auth);
            if (class_getInstanceMethod(ssoid, @selector(userFullName))) MSHookMessageEx(ssoid, @selector(userFullName), (IMP)tr_sso_fullName, (IMP *)&orig_sso_fullName);
            if (class_getInstanceMethod(ssoid, @selector(setAuth:))) MSHookMessageEx(ssoid, @selector(setAuth:), (IMP)tr_sso_setAuth, (IMP *)&orig_sso_setAuth);
        }
        Class yid = NSClassFromString(@"YTIdentity");
        if (yid && class_getInstanceMethod(yid, @selector(authorization)))
            MSHookMessageEx(yid, @selector(authorization), (IMP)tr_ytid_authorization, (IMP *)&orig_ytid_authorization);
        Class c = NSClassFromString(@"YTBaseApiaryService");
        if (!c && NSClassFromString(@"YTBaseInnerTubeService")) {
            Class v12 = NSClassFromString(@"YTBaseInnerTubeService");
            SEL v12Sel = NSSelectorFromString(@"performHTTPRequest:withIdentity:dataBlock:errorBlock:retryEnabled:");
            if (class_getInstanceMethod(v12, v12Sel)) {
                MSHookMessageEx(v12, v12Sel, (IMP)tr_v12, (IMP *)&orig_v12);
                NSLog(@"[TubeReplacer] InnerTube bridge installed (12.x InnerTube service transport)");
            } else NSLog(@"[TubeReplacer] InnerTube bridge: 12.x transport method missing");
            return;
        }
        SEL dataSel  = NSSelectorFromString(@"performHTTPRequest:withRequest:parser:dataBlock:errorBlock:retryEnabled:");
        SEL retrySel = NSSelectorFromString(@"performHTTPRequest:withRequest:parser:responseBlock:errorBlock:retryEnabled:");
        SEL plainSel = NSSelectorFromString(@"performHTTPRequest:withRequest:parser:responseBlock:errorBlock:");

        if (class_getInstanceMethod(c, dataSel)) {
            // 10.x / 11.x: the responseBlock variant forwards here, and InnerTube services call this directly
            MSHookMessageEx(c, dataSel, (IMP)tr_data, (IMP *)&orig_data);
            NSLog(@"[TubeReplacer] InnerTube bridge installed (dataBlock transport)");
        } else if (class_getInstanceMethod(c, retrySel)) {
            MSHookMessageEx(c, retrySel, (IMP)tr_resp_retry, (IMP *)&orig_resp_retry);
            NSLog(@"[TubeReplacer] InnerTube bridge installed (responseBlock+retry transport)");
        } else if (class_getInstanceMethod(c, plainSel)) {
            MSHookMessageEx(c, plainSel, (IMP)tr_resp, (IMP *)&orig_resp);
            NSLog(@"[TubeReplacer] InnerTube bridge installed (responseBlock transport)");
        } else {
            NSLog(@"[TubeReplacer] InnerTube bridge: no transport method found");
        }
    }
}


// diagnostics for the comment buttons (v11): what the app does when a like / dislike / reply is tapped
%hook YTCommentBaseCellController
- (void)didPressLike:(id)a toggleButtonRenderer:(id)r {
    NSLog(@"[TubeReplacer] comment tap: like renderer=%@", [r class]);
    %orig;
}
- (void)didPressDislike:(id)a toggleButtonRenderer:(id)r {
    NSLog(@"[TubeReplacer] comment tap: dislike renderer=%@", [r class]);
    %orig;
}
- (void)didPressCreateReply:(id)a buttonRenderer:(id)r {
    NSLog(@"[TubeReplacer] comment tap: reply renderer=%@", [r class]);
    %orig;
}
%end
