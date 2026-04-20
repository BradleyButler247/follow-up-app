#!/usr/bin/env ruby

require "cgi"
require "csv"
require "date"
require "fileutils"
require "json"
require "net/http"
require "net/smtp"
require "securerandom"
require "time"
require "uri"
require "webrick"

ROOT = File.expand_path(__dir__)
DATA_PATH = File.join(ROOT, "data", "store.json")

def load_env_file(path)
  return unless File.exist?(path)

  File.readlines(path).each do |line|
    stripped = line.strip
    next if stripped.empty? || stripped.start_with?("#")

    key, value = stripped.split("=", 2)
    next if key.to_s.strip.empty?

    ENV[key.strip] ||= value.to_s.strip.gsub(/\A['"]|['"]\z/, "")
  end
end

load_env_file(File.join(ROOT, ".env"))
load_env_file(File.join(ROOT, ".env.local"))

module Support
  module_function

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def string_value(value)
    value.to_s.strip
  end

  def iso_now
    Time.now.utc.iso8601
  end

  def today_iso
    Time.now.strftime("%Y-%m-%d")
  end

  def uuid
    SecureRandom.uuid
  end

  def normalize_bool(value)
    return true if value == true || value.to_s.strip.downcase == "true"
    return false if value == false || value.to_s.strip.downcase == "false"

    false
  end

  def parse_int(value, fallback)
    Integer(value)
  rescue ArgumentError, TypeError
    fallback
  end

  def normalize_status(value)
    normalized = string_value(value)
    return "paused" if normalized == "paused"
    return "do-not-contact" if normalized == "do-not-contact"

    "active"
  end

  def iso_date?(value)
    string_value(value).match?(/\A\d{4}-\d{2}-\d{2}\z/)
  end

  def add_days(date_string, day_offset)
    DateTime.parse("#{date_string}T12:00:00").next_day(day_offset.to_i).strftime("%Y-%m-%d")
  rescue ArgumentError
    today_iso
  end

  def lead_name(lead)
    [lead["firstName"], lead["lastName"]].map { |value| string_value(value) }.reject(&:empty?).join(" ").strip
  end

  def lead_fingerprint(lead)
    [lead["firstName"], lead["lastName"], lead["propertyAddress"]]
      .map { |value| string_value(value).downcase }
      .join("|")
  end

  def html_escape(value)
    CGI.escapeHTML(value.to_s)
  end

  def normalize_phone(value)
    digits = value.to_s.gsub(/\D/, "")
    return nil if digits.empty?
    return "+1#{digits}" if digits.length == 10
    return "+#{digits}" if digits.length == 11 && digits.start_with?("1")

    value.to_s.strip
  end

  def normalize_email(value)
    trimmed = string_value(value)
    return "" if trimmed.empty?

    trimmed.downcase
  end

  def compact_hash(hash)
    hash.each_with_object({}) do |(key, value), result|
      next if value.nil?
      next if value.respond_to?(:empty?) && value.empty?

      result[key] = value
    end
  end

  def safe_hash(value)
    value.is_a?(Hash) ? value : {}
  end

  def event_message(channel, lead_name, status, provider)
    base = "#{channel.capitalize} #{status} for #{lead_name}"
    provider.to_s.empty? ? base : "#{base} via #{provider}"
  end
end

class AccessControl
  COOKIE_NAME = "seller_partner_session".freeze
  SESSION_LIFETIME = 60 * 60 * 24 * 30

  def initialize(access_code)
    @access_code = access_code.to_s.strip
    @sessions = {}
    @lock = Mutex.new
  end

  def enabled?
    !@access_code.empty?
  end

  def login(code, response)
    return false unless enabled?
    return false unless code.to_s.strip == @access_code

    session_id = SecureRandom.hex(24)
    expires_at = Time.now.to_i + SESSION_LIFETIME

    @lock.synchronize do
      prune_sessions!
      @sessions[session_id] = expires_at
    end

    cookie = WEBrick::Cookie.new(COOKIE_NAME, session_id)
    cookie.path = "/"
    cookie.expires = Time.at(expires_at)
    response.cookies << cookie
    true
  end

  def logout(request, response)
    session_id = session_id_from(request)
    @lock.synchronize do
      @sessions.delete(session_id) if session_id
    end

    cookie = WEBrick::Cookie.new(COOKIE_NAME, "")
    cookie.path = "/"
    cookie.expires = Time.at(0)
    response.cookies << cookie
  end

  def authenticated?(request)
    return true unless enabled?

    session_id = session_id_from(request)
    return false if session_id.to_s.empty?

    @lock.synchronize do
      prune_sessions!
      expires_at = @sessions[session_id]
      !expires_at.nil? && expires_at > Time.now.to_i
    end
  end

  private

  def session_id_from(request)
    cookie = request.cookies.find { |item| item.name == COOKIE_NAME }
    cookie&.value.to_s
  end

  def prune_sessions!
    now = Time.now.to_i
    @sessions.delete_if { |_key, expires_at| expires_at <= now }
  end
end

module Defaults
  module_function

  TEMPLATES = {
    "text" =>
      "Hi {{firstName}}, this is {{companyName}} reaching out about {{propertyAddress}}. If you've considered selling, we would love to make you a fair cash offer and keep the process simple. Reply here if you'd be open to a quick conversation. Reply STOP to opt out.",
    "emailSubject" => "Quick question about {{propertyAddress}}",
    "emailBody" =>
      "Hi {{firstName}},\n\nI wanted to reach out about {{propertyAddress}}. {{companyName}} buys houses directly and we try to make the process simple, flexible, and fast.\n\nIf selling is something you would consider, reply here and I can share a few options.\n\nThanks,\n{{companyName}}\n{{companyPhone}}\n{{companyEmail}}",
    "letter" =>
      "{{today}}\n\n{{fullName}}\n{{mailingAddress}}\n\nHi {{firstName}},\n\nI wanted to personally reach out about {{propertyAddress}}. {{companyName}} buys houses directly from homeowners and we aim to make the sale simple and straightforward.\n\nIf you would consider an offer on the property, I would be glad to connect and learn more about your timeline.\n\nSincerely,\n{{companyName}}\n{{companyPhone}}\n{{companyEmail}}"
  }.freeze

  SEQUENCE = [
    { "id" => "step-mail-0", "label" => "Intro letter", "channel" => "mail", "dayOffset" => 0 },
    { "id" => "step-email-2", "label" => "Intro email", "channel" => "email", "dayOffset" => 2 },
    { "id" => "step-text-5", "label" => "Initial text", "channel" => "text", "dayOffset" => 5 },
    { "id" => "step-mail-14", "label" => "Follow-up letter", "channel" => "mail", "dayOffset" => 14 },
    { "id" => "step-text-21", "label" => "Final text follow-up", "channel" => "text", "dayOffset" => 21 }
  ].freeze

  SETTINGS = {
    "system" => {
      "companyName" => "Close Circle Investments",
      "companyPhone" => "(970) 833-1256",
      "companyEmail" => "wilson@closecircleinvest.com",
      "smsFromNumber" => "(970) 833-1256",
      "emailFromAddress" => "wilson@closecircleinvest.com",
      "emailReplyTo" => "wilson@closecircleinvest.com",
      "mailReturnAddress" => "3006 Zuni St, Denver, CO 80211",
      "textProvider" => "manual_google_voice",
      "emailProvider" => "manual_gmail",
      "mailProvider" => "manual_print",
      "crmName" => "",
      "crmWebhookUrl" => "",
      "crmWebhookToken" => "",
      "deliveryMode" => "dry_run",
      "autoSendEnabled" => false,
      "requireManualApproval" => true,
      "pollIntervalSeconds" => 60
    }
  }.freeze

  LEADS = [
    {
      "id" => "lead-fredrick-narragon",
      "firstName" => "Fredrick",
      "lastName" => "Narragon",
      "propertyAddress" => "607 Yellowstone Road, Colorado Springs, CO 80910",
      "mailingAddress" => "607 Yellowstone Road, Colorado Springs, CO 80910",
      "phone" => "",
      "email" => "",
      "sequenceStartDate" => Support.today_iso,
      "status" => "active",
      "notes" => "Seeded from intake details.",
      "channelPreferences" => { "text" => true, "email" => true, "mail" => true },
      "suppressions" => { "text" => false, "email" => false, "mail" => false },
      "outreach" => {},
      "createdAt" => Support.iso_now,
      "updatedAt" => Support.iso_now
    },
    {
      "id" => "lead-robert-beltz",
      "firstName" => "Robert",
      "lastName" => "Beltz",
      "propertyAddress" => "5765 S Crocker St, Littleton",
      "mailingAddress" => "5765 S Crocker St, Littleton",
      "phone" => "3032209885",
      "email" => "robertbeltz@me.com",
      "sequenceStartDate" => Support.today_iso,
      "status" => "active",
      "notes" => "City/state/zip may need to be completed before formal mailing.",
      "channelPreferences" => { "text" => true, "email" => true, "mail" => true },
      "suppressions" => { "text" => false, "email" => false, "mail" => false },
      "outreach" => {},
      "createdAt" => Support.iso_now,
      "updatedAt" => Support.iso_now
    },
    {
      "id" => "lead-sylvia-troy",
      "firstName" => "Sylvia",
      "lastName" => "Troy",
      "propertyAddress" => "805 Holiday Cir, Denver",
      "mailingAddress" => "805 Holiday Cir, Denver",
      "phone" => "3039901436",
      "email" => "sylviatroy69@gmail.com",
      "sequenceStartDate" => Support.today_iso,
      "status" => "active",
      "notes" => "City/state/zip may need to be completed before formal mailing.",
      "channelPreferences" => { "text" => true, "email" => true, "mail" => true },
      "suppressions" => { "text" => false, "email" => false, "mail" => false },
      "outreach" => {},
      "createdAt" => Support.iso_now,
      "updatedAt" => Support.iso_now
    }
  ].freeze

  STATE = {
    "templates" => TEMPLATES,
    "sequence" => SEQUENCE,
    "settings" => SETTINGS,
    "leads" => LEADS,
    "activityLog" => [],
    "runtime" => {
      "lastProcessorRunAt" => nil,
      "lastProcessorSummary" => nil
    }
  }.freeze

  def state
    Support.deep_copy(STATE)
  end

  def normalize_state(raw_state)
    state = state()
    incoming = Support.safe_hash(raw_state)

    state["templates"].merge!(Support.safe_hash(incoming["templates"]))
    state["settings"]["system"].merge!(normalize_system_settings(incoming.dig("settings", "system")))
    state["sequence"] =
      if incoming["sequence"].is_a?(Array) && !incoming["sequence"].empty?
        incoming["sequence"].map { |step| normalize_sequence_step(step) }
      else
        Support.deep_copy(SEQUENCE)
      end
    state["leads"] =
      if incoming["leads"].is_a?(Array)
        incoming["leads"].map { |lead| normalize_lead(lead) }
      else
        []
      end
    state["activityLog"] =
      if incoming["activityLog"].is_a?(Array)
        incoming["activityLog"].first(100)
      else
        []
      end
    state["runtime"].merge!(Support.safe_hash(incoming["runtime"]))
    state
  end

  def normalize_system_settings(input)
    source = Support.safe_hash(input)
    {
      "companyName" => Support.string_value(source["companyName"]),
      "companyPhone" => Support.string_value(source["companyPhone"]),
      "companyEmail" => Support.normalize_email(source["companyEmail"]),
      "smsFromNumber" => Support.string_value(source["smsFromNumber"]),
      "emailFromAddress" => Support.string_value(source["emailFromAddress"]),
      "emailReplyTo" => Support.normalize_email(source["emailReplyTo"]),
      "mailReturnAddress" => Support.string_value(source["mailReturnAddress"]),
      "textProvider" => %w[manual_google_voice twilio].include?(source["textProvider"]) ? source["textProvider"] : "manual_google_voice",
      "emailProvider" => %w[manual_gmail gmail_smtp resend].include?(source["emailProvider"]) ? source["emailProvider"] : "manual_gmail",
      "mailProvider" => %w[manual_print lob].include?(source["mailProvider"]) ? source["mailProvider"] : "manual_print",
      "crmName" => Support.string_value(source["crmName"]),
      "crmWebhookUrl" => Support.string_value(source["crmWebhookUrl"]),
      "crmWebhookToken" => Support.string_value(source["crmWebhookToken"]),
      "deliveryMode" => source["deliveryMode"].to_s == "live" ? "live" : "dry_run",
      "autoSendEnabled" => Support.normalize_bool(source["autoSendEnabled"]),
      "requireManualApproval" => !source.key?("requireManualApproval") || Support.normalize_bool(source["requireManualApproval"]),
      "pollIntervalSeconds" => [15, Support.parse_int(source["pollIntervalSeconds"], 60)].max
    }
  end

  def normalize_channel_map(value, default_value)
    source = Support.safe_hash(value)
    %w[text email mail].each_with_object({}) do |channel, result|
      result[channel] = source.key?(channel) ? Support.normalize_bool(source[channel]) : default_value
    end
  end

  def normalize_lead(input)
    source = Support.safe_hash(input)
    property_address = Support.string_value(source["propertyAddress"])
    mailing_address = Support.string_value(source["mailingAddress"])

    {
      "id" => source["id"].to_s.empty? ? "lead-#{Support.uuid}" : source["id"].to_s,
      "firstName" => Support.string_value(source["firstName"]),
      "lastName" => Support.string_value(source["lastName"]),
      "propertyAddress" => property_address,
      "mailingAddress" => mailing_address.empty? ? property_address : mailing_address,
      "phone" => Support.string_value(source["phone"]),
      "email" => Support.normalize_email(source["email"]),
      "sequenceStartDate" => Support.iso_date?(source["sequenceStartDate"]) ? source["sequenceStartDate"] : Support.today_iso,
      "status" => Support.normalize_status(source["status"]),
      "notes" => Support.string_value(source["notes"]),
      "channelPreferences" => normalize_channel_map(source["channelPreferences"], true),
      "suppressions" => normalize_channel_map(source["suppressions"], false),
      "outreach" => normalize_outreach(source["outreach"]),
      "createdAt" => source["createdAt"] || Support.iso_now,
      "updatedAt" => source["updatedAt"] || Support.iso_now
    }
  end

  def normalize_outreach(input)
    source = Support.safe_hash(input)
    source.each_with_object({}) do |(step_id, value), result|
      next unless value.is_a?(Hash)

      result[step_id] = {
        "status" => Support.string_value(value["status"]),
        "approvedAt" => value["approvedAt"],
        "completedAt" => value["completedAt"],
        "lastAttemptAt" => value["lastAttemptAt"],
        "lastError" => value["lastError"],
        "provider" => value["provider"],
        "providerReference" => value["providerReference"],
        "deliveryMode" => value["deliveryMode"],
        "lastTrigger" => value["lastTrigger"]
      }.delete_if { |_key, item| item.nil? }
    end
  end

  def normalize_sequence_step(step)
    source = Support.safe_hash(step)
    {
      "id" => source["id"].to_s.empty? ? "step-#{Support.uuid}" : source["id"].to_s,
      "label" => Support.string_value(source["label"]).empty? ? "Follow-up step" : Support.string_value(source["label"]),
      "channel" => %w[text email mail].include?(source["channel"]) ? source["channel"] : "mail",
      "dayOffset" => [0, Support.parse_int(source["dayOffset"], 0)].max
    }
  end
end

class DataStore
  def initialize(path)
    @path = path
    @lock = Mutex.new
    FileUtils.mkdir_p(File.dirname(path))
    ensure_store!
  end

  def snapshot
    @lock.synchronize do
      Support.deep_copy(read_state)
    end
  end

  def update
    @lock.synchronize do
      state = read_state
      result = yield(state)
      write_state(state)
      [Support.deep_copy(state), result]
    end
  end

  private

  def ensure_store!
    return if File.exist?(@path)

    write_state(Defaults.state)
  end

  def read_state
    parsed =
      if File.exist?(@path)
        JSON.parse(File.read(@path))
      else
        Defaults.state
      end
    Defaults.normalize_state(parsed)
  rescue JSON::ParserError
    Defaults.state
  end

  def write_state(state)
    normalized = Defaults.normalize_state(state)
    temp_path = "#{@path}.tmp"
    File.write(temp_path, JSON.pretty_generate(normalized))
    File.rename(temp_path, @path)
  end
end

class TemplateRenderer
  def initialize(templates, settings)
    @templates = templates
    @settings = settings
  end

  def drafts_for(lead)
    context = build_context(lead)
    {
      "text" => render(@templates["text"], context),
      "emailSubject" => render(@templates["emailSubject"], context),
      "emailBody" => render(@templates["emailBody"], context),
      "letter" => render(@templates["letter"], context)
    }
  end

  private

  def build_context(lead)
    system = @settings.fetch("system")
    {
      "firstName" => lead["firstName"],
      "lastName" => lead["lastName"],
      "fullName" => Support.lead_name(lead),
      "propertyAddress" => lead["propertyAddress"],
      "mailingAddress" => lead["mailingAddress"],
      "today" => Time.now.strftime("%B %-d, %Y"),
      "companyName" => system["companyName"],
      "companyPhone" => system["companyPhone"],
      "companyEmail" => system["companyEmail"]
    }
  end

  def render(template, context)
    template.to_s.gsub(/\{\{\s*([a-zA-Z0-9]+)\s*\}\}/) do
      key = Regexp.last_match(1)
      context.fetch(key, "")
    end
  end
end

class AddressParser
  SINGLE_LINE_PATTERN = /\A(.+?),\s*([^,]+),\s*([A-Za-z]{2})\s+(\d{5}(?:-\d{4})?)\z/

  def self.parse_us_single_line(address_line, name:)
    candidate = Support.string_value(address_line)
    match = candidate.match(SINGLE_LINE_PATTERN)
    return nil unless match

    {
      "name" => name,
      "address_line1" => match[1].strip,
      "address_city" => match[2].strip,
      "address_state" => match[3].upcase,
      "address_zip" => match[4].strip,
      "address_country" => "US"
    }
  end
end

class QueueBuilder
  def initialize(state)
    @state = state
  end

  def tasks
    @state.fetch("leads").flat_map do |lead|
      @state.fetch("sequence").map do |step|
        build_task(lead, step)
      end
    end.sort_by do |task|
      [
        task["status"] == "blocked" ? 1 : 0,
        task["dueDate"],
        task["leadName"]
      ]
    end
  end

  def task_for(lead_id, step_id)
    tasks.find { |task| task["leadId"] == lead_id && task["id"] == step_id }
  end

  private

  def build_task(lead, step)
    outreach = Support.safe_hash(lead.fetch("outreach", {})[step["id"]])
    readiness = channel_readiness(lead, step["channel"])
    approval_required = @state.dig("settings", "system", "requireManualApproval")
    due_date = Support.add_days(lead["sequenceStartDate"], step["dayOffset"])
    provider_key = provider_for(step["channel"])
    status =
      if outreach["status"] == "completed"
        "completed"
      elsif outreach["status"] == "skipped"
        "skipped"
      elsif !readiness[:ready]
        "blocked"
      elsif outreach["status"] == "failed"
        "failed"
      elsif approval_required && outreach["approvedAt"]
        "approved"
      else
        "pending"
      end

    {
      "id" => step["id"],
      "label" => step["label"],
      "channel" => step["channel"],
      "dayOffset" => step["dayOffset"],
      "dueDate" => due_date,
      "dueNow" => due_date <= Support.today_iso,
      "leadId" => lead["id"],
      "leadName" => Support.lead_name(lead),
      "propertyAddress" => lead["propertyAddress"],
      "status" => status,
      "approvalRequired" => approval_required,
      "approvedAt" => outreach["approvedAt"],
      "completedAt" => outreach["completedAt"],
      "lastAttemptAt" => outreach["lastAttemptAt"],
      "lastError" => outreach["lastError"],
      "provider" => outreach["provider"],
      "providerReference" => outreach["providerReference"],
      "deliveryMode" => outreach["deliveryMode"],
      "providerKey" => provider_key,
      "providerLabel" => provider_label(provider_key),
      "sendActionLabel" => send_action_label(step["channel"], provider_key),
      "blockReason" => readiness[:reason],
      "canSendNow" => readiness[:ready] && (!approval_required || !outreach["approvedAt"].nil?) && !%w[completed skipped].include?(status)
    }
  end

  def channel_readiness(lead, channel)
    return { ready: false, reason: "Lead is paused." } if lead["status"] == "paused"
    return { ready: false, reason: "Lead is marked do not contact." } if lead["status"] == "do-not-contact"
    return { ready: false, reason: "#{channel.capitalize} is disabled for this lead." } unless lead.dig("channelPreferences", channel)
    return { ready: false, reason: "#{channel.capitalize} is suppressed for this lead." } if lead.dig("suppressions", channel)

    if channel == "text"
      return { ready: false, reason: "Add a phone number for text outreach." } if Support.string_value(lead["phone"]).empty?
    end

    if channel == "email"
      return { ready: false, reason: "Add an email address for email outreach." } if Support.string_value(lead["email"]).empty?
    end

    if channel == "mail"
      return { ready: false, reason: "Add a mailing address for direct mail." } if Support.string_value(lead["mailingAddress"]).empty?
    end

    { ready: true, reason: "" }
  end

  def provider_for(channel)
    system = @state.fetch("settings").fetch("system")
    case channel
    when "text"
      system["textProvider"]
    when "email"
      system["emailProvider"]
    when "mail"
      system["mailProvider"]
    else
      "unknown"
    end
  end

  def provider_label(provider_key)
    {
      "manual_google_voice" => "Google Voice manual",
      "twilio" => "Twilio SMS",
      "manual_gmail" => "Gmail manual",
      "gmail_smtp" => "Gmail SMTP",
      "resend" => "Resend",
      "manual_print" => "Manual print/mail",
      "lob" => "Lob"
    }[provider_key] || provider_key.to_s
  end

  def send_action_label(channel, provider_key)
    return "Mark text sent" if provider_key == "manual_google_voice"
    return "Mark emailed" if provider_key == "manual_gmail"
    return "Mark mailed" if provider_key == "manual_print"
    return "Send email" if channel == "email"

    "Send now"
  end
end

class TwilioAdapter
  def initialize(settings)
    @settings = settings
  end

  def configured?
    !account_sid.to_s.empty? && !auth_token.to_s.empty? && (!messaging_service_sid.to_s.empty? || !from_number.to_s.empty?)
  end

  def status
    {
      "configured" => configured?,
      "mode" => "Twilio SMS",
      "message" => configured? ? "Ready for live text sends." : "Set Twilio credentials plus a From number or Messaging Service SID."
    }
  end

  def deliver(to:, body:)
    raise "Twilio is not configured for live SMS sends." unless configured?

    uri = URI("https://api.twilio.com/2010-04-01/Accounts/#{account_sid}/Messages.json")
    request = Net::HTTP::Post.new(uri)
    request.basic_auth(account_sid, auth_token)
    payload = {
      "To" => Support.normalize_phone(to) || to,
      "Body" => body
    }

    if !messaging_service_sid.to_s.empty?
      payload["MessagingServiceSid"] = messaging_service_sid
    else
      payload["From"] = from_number
    end

    request.set_form_data(payload)
    response = perform_http(uri, request)
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      raise parsed["message"] || "Twilio rejected the SMS send."
    end

    {
      "provider" => "twilio",
      "reference" => parsed["sid"],
      "raw" => parsed
    }
  end

  private

  def account_sid
    ENV["TWILIO_ACCOUNT_SID"]
  end

  def auth_token
    ENV["TWILIO_AUTH_TOKEN"]
  end

  def messaging_service_sid
    ENV["TWILIO_MESSAGING_SERVICE_SID"]
  end

  def from_number
    configured_setting = @settings.dig("system", "smsFromNumber").to_s
    return configured_setting unless configured_setting.empty?

    ENV["TWILIO_FROM_NUMBER"].to_s
  end

  def perform_http(uri, request)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(request)
    end
  end
end

class ResendAdapter
  def initialize(settings)
    @settings = settings
  end

  def configured?
    !api_key.to_s.empty? && !from_address.to_s.empty?
  end

  def status
    {
      "configured" => configured?,
      "mode" => "Resend email",
      "message" => configured? ? "Ready for live email sends." : "Set RESEND_API_KEY and an email From address."
    }
  end

  def deliver(to:, subject:, text:)
    raise "Resend is not configured for live email sends." unless configured?

    uri = URI("https://api.resend.com/emails")
    request = Net::HTTP::Post.new(uri)
    request["Authorization"] = "Bearer #{api_key}"
    request["Content-Type"] = "application/json"
    request["Idempotency-Key"] = Support.uuid
    payload = {
      "from" => from_address,
      "to" => [to],
      "subject" => subject,
      "text" => text
    }
    reply_to = reply_to_address
    payload["reply_to"] = reply_to unless reply_to.to_s.empty?
    request.body = JSON.generate(payload)

    response = perform_http(uri, request)
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      raise parsed["message"] || parsed.dig("error", "message") || "Resend rejected the email send."
    end

    {
      "provider" => "resend",
      "reference" => parsed["id"],
      "raw" => parsed
    }
  end

  private

  def api_key
    ENV["RESEND_API_KEY"]
  end

  def from_address
    configured_setting = @settings.dig("system", "emailFromAddress").to_s
    return configured_setting unless configured_setting.empty?

    ENV["RESEND_FROM_ADDRESS"].to_s
  end

  def reply_to_address
    @settings.dig("system", "emailReplyTo").to_s
  end

  def perform_http(uri, request)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(request)
    end
  end
end

class GmailSmtpAdapter
  def initialize(settings)
    @settings = settings
  end

  def configured?
    !username.to_s.empty? && !app_password.to_s.empty?
  end

  def status
    {
      "configured" => configured?,
      "mode" => "Gmail SMTP",
      "message" =>
        if configured?
          "Ready for live email sends from Gmail."
        else
          "Set GMAIL_APP_PASSWORD after turning on 2-Step Verification for the Google Workspace account."
        end
    }
  end

  def deliver(to:, subject:, text:)
    raise "Gmail SMTP is not configured yet." unless configured?

    smtp = Net::SMTP.new("smtp.gmail.com", 587)
    smtp.enable_starttls_auto
    smtp.start("gmail.com", username, app_password, :login) do |connection|
      connection.send_message(build_message(to: to, subject: subject, text: text), from_address, to)
    end

    {
      "provider" => "gmail_smtp",
      "reference" => "gmail-#{Support.uuid}",
      "raw" => { "message" => "Message accepted by Gmail SMTP." }
    }
  end

  private

  def username
    configured_setting = @settings.dig("system", "emailFromAddress").to_s
    return configured_setting unless configured_setting.empty?

    ENV["GMAIL_SMTP_ADDRESS"].to_s
  end

  def from_address
    username
  end

  def reply_to_address
    @settings.dig("system", "emailReplyTo").to_s
  end

  def app_password
    ENV["GMAIL_APP_PASSWORD"].to_s
  end

  def build_message(to:, subject:, text:)
    headers = [
      "From: #{from_address}",
      "To: #{to}",
      "Subject: #{subject}",
      "MIME-Version: 1.0",
      "Content-Type: text/plain; charset=UTF-8"
    ]
    headers << "Reply-To: #{reply_to_address}" unless reply_to_address.empty?
    "#{headers.join("\r\n")}\r\n\r\n#{text}"
  end
end

class ManualGmailAdapter
  def initialize(settings)
    @settings = settings
  end

  def status
    {
      "configured" => !from_address.empty?,
      "mode" => "Gmail manual",
      "message" => "Open the prepared draft in Gmail, send it manually, then mark the queue task complete."
    }
  end

  def deliver(to:, subject:, text:)
    {
      "provider" => "manual_gmail",
      "reference" => "manual-email-#{Support.uuid}",
      "raw" => {
        "message" => "Manual Gmail send recorded.",
        "from" => from_address,
        "to" => to,
        "subject" => subject,
        "text" => text
      }
    }
  end

  private

  def from_address
    @settings.dig("system", "emailFromAddress").to_s
  end
end

class ManualGoogleVoiceAdapter
  def initialize(settings)
    @settings = settings
  end

  def status
    {
      "configured" => !from_number.empty?,
      "mode" => "Google Voice manual",
      "message" =>
        if from_number.empty?
          "Add your Google Voice number so the team knows which line to use."
        else
          "Use the copied text in Google Voice, then click the queue action to mark it sent."
        end
    }
  end

  def deliver(to:, body:)
    {
      "provider" => "manual_google_voice",
      "reference" => "manual-text-#{Support.uuid}",
      "raw" => {
        "message" => "Manual Google Voice send recorded.",
        "from" => from_number,
        "to" => to,
        "body" => body
      }
    }
  end

  private

  def from_number
    @settings.dig("system", "smsFromNumber").to_s
  end
end

class ManualPrintAdapter
  def initialize(settings)
    @settings = settings
  end

  def status
    {
      "configured" => !@settings.dig("system", "mailReturnAddress").to_s.empty?,
      "mode" => "Manual print and mail",
      "message" => "Export or print the letter, then use the queue action to mark it mailed."
    }
  end

  def deliver(to_name:, to_address_line:, letter_text:)
    {
      "provider" => "manual_print",
      "reference" => "manual-mail-#{Support.uuid}",
      "raw" => {
        "message" => "Manual print/mail recorded.",
        "to_name" => to_name,
        "to_address" => to_address_line,
        "letter" => letter_text
      }
    }
  end
end

class LobAdapter
  def initialize(settings)
    @settings = settings
  end

  def configured?
    !api_key.to_s.empty? &&
      !company_name.to_s.empty? &&
      !AddressParser.parse_us_single_line(return_address_line, name: company_name).nil?
  end

  def status
    {
      "configured" => configured?,
      "mode" => "Lob letters",
      "message" => configured? ? "Ready for live letter sends." : "Set LOB_API_KEY, company name, and a parseable return address."
    }
  end

  def deliver(to_name:, to_address_line:, letter_text:)
    raise "Lob is not configured for live mail sends." unless configured?

    to_address = AddressParser.parse_us_single_line(to_address_line, name: to_name)
    raise "Mailing address must look like '123 Main St, Denver, CO 80205' for Lob." unless to_address

    from_address = AddressParser.parse_us_single_line(return_address_line, name: company_name)
    raise "Return address must look like '123 Main St, Denver, CO 80205' for Lob." unless from_address

    uri = URI("https://api.lob.com/v1/letters")
    request = Net::HTTP::Post.new(uri)
    request.basic_auth(api_key, "")
    request["Content-Type"] = "application/json"
    request["Lob-Version"] = "2024-01-01"
    request["Idempotency-Key"] = Support.uuid
    request.body = JSON.generate(
      {
        "description" => "Seller outreach letter",
        "to" => to_address,
        "from" => from_address,
        "file" => build_letter_html(letter_text),
        "color" => false,
        "use_type" => "marketing"
      }
    )

    response = perform_http(uri, request)
    parsed = JSON.parse(response.body)

    unless response.code.to_i.between?(200, 299)
      raise parsed["message"] || parsed.dig("error", "message") || "Lob rejected the letter send."
    end

    {
      "provider" => "lob",
      "reference" => parsed["id"],
      "raw" => parsed
    }
  end

  private

  def api_key
    ENV["LOB_API_KEY"]
  end

  def company_name
    @settings.dig("system", "companyName").to_s
  end

  def return_address_line
    @settings.dig("system", "mailReturnAddress").to_s
  end

  def build_letter_html(letter_text)
    escaped_text = Support.html_escape(letter_text).gsub("\n", "<br>")
    <<~HTML
      <html>
        <head>
          <meta charset="utf-8">
          <style>
            body { font-family: Georgia, serif; font-size: 12pt; line-height: 1.5; margin: 0.75in; color: #1f2b23; }
          </style>
        </head>
        <body>
          <div>#{escaped_text}</div>
        </body>
      </html>
    HTML
  end

  def perform_http(uri, request)
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(request)
    end
  end
end

class DeliveryEngine
  def initialize(store)
    @store = store
  end

  def upsert_lead(attributes, id: nil)
    state, lead = @store.update do |current_state|
      incoming = Support.safe_hash(attributes)
      incoming["id"] = id if id
      normalized = Defaults.normalize_lead(incoming)
      index = current_state["leads"].find_index { |lead| lead["id"] == normalized["id"] }

      if index
        existing = current_state["leads"][index]
        normalized["createdAt"] = existing["createdAt"]
        normalized["outreach"] = existing["outreach"]
        normalized["channelPreferences"] = existing["channelPreferences"].merge(normalized["channelPreferences"])
        normalized["suppressions"] = existing["suppressions"].merge(normalized["suppressions"])
        current_state["leads"][index] = normalized
      else
        current_state["leads"].unshift(normalized)
      end

      normalized
    end

    [state, lead]
  end

  def delete_lead(id)
    @store.update do |state|
      state["leads"].reject! { |lead| lead["id"] == id }
    end
  end

  def import_csv(csv_text)
    parsed = CSV.parse(csv_text, headers: true)
    count = 0

    @store.update do |state|
      parsed.each do |row|
        next if row.to_h.values.all? { |value| Support.string_value(value).empty? }

        incoming = Defaults.normalize_lead(
          {
            "firstName" => row["firstName"],
            "lastName" => row["lastName"],
            "propertyAddress" => row["propertyAddress"],
            "mailingAddress" => row["mailingAddress"],
            "phone" => row["phone"],
            "email" => row["email"],
            "notes" => row["notes"],
            "status" => row["status"],
            "sequenceStartDate" => row["sequenceStartDate"]
          }
        )

        next if incoming["firstName"].empty? || incoming["lastName"].empty? || incoming["propertyAddress"].empty?

        existing_index = state["leads"].find_index do |lead|
          Support.lead_fingerprint(lead) == Support.lead_fingerprint(incoming)
        end

        if existing_index
          existing = state["leads"][existing_index]
          incoming["id"] = existing["id"]
          incoming["createdAt"] = existing["createdAt"]
          incoming["outreach"] = existing["outreach"]
          incoming["channelPreferences"] = existing["channelPreferences"]
          incoming["suppressions"] = existing["suppressions"]
          state["leads"][existing_index] = incoming
        else
          state["leads"].unshift(incoming)
        end

        count += 1
      end
    end

    count
  rescue CSV::MalformedCSVError => error
    raise "CSV import failed: #{error.message}"
  end

  def update_templates(templates)
    @store.update do |state|
      state["templates"].merge!(Support.safe_hash(templates))
    end
  end

  def update_sequence(sequence)
    normalized_sequence = Array(sequence).map { |step| Defaults.normalize_sequence_step(step) }.sort_by { |step| step["dayOffset"] }
    raise "Sequence must include at least one step." if normalized_sequence.empty?

    @store.update do |state|
      state["sequence"] = normalized_sequence
    end
  end

  def update_system_settings(system_settings)
    normalized = Defaults.normalize_system_settings(system_settings)
    @store.update do |state|
      state["settings"]["system"].merge!(normalized)
    end
  end

  def update_suppression(lead_id, channel, suppressed)
    channel_name = channel.to_s
    raise "Unknown channel." unless %w[text email mail].include?(channel_name)

    @store.update do |state|
      lead = find_lead!(state, lead_id)
      lead["suppressions"][channel_name] = Support.normalize_bool(suppressed)
      lead["updatedAt"] = Support.iso_now
    end
  end

  def update_channel_preference(lead_id, channel, enabled)
    channel_name = channel.to_s
    raise "Unknown channel." unless %w[text email mail].include?(channel_name)

    @store.update do |state|
      lead = find_lead!(state, lead_id)
      lead["channelPreferences"][channel_name] = Support.normalize_bool(enabled)
      lead["updatedAt"] = Support.iso_now
    end
  end

  def approve_task(lead_id, step_id)
    @store.update do |state|
      lead = find_lead!(state, lead_id)
      outreach = lead["outreach"][step_id] ||= {}
      outreach["approvedAt"] = Support.iso_now
      outreach.delete("lastError")
      outreach["status"] = "pending" if outreach["status"] == "failed"
      lead["updatedAt"] = Support.iso_now
    end
  end

  def skip_task(lead_id, step_id)
    @store.update do |state|
      lead = find_lead!(state, lead_id)
      outreach = lead["outreach"][step_id] ||= {}
      outreach["status"] = "skipped"
      outreach["completedAt"] = Support.iso_now
      lead["updatedAt"] = Support.iso_now
    end
  end

  def reset_task(lead_id, step_id)
    @store.update do |state|
      lead = find_lead!(state, lead_id)
      lead["outreach"].delete(step_id)
      lead["updatedAt"] = Support.iso_now
    end
  end

  def process_due(trigger: "manual")
    snapshot = @store.snapshot
    queue = QueueBuilder.new(snapshot).tasks
    due_tasks = queue.select do |task|
      task["dueNow"] && task["canSendNow"] && !%w[completed skipped blocked].include?(task["status"])
    end

    results = due_tasks.map do |task|
      send_task(task["leadId"], task["id"], trigger: trigger)
    end

    @store.update do |state|
      state["runtime"]["lastProcessorRunAt"] = Support.iso_now
      state["runtime"]["lastProcessorSummary"] = {
        "attempted" => results.length,
        "completed" => results.count { |result| result["ok"] },
        "failed" => results.count { |result| !result["ok"] },
        "trigger" => trigger
      }
    end

    {
      "attempted" => results.length,
      "results" => results
    }
  end

  def send_task(lead_id, step_id, trigger: "manual")
    snapshot = @store.snapshot
    lead = find_lead!(snapshot, lead_id)
    step = find_step!(snapshot, step_id)
    task = QueueBuilder.new(snapshot).task_for(lead_id, step_id)
    raise "Task is not ready to send." unless task && task["canSendNow"]

    drafts = TemplateRenderer.new(snapshot["templates"], snapshot["settings"]).drafts_for(lead)
    system = snapshot.dig("settings", "system")
    mode = system["deliveryMode"]

    delivery =
      if mode == "dry_run"
        {
          "provider" => "dry_run",
          "reference" => "dry-#{Support.uuid}",
          "raw" => { "message" => "Simulated send in dry_run mode." }
        }
      else
        deliver_live(snapshot["settings"], lead, step["channel"], drafts)
      end

    log_delivery_result(lead_id, step_id, trigger: trigger, mode: mode, delivery: delivery, success: true)
    {
      "ok" => true,
      "leadId" => lead_id,
      "stepId" => step_id,
      "provider" => delivery["provider"],
      "reference" => delivery["reference"]
    }
  rescue StandardError => error
    log_delivery_result(lead_id, step_id, trigger: trigger, mode: snapshot.dig("settings", "system", "deliveryMode"), error: error.message, success: false) if lead_id && step_id
    {
      "ok" => false,
      "leadId" => lead_id,
      "stepId" => step_id,
      "error" => error.message
    }
  end

  def process_text_opt_out(phone:, body:)
    phone_key = Support.normalize_phone(phone)
    message = body.to_s.downcase
    matched = !phone_key.nil? && message.match?(/\b(stop|unsubscribe|end|cancel|quit)\b/)
    return { "matched" => false, "updated" => 0 } unless matched

    updated = 0
    @store.update do |state|
      state["leads"].each do |lead|
        next unless Support.normalize_phone(lead["phone"]) == phone_key

        lead["suppressions"]["text"] = true
        lead["updatedAt"] = Support.iso_now
        updated += 1
      end
    end

    { "matched" => true, "updated" => updated }
  end

  def process_email_opt_out(email:)
    target = Support.normalize_email(email)
    return { "updated" => 0 } if target.empty?

    updated = 0
    @store.update do |state|
      state["leads"].each do |lead|
        next unless Support.normalize_email(lead["email"]) == target

        lead["suppressions"]["email"] = true
        lead["updatedAt"] = Support.iso_now
        updated += 1
      end
    end

    { "updated" => updated }
  end

  def crm_export_csv
    snapshot = @store.snapshot
    rows = crm_rows(snapshot)
    return "" if rows.empty?

    CSV.generate do |csv|
      csv << rows.first.keys
      rows.each { |row| csv << row.values }
    end
  end

  def sync_crm_webhook
    snapshot = @store.snapshot
    system = snapshot.dig("settings", "system")
    webhook_url = system["crmWebhookUrl"].to_s.strip
    raise "Add a CRM webhook URL first." if webhook_url.empty?

    uri = URI(webhook_url)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request["User-Agent"] = "CloseCircleSellerOutreach/1.0"
    token = system["crmWebhookToken"].to_s.strip
    request["Authorization"] = "Bearer #{token}" unless token.empty?
    request["X-CRM-Token"] = token unless token.empty?
    request.body = JSON.generate(
      {
        "source" => "seller-outreach-system",
        "crmName" => system["crmName"],
        "generatedAt" => Support.iso_now,
        "leadCount" => snapshot["leads"].length,
        "leads" => crm_rows(snapshot)
      }
    )

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.request(request)
    end

    unless response.code.to_i.between?(200, 299)
      raise "CRM webhook returned #{response.code}: #{response.body.to_s[0, 300]}"
    end

    log_crm_sync(snapshot["leads"].length, system["crmName"], webhook_url)
    {
      "ok" => true,
      "synced" => snapshot["leads"].length,
      "status" => response.code.to_i
    }
  end

  private

  def crm_rows(snapshot)
    queue_by_lead = QueueBuilder.new(snapshot).tasks.group_by { |task| task["leadId"] }
    snapshot["leads"].map do |lead|
      tasks = queue_by_lead.fetch(lead["id"], [])
      next_task = tasks.find { |task| %w[pending approved failed].include?(task["status"]) }
      completed_count = tasks.count { |task| task["status"] == "completed" }

      {
        "external_id" => lead["id"],
        "first_name" => lead["firstName"],
        "last_name" => lead["lastName"],
        "full_name" => Support.lead_name(lead),
        "property_address" => lead["propertyAddress"],
        "mailing_address" => lead["mailingAddress"],
        "phone" => lead["phone"],
        "email" => lead["email"],
        "lead_status" => lead["status"],
        "notes" => lead["notes"],
        "sequence_start_date" => lead["sequenceStartDate"],
        "text_enabled" => lead.dig("channelPreferences", "text"),
        "email_enabled" => lead.dig("channelPreferences", "email"),
        "mail_enabled" => lead.dig("channelPreferences", "mail"),
        "text_suppressed" => lead.dig("suppressions", "text"),
        "email_suppressed" => lead.dig("suppressions", "email"),
        "mail_suppressed" => lead.dig("suppressions", "mail"),
        "next_action" => next_task ? next_task["label"] : "",
        "next_channel" => next_task ? next_task["channel"] : "",
        "next_due_date" => next_task ? next_task["dueDate"] : "",
        "next_task_status" => next_task ? next_task["status"] : "",
        "completed_steps" => completed_count,
        "updated_at" => lead["updatedAt"],
        "created_at" => lead["createdAt"]
      }
    end
  end

  def log_crm_sync(count, crm_name, webhook_url)
    @store.update do |state|
      state["activityLog"].unshift(
        {
          "id" => Support.uuid,
          "timestamp" => Support.iso_now,
          "leadId" => nil,
          "leadName" => "CRM Sync",
          "stepId" => nil,
          "channel" => "crm",
          "status" => "completed",
          "provider" => crm_name.to_s.empty? ? "webhook" : crm_name,
          "message" => "Synced #{count} lead#{count == 1 ? "" : "s"} to #{crm_name.to_s.empty? ? webhook_url : crm_name}."
        }
      )
      state["activityLog"] = state["activityLog"].first(100)
    end
  end

  def provider_for(channel, settings)
    system = settings.fetch("system")
    case channel
    when "text"
      system["textProvider"]
    when "email"
      system["emailProvider"]
    when "mail"
      system["mailProvider"]
    else
      "unknown"
    end
  end

  def deliver_live(settings, lead, channel, drafts)
    case provider_for(channel, settings)
    when "manual_google_voice"
      ManualGoogleVoiceAdapter.new(settings).deliver(to: lead["phone"], body: drafts["text"])
    when "twilio"
      TwilioAdapter.new(settings).deliver(to: lead["phone"], body: drafts["text"])
    when "gmail_smtp"
      GmailSmtpAdapter.new(settings).deliver(to: lead["email"], subject: drafts["emailSubject"], text: drafts["emailBody"])
    when "manual_gmail"
      ManualGmailAdapter.new(settings).deliver(to: lead["email"], subject: drafts["emailSubject"], text: drafts["emailBody"])
    when "resend"
      ResendAdapter.new(settings).deliver(to: lead["email"], subject: drafts["emailSubject"], text: drafts["emailBody"])
    when "manual_print"
      ManualPrintAdapter.new(settings).deliver(to_name: Support.lead_name(lead), to_address_line: lead["mailingAddress"], letter_text: drafts["letter"])
    when "lob"
      LobAdapter.new(settings).deliver(to_name: Support.lead_name(lead), to_address_line: lead["mailingAddress"], letter_text: drafts["letter"])
    else
      raise "Unknown provider for #{channel}."
    end
  end

  def log_delivery_result(lead_id, step_id, trigger:, mode:, delivery: nil, error: nil, success:)
    @store.update do |state|
      lead = find_lead!(state, lead_id)
      step = find_step!(state, step_id)
      outreach = lead["outreach"][step_id] ||= {}

      outreach["lastAttemptAt"] = Support.iso_now
      outreach["lastTrigger"] = trigger
      outreach["deliveryMode"] = mode

      if success
        outreach["status"] = "completed"
        outreach["completedAt"] = Support.iso_now
        outreach["provider"] = delivery["provider"]
        outreach["providerReference"] = delivery["reference"]
        outreach.delete("lastError")
      else
        outreach["status"] = "failed"
        outreach["lastError"] = error
      end

      lead["updatedAt"] = Support.iso_now
      state["activityLog"].unshift(
        {
          "id" => Support.uuid,
          "timestamp" => Support.iso_now,
          "leadId" => lead["id"],
          "leadName" => Support.lead_name(lead),
          "stepId" => step_id,
          "channel" => step["channel"],
          "status" => success ? "completed" : "failed",
          "provider" => delivery ? delivery["provider"] : nil,
          "message" => success ? Support.event_message(step["channel"], Support.lead_name(lead), "completed", delivery["provider"]) : error
        }
      )
      state["activityLog"] = state["activityLog"].first(100)
    end
  end

  def find_lead!(state, lead_id)
    state["leads"].find { |lead| lead["id"] == lead_id } || raise("Lead not found.")
  end

  def find_step!(state, step_id)
    state["sequence"].find { |step| step["id"] == step_id } || raise("Sequence step not found.")
  end
end

class StateSerializer
  def initialize(state)
    @state = state
  end

  def as_json
    renderer = TemplateRenderer.new(@state["templates"], @state["settings"])
    {
      "templates" => @state["templates"],
      "sequence" => @state["sequence"],
      "settings" => @state["settings"],
      "runtime" => @state["runtime"],
      "providerStatus" => provider_status,
      "leads" => @state["leads"].map { |lead| serialize_lead(lead, renderer) },
      "queue" => QueueBuilder.new(@state).tasks,
      "activityLog" => @state["activityLog"].first(40)
    }
  end

  private

  def serialize_lead(lead, renderer)
    payload = Support.deep_copy(lead)
    payload["drafts"] = renderer.drafts_for(lead)
    payload["mailingAddressParsed"] = !AddressParser.parse_us_single_line(lead["mailingAddress"], name: Support.lead_name(lead)).nil?
    payload
  end

  def provider_status
    settings = @state["settings"]
    {
      "manualGmail" => ManualGmailAdapter.new(settings).status,
      "googleVoice" => ManualGoogleVoiceAdapter.new(settings).status,
      "gmailSmtp" => GmailSmtpAdapter.new(settings).status,
      "manualMail" => ManualPrintAdapter.new(settings).status,
      "twilio" => TwilioAdapter.new(settings).status,
      "resend" => ResendAdapter.new(settings).status,
      "lob" => LobAdapter.new(settings).status
    }
  end
end

class ApiServlet < WEBrick::HTTPServlet::AbstractServlet
  def initialize(server, store, engine, access_control)
    super(server)
    @store = store
    @engine = engine
    @access_control = access_control
  end

  def do_GET(request, response)
    route(request, response)
  end

  def do_POST(request, response)
    route(request, response)
  end

  def do_PUT(request, response)
    route(request, response)
  end

  def do_DELETE(request, response)
    route(request, response)
  end

  private

  def route(request, response)
    path = request.path
    body = parsed_body(request)

    if [request.request_method, path] == ["GET", "/api/health"]
      return json(response, { "ok" => true, "timestamp" => Support.iso_now })
    end

    if [request.request_method, path] == ["POST", "/api/auth/login"]
      success = @access_control.login(body["accessCode"], response)
      return json(response, success ? { "ok" => true } : { "error" => "Invalid access code." }, status: success ? 200 : 401)
    end

    if [request.request_method, path] == ["POST", "/api/auth/logout"]
      @access_control.logout(request, response)
      return json(response, { "ok" => true })
    end

    if [request.request_method, path] == ["GET", "/api/auth/status"]
      return json(response, { "authenticated" => @access_control.authenticated?(request) })
    end

    unless authorized_path?(path) || @access_control.authenticated?(request)
      return json(response, { "error" => "Access code required." }, status: 401)
    end

    case [request.request_method, path]
    when ["GET", "/api/state"]
      json(response, StateSerializer.new(@store.snapshot).as_json)
    when ["POST", "/api/leads"]
      @engine.upsert_lead(body)
      json(response, StateSerializer.new(@store.snapshot).as_json)
    when ["POST", "/api/import/csv"]
      count = @engine.import_csv(body["csvText"].to_s)
      json(response, StateSerializer.new(@store.snapshot).as_json.merge("meta" => { "imported" => count }))
    when ["PUT", "/api/settings/templates"]
      @engine.update_templates(body["templates"])
      json(response, StateSerializer.new(@store.snapshot).as_json)
    when ["PUT", "/api/settings/sequence"]
      @engine.update_sequence(body["sequence"])
      json(response, StateSerializer.new(@store.snapshot).as_json)
    when ["PUT", "/api/settings/system"]
      @engine.update_system_settings(body["system"])
      json(response, StateSerializer.new(@store.snapshot).as_json)
    when ["POST", "/api/queue/process_due"]
      result = @engine.process_due(trigger: "manual")
      json(response, StateSerializer.new(@store.snapshot).as_json.merge("meta" => result))
    when ["GET", "/api/crm/export.csv"]
      csv(response, @engine.crm_export_csv, filename: "seller-crm-export-#{Support.today_iso}.csv")
    when ["POST", "/api/crm/sync"]
      result = @engine.sync_crm_webhook
      json(response, StateSerializer.new(@store.snapshot).as_json.merge("meta" => result))
    when ["POST", "/api/public/unsubscribe/text"]
      result = @engine.process_text_opt_out(phone: body["phone"] || body["From"], body: body["body"] || body["Body"])
      json(response, result)
    when ["POST", "/api/public/unsubscribe/email"]
      result = @engine.process_email_opt_out(email: body["email"])
      json(response, result)
    else
      route_dynamic(request, response, path, body)
    end
  rescue StandardError => error
    json(response, { "error" => error.message }, status: 422)
  end

  def authorized_path?(path)
    path == "/api/public/unsubscribe/text" || path == "/api/public/unsubscribe/email"
  end

  def route_dynamic(request, response, path, body)
    if request.request_method == "PUT" && path.match(%r{\A/api/leads/([^/]+)\z})
      lead_id = Regexp.last_match(1)
      @engine.upsert_lead(body, id: lead_id)
      return json(response, StateSerializer.new(@store.snapshot).as_json)
    end

    if request.request_method == "DELETE" && path.match(%r{\A/api/leads/([^/]+)\z})
      lead_id = Regexp.last_match(1)
      @engine.delete_lead(lead_id)
      return json(response, StateSerializer.new(@store.snapshot).as_json)
    end

    if request.request_method == "POST" && path.match(%r{\A/api/leads/([^/]+)/suppressions\z})
      lead_id = Regexp.last_match(1)
      @engine.update_suppression(lead_id, body["channel"], body["suppressed"])
      return json(response, StateSerializer.new(@store.snapshot).as_json)
    end

    if request.request_method == "POST" && path.match(%r{\A/api/leads/([^/]+)/channel-preferences\z})
      lead_id = Regexp.last_match(1)
      @engine.update_channel_preference(lead_id, body["channel"], body["enabled"])
      return json(response, StateSerializer.new(@store.snapshot).as_json)
    end

    if request.request_method == "POST" && path.match(%r{\A/api/outreach/([^/]+)/([^/]+)/approve\z})
      lead_id = Regexp.last_match(1)
      step_id = Regexp.last_match(2)
      @engine.approve_task(lead_id, step_id)
      return json(response, StateSerializer.new(@store.snapshot).as_json)
    end

    if request.request_method == "POST" && path.match(%r{\A/api/outreach/([^/]+)/([^/]+)/send\z})
      lead_id = Regexp.last_match(1)
      step_id = Regexp.last_match(2)
      result = @engine.send_task(lead_id, step_id, trigger: "manual")
      return json(response, StateSerializer.new(@store.snapshot).as_json.merge("meta" => result))
    end

    if request.request_method == "POST" && path.match(%r{\A/api/outreach/([^/]+)/([^/]+)/skip\z})
      lead_id = Regexp.last_match(1)
      step_id = Regexp.last_match(2)
      @engine.skip_task(lead_id, step_id)
      return json(response, StateSerializer.new(@store.snapshot).as_json)
    end

    if request.request_method == "POST" && path.match(%r{\A/api/outreach/([^/]+)/([^/]+)/reset\z})
      lead_id = Regexp.last_match(1)
      step_id = Regexp.last_match(2)
      @engine.reset_task(lead_id, step_id)
      return json(response, StateSerializer.new(@store.snapshot).as_json)
    end

    json(response, { "error" => "Route not found." }, status: 404)
  end

  def parsed_body(request)
    return {} if request.body.nil? || request.body.empty?

    if request.content_type.to_s.include?("application/json")
      JSON.parse(request.body)
    else
      request.query.transform_values do |value|
        value.is_a?(Array) && value.length == 1 ? value.first : value
      end
    end
  rescue JSON::ParserError
    {}
  end

  def json(response, payload, status: 200)
    response.status = status
    response["Content-Type"] = "application/json"
    response.body = JSON.generate(payload)
  end

  def csv(response, payload, filename:)
    response.status = 200
    response["Content-Type"] = "text/csv; charset=utf-8"
    response["Content-Disposition"] = %(attachment; filename="#{filename}")
    response.body = payload
  end
end

store = DataStore.new(DATA_PATH)
engine = DeliveryEngine.new(store)
access_control = AccessControl.new(ENV.fetch("APP_ACCESS_CODE", ""))

processor = Thread.new do
  loop do
    snapshot = store.snapshot
    if snapshot.dig("settings", "system", "autoSendEnabled")
      begin
        engine.process_due(trigger: "automatic")
      rescue StandardError => error
        warn("Automatic send cycle failed: #{error.message}")
      end
    end

    sleep(snapshot.dig("settings", "system", "pollIntervalSeconds") || 60)
  end
end

port = Integer(ENV.fetch("PORT", "4567"))
host = ENV.fetch("HOST", "0.0.0.0")
server = WEBrick::HTTPServer.new(
  BindAddress: host,
  Port: port,
  DocumentRoot: ROOT,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO)
)
server.mount("/api", ApiServlet, store, engine, access_control)
trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

display_host = host == "0.0.0.0" ? "localhost" : host
warn("Seller Outreach System running at http://#{display_host}:#{port}")
server.start
processor.kill
