extends SceneTree
## Renderiza todas las pistas de MusicCatalog a WAV en build/music_wav/ para la versión web, que no puede
## generarlas en un hilo al arrancar. Después tools/bake_music.sh las pasa a OGG en res://audio/music/.
## Ejecutar tras cambiar MusicCatalog o SynthMusic:
##   tools/bake_music.sh            (necesita GODOT y ffmpeg)

const OUT_DIR := "res://build/music_wav"

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))
	for id in MusicCatalog.ORDER:
		var stream := SynthMusic.to_stream(SynthMusic.render(MusicCatalog.SPECS[id]))
		var path := "%s/%s.wav" % [OUT_DIR, id]
		var err := stream.save_to_wav(path)
		if err != OK:
			push_error("bake_music: no se pudo guardar %s (%s)" % [path, error_string(err)])
			quit(1)
			return
		print("bake_music: %s" % path)
	quit(0)
