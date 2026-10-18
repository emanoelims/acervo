defmodule Acervo.Library.Resolver do
  @moduledoc """
  Resolves a host name to every address it points at.

  `Acervo.Library.SafeFetch` vets each address before connecting. The
  implementation comes from `config :acervo, :resolver`, so tests can swap DNS
  for a static table.
  """

  @callback resolve(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term()}

  @doc "Resolves `host` with the configured implementation."
  @spec resolve(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term()}
  def resolve(host) when is_binary(host), do: impl().resolve(host)

  defp impl, do: Application.get_env(:acervo, :resolver, Acervo.Library.Resolver.Inet)
end

defmodule Acervo.Library.Resolver.Inet do
  @moduledoc "Resolves through the system resolver, merging IPv4 and IPv6 answers (IPv4 first)."
  @behaviour Acervo.Library.Resolver

  @impl true
  def resolve(host) when is_binary(host) do
    host = String.to_charlist(host)

    case {:inet.getaddrs(host, :inet), :inet.getaddrs(host, :inet6)} do
      {{:error, reason}, {:error, _}} -> {:error, reason}
      {v4, v6} -> {:ok, Enum.uniq(addresses(v4) ++ addresses(v6))}
    end
  end

  defp addresses({:ok, addresses}), do: addresses
  defp addresses({:error, _}), do: []
end
