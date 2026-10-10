#include "include/CGtkShim.h"
#include <string.h>

extern void tailscode_soak_note_parse(int hit);

/// Text leaves a model in lumps and is played out of a buffer, so the paragraph on screen is
/// written one character at a time: everything up to the reveal edge is drawn, the last few
/// characters before it carry a wave of colour and opacity, and nothing past the edge is drawn at
/// all. The whole arrived paragraph is laid out once, when it arrives, and a frame afterwards
/// changes what is *painted*, never what is *laid out* — which is the only way a frame stays the
/// same small cost however long the paragraph is. Setting Pango attributes per frame would
/// re-break every line of it, about three microseconds a character, so the reveal lives in the
/// label's snapshot instead.

#define TAILSCODE_REVEAL_WAVE_MAX 64

/// One live row at a time, so one parse is all the cache ever has to hold. Re-rendering markdown
/// and re-parsing markup on every frame was the cost that made a smooth reveal stutter; this makes
/// a frame a substring and a clip.
static char *tailscode_reveal_markup = NULL;
static char *tailscode_reveal_text = NULL;
static PangoAttrList *tailscode_reveal_attrs = NULL;
static int tailscode_reveal_length = 0;
static guint tailscode_reveal_generation = 0;

static gboolean tailscode_reveal_parse(const char *markup) {
    if (tailscode_reveal_markup && strcmp(tailscode_reveal_markup, markup) == 0) {
        tailscode_soak_note_parse(1);
        return TRUE;
    }
    tailscode_soak_note_parse(0);
    PangoAttrList *attrs = NULL;
    char *text = NULL;
    if (!pango_parse_markup(markup, -1, 0, &attrs, &text, NULL, NULL)) return FALSE;
    g_free(tailscode_reveal_markup);
    g_free(tailscode_reveal_text);
    if (tailscode_reveal_attrs) pango_attr_list_unref(tailscode_reveal_attrs);
    tailscode_reveal_markup = g_strdup(markup);
    tailscode_reveal_text = text;
    tailscode_reveal_attrs = attrs;
    tailscode_reveal_length = (int)g_utf8_strlen(text, -1);
    tailscode_reveal_generation++;
    return TRUE;
}

const char *tailscode_markup_text(const char *markup) {
    if (!markup || !tailscode_reveal_parse(markup)) return NULL;
    return tailscode_reveal_text;
}

/// Prose wraps at the pane's width, and a label that stops wrapping runs off the edge of the
/// window. Setting a label's text is not supposed to disturb that, but one silent reset is a
/// paragraph nobody can read — so the properties the transcript depends on are restated rather
/// than assumed.
static void tailscode_label_keep_wrapping(GtkLabel *label) {
    gtk_label_set_wrap(label, TRUE);
    gtk_label_set_wrap_mode(label, PANGO_WRAP_WORD_CHAR);
    gtk_label_set_ellipsize(label, PANGO_ELLIPSIZE_NONE);
    gtk_label_set_xalign(label, 0);
    gtk_label_set_max_width_chars(label, -1);
}

/// A glyph cluster inside the wave: the unit the reveal tints, because a cluster is the smallest
/// thing a font draws as one (a letter and its accents, a ligature, an emoji sequence). Positions
/// are Pango units in the layout's own coordinates.
typedef struct {
    PangoGlyphItem *run;
    int first_glyph;
    int glyph_count;
    int start_byte;
    int end_byte;
    int x;
    int width;
    int baseline;
    int line_top;
    int line_height;
    int distance;
} TailscodeRevealUnit;

/// Everything a frame needs, found without touching the layout: which parts of the paragraph the
/// label's own drawing may show, and the clusters the wave paints itself. The label's own drawing
/// may show every line above `above`, and the part of the line at `line_top` that lies left of
/// `edge_x`; the rest of the revealed words are the wave's. Distances are layout pixels.
typedef struct {
    gboolean fallback;
    gboolean empty;
    gboolean tinted;
    gboolean has_line;
    double above;
    double line_top;
    double line_height;
    double edge_x;
    int unit_count;
    TailscodeRevealUnit units[TAILSCODE_REVEAL_WAVE_MAX];
} TailscodeRevealPlan;

/// Walks the clusters between the wave's first character and the reveal edge, on the lines that
/// hold them. The cost is the wave and the lines above it, never the paragraph: lines are reached
/// by index, and a line is only read once it is known to hold part of the wave.
///
/// Right-to-left runs make "left of this cluster" mean the wrong thing, so a paragraph whose
/// wave touches one is marked `fallback` and drawn whole by the label itself — its words arrive
/// at arrival granularity rather than being drawn wrongly.
static void tailscode_reveal_scan(
    PangoLayout *layout, int edge_bytes, int wave, TailscodeRevealPlan *plan) {
    const char *text = pango_layout_get_text(layout);
    plan->fallback = FALSE;
    plan->empty = edge_bytes <= 0;
    plan->unit_count = 0;
    plan->has_line = FALSE;
    plan->tinted = wave > 0;
    if (plan->empty) return;
    int span = wave < 1 ? 1 : (wave > TAILSCODE_REVEAL_WAVE_MAX ? TAILSCODE_REVEAL_WAVE_MAX : wave);
    const char *cursor = text + edge_bytes;
    for (int index = 0; index < span; index++) {
        const char *previous = g_utf8_find_prev_char(text, cursor);
        if (!previous) break;
        cursor = previous;
    }
    int scan_start = (int)(cursor - text);
    int first_line = 0;
    pango_layout_index_to_line_x(layout, scan_start, FALSE, &first_line, NULL);
    PangoLayoutIter *iter = pango_layout_get_iter(layout);
    for (int index = 0; index < first_line; index++)
        if (!pango_layout_iter_next_line(iter)) break;
    gboolean done = FALSE;
    gboolean first = TRUE;
    int first_top = 0;
    do {
        PangoLayoutLine *line = pango_layout_iter_get_line_readonly(iter);
        if (line->start_index >= edge_bytes) break;
        PangoRectangle logical;
        pango_layout_iter_get_line_extents(iter, NULL, &logical);
        int baseline = pango_layout_iter_get_baseline(iter);
        if (first) first_top = logical.y;
        first = FALSE;
        int x = logical.x;
        for (GSList *node = line->runs; node && !done; node = node->next) {
            PangoGlyphItem *run = node->data;
            if (run->item->analysis.level & 1) {
                plan->fallback = TRUE;
                done = TRUE;
                break;
            }
            PangoGlyphString *glyphs = run->glyphs;
            int run_start = run->item->offset;
            int run_end = run_start + run->item->length;
            x += run->start_x_offset;
            if (run_end <= scan_start) {
                x += pango_glyph_string_get_width(glyphs) + run->end_x_offset;
                continue;
            }
            if (run_start >= edge_bytes) {
                done = TRUE;
                break;
            }
            int glyph = 0;
            while (glyph < glyphs->num_glyphs) {
                int cluster = glyphs->log_clusters[glyph];
                int next = glyph;
                int width = 0;
                while (next < glyphs->num_glyphs && glyphs->log_clusters[next] == cluster) {
                    width += glyphs->glyphs[next].geometry.width;
                    next++;
                }
                int unit_start = run_start + cluster;
                int unit_end =
                    next < glyphs->num_glyphs ? run_start + glyphs->log_clusters[next] : run_end;
                if (unit_end > scan_start) {
                    if (unit_end > edge_bytes || plan->unit_count >= TAILSCODE_REVEAL_WAVE_MAX) {
                        done = TRUE;
                        break;
                    }
                    TailscodeRevealUnit *unit = &plan->units[plan->unit_count++];
                    unit->run = run;
                    unit->first_glyph = glyph;
                    unit->glyph_count = next - glyph;
                    unit->start_byte = unit_start;
                    unit->end_byte = unit_end;
                    unit->x = x;
                    unit->width = width;
                    unit->baseline = baseline - run->y_offset;
                    unit->line_top = logical.y;
                    unit->line_height = logical.height;
                    unit->distance = (int)g_utf8_strlen(text + unit_end, edge_bytes - unit_end);
                }
                x += width;
                glyph = next;
            }
            x += run->end_x_offset;
        }
    } while (!done && pango_layout_iter_next_line(iter));
    pango_layout_iter_free(iter);
    if (plan->fallback) return;
    if (plan->unit_count == 0) {
        plan->tinted = FALSE;
        plan->above = (double)first_top / PANGO_SCALE;
        return;
    }
    const TailscodeRevealUnit *boundary =
        plan->tinted ? &plan->units[0] : &plan->units[plan->unit_count - 1];
    plan->has_line = TRUE;
    plan->above = (double)boundary->line_top / PANGO_SCALE;
    plan->line_top = plan->above;
    plan->line_height = (double)boundary->line_height / PANGO_SCALE;
    plan->edge_x = (double)(plan->tinted ? boundary->x : boundary->x + boundary->width) / PANGO_SCALE;
}

/// What a reveal label remembers between frames. It rides in the instance's private data because
/// `GtkLabel`'s own structure is not public: the type is registered at the size GTK reports for a
/// label, and this is added after it.
typedef struct {
    gboolean active;
    int visible;
    int wave;
    guint32 rgb[TAILSCODE_REVEAL_WAVE_MAX];
    guint16 alpha[TAILSCODE_REVEAL_WAVE_MAX];
    guint edge_generation;
    int edge_chars;
    int edge_bytes;
} TailscodeRevealState;

static gint tailscode_reveal_label_offset = 0;
static gpointer tailscode_reveal_label_parent_class = NULL;

static TailscodeRevealState *tailscode_reveal_state(gpointer label) {
    return G_STRUCT_MEMBER_P(label, tailscode_reveal_label_offset);
}

static void tailscode_reveal_label_snapshot(GtkWidget *widget, GtkSnapshot *snapshot);

static void tailscode_reveal_label_class_init(gpointer klass, gpointer data) {
    (void)data;
    tailscode_reveal_label_parent_class = g_type_class_peek_parent(klass);
    g_type_class_adjust_private_offset(klass, &tailscode_reveal_label_offset);
    GtkWidgetClass *widget_class = GTK_WIDGET_CLASS(klass);
    widget_class->snapshot = tailscode_reveal_label_snapshot;
    gtk_widget_class_set_css_name(widget_class, "label");
    gtk_widget_class_set_accessible_role(widget_class, GTK_ACCESSIBLE_ROLE_LABEL);
}

/// Registered by hand at the size GTK reports for `GtkLabel`, because a label's structure is
/// private to GTK and the usual `G_DEFINE_TYPE` cannot name its size.
static GType tailscode_reveal_label_get_type(void) {
    static gsize registered = 0;
    if (g_once_init_enter(&registered)) {
        GTypeQuery query;
        g_type_query(GTK_TYPE_LABEL, &query);
        GType type = g_type_register_static_simple(
            GTK_TYPE_LABEL, "TailscodeRevealLabel", query.class_size,
            tailscode_reveal_label_class_init, query.instance_size, NULL, 0);
        tailscode_reveal_label_offset =
            g_type_add_instance_private(type, sizeof(TailscodeRevealState));
        g_once_init_leave(&registered, type);
    }
    return (GType)registered;
}

#define TAILSCODE_IS_REVEAL_LABEL(widget) \
    G_TYPE_CHECK_INSTANCE_TYPE((widget), tailscode_reveal_label_get_type())

/// The colour a glyph cluster is painted in: the packed RGB and 16-bit opacity the shared wave
/// computed for the character nearest the edge that the cluster holds.
static GdkRGBA tailscode_reveal_colour(const TailscodeRevealState *self, int distance) {
    int index = distance < self->wave ? distance : self->wave - 1;
    guint32 rgb = self->rgb[index];
    return (GdkRGBA){
        (float)((rgb >> 16) & 0xff) / 255.0f, (float)((rgb >> 8) & 0xff) / 255.0f,
        (float)(rgb & 0xff) / 255.0f, (float)self->alpha[index] / 65535.0f};
}

/// The thin rules a run can carry (a link's underline, a struck-out word), put where the font
/// says they go. The glyphs of the wave are drawn by hand, so the rules that sat under them in the
/// label's own drawing have to be drawn by hand too, or a link would lose its underline for
/// exactly the characters the reader is looking at.
static void tailscode_reveal_rules(
    GtkSnapshot *snapshot, const TailscodeRevealUnit *unit, const GdkRGBA *colour) {
    gboolean underline = FALSE, strike = FALSE;
    for (GSList *node = unit->run->item->analysis.extra_attrs; node; node = node->next) {
        PangoAttribute *attribute = node->data;
        if (attribute->klass->type == PANGO_ATTR_UNDERLINE &&
            ((PangoAttrInt *)attribute)->value != PANGO_UNDERLINE_NONE)
            underline = TRUE;
        if (attribute->klass->type == PANGO_ATTR_STRIKETHROUGH && ((PangoAttrInt *)attribute)->value)
            strike = TRUE;
    }
    if (!underline && !strike) return;
    PangoFont *font = unit->run->item->analysis.font;
    PangoFontMetrics *metrics = pango_font_get_metrics(font, unit->run->item->analysis.language);
    double left = (double)unit->x / PANGO_SCALE;
    double width = (double)unit->width / PANGO_SCALE;
    if (underline) {
        graphene_rect_t rule = GRAPHENE_RECT_INIT(
            left,
            (float)(unit->baseline - pango_font_metrics_get_underline_position(metrics)) / PANGO_SCALE,
            width, (float)pango_font_metrics_get_underline_thickness(metrics) / PANGO_SCALE);
        gtk_snapshot_append_color(snapshot, colour, &rule);
    }
    if (strike) {
        graphene_rect_t rule = GRAPHENE_RECT_INIT(
            left,
            (float)(unit->baseline - pango_font_metrics_get_strikethrough_position(metrics)) /
                PANGO_SCALE,
            width, (float)pango_font_metrics_get_strikethrough_thickness(metrics) / PANGO_SCALE);
        gtk_snapshot_append_color(snapshot, colour, &rule);
    }
    pango_font_metrics_unref(metrics);
}

/// One cluster of the wave, in its own colour. The glyphs are the layout's own, at the layout's
/// own positions, so a tinted cluster lands exactly where the label's drawing would have put it.
static void tailscode_reveal_paint_unit(
    GtkSnapshot *snapshot, const TailscodeRevealUnit *unit, const GdkRGBA *colour) {
    PangoGlyphString *glyphs = pango_glyph_string_new();
    pango_glyph_string_set_size(glyphs, unit->glyph_count);
    for (int index = 0; index < unit->glyph_count; index++) {
        glyphs->glyphs[index] = unit->run->glyphs->glyphs[unit->first_glyph + index];
        glyphs->log_clusters[index] = 0;
    }
    graphene_point_t origin = GRAPHENE_POINT_INIT(
        (float)unit->x / PANGO_SCALE, (float)unit->baseline / PANGO_SCALE);
    GskRenderNode *node =
        gsk_text_node_new(unit->run->item->analysis.font, glyphs, colour, &origin);
    if (node) {
        gtk_snapshot_append_node(snapshot, node);
        gsk_render_node_unref(node);
    }
    pango_glyph_string_free(glyphs);
    tailscode_reveal_rules(snapshot, unit, colour);
}

typedef struct {
    double x, y, w, h;
} TailscodeRevealClip;

/// The rectangles, in widget coordinates, that the label's own drawing is allowed to fill: the
/// band above the line the wave starts on, and that line up to the wave. A rectangle with no
/// area is left out.
static int tailscode_reveal_clips(
    const TailscodeRevealPlan *plan, GtkWidget *widget, int offset_x, int offset_y,
    TailscodeRevealClip clips[2]) {
    int count = 0;
    double above = plan->above + offset_y;
    if (above > 0) clips[count++] = (TailscodeRevealClip){0, 0, gtk_widget_get_width(widget), above};
    if (plan->has_line && plan->edge_x + offset_x > 0 && plan->line_height > 0)
        clips[count++] = (TailscodeRevealClip){
            0, plan->line_top + offset_y, plan->edge_x + offset_x, plan->line_height};
    return count;
}

static void tailscode_reveal_label_snapshot(GtkWidget *widget, GtkSnapshot *snapshot) {
    TailscodeRevealState *self = tailscode_reveal_state(widget);
    GtkWidgetClass *parent = GTK_WIDGET_CLASS(tailscode_reveal_label_parent_class);
    PangoLayout *layout = self->active ? gtk_label_get_layout(GTK_LABEL(widget)) : NULL;
    if (!layout) {
        parent->snapshot(widget, snapshot);
        return;
    }
    TailscodeRevealPlan plan;
    int edge_bytes = (int)MIN((gsize)self->edge_bytes, strlen(pango_layout_get_text(layout)));
    tailscode_reveal_scan(layout, edge_bytes, self->wave, &plan);
    if (plan.fallback) {
        parent->snapshot(widget, snapshot);
        return;
    }
    if (plan.empty) return;
    int offset_x = 0, offset_y = 0;
    gtk_label_get_layout_offsets(GTK_LABEL(widget), &offset_x, &offset_y);
    GtkSnapshot *inner = gtk_snapshot_new();
    parent->snapshot(widget, inner);
    GskRenderNode *base = gtk_snapshot_free_to_node(inner);
    if (base) {
        TailscodeRevealClip clips[2];
        int count = tailscode_reveal_clips(&plan, widget, offset_x, offset_y, clips);
        for (int index = 0; index < count; index++) {
            graphene_rect_t rect =
                GRAPHENE_RECT_INIT(clips[index].x, clips[index].y, clips[index].w, clips[index].h);
            gtk_snapshot_push_clip(snapshot, &rect);
            gtk_snapshot_append_node(snapshot, base);
            gtk_snapshot_pop(snapshot);
        }
        gsk_render_node_unref(base);
    }
    if (!plan.tinted) return;
    gtk_snapshot_save(snapshot);
    graphene_point_t origin = GRAPHENE_POINT_INIT(offset_x, offset_y);
    gtk_snapshot_translate(snapshot, &origin);
    for (int index = 0; index < plan.unit_count; index++) {
        GdkRGBA colour = tailscode_reveal_colour(self, plan.units[index].distance);
        if (colour.alpha <= 0.0f) continue;
        tailscode_reveal_paint_unit(snapshot, &plan.units[index], &colour);
    }
    gtk_snapshot_restore(snapshot);
}

GtkWidget *tailscode_reveal_label_new(void) {
    return g_object_new(tailscode_reveal_label_get_type(), NULL);
}

/// Where the reveal edge sits in the label's text, in bytes. A reveal only moves forward within an
/// arrival, so the previous answer is the starting point and a frame walks the characters that
/// were added rather than the whole paragraph.
static int tailscode_reveal_edge_bytes(TailscodeRevealState *self, int seen) {
    const char *text = tailscode_reveal_text;
    if (self->edge_generation == tailscode_reveal_generation && seen >= self->edge_chars) {
        const char *edge =
            g_utf8_offset_to_pointer(text + self->edge_bytes, seen - self->edge_chars);
        self->edge_chars = seen;
        self->edge_bytes = (int)(edge - text);
        return self->edge_bytes;
    }
    const char *edge = g_utf8_offset_to_pointer(text, seen);
    self->edge_generation = tailscode_reveal_generation;
    self->edge_chars = seen;
    self->edge_bytes = (int)(edge - text);
    return self->edge_bytes;
}

int tailscode_label_reveal(
    GtkWidget *label, const char *markup, int visible, int wave,
    const unsigned int *rgb, const unsigned short *alpha) {
    if (!label || !GTK_IS_LABEL(label) || !markup || !TAILSCODE_IS_REVEAL_LABEL(label)) return -1;
    TailscodeRevealState *self = tailscode_reveal_state(label);
    if (!tailscode_reveal_parse(markup)) return -1;
    int length = tailscode_reveal_length;
    if (visible < 0) {
        self->active = FALSE;
        gtk_label_set_attributes(GTK_LABEL(label), NULL);
        gtk_label_set_markup(GTK_LABEL(label), markup);
        tailscode_label_keep_wrapping(GTK_LABEL(label));
        const char *landed = gtk_label_get_text(GTK_LABEL(label));
        if (!landed || strcmp(landed, tailscode_reveal_text) != 0) return -1;
        gtk_widget_queue_draw(label);
        return length;
    }

    const char *shown = gtk_label_get_text(GTK_LABEL(label));
    if (!shown || strcmp(shown, tailscode_reveal_text) != 0) {
        gtk_label_set_text(GTK_LABEL(label), tailscode_reveal_text);
        gtk_label_set_attributes(GTK_LABEL(label), tailscode_reveal_attrs);
        tailscode_label_keep_wrapping(GTK_LABEL(label));
        self->edge_generation = 0;
    }

    int seen = CLAMP(visible, 0, length);
    int count = wave > TAILSCODE_REVEAL_WAVE_MAX ? TAILSCODE_REVEAL_WAVE_MAX : (wave < 0 ? 0 : wave);
    if (!rgb || !alpha) count = 0;
    for (int index = 0; index < count; index++) {
        self->rgb[index] = rgb[index];
        self->alpha[index] = alpha[index];
    }
    self->wave = count;
    self->visible = seen;
    tailscode_reveal_edge_bytes(self, seen);
    self->active = TRUE;
    gtk_widget_queue_draw(label);
    return length;
}

int tailscode_label_reveal_plan(
    GtkWidget *label, int visible, int wave, double *out, int capacity) {
    if (!label || !TAILSCODE_IS_REVEAL_LABEL(label) || !out) return -1;
    PangoLayout *layout = gtk_label_get_layout(GTK_LABEL(label));
    if (!layout) return -1;
    const char *text = pango_layout_get_text(layout);
    int total = (int)g_utf8_strlen(text, -1);
    int seen = CLAMP(visible, 0, total);
    int edge_bytes = (int)(g_utf8_offset_to_pointer(text, seen) - text);
    TailscodeRevealPlan plan;
    tailscode_reveal_scan(layout, edge_bytes, wave, &plan);
    int needed = 4 + 8 + plan.unit_count * 6;
    if (capacity < needed) return -1;
    int offset_x = 0, offset_y = 0;
    gtk_label_get_layout_offsets(GTK_LABEL(label), &offset_x, &offset_y);
    TailscodeRevealClip clips[2];
    int count = tailscode_reveal_clips(&plan, label, offset_x, offset_y, clips);
    int cursor = 0;
    out[cursor++] = plan.fallback ? 1 : 0;
    out[cursor++] = plan.empty ? 1 : 0;
    out[cursor++] = count;
    out[cursor++] = plan.unit_count;
    for (int index = 0; index < 2; index++) {
        TailscodeRevealClip clip = index < count ? clips[index] : (TailscodeRevealClip){0, 0, 0, 0};
        out[cursor++] = clip.x;
        out[cursor++] = clip.y;
        out[cursor++] = clip.w;
        out[cursor++] = clip.h;
    }
    for (int index = 0; index < plan.unit_count; index++) {
        const TailscodeRevealUnit *unit = &plan.units[index];
        out[cursor++] = offset_x + (double)unit->x / PANGO_SCALE;
        out[cursor++] = offset_y + (double)unit->line_top / PANGO_SCALE;
        out[cursor++] = (double)unit->width / PANGO_SCALE;
        out[cursor++] = (double)unit->line_height / PANGO_SCALE;
        out[cursor++] = (double)g_utf8_strlen(text, unit->start_byte);
        out[cursor++] =
            (double)g_utf8_strlen(text + unit->start_byte, unit->end_byte - unit->start_byte);
    }
    return needed;
}

double tailscode_label_revealed_height(GtkWidget *label, int visible) {
    if (!label || !GTK_IS_LABEL(label)) return -1;
    PangoLayout *layout = gtk_label_get_layout(GTK_LABEL(label));
    if (!layout) return -1;
    int offset_x = 0, offset_y = 0;
    gtk_label_get_layout_offsets(GTK_LABEL(label), &offset_x, &offset_y);
    if (visible <= 0) return offset_y;
    const char *text = pango_layout_get_text(layout);
    if (!text) return -1;
    long total = g_utf8_strlen(text, -1);
    if (visible >= total) {
        int width = 0, height = 0;
        pango_layout_get_pixel_size(layout, &width, &height);
        return offset_y + height;
    }
    const char *edge = g_utf8_offset_to_pointer(text, visible - 1);
    PangoRectangle pos;
    pango_layout_index_to_pos(layout, (int)(edge - text), &pos);
    return offset_y + (double)(pos.y + pos.height) / PANGO_SCALE;
}
