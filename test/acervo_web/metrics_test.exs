defmodule AcervoWeb.MetricsTest do
  use Acervo.DataCase, async: true

  import Acervo.AccountsFixtures
  import Acervo.LibraryFixtures

  alias Acervo.Library.Link
  alias AcervoWeb.Metrics

  describe "metrics/0" do
    # Labels must never carry user data (ids, queries, URLs, titles, error
    # messages): only tags from this bounded allowlist.
    test "uses only allowlisted tags" do
      allowed = ~w(operation model status queue worker state route partial cached scoped)a
      assert Enum.sort(Metrics.allowed_tags()) == Enum.sort(allowed)

      for metric <- Metrics.metrics(), tag <- metric.tags do
        assert tag in allowed, "#{Enum.join(metric.name, ".")} uses the tag #{inspect(tag)}, outside the allowlist"
      end
    end

    test "uses only types the Prometheus reporter supports" do
      for metric <- Metrics.metrics() do
        refute match?(%Telemetry.Metrics.Summary{}, metric), "#{Enum.join(metric.name, ".")} is a summary"
      end
    end
  end

  describe "the metrics server" do
    setup do
      reporter = :"metrics_test_#{System.unique_integer([:positive])}"
      pid = start_supervised!({Metrics, reporter: reporter, supervisor: :"#{reporter}_sup", port: 0, pollers: false})

      {:server, bandit, _type, _modules} = pid |> Supervisor.which_children() |> List.keyfind(:server, 0)
      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

      %{url: "http://127.0.0.1:#{port}"}
    end

    test "serves the app's metrics at /metrics", %{url: url} do
      two_seconds = System.convert_time_unit(2, :second, :native)

      :telemetry.execute(
        [:acervo, :ai, :call, :stop],
        %{duration: two_seconds, input_tokens: 10, output_tokens: 5, cost_usd: 0.0064},
        %{operation: "enrich_link", model: "metrics-test", status: :ok}
      )

      :telemetry.execute(
        [:acervo, :search, :stop],
        %{duration: System.convert_time_unit(80, :millisecond, :native), results: 3},
        %{partial: false, cached: true, scoped: false}
      )

      :telemetry.execute([:oban, :job, :stop], %{duration: 1_000, queue_time: 1_000}, %{
        queue: "ai",
        worker: "Acervo.AI.EnrichLink",
        state: :success
      })

      :telemetry.execute([:acervo, :oban, :queue], %{depth: 4}, %{queue: "metrics-test", state: "available"})
      :telemetry.execute([:acervo, :links, :status], %{count: 7}, %{status: "metrics-test"})

      response = Req.get!(url <> "/metrics", retry: false)

      assert response.status == 200
      assert ["text/plain; version=0.0.4"] = response.headers["content-type"]
      body = response.body

      assert body =~ ~s(acervo_ai_calls_total{model="metrics-test",operation="enrich_link",status="ok"})
      assert body =~ ~s(acervo_ai_cost_nanousd_total{model="metrics-test",operation="enrich_link"} 6400000)
      assert body =~ ~s(acervo_ai_input_tokens_total{model="metrics-test",operation="enrich_link"})
      assert body =~ "acervo_ai_call_duration_seconds_bucket"
      assert body =~ ~s(acervo_search_total{cached="true",partial="false",scoped="false"})
      assert body =~ "acervo_search_duration_seconds_bucket"
      assert body =~ "acervo_search_results_total"
      assert body =~ ~s(oban_job_stop_count{queue="ai",state="success",worker="Acervo.AI.EnrichLink"})
      assert body =~ ~s(acervo_oban_queue_depth{queue="metrics-test",state="available"} 4)
      assert body =~ ~s(acervo_links_status_count{status="metrics-test"} 7)
    end

    test "answers 404 elsewhere", %{url: url} do
      assert Req.get!(url <> "/", retry: false).status == 404
      assert Req.get!(url <> "/health", retry: false).status == 404
    end
  end

  describe "pollers" do
    setup do
      %{scope: user_scope_fixture()}
    end

    test "count links by status, enrichment and embedding", %{scope: scope} do
      before = Acervo.Metrics.link_totals()
      ready = link_fixture(scope)
      _pending = link_fixture(scope)
      Repo.update_all(from(l in Link, where: l.id == ^ready.id), set: [status: :ready, embedding_status: :ready])

      totals = Acervo.Metrics.link_totals()

      assert totals.status["ready"] == (before.status["ready"] || 0) + 1
      assert totals.status["pending"] == (before.status["pending"] || 0) + 1
      assert totals.embedding_status["ready"] == (before.embedding_status["ready"] || 0) + 1
      assert totals.enrichment_status["none"] == (before.enrichment_status["none"] || 0) + 2
    end

    test "emit a gauge for every status, zeros included", %{scope: scope} do
      Acervo.TelemetryHelpers.attach_own([[:acervo, :links, :status], [:acervo, :links, :embedding]])
      link_fixture(scope)

      assert Acervo.Metrics.dispatch_link_totals() == :ok

      assert_received {[:acervo, :links, :status], %{count: pending}, %{status: "pending"}}
      assert pending >= 1
      assert_received {[:acervo, :links, :status], %{count: _failed}, %{status: "failed"}}
      assert_received {[:acervo, :links, :embedding], %{count: _none}, %{status: "none"}}
    end

    test "count queued jobs by queue and state", %{scope: scope} do
      before = Acervo.Metrics.queue_depth()
      Acervo.TelemetryHelpers.attach_own([[:acervo, :oban, :queue]])

      # Saving a link enqueues its capture job.
      link_fixture(scope)

      assert Acervo.Metrics.queue_depth()[{"capture", "available"}] ==
               (before[{"capture", "available"}] || 0) + 1

      assert Acervo.Metrics.dispatch_queue_depth() == :ok
      assert_received {[:acervo, :oban, :queue], %{depth: depth}, %{queue: "capture", state: "available"}}
      assert depth >= 1
      assert_received {[:acervo, :oban, :queue], %{depth: _depth}, %{queue: "ai", state: "retryable"}}
    end
  end
end
