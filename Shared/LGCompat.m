#import "LGCompat.h"
#import <objc/message.h>
#import <objc/runtime.h>

BOOL LGSystemVersionAtLeast(NSInteger major) {
    static NSInteger sMajor = 0;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sMajor = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
    });
    return sMajor >= major;
}

#pragma mark - Class aliases

// iOS 12 SpringBoard names for classes that were renamed with the CoverSheet/BannerKit split in iOS 13/14.
NSString *LGLegacyClassName(NSString *modernName) {
    static NSDictionary<NSString *, NSString *> *sAliases;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sAliases = @{
            @"CSCoverSheetView": @"SBDashBoardView",
            @"CSCoverSheetViewController": @"SBDashBoardViewController",
            @"CSMainPageView": @"SBDashBoardMainPageView",
            @"CSPasscodeBackgroundView": @"SBDashBoardPasscodeBackgroundView",
            @"CSQuickActionsButton": @"SBDashBoardQuickActionsButton",
            @"CSQuickActionsView": @"SBDashBoardQuickActionsView",
            @"SBBannerWindow": @"SBNotificationBannerWindow",
        };
    });
    return modernName ? sAliases[modernName] : nil;
}

Class LGClassNamed(NSString *modernName) {
    if (!modernName.length) return Nil;
    Class cls = NSClassFromString(modernName);
    if (cls) return cls;
    NSString *legacy = LGLegacyClassName(modernName);
    return legacy ? NSClassFromString(legacy) : Nil;
}

BOOL LGClassNameMatches(NSString *actualName, NSString *modernName) {
    if (!actualName || !modernName) return NO;
    if ([actualName isEqualToString:modernName]) return YES;
    NSString *legacy = LGLegacyClassName(modernName);
    return legacy && [actualName isEqualToString:legacy];
}

BOOL LGObjectIsExactClass(id object, NSString *modernName) {
    return object && LGClassNameMatches(NSStringFromClass([object class]), modernName);
}

#pragma mark - Corners

void LGLayerSetCornerStyle(CALayer *layer, LGCornerStyle style) {
    if (!layer) return;
    if (@available(iOS 13.0, *)) {
        layer.cornerCurve = (style == LGCornerStyleContinuous) ? kCACornerCurveContinuous : kCACornerCurveCircular;
        return;
    }
    SEL setter = NSSelectorFromString(@"setContinuousCorners:");
    if ([layer respondsToSelector:setter]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, setter, style == LGCornerStyleContinuous);
    }
}

LGCornerStyle LGLayerGetCornerStyle(CALayer *layer) {
    if (!layer) return LGCornerStyleCircular;
    if (@available(iOS 13.0, *)) {
        return [layer.cornerCurve isEqualToString:kCACornerCurveContinuous] ? LGCornerStyleContinuous : LGCornerStyleCircular;
    }
    SEL getter = NSSelectorFromString(@"continuousCorners");
    if ([layer respondsToSelector:getter]) {
        return ((BOOL (*)(id, SEL))objc_msgSend)(layer, getter) ? LGCornerStyleContinuous : LGCornerStyleCircular;
    }
    return LGCornerStyleCircular;
}

void LGLayerCopyCornerStyle(CALayer *destination, CALayer *source) {
    if (!destination || !source) return;
    if (@available(iOS 13.0, *)) {
        destination.cornerCurve = source.cornerCurve;
        return;
    }
    LGLayerSetCornerStyle(destination, LGLayerGetCornerStyle(source));
}

BOOL LGLayerSetValueIfSupported(CALayer *layer, NSString *key, id value) {
    if (!layer || !key.length) return NO;
    NSString *setterName = [NSString stringWithFormat:@"set%@%@:",
                            [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]];
    if (![layer respondsToSelector:NSSelectorFromString(setterName)]) return NO;
    @try {
        [layer setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return YES;
}

#pragma mark - Colors

static UIColor *LGRGBA(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a];
}

BOOL LGTraitCollectionIsDark(UITraitCollection *traitCollection) {
    if (@available(iOS 12.0, *)) {
        return traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    return NO;
}

UIColor *LGDynamicColor(UIColor *light, UIColor *dark) {
    if (@available(iOS 13.0, *)) {
        return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *trait) {
            return trait.userInterfaceStyle == UIUserInterfaceStyleDark ? dark : light;
        }];
    }
    return light;
}

UIColor *LGResolvedColor(UIColor *color, UITraitCollection *traitCollection) {
    if (!color) return nil;
    if (@available(iOS 13.0, *)) {
        return traitCollection ? [color resolvedColorWithTraitCollection:traitCollection] : color;
    }
    return color;
}

UIColor *LGLabelColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.labelColor;
    return UIColor.blackColor;
}

UIColor *LGSecondaryLabelColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.secondaryLabelColor;
    return LGRGBA(60.0, 60.0, 67.0, 0.6);
}

UIColor *LGTertiaryLabelColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.tertiaryLabelColor;
    return LGRGBA(60.0, 60.0, 67.0, 0.3);
}

UIColor *LGSeparatorColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.separatorColor;
    return LGRGBA(60.0, 60.0, 67.0, 0.29);
}

UIColor *LGSystemBackgroundColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.systemBackgroundColor;
    return UIColor.whiteColor;
}

UIColor *LGSystemGroupedBackgroundColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.systemGroupedBackgroundColor;
    return LGRGBA(242.0, 242.0, 247.0, 1.0);
}

UIColor *LGSecondarySystemGroupedBackgroundColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.secondarySystemGroupedBackgroundColor;
    return UIColor.whiteColor;
}

UIColor *LGTertiarySystemFillColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.tertiarySystemFillColor;
    return LGRGBA(118.0, 118.0, 128.0, 0.12);
}

UIColor *LGSystemIndigoColor(void) {
    if (@available(iOS 13.0, *)) return UIColor.systemIndigoColor;
    return LGRGBA(88.0, 86.0, 214.0, 1.0);
}

#pragma mark - Fonts / effects

UIFont *LGMonospacedFont(CGFloat size, UIFontWeight weight) {
    if (@available(iOS 13.0, *)) {
        return [UIFont monospacedSystemFontOfSize:size weight:weight];
    }
    NSString *name = weight >= UIFontWeightSemibold ? @"Menlo-Bold" : @"Menlo-Regular";
    return [UIFont fontWithName:name size:size] ?: [UIFont monospacedDigitSystemFontOfSize:size weight:weight];
}

UIBlurEffect *LGSystemMaterialBlurEffect(void) {
    if (@available(iOS 13.0, *)) {
        return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleRegular];
}

#pragma mark - Glyphs

static UIBezierPath *LGCircle(CGFloat cx, CGFloat cy, CGFloat r) {
    return [UIBezierPath bezierPathWithArcCenter:CGPointMake(cx, cy) radius:r startAngle:0 endAngle:2.0 * M_PI clockwise:YES];
}

static UIBezierPath *LGRRect(CGFloat x, CGFloat y, CGFloat w, CGFloat h, CGFloat r) {
    return [UIBezierPath bezierPathWithRoundedRect:CGRectMake(x, y, w, h) cornerRadius:r];
}

static UIBezierPath *LGPolyline(const CGFloat *points, NSUInteger count) {
    UIBezierPath *path = [UIBezierPath bezierPath];
    for (NSUInteger i = 0; i + 1 < count * 2; i += 2) {
        CGPoint p = CGPointMake(points[i], points[i + 1]);
        if (i == 0) [path moveToPoint:p];
        else [path addLineToPoint:p];
    }
    return path;
}

#define LG_LINE(...) ({ const CGFloat _pts[] = { __VA_ARGS__ }; LGPolyline(_pts, sizeof(_pts) / sizeof(CGFloat) / 2); })

static UIBezierPath *LGArc(CGFloat cx, CGFloat cy, CGFloat r, CGFloat startDeg, CGFloat endDeg, BOOL clockwise) {
    return [UIBezierPath bezierPathWithArcCenter:CGPointMake(cx, cy)
                                          radius:r
                                      startAngle:startDeg * M_PI / 180.0
                                        endAngle:endDeg * M_PI / 180.0
                                       clockwise:clockwise];
}

typedef struct {
    CGContextRef ctx;
    CGFloat stroke;
} LGGlyphCanvas;

static void LGStroke(LGGlyphCanvas *c, UIBezierPath *path) {
    path.lineWidth = c->stroke;
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    CGContextSetBlendMode(c->ctx, kCGBlendModeNormal);
    [path stroke];
}

static void LGFill(LGGlyphCanvas *c, UIBezierPath *path) {
    CGContextSetBlendMode(c->ctx, kCGBlendModeNormal);
    [path fill];
}

static void LGClearStroke(LGGlyphCanvas *c, UIBezierPath *path) {
    path.lineWidth = c->stroke;
    path.lineCapStyle = kCGLineCapRound;
    path.lineJoinStyle = kCGLineJoinRound;
    CGContextSetBlendMode(c->ctx, kCGBlendModeClear);
    [path stroke];
    CGContextSetBlendMode(c->ctx, kCGBlendModeNormal);
}

static void LGClearFill(LGGlyphCanvas *c, UIBezierPath *path) {
    CGContextSetBlendMode(c->ctx, kCGBlendModeClear);
    [path fill];
    CGContextSetBlendMode(c->ctx, kCGBlendModeNormal);
}

static UIBezierPath *LGFolderPath(void) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(2.0, 7.0)];
    [p addQuadCurveToPoint:CGPointMake(4.5, 4.5) controlPoint:CGPointMake(2.0, 4.5)];
    [p addLineToPoint:CGPointMake(9.0, 4.5)];
    [p addLineToPoint:CGPointMake(11.0, 6.5)];
    [p addLineToPoint:CGPointMake(19.5, 6.5)];
    [p addQuadCurveToPoint:CGPointMake(22.0, 9.0) controlPoint:CGPointMake(22.0, 6.5)];
    [p addLineToPoint:CGPointMake(22.0, 17.5)];
    [p addQuadCurveToPoint:CGPointMake(19.5, 20.0) controlPoint:CGPointMake(22.0, 20.0)];
    [p addLineToPoint:CGPointMake(4.5, 20.0)];
    [p addQuadCurveToPoint:CGPointMake(2.0, 17.5) controlPoint:CGPointMake(2.0, 20.0)];
    [p closePath];
    return p;
}

static UIBezierPath *LGBellPath(CGFloat dx) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(12.0 + dx, 3.0)];
    [p addCurveToPoint:CGPointMake(6.0 + dx, 9.5) controlPoint1:CGPointMake(8.2 + dx, 3.0) controlPoint2:CGPointMake(6.0 + dx, 5.8)];
    [p addLineToPoint:CGPointMake(6.0 + dx, 14.0)];
    [p addLineToPoint:CGPointMake(4.0 + dx, 17.0)];
    [p addLineToPoint:CGPointMake(20.0 + dx, 17.0)];
    [p addLineToPoint:CGPointMake(18.0 + dx, 14.0)];
    [p addLineToPoint:CGPointMake(18.0 + dx, 9.5)];
    [p addCurveToPoint:CGPointMake(12.0 + dx, 3.0) controlPoint1:CGPointMake(18.0 + dx, 5.8) controlPoint2:CGPointMake(15.8 + dx, 3.0)];
    [p closePath];
    [p appendPath:LGArc(12.0 + dx, 18.0, 2.4, 0.0, 180.0, YES)];
    return p;
}

static void LGDrawHand(LGGlyphCanvas *c, BOOL tap) {
    if (tap) {
        LGFill(c, LGRRect(9.6, 6.0, 3.6, 11.0, 1.8));
        LGFill(c, LGRRect(13.0, 10.0, 3.2, 7.0, 1.6));
        LGFill(c, LGRRect(16.0, 11.0, 3.0, 6.0, 1.5));
        LGFill(c, LGRRect(7.5, 13.0, 12.0, 9.0, 3.5));
        UIBezierPath *thumb = LGRRect(-1.6, -4.0, 3.2, 8.0, 1.6);
        [thumb applyTransform:CGAffineTransformRotate(CGAffineTransformMakeTranslation(7.6, 15.6), -0.7)];
        LGFill(c, thumb);
        LGStroke(c, LGArc(11.4, 6.0, 4.4, 200.0, 340.0, YES));
        return;
    }
    LGFill(c, LGRRect(7.4, 7.0, 2.9, 9.0, 1.45));
    LGFill(c, LGRRect(10.5, 5.0, 2.9, 10.0, 1.45));
    LGFill(c, LGRRect(13.6, 5.6, 2.9, 9.4, 1.45));
    LGFill(c, LGRRect(16.7, 7.6, 2.8, 8.0, 1.4));
    LGFill(c, LGRRect(7.4, 12.0, 12.1, 10.0, 4.0));
    UIBezierPath *thumb = LGRRect(-1.5, -4.0, 3.0, 8.0, 1.5);
    [thumb applyTransform:CGAffineTransformRotate(CGAffineTransformMakeTranslation(6.0, 15.2), -0.6)];
    LGFill(c, thumb);
    UIBezierPath *wave = [UIBezierPath bezierPath];
    [wave moveToPoint:CGPointMake(1.8, 6.0)];
    [wave addCurveToPoint:CGPointMake(5.5, 3.0) controlPoint1:CGPointMake(2.6, 3.0) controlPoint2:CGPointMake(4.4, 2.0)];
    LGStroke(c, wave);
}

static BOOL LGDrawGlyphNamed(NSString *name, LGGlyphCanvas *c) {
    if ([name hasSuffix:@".circle.fill"] && ![name isEqualToString:@"magnifyingglass.circle.fill"]) {
        NSString *inner = [name substringToIndex:name.length - @".circle.fill".length];
        LGFill(c, LGCircle(12.0, 12.0, 10.5));
        if ([inner isEqualToString:@"arrow.counterclockwise"]) {
            LGClearStroke(c, LGArc(12.0, 12.6, 5.0, -90.0, 180.0, YES));
            LGClearStroke(c, LG_LINE(14.2, 5.2, 11.6, 7.6, 14.2, 10.0));
        } else if ([inner isEqualToString:@"info"]) {
            LGClearFill(c, LGCircle(12.0, 7.4, 1.4));
            LGClearStroke(c, LG_LINE(12.0, 11.0, 12.0, 17.0));
        } else if ([inner isEqualToString:@"exclamationmark"]) {
            LGClearStroke(c, LG_LINE(12.0, 6.6, 12.0, 13.2));
            LGClearFill(c, LGCircle(12.0, 17.0, 1.4));
        } else if ([inner isEqualToString:@"ellipsis"]) {
            LGClearFill(c, LGCircle(7.4, 12.0, 1.5));
            LGClearFill(c, LGCircle(12.0, 12.0, 1.5));
            LGClearFill(c, LGCircle(16.6, 12.0, 1.5));
        } else if ([inner isEqualToString:@"checkmark"]) {
            LGClearStroke(c, LG_LINE(7.4, 12.4, 10.6, 15.6, 16.6, 8.6));
        } else if ([inner isEqualToString:@"xmark"]) {
            LGClearStroke(c, LG_LINE(8.4, 8.4, 15.6, 15.6));
            LGClearStroke(c, LG_LINE(15.6, 8.4, 8.4, 15.6));
        } else if ([inner isEqualToString:@"plus"]) {
            LGClearStroke(c, LG_LINE(12.0, 7.4, 12.0, 16.6));
            LGClearStroke(c, LG_LINE(7.4, 12.0, 16.6, 12.0));
        } else {
            return NO;
        }
        return YES;
    }

    if ([name isEqualToString:@"chevron.left"]) { LGStroke(c, LG_LINE(15.0, 4.5, 7.5, 12.0, 15.0, 19.5)); return YES; }
    if ([name isEqualToString:@"chevron.right"]) { LGStroke(c, LG_LINE(9.0, 4.5, 16.5, 12.0, 9.0, 19.5)); return YES; }
    if ([name isEqualToString:@"chevron.up"]) { LGStroke(c, LG_LINE(4.5, 15.5, 12.0, 8.0, 19.5, 15.5)); return YES; }
    if ([name isEqualToString:@"chevron.down"]) { LGStroke(c, LG_LINE(4.5, 8.5, 12.0, 16.0, 19.5, 8.5)); return YES; }
    if ([name isEqualToString:@"checkmark"]) { LGStroke(c, LG_LINE(4.5, 12.8, 9.6, 18.0, 19.5, 6.0)); return YES; }
    if ([name isEqualToString:@"xmark"]) {
        LGStroke(c, LG_LINE(5.5, 5.5, 18.5, 18.5));
        LGStroke(c, LG_LINE(18.5, 5.5, 5.5, 18.5));
        return YES;
    }
    if ([name isEqualToString:@"arrow.counterclockwise"]) {
        LGStroke(c, LGArc(12.0, 13.0, 7.5, -90.0, 180.0, YES));
        LGStroke(c, LG_LINE(14.8, 2.6, 11.6, 5.5, 14.8, 8.4));
        return YES;
    }
    if ([name isEqualToString:@"line.3.horizontal"]) {
        LGStroke(c, LG_LINE(4.5, 6.5, 19.5, 6.5));
        LGStroke(c, LG_LINE(4.5, 12.0, 19.5, 12.0));
        LGStroke(c, LG_LINE(4.5, 17.5, 19.5, 17.5));
        return YES;
    }
    if ([name isEqualToString:@"doc.on.doc"]) {
        LGStroke(c, LGRRect(4.5, 2.5, 10.5, 14.0, 2.2));
        LGClearFill(c, LGRRect(7.5, 5.5, 14.0, 18.0, 2.5));
        LGStroke(c, LGRRect(9.0, 7.0, 10.5, 14.5, 2.2));
        return YES;
    }
    if ([name isEqualToString:@"info.circle"]) {
        LGStroke(c, LGCircle(12.0, 12.0, 9.5));
        LGFill(c, LGCircle(12.0, 7.4, 1.3));
        LGStroke(c, LG_LINE(12.0, 11.0, 12.0, 17.0));
        return YES;
    }
    if ([name isEqualToString:@"ellipsis.circle"]) {
        LGStroke(c, LGCircle(12.0, 12.0, 9.5));
        LGFill(c, LGCircle(7.5, 12.0, 1.4));
        LGFill(c, LGCircle(12.0, 12.0, 1.4));
        LGFill(c, LGCircle(16.5, 12.0, 1.4));
        return YES;
    }
    if ([name isEqualToString:@"circle"]) { LGStroke(c, LGCircle(12.0, 12.0, 9.5)); return YES; }
    if ([name isEqualToString:@"iphone"]) {
        LGStroke(c, LGRRect(7.0, 2.5, 10.0, 19.0, 2.6));
        LGStroke(c, LG_LINE(10.8, 5.2, 13.2, 5.2));
        return YES;
    }
    if ([name isEqualToString:@"lock.fill"]) {
        LGStroke(c, LGArc(12.0, 8.5, 4.0, 180.0, 360.0, YES));
        LGStroke(c, LG_LINE(8.0, 8.5, 8.0, 11.0));
        LGStroke(c, LG_LINE(16.0, 8.5, 16.0, 11.0));
        LGFill(c, LGRRect(5.0, 10.5, 14.0, 11.0, 2.4));
        return YES;
    }
    if ([name isEqualToString:@"apps.iphone"]) {
        LGStroke(c, LGRRect(5.5, 2.0, 13.0, 20.0, 3.0));
        LGFill(c, LGRRect(8.4, 6.0, 3.0, 3.0, 0.9));
        LGFill(c, LGRRect(12.6, 6.0, 3.0, 3.0, 0.9));
        LGFill(c, LGRRect(8.4, 10.6, 3.0, 3.0, 0.9));
        LGFill(c, LGRRect(12.6, 10.6, 3.0, 3.0, 0.9));
        return YES;
    }
    if ([name isEqualToString:@"square.grid.2x2.fill"]) {
        LGFill(c, LGRRect(3.0, 3.0, 8.0, 8.0, 2.2));
        LGFill(c, LGRRect(13.0, 3.0, 8.0, 8.0, 2.2));
        LGFill(c, LGRRect(3.0, 13.0, 8.0, 8.0, 2.2));
        LGFill(c, LGRRect(13.0, 13.0, 8.0, 8.0, 2.2));
        return YES;
    }
    if ([name isEqualToString:@"rectangle.bottomthird.inset.filled"]) {
        LGStroke(c, LGRRect(2.5, 4.0, 19.0, 16.0, 3.2));
        LGFill(c, LGRRect(5.0, 13.6, 14.0, 4.0, 1.3));
        return YES;
    }
    if ([name isEqualToString:@"rectangle.topthird.inset.filled"]) {
        LGStroke(c, LGRRect(2.5, 4.0, 19.0, 16.0, 3.2));
        LGFill(c, LGRRect(5.0, 6.4, 14.0, 4.0, 1.3));
        return YES;
    }
    if ([name isEqualToString:@"rectangle.3.group.fill"]) {
        LGFill(c, LGRRect(2.0, 3.0, 20.0, 8.0, 2.2));
        LGFill(c, LGRRect(2.0, 13.0, 9.0, 8.0, 2.2));
        LGFill(c, LGRRect(13.0, 13.0, 9.0, 8.0, 2.2));
        return YES;
    }
    if ([name isEqualToString:@"folder.fill"]) { LGFill(c, LGFolderPath()); return YES; }
    if ([name isEqualToString:@"folder"]) { LGStroke(c, LGFolderPath()); return YES; }
    if ([name isEqualToString:@"app.fill"]) { LGFill(c, LGRRect(3.0, 3.0, 18.0, 18.0, 5.0)); return YES; }
    if ([name isEqualToString:@"exclamationmark.bubble.fill"]) {
        UIBezierPath *bubble = LGRRect(2.0, 3.0, 20.0, 14.0, 4.0);
        [bubble appendPath:LG_LINE(6.0, 16.0, 5.5, 21.5, 11.5, 16.0)];
        LGFill(c, bubble);
        LGClearStroke(c, LG_LINE(12.0, 6.4, 12.0, 10.6));
        LGClearFill(c, LGCircle(12.0, 13.8, 1.3));
        return YES;
    }
    if ([name isEqualToString:@"switch.2"]) {
        LGStroke(c, LG_LINE(3.0, 7.0, 13.0, 7.0));
        LGStroke(c, LGCircle(17.5, 7.0, 3.2));
        LGStroke(c, LG_LINE(11.0, 17.0, 21.0, 17.0));
        LGStroke(c, LGCircle(6.5, 17.0, 3.2));
        return YES;
    }
    if ([name isEqualToString:@"magnifyingglass"]) {
        LGStroke(c, LGCircle(10.5, 10.5, 6.5));
        LGStroke(c, LG_LINE(15.4, 15.4, 20.5, 20.5));
        return YES;
    }
    if ([name isEqualToString:@"magnifyingglass.circle.fill"]) {
        LGFill(c, LGCircle(12.0, 12.0, 10.5));
        LGClearStroke(c, LGCircle(11.0, 11.0, 4.0));
        LGClearStroke(c, LG_LINE(14.0, 14.0, 17.0, 17.0));
        return YES;
    }
    if ([name isEqualToString:@"bell.fill"]) { LGFill(c, LGBellPath(0.0)); return YES; }
    if ([name isEqualToString:@"bell.badge.fill"]) {
        LGFill(c, LGBellPath(-1.0));
        LGClearFill(c, LGCircle(18.0, 5.5, 5.0));
        LGFill(c, LGCircle(18.0, 5.5, 3.4));
        return YES;
    }
    if ([name isEqualToString:@"flashlight.on.fill"]) {
        UIBezierPath *p = [UIBezierPath bezierPath];
        [p moveToPoint:CGPointMake(7.0, 2.0)];
        [p addLineToPoint:CGPointMake(17.0, 2.0)];
        [p addLineToPoint:CGPointMake(17.0, 6.0)];
        [p addLineToPoint:CGPointMake(15.0, 10.0)];
        [p addLineToPoint:CGPointMake(15.0, 20.5)];
        [p addQuadCurveToPoint:CGPointMake(13.5, 22.0) controlPoint:CGPointMake(15.0, 22.0)];
        [p addLineToPoint:CGPointMake(10.5, 22.0)];
        [p addQuadCurveToPoint:CGPointMake(9.0, 20.5) controlPoint:CGPointMake(9.0, 22.0)];
        [p addLineToPoint:CGPointMake(9.0, 10.0)];
        [p addLineToPoint:CGPointMake(7.0, 6.0)];
        [p closePath];
        LGFill(c, p);
        LGClearFill(c, LGCircle(12.0, 14.0, 1.3));
        return YES;
    }
    if ([name isEqualToString:@"circle.grid.3x3.fill"]) {
        for (int row = 0; row < 3; row++) {
            for (int col = 0; col < 3; col++) {
                LGFill(c, LGCircle(4.5 + col * 7.5, 4.5 + row * 7.5, 2.6));
            }
        }
        return YES;
    }
    if ([name isEqualToString:@"clock.fill"]) {
        LGFill(c, LGCircle(12.0, 12.0, 10.5));
        LGClearStroke(c, LG_LINE(12.0, 6.2, 12.0, 12.0, 16.0, 14.4));
        return YES;
    }
    if ([name isEqualToString:@"hand.draw.fill"]) { LGDrawHand(c, NO); return YES; }
    if ([name isEqualToString:@"hand.tap.fill"]) { LGDrawHand(c, YES); return YES; }
    if ([name isEqualToString:@"keyboard.fill"]) {
        LGFill(c, LGRRect(1.5, 5.0, 21.0, 14.0, 2.6));
        for (int row = 0; row < 2; row++) {
            for (int col = 0; col < 6; col++) {
                LGClearFill(c, LGRRect(3.6 + col * 2.95, 7.6 + row * 3.2, 1.9, 1.9, 0.5));
            }
        }
        LGClearFill(c, LGRRect(7.0, 14.6, 10.0, 1.9, 0.6));
        return YES;
    }
    if ([name isEqualToString:@"speaker.wave.3.fill"]) {
        LGFill(c, LG_LINE(1.5, 9.0, 5.5, 9.0, 10.5, 4.5, 10.5, 19.5, 5.5, 15.0, 1.5, 15.0));
        LGStroke(c, LGArc(10.5, 12.0, 3.6, -45.0, 45.0, YES));
        LGStroke(c, LGArc(10.5, 12.0, 7.0, -48.0, 48.0, YES));
        LGStroke(c, LGArc(10.5, 12.0, 10.4, -50.0, 50.0, YES));
        return YES;
    }
    if ([name isEqualToString:@"slider.horizontal.3"]) {
        const CGFloat knobs[3] = { 15.0, 8.0, 17.0 };
        for (int i = 0; i < 3; i++) {
            CGFloat y = 5.5 + i * 6.5;
            LGStroke(c, LG_LINE(3.0, y, 21.0, y));
            LGClearFill(c, LGCircle(knobs[i], y, 3.8));
            LGStroke(c, LGCircle(knobs[i], y, 2.4));
        }
        return YES;
    }
    if ([name isEqualToString:@"mic"] || [name isEqualToString:@"mic.fill"] || [name isEqualToString:@"microphone"]) {
        UIBezierPath *capsule = LGRRect(8.8, 2.0, 6.4, 12.0, 3.2);
        if ([name isEqualToString:@"mic"]) LGStroke(c, capsule);
        else LGFill(c, capsule);
        LGStroke(c, LGArc(12.0, 10.5, 6.5, 0.0, 180.0, YES));
        LGStroke(c, LG_LINE(12.0, 17.0, 12.0, 21.0));
        LGStroke(c, LG_LINE(8.5, 21.0, 15.5, 21.0));
        return YES;
    }
    return NO;
}

static UIImage *LGRenderVectorGlyph(NSString *name, CGFloat pointSize, UIFontWeight weight) {
    CGFloat side = ceil(pointSize * 1.2);
    if (side <= 0.0) return nil;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(side, side), NO, 0.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }
    CGFloat scale = side / 24.0;
    CGContextScaleCTM(ctx, scale, scale);
    [UIColor.blackColor setFill];
    [UIColor.blackColor setStroke];
    CGFloat weightFactor = MAX(0.0, MIN(1.0, (weight + 0.8) / 1.4));
    LGGlyphCanvas canvas = { ctx, (1.25 + weightFactor * 1.35) * (20.0 / MAX(pointSize, 8.0)) * 0.9 + 0.55 };
    BOOL drawn = LGDrawGlyphNamed(name, &canvas);
    UIImage *image = drawn ? UIGraphicsGetImageFromCurrentImageContext() : nil;
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

UIImage *LGSymbolImage(NSString *name, CGFloat pointSize, UIFontWeight weight) {
    if (!name.length) return nil;
    if (pointSize <= 0.0) pointSize = 17.0;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolWeight symbolWeight = UIImageSymbolWeightRegular;
        if (weight >= UIFontWeightBlack) symbolWeight = UIImageSymbolWeightBlack;
        else if (weight >= UIFontWeightHeavy) symbolWeight = UIImageSymbolWeightHeavy;
        else if (weight >= UIFontWeightBold) symbolWeight = UIImageSymbolWeightBold;
        else if (weight >= UIFontWeightSemibold) symbolWeight = UIImageSymbolWeightSemibold;
        else if (weight >= UIFontWeightMedium) symbolWeight = UIImageSymbolWeightMedium;
        else if (weight >= UIFontWeightRegular) symbolWeight = UIImageSymbolWeightRegular;
        else if (weight >= UIFontWeightLight) symbolWeight = UIImageSymbolWeightLight;
        else if (weight >= UIFontWeightThin) symbolWeight = UIImageSymbolWeightThin;
        else symbolWeight = UIImageSymbolWeightUltraLight;
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:symbolWeight];
        UIImage *image = [UIImage systemImageNamed:name withConfiguration:config];
        if (image) return image;
    }

    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
    });
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%.2f|%.2f|%.1f", name, pointSize, weight, UIScreen.mainScreen.scale];
    UIImage *cached = [cache objectForKey:cacheKey];
    if (cached) return cached;
    UIImage *image = LGRenderVectorGlyph(name, pointSize, weight);
    if (image) [cache setObject:image forKey:cacheKey];
    return image;
}

#pragma mark - Control handlers

@interface LGControlBlockTarget : NSObject
@property (nonatomic, copy) LGControlHandler handler;
@end

@implementation LGControlBlockTarget
- (void)lg_invoke:(UIControl *)sender {
    if (self.handler) self.handler(sender);
}
@end

static const void *kLGControlBlockTargetsKey = &kLGControlBlockTargetsKey;

void LGControlAddHandler(UIControl *control, UIControlEvents events, LGControlHandler handler) {
    if (!control || !handler) return;
    NSMutableArray *targets = objc_getAssociatedObject(control, kLGControlBlockTargetsKey);
    if (!targets) {
        targets = [NSMutableArray array];
        objc_setAssociatedObject(control, kLGControlBlockTargetsKey, targets, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    LGControlBlockTarget *target = [LGControlBlockTarget new];
    target.handler = handler;
    [targets addObject:target];
    [control addTarget:target action:@selector(lg_invoke:) forControlEvents:events];
}

UIViewController *LGPresentingViewControllerForView(UIView *view) {
    UIResponder *responder = view;
    UIViewController *controller = nil;
    while (responder) {
        if ([responder isKindOfClass:UIViewController.class]) {
            controller = (UIViewController *)responder;
            break;
        }
        responder = responder.nextResponder;
    }
    if (!controller) controller = view.window.rootViewController;
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

UIInterfaceOrientation LGWindowInterfaceOrientation(UIWindow *window) {
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = window.windowScene;
        if (scene) return scene.interfaceOrientation;
    }
    UIApplication *application = UIApplication.sharedApplication;
    SEL activeSelector = NSSelectorFromString(@"activeInterfaceOrientation");
    if ([application respondsToSelector:activeSelector]) {
        return ((UIInterfaceOrientation (*)(id, SEL))objc_msgSend)(application, activeSelector);
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return application.statusBarOrientation;
#pragma clang diagnostic pop
}

#pragma mark - Menus

@implementation LGMenuItem
+ (instancetype)itemWithTitle:(NSString *)title symbolName:(NSString *)symbolName handler:(dispatch_block_t)handler {
    LGMenuItem *item = [self new];
    item.title = title;
    item.symbolName = symbolName;
    item.handler = handler;
    return item;
}
@end

static NSString *LGUIKitLocalizedString(NSString *key) {
    NSBundle *bundle = [NSBundle bundleForClass:UIApplication.class];
    return [bundle localizedStringForKey:key value:key table:nil];
}

void LGPresentMenu(UIView *sourceView, NSString *title, NSArray<LGMenuItem *> *items) {
    if (!sourceView || !items.count) return;
    UIViewController *presenter = LGPresentingViewControllerForView(sourceView);
    if (!presenter) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:(title.length ? title : nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (LGMenuItem *item in items) {
        dispatch_block_t handler = item.handler;
        UIAlertAction *action = [UIAlertAction actionWithTitle:item.title ?: @""
                                                         style:item.destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                                       handler:^(__unused UIAlertAction *a) {
            if (handler) handler();
        }];
        if (item.checked && [action respondsToSelector:NSSelectorFromString(@"_setChecked:")]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(action, NSSelectorFromString(@"_setChecked:"), YES);
        }
        if (item.symbolName.length && [action respondsToSelector:NSSelectorFromString(@"setImage:")]) {
            UIImage *image = LGSymbolImage(item.symbolName, 17.0, UIFontWeightRegular);
            if (image) ((void (*)(id, SEL, id))objc_msgSend)(action, NSSelectorFromString(@"setImage:"), image);
        }
        [sheet addAction:action];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:LGUIKitLocalizedString(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView;
        popover.sourceRect = sourceView.bounds;
    }
    [presenter presentViewController:sheet animated:YES completion:nil];
}

BOOL LGNativeButtonMenusAvailable(void) {
    if (@available(iOS 14.0, *)) return YES;
    return NO;
}

id LGNativeMenuFromItems(NSString *title, NSArray<LGMenuItem *> *items) {
    if (@available(iOS 14.0, *)) {
        NSMutableArray<UIMenuElement *> *children = [NSMutableArray array];
        for (LGMenuItem *item in items) {
            dispatch_block_t handler = item.handler;
            UIImage *image = item.symbolName.length ? [UIImage systemImageNamed:item.symbolName] : nil;
            UIAction *action = [UIAction actionWithTitle:item.title ?: @""
                                                   image:image
                                              identifier:nil
                                                 handler:^(__unused __kindof UIAction *a) {
                if (handler) handler();
            }];
            if (item.destructive) action.attributes = UIMenuElementAttributesDestructive;
            action.state = item.checked ? UIMenuElementStateOn : UIMenuElementStateOff;
            [children addObject:action];
        }
        return [UIMenu menuWithTitle:title ?: @"" children:children];
    }
    return nil;
}

static const void *kLGButtonMenuItemsKey = &kLGButtonMenuItemsKey;
static const void *kLGButtonMenuTargetInstalledKey = &kLGButtonMenuTargetInstalledKey;

void LGButtonSetMenuItems(UIButton *button, NSArray<LGMenuItem *> *items) {
    if (!button) return;
    if (@available(iOS 14.0, *)) {
        button.menu = items.count ? LGNativeMenuFromItems(@"", items) : nil;
        button.showsMenuAsPrimaryAction = items.count > 0;
        return;
    }
    objc_setAssociatedObject(button, kLGButtonMenuItemsKey, [items copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (objc_getAssociatedObject(button, kLGButtonMenuTargetInstalledKey)) return;
    objc_setAssociatedObject(button, kLGButtonMenuTargetInstalledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    LGControlAddHandler(button, UIControlEventTouchUpInside, ^(UIButton *sender) {
        NSArray<LGMenuItem *> *current = objc_getAssociatedObject(sender, kLGButtonMenuItemsKey);
        LGPresentMenu(sender, nil, current);
    });
}

#pragma mark - Color well

static UIImage *LGCheckerboardImage(void) {
    static UIImage *image;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGFloat cell = 5.0;
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(cell * 2.0, cell * 2.0), YES, 0.0);
        [UIColor.whiteColor setFill];
        UIRectFill(CGRectMake(0, 0, cell * 2.0, cell * 2.0));
        [[UIColor colorWithWhite:0.8 alpha:1.0] setFill];
        UIRectFill(CGRectMake(0, 0, cell, cell));
        UIRectFill(CGRectMake(cell, cell, cell, cell));
        image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    });
    return image;
}

static NSString *LGHexStringFromColor(UIColor *color, BOOL includeAlpha) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat w = 0;
        if ([color getWhite:&w alpha:&a]) r = g = b = w;
    }
    int R = (int)lround(MIN(MAX(r, 0.0), 1.0) * 255.0);
    int G = (int)lround(MIN(MAX(g, 0.0), 1.0) * 255.0);
    int B = (int)lround(MIN(MAX(b, 0.0), 1.0) * 255.0);
    int A = (int)lround(MIN(MAX(a, 0.0), 1.0) * 255.0);
    return includeAlpha ? [NSString stringWithFormat:@"%02X%02X%02X%02X", R, G, B, A]
                        : [NSString stringWithFormat:@"%02X%02X%02X", R, G, B];
}

static UIColor *LGColorFromHexString(NSString *text) {
    NSString *hex = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                     stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return nil;
    unsigned int value = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&value]) return nil;
    if (hex.length == 6) value = (value << 8) | 0xFF;
    return [UIColor colorWithRed:((value >> 24) & 0xFF) / 255.0
                           green:((value >> 16) & 0xFF) / 255.0
                            blue:((value >> 8) & 0xFF) / 255.0
                           alpha:(value & 0xFF) / 255.0];
}

@interface LGColorPickerViewController : UIViewController <UITextFieldDelegate>
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, assign) BOOL supportsAlpha;
@property (nonatomic, copy) void (^colorChanged)(UIColor *color);
@end

@implementation LGColorPickerViewController {
    UIView *_preview;
    NSArray<UISlider *> *_sliders;
    NSArray<UILabel *> *_valueLabels;
    UITextField *_hexField;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = LGSystemGroupedBackgroundColor();
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self
                                                                                           action:@selector(lg_done)];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    UIView *previewBacking = [[UIView alloc] initWithFrame:CGRectZero];
    previewBacking.backgroundColor = [UIColor colorWithPatternImage:LGCheckerboardImage()];
    previewBacking.layer.cornerRadius = 14.0;
    LGLayerSetContinuousCorners(previewBacking.layer);
    previewBacking.clipsToBounds = YES;
    _preview = [[UIView alloc] initWithFrame:CGRectZero];
    _preview.translatesAutoresizingMaskIntoConstraints = NO;
    [previewBacking addSubview:_preview];
    [NSLayoutConstraint activateConstraints:@[
        [_preview.topAnchor constraintEqualToAnchor:previewBacking.topAnchor],
        [_preview.bottomAnchor constraintEqualToAnchor:previewBacking.bottomAnchor],
        [_preview.leadingAnchor constraintEqualToAnchor:previewBacking.leadingAnchor],
        [_preview.trailingAnchor constraintEqualToAnchor:previewBacking.trailingAnchor],
        [previewBacking.heightAnchor constraintEqualToConstant:72.0],
    ]];
    [stack addArrangedSubview:previewBacking];

    NSArray<NSString *> *names = self.supportsAlpha ? @[@"R", @"G", @"B", @"A"] : @[@"R", @"G", @"B"];
    NSArray<UIColor *> *tints = @[UIColor.systemRedColor, UIColor.systemGreenColor, UIColor.systemBlueColor, UIColor.grayColor];
    NSMutableArray *sliders = [NSMutableArray array];
    NSMutableArray *labels = [NSMutableArray array];
    for (NSUInteger i = 0; i < names.count; i++) {
        UILabel *name = [[UILabel alloc] initWithFrame:CGRectZero];
        name.text = names[i];
        name.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
        name.textColor = LGLabelColor();
        [name.widthAnchor constraintEqualToConstant:20.0].active = YES;

        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectZero];
        slider.minimumValue = 0.0;
        slider.maximumValue = 255.0;
        slider.minimumTrackTintColor = tints[i];
        slider.tag = (NSInteger)i;
        [slider addTarget:self action:@selector(lg_sliderChanged:) forControlEvents:UIControlEventValueChanged];

        UILabel *value = [[UILabel alloc] initWithFrame:CGRectZero];
        value.font = LGMonospacedFont(15.0, UIFontWeightRegular);
        value.textColor = LGSecondaryLabelColor();
        value.textAlignment = NSTextAlignmentRight;
        [value.widthAnchor constraintEqualToConstant:40.0].active = YES;

        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[name, slider, value]];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 10.0;
        row.alignment = UIStackViewAlignmentCenter;
        [stack addArrangedSubview:row];
        [sliders addObject:slider];
        [labels addObject:value];
    }
    _sliders = sliders;
    _valueLabels = labels;

    _hexField = [[UITextField alloc] initWithFrame:CGRectZero];
    _hexField.borderStyle = UITextBorderStyleRoundedRect;
    _hexField.font = LGMonospacedFont(17.0, UIFontWeightRegular);
    _hexField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
    _hexField.autocorrectionType = UITextAutocorrectionTypeNo;
    _hexField.spellCheckingType = UITextSpellCheckingTypeNo;
    _hexField.returnKeyType = UIReturnKeyDone;
    _hexField.delegate = self;
    _hexField.placeholder = self.supportsAlpha ? @"RRGGBBAA" : @"RRGGBB";
    [_hexField addTarget:self action:@selector(lg_hexChanged:) forControlEvents:UIControlEventEditingChanged];
    [stack addArrangedSubview:_hexField];

    UILayoutGuide *guide = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:guide.topAnchor constant:20.0],
        [stack.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor constant:20.0],
        [stack.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor constant:-20.0],
    ]];
    [self lg_syncControlsUpdatingHex:YES];
}

- (void)lg_syncControlsUpdatingHex:(BOOL)updateHex {
    CGFloat comps[4] = { 0, 0, 0, 1 };
    if (![self.color getRed:&comps[0] green:&comps[1] blue:&comps[2] alpha:&comps[3]]) {
        CGFloat w = 0;
        if ([self.color getWhite:&w alpha:&comps[3]]) comps[0] = comps[1] = comps[2] = w;
    }
    for (NSUInteger i = 0; i < _sliders.count; i++) {
        CGFloat v = MIN(MAX(comps[i], 0.0), 1.0) * 255.0;
        _sliders[i].value = (float)v;
        _valueLabels[i].text = [NSString stringWithFormat:@"%d", (int)lround(v)];
    }
    _preview.backgroundColor = self.color;
    if (updateHex) _hexField.text = LGHexStringFromColor(self.color, self.supportsAlpha);
}

- (void)lg_commitColor:(UIColor *)color updatingHex:(BOOL)updateHex {
    self.color = color;
    [self lg_syncControlsUpdatingHex:updateHex];
    if (self.colorChanged) self.colorChanged(color);
}

- (void)lg_sliderChanged:(UISlider *)sender {
    (void)sender;
    CGFloat r = _sliders[0].value / 255.0;
    CGFloat g = _sliders[1].value / 255.0;
    CGFloat b = _sliders[2].value / 255.0;
    CGFloat a = _sliders.count > 3 ? _sliders[3].value / 255.0 : 1.0;
    [self lg_commitColor:[UIColor colorWithRed:r green:g blue:b alpha:a] updatingHex:YES];
}

- (void)lg_hexChanged:(UITextField *)field {
    UIColor *color = LGColorFromHexString(field.text);
    if (!color) return;
    if (!self.supportsAlpha) color = [color colorWithAlphaComponent:1.0];
    [self lg_commitColor:color updatingHex:NO];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)lg_done {
    [self.view endEditing:YES];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

@implementation LGColorWell {
    UIView *_nativeWell;
    UIView *_checker;
    UIView *_swatch;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _selectedColor = UIColor.whiteColor;
    if (@available(iOS 14.0, *)) {
        UIColorWell *well = [[UIColorWell alloc] initWithFrame:self.bounds];
        well.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        well.selectedColor = _selectedColor;
        __weak LGColorWell *weakSelf = self;
        [well addAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
            LGColorWell *strongSelf = weakSelf;
            UIColorWell *sender = (UIColorWell *)action.sender;
            if (!strongSelf || !sender.selectedColor) return;
            strongSelf->_selectedColor = sender.selectedColor;
            [strongSelf sendActionsForControlEvents:UIControlEventValueChanged];
        }] forControlEvents:UIControlEventValueChanged];
        _nativeWell = well;
        [self addSubview:well];
        return self;
    }
    _checker = [[UIView alloc] initWithFrame:self.bounds];
    _checker.userInteractionEnabled = NO;
    _checker.backgroundColor = [UIColor colorWithPatternImage:LGCheckerboardImage()];
    _checker.clipsToBounds = YES;
    [self addSubview:_checker];
    _swatch = [[UIView alloc] initWithFrame:self.bounds];
    _swatch.userInteractionEnabled = NO;
    _swatch.layer.borderWidth = 2.0;
    _swatch.layer.borderColor = LGTertiaryLabelColor().CGColor;
    [self addSubview:_swatch];
    [self addTarget:self action:@selector(lg_present) forControlEvents:UIControlEventTouchUpInside];
    [self lg_updateSwatch];
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (_nativeWell) return;
    CGFloat radius = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) * 0.5;
    _checker.frame = self.bounds;
    _swatch.frame = self.bounds;
    _checker.layer.cornerRadius = radius;
    _swatch.layer.cornerRadius = radius;
}

- (void)setSelectedColor:(UIColor *)selectedColor {
    _selectedColor = selectedColor ?: UIColor.clearColor;
    if (@available(iOS 14.0, *)) {
        if ([_nativeWell isKindOfClass:UIColorWell.class]) ((UIColorWell *)_nativeWell).selectedColor = _selectedColor;
    }
    [self lg_updateSwatch];
}

- (void)setSupportsAlpha:(BOOL)supportsAlpha {
    _supportsAlpha = supportsAlpha;
    if (@available(iOS 14.0, *)) {
        if ([_nativeWell isKindOfClass:UIColorWell.class]) ((UIColorWell *)_nativeWell).supportsAlpha = supportsAlpha;
    }
}

- (void)setTitle:(NSString *)title {
    _title = [title copy];
    if (@available(iOS 14.0, *)) {
        if ([_nativeWell isKindOfClass:UIColorWell.class]) ((UIColorWell *)_nativeWell).title = _title;
    }
}

- (void)lg_updateSwatch {
    _swatch.backgroundColor = _selectedColor;
}

- (void)lg_present {
    UIViewController *presenter = LGPresentingViewControllerForView(self);
    if (!presenter) return;
    LGColorPickerViewController *picker = [LGColorPickerViewController new];
    picker.color = _selectedColor;
    picker.supportsAlpha = _supportsAlpha;
    picker.title = _title;
    __weak LGColorWell *weakSelf = self;
    picker.colorChanged = ^(UIColor *color) {
        LGColorWell *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_selectedColor = color;
        [strongSelf lg_updateSwatch];
        [strongSelf sendActionsForControlEvents:UIControlEventValueChanged];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [presenter presentViewController:nav animated:YES completion:nil];
}

@end
