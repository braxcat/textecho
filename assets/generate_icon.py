#!/usr/bin/env python3
"""Generate TextEcho app icon at all required sizes for .icns."""

import math
import struct
import zlib
import os

def create_png(width, height, pixels):
    """Create a PNG file from RGBA pixel data."""
    def make_chunk(chunk_type, data):
        chunk = chunk_type + data
        crc = struct.pack('>I', zlib.crc32(chunk) & 0xffffffff)
        return struct.pack('>I', len(data)) + chunk + crc

    header = b'\x89PNG\r\n\x1a\n'
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)

    raw_data = b''
    for y in range(height):
        raw_data += b'\x00'  # filter byte
        for x in range(width):
            idx = (y * width + x) * 4
            raw_data += bytes(pixels[idx:idx+4])

    compressed = zlib.compress(raw_data, 9)

    png = header
    png += make_chunk(b'IHDR', ihdr)
    png += make_chunk(b'IDAT', compressed)
    png += make_chunk(b'IEND', b'')
    return png


def draw_icon(size):
    """Draw the TextEcho icon at the given size."""
    pixels = [0] * (size * size * 4)

    cx, cy = size / 2, size / 2
    scale = size / 1024.0

    def set_pixel(x, y, r, g, b, a=255):
        if 0 <= x < size and 0 <= y < size:
            idx = (y * size + x) * 4
            # Alpha blend
            old_a = pixels[idx + 3]
            if old_a == 0:
                pixels[idx] = r
                pixels[idx+1] = g
                pixels[idx+2] = b
                pixels[idx+3] = a
            else:
                fa = a / 255.0
                pixels[idx] = int(r * fa + pixels[idx] * (1 - fa))
                pixels[idx+1] = int(g * fa + pixels[idx+1] * (1 - fa))
                pixels[idx+2] = int(b * fa + pixels[idx+2] * (1 - fa))
                pixels[idx+3] = min(255, old_a + a)

    def fill_circle(cx, cy, radius, r, g, b, a=255):
        r2 = radius * radius
        for y in range(max(0, int(cy - radius - 1)), min(size, int(cy + radius + 2))):
            for x in range(max(0, int(cx - radius - 1)), min(size, int(cx + radius + 2))):
                dx = x - cx
                dy = y - cy
                d2 = dx*dx + dy*dy
                if d2 <= r2:
                    # Anti-alias at edge
                    edge = radius - math.sqrt(d2)
                    aa = min(1.0, max(0.0, edge * 1.5))
                    set_pixel(x, y, r, g, b, int(a * aa))

    def fill_rounded_rect(x1, y1, x2, y2, radius, r, g, b, a=255):
        for y in range(max(0, int(y1)), min(size, int(y2) + 1)):
            for x in range(max(0, int(x1)), min(size, int(x2) + 1)):
                inside = True
                edge_dist = float('inf')

                # Check corners
                corners = [
                    (x1 + radius, y1 + radius),
                    (x2 - radius, y1 + radius),
                    (x1 + radius, y2 - radius),
                    (x2 - radius, y2 - radius),
                ]

                for cx_c, cy_c in corners:
                    dx = abs(x - cx_c)
                    dy = abs(y - cy_c)
                    if (x < x1 + radius or x > x2 - radius) and \
                       (y < y1 + radius or y > y2 - radius):
                        dist = math.sqrt(dx*dx + dy*dy)
                        if dist > radius:
                            inside = False
                        edge_dist = min(edge_dist, radius - dist)

                if inside:
                    aa = min(1.0, max(0.0, edge_dist * 1.5)) if edge_dist < 2 else 1.0
                    set_pixel(x, y, r, g, b, int(a * aa))

    # === Background: rounded square ===
    margin = 80 * scale
    corner_r = 200 * scale
    # Dark gradient background (Tokyo Night inspired)
    bg_r1, bg_g1, bg_b1 = 0x16, 0x16, 0x2b  # Deep navy top
    bg_r2, bg_g2, bg_b2 = 0x1a, 0x1b, 0x26  # Tokyo Night bottom

    for y in range(size):
        for x in range(size):
            # Check if inside rounded rect
            x1, y1 = margin, margin
            x2, y2 = size - margin, size - margin

            inside = True
            edge_dist = float('inf')

            if x < x1 + corner_r and y < y1 + corner_r:
                d = math.sqrt((x - x1 - corner_r)**2 + (y - y1 - corner_r)**2)
                if d > corner_r: inside = False
                edge_dist = corner_r - d
            elif x > x2 - corner_r and y < y1 + corner_r:
                d = math.sqrt((x - x2 + corner_r)**2 + (y - y1 - corner_r)**2)
                if d > corner_r: inside = False
                edge_dist = corner_r - d
            elif x < x1 + corner_r and y > y2 - corner_r:
                d = math.sqrt((x - x1 - corner_r)**2 + (y - y2 + corner_r)**2)
                if d > corner_r: inside = False
                edge_dist = corner_r - d
            elif x > x2 - corner_r and y > y2 - corner_r:
                d = math.sqrt((x - x2 + corner_r)**2 + (y - y2 + corner_r)**2)
                if d > corner_r: inside = False
                edge_dist = corner_r - d
            elif x < x1 or x > x2 or y < y1 or y > y2:
                inside = False
                edge_dist = 0
            else:
                edge_dist = min(x - x1, x2 - x, y - y1, y2 - y)

            if inside:
                t = (y - margin) / (size - 2 * margin)
                r = int(bg_r1 + (bg_r2 - bg_r1) * t)
                g = int(bg_g1 + (bg_g2 - bg_g1) * t)
                b = int(bg_b1 + (bg_b2 - bg_b1) * t)
                aa = min(1.0, max(0.0, edge_dist * 1.5)) if edge_dist < 2 else 1.0
                set_pixel(x, y, r, g, b, int(255 * aa))

    # === Waveform bars (center of icon) ===
    # Audio waveform visualization - clean vertical bars
    wave_cx = cx
    wave_cy = cy - 30 * scale
    bar_width = 28 * scale
    bar_gap = 18 * scale
    bar_heights = [0.3, 0.55, 0.85, 1.0, 0.7, 0.95, 0.6, 0.4, 0.75, 0.5, 0.35]
    max_bar_h = 280 * scale

    # Accent blue color (#7aa2f7) with glow
    accent_r, accent_g, accent_b = 0x7a, 0xa2, 0xf7

    num_bars = len(bar_heights)
    total_w = num_bars * bar_width + (num_bars - 1) * bar_gap
    start_x = wave_cx - total_w / 2

    for i, h_ratio in enumerate(bar_heights):
        bar_h = max_bar_h * h_ratio
        bx = start_x + i * (bar_width + bar_gap)
        by = wave_cy - bar_h / 2
        bar_r = bar_width / 2

        # Draw rounded bar
        for y in range(max(0, int(by - 1)), min(size, int(by + bar_h + 2))):
            for x in range(max(0, int(bx - 1)), min(size, int(bx + bar_width + 2))):
                dx = x - (bx + bar_width / 2)
                dy_top = y - (by + bar_r)
                dy_bot = y - (by + bar_h - bar_r)

                inside = False
                edge = 0

                if y < by + bar_r:
                    d = math.sqrt(dx*dx + dy_top*dy_top)
                    if d <= bar_r:
                        inside = True
                        edge = bar_r - d
                elif y > by + bar_h - bar_r:
                    d = math.sqrt(dx*dx + dy_bot*dy_bot)
                    if d <= bar_r:
                        inside = True
                        edge = bar_r - d
                elif abs(dx) <= bar_width / 2:
                    inside = True
                    edge = bar_width / 2 - abs(dx)

                if inside:
                    # Gradient: lighter at top, accent at bottom
                    t = (y - by) / max(1, bar_h)
                    pr = int(accent_r + (255 - accent_r) * 0.3 * (1 - t))
                    pg = int(accent_g + (255 - accent_g) * 0.2 * (1 - t))
                    pb = min(255, int(accent_b + (255 - accent_b) * 0.1 * (1 - t)))
                    aa = min(1.0, max(0.0, edge * 1.5))
                    set_pixel(x, y, pr, pg, pb, int(255 * aa))

    # === Text cursor (blinking cursor line) ===
    cursor_x = wave_cx + total_w / 2 + 35 * scale
    cursor_y1 = wave_cy - max_bar_h * 0.4
    cursor_y2 = wave_cy + max_bar_h * 0.4
    cursor_w = 8 * scale

    # Green cursor (#9ece6a)
    for y in range(int(cursor_y1), int(cursor_y2)):
        for x in range(int(cursor_x), int(cursor_x + cursor_w)):
            if 0 <= x < size and 0 <= y < size:
                # Soft edges
                ex = min(x - cursor_x, cursor_x + cursor_w - x)
                ey = min(y - cursor_y1, cursor_y2 - y)
                edge = min(ex, ey)
                aa = min(1.0, max(0.0, edge * 0.8))
                set_pixel(x, y, 0x9e, 0xce, 0x6a, int(220 * aa))

    # === Subtle "TE" monogram at bottom ===
    # Small text hint at bottom
    text_y = cy + 200 * scale
    text_size = 48 * scale
    dim_r, dim_g, dim_b = 0x56, 0x5f, 0x89

    # Simple "T"
    t_x = cx - 60 * scale
    t_w = 50 * scale
    t_thick = 8 * scale
    # T horizontal
    for y in range(int(text_y), int(text_y + t_thick)):
        for x in range(int(t_x - t_w/2), int(t_x + t_w/2)):
            if 0 <= x < size and 0 <= y < size:
                set_pixel(x, y, dim_r, dim_g, dim_b, 180)
    # T vertical
    for y in range(int(text_y), int(text_y + text_size)):
        for x in range(int(t_x - t_thick/2), int(t_x + t_thick/2)):
            if 0 <= x < size and 0 <= y < size:
                set_pixel(x, y, dim_r, dim_g, dim_b, 180)

    # Simple "E"
    e_x = cx + 10 * scale
    e_w = 40 * scale
    e_thick = 8 * scale
    # E vertical
    for y in range(int(text_y), int(text_y + text_size)):
        for x in range(int(e_x), int(e_x + e_thick)):
            if 0 <= x < size and 0 <= y < size:
                set_pixel(x, y, dim_r, dim_g, dim_b, 180)
    # E top horizontal
    for y in range(int(text_y), int(text_y + e_thick)):
        for x in range(int(e_x), int(e_x + e_w)):
            if 0 <= x < size and 0 <= y < size:
                set_pixel(x, y, dim_r, dim_g, dim_b, 180)
    # E middle horizontal
    mid_y = text_y + text_size / 2 - e_thick / 2
    for y in range(int(mid_y), int(mid_y + e_thick)):
        for x in range(int(e_x), int(e_x + e_w * 0.8)):
            if 0 <= x < size and 0 <= y < size:
                set_pixel(x, y, dim_r, dim_g, dim_b, 180)
    # E bottom horizontal
    for y in range(int(text_y + text_size - e_thick), int(text_y + text_size)):
        for x in range(int(e_x), int(e_x + e_w)):
            if 0 <= x < size and 0 <= y < size:
                set_pixel(x, y, dim_r, dim_g, dim_b, 180)

    return pixels


# Generate all required icon sizes
sizes = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}

iconset_dir = "assets/TextEcho.iconset"
os.makedirs(iconset_dir, exist_ok=True)

for filename, sz in sizes.items():
    print(f"  Generating {filename} ({sz}x{sz})...")
    pixels = draw_icon(sz)
    png_data = create_png(sz, sz, pixels)
    with open(os.path.join(iconset_dir, filename), 'wb') as f:
        f.write(png_data)

print("Done! Now run:")
print("  iconutil -c icns assets/TextEcho.iconset -o assets/TextEcho.icns")
