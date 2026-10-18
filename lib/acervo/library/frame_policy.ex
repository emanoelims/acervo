defmodule Acervo.Library.FramePolicy do
  @moduledoc """
  Decides from a page's final URL and response headers whether Acervo may
  show it in a frame.

  A page is not embeddable when:

    * its final URL is not `https` (the app is, so the frame would be mixed
      content);
    * `X-Frame-Options` is `DENY` or `SAMEORIGIN`;
    * any enforced `Content-Security-Policy` has a `frame-ancestors`
      directive that allows neither `*` nor `https:`. A host list counts as
      a refusal, since Acervo can't count on being in it.

  Header names and values are compared case-insensitively. Report-only
  policies are ignored, as browsers do.
  """

  @type headers :: %{optional(String.t()) => String.t() | [String.t()]} | [{String.t(), String.t()}]

  @doc "Returns whether the page at `url`, answered with `headers`, may be framed."
  @spec embeddable?(String.t(), headers()) :: boolean()
  def embeddable?(url, headers) when is_binary(url) do
    headers = normalize(headers)
    https?(url) and frame_options_allow?(headers) and policies_allow?(headers)
  end

  defp https?(url), do: match?(%URI{scheme: "https", host: host} when is_binary(host) and host != "", URI.parse(url))

  defp frame_options_allow?(headers) do
    headers
    |> values("x-frame-options")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.all?(&(&1 not in ["deny", "sameorigin"]))
  end

  # Every header, and every comma-separated policy within one, is enforced on
  # its own, so each must allow framing.
  defp policies_allow?(headers) do
    headers
    |> values("content-security-policy")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.all?(&policy_allows?/1)
  end

  defp policy_allows?(policy) do
    policy
    |> String.split(";")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase() |> String.split()))
    |> Enum.find(&match?(["frame-ancestors" | _sources], &1))
    |> case do
      ["frame-ancestors" | sources] -> "*" in sources or "https:" in sources
      nil -> true
    end
  end

  defp values(headers, name), do: Enum.flat_map(headers, fn {key, value} -> if key == name, do: value, else: [] end)

  defp normalize(headers) do
    Enum.map(headers, fn {key, value} -> {String.downcase(to_string(key)), List.wrap(value)} end)
  end
end
