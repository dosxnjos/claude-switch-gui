from PIL import Image, ImageDraw, ImageFont
import math, os, struct, io

def draw_rounded_rect(draw, xy, radius, fill):
    x0, y0, x1, y1 = xy
    draw.rectangle([x0 + radius, y0, x1 - radius, y1], fill=fill)
    draw.rectangle([x0, y0 + radius, x1, y1 - radius], fill=fill)
    draw.ellipse([x0, y0, x0 + radius*2, y0 + radius*2], fill=fill)
    draw.ellipse([x1 - radius*2, y0, x1, y0 + radius*2], fill=fill)
    draw.ellipse([x0, y1 - radius*2, x0 + radius*2, y1], fill=fill)
    draw.ellipse([x1 - radius*2, y1 - radius*2, x1, y1], fill=fill)

def draw_swap_arrows(draw, cx, cy, r, color, lw):
    """Draw two semicircular swap arrows (clockwise top, counterclockwise bottom)"""
    # Top arc: left to right (going over the top)
    # Bottom arc: right to left (going under the bottom)

    steps = 60

    # Top arrow: arc from 200° to 340° (left side going up and right)
    top_pts = []
    for i in range(steps + 1):
        a = math.radians(200 + (140 * i / steps))
        top_pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))

    # Bottom arrow: arc from 20° to 160° (right side going down and left)
    bot_pts = []
    for i in range(steps + 1):
        a = math.radians(20 + (140 * i / steps))
        bot_pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))

    for pts in [top_pts, bot_pts]:
        for i in range(len(pts) - 1):
            draw.line([pts[i], pts[i+1]], fill=color, width=lw)

    def arrowhead(tip, prev, size, color):
        dx = tip[0] - prev[0]
        dy = tip[1] - prev[1]
        length = math.hypot(dx, dy)
        if length == 0:
            return
        ux, uy = dx/length, dy/length
        px, py = -uy, ux
        p1 = (tip[0] - ux*size + px*size*0.5, tip[1] - uy*size + py*size*0.5)
        p2 = (tip[0] - ux*size - px*size*0.5, tip[1] - uy*size - py*size*0.5)
        draw.polygon([tip, p1, p2], fill=color)

    arrowhead(top_pts[-1], top_pts[-3], lw * 2.2, color)
    arrowhead(bot_pts[-1], bot_pts[-3], lw * 2.2, color)

def make_icon(size):
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # Background rounded square
    CLAUDE_ORANGE = (204, 112, 76)
    CLAUDE_DARK   = (170, 85, 50)
    pad = max(1, size // 64)
    radius = size // 5
    draw_rounded_rect(draw, (pad, pad, size - pad, size - pad), radius, CLAUDE_ORANGE)

    # Subtle inner shadow / gradient feel — darker bottom strip
    for i in range(size // 4):
        alpha = int(40 * i / (size // 4))
        y = size - size//4 + i
        draw.line([(pad, y), (size - pad, y)],
                  fill=(0, 0, 0, alpha))

    # Draw "C" letter — bold, centered, slightly up
    WHITE = (255, 255, 255)
    font_size = int(size * 0.52)
    font = None
    for name in ["arialbd.ttf", "Arial Bold.ttf", "arial.ttf", "DejaVuSans-Bold.ttf"]:
        try:
            font = ImageFont.truetype(name, font_size)
            break
        except:
            pass
    if font is None:
        font = ImageFont.load_default()

    bbox = draw.textbbox((0, 0), "C", font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    tx = (size - tw) / 2 - bbox[0]
    ty = (size - th) / 2 - bbox[1] - size * 0.04
    draw.text((tx, ty), "C", font=font, fill=WHITE)

    # Badge circle in bottom-right for swap arrows
    badge_r   = size // 4
    badge_cx  = size - badge_r + size // 16
    badge_cy  = size - badge_r + size // 16

    # Badge background: slightly darker circle
    BADGE_BG = (160, 76, 42, 240)
    draw.ellipse(
        [badge_cx - badge_r, badge_cy - badge_r,
         badge_cx + badge_r, badge_cy + badge_r],
        fill=BADGE_BG
    )

    # Swap arrows inside badge
    arrow_r = int(badge_r * 0.52)
    lw = max(2, size // 32)
    draw_swap_arrows(draw, badge_cx, badge_cy, arrow_r, WHITE, lw)

    return img

sizes = [256, 128, 64, 48, 32, 16]
images = {s: make_icon(s) for s in sizes}

# Save PNG (preview)
images[256].save("claude-switch-icon.png")

# Build ICO manually with all sizes
def img_to_bmp_bytes(img):
    buf = io.BytesIO()
    img.save(buf, format="BMP")
    data = buf.getvalue()
    return data[14:]  # strip BMP file header, keep DIB

def img_to_png_bytes(img):
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()

# ICO header
num_images = len(sizes)
header = struct.pack("<HHH", 0, 1, num_images)

image_data = []
for s in sizes:
    if s >= 256:
        data = img_to_png_bytes(images[s])
    else:
        data = img_to_bmp_bytes(images[s])
    image_data.append(data)

offset = 6 + num_images * 16
entries = b""
for i, s in enumerate(sizes):
    w = 0 if s == 256 else s
    h = 0 if s == 256 else s
    entries += struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(image_data[i]), offset)
    offset += len(image_data[i])

with open("claude-switch.ico", "wb") as f:
    f.write(header + entries)
    for d in image_data:
        f.write(d)

print("Done: claude-switch.ico and claude-switch-icon.png")
