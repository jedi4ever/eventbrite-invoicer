## Eventbrite-invoicer

Ruby script to read an Eventbrite event and generate invoices for the attendees and optionally email them
This is was created out of the frustration that Eventbrite doesn't generate invoices automagically.

## Install

    $ bundle install

## Config
### Credentials.yml
By default it will look for a file with your Eventbrite application credential in your local directory with the 
name 'credentials.yml'. You can generate them by visiting <https://www.eventbrite.com/myaccount/apps/> and generating 
one. This will give you *Your Personal OAuth token*.

    ---
    :access_token: <Your Personal OAuth Token>

### Settings file
By default it wil look for a file with your eventbrite event/invoice settings in your local directory with the 
name 'settings.yml'. Adapt to your likings. 

Most likely you'll need to :

- find your eventid
- provide a logo file

        # Event that we used to generate it
        :event:
          :id: YOUREVENTID

        # Settings for the invoice
        :invoice:
          :prefix: F
          :start: 491
          :country: BE
          :locale: :nl
          :output_dir: .
          # passed to Payday::Config.default.
          :config:
            :invoice_logo: logo.png
            :company_name: Your company
            :company_details: |
              your company address
              email@yourcompany
              Tax: your taxnumber

            :date_format: '%D-%M-%Y'
            :currency: USD
            :page_size: A4
          # passed as fields to Payday
          :fields:
            :tax_rate: 0.21
            :tax_description: BTW 21%
            :notes: Paid with Paypal
            :company_name: Yourcompany name
            :description: Your event 2013

        # Setting for the email
        :email:
          :smtp_server: 127.0.0.1
          :smtp_port: 9025
          :from: info@yourevent.org
          :testaddress: atestemail@yourevent.org
          :subject: Your event 2013
          :body: |
           Dear attendee,

           as requested, here is the invoice for your ticket(s) for Your event

           Hope you enjoyed the event!
           The organizers.

## Eventbrite setup
The script currently assumes that you have configured your event with the following 'questions':

- invoice_required: YES OR NO
- company_name: company where to send the invoice to (including Country)
- company_address: where to send the invoice to
- company_tax_number_vat : if applicable

## Run it

    Usage: eventbrite-invoicer [options]
       -h, --help                       Display this screen
       -c, --credentials FILENAME       Path to credentials yamlfile. Default: credentials.yml
       -s, --settings FILENAME          Path to settings yamlfile. Default: settings.yml
       -m, --mail OPTION                Option to mail. Default: none. Other options: "test"|"attendee"

## Big thanks to

- Payday gem : <https://github.com/commondream/payday>
- Eventbrite: <http://evenbrite.com>
- Eventbrite-Client Gem: <https://github.com/ryanj/eventbrite-client.rb>
