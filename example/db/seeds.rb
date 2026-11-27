# frozen_string_literal: true

[ [ "Mechanical keyboard", 12_900 ], [ "USB-C dock", 8_900 ] ].each do |name, price_cents|
  Product.find_or_create_by!(name:) { |product| product.assign_attributes(stock: 20, price_cents:) }
end
