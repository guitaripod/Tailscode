#include "terminal_engine.h"

#include <math.h>

typedef struct {
  TSBoxRect* out;
  size_t count;
  float scale;
} TSBoxPen;

static float ts_snap(const TSBoxPen* pen, float value) {
  return roundf(value * pen->scale) / pen->scale;
}

static void ts_box_fill(TSBoxPen* pen, float x0, float y0, float x1, float y1, float alpha) {
  if (pen->count >= TS_BOX_RECTS_MAX) return;
  float left = ts_snap(pen, x0);
  float top = ts_snap(pen, y0);
  float right = ts_snap(pen, x1);
  float bottom = ts_snap(pen, y1);
  if (right <= left || bottom <= top) return;
  TSBoxRect rect = {.x = left, .y = top, .width = right - left, .height = bottom - top, .alpha = alpha};
  pen->out[pen->count++] = rect;
}

static const char* const ts_box_arms[] = {
    "0101", "0202", "1010", "2020", "0101", "0202", "1010", "2020", "0101", "0202", "1010", "2020",
    "0110", "0210", "0120", "0220", "0011", "0012", "0021", "0022", "1100", "1200", "2100", "2200",
    "1001", "1002", "2001", "2002", "1110", "1210", "2110", "1120", "2120", "2210", "1220", "2220",
    "1011", "1012", "2011", "1021", "2021", "2012", "1022", "2022", "0111", "0112", "0211", "0212",
    "0121", "0122", "0221", "0222", "1101", "1102", "1201", "1202", "2101", "2102", "2201", "2202",
    "1111", "1112", "1211", "1212", "2111", "1121", "2121", "2112", "2211", "1122", "1221", "2212",
    "1222", "2122", "2221", "2222", "0101", "0202", "1010", "2020",
};

static const char* const ts_box_stubs[] = {
    "0001", "1000", "0100", "0010", "0002", "2000", "0200", "0020", "0201", "1020", "0102", "2010",
};

static float ts_box_weight(char arm, float light, float heavy) {
  return arm == '2' ? heavy : arm == '1' ? light : 0;
}

/// Lines from the middle of the cell out to the edges named in `arms` (up, right, down, left),
/// each as thick as its digit says. Every arm reaches far enough into the middle to cover the
/// arms it meets, so a corner has no notch.
static void ts_box_lines(TSBoxPen* pen, const char* arms, float w, float h, float light, float heavy) {
  float up = ts_box_weight(arms[0], light, heavy);
  float right = ts_box_weight(arms[1], light, heavy);
  float down = ts_box_weight(arms[2], light, heavy);
  float left = ts_box_weight(arms[3], light, heavy);
  float vertical = fmaxf(up, down);
  float horizontal = fmaxf(left, right);
  float cx = ts_snap(pen, (w - vertical) / 2) + vertical / 2;
  float cy = ts_snap(pen, (h - horizontal) / 2) + horizontal / 2;
  if (vertical == 0) cx = ts_snap(pen, (w - light) / 2) + light / 2;
  if (horizontal == 0) cy = ts_snap(pen, (h - light) / 2) + light / 2;
  if (up > 0) ts_box_fill(pen, cx - up / 2, 0, cx + up / 2, cy + horizontal / 2, 1);
  if (down > 0) ts_box_fill(pen, cx - down / 2, cy - horizontal / 2, cx + down / 2, h, 1);
  if (left > 0) ts_box_fill(pen, 0, cy - left / 2, cx + vertical / 2, cy + left / 2, 1);
  if (right > 0) ts_box_fill(pen, cx - vertical / 2, cy - right / 2, w, cy + right / 2, 1);
}

/// A corner that turns instead of meeting square: each arm stops short of the middle and a short
/// run of squares along a quarter circle joins them, which at a terminal's sizes reads as the arc
/// the character means.
static void ts_box_round(TSBoxPen* pen, bool up, bool right, float w, float h, float light) {
  float cx = ts_snap(pen, (w - light) / 2);
  float cy = ts_snap(pen, (h - light) / 2);
  float step = 1 / pen->scale;
  float radius = floorf(fminf(w, h) / 4 * pen->scale) / pen->scale;
  if (radius < step) radius = step;
  float toward_x = right ? 1 : -1;
  float toward_y = up ? -1 : 1;
  ts_box_fill(pen, right ? cx + radius : 0, cy, right ? w : cx + light - radius, cy + light, 1);
  ts_box_fill(pen, cx, up ? 0 : cy + radius, cx + light, up ? cy + light - radius : h, 1);
  int steps = (int)lroundf(radius / step) + 1;
  if (steps > 10) steps = 10;
  for (int index = 1; index < steps; index++) {
    float turn = 1.5707964f * (float)index / (float)steps;
    float x = cx + toward_x * (radius - radius * cosf(turn));
    float y = cy + toward_y * (radius - radius * sinf(turn));
    ts_box_fill(pen, x, y, x + light, y + light, 1);
  }
}

static void ts_box_double(TSBoxPen* pen, uint32_t codepoint, float w, float h, float light) {
  float gap = light;
  float cx = ts_snap(pen, (w - light) / 2);
  float cy = ts_snap(pen, (h - light) / 2);
  float x0 = cx - gap;
  float x1 = cx + gap;
  float y0 = cy - gap;
  float y1 = cy + gap;
  bool up = false, right = false, down = false, left = false;
  switch (codepoint) {
    case 0x2550: left = right = true; break;
    case 0x2551: up = down = true; break;
    case 0x2554: down = right = true; break;
    case 0x2557: down = left = true; break;
    case 0x255a: up = right = true; break;
    case 0x255d: up = left = true; break;
    case 0x2560: up = down = right = true; break;
    case 0x2563: up = down = left = true; break;
    case 0x2566: left = right = down = true; break;
    case 0x2569: left = right = up = true; break;
    case 0x256c: up = down = left = right = true; break;
    default: return;
  }
  if (left && right && !up && !down) {
    ts_box_fill(pen, 0, y0, w, y0 + light, 1);
    ts_box_fill(pen, 0, y1, w, y1 + light, 1);
    return;
  }
  if (up && down && !left && !right) {
    ts_box_fill(pen, x0, 0, x0 + light, h, 1);
    ts_box_fill(pen, x1, 0, x1 + light, h, 1);
    return;
  }
  if (up && down) {
    if (!left) ts_box_fill(pen, x0, 0, x0 + light, h, 1);
    if (!right) ts_box_fill(pen, x1, 0, x1 + light, h, 1);
  }
  if (left && right) {
    if (!up) ts_box_fill(pen, 0, y0, w, y0 + light, 1);
    if (!down) ts_box_fill(pen, 0, y1, w, y1 + light, 1);
  }
  if (up && left) {
    ts_box_fill(pen, x0, 0, x0 + light, y0 + light, 1);
    ts_box_fill(pen, 0, y0, x0 + light, y0 + light, 1);
  }
  if (up && right) {
    ts_box_fill(pen, x1, 0, x1 + light, y0 + light, 1);
    ts_box_fill(pen, x1, y0, w, y0 + light, 1);
  }
  if (down && left) {
    ts_box_fill(pen, x0, y1, x0 + light, h, 1);
    ts_box_fill(pen, 0, y1, x0 + light, y1 + light, 1);
  }
  if (down && right) {
    ts_box_fill(pen, x1, y1, x1 + light, h, 1);
    ts_box_fill(pen, x1, y1, w, y1 + light, 1);
  }
  if (up && !down && left != right) {
    float outer = left ? x1 : x0;
    ts_box_fill(pen, outer, 0, outer + light, y1 + light, 1);
    ts_box_fill(pen, left ? 0 : x0, y1, left ? x1 + light : w, y1 + light, 1);
  }
  if (down && !up && left != right) {
    float outer = left ? x1 : x0;
    ts_box_fill(pen, outer, y0, outer + light, h, 1);
    ts_box_fill(pen, left ? 0 : x0, y0, left ? x1 + light : w, y0 + light, 1);
  }
}

static void ts_box_block(TSBoxPen* pen, uint32_t codepoint, float w, float h) {
  float mx = w / 2;
  float my = h / 2;
  if (codepoint == 0x2580) {
    ts_box_fill(pen, 0, 0, w, my, 1);
  } else if (codepoint >= 0x2581 && codepoint <= 0x2588) {
    float eighths = (float)(codepoint - 0x2580);
    ts_box_fill(pen, 0, h - h * eighths / 8, w, h, 1);
  } else if (codepoint >= 0x2589 && codepoint <= 0x258f) {
    float eighths = (float)(0x2590 - codepoint);
    ts_box_fill(pen, 0, 0, w * eighths / 8, h, 1);
  } else if (codepoint == 0x2590) {
    ts_box_fill(pen, mx, 0, w, h, 1);
  } else if (codepoint >= 0x2591 && codepoint <= 0x2593) {
    ts_box_fill(pen, 0, 0, w, h, 0.25f * (float)(codepoint - 0x2590));
  } else if (codepoint == 0x2594) {
    ts_box_fill(pen, 0, 0, w, h / 8, 1);
  } else if (codepoint == 0x2595) {
    ts_box_fill(pen, w - w / 8, 0, w, h, 1);
  } else {
    static const uint8_t quadrants[] = {4, 8, 1, 13, 9, 7, 11, 2, 6, 14};
    uint8_t mask = quadrants[codepoint - 0x2596];
    if (mask & 1) ts_box_fill(pen, 0, 0, mx, my, 1);
    if (mask & 2) ts_box_fill(pen, mx, 0, w, my, 1);
    if (mask & 4) ts_box_fill(pen, 0, my, mx, h, 1);
    if (mask & 8) ts_box_fill(pen, mx, my, w, h, 1);
  }
}

size_t ts_box_drawing(uint32_t codepoint, float width, float height, float scale, TSBoxRect* out) {
  if (codepoint < 0x2500 || codepoint > 0x259f || width <= 0 || height <= 0) return 0;
  TSBoxPen pen = {.out = out, .count = 0, .scale = scale > 0 ? scale : 1};
  float light = fmaxf(1, roundf(width / 8 * pen.scale)) / pen.scale;
  float heavy = light * 2;
  if (codepoint <= 0x254f) {
    ts_box_lines(&pen, ts_box_arms[codepoint - 0x2500], width, height, light, heavy);
  } else if (codepoint <= 0x256c) {
    ts_box_double(&pen, codepoint, width, height, light);
  } else if (codepoint <= 0x2570) {
    bool up = codepoint == 0x256f || codepoint == 0x2570;
    bool right = codepoint == 0x256d || codepoint == 0x2570;
    ts_box_round(&pen, up, right, width, height, light);
  } else if (codepoint <= 0x2573) {
    return 0;
  } else if (codepoint <= 0x257f) {
    ts_box_lines(&pen, ts_box_stubs[codepoint - 0x2574], width, height, light, heavy);
  } else {
    ts_box_block(&pen, codepoint, width, height);
  }
  return pen.count;
}
