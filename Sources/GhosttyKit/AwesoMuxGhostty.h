#ifndef AWESOMUX_GHOSTTY_H
#define AWESOMUX_GHOSTTY_H

#include "../../.build/ghostty/GhosttyKit.xcframework/macos-arm64/Headers/ghostty.h"

// Returns 0 for a complete dump, 1 when any limit is exceeded. On rejection
// written is zero and buffer must be discarded. Does not allocate output.
int awesomux_surface_read_scrollback(ghostty_surface_t surface,
                                    size_t maximum_rows,
                                    size_t maximum_cells,
                                    size_t maximum_page_bytes,
                                    unsigned char *buffer,
                                    size_t capacity,
                                    size_t *written);

#endif
