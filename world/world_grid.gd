class_name WorldGrid
extends RefCounted

## The room's LOGICAL grid — the single source of truth for what's wall, what's floor,
## and where tiles sit in pixel space. The TileMapLayer in main.tscn is PRESENTATION only:
## main.gd paints it FROM this data at runtime, so the picture can never disagree with the
## adjudication grid. This room is a disposable prototype fixture — procedural dungeon
## generation replaces the hardcoded ROOM_LAYOUT at ROADMAP M4a.
##
## All-static: never instanced. Every function is a pure query over the consts below; there is
## no per-node state to hold. (extends RefCounted only so `class_name` is legal — no instances
## are made.)

## Pixels per tile edge (square). Matches the 32rogues tileset cell size.
const TILE_PX := 32

## 48 columns × 28 rows. '#' = wall, '.' = floor. Read as ROOM_LAYOUT[row][col], i.e.
## ROOM_LAYOUT[tile.y][tile.x]. Disposable multi-room fixture (M3.5 — the screen-size /
## camera question; M4a's procedural generation replaces it). Five rooms joined by 1–2-tile
## corridors:
##  - A  start room, top-left      (cols 2–13, rows 2–8)
##  - B  top-right                 (cols 32–45, rows 2–9)
##  - C  centre                    (cols 19–30, rows 12–18)
##  - D  bottom-left               (cols 2–13, rows 19–25)
##  - E  bottom-right              (cols 33–45, rows 18–25)
## Corridors: A↔B along row 5; A↔D down col 7; the A–B corridor↔C down col 25; C↔E along
## row 16; D↔E along row 22.
## Features preserved from the M2 fixture, spread across the map:
##  - full wall border ((0,0) MUST stay wall — MoveReferee's _NO_TILE sentinel assumes it),
##  - a single pillar in A at (10,4) and a 2-tile pillar in C at (24,15)/(25,15),
##  - one diagonal-gate in B: walls at (40,5) and (41,4) touch only at a corner, with their
##    flanking tiles (40,4) and (41,5) left as floor — the corner rule rejects a diagonal
##    squeeze between the two walls even though both endpoints are floor.
const ROOM_LAYOUT: Array[String] = [
	"################################################",  # row 0  — border
	"################################################",  # row 1
	"##............##################..............##",  # row 2
	"##............##################..............##",  # row 3
	"##........#...##################.........#....##",  # row 4  — A pillar (10,4); gate wall (41,4)
	"##......................................#.....##",  # row 5  — A↔B corridor; gate wall (40,5)
	"##............###########.######..............##",  # row 6
	"##............###########.######..............##",  # row 7
	"##............###########.######..............##",  # row 8
	"#######.#################.######..............##",  # row 9
	"#######.#################.######################",  # row 10
	"#######.#################.######################",  # row 11
	"#######.###########............#################",  # row 12
	"#######.###########............#################",  # row 13
	"#######.###########............#################",  # row 14
	"#######.###########.....##.....#################",  # row 15 — C pillar (24,15)/(25,15)
	"#######.###########...............##############",  # row 16 — C↔E corridor
	"#######.###########............##.##############",  # row 17 — C↔E corridor turns south
	"#######.###########............##.............##",  # row 18
	"##............###################.............##",  # row 19
	"##............###################.............##",  # row 20
	"##............###################.............##",  # row 21
	"##............................................##",  # row 22 — D↔E corridor
	"##............###################.............##",  # row 23
	"##............###################.............##",  # row 24
	"##............###################.............##",  # row 25
	"################################################",  # row 26
	"################################################",  # row 27 — border
]


## The five rooms as tile rectangles (name → Rect2i), transcribed from the ROOM_LAYOUT ranges
## documented above. Rect2i is (position, size): size = span-inclusive count, so has_point(tile) is
## true for the whole authored range (e.g. A spans cols 2–13 → x in [2, 14), i.e. 2–13). Corridors
## belong to NO room and match none of these. Read by main.gd's F6 dev-summon (room_rect_of) to
## resolve which room a presser stands in. Query/presentation data like everything here — never
## adjudication truth; a spawn still filters by is_walkable + the referee's occupancy.
const ROOMS := {
	"A": Rect2i(2, 2, 12, 7),    # start room, top-left  (cols 2–13,  rows 2–8)
	"B": Rect2i(32, 2, 14, 8),   # top-right             (cols 32–45, rows 2–9)
	"C": Rect2i(19, 12, 12, 7),  # centre                (cols 19–30, rows 12–18)
	"D": Rect2i(2, 19, 12, 7),   # bottom-left           (cols 2–13,  rows 19–25)
	"E": Rect2i(33, 18, 13, 8),  # bottom-right          (cols 33–45, rows 18–25)
}


## Grid extent in tiles: Vector2i(columns, rows).
static func size() -> Vector2i:
	return Vector2i(ROOM_LAYOUT[0].length(), ROOM_LAYOUT.size())


## The room rectangle CONTAINING `tile`, or a ZERO-SIZE Rect2i when the tile lies in a corridor (or
## otherwise in no room). Callers test the result with `has_area()` / `size == Vector2i.ZERO` for
## "not in a room". Pure static query over ROOMS, like every function here.
static func room_rect_of(tile: Vector2i) -> Rect2i:
	for rect in ROOMS.values():
		if rect.has_point(tile):
			return rect
	return Rect2i()


## True if the tile coordinate lies within the grid rectangle.
static func in_bounds(tile: Vector2i) -> bool:
	var s := size()
	return tile.x >= 0 and tile.y >= 0 and tile.x < s.x and tile.y < s.y


## True if the tile is a wall. Out-of-bounds counts as wall (nothing off-grid is enterable).
static func is_wall(tile: Vector2i) -> bool:
	if not in_bounds(tile):
		return true
	return ROOM_LAYOUT[tile.y][tile.x] == "#"


## True if a body may occupy this tile: in-bounds AND not a wall.
static func is_walkable(tile: Vector2i) -> bool:
	return in_bounds(tile) and not is_wall(tile)


## Tile → world pixels at the tile's CENTER (tile*TILE_PX + half-tile), so sprites land on
## px ≡ TILE_PX/2 (mod TILE_PX). This is the position a player node renders at.
static func tile_to_world(tile: Vector2i) -> Vector2:
	var half := TILE_PX / 2
	return Vector2(tile.x * TILE_PX + half, tile.y * TILE_PX + half)


## World pixels → the tile that contains them (floor-divide by TILE_PX). Inverse of
## tile_to_world for any point inside a tile's cell.
static func world_to_tile(pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(pos.x / TILE_PX)), int(floor(pos.y / TILE_PX)))


## Grid-cell coords → the pixel Rect2 that windows that cell out of a TILE_PX-cell atlas
## (coords × TILE_PX, TILE_PX square). The ONE place the sprite/portrait region math lives, so
## every atlas-region site (player class, monster, weapon rig, party frame, char panel) can never
## drift from the tile size. Presentation-only, like every helper here.
static func atlas_region(coords: Vector2i) -> Rect2:
	return Rect2(coords.x * TILE_PX, coords.y * TILE_PX, TILE_PX, TILE_PX)


# ── Pathfinding ───────────────────────────────────────────────────────────────

# Lazily-built A* over the room, shared by every caller (static, like everything here). Solids
# come from is_wall only — OCCUPANCY IS DELIBERATELY NOT IN THIS GRID: bodies are volatile
# (they move every step, and per the corner rule bodies don't block diagonal squeezes), so
# callers route around them per-query via find_path's `avoid` parameter instead of mutating
# shared state. NOTE for M4a: dungeon regeneration must drop this cache (rebuild from the new
# layout) — a stale grid would path through the old room's walls.
static var _astar: AStarGrid2D = null


## 8-way path from `from` to `to` over the walkable grid, as tile coords with path[0] == from.
## Empty array = unreachable (or an endpoint is a wall/out of bounds). `avoid` tiles are made
## temporarily solid for THIS query only (transient obstacles — other bodies), restored after.
## Diagonals follow the corner rule's wall half exactly (AT_LEAST_ONE_WALKABLE — see _build_astar):
## a diagonal is refused only when BOTH flanking orthogonals are walls, so a path may round a single
## wall corner but never squeezes between two walls that touch only at a corner.
static func find_path(from: Vector2i, to: Vector2i, avoid: Array[Vector2i] = []) -> Array[Vector2i]:
	if not in_bounds(from) or not in_bounds(to):
		return []
	if _astar == null:
		_build_astar()
	# A solid origin can't happen today (players only ever stand on floor), so it means a spawn
	# or bookkeeping bug upstream — warn loudly instead of letting walks silently do nothing.
	if _astar.is_point_solid(from):
		push_warning("[WorldGrid] find_path from solid tile %s — no path (upstream bug?)" % from)
		return []
	# Temp-solid the avoid tiles; track only the ones we actually flipped so restore is exact
	# (walls are already solid, and `from` is never flipped — a solid start yields no path).
	var flipped: Array[Vector2i] = []
	for tile in avoid:
		if in_bounds(tile) and tile != from and not _astar.is_point_solid(tile):
			_astar.set_point_solid(tile, true)
			flipped.append(tile)
	var packed := _astar.get_id_path(from, to)
	for tile in flipped:
		_astar.set_point_solid(tile, false)
	var path: Array[Vector2i] = []
	for point in packed:
		path.append(point)
	return path


## Build the shared grid once from ROOM_LAYOUT: region = the room rectangle, solids = walls,
## octile heuristics (the natural 8-way distance), and AT_LEAST_ONE_WALKABLE diagonals — which
## mirrors the corner rule's RELAXED wall half (DESIGN §2.2.7, Jon 2026-07-21): a diagonal is now
## blocked only when BOTH flanking orthogonals are walls, so monster A* proposes exactly the
## single-wall-corner diagonals a player may take, and no others. (Body occupancy is per-query
## `avoid`, never baked in.)
static func _build_astar() -> void:
	_astar = AStarGrid2D.new()
	_astar.region = Rect2i(Vector2i.ZERO, size())
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_AT_LEAST_ONE_WALKABLE
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.update()
	var grid_size := size()
	for y in grid_size.y:
		for x in grid_size.x:
			var tile := Vector2i(x, y)
			if is_wall(tile):
				_astar.set_point_solid(tile, true)
