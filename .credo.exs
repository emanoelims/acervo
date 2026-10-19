# Credo's default configuration, with `dev/` (development-only pages such as
# the styleguide) analyzed alongside `lib/` and `test/`.
%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/", "dev/"],
        excluded: [~r"/_build/", ~r"/deps/", ~r"/node_modules/"]
      }
    }
  ]
}
