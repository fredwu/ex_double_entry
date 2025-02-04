defmodule ExDoubleEntry do
  @db_schema Application.compile_env(:ex_double_entry, :db_schema)
  @db_table_prefix Application.compile_env(:ex_double_entry, :db_table_prefix)
  @repo Application.compile_env(:ex_double_entry, :repo)

  @dialyzer {:nowarn_function, {:db_schema, 0}}

  def db_schema do
    if ExDoubleEntry.Repo.__adapter__() == Ecto.Adapters.Postgres do
      @db_schema
    else
      nil
    end
  end

  def db_table_prefix, do: @db_table_prefix
  def repo, do: @repo

  @doc """
  ## Examples

  iex> ExDoubleEntry.make_account!(:savings).__struct__
  ExDoubleEntry.Account
  """
  defdelegate make_account!(identifier, opts \\ []), to: ExDoubleEntry.Account, as: :make!

  @doc """
  ## Examples

  iex> ExDoubleEntry.lookup_account!(:savings, currency: :USD)
  nil
  """
  defdelegate lookup_account!(identifier, opts \\ []), to: ExDoubleEntry.Account, as: :lookup!

  @doc """
  ## Examples

  iex>ExDoubleEntry.make_account!(:savings) |> ExDoubleEntry.account_locked?()
  false
  """
  defdelegate account_locked?(account), to: ExDoubleEntry.AccountBalance, as: :locked?

  @doc """
  ## Examples

  iex> [ExDoubleEntry.make_account!(:savings)] |> ExDoubleEntry.lock_accounts(fn [_acc] -> true end)
  {:ok, true}
  """
  defdelegate lock_accounts(accounts, fun), to: ExDoubleEntry.AccountBalance, as: :lock_multi!

  @doc """
  ## Examples

  iex> %ExDoubleEntry.Transfer{
  iex>   money: MoneyProxy.new(42, :USD),
  iex>   from: %ExDoubleEntry.Account{identifier: :checking, currency: :USD, balance: MoneyProxy.new(42, :USD), positive_only?: false},
  iex>   to: %ExDoubleEntry.Account{identifier: :savings, currency: :USD, balance: MoneyProxy.new(0, :USD)},
  iex>   code: :deposit
  iex> }
  iex> |> ExDoubleEntry.transfer!()
  iex> |> Tuple.to_list()
  iex> |> List.first()
  :ok
  """
  defdelegate transfer!(transfer), to: ExDoubleEntry.Transfer, as: :perform!

  def transfer(transfer) do
    ExDoubleEntry.Transfer.perform!(transfer, ensure_accounts: false)
  end

  defdelegate reverse(transfer), to: ExDoubleEntry.Reversal, as: :perform!
end
