defmodule Acervo.FailingMailAdapter do
  @moduledoc "Swoosh adapter whose deliveries always fail; swap it in with `Application.put_env/3`."
  use Swoosh.Adapter

  @impl true
  def deliver(_email, _config), do: {:error, :smtp_down}
end
