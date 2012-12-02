require 'eventbrite-client'
require 'mail'
require 'ostruct'
require 'pp'
require 'iso_country_codes'

require 'payday'


# Read  files
options = {
  :credentials => 'credentials.yml',
  :settings => 'settings.yml',
  :mail => nil
}

optparse = OptionParser.new do |opts|
  opts.on('-h','--help','Display this screen') do
    puts opts
    exit
  end
  opts.on('-c','--credentials FILENAME', 'Path to credentials yamlfile. Default: credentials.yml') do |f|
    options[:credentials] = f
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

# Loading credentials
begin
  credentials = YAML.load_file(options[:credentials])
rescue Exception => e
  puts "Error #{e}"
  exit -1
end

settings={}
# Loading setting
begin
  settings = YAML.load_file(options[:settings])
rescue Exception => e
  puts "Error #{e}"
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

class EbAttendee

  def method_missing(name, *args)
    unless (instance_variables.include?("@#{name}"))
      return instance_variable_get "@#{name}"
    end
  end

  def bill_to
    bill = Array.new
    bill << "#{@first_name} #{@last_name}"
    bill << "#{@email}"

    # If an invoice is required there is a company_name & company_address
    if self.invoice_required?
      [ @company_name, @company_address].each do |b|
        bill << b
      end
    else
      [ @home_address, @home_address2 ,  @home_city].each do |b|
        bill << b
      end
      bill << "#{IsoCountryCodes.find(@home_country).name}"
    end

    # Try to correct VAT address
    unless @company_tax_number_vat.nil?
      if @company_tax_number_vat.match(/^[0-9]/)
        bill << @home_country + @company_tax_number_vat
      else
        bill << @company_tax_number_vat
      end
    end
    bill.reject! { |i| i == nil }
    return bill.join("\n")
  end

  def safe_name
    if self.invoice_required?
      unless @company_name.empty?
        name = @company_name.downcase.gsub(/[^A-Za-z\ ]/,'').gsub(/[\ -]/,'_')
      else
        puts "Warning empty company for invoice"
        name = "#{first_name}#{last_name}"
      end
    else
      name = "#{first_name}#{last_name}"
    end
    name.downcase.gsub(/[^A-Za-z\ ]/,'').gsub(/[\ -]/,'_')
  end

  def from_country?(country)
    @home_country.upcase == country
  end

  def free?
    @amount_paid.to_f == 0
  end

  def invoice_required?
    @invoice_required == 'YES'
  end


end

# Setup eventbrite credentials
app_key       = credentials[:app_key]
user_key      = credentials[:user_key]
event_id      = settings[:event][:id]
eb_auth_tokens = { app_key: app_key, user_key: user_key}

# Connect to Eventbrite
eb_client = EventbriteClient.new(eb_auth_tokens)

# Find all events
response = eb_client.user_list_events()

# Lookup the event
eb_events = eb_client.event_get({ id: event_id })
eb_event = eb_events['event']

# Find all ticket types
tickets = Hash.new
eb_tickets = eb_event['tickets']
eb_tickets.each do |eb_ticket|
  ticket = eb_ticket['ticket']
  ticket.keys.each do |key|
    ticket_id = ticket['id']
    tickets[ticket_id] = Hash.new if tickets[ticket_id].nil?
    tickets[ticket_id][key] = ticket[key]
  end
end

# Load each attendee
eb_attendees = eb_client.event_list_attendees({ id: event_id })['attendees']
attendees = Array.new

eb_attendees.each do |eb_attendee|
  p = EbAttendee.new

  # Inject all information into our attendee p
  eb_attendee['attendee'].keys.each do |name|
    p.instance_variable_set("@#{name}",eb_attendee['attendee'][name])
  end

  # Sanitize question results and inject them as variables
  eb_answers = eb_attendee['attendee']['answers']
  eb_answers.each do |eb_answer|
    answer = eb_answer['answer']
    question_name = answer['question'].downcase.gsub(/[^A-Za-z0-9_\ \-]/,'').gsub(/[\ -]/,'_')
    # Inject all answers into our attendee p
    p.instance_variable_set("@#{question_name}",answer['answer_text'])
  end

  attendees << p
end

# Sort by ticket created date
attendees.sort! { |a,b|
  Date.parse(a.created) <=> Date.parse(b.created)
}

# Stats
money = 0
free_tickets = 0
invoices = 0
countries = Hash.new
discounts = Hash.new

# Now iterate over all attendees (from memory)
attendees.each do |attendee|

  # Update the stats for money, free tickets and invoices
  money = money + attendee.amount_paid.to_f
  free_tickets +=1 if attendee.amount_paid.to_f == 0
  invoices +=1 if attendee.invoice_required == 'YES'

  # See how many got discounts
  discounts[attendee.discount] += 1 unless discounts[attendee.discount].nil?
  discounts[attendee.discount] = 1 if discounts[attendee.discount].nil?
end

80.times { print '-'}
puts

puts "Attendees: #{attendees.size} - Tickets: Free #{free_tickets} - Invoice Required #{invoices}"
puts "Total Sales: #{money}"
80.times { print '-'}
puts

# Now for all attendees in memory
attendees.each do |attendee|

  # Only if they have paid
  unless attendee.amount_paid.to_f == 0

    # Always VAT
    vat_options = {
      :tax_rate => settings[:invoice][:fields][:tax_rate],
      :tax_description => settings[:invoice][:fields][:tax_description],
      :notes => settings[:invoice][:fields][:notes]
    }

    invoice_options = {
      :invoice_number => invoice_nr,
      :bill_to => attendee.bill_to,
      :paid_at => attendee.created
    }

    invoice = Payday::Invoice.new(
      invoice_options.merge(vat_options)
    )
    invoice_nr += 1

    # We create separate invoices per attendee
    item_options = {
      :quantity => 1,
      :description => "#{settings[:invoice][:fields][:description]} - #{tickets[attendee.ticket_id]['name']}",
    }

    price_options = {
      :price => attendee.amount_paid.to_f/(1.21),
    }

    invoice.line_items << Payday::LineItem.new(
      item_options.merge(price_options)
    )

    # Create the PDF file if it doesn't exist
    pdf_file="#{settings[:invoice][:prefix]}#{invoice_nr}-#{attendee.safe_name}.pdf"

    unless File.exists?(pdf_file)
      begin
        invoice.render_pdf_to_file(File.join(settings[:output_dir],pdf_file))
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

      # Only send invoices to people that requested one
      if attendee.invoice_required?
        mail = Mail.new do
          from settings[:email][:from]
          to "#{attendee.email}" if options[:mail] == 'attendee'
          to settings[:email][:test_address] if option[:mail] = 'test'
          subject settings[:email][:subject]
          body settings[:email][:body]

          # Attach file
          add_file(pdf_file)
        end

        # Send mail
        #mail.deliver
      end
    end

  end
end
