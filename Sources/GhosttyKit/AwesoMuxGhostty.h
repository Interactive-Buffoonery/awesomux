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

// Returns 0 for all text, 2 for a recent suffix with older output omitted,
// or 1 when even the newest row cannot fit the admission/output limits.
// Rejected buffers must be discarded. Never scans the excluded older pages.
int awesomux_surface_read_recent_scrollback(ghostty_surface_t surface,
                                           size_t maximum_rows,
                                           size_t maximum_cells,
                                           size_t maximum_page_bytes,
                                           unsigned char *buffer,
                                           size_t capacity,
                                           size_t *written);

// Main-thread barrier for advisory OSC 7 reports captured by the IO reader.
// Zero disables acceptance; callers must never reuse a generation on a surface.
void awesomux_surface_set_remote_pwd_generation(ghostty_surface_t surface,
                                                uint64_t generation);

#endif
