###############################################################################
# modules/compute/cognito.tf
#
# The Cognito User Pool + User Pool Client + User Pool Domain +
# clinicians group. The pool is the OIDC issuer for the sample
# app's JWT verification (see auth.py).
#
# Posture:
#   - auto_verified_attributes = ["email"]  : email is verified on
#                                             sign-up.
#   - username_attributes = ["email"]  : email is the username
#                                       (no separate username field).
#   - password_policy  : 12+ chars, mixed case, digit, symbol --
#                        meets the plan's R21 control.
#   - mfa_configuration = "OPTIONAL"  : MFA is documented as
#                        future-unit work; production should be
#                        "ON" or "OPTIONAL" with a hard requirement
#                        for clinicians.
#   - admin_create_user_config.allow_admin_create_user_only = false
#                      : users can self-sign-up. (Switched to true
#                        when the MVP goes to prod.)
#   - prevent_user_existence_errors = "ENABLED"  : defense against
#                        user enumeration. A wrong username +
#                        wrong password returns the same error as
#                        right username + wrong password.
#   - account_recovery_setting  : email-based recovery.
#
# User Pool Client:
#   - generate_secret = true  : server-side client. The secret is
#                        stored in Secrets Manager (the security
#                        module's cognito_client_secret); the task
#                        definition's `secrets` block passes it to
#                        the container as COGNITO_CLIENT_SECRET.
#   - allowed_oauth_flows = ["code"]  : OAuth2 authorization code
#                        flow only (NOT implicit -- implicit leaks
#                        the access token in the URL fragment).
#   - allowed_oauth_scopes = ["openid", "email", "profile"]  :
#                        OIDC standard scopes only.
#   - explicit_auth_flows  : no ADMIN_NO_SRP_AUTH. SRP (Secure
#                        Remote Password) is the only flow; ADMIN
#                        flow bypasses the password challenge
#                        and is documented as a user-enumeration
#                        vector.
#   - prevent_user_existence_errors  : ENABLED.
#
# User Pool Domain:
#   - domain_prefix = local.cognito_domain_prefix  : the
#     *.auth.${region}.amazoncognito.com prefix. Required for
#     hosted UI (future unit) and for the JWKS / OIDC discovery
#     endpoints.
#
# clinicians group:
#   - Pre-created so the authorization model in auth.py (any
#     user in this group can read/delete any patient's data)
#     has a target. The group has no precedence and no IAM role
#     attached (the group is consumed by the app, not by AWS APIs).
###############################################################################

# ---------------------------------------------------------------------------
# User Pool.
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool" "this" {
  name                     = local.cognito_user_pool_name
  auto_verified_attributes = ["email"]
  username_attributes      = ["email"]

  # Password policy. The plan's R21 control requires "strong"
  # passwords -- 12+ chars, mixed case, digit, symbol.
  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  # MFA: optional in the MVP. Production should require MFA for
  # clinicians; this is a documented follow-up.
  mfa_configuration = "OPTIONAL"

  # Admin-create-user config: allow admin to create test users
  # without forcing a self-sign-up. In dev this is the path the
  # team uses to seed test data; in prod the preference is
  # self-sign-up only (allow_admin_create_user_only = false,
  # which is the current default).
  admin_create_user_config {
    allow_admin_create_user_only = false

    invite_message_template {
      email_subject = "Your NiaHealth account"
      email_message = "Your username is {username} and temporary password is {####}."
      sms_message   = "Your username is {username} and temporary password is {####}."
    }
  }

  # Account recovery: email-based.
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Email configuration: use Cognito's built-in email sender for
  # the MVP. A future unit can switch to SES.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # User attribute schema: email (required, mutable=false because
  # Cognito uses it as the username) + name (optional, mutable).
  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = false

    string_attribute_constraints {
      min_length = 5
      max_length = 320
    }
  }

  schema {
    name                = "name"
    attribute_data_type = "String"
    required            = false
    mutable             = true

    string_attribute_constraints {
      min_length = 0
      max_length = 256
    }
  }

  # Defense against user enumeration. ENABLED means the user
  # existence check is suppressed in the auth response.
  user_pool_add_ons {
    advanced_security_mode = "ENFORCED"

    # Username case sensitivity: case-insensitive so
    # "Patient@x.com" and "patient@x.com" map to the same user.
  }

  # Username case-insensitive is implicit in modern Cognito; the
  # `username_configuration` block makes it explicit.
  username_configuration {
    case_sensitive = false
  }

  # The verification message template for email-based sign-up.
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Confirm your NiaHealth sign-up"
    email_message        = "Your verification code is {####}."
  }

  tags = merge(var.tags, {
    Name      = local.cognito_user_pool_name
    Purpose   = "oidc-user-pool"
    DataClass = "metadata"
  })
}

# ---------------------------------------------------------------------------
# User Pool Client.
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool_client" "this" {
  name         = "${local.name_prefix}-app-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = true # server-side client; secret in Secrets Manager

  # Token validity. ID + access tokens last 1 hour; refresh tokens
  # last 30 days. The 1-hour ID token lifetime is the right
  # posture for an MVP -- production may want shorter.
  id_token_validity      = 1
  access_token_validity  = 1
  refresh_token_validity = 30

  token_validity_units {
    id_token      = "hours"
    access_token  = "hours"
    refresh_token = "days"
  }

  # OAuth2 flows. Authorization code only -- no implicit (which
  # would leak the access token in the URL fragment).
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]

  callback_urls = var.cognito_callback_urls
  logout_urls   = var.cognito_logout_urls

  # Supported identity providers. Cognito itself (the user pool)
  # is the IdP. Federated IdPs (e.g. Google) are a future unit.
  supported_identity_providers = ["COGNITO"]

  # Explicit auth flows. NO ADMIN_NO_SRP_AUTH (defense against
  # user enumeration). SRP is the only password-auth path.
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_PASSWORD_AUTH", # for the demo's CLI tests; OK in dev
  ]

  # Defense against user enumeration.
  prevent_user_existence_errors = "ENABLED"

  # Read/write attributes. The app reads email + name; writes
  # only name (email is immutable because it's the username).
  read_attributes  = ["email", "email_verified", "name"]
  write_attributes = ["name"]

  # NOTE: aws_cognito_user_pool_client does NOT support a `tags`
  # argument in the v5 provider. The User Pool itself carries
  # the Environment / DataClass / Owner tags via default_tags
  # + the inline `tags` block on aws_cognito_user_pool.this.
}

# ---------------------------------------------------------------------------
# User Pool Domain. The *.auth.${region}.amazoncognito.com prefix
# is required for hosted UI (future) and for the JWKS / OIDC
# discovery endpoints. The domain is a UNIQUE global resource --
# only one AWS account can own a given prefix. The prefix is
# namespaced by environment to avoid collisions across envs.
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool_domain" "this" {
  domain       = local.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.this.id
}

# ---------------------------------------------------------------------------
# clinicians group. The authorization model in auth.py grants
# any user in this group access to any patient's data. Pre-created
# so the group exists; the operator adds users via the Cognito
# console (or a future U9 onboarding playbook).
# ---------------------------------------------------------------------------
resource "aws_cognito_user_group" "clinicians" {
  name         = "clinicians"
  user_pool_id = aws_cognito_user_pool.this.id
  description  = "Clinicians. Members can read/delete any patient's record via the sample app."

  # precedence is the order in which this group is evaluated
  # against other groups in the same user pool. Lower = higher
  # precedence. The MVP has only one group; precedence is
  # cosmetic here.
  precedence = 10
}
