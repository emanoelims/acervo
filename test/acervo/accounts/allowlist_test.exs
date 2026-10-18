defmodule Acervo.Accounts.AllowlistTest do
  use ExUnit.Case, async: false

  alias Acervo.Accounts.Allowlist

  setup do
    previous = Application.get_env(:acervo, :allowed_emails)
    on_exit(fn -> Application.put_env(:acervo, :allowed_emails, previous) end)
  end

  test "parse/1 trims, downcases and drops blanks" do
    assert Allowlist.parse(" Me@Example.com, ,other@x.io ") == ["me@example.com", "other@x.io"]
    assert Allowlist.parse(nil) == []
  end

  test "allowed?/1 accepts anyone when configured as :all" do
    Application.put_env(:acervo, :allowed_emails, :all)
    assert Allowlist.allowed?("anyone@example.com")
  end

  test "allowed?/1 matches case-insensitively against the list" do
    Application.put_env(:acervo, :allowed_emails, ["me@example.com"])
    assert Allowlist.allowed?(" ME@example.com ")
    refute Allowlist.allowed?("other@example.com")
  end
end
