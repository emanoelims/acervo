defmodule Acervo.Library.FramePolicyTest do
  use ExUnit.Case, async: true

  alias Acervo.Library.FramePolicy

  @url "https://example.com/post"

  defp embeddable?(headers, url \\ @url), do: FramePolicy.embeddable?(url, headers)

  test "a page without framing headers is embeddable" do
    assert embeddable?(%{})
    assert embeddable?(%{"content-type" => ["text/html"]})
  end

  test "an http page is not, whatever its headers" do
    refute embeddable?(%{}, "http://example.com/post")
    refute embeddable?(%{}, "not a url")
  end

  describe "X-Frame-Options" do
    test "DENY and SAMEORIGIN refuse framing" do
      refute embeddable?(%{"x-frame-options" => ["DENY"]})
      refute embeddable?(%{"x-frame-options" => ["SAMEORIGIN"]})
    end

    test "names and values are case-insensitive" do
      refute embeddable?(%{"X-Frame-Options" => "deny"})
      refute embeddable?([{"X-FRAME-OPTIONS", " SameOrigin "}])
    end

    test "a repeated or comma-joined value refuses when any part does" do
      refute embeddable?(%{"x-frame-options" => ["ALLOWALL", "DENY"]})
      refute embeddable?(%{"x-frame-options" => ["sameorigin, sameorigin"]})
    end

    test "values browsers ignore don't refuse" do
      assert embeddable?(%{"x-frame-options" => ["ALLOW-FROM https://acervo.test"]})
      assert embeddable?(%{"x-frame-options" => ["ALLOWALL"]})
    end
  end

  describe "Content-Security-Policy frame-ancestors" do
    defp csp(policies), do: %{"content-security-policy" => List.wrap(policies)}

    test "'none' and 'self' refuse framing" do
      refute embeddable?(csp("frame-ancestors 'none'"))
      refute embeddable?(csp("default-src 'self'; frame-ancestors 'self';"))
    end

    test "* and https: allow it" do
      assert embeddable?(csp("frame-ancestors *"))
      assert embeddable?(csp("frame-ancestors https:"))
      assert embeddable?(csp("frame-ancestors 'self' https:"))
    end

    test "a host list refuses it" do
      refute embeddable?(csp("frame-ancestors 'self' https://partner.example https://*.example.org"))
    end

    test "an empty source list refuses it" do
      refute embeddable?(csp("script-src 'self'; frame-ancestors"))
    end

    test "a policy without frame-ancestors allows it" do
      assert embeddable?(csp("default-src 'self'; script-src 'self' https://cdn.example"))
    end

    test "every policy must allow it, in separate headers or comma-joined" do
      refute embeddable?(csp(["frame-ancestors *", "frame-ancestors 'none'"]))
      refute embeddable?(csp("frame-ancestors *, frame-ancestors 'self'"))
      assert embeddable?(csp(["default-src 'self'", "frame-ancestors https:"]))
    end

    test "only the first frame-ancestors of a policy counts" do
      assert embeddable?(csp("frame-ancestors *; frame-ancestors 'none'"))
    end

    test "directive names and sources are case-insensitive" do
      refute embeddable?(%{"Content-Security-Policy" => "FRAME-ANCESTORS 'NONE'"})
      assert embeddable?(%{"Content-Security-Policy" => "Frame-Ancestors HTTPS:"})
    end

    test "report-only policies are ignored" do
      assert embeddable?(%{"content-security-policy-report-only" => ["frame-ancestors 'none'"]})
    end
  end
end
