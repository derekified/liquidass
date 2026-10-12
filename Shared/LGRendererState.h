#ifndef LG_RENDERER_STATE_H
#define LG_RENDERER_STATE_H

#include <stdbool.h>
#include <stdint.h>
#include <notify.h>

// Published by backboardd through notifyd; readers treat anything but Active as
// "custom glass shader is not compositing" and draw an in-process material.
enum {
    LGRendererStateUnknown = 0,
    LGRendererStateStarting = 1,
    LGRendererStateRegistered = 2,
    LGRendererStateActive = 3,
    LGRendererStateUnavailable = 4,
};

#define LG_RENDERER_STATE_NOTIFY_NAME "dylv.liquidglass/RendererState"

static inline int LGRendererStateToken(void) {
    static int sToken = -1;
    if (sToken < 0) {
        int token = -1;
        if (notify_register_check(LG_RENDERER_STATE_NOTIFY_NAME, &token) != NOTIFY_STATUS_OK)
            return -1;
        sToken = token;
    }
    return sToken;
}

static inline uint64_t LGRendererStateRead(void) {
    int token = LGRendererStateToken();
    uint64_t state = LGRendererStateUnknown;
    if (token < 0 || notify_get_state(token, &state) != NOTIFY_STATUS_OK)
        return LGRendererStateUnknown;
    return state;
}

static inline bool LGRendererStateWrite(uint64_t state) {
    int token = LGRendererStateToken();
    return token >= 0 && notify_set_state(token, state) == NOTIFY_STATUS_OK;
}

#endif
