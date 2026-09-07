#!/usr/bin/env python3
"""Generate pixel-exact 1216x684 EPD grayscale test images."""

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


WIDTH = 1216
HEIGHT = 684
OUTPUT_DIR = Path(__file__).resolve().parents[3] / "Assets" / "TestPatterns"


def half_open_box(x0: int, y0: int, x1: int, y1: int) -> tuple[int, int, int, int]:
    """Convert half-open coordinates to Pillow's inclusive rectangle format."""
    return x0, y0, x1 - 1, y1 - 1


def draw_edge_rulers(draw: ImageDraw.ImageDraw) -> None:
    """Draw pixel-aligned rulers and asymmetric corners for locating clipping."""
    for x in range(0, WIDTH, 16):
        color = 0 if (x // 16) % 2 == 0 else 255
        draw.rectangle(half_open_box(x, 0, min(x + 16, WIDTH), 8), fill=color)
        draw.rectangle(
            half_open_box(x, HEIGHT - 8, min(x + 16, WIDTH), HEIGHT),
            fill=color,
        )

    for y in range(0, HEIGHT, 16):
        color = 0 if (y // 16) % 2 == 0 else 255
        draw.rectangle(half_open_box(0, y, 8, min(y + 16, HEIGHT)), fill=color)
        draw.rectangle(
            half_open_box(WIDTH - 8, y, WIDTH, min(y + 16, HEIGHT)),
            fill=color,
        )

    draw.rectangle(half_open_box(8, 8, WIDTH - 8, HEIGHT - 8), outline=0, width=2)

    # Four deliberately different corner marks make flips and one-pixel shifts clear.
    draw.rectangle(half_open_box(16, 16, 56, 56), fill=0)
    draw.rectangle(half_open_box(WIDTH - 56, 16, WIDTH - 16, 56), outline=0, width=4)
    draw.line((16, HEIGHT - 56, 56, HEIGHT - 16), fill=0, width=2)
    draw.line((56, HEIGHT - 56, 16, HEIGHT - 16), fill=0, width=2)
    for row in range(4):
        for col in range(4):
            color = 0 if (row + col) % 2 == 0 else 255
            x0 = WIDTH - 56 + col * 10
            y0 = HEIGHT - 56 + row * 10
            draw.rectangle(half_open_box(x0, y0, x0 + 10, y0 + 10), fill=color)


def draw_centered_binary_text(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int, int, int],
    text: str,
    fill: int,
    font: ImageFont.ImageFont,
) -> None:
    """Draw non-antialiased text so no unintended gray levels are introduced."""
    draw.fontmode = "1"
    bounds = draw.textbbox((0, 0), text, font=font)
    text_width = bounds[2] - bounds[0]
    text_height = bounds[3] - bounds[1]
    x0, y0, x1, y1 = xy
    x = x0 + (x1 - x0 - text_width) // 2
    y = y0 + (y1 - y0 - text_height) // 2
    draw.text((x, y), text, font=font, fill=fill)


def generate_16_level_chart() -> Image.Image:
    image = Image.new("L", (WIDTH, HEIGHT), 255)
    draw = ImageDraw.Draw(image)
    font = ImageFont.load_default(size=18)
    draw_edge_rulers(draw)

    chart_left = 32
    chart_top = 54
    cell_width = 288
    cell_height = 144

    for level in range(16):
        row, col = divmod(level, 4)
        x0 = chart_left + col * cell_width
        y0 = chart_top + row * cell_height
        x1 = x0 + cell_width
        y1 = y0 + cell_height
        value = level * 17
        draw.rectangle(half_open_box(x0, y0, x1, y1), fill=value)
        label_color = 255 if value < 128 else 0
        draw_centered_binary_text(
            draw,
            (x0, y0, x1, y1),
            f"LEVEL {level:02d}   Y={value:03d} (0x{value:02X})",
            label_color,
            font,
        )

    # Two-level separators remain visible at both ends of the grayscale range.
    for x in range(chart_left, chart_left + 4 * cell_width + 1, cell_width):
        draw.line((x, chart_top, x, chart_top + 4 * cell_height - 1), fill=255, width=1)
        if x + 1 < WIDTH:
            draw.line((x + 1, chart_top, x + 1, chart_top + 4 * cell_height - 1), fill=0, width=1)
    for y in range(chart_top, chart_top + 4 * cell_height + 1, cell_height):
        draw.line((chart_left, y, chart_left + 4 * cell_width - 1, y), fill=255, width=1)
        if y + 1 < HEIGHT:
            draw.line((chart_left, y + 1, chart_left + 4 * cell_width - 1, y + 1), fill=0, width=1)

    return image.convert("RGB")


def generate_uniform_grayscale_gradient() -> Image.Image:
    """Generate a full-height linear ramp from black at left to white at right."""
    row = bytes(round(x * 255 / (WIDTH - 1)) for x in range(WIDTH))
    return Image.frombytes("L", (WIDTH, HEIGHT), row * HEIGHT).convert("RGB")


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    outputs = {
        "epd_16_grayscale_1216x684.png": generate_16_level_chart(),
        "epd_uniform_grayscale_gradient_1216x684.png":
            generate_uniform_grayscale_gradient(),
    }
    for name, image in outputs.items():
        path = OUTPUT_DIR / name
        image.save(path, format="PNG", optimize=False)
        print(path)


if __name__ == "__main__":
    main()
