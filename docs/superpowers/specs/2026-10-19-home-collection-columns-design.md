# Home: one column per collection (#84)

## Goal

The home (`/`) shows the whole archive at a glance: next to the navigation
column, the inbox (when it has links) and then one narrow column per
collection, each with its newest links. Clicking a link opens it in the usual
layout, with its collection (or the inbox) as the list column.

## Decisions

- **Columns.** The navigation column, then the inbox column when it has
  links, then one column per non-empty collection, in the navigation's order
  (`position`, then name). Empty collections are left out of the home; they
  stay in the navigation.
- **Size.** Home columns are 320px wide, like the root column. At phone
  width each takes the screen and the row snaps, as today.
- **Content.** The 12 newest links of each column (inbox: the newest
  untriaged links), as compact cards, and a "See all (N)" row at the end
  that patches to the collection (`/c/<slug>`) or the inbox.
- **Compact card.** A variant of the link card: the 16:10 image and the
  title (two lines at most), with no description, date or source mark, and
  a smaller radius. Without an image: title and host. Pending links show the
  skeleton.
- **Opening a link.** A card in a collection column patches to
  `/c/<slug>/l/<id>`, one in the inbox column to `/inbox/l/<id>`: the
  existing layout, with that list as the first list column and the link
  next to it.
- **Live updates.** The home reloads only the columns a broadcast touches
  (saved, updated, deleted, moved between collections, triaged), so new
  links and generated images appear on their own.
- **One query.** The newest links of every collection come from a single
  query (a window function per collection), not one query per column.

## Components

- `Library` (or `Collections`): `home_columns(scope, per_column)` returns the
  inbox column (when it has links) and each non-empty collection with its
  newest links and total count, preloaded as the cards need them.
- `LinkComponents.card/1`: a `compact` variant.
- `ArchiveLive`: on `/` with no filter, renders the home columns after the
  root column; the existing filter layout is unchanged. Broadcast handlers
  refresh the affected home columns.
- `UIComponents.column`: a narrow size if needed.
- In-app guide and `guides/features.md` describe the new home; the
  styleguide (`/dev/styleguide`) shows the compact card and a home column.

## Testing

`home_columns/2` (order, limits, empty collections left out, inbox only when
non-empty, scoping to the user); the LiveView home (columns render, card
patches, "See all" patches, live refresh on a broadcast); a visual check at
desktop and phone width.
