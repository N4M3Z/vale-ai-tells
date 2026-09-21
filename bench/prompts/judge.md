# Judge prompt

You are reviewing a text for the marks of machine-generated prose, the patterns a careful reader recognizes as written by a language model rather than a person. Do not judge quality or correctness. Do not guess who wrote it. Annotate the sentences.

Read the whole document first. Then list every sentence that carries a tell. For each one, output an object with these fields:

- `sentence`: the sentence verbatim, as one string.
- `quote`: the shortest span inside the sentence that carries the tell.
- `category`: one of `vocabulary`, `negative-parallelism`, `rule-of-three`, `hedging`, `filler`, `sycophancy`, `generic-conclusion`, `superficial-ing`, `vague-attribution`, `figurative-verb`, `metaphor-noun`, `anthropomorphism`, `em-dash`, `colon-drumroll`, `staccato`, `bold-or-list-overuse`, `title-case-heading`, `over-compression`, `synonym-cycling`, `false-range`, `other`.
- `tell`: one sentence naming the pattern in plain words.
- `regex`: a case-insensitive regular expression that would match this tell in other texts, or null if the pattern is not expressible as a regex over the sentence.
- `confidence`: `high`, `medium`, or `low`.

Do not flag a plain declarative sentence for being plain. Do not flag a term of art in its field. Do not flag one em dash, one bold run, or one transition word; flag a density of them, and put the density claim in `tell`.

Return only a JSON object: `{"document": "<id>", "annotations": [ ... ]}`. No prose before or after the JSON.

The document id is `{{DOCUMENT_ID}}`. The text follows the line of equals signs.

====================
{{TEXT}}
