defmodule ExDoubleEntryStressTest do
  use ExDoubleEntry.DataCase, async: false
  import ExDoubleEntry
  import Ecto.Query
  alias ExDoubleEntry.{Line, MoneyProxy}

  @moduletag concurrent_db_pool: true

  @processes 5
  @account_pairs_per_process 10
  @transfers_per_account 100

  setup do
    initial_transfers_config = Application.fetch_env!(:ex_double_entry, :transfers)

    on_exit(fn ->
      Application.put_env(:ex_double_entry, :transfers, initial_transfers_config)
    end)
  end

  test "stress test" do
    accounts_config = Application.fetch_env!(:ex_double_entry, :accounts)
    transfers_config = Application.fetch_env!(:ex_double_entry, :transfers)

    {new_accounts_config, new_transfer_config} =
      Enum.reduce(
        1..@account_pairs_per_process,
        {accounts_config, transfers_config},
        fn n, {ac, tc} ->
          acc_a_identifier = :"acc-#{n}-a"
          acc_b_identifier = :"acc-#{n}-b"

          merged_accounts_config =
            Map.merge(ac, %{
              acc_a_identifier => [],
              acc_b_identifier => []
            })

          transfers_config_items = tc[:transfer] ++ [{acc_a_identifier, acc_b_identifier}]

          merged_transfers_config =
            Map.merge(tc, %{
              transfer: transfers_config_items
            })

          {merged_accounts_config, merged_transfers_config}
        end
      )

    Application.put_env(:ex_double_entry, :accounts, new_accounts_config)
    Application.put_env(:ex_double_entry, :transfers, new_transfer_config)

    tasks =
      for _ <- 1..@processes do
        Task.async(fn ->
          {amount_out, amount_in} =
            Enum.reduce(1..@account_pairs_per_process, {0, 0}, fn n, {aa, bb} ->
              acc_a_identifier = :"acc-#{n}-a"
              acc_b_identifier = :"acc-#{n}-b"

              scope = Enum.random([nil, "scope-#{n}"])

              acc_a =
                try do
                  make_account!(acc_a_identifier, scope: scope)
                rescue
                  _ -> lookup_account!(acc_a_identifier, scope: scope)
                end

              acc_b =
                try do
                  make_account!(acc_b_identifier, scope: scope)
                rescue
                  _ -> lookup_account!(acc_b_identifier, scope: scope)
                end

              {amount_aa, amount_bb} =
                Enum.reduce(
                  1..@transfers_per_account,
                  {Decimal.new(0), Decimal.new(0)},
                  fn _, {a, b} ->
                    amount = :rand.uniform(1_000_00)

                    {:ok, {amount_a, amount_b}} =
                      lock_accounts([acc_a, acc_b], fn [acc_a, acc_b] ->
                        {:ok, _} =
                          transfer!(
                            money: MoneyProxy.new(amount, :USD),
                            from: acc_a,
                            to: acc_b,
                            code: :transfer
                          )

                        amount_a = Decimal.new(-amount)
                        amount_b = Decimal.new(amount)

                        scope_cond = fn query, value ->
                          case value do
                            nil ->
                              query
                              |> where([q], is_nil(q.account_scope))
                              |> where([q], is_nil(q.partner_scope))

                            _ ->
                              query
                              |> where([q], q.account_scope == ^value)
                              |> where([q], q.partner_scope == ^value)
                          end
                        end

                        lines_a =
                          from(
                            l in Line,
                            where: l.account_identifier == ^acc_a_identifier,
                            where: l.partner_identifier == ^acc_b_identifier,
                            where: l.code == :transfer,
                            order_by: [desc: l.balance_amount]
                          )
                          |> scope_cond.(scope)
                          |> ExDoubleEntry.repo().all()

                        lines_b =
                          from(
                            l in Line,
                            where: l.account_identifier == ^acc_b_identifier,
                            where: l.partner_identifier == ^acc_a_identifier,
                            where: l.code == :transfer,
                            order_by: [asc: l.balance_amount]
                          )
                          |> scope_cond.(scope)
                          |> ExDoubleEntry.repo().all()

                        {lines_a_amount, lines_a_balance_amount} =
                          Enum.reduce(
                            lines_a,
                            {Decimal.new(0), Decimal.new(0)},
                            fn line, {amount, _ba} ->
                              {Decimal.add(amount, line.amount), line.balance_amount}
                            end
                          )

                        assert lines_a_amount == lines_a_balance_amount

                        {lines_b_amount, lines_b_balance_amount} =
                          Enum.reduce(
                            lines_b,
                            {Decimal.new(0), Decimal.new(0)},
                            fn line, {amount, _ba} ->
                              {Decimal.add(amount, line.amount), line.balance_amount}
                            end
                          )

                        assert lines_b_amount == lines_b_balance_amount

                        assert Decimal.add(
                                 lines_a_balance_amount,
                                 lines_b_balance_amount
                               ) == Decimal.new(0)

                        {Decimal.add(a, amount_a), Decimal.add(b, amount_b)}
                      end)

                    {amount_a, amount_b}
                  end
                )

              IO.write(".")

              {Decimal.add(aa, amount_aa), Decimal.add(bb, amount_bb)}
            end)

          assert Decimal.add(amount_out, amount_in) == Decimal.new(0)
        end)
      end

    Task.await_many(tasks, :infinity)

    assert Line |> ExDoubleEntry.repo().all() |> Enum.count() ==
             @processes * @account_pairs_per_process * @transfers_per_account * 2
  end
end
