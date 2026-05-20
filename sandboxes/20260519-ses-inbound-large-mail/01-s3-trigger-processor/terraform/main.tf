module "ses_inbound" {
  source = "../../modules/ses-inbound"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
    aws.us_east_2 = aws.us_east_2
  }

  name   = var.sandbox_name
  region = var.region
  domain = var.domain

  allowed_recipients = var.allowed_recipients
  allow_list_domains = var.allow_list_domains

  enable_killswitch               = true
  killswitch_received_threshold   = var.killswitch_received_threshold
  killswitch_invocation_threshold = var.killswitch_invocation_threshold

  slack_team_id    = var.slack_team_id
  slack_channel_id = var.slack_channel_id
}
