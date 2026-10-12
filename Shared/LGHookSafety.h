#pragma once

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#include <substrate.h>
#include <objc/runtime.h>

void LGLog(NSString *format, ...);

// Substitute's Substrate shim aborts on a nil class or a missing selector; iOS 12 lacks many hooked classes.
static inline void LGSafeHookMessageEx(Class cls, SEL sel, IMP imp, IMP *result) {
    if (result) *result = NULL;
    if (!cls || !sel || !class_getInstanceMethod(cls, sel)) {
        LGLog(@"[hooks] skipped %c[%s %s]: not present on this OS",
              (cls && class_isMetaClass(cls)) ? '+' : '-',
              cls ? class_getName(cls) : "nil", sel ? sel_getName(sel) : "nil");
        return;
    }
    MSHookMessageEx(cls, sel, imp, result);
}

#define MSHookMessageEx LGSafeHookMessageEx
#endif
