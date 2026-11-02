#ifndef TAILSCODE_STAGE_H
#define TAILSCODE_STAGE_H

#include <gtk/gtk.h>

/// The quick ask's card on the desktop: `hit` answers which edges (1 left, 2 right, 4 top,
/// 8 bottom) a point measured from the card's corner takes hold of; `drag` is told a hold
/// beginning (phase 0), moving (1) and letting go (2), with 16 for the whole card moved by its
/// ground. `room` is the overlay the card is drawn in, which takes the presses on its border; with
/// none the card is an ordinary window: its ground asks the desktop to move it and its edges are
/// the desktop's.
typedef int (*TailscodeStageHit)(double x, double y, double width, double height, void *data);
typedef void (*TailscodeStageDrag)(int phase, int edges, double dx, double dy, void *data);
void tailscode_stage_track(GtkWidget *card, GtkWidget *room, TailscodeStageHit hit,
                           TailscodeStageDrag drag, void *data);
/// A press anywhere on `room` that is not on `card`.
void tailscode_stage_backdrop(GtkWidget *room, GtkWidget *card, void (*handler)(void *),
                              void *data);
/// A surface-filling widget that gives its one child exactly the rectangle last placed.
GtkWidget *tailscode_stage_room(void);
void tailscode_stage_room_place(GtkWidget *room, double x, double y, double width,
                                double height);
/// Called once, the first frame `widget` has a size.
void tailscode_when_sized(GtkWidget *widget, void (*handler)(int width, int height, void *),
                          void *data);

#endif
