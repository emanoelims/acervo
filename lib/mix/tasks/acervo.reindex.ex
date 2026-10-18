defmodule Mix.Tasks.Acervo.Reindex do
  @shortdoc "Re-embeds links whose embedding is missing or from another model"

  @moduledoc """
  Enqueues `Acervo.Search.EmbedLink` for every ready link whose embedding is
  missing or was made with another model than the configured one. See
  `Acervo.Release.reindex/1`.

      mix acervo.reindex
      mix acervo.reindex --all

  `--all` enqueues every ready link, for a change in the embedded document's
  format; links whose document and model are unchanged still cost no call.

  The task starts no queues: the running app's `embed` queue does the work,
  so start the dev server first.
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {opts, _args} = OptionParser.parse!(args, strict: [all: :boolean])
    Mix.Task.run("app.config")
    Acervo.Release.reindex(all: Keyword.get(opts, :all, false))
  end
end
