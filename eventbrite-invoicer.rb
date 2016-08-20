require 'mail'
require 'ostruct'
require 'pp'
require 'iso_country_codes'
require 'active_model'
require 'active_importer'
require 'payday'
require 'set'
require 'erb'


# Read  files
options = {
  :settings => 'settings.yml',
  :mail => nil
}

optparse = OptionParser.new do |opts|
  opts.on('-h','--help','Display this screen') do
    puts opts
    exit
  end
  opts.on('-f','--file FILENAME', 'Path to the Eventbrite CSV report.') do |f|
    options[:file] = f
  end
  opts.on('-s','--settings FILENAME', 'Path to settings yamlfile. Default: settings.yml') do |f|
    options[:settings] = f
  end
  opts.on('-m','--mail OPTION', 'Option to mail. Default: none. Other options: "test"|"attendee"') do |m|
    options[:settings] = m if m == 'test'
    options[:settings] = m if m == 'attendee'
  end
end

optparse.parse!

settings={}
# Loading setting
begin
  settings = YAML.load_file(options[:settings])
rescue Exception => e
  puts "Error #{e}"
  puts optparse
  exit -1
end

I18n.default_locale = settings[:invoice][:locale]

Payday::Config.default.invoice_logo = settings[:invoice][:config][:invoice_logo]
Payday::Config.default.company_name = settings[:invoice][:config][:company_name]
Payday::Config.default.company_details = settings[:invoice][:config][:company_details]
Payday::Config.default.date_format = settings[:invoice][:config][:date_format]
Payday::Config.default.currency = settings[:invoice][:config][:currency]
Payday::Config.default.page_size = settings[:invoice][:config][:page_size]

# Initalize the setting
country = settings[:invoice][:country]

# First invoice_nr from settings
invoice_nr = settings[:invoice][:start]

class Order
  include ActiveModel::Model

  attr_accessor :nr, :date, :company, :address_line_1, :address_line_2, :city, :postcode, :country, :tax_id,
                :first_name, :last_name, :email
  attr_reader :attendees

  validates :nr, presence: true
  validates :date, presence: true
  validates :email, presence: true

  def initialize
    @attendees = []
  end

  def add_attendee(attendee)
    @attendees << attendee
  end

  def total
    @attendees.reduce(0) { | interim_total, attendee | interim_total += attendee.total }
  end

  def tax
    @attendees.reduce(0) { | interim_tax, attendee | interim_tax += attendee.tax }
  end

  def bill_to
    bill = Array.new
    bill << "#{@first_name} #{@last_name}"
    bill << "#{@email}"

    [ @company, @address_line_1, @address_line_2].each do |b|
      bill << b
    end
    bill << "#{@postcode} #{@city}"
    unless @country.nil?
      bill << "#{IsoCountryCodes.find(@country).name}"
    end
    bill << "#{@tax_id}"

    bill.reject! { |i| i == nil }
    return bill.join("\n")
  end

  def safe_name
    name = ''
    unless @company.nil?
      name = @company.downcase.gsub(/[^A-Za-z\ ]/,'').gsub(/[\ -]/,'_')
    else
      name = "#{first_name} #{last_name}"
    end
    name.downcase.gsub(/[^A-Za-z\ ]/,'').gsub(/[\ -]/,'_')
  end

  def nr_of_attendees
    @attendees.length
  end

  def to_s
    "Order %s, %s, %-25s, %-35s, %-15s, %-20s, %-12s, %s, %s, %s" % [@nr, @date, @company, @email, @first_name, @last_name, @tax_id, nr_of_attendees, total, tax]
  end

  def eql?(other)
    other.instance_of?(self.class) && @nr == other.nr
  end

  def ==(other)
    self.eql?(other)
  end

  def hash
    @nr
  end

  def free?
    @total.to_f == 0
  end

end

$orders = {}
class OrderImporter < ActiveImporter::Base
  imports Order

  column('Order no.', :nr) do |order_nr|
    order_nr.to_i
  end
  column('Order Date', :date) do |date_string|
    Date.parse(date_string)
  end
  column 'Buyer Email', :email
  column 'Buyer First Name', :first_name
  column 'Buyer Surname', :last_name
  column 'Company', :company, optional: true
  column('Tax Registration ID', :tax_id) do |company_tax_number_vat|
    unless company_tax_number_vat.nil?
      if company_tax_number_vat.match(/^[0-9]/)
        company_tax_number_vat = row['Tax Country'] + company_tax_number_vat
      end
    end
    company_tax_number_vat.delete(' ').delete('.')
  end
  column 'Tax Address 1', :address_line_1
  column 'Tax Address 2', :address_line_2
  column 'Tax Postcode', :postcode
  column 'Tax City', :city
  column 'Tax Country', :country

  on :row_processed do
    $orders[model.nr] = model
  end
end

class Attendee

  attr_accessor :email, :first_name, :last_name, :ticket_type, :total, :tax

  def to_s
    "Attendee %-35s, %-15s, %-20s" % [@email, @first_name, @last_name]
  end

end

class AttendeeImporter < ActiveImporter::Base
  imports Attendee

  column 'Email', :email
  column 'First Name', :first_name
  column 'Surname', :last_name
  column 'Ticket Type', :ticket_type
  column('Total Paid', :total) do |total|
    total.to_f
  end
  column('Tax Paid', :tax) do |tax|
    tax.to_f
  end

  on :row_processed do
    order_nr = row['Order no.'].to_i
    order = $orders[order_nr]
    order.add_attendee(model)
  end

end

if options[:file].nil?
  puts "No input file given!"
  puts optparse
  exit -1
end

# first scan, import the orders
OrderImporter.import(options[:file])
# second scan, import the attendees and link them to the orders.
AttendeeImporter.import(options[:file])

$orders.values.each do |order|
  puts order
end


# Stats
money = 0
free_tickets = 0
invoices = 0
attendees = 0
countries = Hash.new

# Now iterate over all orders (from memory)
$orders.values.each do |order|

  # Update the stats for money, free tickets and invoices
  money += order.total
  attendees += order.nr_of_attendees
  free_tickets += order.nr_of_attendees if order.total == 0
  invoices +=1 if order.total > 0

end

80.times { print '-'}
puts

puts "Orders: #{$orders.values.length} - Invoice Required #{invoices} / Attendees: #{attendees} - Tickets: Free #{free_tickets}"
puts "Total Sales: #{money}"
80.times { print '-'}
puts

# Now for all attendees in memory
$orders.values.each do |order|

  # Only if they have paid
  unless order.total == 0

    puts "Generating invoice for order %s - %s" % [order.nr, order.safe_name]

    notes_template = ERB.new settings[:invoice][:fields][:notes]
    # Always VAT
    vat_options = {
      :tax_rate => settings[:invoice][:fields][:tax_rate],
      :tax_description => settings[:invoice][:fields][:tax_description],
      :notes => notes_template.result(binding)
    }

    invoice_display_nr = '%03d' % [invoice_nr]
    invoice_options = {
      :invoice_number => "#{settings[:invoice][:prefix]}#{invoice_display_nr}",
      :bill_to => order.bill_to,
      :invoice_date => Date.today
    }

    invoice = Payday::Invoice.new(
      invoice_options.merge(vat_options)
    )

    # We create a single invoice per order
    order.attendees.each do |attendee|
      description_template = ERB.new settings[:invoice][:fields][:description]
      item_options = {
        :quantity => 1,
        :description => description_template.result(binding),
      }

      price_options = {
        :price => attendee.total/(1+settings[:invoice][:fields][:tax_rate].to_f),
      }

      invoice.line_items << Payday::LineItem.new(
        item_options.merge(price_options)
      )
    end

    # Create the PDF file if it doesn't exist
    pdf_file="#{settings[:invoice][:prefix]}#{invoice_display_nr}-#{order.safe_name}.pdf"
    pdf_full_path = File.join(settings[:invoice][:output_dir], pdf_file)

    unless File.exists?(pdf_file)
      begin
        invoice.render_pdf_to_file(pdf_full_path)
      rescue Exception => ex
        puts "Error: #{ex}"
        exit -1
      end
    end

    unless options[:mail].nil?
      # Set mail configuration
      Mail.defaults do
        smtp = Net::SMTP.start(settings[:email][:smtp_server],settings[:email][:smtp_port])
        delivery_method :smtp_connection , :connection => smtp
      end

      mail = Mail.new do
        from settings[:email][:from]
        to "#{order.email}" if options[:mail] == 'attendee'
        to settings[:email][:test_address] if option[:mail] = 'test'
        subject settings[:email][:subject]
        body settings[:email][:body]

        # Attach file
        add_file(pdf_file)

      end
      # Send mail
      mail.deliver
    end

    invoice_nr += 1
  end
end
