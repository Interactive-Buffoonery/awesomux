#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>
#include "AwesoMuxAppKitTestHost.h"

static bool hostStarted = false;

bool awesomuxAppKitTestHostIsRunning(void) {
    return hostStarted && NSApplication.sharedApplication.isRunning;
}

__attribute__((constructor))
static void installAppKitTestHost(void) {
    const char *enabled = getenv("AWESOMUX_APPKIT_TEST_HOST");
    if (!enabled || strcmp(enabled, "1") != 0) return;
    if (![NSProcessInfo.processInfo.arguments containsObject:@"swift-testing"]) return;

    // Schedule before Swift Testing starts, outside any main-queue job. AppKit
    // uses run-loop stops while delivering events; Swift's async-main loop
    // treats a stop as process completion. NSApplication owns those stops.
    CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
        hostStarted = true;
        [NSApplication.sharedApplication run];
    });
}
