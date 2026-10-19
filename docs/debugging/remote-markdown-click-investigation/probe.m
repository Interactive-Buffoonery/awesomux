#import <AppKit/AppKit.h>
#include "ghostty.h"
#include <stdio.h>
static int opens;
static void wake(void *p) {}
static bool action(ghostty_app_t app, ghostty_target_s target, ghostty_action_s a) {
    if(a.tag == GHOSTTY_ACTION_OPEN_URL) { opens++; printf("OPEN %.*s\n", (int)a.action.open_url.len, a.action.open_url.url); }
    if(a.tag == GHOSTTY_ACTION_MOUSE_OVER_LINK) printf("HOVER %.*s\n", (int)a.action.mouse_over_link.len, a.action.mouse_over_link.url);
    return true;
}
static ghostty_clipboard_read_result_e readcb(void*a,ghostty_clipboard_e b,void*c,const char*const*d,size_t e,bool f) { return GHOSTTY_CLIPBOARD_READ_UNAVAILABLE; }
static void writecb(void*a,ghostty_clipboard_e b,const ghostty_clipboard_content_s*c,size_t d,bool e) {}
static void pump(ghostty_app_t app, double duration) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:duration];
    while([until timeIntervalSinceNow]>0) { ghostty_app_tick(app); [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; }
}
int main(int argc,char**argv) { @autoreleasepool {
    [NSApplication sharedApplication];
    if(ghostty_init(1,argv)) return 2;
    ghostty_config_t config=ghostty_config_new();
    ghostty_config_load_file(config,"/tmp/awesomux-markdown-click-investigation/config");
    ghostty_config_finalize(config);
    ghostty_runtime_config_s rt={.wakeup_cb=wake,.action_cb=action,.read_clipboard_cb=readcb,.write_clipboard_cb=writecb};
    ghostty_app_t app=ghostty_app_new(&rt,config); if(!app) return 3;
    NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,400) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    NSView *view=[[NSView alloc] initWithFrame:NSMakeRect(0,0,800,400)]; window.contentView=view;
    ghostty_surface_config_s sc=ghostty_surface_config_new(); sc.platform_tag=GHOSTTY_PLATFORM_MACOS; sc.platform.macos.nsview=(__bridge void*)view; sc.scale_factor=1; sc.working_directory="/tmp"; sc.command="/bin/cat /tmp/awesomux-markdown-click-investigation/fixture"; sc.wait_after_command=true;
    ghostty_surface_t surface=ghostty_surface_new(app,&sc); if(!surface) return 4;
    ghostty_surface_set_size(surface,800,400); ghostty_surface_set_focus(surface,true); pump(app,1);
    ghostty_surface_size_s sz=ghostty_surface_size(surface); printf("GRID %u %u cell=%u,%u\n",sz.columns,sz.rows,sz.cell_width_px,sz.cell_height_px);
    // Fixture paths begin at column 2 and use one row each.
    for(int row=0;row<4;row++) { printf("ROW %d\n",row); int before=opens;
        ghostty_surface_mouse_pos(surface,5.5*sz.cell_width_px,(row+0.5)*sz.cell_height_px,GHOSTTY_MODS_SUPER); pump(app,.1);
        ghostty_text_s word={0}; if(ghostty_surface_quicklook_word(surface,&word)) {printf("WORD %.*s start=%u length=%u\n",(int)word.text_len,word.text,word.offset_start,word.offset_len);ghostty_surface_free_text(surface,&word);}
        ghostty_surface_mouse_button(surface,GHOSTTY_MOUSE_PRESS,GHOSTTY_MOUSE_LEFT,GHOSTTY_MODS_SUPER);
        ghostty_surface_mouse_button(surface,GHOSTTY_MOUSE_RELEASE,GHOSTTY_MOUSE_LEFT,GHOSTTY_MODS_SUPER); pump(app,.1);
        printf("RESULT row=%d opens=%d\n",row,opens-before);
    }
    fflush(stdout); ghostty_surface_free(surface); ghostty_app_free(app); ghostty_config_free(config);
    return 0;
} }
