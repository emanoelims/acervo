# Uniform media and automatic snapshots (#80, #81)

## Goal

Cards look even: every card image has the same shape. Links without a preview
image get one automatically, a screenshot of the page's first screen, and the
user can ask for a new one at any time.

## Decisions

- **One shape.** Card and detail images are 16:10, cropped with
  `object-fit: cover` from the top. The YouTube thumbnail and the capture
  skeleton use the same ratio. Extra images in the link column keep their
  natural size.
- **Screenshots come from a Fly Sprite.** `infra/screenshots/` holds the
  service (Playwright Chromium behind `POST /shot`, 1200×750 JPEG). The app
  calls it with `ACERVO_SHOTS_URL` and `ACERVO_SHOTS_TOKEN`; without them the
  feature is off (dev and test) and everything works as before.
- **A new image kind, `:snapshot`.** Generated screenshots are told apart
  from screenshots the user uploads (`:screenshot`). A new snapshot replaces
  the link's previous snapshots and never touches uploads or previews. The
  kind column is a string, so no migration is needed.
- **When.** A capture that ends with no card image (no preview, screenshot
  or snapshot) on a generic link enqueues a snapshot. This includes captures
  that end with a permanent error (403, bot walls), because a real browser
  often gets through where the plain fetch did not. YouTube, X and Instagram
  links keep their own images.
- **Enrichment waits for the snapshot.** When a snapshot is enqueued, the
  capture does not enqueue enrichment; the snapshot job does when it ends,
  whatever the outcome, if the link was never enriched. So the model sees the
  image and is paid once. A snapshot the user asks for re-enriches the link,
  like an uploaded screenshot does today.
- **"Generate a new image".** The camera button in the link column becomes a
  small menu: generate a new image (only when the feature is on) and upload
  one. While the job runs the menu item shows progress; a failure shows a
  quiet flash.
- **No placeholder** for cards that still have no image: they stay compact
  text cards. With snapshots, these are rare.

## Components

- `Acervo.Library.Screenshots`: `enabled?/0` and `take(url)` returning
  `{:ok, jpeg}` or `{:error, reason}`, where the reason says whether a retry
  can help (`:busy`, transport and 5xx are transient; `:rejected` for 400 and
  422, `:unauthorized` for 401, are permanent). Req, with the test plug
  pattern the app already uses for external HTTP.
- `Acervo.Library.CaptureSnapshot`: Oban worker on a new `snapshot` queue
  (limit 1), 3 attempts, unique per link. Args: `link_id`, `replace`
  (user-requested). Busy snoozes. Stores through `Images.normalize/1` and
  `Storage.put/3`, in one transaction that deletes the link's old snapshots
  and moves its other card images down. Broadcasts the link; on a final
  failure of a requested snapshot, broadcasts `{:snapshot_failed, link}`.
- `CaptureLink`: decides between enqueueing the snapshot and enrichment, as
  above.
- `Library.request_snapshot(scope, link)`: the public entry for the button.
- `Release.backfill_snapshots/0`: enqueues snapshots for ready generic links
  with no card image, at low priority.

## Testing

The client against a stubbed service (success, 401, 422, 503, timeout); the
worker's storage, replacement rules, enrichment hand-off and snooze; the
capture's choice between snapshot and enrichment; the LiveView menu and its
progress and failure states; CSS checked in the browser at desktop and phone
width.
