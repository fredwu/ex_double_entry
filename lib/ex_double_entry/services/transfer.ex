defmodule ExDoubleEntry.Transfer do
  require Logger

  @type t() :: %__MODULE__{}
  @type result() :: {:ok, %__MODULE__{}} | {:error, atom(), String.t()}

  @enforce_keys [:money, :from, :to, :code]
  defstruct [:money, :from, :to, :code, :metadata, :idempotence]

  alias ExDoubleEntry.{Account, AccountBalance, Guard, Line, MoneyProxy, Transfer}

  def perform!(%Transfer{} = transfer) do
    perform!(transfer, ensure_accounts: true)
  end

  def perform!(transfer_attrs) do
    perform!(transfer_attrs, ensure_accounts: true)
  end

  def perform!(%Transfer{} = transfer, ensure_accounts: ensure_accounts) do
    with {:ok, _} <- Guard.positive_amount?(transfer),
         {:ok, _} <- Guard.valid_definition?(transfer),
         {:ok, _} <- Guard.matching_currency?(transfer),
         {:ok, _} <- Guard.positive_balance_if_enforced?(transfer),
         {:ok, _} <- Guard.idempotent_if_provided?(transfer) do
      perform(transfer, ensure_accounts: ensure_accounts)
    end
  end

  def perform!(transfer_attrs, ensure_accounts: ensure_accounts) do
    Transfer |> struct(transfer_attrs) |> perform!(ensure_accounts: ensure_accounts)
  end

  def perform(%Transfer{} = transfer) do
    perform(transfer, ensure_accounts: true)
  end

  def perform(
        %Transfer{
          money: money,
          from: from,
          to: to,
          code: code,
          metadata: metadata,
          idempotence: idempotence
        } = transfer,
        ensure_accounts: ensure_accounts
      ) do
    Logger.debug("Attempting transfer: #{inspect(transfer)}")

    {from, to} = ensure_accounts_if_needed(ensure_accounts, from, to)

    AccountBalance.lock_multi!([from, to], fn [from, to] ->
      line1 =
        Line.insert!(MoneyProxy.neg(money),
          account: from,
          partner: to,
          code: code,
          metadata: metadata,
          idempotence: idempotence
        )

      line2 =
        Line.insert!(money,
          account: to,
          partner: from,
          code: code,
          metadata: metadata,
          idempotence: idempotence
        )

      Line.update_partner_line_id!(line1, line2.id)
      Line.update_partner_line_id!(line2, line1.id)

      from_amount = MoneyProxy.subtract(from.balance, money).amount
      to_amount = MoneyProxy.add(to.balance, money).amount

      AccountBalance.update_balance!(from, from_amount)
      AccountBalance.update_balance!(to, to_amount)

      Logger.debug("Completed transfer: #{inspect(transfer)}")

      transfer
    end)
  end

  defp ensure_accounts_if_needed(true, acc_a, acc_b) do
    {
      acc_a |> AccountBalance.for_account!() |> Account.present(),
      acc_b |> AccountBalance.for_account!() |> Account.present()
    }
  end

  defp ensure_accounts_if_needed(_, acc_a, acc_b) do
    cond do
      is_nil(AccountBalance.for_account(acc_a)) ->
        raise Account.NotFoundError

      is_nil(AccountBalance.for_account(acc_b)) ->
        raise Account.NotFoundError

      true ->
        {acc_a, acc_b}
    end
  end
end
