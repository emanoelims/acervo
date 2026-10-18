defmodule Acervo.StaticResolver do
  @moduledoc """
  Test resolver that answers from `Application.get_env(:acervo, :static_hosts, %{})`,
  a map of host to a list of `:inet.ip_address()` tuples. Unknown hosts fail
  with `:nxdomain`. Shared fixture hosts live in `config/test.exs`; a test that
  needs more must put them in the environment from an `async: false` module.
  """
  @behaviour Acervo.Library.Resolver

  @impl true
  def resolve(host) do
    case Map.fetch(Application.get_env(:acervo, :static_hosts, %{}), String.downcase(host)) do
      {:ok, [_ | _] = addresses} -> {:ok, addresses}
      _ -> {:error, :nxdomain}
    end
  end
end
