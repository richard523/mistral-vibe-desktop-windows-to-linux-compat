#!/usr/bin/env python3
# vibe-tray: GNOME top-bar (AppIndicator) tray icon for Mistral Vibe Desktop.
#
# The app's own Windows tray icon never reaches the Linux desktop (wine has no
# SNI/XEmbed owner under GNOME), so this provides the clickable icon instead:
#   left-click / "Show Vibe"  -> run the launcher, which shows the window if the
#                                app is running (incl. windowless close-to-tray)
#                                or launches the app if it is not running
#   "Quit Vibe"               -> kill the app
# Started by the vibe-desktop launcher and via XDG autostart; tiny resident cost.
import os
import subprocess

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import Gtk, AyatanaAppIndicator3, GLib

ICON = os.path.expanduser("~/.local/share/icons/hicolor/128x128/apps/mistral-vibe-desktop.png")
LAUNCHER = os.path.expanduser("~/.local/bin/vibe-desktop")
APP_PATTERN = r"Vibe\.exe"


def app_alive():
    return subprocess.run(["pgrep", "-f", APP_PATTERN], capture_output=True).returncode == 0


def show_vibe(*_args):
    subprocess.Popen([LAUNCHER])


def quit_vibe(*_args):
    subprocess.run(["pkill", "-f", APP_PATTERN])
    Gtk.main_quit()


def main():
    ind = AyatanaAppIndicator3.Indicator.new(
        "mistral-vibe-desktop", ICON, AyatanaAppIndicator3.IndicatorCategory.APPLICATION_STATUS
    )
    ind.set_status(AyatanaAppIndicator3.IndicatorStatus.ACTIVE)
    ind.set_title("Mistral Vibe Desktop")

    menu = Gtk.Menu()
    mi_show = Gtk.MenuItem(label="Show Vibe")
    mi_show.connect("activate", show_vibe)
    mi_quit = Gtk.MenuItem(label="Quit Vibe")
    mi_quit.connect("activate", quit_vibe)
    menu.append(mi_show)
    menu.append(mi_quit)
    menu.show_all()
    ind.set_menu(menu)
    ind.connect("activate", show_vibe)  # left click

    def refresh(*_a):
        # dim the icon when the app is not running (click still launches it)
        ind.set_status(
            AyatanaAppIndicator3.IndicatorStatus.ACTIVE
            if app_alive()
            else AyatanaAppIndicator3.IndicatorStatus.PASSIVE
        )
        return True

    GLib.timeout_add_seconds(2, refresh)
    Gtk.main()


if __name__ == "__main__":
    main()
