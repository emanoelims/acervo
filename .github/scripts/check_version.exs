Mix.start()
Code.compile_file("mix.exs")
version = Keyword.fetch!(Acervo.MixProject.project(), :version)
Version.parse!(version)

if System.get_env("GITHUB_REF_TYPE") == "tag" do
  tag = System.fetch_env!("GITHUB_REF_NAME")

  if tag != "v#{version}" do
    IO.puts(:stderr, "Tag #{tag} must match version v#{version} from mix.exs")
    System.halt(1)
  end
end

IO.puts("Valid version: #{version}")
