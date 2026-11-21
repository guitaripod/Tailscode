#include "include/CGtkShim.h"
#include <hb.h>
#include <math.h>
#include <string.h>

#define TERM_PADDING 6
#define TERM_FALLBACK_LIMIT 2048

static gint term_rows_built = 0;
static gint term_snapshots = 0;

#define TAILSCODE_TYPE_TERM_VIEW (tailscode_term_view_get_type())
G_DECLARE_FINAL_TYPE(TailscodeTermView, tailscode_term_view, TAILSCODE, TERM_VIEW, GtkWidget)

typedef struct {
    PangoFont *font;
    hb_font_t *shaper;
    PangoGlyph ascii[128];
} TermFace;

struct _TailscodeTermView {
    GtkWidget parent_instance;
    TailscodeTermCallbacks callbacks;
    void *data;
    void (*destroy)(void *);
    GtkIMContext *input;
    char *family;
    double points;
    double scale;
    PangoFontDescription *description;
    TermFace faces[4];
    gboolean faces_ready;
    double cell_width;
    double cell_height;
    double ascent;
    double underline_offset;
    double strike_offset;
    double line_thickness;
    GHashTable *fallbacks;
    GskRenderNode **rows;
    int row_count;
    int cols;
    int grid_cols;
    int grid_rows;
    GdkRGBA background;
    GdkRGBA cursor_color;
    gboolean cursor_visible;
    gboolean cursor_blinking;
    int cursor_style;
    int cursor_x;
    int cursor_y;
    TSCell cursor_cell;
    uint32_t cursor_extras[16];
    guint64 scroll_total;
    guint64 scroll_offset;
    guint64 scroll_length;
    gboolean focused;
    gboolean blink_on;
    guint blink_source;
    guint tick_id;
    gboolean pressed;
};

G_DEFINE_FINAL_TYPE(TailscodeTermView, tailscode_term_view, GTK_TYPE_WIDGET)

static GdkRGBA term_rgba(uint32_t rgb, float alpha) {
    GdkRGBA color = {
        .red = (float)((rgb >> 16) & 0xff) / 255.0f,
        .green = (float)((rgb >> 8) & 0xff) / 255.0f,
        .blue = (float)(rgb & 0xff) / 255.0f,
        .alpha = alpha,
    };
    return color;
}

static void term_drop_rows(TailscodeTermView *self) {
    for (int row = 0; row < self->row_count; row++) {
        if (self->rows[row]) gsk_render_node_unref(self->rows[row]);
    }
    g_free(self->rows);
    self->rows = NULL;
    self->row_count = 0;
}

static void term_drop_faces(TailscodeTermView *self) {
    for (int index = 0; index < 4; index++) {
        g_clear_object(&self->faces[index].font);
        self->faces[index].shaper = NULL;
    }
    self->faces_ready = FALSE;
    if (self->fallbacks) g_hash_table_remove_all(self->fallbacks);
}

static double term_surface_scale(TailscodeTermView *self) {
    GtkNative *native = gtk_widget_get_native(GTK_WIDGET(self));
    GdkSurface *surface = native ? gtk_native_get_surface(native) : NULL;
    if (surface) return gdk_surface_get_scale(surface);
    return (double)gtk_widget_get_scale_factor(GTK_WIDGET(self));
}

static double term_snap(TailscodeTermView *self, double value) {
    return ceil(value * self->scale) / self->scale;
}

/// Loads the four faces and measures a cell. A cell is as wide as the face's own advance, rounded
/// up to a whole device pixel so no column is drawn between two.
static void term_load_faces(TailscodeTermView *self) {
    if (self->faces_ready) return;
    PangoContext *context = gtk_widget_get_pango_context(GTK_WIDGET(self));
    self->scale = term_surface_scale(self);
    if (self->scale <= 0) self->scale = 1;
    g_clear_pointer(&self->description, pango_font_description_free);
    self->description = pango_font_description_new();
    pango_font_description_set_family(self->description, self->family ? self->family : "monospace");
    pango_font_description_set_size(self->description, (int)lround(self->points * PANGO_SCALE));
    for (int index = 0; index < 4; index++) {
        PangoFontDescription *face = pango_font_description_copy(self->description);
        pango_font_description_set_weight(face, (index & 1) ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL);
        pango_font_description_set_style(face, (index & 2) ? PANGO_STYLE_ITALIC : PANGO_STYLE_NORMAL);
        self->faces[index].font = pango_context_load_font(context, face);
        pango_font_description_free(face);
        self->faces[index].shaper = self->faces[index].font ? pango_font_get_hb_font(self->faces[index].font) : NULL;
        for (int code = 0; code < 128; code++) {
            hb_codepoint_t glyph = 0;
            gboolean found = self->faces[index].shaper && code >= 0x20 && code < 0x7f &&
                             hb_font_get_nominal_glyph(self->faces[index].shaper, (hb_codepoint_t)code, &glyph);
            self->faces[index].ascii[code] = found ? glyph : PANGO_GLYPH_EMPTY;
        }
    }
    PangoFont *regular = self->faces[0].font;
    if (!regular) return;
    PangoFontMetrics *metrics = pango_font_get_metrics(regular, pango_context_get_language(context));
    PangoRectangle logical = {0};
    PangoGlyph measure = self->faces[0].ascii['M'];
    if (measure != PANGO_GLYPH_EMPTY) pango_font_get_glyph_extents(regular, measure, NULL, &logical);
    double advance = logical.width > 0 ? (double)logical.width / PANGO_SCALE
                                       : (double)pango_font_metrics_get_approximate_digit_width(metrics) / PANGO_SCALE;
    double ascent = (double)pango_font_metrics_get_ascent(metrics) / PANGO_SCALE;
    double descent = (double)pango_font_metrics_get_descent(metrics) / PANGO_SCALE;
    self->cell_width = fmax(term_snap(self, advance), 1);
    self->cell_height = fmax(term_snap(self, ascent + descent), 1);
    self->ascent = round(ascent * self->scale) / self->scale;
    self->line_thickness = fmax(round((double)pango_font_metrics_get_underline_thickness(metrics) / PANGO_SCALE * self->scale), 1) / self->scale;
    self->underline_offset = fmin(self->ascent - (double)pango_font_metrics_get_underline_position(metrics) / PANGO_SCALE,
                                  self->cell_height - self->line_thickness);
    self->strike_offset = self->ascent - (double)pango_font_metrics_get_strikethrough_position(metrics) / PANGO_SCALE;
    pango_font_metrics_unref(metrics);
    self->faces_ready = TRUE;
}

static void term_report_size(TailscodeTermView *self) {
    term_load_faces(self);
    int width = gtk_widget_get_width(GTK_WIDGET(self));
    int height = gtk_widget_get_height(GTK_WIDGET(self));
    if (!self->faces_ready || width <= 0 || height <= 0) return;
    int cols = (int)floor((width - 2 * TERM_PADDING) / self->cell_width);
    int rows = (int)floor((height - 2 * TERM_PADDING) / self->cell_height);
    if (cols < 2) cols = 2;
    if (rows < 1) rows = 1;
    if (cols == self->grid_cols && rows == self->grid_rows) return;
    self->grid_cols = cols;
    self->grid_rows = rows;
    if (self->callbacks.resized) {
        self->callbacks.resized(
            cols, rows, (int)lround(self->cell_width * self->scale), (int)lround(self->cell_height * self->scale),
            (int)lround(TERM_PADDING * self->scale), (int)lround(width * self->scale),
            (int)lround(height * self->scale), self->data);
    }
}

static PangoGlyph term_glyph(TermFace *face, uint32_t codepoint) {
    if (codepoint < 128) return face->ascii[codepoint];
    hb_codepoint_t glyph = 0;
    if (face->shaper && hb_font_get_nominal_glyph(face->shaper, codepoint, &glyph)) return glyph;
    return PANGO_GLYPH_EMPTY;
}

static int term_face_index(const TSCell *cell) {
    return ((cell->flags & TS_CELL_BOLD) ? 1 : 0) | ((cell->flags & TS_CELL_ITALIC) ? 2 : 0);
}

/// A character the face has no glyph for, or one made of several codepoints: laid out by Pango,
/// which finds a font that has it, and kept so the next frame does not lay it out again.
static void term_draw_fallback(
    TailscodeTermView *self, GtkSnapshot *snapshot, const TSCell *cell, const uint32_t *extras, double x,
    const GdkRGBA *color) {
    gunichar codepoints[18];
    int count = 0;
    codepoints[count++] = cell->codepoint;
    for (int index = 0; index < cell->extra && count < 17 && extras; index++) {
        codepoints[count++] = extras[cell->extra_offset + index];
    }
    char *text = g_ucs4_to_utf8(codepoints, count, NULL, NULL, NULL);
    if (!text) return;
    char *key = g_strdup_printf("%d:%s", term_face_index(cell), text);
    PangoLayout *layout = g_hash_table_lookup(self->fallbacks, key);
    if (!layout) {
        if (g_hash_table_size(self->fallbacks) >= TERM_FALLBACK_LIMIT) g_hash_table_remove_all(self->fallbacks);
        layout = pango_layout_new(gtk_widget_get_pango_context(GTK_WIDGET(self)));
        PangoFontDescription *face = pango_font_description_copy(self->description);
        if (cell->flags & TS_CELL_BOLD) pango_font_description_set_weight(face, PANGO_WEIGHT_BOLD);
        if (cell->flags & TS_CELL_ITALIC) pango_font_description_set_style(face, PANGO_STYLE_ITALIC);
        pango_layout_set_font_description(layout, face);
        pango_font_description_free(face);
        pango_layout_set_text(layout, text, -1);
        g_hash_table_insert(self->fallbacks, g_strdup(key), layout);
    }
    double baseline = (double)pango_layout_get_baseline(layout) / PANGO_SCALE;
    gtk_snapshot_save(snapshot);
    gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT((float)x, (float)(self->ascent - baseline)));
    gtk_snapshot_append_layout(snapshot, layout, color);
    gtk_snapshot_restore(snapshot);
    g_free(key);
    g_free(text);
}

static gboolean term_draw_box(
    TailscodeTermView *self, GtkSnapshot *snapshot, const TSCell *cell, double x, const GdkRGBA *color) {
    TSBoxRect rects[TS_BOX_RECTS_MAX];
    double width = self->cell_width * (cell->width == 2 ? 2 : 1);
    size_t count = ts_box_drawing(cell->codepoint, (float)width, (float)self->cell_height, (float)self->scale, rects);
    for (size_t index = 0; index < count; index++) {
        GdkRGBA shade = *color;
        shade.alpha *= rects[index].alpha;
        gtk_snapshot_append_color(
            snapshot, &shade,
            &GRAPHENE_RECT_INIT((float)x + rects[index].x, rects[index].y, rects[index].width, rects[index].height));
    }
    return count > 0;
}

typedef struct {
    PangoGlyphString *glyphs;
    int count;
    int face;
    uint32_t color;
    double x;
} TermRun;

static void term_flush_run(TailscodeTermView *self, GtkSnapshot *snapshot, TermRun *run) {
    if (run->count == 0) return;
    pango_glyph_string_set_size(run->glyphs, run->count);
    GdkRGBA color = term_rgba(run->color, 1);
    GskRenderNode *node = gsk_text_node_new(
        self->faces[run->face].font, run->glyphs, &color,
        &GRAPHENE_POINT_INIT((float)run->x, (float)self->ascent));
    if (node) {
        gtk_snapshot_append_node(snapshot, node);
        gsk_render_node_unref(node);
    }
    run->count = 0;
}

static void term_draw_decorations(TailscodeTermView *self, GtkSnapshot *snapshot, const TSCell *cell, double x) {
    double width = self->cell_width * (cell->width == 2 ? 2 : 1);
    double thick = self->line_thickness;
    GdkRGBA ink = term_rgba(cell->fg, 1);
    if (cell->flags & TS_CELL_STRIKETHROUGH) {
        gtk_snapshot_append_color(snapshot, &ink, &GRAPHENE_RECT_INIT((float)x, (float)self->strike_offset, (float)width, (float)thick));
    }
    if (cell->flags & TS_CELL_OVERLINE) {
        gtk_snapshot_append_color(snapshot, &ink, &GRAPHENE_RECT_INIT((float)x, 0, (float)width, (float)thick));
    }
    int underline = (cell->flags & TS_CELL_UNDERLINE_MASK) >> TS_CELL_UNDERLINE_SHIFT;
    if (underline == TS_UNDERLINE_NONE) return;
    GdkRGBA line = term_rgba(cell->decoration, 1);
    double y = self->underline_offset;
    double pixel = 1 / self->scale;
    switch (underline) {
        case TS_UNDERLINE_DOUBLE:
            gtk_snapshot_append_color(snapshot, &line, &GRAPHENE_RECT_INIT((float)x, (float)(y - thick - pixel), (float)width, (float)thick));
            gtk_snapshot_append_color(snapshot, &line, &GRAPHENE_RECT_INIT((float)x, (float)y, (float)width, (float)thick));
            break;
        case TS_UNDERLINE_CURLY: {
            double step = fmax(thick * 2, 2 * pixel);
            int index = 0;
            for (double at = 0; at < width; at += step, index++) {
                double lift = (index % 2 == 0) ? 0 : -thick;
                gtk_snapshot_append_color(snapshot, &line, &GRAPHENE_RECT_INIT((float)(x + at), (float)(y + lift), (float)fmin(step, width - at), (float)thick));
            }
            break;
        }
        case TS_UNDERLINE_DOTTED:
        case TS_UNDERLINE_DASHED: {
            double on = underline == TS_UNDERLINE_DOTTED ? thick : thick * 3;
            double period = on + thick * 2;
            for (double at = 0; at < width; at += period) {
                gtk_snapshot_append_color(snapshot, &line, &GRAPHENE_RECT_INIT((float)(x + at), (float)y, (float)fmin(on, width - at), (float)thick));
            }
            break;
        }
        default:
            gtk_snapshot_append_color(snapshot, &line, &GRAPHENE_RECT_INIT((float)x, (float)y, (float)width, (float)thick));
            break;
    }
}

/// One row as a render node: the fills behind its cells, its text in as few runs as the colours
/// and faces allow, then what is drawn over text.
static GskRenderNode *term_build_row(TailscodeTermView *self, const TSFrame *frame, int row) {
    const TSCell *cells = frame->cells + (size_t)row * frame->cols;
    const uint32_t *extras = frame->row_extras ? frame->row_extras[row] : NULL;
    GtkSnapshot *snapshot = gtk_snapshot_new();
    int cols = frame->cols;
    for (int start = 0; start < cols;) {
        if (!(cells[start].flags & TS_CELL_FILLED)) {
            start++;
            continue;
        }
        int end = start + 1;
        while (end < cols && (cells[end].flags & TS_CELL_FILLED) && cells[end].bg == cells[start].bg) end++;
        GdkRGBA fill = term_rgba(cells[start].bg, 1);
        gtk_snapshot_append_color(
            snapshot, &fill,
            &GRAPHENE_RECT_INIT(
                (float)(start * self->cell_width), 0, (float)((end - start) * self->cell_width), (float)self->cell_height));
        start = end;
    }
    TermRun run = {.glyphs = pango_glyph_string_new(), .count = 0};
    pango_glyph_string_set_size(run.glyphs, cols);
    int expected = -1;
    for (int col = 0; col < cols; col++) {
        const TSCell *cell = &cells[col];
        if (cell->width == 0 || cell->codepoint == 0 || cell->codepoint == ' ') continue;
        double x = col * self->cell_width;
        GdkRGBA ink = term_rgba(cell->fg, 1);
        if (cell->codepoint >= 0x2500 && cell->codepoint <= 0x259f && cell->extra == 0) {
            term_flush_run(self, snapshot, &run);
            if (term_draw_box(self, snapshot, cell, x, &ink)) continue;
        }
        int face = term_face_index(cell);
        PangoGlyph glyph = cell->extra == 0 && self->faces[face].font ? term_glyph(&self->faces[face], cell->codepoint) : PANGO_GLYPH_EMPTY;
        if (glyph == PANGO_GLYPH_EMPTY) {
            term_flush_run(self, snapshot, &run);
            term_draw_fallback(self, snapshot, cell, extras, x, &ink);
            continue;
        }
        if (run.count > 0 && (run.face != face || run.color != cell->fg || col != expected)) {
            term_flush_run(self, snapshot, &run);
        }
        if (run.count == 0) {
            run.face = face;
            run.color = cell->fg;
            run.x = x;
        }
        PangoGlyphInfo *info = &run.glyphs->glyphs[run.count];
        info->glyph = glyph;
        info->geometry.width = (int)lround(self->cell_width * cell->width * PANGO_SCALE);
        info->geometry.x_offset = 0;
        info->geometry.y_offset = 0;
        info->attr.is_cluster_start = 1;
        info->attr.is_color = 0;
        run.glyphs->log_clusters[run.count] = run.count;
        run.count++;
        expected = col + cell->width;
    }
    term_flush_run(self, snapshot, &run);
    pango_glyph_string_free(run.glyphs);
    for (int col = 0; col < cols; col++) {
        const TSCell *cell = &cells[col];
        if (cell->width == 0) continue;
        if (cell->flags & (TS_CELL_STRIKETHROUGH | TS_CELL_OVERLINE | TS_CELL_UNDERLINE_MASK)) {
            term_draw_decorations(self, snapshot, cell, col * self->cell_width);
        }
    }
    g_atomic_int_inc(&term_rows_built);
    return gtk_snapshot_free_to_node(snapshot);
}

static void term_stop_blink(TailscodeTermView *self) {
    if (self->blink_source) g_source_remove(self->blink_source);
    self->blink_source = 0;
    self->blink_on = TRUE;
}

static gboolean term_blink(gpointer data) {
    TailscodeTermView *self = data;
    self->blink_on = !self->blink_on;
    gtk_widget_queue_draw(GTK_WIDGET(self));
    return G_SOURCE_CONTINUE;
}

/// The cursor blinks only where someone is looking and typing: a focused, mapped view whose
/// program asked for a blinking cursor. Everywhere else it holds still and costs nothing.
static void term_sync_blink(TailscodeTermView *self) {
    gboolean wanted = self->focused && self->cursor_blinking && self->cursor_visible &&
                      gtk_widget_get_mapped(GTK_WIDGET(self));
    if (wanted && !self->blink_source) {
        self->blink_on = TRUE;
        self->blink_source = g_timeout_add(600, term_blink, self);
    } else if (!wanted && self->blink_source) {
        term_stop_blink(self);
        gtk_widget_queue_draw(GTK_WIDGET(self));
    }
}

void tailscode_term_view_update(GtkWidget *view, const TSFrame *frame) {
    TailscodeTermView *self = TAILSCODE_TERM_VIEW(view);
    if (!frame || !frame->cells || frame->cols == 0 || frame->rows == 0) return;
    term_load_faces(self);
    if (!self->faces_ready) return;
    gboolean everything = frame->dirty == TS_DIRTY_ALL || self->row_count != frame->rows || self->cols != frame->cols;
    if (self->row_count != frame->rows) {
        term_drop_rows(self);
        self->rows = g_new0(GskRenderNode *, frame->rows);
        self->row_count = frame->rows;
    }
    self->cols = frame->cols;
    gboolean changed = everything;
    for (int row = 0; row < frame->rows; row++) {
        if (!everything && !frame->row_dirty[row]) continue;
        if (self->rows[row]) gsk_render_node_unref(self->rows[row]);
        self->rows[row] = term_build_row(self, frame, row);
        changed = TRUE;
    }
    GdkRGBA background = term_rgba(frame->background, 1);
    if (!gdk_rgba_equal(&background, &self->background)) changed = TRUE;
    self->background = background;
    self->cursor_color = term_rgba(frame->cursor_color, 1);
    if (self->cursor_visible != frame->cursor_visible || self->cursor_x != frame->cursor_x ||
        self->cursor_y != frame->cursor_y || self->cursor_style != frame->cursor_style ||
        self->scroll_total != frame->scroll_total || self->scroll_offset != frame->scroll_offset ||
        self->scroll_length != frame->scroll_length) {
        changed = TRUE;
    }
    self->cursor_visible = frame->cursor_visible;
    self->cursor_blinking = frame->cursor_blinking;
    self->cursor_style = frame->cursor_style;
    self->cursor_x = frame->cursor_x;
    self->cursor_y = frame->cursor_y;
    memset(&self->cursor_cell, 0, sizeof(TSCell));
    if (frame->cursor_visible && frame->cursor_x < frame->cols && frame->cursor_y < frame->rows) {
        self->cursor_cell = frame->cells[(size_t)frame->cursor_y * frame->cols + frame->cursor_x];
        const uint32_t *extras = frame->row_extras ? frame->row_extras[frame->cursor_y] : NULL;
        int kept = self->cursor_cell.extra < 16 ? self->cursor_cell.extra : 16;
        for (int index = 0; index < kept && extras; index++) {
            self->cursor_extras[index] = extras[self->cursor_cell.extra_offset + index];
        }
        self->cursor_cell.extra = (uint8_t)kept;
        self->cursor_cell.extra_offset = 0;
    }
    self->scroll_total = frame->scroll_total;
    self->scroll_offset = frame->scroll_offset;
    self->scroll_length = frame->scroll_length;
    if (self->input && frame->cursor_visible) {
        GdkRectangle caret = {
            .x = TERM_PADDING + (int)(frame->cursor_x * self->cell_width),
            .y = TERM_PADDING + (int)(frame->cursor_y * self->cell_height),
            .width = (int)self->cell_width,
            .height = (int)self->cell_height,
        };
        gtk_im_context_set_cursor_location(self->input, &caret);
    }
    term_sync_blink(self);
    if (changed) {
        self->blink_on = TRUE;
        gtk_widget_queue_draw(view);
    }
}

static void term_draw_cursor(TailscodeTermView *self, GtkSnapshot *snapshot) {
    if (!self->cursor_visible || self->cursor_y >= self->row_count) return;
    if (self->focused && self->cursor_blinking && !self->blink_on) return;
    double width = self->cell_width * (self->cursor_cell.width == 2 ? 2 : 1);
    double height = self->cell_height;
    double line = fmax(round(self->cell_width / 6 * self->scale), 1) / self->scale;
    double x = self->cursor_x * self->cell_width;
    double y = self->cursor_y * self->cell_height;
    gtk_snapshot_save(snapshot);
    gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT((float)x, (float)y));
    int style = self->focused ? self->cursor_style : TS_CURSOR_HOLLOW;
    if (style == TS_CURSOR_BAR) {
        gtk_snapshot_append_color(snapshot, &self->cursor_color, &GRAPHENE_RECT_INIT(0, 0, (float)line, (float)height));
    } else if (style == TS_CURSOR_UNDERLINE) {
        gtk_snapshot_append_color(snapshot, &self->cursor_color, &GRAPHENE_RECT_INIT(0, (float)(height - line), (float)width, (float)line));
    } else if (style == TS_CURSOR_HOLLOW) {
        float thin = (float)(1 / self->scale);
        gtk_snapshot_append_color(snapshot, &self->cursor_color, &GRAPHENE_RECT_INIT(0, 0, (float)width, thin));
        gtk_snapshot_append_color(snapshot, &self->cursor_color, &GRAPHENE_RECT_INIT(0, (float)height - thin, (float)width, thin));
        gtk_snapshot_append_color(snapshot, &self->cursor_color, &GRAPHENE_RECT_INIT(0, 0, thin, (float)height));
        gtk_snapshot_append_color(snapshot, &self->cursor_color, &GRAPHENE_RECT_INIT((float)width - thin, 0, thin, (float)height));
    } else {
        gtk_snapshot_append_color(snapshot, &self->cursor_color, &GRAPHENE_RECT_INIT(0, 0, (float)width, (float)height));
        const TSCell *cell = &self->cursor_cell;
        if (cell->codepoint != 0 && cell->codepoint != ' ') {
            GdkRGBA ink = self->background;
            if (!(cell->codepoint >= 0x2500 && cell->codepoint <= 0x259f && term_draw_box(self, snapshot, cell, 0, &ink))) {
                term_draw_fallback(self, snapshot, cell, self->cursor_extras, 0, &ink);
            }
        }
    }
    gtk_snapshot_restore(snapshot);
}

/// A thin mark on the right edge that says how far back the screen is scrolled, drawn only while
/// it is: a terminal at its newest line shows nothing there.
static void term_draw_scroll_mark(TailscodeTermView *self, GtkSnapshot *snapshot, int width, int height) {
    if (self->scroll_total <= self->scroll_length) return;
    if (self->scroll_offset + self->scroll_length >= self->scroll_total) return;
    double track = height - 8;
    double length = fmax(track * (double)self->scroll_length / (double)self->scroll_total, 18);
    double top = 4 + (track - length) * (double)self->scroll_offset / (double)(self->scroll_total - self->scroll_length);
    GdkRGBA mark = self->cursor_color;
    mark.alpha = 0.45f;
    GskRoundedRect shape;
    gsk_rounded_rect_init_from_rect(&shape, &GRAPHENE_RECT_INIT((float)(width - 6), (float)top, 3, (float)length), 1.5f);
    gtk_snapshot_push_rounded_clip(snapshot, &shape);
    gtk_snapshot_append_color(snapshot, &mark, &shape.bounds);
    gtk_snapshot_pop(snapshot);
}

static void tailscode_term_view_snapshot(GtkWidget *widget, GtkSnapshot *snapshot) {
    TailscodeTermView *self = TAILSCODE_TERM_VIEW(widget);
    int width = gtk_widget_get_width(widget);
    int height = gtk_widget_get_height(widget);
    if (width <= 0 || height <= 0 || tailscode_is_quitting()) return;
    g_atomic_int_inc(&term_snapshots);
    gtk_snapshot_append_color(snapshot, &self->background, &GRAPHENE_RECT_INIT(0, 0, (float)width, (float)height));
    if (!self->faces_ready) return;
    gtk_snapshot_push_clip(snapshot, &GRAPHENE_RECT_INIT(0, 0, (float)width, (float)height));
    gtk_snapshot_save(snapshot);
    gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT(TERM_PADDING, TERM_PADDING));
    for (int row = 0; row < self->row_count; row++) {
        if (!self->rows[row]) continue;
        gtk_snapshot_save(snapshot);
        gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT(0, (float)(row * self->cell_height)));
        gtk_snapshot_append_node(snapshot, self->rows[row]);
        gtk_snapshot_restore(snapshot);
    }
    term_draw_cursor(self, snapshot);
    gtk_snapshot_restore(snapshot);
    term_draw_scroll_mark(self, snapshot, width, height);
    gtk_snapshot_pop(snapshot);
}

static void tailscode_term_view_size_allocate(GtkWidget *widget, int width, int height, int baseline) {
    (void)width;
    (void)height;
    (void)baseline;
    term_report_size(TAILSCODE_TERM_VIEW(widget));
}

static void tailscode_term_view_measure(
    GtkWidget *widget, GtkOrientation orientation, int for_size, int *minimum, int *natural, int *minimum_baseline,
    int *natural_baseline) {
    (void)widget;
    (void)for_size;
    *minimum = orientation == GTK_ORIENTATION_HORIZONTAL ? 80 : 40;
    *natural = orientation == GTK_ORIENTATION_HORIZONTAL ? 640 : 240;
    *minimum_baseline = -1;
    *natural_baseline = -1;
}

static void term_rescale(TailscodeTermView *self) {
    double scale = term_surface_scale(self);
    if (self->faces_ready && fabs(scale - self->scale) < 0.001) return;
    term_drop_faces(self);
    term_drop_rows(self);
    self->grid_cols = 0;
    self->grid_rows = 0;
    term_report_size(self);
    if (self->callbacks.tick) self->callbacks.tick(self->data);
}

static void tailscode_term_view_map(GtkWidget *widget) {
    GTK_WIDGET_CLASS(tailscode_term_view_parent_class)->map(widget);
    TailscodeTermView *self = TAILSCODE_TERM_VIEW(widget);
    term_rescale(self);
    term_sync_blink(self);
    if (self->callbacks.tick) self->callbacks.tick(self->data);
}

static void tailscode_term_view_unmap(GtkWidget *widget) {
    TailscodeTermView *self = TAILSCODE_TERM_VIEW(widget);
    term_stop_blink(self);
    if (self->tick_id) gtk_widget_remove_tick_callback(widget, self->tick_id);
    self->tick_id = 0;
    GTK_WIDGET_CLASS(tailscode_term_view_parent_class)->unmap(widget);
}

static void term_scale_changed(GObject *object, GParamSpec *spec, gpointer data) {
    (void)spec;
    (void)data;
    TailscodeTermView *self = TAILSCODE_TERM_VIEW(object);
    if (gtk_widget_get_mapped(GTK_WIDGET(self))) term_rescale(self);
}

static void tailscode_term_view_dispose(GObject *object) {
    TailscodeTermView *self = TAILSCODE_TERM_VIEW(object);
    term_stop_blink(self);
    memset(&self->callbacks, 0, sizeof(self->callbacks));
    if (self->destroy && self->data) self->destroy(self->data);
    self->data = NULL;
    self->destroy = NULL;
    if (self->input) gtk_im_context_set_client_widget(self->input, NULL);
    g_clear_object(&self->input);
    G_OBJECT_CLASS(tailscode_term_view_parent_class)->dispose(object);
}

static void tailscode_term_view_finalize(GObject *object) {
    TailscodeTermView *self = TAILSCODE_TERM_VIEW(object);
    term_drop_rows(self);
    term_drop_faces(self);
    g_clear_pointer(&self->fallbacks, g_hash_table_destroy);
    g_clear_pointer(&self->description, pango_font_description_free);
    g_free(self->family);
    G_OBJECT_CLASS(tailscode_term_view_parent_class)->finalize(object);
}

static void tailscode_term_view_class_init(TailscodeTermViewClass *class) {
    G_OBJECT_CLASS(class)->dispose = tailscode_term_view_dispose;
    G_OBJECT_CLASS(class)->finalize = tailscode_term_view_finalize;
    GTK_WIDGET_CLASS(class)->snapshot = tailscode_term_view_snapshot;
    GTK_WIDGET_CLASS(class)->size_allocate = tailscode_term_view_size_allocate;
    GTK_WIDGET_CLASS(class)->measure = tailscode_term_view_measure;
    GTK_WIDGET_CLASS(class)->map = tailscode_term_view_map;
    GTK_WIDGET_CLASS(class)->unmap = tailscode_term_view_unmap;
    gtk_widget_class_set_css_name(GTK_WIDGET_CLASS(class), "terminal-view");
}

static guint term_state(GtkEventController *controller) {
    return (guint)gtk_event_controller_get_current_event_state(controller);
}

static gboolean term_key_pressed(GtkEventControllerKey *controller, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    (void)controller;
    TailscodeTermView *self = data;
    if (!self->callbacks.key) return FALSE;
    return self->callbacks.key(keyval, keycode, (guint)state, self->data);
}

static void term_committed(GtkIMContext *context, const char *text, gpointer data) {
    (void)context;
    TailscodeTermView *self = data;
    if (self->callbacks.text && text && *text) self->callbacks.text(text, self->data);
}

static void term_focus_entered(GtkEventControllerFocus *controller, gpointer data) {
    (void)controller;
    TailscodeTermView *self = data;
    self->focused = TRUE;
    if (self->input) gtk_im_context_focus_in(self->input);
    term_sync_blink(self);
    gtk_widget_queue_draw(GTK_WIDGET(self));
    if (self->callbacks.focus) self->callbacks.focus(TRUE, self->data);
}

static void term_focus_left(GtkEventControllerFocus *controller, gpointer data) {
    (void)controller;
    TailscodeTermView *self = data;
    self->focused = FALSE;
    if (self->input) gtk_im_context_focus_out(self->input);
    term_sync_blink(self);
    gtk_widget_queue_draw(GTK_WIDGET(self));
    if (self->callbacks.focus) self->callbacks.focus(FALSE, self->data);
}

static void term_pressed(GtkGestureClick *gesture, int presses, double x, double y, gpointer data) {
    (void)presses;
    TailscodeTermView *self = data;
    gtk_widget_grab_focus(GTK_WIDGET(self));
    self->pressed = TRUE;
    int button = (int)gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));
    if (self->callbacks.pointer) {
        self->callbacks.pointer(
            0, button, x * self->scale, y * self->scale, term_state(GTK_EVENT_CONTROLLER(gesture)), self->data);
    }
}

static void term_released(GtkGestureClick *gesture, int presses, double x, double y, gpointer data) {
    (void)presses;
    TailscodeTermView *self = data;
    self->pressed = FALSE;
    int button = (int)gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(gesture));
    if (self->callbacks.pointer) {
        self->callbacks.pointer(
            1, button, x * self->scale, y * self->scale, term_state(GTK_EVENT_CONTROLLER(gesture)), self->data);
    }
}

static void term_moved(GtkEventControllerMotion *controller, double x, double y, gpointer data) {
    TailscodeTermView *self = data;
    if (self->callbacks.pointer) {
        self->callbacks.pointer(
            2, self->pressed ? 1 : 0, x * self->scale, y * self->scale, term_state(GTK_EVENT_CONTROLLER(controller)),
            self->data);
    }
}

static gboolean term_scrolled(GtkEventControllerScroll *controller, double dx, double dy, gpointer data) {
    (void)dx;
    TailscodeTermView *self = data;
    if (!self->callbacks.scroll || !self->faces_ready) return FALSE;
    double rows = dy;
    if (gtk_event_controller_scroll_get_unit(controller) == GDK_SCROLL_UNIT_SURFACE) {
        rows = dy / self->cell_height;
    } else {
        rows = dy * 3;
    }
    GdkEvent *event = gtk_event_controller_get_current_event(GTK_EVENT_CONTROLLER(controller));
    double x = 0;
    double y = 0;
    if (event) gdk_event_get_position(event, &x, &y);
    graphene_point_t local = GRAPHENE_POINT_INIT((float)x, (float)y);
    GtkNative *native = gtk_widget_get_native(GTK_WIDGET(self));
    if (native) {
        double offset_x = 0;
        double offset_y = 0;
        gtk_native_get_surface_transform(native, &offset_x, &offset_y);
        graphene_point_t in_native = GRAPHENE_POINT_INIT((float)(x - offset_x), (float)(y - offset_y));
        if (!gtk_widget_compute_point(GTK_WIDGET(native), GTK_WIDGET(self), &in_native, &local)) local = in_native;
    }
    self->callbacks.scroll(
        rows, local.x * self->scale, local.y * self->scale, term_state(GTK_EVENT_CONTROLLER(controller)), self->data);
    return TRUE;
}

static void tailscode_term_view_init(TailscodeTermView *self) {
    GtkWidget *widget = GTK_WIDGET(self);
    self->points = 11;
    self->scale = 1;
    self->blink_on = TRUE;
    self->background = (GdkRGBA){0, 0, 0, 1};
    self->cursor_color = (GdkRGBA){1, 1, 1, 1};
    self->fallbacks = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, g_object_unref);
    gtk_widget_set_focusable(widget, TRUE);
    gtk_widget_set_hexpand(widget, TRUE);
    gtk_widget_set_vexpand(widget, TRUE);
    gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN);
    gtk_widget_set_cursor_from_name(widget, "text");

    self->input = gtk_im_multicontext_new();
    gtk_im_context_set_client_widget(self->input, widget);
    g_signal_connect(self->input, "commit", G_CALLBACK(term_committed), self);
    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_key_set_im_context(GTK_EVENT_CONTROLLER_KEY(keys), self->input);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(term_key_pressed), self);
    gtk_widget_add_controller(widget, keys);

    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "enter", G_CALLBACK(term_focus_entered), self);
    g_signal_connect(focus, "leave", G_CALLBACK(term_focus_left), self);
    gtk_widget_add_controller(widget, focus);

    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    g_signal_connect(click, "pressed", G_CALLBACK(term_pressed), self);
    g_signal_connect(click, "released", G_CALLBACK(term_released), self);
    gtk_widget_add_controller(widget, GTK_EVENT_CONTROLLER(click));

    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(term_moved), self);
    gtk_widget_add_controller(widget, motion);

    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
    g_signal_connect(scroll, "scroll", G_CALLBACK(term_scrolled), self);
    gtk_widget_add_controller(widget, scroll);

    g_signal_connect(self, "notify::scale-factor", G_CALLBACK(term_scale_changed), NULL);
}

GtkWidget *tailscode_term_view_new(const TailscodeTermCallbacks *callbacks, void *data, void (*destroy)(void *)) {
    TailscodeTermView *self = g_object_new(TAILSCODE_TYPE_TERM_VIEW, NULL);
    if (callbacks) self->callbacks = *callbacks;
    self->data = data;
    self->destroy = destroy;
    return GTK_WIDGET(self);
}

void tailscode_term_view_set_font(GtkWidget *view, const char *family, double points) {
    TailscodeTermView *self = TAILSCODE_TERM_VIEW(view);
    if (g_strcmp0(self->family, family) == 0 && fabs(self->points - points) < 0.01 && self->faces_ready) return;
    g_free(self->family);
    self->family = g_strdup(family);
    self->points = points > 1 ? points : 11;
    term_drop_faces(self);
    term_drop_rows(self);
    self->grid_cols = 0;
    self->grid_rows = 0;
    if (gtk_widget_get_mapped(view)) {
        term_report_size(self);
        if (self->callbacks.tick) self->callbacks.tick(self->data);
    }
}

void tailscode_term_view_set_canvas(GtkWidget *view, uint32_t rgb) {
    TailscodeTermView *self = TAILSCODE_TERM_VIEW(view);
    self->background = term_rgba(rgb, 1);
    gtk_widget_queue_draw(view);
}

static gboolean term_ticked(GtkWidget *widget, GdkFrameClock *clock, gpointer data) {
    (void)clock;
    (void)data;
    TailscodeTermView *self = TAILSCODE_TERM_VIEW(widget);
    self->tick_id = 0;
    if (self->callbacks.tick) self->callbacks.tick(self->data);
    return G_SOURCE_REMOVE;
}

void tailscode_term_view_request_tick(GtkWidget *view) {
    TailscodeTermView *self = TAILSCODE_TERM_VIEW(view);
    if (self->tick_id || !gtk_widget_get_mapped(view)) return;
    self->tick_id = gtk_widget_add_tick_callback(view, term_ticked, NULL, NULL);
}

gboolean tailscode_term_view_is_mapped(GtkWidget *view) { return gtk_widget_get_mapped(view); }

double tailscode_term_default_points(void) {
    char *name = NULL;
    double points = 11;
    GtkSettings *settings = gtk_settings_get_default();
    if (settings) g_object_get(settings, "gtk-font-name", &name, NULL);
    if (name) {
        PangoFontDescription *description = pango_font_description_from_string(name);
        int size = pango_font_description_get_size(description);
        if (size > 0 && !pango_font_description_get_size_is_absolute(description)) points = (double)size / PANGO_SCALE;
        pango_font_description_free(description);
        g_free(name);
    }
    return points;
}

long tailscode_term_view_rows_built(void) { return g_atomic_int_get(&term_rows_built); }

long tailscode_term_view_snapshots(void) { return g_atomic_int_get(&term_snapshots); }
