# Acervo

To start your Phoenix server:

* Run `mise install` to install Elixir/Erlang
* Run `mise run db:create` once (then `mise run db`) to start Postgres 18 with pgvector in an Apple container on port 5432
* Copy `mise.local.toml.example` to `mise.local.toml` and fill in your secrets (e.g. `ANTHROPIC_API_KEY`)
* Run `mise run setup` to install and setup dependencies
* Start Phoenix endpoint with `mise run dev` or inside IEx with `mise exec -- iex -S mix phx.server`

Run `mise run precommit` before submitting changes. See [CONTRIBUTING.md](CONTRIBUTING.md)
for commit, changelog, and release conventions, and [CHANGELOG.md](CHANGELOG.md) for changes.

Now you can visit [`localhost:4200`](http://localhost:4200) from your browser.

Ready to run in production? Please see the [deployment guide](guides/deployment.md).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix

## License

[MIT](LICENSE)
