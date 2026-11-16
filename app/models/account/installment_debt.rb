# Debt a credit card already carries but that has not been charged yet: the
# open occurrences of its auto-charge installment plans (see
# RecurringTransaction::ChargePoster).
#
# Read-side only. The stored balance, the balance history and the sync engine
# never see it: each charge moves its amount from here into the real balance
# on the day it posts, so the two always add up to what is owed.
module Account::InstallmentDebt
  extend ActiveSupport::Concern

  included do
    monetize :installments_outstanding, :total_balance
  end

  def installments_outstanding
    return BigDecimal(0) unless credit_card?

    @installments_outstanding ||= begin
      occurrences = RecurringOccurrence
                      .open_status
                      .joins(:recurring_transaction)
                      .where(recurring_transactions: {
                               account_id: id, status: "active", auto_charge: true,
                               bill_type: "installment", end_mode: "after_count", currency: currency
                             })
                      .includes(:recurring_transaction)
                      .to_a

      paid = RecurringAllocation.confirmed
                                .where(recurring_occurrence_id: occurrences.map(&:id))
                                .group(:recurring_occurrence_id)
                                .sum(:allocated_amount)
      occurrences.each { |occurrence| occurrence.cached_confirmed_allocated = paid.fetch(occurrence.id, 0) }

      occurrences.sum(BigDecimal(0), &:remaining_amount)
    end
  end

  def reload(*)
    @installments_outstanding = nil
    super
  end

  # What the account owes or holds, counting installments still to be charged.
  def total_balance
    balance + installments_outstanding
  end
end
