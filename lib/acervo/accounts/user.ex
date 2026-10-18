defmodule Acervo.Accounts.User do
  @moduledoc false
  use Acervo.Schema
  use Gettext, backend: AcervoWeb.Gettext

  import Ecto.Changeset

  alias Acervo.Accounts.Allowlist

  schema "users" do
    field :email, :string
    field :confirmed_at, :utc_datetime
    field :authenticated_at, :utc_datetime, virtual: true

    timestamps()
  end

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
    * `:validate_allowlist` - Set to true on registration to only accept emails
      in the configured allowlist. Defaults to `false`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: dgettext_noop("errors", "must have the @ sign and no spaces")
      )
      |> validate_length(:email, max: 160)
      |> maybe_validate_allowlist(opts)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Acervo.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp maybe_validate_allowlist(changeset, opts) do
    if Keyword.get(opts, :validate_allowlist, false) do
      validate_change(changeset, :email, &allowlist_errors/2)
    else
      changeset
    end
  end

  defp allowlist_errors(:email, email) do
    if Allowlist.allowed?(email), do: [], else: [email: dgettext_noop("errors", "is not allowed to register")]
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, dgettext_noop("errors", "did not change"))
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end
end
