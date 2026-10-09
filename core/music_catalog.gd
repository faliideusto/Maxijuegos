class_name MusicCatalog
extends RefCounted
## Las pistas musicales del juego: una descripción por pista para SynthMusic. Cada minijuego declara cuál
## suena en su meta.tres (campo `music`); el menú, la presentación, el marcador y el final tienen la suya.
## Criterio: lo que pide concentración (Reflejos) va SIN música; lo frenético (machacar, carreras) va rápido y
## percusivo; lo espacial, con arpegios y bajo de sintetizador; el pantano, con ritmo saltarín; la bomba, con
## tensión menor. El volumen de cada una lo regula el autoload Audio.

## Orden en que se generan en segundo plano (la primera se necesita antes).
const ORDER: Array[StringName] = [&"menu", &"mash", &"platform", &"coins", &"cube", &"wave", &"tongue", &"bomb",
		&"spot", &"scoreboard", &"final"]

const SPECS := {
	# Menú, lobby y ajustes: cálido y tranquilo (Do mayor).
	&"menu": {"bpm": 104, "bars": 8, "root": 60, "scale": "major", "prog": [0, 4, 5, 3, 0, 4, 5, 4],
		"bass": "half", "arp": "updown", "arp_rate": 2, "arp_wave": 3, "lead": "motif", "lead_wave": 3,
		"drums": "half", "pad": true, "swing": 0.0, "seed": 11,
		"mix": {"bass": 0.5, "arp": 0.22, "lead": 0.26, "drums": 0.32, "pad": 0.16}},
	# ¡Machaca!: rápido y frenético.
	&"mash": {"bpm": 156, "bars": 8, "root": 57, "scale": "minor", "prog": [0, 0, 5, 4, 0, 0, 5, 6],
		"bass": "pulse16", "arp": "up", "arp_rate": 1, "arp_wave": 4, "lead": "motif", "lead_wave": 1,
		"drums": "four", "pad": false, "swing": 0.0, "seed": 23,
		"mix": {"bass": 0.5, "arp": 0.2, "lead": 0.26, "drums": 0.55, "pad": 0.0}},
	# Plataforma menguante: tenso y saltarín.
	&"platform": {"bpm": 132, "bars": 8, "root": 55, "scale": "dorian", "prog": [0, 3, 0, 4, 0, 3, 6, 4],
		"bass": "offbeat", "arp": "skip", "arp_rate": 2, "arp_wave": 1, "lead": "motif", "lead_wave": 4,
		"drums": "basic", "pad": false, "swing": 0.0, "seed": 31,
		"mix": {"bass": 0.55, "arp": 0.2, "lead": 0.24, "drums": 0.5, "pad": 0.0}},
	# Lluvia de monedas: alegre (pentatónica mayor).
	&"coins": {"bpm": 138, "bars": 8, "root": 62, "scale": "penta_major", "prog": [0, 2, 3, 2, 0, 2, 4, 3],
		"bass": "walk", "arp": "up", "arp_rate": 2, "arp_wave": 3, "lead": "motif", "lead_wave": 1,
		"drums": "basic", "pad": false, "swing": 0.12, "seed": 47,
		"mix": {"bass": 0.5, "arp": 0.24, "lead": 0.26, "drums": 0.42, "pad": 0.0}},
	# Salto Neón: electrónica de conducción (bombo a negras, bajo a semicorcheas).
	&"cube": {"bpm": 142, "bars": 8, "root": 52, "scale": "minor", "prog": [0, 0, 5, 5, 3, 3, 4, 4],
		"bass": "pulse16", "arp": "updown", "arp_rate": 1, "arp_wave": 4, "lead": "motif", "lead_wave": 2,
		"drums": "four", "pad": true, "swing": 0.0, "seed": 59,
		"mix": {"bass": 0.55, "arp": 0.18, "lead": 0.24, "drums": 0.55, "pad": 0.1}},
	# Onda Neón: synthwave espacial (arpegios largos y colchón).
	&"wave": {"bpm": 118, "bars": 8, "root": 57, "scale": "minor", "prog": [0, 5, 2, 6, 0, 5, 3, 4],
		"bass": "root8", "arp": "updown", "arp_rate": 1, "arp_wave": 3, "lead": "motif", "lead_wave": 2,
		"drums": "basic", "pad": true, "swing": 0.0, "seed": 71,
		"mix": {"bass": 0.5, "arp": 0.24, "lead": 0.22, "drums": 0.42, "pad": 0.2}},
	# Columpio de Lengua: pantano saltarín (pentatónica menor con swing).
	&"tongue": {"bpm": 104, "bars": 8, "root": 55, "scale": "penta_minor", "prog": [0, 0, 3, 2, 0, 0, 4, 2],
		"bass": "walk", "arp": "skip", "arp_rate": 2, "arp_wave": 3, "lead": "motif", "lead_wave": 3,
		"drums": "half", "pad": true, "swing": 0.22, "seed": 83,
		"mix": {"bass": 0.55, "arp": 0.24, "lead": 0.26, "drums": 0.36, "pad": 0.14}},
	# Bomba de Palabras: tensión (menor, sin melodía para no estorbar al escribir).
	&"bomb": {"bpm": 120, "bars": 8, "root": 53, "scale": "minor", "prog": [0, 0, 5, 4, 0, 0, 3, 4],
		"bass": "offbeat", "arp": "updown", "arp_rate": 2, "arp_wave": 4, "lead": "none", "lead_wave": 1,
		"drums": "march", "pad": true, "swing": 0.0, "seed": 97,
		"mix": {"bass": 0.5, "arp": 0.2, "lead": 0.0, "drums": 0.3, "pad": 0.14}},
	# Caza del Foco: baile de discoteca con tensión (bombo a negras, bajo a semicorcheas, arpegio rápido).
	&"spot": {"bpm": 136, "bars": 8, "root": 55, "scale": "minor", "prog": [0, 0, 3, 4, 0, 0, 5, 4],
		"bass": "pulse16", "arp": "up", "arp_rate": 1, "arp_wave": 4, "lead": "motif", "lead_wave": 2,
		"drums": "four", "pad": true, "swing": 0.0, "seed": 131,
		"mix": {"bass": 0.55, "arp": 0.2, "lead": 0.24, "drums": 0.55, "pad": 0.12}},
	# Marcador: animado y breve.
	&"scoreboard": {"bpm": 124, "bars": 4, "root": 60, "scale": "major", "prog": [0, 3, 4, 0],
		"bass": "root8", "arp": "up", "arp_rate": 2, "arp_wave": 3, "lead": "motif", "lead_wave": 3,
		"drums": "basic", "pad": false, "swing": 0.0, "seed": 101,
		"mix": {"bass": 0.5, "arp": 0.22, "lead": 0.26, "drums": 0.4, "pad": 0.0}},
	# Pantalla final: celebración (la fanfarria suena aparte, encima).
	&"final": {"bpm": 112, "bars": 8, "root": 62, "scale": "major", "prog": [0, 3, 4, 0, 5, 3, 4, 0],
		"bass": "root8", "arp": "updown", "arp_rate": 1, "arp_wave": 3, "lead": "motif", "lead_wave": 1,
		"drums": "four", "pad": true, "swing": 0.0, "seed": 113,
		"mix": {"bass": 0.5, "arp": 0.2, "lead": 0.28, "drums": 0.42, "pad": 0.16}},
}

## Volumen relativo de cada pista (dB): las que acompañan a la acción van más bajas.
const VOLUME_DB := {
	&"menu": -13.0, &"mash": -15.0, &"platform": -15.0, &"coins": -15.0, &"cube": -15.0, &"wave": -15.0,
	&"tongue": -15.0, &"bomb": -17.0, &"spot": -15.0, &"scoreboard": -14.0, &"final": -13.0,
}
