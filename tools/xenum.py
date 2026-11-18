#!/usr/bin/env python3
# Enumerate X windows: root children + one level of children (mutter may reparent
# X clients into frame windows, which would hide them from a root-only scan).
import ctypes, sys
X = ctypes.CDLL("libX11.so.6")
X.XOpenDisplay.restype = ctypes.c_void_p
X.XOpenDisplay.argtypes = [ctypes.c_char_p]
X.XDefaultRootWindow.restype = ctypes.c_ulong
X.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
X.XQueryTree.restype = ctypes.c_int
X.XQueryTree.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)), ctypes.POINTER(ctypes.c_uint)]
X.XGetClassHint.restype = ctypes.c_int
X.XGetClassHint.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_void_p]
X.XFetchName.restype = ctypes.c_int
X.XFetchName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_char_p)]
X.XGetWindowAttributes.restype = ctypes.c_int
class XWindowAttributes(ctypes.Structure):
    _fields_=[("x",ctypes.c_int),("y",ctypes.c_int),("width",ctypes.c_int),("height",ctypes.c_int),("border_width",ctypes.c_int),("depth",ctypes.c_int),("visual",ctypes.c_void_p),("root",ctypes.c_ulong),("class",ctypes.c_int),("bit_gravity",ctypes.c_int),("win_gravity",ctypes.c_int),("backing_store",ctypes.c_int),("backing_planes",ctypes.c_ulong),("backing_pixel",ctypes.c_ulong),("save_under",ctypes.c_int),("colormap",ctypes.c_ulong),("map_installed",ctypes.c_int),("map_state",ctypes.c_int),("all_event_masks",ctypes.c_ulong),("your_event_mask",ctypes.c_ulong),("do_not_propagate_mask",ctypes.c_ulong),("override_redirect",ctypes.c_int),("screen",ctypes.c_void_p)]
X.XGetWindowAttributes.argtypes=[ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(XWindowAttributes)]
X.XTranslateCoordinates.restype = ctypes.c_int
X.XTranslateCoordinates.argtypes=[ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong)]

d = X.XOpenDisplay(None)
root = X.XDefaultRootWindow(d)

class ClassHint(ctypes.Structure):
    _fields_=[("res_name",ctypes.c_void_p),("res_class",ctypes.c_void_p)]

def klass(w):
    ch = ClassHint()
    if X.XGetClassHint(d, w, ctypes.byref(ch)) and ch.res_class:
        s = ctypes.cast(ch.res_class, ctypes.c_char_p).value.decode(errors='replace')
        return s
    return ''

def title(w):
    p = ctypes.c_char_p()
    if X.XFetchName(d, w, ctypes.byref(p)) and p.value:
        return p.value.decode(errors='replace')
    return ''

def absgeo(w):
    a = XWindowAttributes()
    if not X.XGetWindowAttributes(d, w, ctypes.byref(a)): return None
    rx, ry = ctypes.c_int(), ctypes.c_int(); child = ctypes.c_ulong()
    X.XTranslateCoordinates(d, w, root, 0, 0, ctypes.byref(rx), ctypes.byref(ry), ctypes.byref(child))
    return rx.value, ry.value, a.width, a.height, a.map_state, a.override_redirect

def kids(w):
    r, p = ctypes.c_ulong(), ctypes.c_ulong()
    k = ctypes.POINTER(ctypes.c_ulong)(); n = ctypes.c_uint()
    if X.XQueryTree(d, w, ctypes.byref(r), ctypes.byref(p), ctypes.byref(k), ctypes.byref(n)):
        return [k[i] for i in range(n.value)]
    return []

def show(w, depth):
    g = absgeo(w)
    if not g: return
    x, y, wd, ht, ms, orr = g
    if wd < 4 or ht < 4: return
    print(f"{'  '*depth}{w:#x} abs=({x},{y}) {wd}x{ht} map={ms} or={orr} class='{klass(w)}' title='{title(w)[:25]}'")

for w in kids(root):
    show(w, 0)
    for c in kids(w):
        show(c, 1)
