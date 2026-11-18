/* vibe-edge-fix: set the X background pixel of every steam_app_0 window dark.
 *
 * Why: Electron windows under wine get background_pixel=WhitePixel at creation
 * (class brush NULL). XWayland composites the uncovered 4px resize-frame edge
 * from that pixel -> white bars on the right/bottom. Setting it to the app's
 * dark theme color removes the bars in every window state, at creation time.
 *
 * Modes:  vibe-edge-fix <wid>     one window
 *         vibe-edge-fix --watch   poll root children every 200ms while a
 *                                 Vibe.exe process exists, then exit.
 */
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

#define BG 0x1B1B17UL   /* 23,23,27 */
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
    /* pgrep -f 'Vibe\.exe' without matching ourselves: use /proc scan */
    FILE *f = popen("pgrep -f 'Vibe\\.exe'", "r");
    if (!f) return 1;
    char buf[64];
    int found = fgets(buf, sizeof buf, f) != NULL;
    pclose(f);
    return found;
}

int main(int argc, char **argv) {
    Display *d = XOpenDisplay(NULL);
    if (!d) { fprintf(stderr, "no display\n"); return 1; }
    XSetErrorHandler(ignore_xerr);
    Window root = DefaultRootWindow(d);

    if (argc > 1 && strcmp(argv[1], "--watch") != 0) {
        Window w = strtoul(argv[1], NULL, 0);
        XSetWindowBackground(d, w, BG);
        XFlush(d);
        printf("bg set dark on %s\n", argv[1]);
        return 0;
    }

    /* ignore X errors (windows dying mid-scan) */
    fprintf(stderr, "watching...\n");
    while (app_alive()) {
        Window r, p, *kids = NULL;
        unsigned int n = 0;
        if (XQueryTree(d, root, &r, &p, &kids, &n)) {
            for (unsigned int i = 0; i < n; i++)
                if (is_app(d, kids[i]))
                    XSetWindowBackground(d, kids[i], BG);
            XFlush(d);
            if (kids) XFree(kids);
        }
        usleep(200000);
    }
    fprintf(stderr, "app gone, exiting\n");
    return 0;
}
