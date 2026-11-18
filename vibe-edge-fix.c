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
#include <dirent.h>
#include <fcntl.h>
#include <poll.h>
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

/* /proc scan instead of popen("pgrep -f Vibe\\.exe"): the fork+exec+pclose
   cost 5x/s dominated this daemon's CPU (measured 12.9% of a whole core while
   it exists only to repaint 4 edge strips). Same match, no fork. */
static int app_alive(void) {
    DIR *dp = opendir("/proc");
    if (!dp) return 1;
    struct dirent *e;
    int found = 0;
    while (!found && (e = readdir(dp))) {
        if (e->d_name[0] < '0' || e->d_name[0] > '9') continue;
        char path[128], buf[4096];
        snprintf(path, sizeof path, "/proc/%s/cmdline", e->d_name);
        int fd = open(path, O_RDONLY);
        if (fd < 0) continue;
        ssize_t n = read(fd, buf, sizeof buf - 1);
        close(fd);
        if (n <= 0) continue;
        buf[n] = 0;
        if (strstr(buf, "Vibe.exe")) found = 1;
    }
    closedir(dp);
    return found;
}

/* returns 0 once the window is gone, so the cache can drop it */
static int fix_window(Display *d, Window w) {
    XWindowAttributes a;
    if (!XGetWindowAttributes(d, w, &a)) return 0;
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
    return 1;
}

/* Cache of the windows that actually need painting. A tree walk is 5076
   XGetClassHint round trips on a live Proton session (measured 16% of a whole
   core at 5 polls/s); walking once and tracking new windows from CreateNotify
   on the root costs 29 windows per poll instead. */
#define MAXW 256
static Window wins[MAXW];
static int nwins;

static void adopt(Window w) {
    for (int i = 0; i < nwins; i++) if (wins[i] == w) return;
    if (nwins < MAXW) wins[nwins++] = w;
}

static void collect(Display *d, Window w, int depth) {
    if (depth < 0) return;
    if (is_app(d, w)) adopt(w);
    Window r, p, *kids = NULL;
    unsigned int n = 0;
    if (XQueryTree(d, w, &r, &p, &kids, &n)) {
        for (unsigned int i = 0; i < n; i++) collect(d, kids[i], depth - 1);
        if (kids) XFree(kids);
    }
}

static void repaint_all(Display *d) {
    int k = 0;
    for (int i = 0; i < nwins; i++)
        if (fix_window(d, wins[i])) wins[k++] = wins[i];
    nwins = k;
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
    XSelectInput(d, root, SubstructureNotifyMask);
    collect(d, root, 3);
    int alive = 1, tick = 0, misses = 0;
    while (alive) {
        repaint_all(d);              /* Chromium repaints the frame white again, so
                                        the strips need overpainting every poll */
        XFlush(d);
        struct pollfd pfd = { ConnectionNumber(d), POLLIN, 0 };
        if (poll(&pfd, 1, 200) > 0 && (pfd.revents & POLLIN)) {
            while (XPending(d)) {
                XEvent e;
                XNextEvent(d, &e);
                if (e.type == CreateNotify) collect(d, e.xcreatewindow.window, 1);
                else if (e.type == MapNotify) collect(d, e.xmap.window, 1);
            }
        }
        if (++tick % 25 == 0) {           /* /proc scan every 5s, not 5x/s */
            /* a single miss is a mid-boot hiccup (umu-run -> proton -> wine
               hand-off), not the app closing: require 3 in a row (~15s) */
            if (app_alive()) misses = 0;
            else if (++misses >= 3) alive = 0;
        }
        if (tick % 1500 == 0) collect(d, root, 3);  /* safety net: full rescan every 5min
                                                       in case a CreateNotify was missed */
    }
    fprintf(stderr, "app gone, exiting\n");
    return 0;
}
