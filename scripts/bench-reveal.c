/// What a frame of the written-not-pasted reveal costs, and whether it draws what the old one drew.
///
/// Built and run on the Linux box inside the headless display (never the real desktop):
///
///     gcc -O2 scripts/bench-reveal.c -o /tmp/bench-reveal $(pkg-config --cflags --libs gtk4 libadwaita-1) -lm
///     DISPLAY=:81 /tmp/bench-reveal cost      per-frame cost at 500, 2000 and 8000 characters, the
///                                             attribute-per-frame method this replaced against the reveal label
///     DISPLAY=:81 /tmp/bench-reveal pixels    the reveal label against the old method, rendered by the cairo
///                                             renderer and compared pixel for pixel, with the wave over links,
///                                             strikethrough, CJK and emoji
///     DISPLAY=:81 /tmp/bench-reveal wave      PNGs in /tmp of a strongly coloured wave at several edges
///
/// It compiles `reveal.c` directly, so what it measures is what ships.
#include "../TailscodeLinux/Sources/CGtkShim/reveal.c"
#include <stdio.h>
#include <stdlib.h>

void tailscode_soak_note_parse(int hit) { (void)hit; }

static double now_ms(void){ return g_get_monotonic_time()/1000.0; }

static char *make_text(int n) {
    const char *words[] = {"the","stream","writes","answer","slowly","into","a","paragraph","that","wraps","around","edge","of","pane","and","never","moves","again","after","landing"};
    GString *s = g_string_new(NULL);
    int i = 0;
    while ((int)s->len < n) { g_string_append(s, words[(i*7+i/3)%20]); g_string_append_c(s, ' '); i++; }
    g_string_truncate(s, n);
    return g_string_free(s, FALSE);
}

typedef struct { GtkWidget *win, *box, *label; } Rig;

static Rig make_rig(GtkWidget *label, int width) {
    Rig r;
    r.win = gtk_window_new();
    r.box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    r.label = label;
    gtk_label_set_wrap(GTK_LABEL(label), TRUE);
    gtk_label_set_wrap_mode(GTK_LABEL(label), PANGO_WRAP_WORD_CHAR);
    gtk_label_set_xalign(GTK_LABEL(label), 0);
    gtk_label_set_selectable(GTK_LABEL(label), TRUE);
    gtk_widget_set_valign(label, GTK_ALIGN_START);
    gtk_box_append(GTK_BOX(r.box), label);
    gtk_window_set_child(GTK_WINDOW(r.win), r.box);
    gtk_window_set_default_size(GTK_WINDOW(r.win), width, 500);
    gtk_window_present(GTK_WINDOW(r.win));
    gint64 deadline = g_get_monotonic_time() + 5 * G_USEC_PER_SEC;
    while (gtk_widget_get_width(label) <= 0 && g_get_monotonic_time() < deadline) {
        g_main_context_iteration(NULL, FALSE);
        g_usleep(2000);
    }
    for (int i = 0; i < 20; i++) { g_main_context_iteration(NULL, FALSE); g_usleep(2000); }
    if (gtk_widget_get_width(label) <= 0) fprintf(stderr, "label never allocated\n");
    return r;
}

static GskRenderNode *snap(Rig *r) {
    GtkSnapshot *s = gtk_snapshot_new();
    gtk_widget_queue_draw(r->label);
    gtk_widget_snapshot_child(r->box, r->label, s);
    return gtk_snapshot_free_to_node(s);
}

static void fill_wave(guint32 *rgb, guint16 *alpha, int wave, guint32 settled) {
    for (int k = 0; k < wave; k++) {
        double t = 1.0 - (double)k / wave;
        rgb[k] = settled;
        alpha[k] = (guint16)(65535 * (0.3 + 0.7 * (1 - t)));
    }
}

static void old_frame(GtkWidget *label, const char *text, PangoAttrList *base, int visible, int wave) {
    const char *edge = g_utf8_offset_to_pointer(text, visible);
    PangoAttrList *list = pango_attr_list_copy(base);
    PangoAttribute *hidden = pango_attr_foreground_alpha_new(1);
    hidden->start_index = edge - text; hidden->end_index = G_MAXUINT;
    pango_attr_list_insert(list, hidden);
    const char *cursor = edge;
    for (int k=0;k<wave;k++) {
        const char *prev = g_utf8_find_prev_char(text, cursor); if (!prev) break;
        PangoAttribute *fg = pango_attr_foreground_new(60000, 20000+k*1000, 10000);
        fg->start_index = prev-text; fg->end_index = cursor-text; pango_attr_list_insert(list, fg);
        PangoAttribute *fa = pango_attr_foreground_alpha_new(30000+k*1000);
        fa->start_index = prev-text; fa->end_index = cursor-text; pango_attr_list_insert(list, fa);
        cursor = prev;
    }
    gtk_label_set_attributes(GTK_LABEL(label), list);
    pango_attr_list_unref(list);
}

static void cost_bench(void) {
    int sizes[] = {500, 2000, 8000};
    for (int si = 0; si < 3; si++) {
        int n = sizes[si];
        char *text = make_text(n);
        int iters = 200;

        GtkWidget *plain = gtk_label_new(NULL);
        gtk_label_set_text(GTK_LABEL(plain), text);
        Rig a = make_rig(plain, 900);
        PangoAttrList *base = pango_attr_list_new();
        double t0 = now_ms();
        for (int i = 0; i < iters; i++) {
            old_frame(plain, text, base, n / 2 + i % 20, 26);
            int mw, nw, mh, nh;
            gtk_widget_measure(plain, GTK_ORIENTATION_HORIZONTAL, -1, &mw, &nw, NULL, NULL);
            gtk_widget_measure(plain, GTK_ORIENTATION_VERTICAL, 900, &mh, &nh, NULL, NULL);
            gtk_widget_allocate(plain, 900, nh, -1, NULL);
            GskRenderNode *node = snap(&a);
            if (node) gsk_render_node_unref(node);
        }
        printf("N=%-5d BEFORE  attrs+measure+allocate+snapshot     %.3f ms/frame\n", n, (now_ms() - t0) / iters);
        gtk_window_destroy(GTK_WINDOW(a.win));
        for (int i = 0; i < 20; i++) g_main_context_iteration(NULL, FALSE);

        char *markup = g_markup_escape_text(text, -1);
        GtkWidget *reveal = tailscode_reveal_label_new();
        Rig b = make_rig(reveal, 900);
        guint32 rgb[26]; guint16 alpha[26];
        fill_wave(rgb, alpha, 26, 0xd0d0d0);
        tailscode_label_reveal(reveal, markup, n / 2, 26, rgb, alpha);
        for (int i = 0; i < 30; i++) g_main_context_iteration(NULL, FALSE);
        PangoLayout *layout = gtk_label_get_layout(GTK_LABEL(reveal));
        guint serial = pango_layout_get_serial(layout);
        double t_reveal = 0, t_snap = 0, t_measure = 0;
        for (int i = 0; i < iters; i++) {
            double s0 = now_ms();
            tailscode_label_reveal(reveal, markup, n / 2 + i % 20, 26, rgb, alpha);
            double s1 = now_ms();
            int mw, nw;
            gtk_widget_measure(reveal, GTK_ORIENTATION_VERTICAL, 900, &mw, &nw, NULL, NULL);
            double s2 = now_ms();
            GskRenderNode *node = snap(&b);
            double s3 = now_ms();
            if (node) gsk_render_node_unref(node);
            t_reveal += s1 - s0; t_measure += s2 - s1; t_snap += s3 - s2;
        }
        printf("N=%-5d AFTER   reveal %.3f + measure %.3f + snapshot %.3f = %.3f ms/frame  (layout serial %s, lines=%d)\n",
            n, t_reveal / iters, t_measure / iters, t_snap / iters, (t_reveal + t_measure + t_snap) / iters,
            pango_layout_get_serial(gtk_label_get_layout(GTK_LABEL(reveal))) == serial ? "unchanged" : "CHANGED",
            pango_layout_get_line_count(layout));
        gtk_window_destroy(GTK_WINDOW(b.win));
        for (int i = 0; i < 20; i++) g_main_context_iteration(NULL, FALSE);
        g_free(text); g_free(markup);
    }
}

static unsigned char *render(GskRenderNode *node, int w, int h, int *stride) {
    GskRenderer *renderer = gsk_cairo_renderer_new();
    GError *error = NULL;
    if (!gsk_renderer_realize_for_display(renderer, gdk_display_get_default(), &error)) {
        fprintf(stderr, "realize: %s\n", error->message);
        return NULL;
    }
    graphene_rect_t view = GRAPHENE_RECT_INIT(0, 0, w, h);
    GdkTexture *texture = gsk_renderer_render_texture(renderer, node, &view);
    *stride = w * 4;
    unsigned char *data = g_malloc0((gsize)w * h * 4);
    gdk_texture_download(texture, data, *stride);
    g_object_unref(texture);
    gsk_renderer_unrealize(renderer);
    g_object_unref(renderer);
    return data;
}

static void save(const char *path, unsigned char *data, int w, int h) {
    cairo_surface_t *surface = cairo_image_surface_create_for_data(data, CAIRO_FORMAT_ARGB32, w, h, w * 4);
    cairo_surface_write_to_png(surface, path);
    cairo_surface_destroy(surface);
}

static int pixel_compare(const char *label, const char *markup, const char *text, int visible, int wave, const char *tag) {
    GtkWidget *plain = gtk_label_new(NULL);
    gtk_label_set_text(GTK_LABEL(plain), text);
    Rig a = make_rig(plain, 500);
    GtkWidget *reveal = tailscode_reveal_label_new();
    Rig b = make_rig(reveal, 500);
    GdkRGBA color;
    gtk_widget_get_color(reveal, &color);
    guint32 settled = ((guint32)(color.red * 255 + 0.5) << 16) | ((guint32)(color.green * 255 + 0.5) << 8) | (guint32)(color.blue * 255 + 0.5);
    guint32 rgb[64]; guint16 alpha[64];
    for (int k = 0; k < wave; k++) { rgb[k] = settled; alpha[k] = 65535; }
    PangoAttrList *attrs = NULL; char *parsed = NULL;
    pango_parse_markup(markup, -1, 0, &attrs, &parsed, NULL, NULL);
    const char *edge = g_utf8_offset_to_pointer(parsed, visible);
    PangoAttrList *list = pango_attr_list_copy(attrs);
    PangoAttribute *hidden = pango_attr_foreground_alpha_new(1);
    hidden->start_index = edge - parsed; hidden->end_index = G_MAXUINT;
    pango_attr_list_insert(list, hidden);
    const char *wcur = edge;
    for (int k = 0; k < wave; k++) {
        const char *prev = g_utf8_find_prev_char(parsed, wcur); if (!prev) break;
        PangoAttribute *fg = pango_attr_foreground_new(((settled>>16)&0xff)*257, ((settled>>8)&0xff)*257, (settled&0xff)*257);
        fg->start_index = prev - parsed; fg->end_index = wcur - parsed; pango_attr_list_insert(list, fg);
        wcur = prev;
    }
    gtk_label_set_text(GTK_LABEL(plain), parsed);
    gtk_label_set_attributes(GTK_LABEL(plain), list);
    tailscode_label_reveal(reveal, markup, visible, wave, rgb, alpha);
    for (int i = 0; i < 40; i++) g_main_context_iteration(NULL, FALSE);
    int w = gtk_widget_get_width(plain), h = gtk_widget_get_height(plain);
    GskRenderNode *na = snap(&a), *nb = snap(&b);
    int sa, sb;
    unsigned char *pa = render(na, w, h, &sa), *pb = render(nb, w, h, &sb);
    long diff = 0, strong = 0, ink = 0;
    for (int i = 0; i < w * h; i++) {
        if (i % w == 0) continue;
        int d = 0;
        for (int c = 0; c < 4; c++) { int v = abs((int)pa[i*4+c] - (int)pb[i*4+c]); if (v > d) d = v; }
        if (d > 0) diff++;
        if (d > 48) strong++;
        if (pa[i*4+3] > 0) ink++;
    }
    printf("%-28s visible=%-4d wave=%-2d size=%dx%d  differing=%ld strong(>48)=%ld  nonblank=%ld\n", label, visible, wave, w, h, diff, strong, ink);
    char path[256];
    snprintf(path, sizeof path, "/tmp/tsr1-%s-plain.png", tag); save(path, pa, w, h);
    snprintf(path, sizeof path, "/tmp/tsr1-%s-reveal.png", tag); save(path, pb, w, h);
    gtk_window_destroy(GTK_WINDOW(a.win)); gtk_window_destroy(GTK_WINDOW(b.win));
    for (int i = 0; i < 20; i++) g_main_context_iteration(NULL, FALSE);
    return strong > 0;
}

static void wave_picture(int visible, const char *path) {
    const char *markup = "The stream writes an answer slowly into a paragraph that wraps around the edge of the pane and <b>never moves</b> again after landing. Read <span foreground=\"#2a6fd6\" underline=\"single\">the linked phrase here</span> and <s>struck words</s>, naïve café 日本語のテキスト and a ✅ mark, then more words so the paragraph runs on to a fourth line of the label.";
    GtkWidget *reveal = tailscode_reveal_label_new();
    Rig b = make_rig(reveal, 440);
    guint32 rgb[26]; guint16 alpha[26];
    for (int k = 0; k < 26; k++) {
        double heat = 1.0 - (double)k / 26;
        guint32 r = (guint32)(0x20 + heat * (0xe0 - 0x20)), g = (guint32)(0x20 + heat * (0x40 - 0x20)), bl = (guint32)(0x30 + heat * (0x10 - 0x30));
        rgb[k] = (r << 16) | (g << 8) | bl;
        alpha[k] = (guint16)(65535 * (k < 4 ? 0.35 + 0.15 * k : 1.0));
    }
    tailscode_label_reveal(reveal, markup, visible, 26, rgb, alpha);
    for (int i = 0; i < 40; i++) { g_main_context_iteration(NULL, FALSE); g_usleep(2000); }
    int w = gtk_widget_get_width(reveal), h = gtk_widget_get_height(reveal);
    GskRenderNode *nb = snap(&b);
    int sb;
    unsigned char *pb = render(nb, w, h, &sb);
    save(path, pb, w, h);
    gtk_window_destroy(GTK_WINDOW(b.win));
    for (int i = 0; i < 20; i++) g_main_context_iteration(NULL, FALSE);
}

int main(int argc, char **argv) {
    gtk_init();
    const char *mode = argc > 1 ? argv[1] : "cost";
    if (strcmp(mode, "wave") == 0) {
        int cases[] = {70, 118, 150, 205, 250, 400};
        for (unsigned i = 0; i < 6; i++) { char p[64]; snprintf(p, sizeof p, "/tmp/tsr1-wave%d.png", cases[i]); wave_picture(cases[i], p); }
        return 0;
    }
    if (strcmp(mode, "cost") == 0) { cost_bench(); return 0; }
    const char *markup = "Hello <b>bold text</b> and <i>italic words</i> with <span foreground=\"#8cf\">coloured code</span> then a <span foreground=\"#8cf\" underline=\"single\">linked phrase here</span> and <s>struck out words</s> plus some more plain text that wraps across several lines of the label so that the reveal edge crosses a wrap break somewhere in here, fine naïve café 日本語のテキスト 😀 emoji end.";
    PangoAttrList *attrs = NULL; char *parsed = NULL;
    pango_parse_markup(markup, -1, 0, &attrs, &parsed, NULL, NULL);
    int total = g_utf8_strlen(parsed, -1);
    int bad = 0;
    int cases[] = {5, 17, 40, 62, 72, 80, 92, 100, 121, 160, 200, 214, 222, 230, 240, 262, total};
    for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        char tag[32]; snprintf(tag, sizeof tag, "v%d", cases[i]);
        bad += pixel_compare("equal-colour wave vs old", markup, parsed, cases[i] > total ? total : cases[i], 26, tag);
    }
    printf("strong-diff cases: %d\n", bad);
    return bad != 0;
}
