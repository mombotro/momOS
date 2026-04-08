#pragma once
struct lconv { const char *decimal_point; };
static inline struct lconv *localeconv(void) {
    static struct lconv lc = { "." };
    return &lc;
}
