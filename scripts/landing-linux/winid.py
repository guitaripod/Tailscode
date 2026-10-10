import sys
from Xlib import display
d = display.Display(":87")
title = sys.argv[1]
ids = [w.id for w in d.screen().root.query_tree().children if w.get_wm_name() == title and w.get_attributes().map_state == 2]
print(hex(ids[-1]) if ids else "", end="")
