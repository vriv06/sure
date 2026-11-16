# Opt-in per bill: on a manual credit card, Sure records each occurrence's
# charge as a transaction when its date arrives (see
# RecurringTransaction::ChargePoster).
class AddAutoChargeToRecurringTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :recurring_transactions, :auto_charge, :boolean, default: false, null: false
  end
end
