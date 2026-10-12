#import <UIKit/UIKit.h>
#import "../Shared/LGCompat.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "../Shared/LGLiveBackdropView.h"
#import "../Shared/LGGlassKit.h"
#import "../Shared/LGSharedSupport.h"

@interface MTMaterialView : UIView
@end

@interface SBRingerPillView : UIView
@end

static const void * const kLGPillHUDGlassKey = &kLGPillHUDGlassKey;

static BOOL LGPillHUDEnabled(void) {
    return lgHostEnabled(@"PillHUD");
}

static void LGUpdateRingerPillGlass(SBRingerPillView *self) {
    if (!self) return;

    MTMaterialView *base = nil;
    UIView *shadow = nil;
    @try {
        base = [self valueForKey:@"_materialView"];
        shadow = [self valueForKey:@"_shadowView"];
    } @catch (...) {}

    LGLiveBackdropView *glass = objc_getAssociatedObject(self, kLGPillHUDGlassKey);
    if (!LGPillHUDEnabled()) {
        glass.hidden = YES;
        if (base) base.hidden = NO;
        return;
    }

    if (base) base.hidden = YES;
    if (!glass) {
        glass = LGCreateRegisteredGlass(self.bounds, nil, @"PillHUD");
        if (!glass) return;
        objc_setAssociatedObject(self, kLGPillHUDGlassKey, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lgTrackGlass(glass, @"PillHUD", self);
        if (shadow) [self insertSubview:glass aboveSubview:shadow];
        else [self insertSubview:glass atIndex:0];
    }

    CGFloat radius = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) * 0.5;
    glass.hidden = NO;
    glass.frame = self.bounds;
    glass.layer.cornerRadius = radius;
    LGLayerSetContinuousCorners(glass.layer);
    glass.layer.masksToBounds = YES;
    [glass applyFilters];

    self.layer.cornerRadius = radius;
    LGLayerSetContinuousCorners(self.layer);
}

%group LGPillHUDHooks

%hook SBRingerPillView

- (void)layoutSubviews {
    %orig;
    LGUpdateRingerPillGlass(self);
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess() || !NSClassFromString(@"SBRingerPillView")) return;
    %init(LGPillHUDHooks);
    lgObservePreferenceReload(^{
        LGLog(@"PillHUD: Preferences reloaded");
    });
}
