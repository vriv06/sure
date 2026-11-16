require "test_helper"

class RecurringTransaction::ChargePosterTest < ActiveSupport::TestCase
  ChargePoster = RecurringTransaction::ChargePoster

  def setup
    @family = families(:dylan_family)
    @card = accounts(:credit_card)
    @today = Date.new(2026, 11, 15)
    travel_to @today
  end

  test "posts the charge of an occurrence that has reached its date" do
    bill = card_bill(amount: 300, first_due_on: @today)

    assert_difference -> { @card.entries.count }, 1 do
      ChargePoster.new(bill).post_due!
    end

    occurrence = bill.recurring_occurrences.find_by!(due_on: @today)
    entry = occurrence.allocations.confirmed.sole.entry

    assert_equal "paid", occurrence.status
    assert_equal @today, entry.date
    assert_equal 300, entry.amount
    assert_equal "Turntable", entry.name
    assert_equal bill.category_id, entry.entryable.category_id
    assert_equal "standard", entry.entryable.kind
    assert_equal @card, entry.account
  end

  test "does not post an occurrence dated in the future" do
    bill = card_bill(amount: 300, first_due_on: @today + 1)

    assert_no_difference -> { @card.entries.count } do
      ChargePoster.new(bill).post_due!
    end

    assert bill.recurring_occurrences.all?(&:scheduled?)
  end

  test "posting twice creates one charge" do
    bill = card_bill(amount: 300, first_due_on: @today)

    ChargePoster.new(bill).post_due!

    assert_no_difference -> { @card.entries.count } do
      ChargePoster.new(bill).post_due!
    end
  end

  test "does nothing when the bill has not opted in" do
    bill = card_bill(amount: 300, first_due_on: @today, auto_charge: false)

    assert_no_difference -> { Entry.count } do
      ChargePoster.new(bill).post_due!
    end
  end

  test "does nothing when the account is not a credit card" do
    bill = card_bill(amount: 300, first_due_on: @today, account: accounts(:depository))

    assert_no_difference -> { Entry.count } do
      ChargePoster.new(bill).post_due!
    end
  end

  test "does nothing when the account is linked to a provider" do
    bill = card_bill(amount: 300, first_due_on: @today)
    Account.any_instance.stubs(:linked?).returns(true)

    assert_no_difference -> { Entry.count } do
      ChargePoster.new(bill).post_due!
    end
  end

  test "leaves an occurrence that already has a payment alone" do
    bill = card_bill(amount: 300, first_due_on: @today)
    occurrence = bill.recurring_occurrences.find_by!(due_on: @today)
    RecurringTransaction::Allocator.new(occurrence).allocate!(amount: 100, paid_on: @today)

    assert_no_difference -> { @card.entries.count } do
      ChargePoster.new(bill).post_due!
    end
  end

  test "a bill created with the flag on charges what is already due" do
    assert_difference -> { @card.entries.count }, 1 do
      card_bill(amount: 300, first_due_on: @today, on_create: true)
    end
  end

  test "turning the flag on charges what is already due" do
    bill = card_bill(amount: 300, first_due_on: @today, auto_charge: false)

    assert_difference -> { @card.entries.count }, 1 do
      bill.update!(auto_charge: true)
    end
  end

  test "the nightly job charges an occurrence whose date has arrived" do
    bill = card_bill(amount: 300, first_due_on: @today + 1)

    travel_to @today + 1 do
      assert_difference -> { @card.entries.count }, 1 do
        GenerateRecurringOccurrencesJob.perform_now(@family.id)
      end
    end

    assert_equal "paid", bill.recurring_occurrences.find_by!(due_on: @today + 1).status
  end

  test "the detection pipeline charges an occurrence whose date has arrived" do
    card_bill(amount: 300, first_due_on: @today + 1)

    travel_to @today + 1 do
      assert_difference -> { @card.entries.count }, 1 do
        RecurringTransaction::Pipeline.new(@family).run!
      end
    end
  end

  # A sync already running absorbs a second request without rereading the
  # ledger, so charges posted while it runs would be left out of the balance.
  test "charging several bills on one card asks for its sync once, after all of them" do
    first = card_bill(amount: 300, first_due_on: @today)
    second = card_bill(amount: 200, first_due_on: @today, name: "Speakers")

    Account.any_instance.expects(:sync_later).once

    assert_difference -> { @card.entries.count }, 2 do
      ChargePoster.post_all!([ first, second ])
    end
  end

  private
    # Declared with the flag off and opted in without callbacks, so each test
    # drives the poster itself. `on_create: true` declares it already opted in.
    def card_bill(amount:, first_due_on:, auto_charge: true, account: @card, on_create: false, name: "Turntable")
      bill = RecurringTransaction::DeclaredBill.new(
        family: @family,
        user: users(:family_admin),
        attrs: {
          name: name, amount: amount.to_s, account_id: account.id,
          category_id: categories(:food_and_drink).id,
          frequency_preset: "monthly", first_due_on: first_due_on.to_s,
          auto_charge: on_create ? "1" : "0"
        }
      ).build
      assert RecurringTransaction::DeclaredBill.save(bill), bill.errors.full_messages.to_sentence
      bill.update_columns(auto_charge: true) if auto_charge && !on_create
      bill
    end
end
