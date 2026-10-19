# Related links and AI notes (#83)

## Goal

From any link, see what else in the archive belongs with it, connect pages
by hand, and get a short summary with key points when asked.

## Decisions

### Related links

- The link column gets a "Related" section after the notes, with up to 5
  compact cards (the home's compact card).
- **Manual first.** Links the user connected by hand come first, marked with
  a link glyph.
- **Then similar ones.** Nearest neighbours by the link's embedding (pgvector
  cosine distance, HNSW), from the same user's links, excluding the link
  itself and the manual ones, kept only above the search's similarity cutoff
  (similarity ≥ 0.27). No model call.
- **See more.** A quiet "See more similar" row opens the search column with
  the full similar list, as a search scoped to "similar to <title>".
- Links without an embedding yet show only their manual relations.

### Manual relations

- A link-glyph button in the link's actions opens a popover picker, like the
  collection picker. It searches the user's links by title and connects the
  chosen one.
- **Symmetric.** One row per pair in `link_relations` (`link_a_id <
  link_b_id`, unique index, both foreign keys on delete cascade, `user_id`
  for scoping), so A↔B shows on both links.
- Each manual relation shows as a removable card or chip (✕), like
  collections.

### AI notes

- A "Generate notes" button in the notes area asks the model for a short
  summary paragraph and 3–7 key points, in Portuguese.
  - The input is the reader text when there is one, else the title,
    description and excerpt.
  - The output is structured (summary and points) and rendered as text.
- **Separate from the user's note.** Stored in its own field on the link
  (`ai_notes`, plus `ai_notes_at`) and editable like the note. "Generate
  again" replaces only the AI notes.
- **Setting.** "Automatic notes" in the settings popover, stored per user:
  `never` (default), `long` (reader text above about 1,500 words) or
  `always`. When automatic, notes are generated after enrichment, at the
  same priority.
- **Infrastructure.** An Oban job on the `ai` queue, unique per link, logs
  its cost in `ai_calls` with the default chat model (Opus 5.5). It uses the
  same prompt-injection defenses as enrichment: a random delimiter around
  page text and normalized output.
- **Search.** The AI notes join the link's search text (tsv and embedding
  document), so a link can be found by what its summary says.

## Testing

- Relations: create, delete, symmetric listing, scoping, no self-relations,
  duplicates rejected.
- Similar query: cutoff, exclusions, scoping.
- Notes job: stubbed model, replacement, cost logged, setting thresholds.
- LiveView: related section, picker, remove, generate button and its busy
  state, setting.
- Visual check of the related section and notes area.
