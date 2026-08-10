#!/usr/bin/env python3
"""A minimal XDND drag source, for measuring what the engine does with a real system drop.

No test can stage a drag - the window system delivers it - so this drives the X11 side of the protocol
directly and reports the one bit that matters: whether the engine answered "I will accept this".

Run it against a nested X server so nothing touches the real desktop:

    Xephyr :77 -screen 1024x768 &
    DISPLAY=:77 SCITER_LIB=$PWD/lib/linux/x64 ./target/debug/drag_and_drop.exe &
    python3 spike/xdnd/xdnd_source.py :77 300 200 3.0

Usage: xdnd_source.py <display> <root_x> <root_y> [delay before dropping]

The handshake is XdndEnter -> XdndPosition -> (XdndStatus from the engine) -> XdndDrop. "accept=True"
in the XdndStatus line is the engine agreeing to the drop; see docs/RESEARCH-METHOD.md section 9 for
what that measured.
"""
import ctypes, ctypes.util, sys, time

x11 = ctypes.CDLL(ctypes.util.find_library("X11"))

Atom = ctypes.c_ulong
Window = ctypes.c_ulong


class XClientMessageEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("window", Window),
        ("message_type", Atom),
        ("format", ctypes.c_int),
        ("data", ctypes.c_long * 5),
    ]


class XSelectionRequestEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("owner", Window),
        ("requestor", Window),
        ("selection", Atom),
        ("target", Atom),
        ("property", Atom),
        ("time", ctypes.c_ulong),
    ]


class XSelectionEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("requestor", Window),
        ("selection", Atom),
        ("target", Atom),
        ("property", Atom),
        ("time", ctypes.c_ulong),
    ]


class XEvent(ctypes.Union):
    _fields_ = [
        ("type", ctypes.c_int),
        ("xclient", XClientMessageEvent),
        ("xselectionrequest", XSelectionRequestEvent),
        ("xselection", XSelectionEvent),
        ("pad", ctypes.c_long * 24),
    ]


ClientMessage, SelectionRequest, SelectionNotify = 33, 30, 31
PropModeReplace = 0
AnyPropertyType = 0

x11.XOpenDisplay.restype = ctypes.c_void_p
x11.XInternAtom.restype = Atom
x11.XCreateSimpleWindow.restype = Window
x11.XDefaultRootWindow.restype = Window

display_name = (sys.argv[1] if len(sys.argv) > 1 else ":77").encode()
drop_x = int(sys.argv[2]) if len(sys.argv) > 2 else 500
drop_y = int(sys.argv[3]) if len(sys.argv) > 3 else 360
delay = float(sys.argv[4]) if len(sys.argv) > 4 else 2.0

dpy = ctypes.c_void_p(x11.XOpenDisplay(display_name))
if not dpy.value:
    sys.exit(f"cannot open {display_name!r}")


def atom(name):
    return x11.XInternAtom(dpy, name.encode(), False)


A = {
    n: atom(n)
    for n in (
        "XdndAware",
        "XdndSelection",
        "XdndEnter",
        "XdndPosition",
        "XdndStatus",
        "XdndDrop",
        "XdndLeave",
        "XdndFinished",
        "XdndActionCopy",
        "XdndTypeList",
        "text/uri-list",
        "text/plain;charset=utf-8",
        "text/plain",
        "UTF8_STRING",
        "STRING",
        "ODIN_DND_PROP",
    )
}

root = x11.XDefaultRootWindow(dpy)


def prop(win, name_atom):
    """Returns the raw property value, or None."""
    actual_type = Atom()
    actual_format = ctypes.c_int()
    nitems = ctypes.c_ulong()
    bytes_after = ctypes.c_ulong()
    data = ctypes.POINTER(ctypes.c_ubyte)()
    ok = x11.XGetWindowProperty(
        dpy, Window(win), Atom(name_atom), 0, 4, False, AnyPropertyType,
        ctypes.byref(actual_type), ctypes.byref(actual_format),
        ctypes.byref(nitems), ctypes.byref(bytes_after), ctypes.byref(data),
    )
    if ok != 0 or actual_type.value == 0 or not data:
        return None
    out = bytes(bytearray(data[: max(1, nitems.value * (actual_format.value // 8))]))
    x11.XFree(data)
    return out


def find_xdnd_aware(win, depth=0):
    """Depth-first search for a window advertising XdndAware."""
    if prop(win, A["XdndAware"]) is not None:
        return win
    root_ret, parent_ret = Window(), Window()
    children = ctypes.POINTER(Window)()
    n = ctypes.c_uint()
    if not x11.XQueryTree(dpy, Window(win), ctypes.byref(root_ret), ctypes.byref(parent_ret),
                          ctypes.byref(children), ctypes.byref(n)):
        return None
    found = None
    for i in range(n.value):
        found = find_xdnd_aware(children[i], depth + 1)
        if found:
            break
    if children:
        x11.XFree(children)
    return found


time.sleep(delay)

target = find_xdnd_aware(root)
if not target:
    sys.exit("no XdndAware window found - the engine did not advertise a drop target")
print(f"source: target window = 0x{target:x}", flush=True)
aware = prop(target, A["XdndAware"])
print(f"source: target XdndAware = {aware!r}", flush=True)

src = x11.XCreateSimpleWindow(dpy, Window(root), 0, 0, 1, 1, 0, 0, 0)
x11.XSelectInput(dpy, Window(src), 0)
x11.XSetSelectionOwner(dpy, Atom(A["XdndSelection"]), Window(src), 0)
x11.XFlush(dpy)

TYPES = [A["text/uri-list"], A["text/plain;charset=utf-8"], A["text/plain"]]
PAYLOAD = b"file:///home/kelvin/dev/odin-sciter/README.md\r\n"


def send(win, message_type, l0=0, l1=0, l2=0, l3=0, l4=0):
    ev = XEvent()
    ev.xclient.type = ClientMessage
    ev.xclient.display = dpy
    ev.xclient.window = win
    ev.xclient.message_type = message_type
    ev.xclient.format = 32
    for i, v in enumerate((l0, l1, l2, l3, l4)):
        ev.xclient.data[i] = v
    x11.XSendEvent(dpy, Window(win), False, 0, ctypes.byref(ev))
    x11.XFlush(dpy)


XDND_VERSION = 5
send(target, A["XdndEnter"], src, (XDND_VERSION << 24), TYPES[0], TYPES[1], TYPES[2])
print("source: XdndEnter sent", flush=True)
time.sleep(0.2)

send(target, A["XdndPosition"], src, 0, (drop_x << 16) | drop_y, 0, A["XdndActionCopy"])
print(f"source: XdndPosition ({drop_x},{drop_y}) sent", flush=True)

# Pump for XdndStatus, then drop.
deadline = time.time() + 3
status_seen = False
ev = XEvent()
while time.time() < deadline:
    while x11.XPending(dpy):
        x11.XNextEvent(dpy, ctypes.byref(ev))
        if ev.type == ClientMessage and ev.xclient.message_type == A["XdndStatus"]:
            accepted = bool(ev.xclient.data[1] & 1)
            print(f"source: XdndStatus accept={accepted}", flush=True)
            status_seen = True
        elif ev.type == SelectionRequest:
            r = ev.xselectionrequest
            x11.XChangeProperty(dpy, Window(r.requestor), Atom(r.property), Atom(r.target), 8,
                                PropModeReplace, PAYLOAD, len(PAYLOAD))
            out = XEvent()
            out.xselection.type = SelectionNotify
            out.xselection.display = dpy
            out.xselection.requestor = r.requestor
            out.xselection.selection = r.selection
            out.xselection.target = r.target
            out.xselection.property = r.property
            out.xselection.time = r.time
            x11.XSendEvent(dpy, Window(r.requestor), False, 0, ctypes.byref(out))
            x11.XFlush(dpy)
            print("source: answered SelectionRequest with the payload", flush=True)
        elif ev.type == ClientMessage and ev.xclient.message_type == A["XdndFinished"]:
            print("source: XdndFinished", flush=True)
    if status_seen and time.time() > deadline - 2.4:
        break
    time.sleep(0.05)

send(target, A["XdndDrop"], src, 0, 0)
print("source: XdndDrop sent", flush=True)

deadline = time.time() + 3
while time.time() < deadline:
    while x11.XPending(dpy):
        x11.XNextEvent(dpy, ctypes.byref(ev))
        if ev.type == SelectionRequest:
            r = ev.xselectionrequest
            x11.XChangeProperty(dpy, Window(r.requestor), Atom(r.property), Atom(r.target), 8,
                                PropModeReplace, PAYLOAD, len(PAYLOAD))
            out = XEvent()
            out.xselection.type = SelectionNotify
            out.xselection.display = dpy
            out.xselection.requestor = r.requestor
            out.xselection.selection = r.selection
            out.xselection.target = r.target
            out.xselection.property = r.property
            out.xselection.time = r.time
            x11.XSendEvent(dpy, Window(r.requestor), False, 0, ctypes.byref(out))
            x11.XFlush(dpy)
            print("source: answered SelectionRequest with the payload", flush=True)
        elif ev.type == ClientMessage and ev.xclient.message_type == A["XdndFinished"]:
            print("source: XdndFinished", flush=True)
            deadline = 0
    time.sleep(0.05)

print("source: done", flush=True)
