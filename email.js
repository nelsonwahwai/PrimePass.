one// ── Email Service (Stub) ─────────────────────────────────────────────────────
// In production, integrate with SendGrid, SES, Mailgun, or SMTP.
// This stub logs emails to console for development.

async function sendEmail({ to, subject, html, text }) {
  const logEntry = `📧 EMAIL to: ${to} | subject: ${subject}`;
  console.log(logEntry);

  // In production, replace with actual email API call:
  // const sgMail = require('@sendgrid/mail');
  // sgMail.setApiKey(process.env.SENDGRID_API_KEY);
  // await sgMail.send({ to, from: 'noreply@primepass.com', subject, html });

  // For dev, log the content length instead of full HTML
  console.log(`   HTML length: ${(html || '').length} chars | Text length: ${(text || '').length} chars`);
  console.log(`   Email logged — no actual send in dev mode.`);

  return { success: true, messageId: `stub-${Date.now()}` };
}

module.exports = { sendEmail };

