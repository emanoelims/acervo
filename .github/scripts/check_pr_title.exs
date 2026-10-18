title = System.fetch_env!("PR_TITLE")

pattern =
  ~r/\A(?:feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(?:\([a-z0-9][a-z0-9._\/-]*\))?!?: \S[^\r\n]*\z/u

if !Regex.match?(pattern, title) do
  IO.puts(
    :stderr,
    "Invalid title. Use Conventional Commits, for example: feat(catalog): add search"
  )

  System.halt(1)
end
