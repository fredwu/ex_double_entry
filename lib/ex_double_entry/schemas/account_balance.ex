defmodule ExDoubleEntry.AccountBalance do
  require Logger

  use Ecto.Schema

  import Ecto.{Changeset, Query}

  alias ExDoubleEntry.{Account, AccountBalance, EctoType}

  @schema_prefix ExDoubleEntry.db_schema()
  schema "#{ExDoubleEntry.db_table_prefix()}account_balances" do
    field :identifier, EctoType.Identifier
    field :currency, EctoType.Currency
    field :scope, EctoType.Scope
    field :balance_amount, EctoType.Amount
    field :metadata, :map

    timestamps type: :utc_datetime_usec
  end

  defp changeset(params) do
    %AccountBalance{}
    |> cast(params, [:identifier, :currency, :scope, :balance_amount, :metadata])
    |> validate_required([:identifier, :currency, :balance_amount])
    |> unique_constraint(:identifier, name: :scope_currency_identifier_index)
  end

  def find(%Account{} = account) do
    for_account(account, lock: false)
  end

  def create!(%Account{
        identifier: identifier,
        currency: currency,
        scope: scope,
        metadata: metadata
      }) do
    %{
      identifier: identifier,
      currency: currency,
      scope: scope,
      balance_amount: 0,
      metadata: metadata
    }
    |> changeset()
    |> ExDoubleEntry.repo().insert!()
  end

  def for_account!(%Account{} = account) do
    for_account!(account, lock: false)
  end

  def for_account!(%Account{} = account, lock: lock) do
    for_account(account, lock: lock) || create!(account)
  end

  def for_account(nil), do: nil

  def for_account(%Account{} = account) do
    for_account(account, lock: false)
  end

  def for_account(
        %Account{identifier: identifier, currency: currency, scope: scope},
        lock: lock
      ) do
    from(
      ab in AccountBalance,
      where: ab.identifier == ^identifier,
      where: ab.currency == ^currency
    )
    |> scope_cond(scope)
    |> lock_cond(lock)
    |> ExDoubleEntry.repo().one()
    |> case do
      nil ->
        Logger.debug(fn ->
          "Account not found with identifier: #{identifier}, currency: #{currency} and scope: #{scope}."
        end)

        nil

      acc ->
        acc
    end
  end

  defp scope_cond(query, scope) do
    case scope do
      nil -> where(query, [ab], ab.scope == ^"")
      _ -> where(query, [ab], ab.scope == ^scope)
    end
  end

  if ExDoubleEntry.Repo.__adapter__() == Ecto.Adapters.Postgres do
    defp lock_cond(query, lock) do
      case lock do
        true -> lock(query, "FOR NO KEY UPDATE")
        false -> query
      end
    end
  else
    defp lock_cond(query, lock) do
      case lock do
        true -> lock(query, "FOR UPDATE")
        false -> query
      end
    end
  end

  def lock!(%Account{} = account) do
    for_account(account, lock: true)
  end

  def lock_multi!(accounts, fun) do
    ExDoubleEntry.repo().transaction(fn ->
      accounts
      |> Enum.sort()
      |> Enum.map(&lock!/1)
      |> then(fn locked_accounts ->
        accounts
        |> Enum.map(fn account -> Enum.find(locked_accounts, &compare_by_id(&1, account)) end)
        |> Enum.map(&Account.present/1)
        |> fun.()
      end)
    end)
  end

  @spec locked?(list(Account.t())) :: boolean()
  def locked?(accounts) when is_list(accounts) do
    Enum.any?(accounts, &locked?/1)
  end

  @spec locked?(Account.t()) :: boolean()
  def locked?(%Account{} = account) do
    subset =
      AccountBalance
      |> from()
      |> where([r], r.id == ^account.id)
      |> lock("FOR UPDATE SKIP LOCKED")
      |> select([r], r.id)

    AccountBalance
    |> from()
    |> where([r], r.id == ^account.id)
    |> where([r], r.id not in subquery(subset))
    |> ExDoubleEntry.repo().exists?()
  end

  def update_balance!(%Account{} = account, balance_amount) do
    account
    |> lock!()
    |> Ecto.Changeset.change(balance_amount: balance_amount)
    |> ExDoubleEntry.repo().update!()
  end

  defp compare_by_id(%{id: id}, %{id: id}), do: true
  defp compare_by_id(_acc1, _acc2), do: false
end
