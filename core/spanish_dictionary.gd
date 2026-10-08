class_name SpanishDictionary
extends RefCounted
## Diccionario español para los minijuegos de palabras. Los datos están en res://data/ y se generan con
## tools/build_dictionary.py a partir del diccionario ortográfico es_ES de LibreOffice (triple licencia
## GPLv3+/LGPLv3+/MPL 1.1+; se usa bajo MPL 1.1; ver data/DICCIONARIO_LICENCIA.md).
##
##   data/es_words.txt      593 mil formas (plurales, conjugaciones...), en minúsculas y sin tildes (con ñ),
##                          una por línea y ordenadas
##   data/es_tiers.txt      combinaciones de letras por nivel: "nivel|cas|nº de palabras|ejemplo,ejemplo,..."
##
## Todo se compara "normalizado": minúsculas y sin tildes ni diéresis (la ñ se conserva), así que
## "Camión", "camion" y "CAMIÓN" son la misma palabra. Se carga una sola vez por proceso.
## Para exportar el juego hay que incluir *.txt en los recursos exportados.

const WORDS_PATH := "res://data/es_words.txt"
const TIERS_PATH := "res://data/es_tiers.txt"

static var _words: Array = []
static var _loaded: bool = false
## Combinaciones de letras por nivel de dificultad (índice 0 = nivel 1, muy fácil ... 4 = nivel 5, experto).
static var tiers: Array = []                    # Array de Array[String]
static var syllable_samples: Dictionary = {}    # combinación → Array[String] de palabras de ejemplo

static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	if FileAccess.file_exists(WORDS_PATH):
		var text := FileAccess.get_file_as_string(WORDS_PATH).replace(char(13), "")
		_words = Array(text.split(char(10), false))
	else:
		push_warning("SpanishDictionary: falta %s (genera los datos con tools/build_dictionary.py)" % WORDS_PATH)
	if FileAccess.file_exists(TIERS_PATH):
		for line in FileAccess.get_file_as_string(TIERS_PATH).replace(char(13), "").split(char(10), false):
			var parts := line.split("|")
			if parts.size() < 4:
				continue
			var tier := int(parts[0]) - 1
			while tiers.size() <= tier:
				tiers.append([])
			tiers[tier].append(parts[1])
			syllable_samples[parts[1]] = Array(parts[3].split(",", false))

static func word_count() -> int:
	ensure_loaded()
	return _words.size()

## Minúsculas, sin tildes ni diéresis (se conserva la ñ). Los demás caracteres se dejan tal cual.
static func normalize(text: String) -> String:
	var out := ""
	for ch in text.to_lower():
		match ch:
			"á", "à", "â", "ä": out += "a"
			"é", "è", "ê", "ë": out += "e"
			"í", "ì", "î", "ï": out += "i"
			"ó", "ò", "ô", "ö": out += "o"
			"ú", "ù", "û", "ü": out += "u"
			_: out += ch
	return out

## ¿Son todo letras a-z/ñ? (la palabra debe estar ya normalizada)
static func is_letters(word: String) -> bool:
	if word.is_empty():
		return false
	for ch in word:
		if not ((ch >= "a" and ch <= "z") or ch == "ñ"):
			return false
	return true

## ¿Existe la palabra (ya normalizada)?
static func has_word(word: String) -> bool:
	ensure_loaded()
	var i := _words.bsearch(word)
	return i < _words.size() and _words[i] == word

## Palabras de ejemplo (normalizadas) que contienen la combinación.
static func samples_for(syllable: String) -> Array:
	ensure_loaded()
	return syllable_samples.get(syllable, [])
