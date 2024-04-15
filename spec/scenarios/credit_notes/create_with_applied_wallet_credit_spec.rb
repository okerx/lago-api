# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Create Credit Note with Applied Wallet Credit', type: :request do
  let(:organization) { create(:organization, webhook_url: nil, email_settings: []) }
  let(:customer) { create(:customer, organization:) }

  let(:metric) { create(:sum_billable_metric, organization:) }
  let(:plan) { create(:plan, pay_in_advance: false, organization:, amount_cents: 0) }
  let(:charge) { create(:percentage_charge, plan:, billable_metric: metric, properties: { rate: '1.5' }) }

  let(:tax) { create(:tax, organization:, rate: 20.0) }
  let(:customer_tax) { create(:customer_applied_tax, customer:, tax:) }

  let(:pdf_generator) { instance_double(Utils::PdfGenerator) }
  let(:pdf_file) { StringIO.new(File.read(Rails.root.join('spec/fixtures/blank.pdf'))) }
  let(:pdf_result) { OpenStruct.new(io: pdf_file) }

  around { |test| lago_premium!(&test) }

  before do
    charge
    customer_tax

    allow(Utils::PdfGenerator).to receive(:new)
      .and_return(pdf_generator)
    allow(pdf_generator).to receive(:call)
      .and_return(pdf_result)
  end

  it 'behaves like the expected behavioers' do
    create_tax(name: 'Taxes', code: 'taxes', rate: 20.0)

    # Create a wallet for the customer
    create_wallet(
      {
        external_customer_id: customer.external_id,
        rate_amount: '1',
        name: 'wallet',
        currency: 'EUR',
        paid_credits: '4000',
        granted_credits: '4000',
      },
    )

    wallet = customer.wallets.first

    # Create a subscription
    travel_to(Time.zone.parse('2024-04-14T00:12:00')) do
      create_subscription(
        {
          external_customer_id: customer.external_id,
          external_id: customer.external_id,
          plan_code: plan.code,
          billing_time: 'anniversary',
        },
      )
    end

    subscription = customer.subscriptions.first

    # Send an event
    travel_to(Time.zone.parse('2024-04-14T00:13:00')) do
      create_event(
        {
          code: metric.code,
          transaction_id: SecureRandom.uuid,
          external_subscription_id: subscription.external_id,
          properties: { metric.field_name => '852580.50' },
        },
      )
    end

    # Terminate the subscription
    travel_to(Time.zone.parse('2024-04-14T00:13:30')) do
      terminate_subscription(subscription)
    end

    invoice = customer.invoices.order(created_at: :desc).first

    # Mark the invoice as paid
    travel_to(Time.zone.parse('2024-04-14T00:13:40')) do
      finalize_invoice(invoice)
      update_invoice(invoice, { payment_status: 'succeeded' })
    end

    expect(invoice.reload).to be_succeeded
    expect(invoice.fees_amount_cents).to eq(1_278_871)
    expect(invoice.coupons_amount_cents).to eq(0)
    expect(invoice.taxes_rate).to eq(20.0)
    expect(invoice.taxes_amount_cents).to eq(255_774)
    expect(invoice.total_amount_cents).to eq(1_134_645)
    expect(invoice.prepaid_credit_amount_cents).to eq(400_000)

    expect(invoice.fees.count).to eq(2)
    fee = invoice.fees.charge.first

    # Create a credit note
    travel_to(Time.zone.parse('2024-04-14T00:13:50')) do
      estimate_credit_note(
        invoice_id: invoice.id,
        items: [
          {
            fee_id: fee.id,
            amount_cents: fee.amount_cents,
          },
        ],
      )

      estimate = json[:estimated_credit_note]
      expect(estimate[:max_refundable_amount_cents]).to eq(1_134_645)
      expect(estimate[:max_creditable_amount_cents]).to eq(1_534_645)
      expect(estimate[:taxes_rate]).to eq(20)
      expect(estimate[:items].first[:amount_cents]).to eq(1_278_871)

      create_credit_note(
        invoice_id: invoice.id,
        reason: :other,
        credit_amount_cents: 0,
        refund_amount_cents: 1_134_644,
        items: [
          {
            fee_id: fee.id,
            amount_cents: 945_537,
          },
        ],
      )




      # TODO: check it's a success
    end
  end
end
