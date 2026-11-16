class RecurringTransaction
  # Records the charge of each occurrence that has reached its date, for a
  # bill that opted in (`auto_charge`) on a manual credit card.
  #
  # A card bill is a charge, not a payment: it lands on the card on its date,
  # counts as spending that month, and is settled later by paying the card.
  # A linked card is skipped because its provider posts the charge itself, so
  # a second one would double the spend.
  #
  # Never writes a transaction dated in the future, and never touches an
  # occurrence that is closed or already carries a payment, so it is safe to
  # run as often as the occurrences are generated.
  class ChargePoster
    attr_reader :series

    def initialize(series)
      @series = series
    end

    def self.eligible?(series)
      series.auto_charge? && series.active? && series.amount.to_d.positive? &&
        series.destination_account_id.nil? && series.account.present? &&
        series.account.credit_card? && !series.account.linked?
    end

    # Posts every series' due charges, then asks each card for one sync. A
    # sync already running absorbs a second request without rereading the
    # ledger, so syncing per series would leave the later charges out of the
    # balance.
    def self.post_all!(all_series, as_of: Date.current)
      charged = all_series.select { |series| new(series).post_due!(as_of: as_of, sync: false).positive? }
      charged.map(&:account).uniq.each(&:sync_later)
      charged.size
    end

    # Returns the number of charges posted.
    def post_due!(as_of: Date.current, sync: true)
      return 0 unless self.class.eligible?(series)

      posted = due_occurrences(as_of).count { |occurrence| post!(occurrence) }
      series.account.sync_later if sync && posted.positive?
      posted
    end

    private
      def due_occurrences(as_of)
        series.recurring_occurrences
              .open_status
              .where(due_on: ..as_of)
              .where.not(id: RecurringAllocation.select(:recurring_occurrence_id))
              .order(:due_on)
      end

      def post!(occurrence)
        Entry.transaction do
          occurrence.lock!
          next false unless occurrence.scheduled? && occurrence.allocations.none?

          amount = occurrence.remaining_amount
          next false unless amount.positive?

          entry = series.account.entries.create!(
            date: occurrence.due_on,
            name: series.name.presence || series.merchant&.name,
            amount: amount,
            currency: occurrence.currency,
            entryable: Transaction.new(category_id: series.category_id, merchant_id: series.merchant_id)
          )

          Allocator.new(occurrence).allocate!(entry: entry, paid_on: entry.date, source: "auto_matched")
          true
        end
      end
  end
end
