require "test_helper"

class Account::InstallmentDebtTest < ActiveSupport::TestCase
  def setup
    @family = families(:dylan_family)
    @card = accounts(:credit_card)
    @today = Date.new(2026, 11, 15)
    travel_to @today
  end

  test "a card with no auto-charge installment plan has nothing outstanding" do
    assert_equal 0, @card.installments_outstanding
    assert_equal @card.balance, @card.total_balance
  end

  test "the uncharged payments of an auto-charge installment plan are outstanding" do
    installment_plan(amount: 100, payments: 3, first_due_on: @today + 1)

    assert_equal 300, @card.installments_outstanding
    assert_equal @card.balance + 300, @card.total_balance
    assert_equal Money.new(@card.balance + 300, "USD"), @card.total_balance_money
  end

  test "a payment that was charged is no longer outstanding" do
    installment_plan(amount: 100, payments: 3, first_due_on: @today)

    assert_equal 200, @card.installments_outstanding
  end

  test "a plan that does not auto-charge is not counted" do
    installment_plan(amount: 100, payments: 3, first_due_on: @today + 1, auto_charge: false)

    assert_equal 0, @card.installments_outstanding
  end

  test "an auto-charge bill with no end is not counted" do
    installment_plan(amount: 100, payments: nil, first_due_on: @today + 1)

    assert_equal 0, @card.installments_outstanding
  end

  test "a paused plan is not counted" do
    plan = installment_plan(amount: 100, payments: 3, first_due_on: @today + 1)
    plan.update!(status: "paused")

    assert_equal 0, @card.installments_outstanding
  end

  test "an account that is not a credit card has nothing outstanding" do
    installment_plan(amount: 100, payments: 3, first_due_on: @today + 1, account: accounts(:depository))

    assert_equal 0, accounts(:depository).installments_outstanding
  end

  test "the balance sheet counts outstanding installments as debt" do
    before = BalanceSheet.new(@family)
    liabilities, net_worth = before.liabilities.total, before.net_worth

    installment_plan(amount: 100, payments: 3, first_due_on: @today + 1)
    after = BalanceSheet.new(@family)

    assert_equal liabilities + 300, after.liabilities.total
    assert_equal net_worth - 300, after.net_worth
  end

  private
    def installment_plan(amount:, payments:, first_due_on:, auto_charge: true, account: @card)
      bill = RecurringTransaction::DeclaredBill.new(
        family: @family,
        user: users(:family_admin),
        attrs: {
          name: "Turntable", amount: amount.to_s, account_id: account.id,
          frequency_preset: "monthly", first_due_on: first_due_on.to_s,
          auto_charge: auto_charge ? "1" : "0"
        }
      ).build
      if payments
        bill.bill_type = "installment"
        bill.end_mode = "after_count"
        bill.end_after_count = payments
      end
      assert RecurringTransaction::DeclaredBill.save(bill), bill.errors.full_messages.to_sentence
      bill
    end
end
