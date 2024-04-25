# frozen_string_literal: true

module Types
  module IntegrationCustomers
    class Object < Types::BaseObject
      graphql_name 'IntegrationCustomer'

      field :external_customer_id, String, null: true
      field :id, ID, null: false
      field :subsidiary_id, String, null: true
      field :sync_with_provider, Boolean, null: true
    end
  end
end
