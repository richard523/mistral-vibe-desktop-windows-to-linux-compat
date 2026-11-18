/* vibe-edge-fix: paint the X background/border of every steam_app_0 window dark.
 *
 * Why: Electron windows under wine are created with background_pixel=WhitePixel
 * (Chromium's window class brush is NULL). The 4px resize-frame edge that
 * Chromium leaves unpainted is composited by XWayland from that background ->
 * white bars on the right/bottom of the window whenever its edge is on screen
 * (worst when a full-size helper window like "Dictation" sits flush at the
 * monitor's right edge behind the main window and peeks out).
 * Registry colors / wine metrics / --default-background-color can't reach it.
 *
 * What works (measured): set background-pixmap None + background/border pixel
 * dark so any future expose repaints dark, AND directly fill the 8px edge
 * strips dark every poll - changing the bg of a viewable window does not
 * repaint it by itself, and XClearArea/expose makes Chromium repaint the
 * frame white again, so we paint over the strips instead.
 *
 * Modes:  vibe-edge-fix <wid>     one window
 *         vibe-edge-fix --watch   poll the whole window tree every 200ms while a
 *                                 Vibe.exe process exists, then exit.
 */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BG 0x1B1B17UL   /* 23,23,27 - the app's dark theme color */
#define APP_CLASS "steam_app_0"

static int ignore_xerr(Display *d, XErrorEvent *e) { (void)d; (void)e; return 0; }

static int is_app(Display *d, Window w) {
    XClassHint h;
    h.res_name = h.res_class = NULL;
    if (!XGetClassHint(d, w, &h)) return 0;
    int ok = h.res_class && strcmp(h.res_class, APP_CLASS) == 0;
    if (h.res_name) XFree(h.res_name);
    if (h.res_class) XFree(h.res_class);
    return ok;
}

static int app_alive(void) {
    FILE *f = popen("pgrep -f 'Vibe\\.exe'", "r");
    if (!f) return 1;
    char buf[64];
    int found = fgets(buf, sizeof buf, f) != NULL;
    pclose(f);
    return found;
}

static void fix_window(Display *d, Window w) {
    XWindowAttributes a;
    if (!XGetWindowAttributes(d, w, &a)) return;
    XSetWindowBackgroundPixmap(d, w, None);   /* a pixmap would override the pixel */
    XSetWindowBackground(d, w, BG);
    XSetWindowBorder(d, w, BG);
    if (a.width > 20 && a.height > 20) {
        GC gc = XCreateGC(d, w, 0, NULL);
        XSetForeground(d, gc, BG);
        XFillRectangle(d, w, gc, a.width - 8, 0, 8, a.height);
        XFillRectangle(d, w, gc, 0, a.height - 8, a.width, 8);
        XFillRectangle(d, w, gc, 0, 0, 8, a.height);
        XFillRectangle(d, w, gc, 0, 0, a.width, 8);
        XFreeGC(d, gc);
    }
}

static void walk(Display *d, Window w, int depth) {
    if (depth < 0) return;
    if (is_app(d, w)) fix_window(d, w);
    Window r, p, *kids = NULL;
    unsigned int n = 0;
    if (XQueryTree(d, w, &r, &p, &kids, &n)) {
        for (unsigned int i = 0; i < n; i++) walk(d, kids[i], depth - 1);
        if (kids) XFree(kids);
    }
}

int main(int argc, char **argv) {
    Display *d = XOpenDisplay(NULL);
    if (!d) { fprintf(stderr, "no display\n"); return 1; }
    XSetErrorHandler(ignore_xerr);
    Window root = DefaultRootWindow(d);

    if (argc > 1 && strcmp(argv[1], "--watch") != 0) {
        Window w = strtoul(argv[1], NULL, 0);
        fix_window(d, w);
        XFlush(d);
        printf("bg set dark on %s\n", argv[1]);
        return 0;
    }

    fprintf(stderr, "watching...\n");
    /* fresh launches start us before Vibe.exe exists; wait for it to appear
       (umu/wine boot takes seconds) instead of exiting immediately */
    {
        int waited = 0;
        while (!app_alive()) {
            if (++waited > 300) { fprintf(stderr, "no app after 60s, exiting\n"); return 0; }
            usleep(200000);
        }
    }
    while (app_alive()) {
        walk(d, root, 3);
        XFlush(d);
        usleep(200000);
    }
    fprintf(stderr, "app gone, exiting\n");
    return 0;
}
