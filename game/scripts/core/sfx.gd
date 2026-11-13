class_name Sfx
extends RefCounted
## Small audio helpers shared by the player's cockpit sounds and world sounds.


## A WAV resource set to loop over its whole length.
static func looped(path: String) -> AudioStreamWAV:
	var stream: AudioStreamWAV = load(path)
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = int(stream.get_length() * stream.mix_rate)
	return stream
