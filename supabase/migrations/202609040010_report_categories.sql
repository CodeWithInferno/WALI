-- Preserve the distinct report categories already offered by the native app.
alter type wali.report_kind add value if not exists 'trademark';
alter type wali.report_kind add value if not exists 'technical_issue';
