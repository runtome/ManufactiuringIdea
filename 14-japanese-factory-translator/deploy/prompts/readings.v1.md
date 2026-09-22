---
id: readings.v1
purpose: two or three plain readings of an ambiguous sentence instead of a guess (FR-15, AC-05; IF-75)
model_max_params_b: 9
temperature: 0.3
output: json
inputs: [source_text, source_lang, target_langs, ambiguity_reason]
---
The sentence below can be read in more than one way. Give the reader the possible readings so a person can ask which one was meant. Do not pick one.

Sentence ({{source_lang}}): {{source_text}}
Why it is ambiguous: {{ambiguity_reason}}

Rules:
1. Give 2 or 3 readings, each a plain restatement in {{source_lang}} plus a translation into each of {{target_langs}}.
2. Each reading gets a short usage note: in what situation a plant worker would mean this reading.
3. Keep every number, code and term exactly as in the sentence.
4. Do not add a recommendation, a cause or a document reference.

Answer with JSON only:
{"readings": [{"ordinal": 1, "reading_ja": "...", "th": "...", "en": "...", "usage_note": "..."}]}
