// channelheader.x
// TubeReplacer - channel page header: avatar below the banner, title and a theme-coloured subscribe
// button next to it.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "general.h"

@interface YTC4TabbedHeaderView : UIView
- (UIView *)avatarImageView;
- (UIView *)bannerImageView;
- (UILabel *)titleLabel;
- (UIView *)subscribeSwitch;
- (UILabel *)subscriberCountLabel;
- (void)setSubscriberCount:(id)count;
- (CGFloat)avatarImageLength;
@end

static const char kTRThemeKey;
static const char kTRSubKey;
extern BOOL gTRHeaderIsOwn;
static const char kTRNoBannerKey;

static NSString *TRFormattedText(id fs) { // YTIFormattedString -> plain text
    if ([fs isKindOfClass:[NSString class]]) return fs;
    NSMutableString *out = [NSMutableString string];
    @try {
        id runs = [fs respondsToSelector:@selector(runsArray)] ? [fs performSelector:@selector(runsArray)] : nil;
        for (id r in ([runs respondsToSelector:@selector(countByEnumeratingWithState:objects:count:)] ? runs : @[])) {
            id t = [r respondsToSelector:@selector(text)] ? [r performSelector:@selector(text)] : nil;
            if ([t isKindOfClass:[NSString class]]) [out appendString:t];
        }
    } @catch (NSException *e) {}
    return out;
}

%hook YTC4TabbedHeaderView

// remember what the app was given: its own label stays blank in the tablet layout
- (void)setSubscriberCount:(id)count {
    %orig;
    NSString *t = TRFormattedText(count);
    objc_setAssociatedObject(self, &kTRSubKey, t, OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSLog(@"[TubeReplacer] header setSubscriberCount: %@ (%@)", t, [count class]);
}

// channels without a banner image: the app still reserves the banner's height (a big empty gap)
- (void)setHasBannerImage:(BOOL)has {
    %orig;
    objc_setAssociatedObject(self, &kTRNoBannerKey, has ? nil : @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[TubeReplacer] header hasBannerImage: %d", (int)has);
}
static BOOL TRNoBanner(id v) { return majorVersion() == 12 && [objc_getAssociatedObject(v, &kTRNoBannerKey) boolValue]; }
- (CGFloat)bannerImageHeight { return TRNoBanner(self) ? 0 : %orig; }
- (CGFloat)unshrunkBannerImageHeight { return TRNoBanner(self) ? 0 : %orig; }
- (CGFloat)shrunkBannerImageHeight { return TRNoBanner(self) ? 0 : %orig; }

// 12.x puts the avatar/title/subscribe row under the banner: give the title area the room it needs
- (CGFloat)titleAreaHeight {
    CGFloat h = %orig;
    if (majorVersion() != 12) return h;
    if (TRNoBanner(self)) return MAX([self avatarImageLength], 64) + 40; // avatar row only
    // banner edge -> avatar half / name + subscriber rows + padding (the app's own height left a big grey gap under the name)
    return MAX([self avatarImageLength] / 2 + 10, 10 + 24 + 2 + 18) + 16;
}

- (void)layoutSubviews {
    %orig;
    if (gTRHeaderIsOwn) { @try { [[self subscribeSwitch] setHidden:YES]; } @catch (NSException *e) {} }
    // only 12.x needs this: 10.x/11.x and 13.x already lay their header out properly
    if (majorVersion() != 12) return;
    @try {
        UIView *av = [self avatarImageView];
        UIView *bn = [self bannerImageView];
        UILabel *tl = [self titleLabel];
        UILabel *cl = [self subscriberCountLabel];
        UIView *sw = [self subscribeSwitch];
        if (!av || [av isHidden] || av.frame.size.width < 20) return;
        CGFloat W = self.bounds.size.width;
        BOOL hasBn = bn && ![bn isHidden] && bn.frame.size.height > 1;
        BOOL noBanner = TRNoBanner(self);
        CGFloat edge = hasBn ? CGRectGetMaxY(bn.frame) : av.frame.origin.y;
        if (noBanner) { CGRect na = av.frame; na.origin.y = 16; av.frame = na; edge = 16 - 10 + 6; } // avatar at the top, row beside it
        // avatar centred on the banner's lower edge (half over the banner, half over the grey bar)
        CGRect a = av.frame;
        if (hasBn) { a.origin.y = edge - a.size.height / 2; av.frame = a; }
        [self bringSubviewToFront:av];
        CGFloat rowTop = edge + 10;
        CGFloat right = W - 16;
        // subscribe button on the right
        CGFloat sx = right;
        if (sw && ![sw isHidden]) {
            CGSize ss = sw.frame.size;
            CGFloat sw_ = MIN(MAX(ss.width, 110), 190), sh = MAX(ss.height, 32);
            sx = right - sw_;
            sw.frame = CGRectMake(sx, rowTop + 6, sw_, sh);
            [self bringSubviewToFront:sw];
        }
        CGFloat x = CGRectGetMaxX(a) + 14, w = sx - 12 - x;
        if (w < 60) return;
        CGFloat y = rowTop;
        if (tl && ![tl isHidden]) {
            tl.hidden = NO; tl.alpha = 1; tl.numberOfLines = 1;
            CGFloat th = MAX([tl sizeThatFits:CGSizeMake(w, 100)].height, 24);
            tl.frame = CGRectMake(x, y, w, th); y += th + 2;
        }
        NSString *given = objc_getAssociatedObject(self, &kTRSubKey);
        static int dbg = 0;
        if (dbg++ < 4) NSLog(@"[TubeReplacer] header subscriber label: %@ super=%@ hidden=%d text='%@' attr=%lu given='%@'", [cl class], cl.superview == self ? @"self" : (cl.superview ? @"other" : @"none"), cl.hidden, [cl text], (unsigned long)[[cl attributedText] length], given);
        if (cl && ![[cl text] length] && ![[cl attributedText] length] && [given length]) {
            [cl setText:given]; // the app left its label empty: fill it ourselves
            cl.font = [UIFont systemFontOfSize:14]; cl.textColor = [UIColor grayColor];
        }
        if (cl && cl.superview != self && ([[cl text] length] || [[cl attributedText] length])) [self addSubview:cl];
        if (cl && ([[cl text] length] || [[cl attributedText] length])) {
            cl.hidden = NO; cl.alpha = 1; cl.numberOfLines = 1;
            CGFloat ch = MAX([cl sizeThatFits:CGSizeMake(w, 60)].height, 18);
            cl.frame = CGRectMake(x, y, w, ch);
        }
    } @catch (NSException *e) {}
}

%end

@interface YTC4TabbedHeaderViewController : NSObject
- (YTC4TabbedHeaderView *)headerView;
@end

%hook YTC4TabbedHeaderViewController

// the page colour is derived from the channel's banner: use it for the subscribe button too
static CGFloat TRLuma(UIColor *c) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![c getRed:&r green:&g blue:&b alpha:&a]) { CGFloat w = 0; if ([c getWhite:&w alpha:&a]) return w; return 0.5; }
    return 0.299 * r + 0.587 * g + 0.114 * b;
}
- (void)themeColorDidChange:(UIColor *)color titleColor:(id)title animated:(BOOL)animated {
    // a light channel colour (white themed banner) with the app's white title text is unreadable: use dark text on it
    if ([color isKindOfClass:[UIColor class]] && [title isKindOfClass:[UIColor class]] && TRLuma(color) > 0.7 && TRLuma(title) > 0.6) {
        title = [UIColor colorWithWhite:0.13 alpha:1];
    }
    %orig(color, title, animated);
    if (majorVersion() != 12) return;
    @try {
        if ([color isKindOfClass:[UIColor class]]) {
            id hv = [self headerView];
            objc_setAssociatedObject(hv, &kTRThemeKey, color, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [hv setNeedsLayout];
        }
    } @catch (NSException *e) {}
}

%end


// iPad v11 home grid: more padding around the cards makes them narrower (smaller thumbnails, same column count)
@interface YTShelfSectionController : NSObject
- (CGFloat)sectionPaddingX;
@end
%hook YTShelfSectionController
- (CGFloat)sectionPaddingX {
    CGFloat p = %orig;
    if (majorVersion() == 11 && [[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) return p + 40;
    return p;
}
%end


// v12: the avatar button opens the old overflow menu (Switch account / Settings / Help) unless this flag is on;
// the account panel (header with the person, My channel, Notifications, History...) is what the guide's menu feeds
%hook YTGlobalConfig
- (BOOL)useAccountPanel { return YES; }
%end
