class_name FrameStats
extends RefCounted
## Frame times over the last few seconds, for the stats readout. The average
## alone hides stutter, so it also gives the "1% low" (the rate the slowest
## hundredth of frames ran at, as in the benchmark) and the slowest frame.

const WINDOW_MS: float = 5000.0   ## how far back the figures look
const CAPACITY: int = 2048        ## frames kept at most (5 s at 400 frames a second)

var avg_ms: float = 0.0
var avg_fps: float = 0.0
var low_fps: float = 0.0          ## 1% low: 99 frames in 100 were at least this fast
var worst_ms: float = 0.0

var _ms: PackedFloat32Array = PackedFloat32Array()
var _head: int = 0                ## where the next frame is written
var _count: int = 0
var _span: float = 0.0            ## ms covered by the frames kept


func _init() -> void:
	_ms.resize(CAPACITY)


func clear() -> void:
	_head = 0
	_count = 0
	_span = 0.0


func count() -> int:
	return _count


## Record one frame that took `delta` seconds.
func add(delta: float) -> void:
	var ms: float = delta * 1000.0
	if _count == CAPACITY:
		_drop_oldest()
	_ms[_head] = ms
	_head = (_head + 1) % CAPACITY
	_count += 1
	_span += ms
	while _count > 1 and _span - _oldest() > WINDOW_MS:
		_drop_oldest()


func _oldest() -> float:
	return _ms[(_head - _count + CAPACITY) % CAPACITY]


func _drop_oldest() -> void:
	_span -= _oldest()
	_count -= 1


## Work the figures out from the frames kept. Sorting a few hundred numbers:
## call it a couple of times a second, not every frame.
func summarise() -> void:
	if _count == 0:
		avg_ms = 0.0
		avg_fps = 0.0
		low_fps = 0.0
		worst_ms = 0.0
		return
	var sorted: PackedFloat32Array = recent(_count)
	sorted.sort()
	avg_ms = _span / _count
	avg_fps = 1000.0 / maxf(avg_ms, 0.001)
	low_fps = 1000.0 / maxf(sorted[mini(int(_count * 0.99), _count - 1)], 0.001)
	worst_ms = sorted[_count - 1]


## The newest `n` frame times in ms, oldest first (for the graph).
func recent(n: int) -> PackedFloat32Array:
	var take: int = mini(n, _count)
	var out: PackedFloat32Array = PackedFloat32Array()
	out.resize(take)
	for i in range(take):
		out[i] = _ms[(_head - take + i + CAPACITY) % CAPACITY]
	return out
