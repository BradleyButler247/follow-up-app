# Seller Outreach System

This project is now a backend-powered local app for managing seller outreach across text, email, and direct mail.
It is preconfigured around your current stack:

- Gmail as a manual compose workflow
- Google Voice as a manual texting workflow
- Printable/manual direct mail

## What it does

- Stores sellers in a local JSON data store
- Generates personalized text, email, and mail drafts from editable templates
- Runs a follow-up sequence with per-step approval, skip, reset, and send actions
- Supports `dry_run` mode and `live` mode
- Tracks suppression status per lead and channel
- Exports working CSV queues and JSON backups
- Exports a CRM-ready seller CSV
- Syncs leads to a generic CRM webhook
- Includes manual Gmail compose, Google Voice manual workflow, printable mail workflow, and optional Gmail SMTP, Twilio, Resend, and Lob adapters

## Run the app

1. Start the server:

```bash
ruby server.rb
```

2. Open [http://localhost:4567](http://localhost:4567).

## Share with teammates

The app has a shared access code in `.env`:

```bash
APP_ACCESS_CODE=CCI-9J4M-7P2K
```

If your teammate is on the same Wi-Fi or office network:

1. Keep the server running on your computer.
2. Find your local IP:

```bash
ipconfig getifaddr en0
```

3. Have them open:

```text
http://YOUR_LOCAL_IP:4567
```

4. Give them the access code.

For teammates outside your network, host it on a private server or use a secure tunnel such as Cloudflare Tunnel. Keep the access code private.

## CRM options

The app now supports two CRM paths:

- `Export CRM CSV`: downloads a CRM-ready lead file with owner, property, contact, suppression, next-action, and status fields.
- `Sync CRM webhook`: posts all leads as JSON to a CRM, Zapier, Make, or other webhook URL.

To use webhook sync:

1. Paste the CRM or automation webhook URL into `CRM webhook URL`.
2. Add an optional token if your CRM or automation asks for one.
3. Save settings.
4. Click `Sync CRM webhook`.

If your CRM has no webhook intake, use `Export CRM CSV` and import that file into the CRM.

## Fastest setup for your current stack

### Gmail manual email

No password is required for immediate use.
The app will:

- generate the email
- let you copy it
- open a Gmail compose tab with the recipient, subject, and body filled in
- let you mark the queue step complete after sending

### Google Voice texting

Google Voice is also set up as a manual workflow.
The app will:

- generate the text
- let you copy it
- let you mark the queue step complete after sending it in Google Voice

The app is already prefilled with:

- Gmail address: `wilson@closecircleinvest.com`
- Company name: `Close Circle Investments`
- Business phone: `(970) 833-1256`
- Return address: `3006 Zuni St, Denver, CO 80211`

Google’s help says Google Voice is not intended for bulk messaging:

- [Google Voice Help](https://support.google.com/voice/answer/115116?hl=en&co=GENIE.Platform%3DDesktop)

### Direct mail

For now, direct mail is a manual print/export workflow.
Seller mailing addresses should ideally look like:

```text
123 Main St, Denver, CO 80205
```

### Optional later upgrades

If you later want more automation, the app still supports:

- Gmail SMTP with an app password
- Twilio for SMS
- Resend for email
- Lob for direct mail

Those remain optional.

## Safety defaults

- Delivery mode defaults to `dry_run`
- Manual approval defaults to `required`
- Auto send defaults to `off`
- Per-lead suppression can be toggled for text, email, and mail

## CSV import

Required headers:

- `firstName`
- `lastName`
- `propertyAddress`

Optional headers:

- `mailingAddress`
- `phone`
- `email`
- `notes`
- `status`
- `sequenceStartDate`

If a field contains commas, wrap it in quotes.

Example:

```csv
firstName,lastName,propertyAddress,mailingAddress,phone,email,notes
Sarah,Nguyen,"123 Oak St, Denver, CO 80205","123 Oak St, Denver, CO 80205",3035550101,sarah@example.com,Inherited property
```

## Public opt-out endpoints

These are ready for future webhook wiring:

- `POST /api/public/unsubscribe/text`
- `POST /api/public/unsubscribe/email`

The text opt-out endpoint accepts Twilio-style fields like `From` and `Body`.

## Important notes

- This app is designed for local or private internal use and now includes a shared access code.
- Before using live outreach, verify your process against the rules that apply to your market, channel, consent practices, and suppression handling.
- Gmail also has sending limits, so use it for controlled outreach rather than mass blasting:
  [Gmail sending limits](https://support.google.com/mail/answer/22839)
# follow-up-app
