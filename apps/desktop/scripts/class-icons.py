# Cuts the class icons the app shows from the game's UI-Classes-Circles
# texture (file 237669), a 4 by 4 grid in CLASS_ICON_TCOORDS order.
#   curl -o circles.blp "https://wago.tools/api/casc/237669?version=1.60.1.70245"
#   python scripts/class-icons.py circles.blp src/classes   (needs Pillow)
import sys
from PIL import Image

source, out = sys.argv[1], sys.argv[2]
sheet = Image.open(source).convert("RGBA")
grid = {"warrior": (0, 0), "mage": (1, 0), "rogue": (2, 0), "druid": (3, 0),
        "hunter": (0, 1), "shaman": (1, 1), "priest": (2, 1), "warlock": (3, 1), "paladin": (0, 2)}
size = sheet.size[0] // 4
for name, (x, y) in grid.items():
    sheet.crop((x * size, y * size, (x + 1) * size, (y + 1) * size)).save(f"{out}/{name}.png")
