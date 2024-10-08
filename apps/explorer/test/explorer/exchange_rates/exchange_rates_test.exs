defmodule Explorer.ExchangeRatesTest do
  use Explorer.DataCase

  import Mox

  alias Plug.Conn
  alias Explorer.ExchangeRates
  alias Explorer.ExchangeRates.Token
  alias Explorer.ExchangeRates.Source.TestSource
  alias Explorer.Market.MarketHistoryCache

  @moduletag :capture_log

  setup :verify_on_exit!

  setup do
    Supervisor.terminate_child(Explorer.Supervisor, {ConCache, MarketHistoryCache.cache_name()})
    Supervisor.restart_child(Explorer.Supervisor, {ConCache, MarketHistoryCache.cache_name()})

    # Use TestSource mock and ets table for this test set
    source_configuration = Application.get_env(:explorer, Explorer.ExchangeRates.Source)
    rates_configuration = Application.get_env(:explorer, Explorer.ExchangeRates)

    Application.put_env(:explorer, Explorer.ExchangeRates.Source, source: TestSource)
    Application.put_env(:explorer, Explorer.ExchangeRates, table_name: :rates)
    Application.put_env(:explorer, Explorer.ExchangeRates, enabled: true)

    on_exit(fn ->
      Application.put_env(:explorer, Explorer.ExchangeRates.Source, source_configuration)
      Application.put_env(:explorer, Explorer.ExchangeRates, rates_configuration)
      Supervisor.terminate_child(Explorer.Supervisor, Explorer.Chain.Cache.Blocks.child_id())
      Supervisor.restart_child(Explorer.Supervisor, Explorer.Chain.Cache.Blocks.child_id())
    end)
  end

  test "init" do
    assert :ets.info(ExchangeRates.table_name()) == :undefined

    assert {:ok, %{}} == ExchangeRates.init([])
    assert_received :update
    table = :ets.info(ExchangeRates.table_name())
    refute table == :undefined
    assert table[:name] == ExchangeRates.table_name()
    assert table[:named_table]
    assert table[:read_concurrency]
    assert table[:type] == :set
    assert table[:write_concurrency]
  end

  test "handle_info with :update" do
    bypass = Bypass.open()

    Bypass.expect(bypass, "GET", "/", fn conn ->
      Conn.resp(conn, 200, "{}")
    end)

    stub(TestSource, :source_url, fn -> "http://localhost:#{bypass.port}" end)

    ExchangeRates.init([])
    state = %{}

    expect(TestSource, :format_data, fn _ -> [Token.null()] end)
    expect(TestSource, :headers, fn -> [] end)
    set_mox_global()

    assert {:noreply, ^state} = ExchangeRates.handle_info(:update, state)
    assert_receive {_, {:ok, false, [%Token{}]}}
  end

  describe "ticker fetch task" do
    setup do
      ExchangeRates.init([])
      :ok
    end

    test "with successful fetch" do
      expected_token = %Token{
        available_supply: Decimal.new("1000000.0"),
        total_supply: Decimal.new("1000000.0"),
        btc_value: Decimal.new("1.000"),
        id: "test_id",
        last_updated: DateTime.utc_now(),
        market_cap_usd: Decimal.new("1000000.0"),
        tvl_usd: Decimal.new("2000000.0"),
        name: "test_name",
        symbol: "test_symbol",
        usd_value: Decimal.new("1.0"),
        volume_24h_usd: Decimal.new("1000.0"),
        image_url: nil
      }

      state = %{}

      assert {:noreply, ^state} = ExchangeRates.handle_info({nil, {:ok, false, [expected_token]}}, state)

      assert [false: ^expected_token] = :ets.lookup(ExchangeRates.table_name(), false)
    end

    test "with failed fetch" do
      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/", fn conn ->
        Conn.resp(conn, 200, "{}")
      end)

      stub(TestSource, :source_url, fn -> "http://localhost:#{bypass.port}" end)

      state = %{}

      expect(TestSource, :format_data, fn _ -> [Token.null()] end)
      expect(TestSource, :headers, fn -> [] end)
      set_mox_global()

      assert {:noreply, ^state} = ExchangeRates.handle_info({nil, {:error, false, "some error"}}, state)

      assert_receive :update

      assert {:noreply, ^state} = ExchangeRates.handle_info(:update, state)
      assert_receive {_, {:ok, false, [%Token{}]}}
    end
  end

  test "list/0" do
    ExchangeRates.init([])

    rate_a = %Token{Token.null() | symbol: "a"}
    rate_z = %Token{Token.null() | symbol: "z"}

    rates = [
      rate_z,
      rate_a
    ]

    expected_rates = Enum.reverse(rates)

    :ets.insert(ExchangeRates.table_name(), {false, rate_z})
    :ets.insert(ExchangeRates.table_name(), {true, rate_a})

    assert expected_rates == ExchangeRates.list()
  end

  test "lookup/1" do
    ExchangeRates.init([])

    z = %Token{Token.null() | symbol: "z"}

    rates = [z, %Token{Token.null() | symbol: "a"}]

    for rate <- rates, do: :ets.insert(ExchangeRates.table_name(), Token.to_tuple(rate))

    assert z == ExchangeRates.lookup("z")
    assert nil == ExchangeRates.lookup("nope")
  end

  test "lookup when disabled" do
    Application.put_env(:explorer, Explorer.ExchangeRates, enabled: false)

    assert nil == ExchangeRates.lookup("z")
  end
end
