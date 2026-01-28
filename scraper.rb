#!/usr/bin/env ruby
# frozen_string_literal: true

require "scraperwiki"
require "httparty"

class Scraper
  # Password required to get token
  BASIC_AUTH_FOR_TOKEN = "Y2xpZW50YXBwOg=="

  # Throttle block to be nice to servers we are scraping
  def throttle_block(extra_delay: 0.5)
    if @pause_duration
      puts "  Pausing #{@pause_duration}s"
      sleep(@pause_duration)
    end
    start_time = Time.now.to_f
    page = yield
    @pause_duration = (Time.now.to_f - start_time + extra_delay).round(3)
    page
  end

  # Cleanup and vacuum database of old records (planning alerts only looks at last 5 days)
  def cleanup_old_records
    cutoff_date = (Date.today - 30).to_s
    vacuum_cutoff_date = (Date.today - 35).to_s

    stats = ScraperWiki.sqliteexecute(
      "SELECT COUNT(*) as count, MIN(date_scraped) as oldest FROM data WHERE date_scraped < ?",
      [cutoff_date]
    ).first

    deleted_count = stats["count"]
    oldest_date = stats["oldest"]

    return unless deleted_count.positive? || ENV["VACUUM"]

    puts "Deleting #{deleted_count} applications scraped between #{oldest_date} and #{cutoff_date}"
    ScraperWiki.sqliteexecute("DELETE FROM data WHERE date_scraped < ?", [cutoff_date])

    # VACUUM roughly once each 33 days or if older than 35 days (first time) or if VACUUM is set
    return unless rand < 0.03 || (oldest_date && oldest_date < vacuum_cutoff_date) || ENV["VACUUM"]

    puts "  Running VACUUM to reclaim space..."
    ScraperWiki.sqliteexecute("VACUUM")
  end

  def applications_page(authority_id, start_row, headers)
    # Getting the most recently submitted applications for the particular authority
    query = {
      "data": {
        "applicationListSearchRequest": {
          "searchFilters": [
            {
              "id": "completed",
              "selected": ["ALL"],
            },
          ],
          "searchText": nil,
          "myApplications": false,
          "watchedApplications": false,
          "searchInitiatedByUserClickEvent": false,
          "sortField": "SUBMITTED_DATE",
          "sortDirection": "desc",
          "startRow": start_row,
        },
        "tab": "ALL",
        "filterString": "",
        "completedFilterString": "ALL",
        "responsibleAuthoritySiteId": authority_id,
      },
    }

    application_list_url = "https://www.spear.land.vic.gov.au/spear/api/v1/applicationlist/publicSearch"
    applications = HTTParty.post(
      application_list_url,
      body: query.to_json,
      headers: headers
    )

    # Process a page of applications
    rows = applications&.dig("data", "resultRows")
    if rows.nil?
      puts "Error: unable to find rows from #{application_list_url}"
      return
    end

    expected_count = applications&.dig("data", "numFound").to_i
    if rows.size == expected_count
      puts "Found #{rows.size} rows of applications from #{application_list_url}"
    else
      puts "WARNING: Found #{rows.size} rows of applications from #{application_list_url}, expected #{expected_count}"
    end

    rows.each do |a|
      spear_reference = a["spearReference"]
      if spear_reference.nil?
        puts "Error: spear_reference is empty - skipping record from #{application_list_url}"
        next
      end

      if a["submittedDate"].nil?
        puts "Error: SubmittedDate is empty for #{spear_reference} - skipping record from #{application_list_url}"
        next
      end

      # We need to get more detailed information to get the application id (for the info_url) and
      # a half-way decent description.
      # This requires two more API calls. Ugh.
      application_url = "https://www.spear.land.vic.gov.au/spear/api/v1/applications/retrieve/#{spear_reference}?publicView=true"
      result = HTTParty.get(
        application_url,
        headers: headers
      )
      application_id = result["data"]&.dig("applicationId")
      if application_id.nil?
        puts "Error: Missing application_id for #{spear_reference} - skipping record from #{application_url}"
        next
      end
      detail_url = "https://www.spear.land.vic.gov.au/spear/api/v1/applications/#{application_id}/summary?publicView=true"
      detail = HTTParty.get(
        detail_url,
        headers: headers
      )

      unless detail&.dig("data")
        puts "Error: Missing detail data for #{spear_reference} - skipping record from #{detail_url}"
        next
      end

      description = detail&.dig("data", "intendedUse").to_s
      puts "WARNING: missing description for #{spear_reference} - from #{application_list_url}" if description.empty?

      yield(
        "council_reference" => a["spearReference"],
        "address" => a["property"],
        "description" => description,
        "info_url" => "https://www.spear.land.vic.gov.au/spear/app/public/applications/#{application_id}/summary",
        "date_scraped" => Date.today.to_s,
        "date_received" => Date.strptime(a["submittedDate"], "%d/%m/%Y").to_s
      )
    end
  end

  def all_applications(authority_id, headers, &block)
    start_row = 0

    loop do
      number_on_page, total_no = applications_page(authority_id, start_row, headers, &block)
      start_row += number_on_page
      break if start_row >= total_no
    end
  end

  def run
    tokens = HTTParty.post(
      "https://www.spear.land.vic.gov.au/spear/api/v1/oauth/token",
      body: "username=public&password=&grant_type=password&client_id=clientapp&scope=spear_rest_api",
      headers: { "Authorization" => "Basic #{BASIC_AUTH_FOR_TOKEN}" }
    )

    headers = {
      "Authorization" => "Bearer #{tokens['access_token']}",
      "Content-Type" => "application/json",
    }

    authorities = HTTParty.post(
      "https://www.spear.land.vic.gov.au/spear/api/v1/site/search",
      body: '{"data":{"searchType":"publicsearch","searchTypeFilter":"all","searchText":null,"showInactiveSites":false}}',
      headers: headers
    )

    puts "Found #{authorities['data'].size} authorities ..."

    authorities["data"].each do |authority|
      next if ENV["MORPH_AUTHORITIES"] && !ENV["MORPH_AUTHORITIES"].split(",").include?(authority["name"])

      puts
      puts "Getting applications for #{authority['name']}..."
      id = authority["id"]

      all_applications(id, headers) do |record|
        # We only want the last 28 days
        break if Date.parse(record["date_received"]) < Date.today - 28

        puts "Saving #{record['council_reference']} - #{record['address']} ..."
        ScraperWiki.save_sqlite(["council_reference"], record)
      end
    end
    puts "Finished!"
  end
end

Scraper.new.run if __FILE__ == $PROGRAM_NAME
