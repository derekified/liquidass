#pragma once

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#ifdef __cplusplus
extern "C" {
#endif

BOOL LGSystemVersionAtLeast(NSInteger major);

NSString *LGLegacyClassName(NSString *modernName);
Class LGClassNamed(NSString *modernName);
BOOL LGClassNameMatches(NSString *actualName, NSString *modernName);
BOOL LGObjectIsExactClass(id object, NSString *modernName);

typedef NS_ENUM(NSInteger, LGCornerStyle) {
    LGCornerStyleCircular = 0,
    LGCornerStyleContinuous = 1,
};

void LGLayerSetCornerStyle(CALayer *layer, LGCornerStyle style);
LGCornerStyle LGLayerGetCornerStyle(CALayer *layer);
void LGLayerCopyCornerStyle(CALayer *destination, CALayer *source);
static inline void LGLayerSetContinuousCorners(CALayer *layer) {
    LGLayerSetCornerStyle(layer, LGCornerStyleContinuous);
}

BOOL LGLayerSetValueIfSupported(CALayer *layer, NSString *key, id value);

UIColor *LGDynamicColor(UIColor *light, UIColor *dark);
BOOL LGTraitCollectionIsDark(UITraitCollection *traitCollection);
UIColor *LGResolvedColor(UIColor *color, UITraitCollection *traitCollection);
UIColor *LGLabelColor(void);
UIColor *LGSecondaryLabelColor(void);
UIColor *LGTertiaryLabelColor(void);
UIColor *LGSeparatorColor(void);
UIColor *LGSystemBackgroundColor(void);
UIColor *LGSystemGroupedBackgroundColor(void);
UIColor *LGSecondarySystemGroupedBackgroundColor(void);
UIColor *LGTertiarySystemFillColor(void);
UIColor *LGSystemIndigoColor(void);

UIFont *LGMonospacedFont(CGFloat size, UIFontWeight weight);
UIBlurEffect *LGSystemMaterialBlurEffect(void);

UIImage *LGSymbolImage(NSString *name, CGFloat pointSize, UIFontWeight weight);

typedef void (^LGControlHandler)(__kindof UIControl *sender);
void LGControlAddHandler(UIControl *control, UIControlEvents events, LGControlHandler handler);

UIViewController *LGPresentingViewControllerForView(UIView *view);
UIInterfaceOrientation LGWindowInterfaceOrientation(UIWindow *window);

#ifdef __cplusplus
}
#endif

@interface LGMenuItem : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *symbolName;
@property (nonatomic, assign) BOOL destructive;
@property (nonatomic, assign) BOOL checked;
@property (nonatomic, copy) dispatch_block_t handler;
+ (instancetype)itemWithTitle:(NSString *)title symbolName:(NSString *)symbolName handler:(dispatch_block_t)handler;
@end

#ifdef __cplusplus
extern "C" {
#endif

void LGPresentMenu(UIView *sourceView, NSString *title, NSArray<LGMenuItem *> *items);
BOOL LGNativeButtonMenusAvailable(void);
id LGNativeMenuFromItems(NSString *title, NSArray<LGMenuItem *> *items);
void LGButtonSetMenuItems(UIButton *button, NSArray<LGMenuItem *> *items);

#ifdef __cplusplus
}
#endif

@interface LGColorWell : UIControl
@property (nonatomic, strong) UIColor *selectedColor;
@property (nonatomic, assign) BOOL supportsAlpha;
@property (nonatomic, copy) NSString *title;
@end
