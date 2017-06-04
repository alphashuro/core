require 'paypal-sdk-rest'

module Api::V2::CashOutsHelper

  include Api::V2::BaseHelper
  include PayPal::SDK::REST

  def filter!(collection)
    # Filter by cash outs that have been sent
    if params.has_key? :sent
      if params[:sent].to_bool
        # Only show sent
        collection = collection.where('cash_outs.sent_at IS NOT NULL')
      else
        # Only show pending
        collection = collection.where('cash_outs.sent_at IS NULL')
      end
    end

    collection
  end

  def order!(collection)
    return collection unless params[:order]

    _collection = collection

    direction = _direction_for_order_value(params[:order])
    order_value = _strip_order_value(params[:order])

    case order_value
    when 'sent'
      _collection = _collection.reorder("sent_at #{direction}")

    when 'created'
      _collection = _collection.reorder("created_at #{direction}")
    end

    _collection
  end

  def send_paypal!()
    # select cash outs that have been approved but not sent yet
    collection = ::CashOut::Paypal
      .where('cash_outs.approved_at IS NOT NULL')
      .where('cash_outs.sent_at IS NULL')
      .where('cash_outs.batch_id IS NULL')

    # # Paypal only allows making 500 payouts per request
    # # so we need to iterate through the collection 500 at a time
    collection.find_in_batches(batch_size: 500) do |batch|
      send_paypal_batch(batch)
    end
  end

  def send_paypal_batch(cashouts)
    # map them to the structure that paypal expects
    payouts = cashouts.map do |cashout|
      {
        :recipient_type => 'EMAIL',
        :amount => {
          :value => cashout.amount,
          :currency => 'USD'
        },
        :note => "Your cash out has been processed. Ref: #{cashout.id}",
        :receiver => cashout.paypal_address,
        :sender_item_id => cashout.id,
      }
    end

    batch_id = SecureRandom.hex(8)

    batch = Payout.new(
      {
        :sender_batch_header => {
          :sender_batch_id => batch_id,
          :email_subject => "Sending Batch Payment #{batch_id}",
        },
        :items => payouts
      }
    )

    begin
      payout_batch = batch.create
      batch_id = payout_batch.batch_header.payout_batch_id

      logger.info "Created Payout: #{batch_id}"

      # update the batch_id for this batch's cash outs
      cashout_ids = cashouts.collect &:id
      CashOut::Paypal
        .where(id: cashout_ids)
        .update_all(batch_id: batch_id)

      return payout_batch
    rescue ResourceNotFound => err
      logger.error payout.error.inspect
    end
  end

  def check_paypal_batch_status()
    # select items that have been batched but not paid out yet
    batch_ids = CashOut::Paypal
      .where('cash_outs.batch_id IS NOT NULL')
      .where('cash_outs.sent_at IS NULL')
      .uniq
      .pluck(:batch_id)

    batch_ids.each do |batch_id|
      payout_batch = Payout.get batch_id

      items = payout_batch.items.map { |item| item.payout_item.sender_item_id }

      case payout_batch.batch_header.batch_status
      when 'SUCCESS'
        CashOut::Paypal
          .where(id: items)
          .update_all sent_at: DateTime.now
      when 'DENIED'
        CashOut::Paypal
          .where(id: items)
          .update_all batch_id: nil
      end
    end
  end

end
