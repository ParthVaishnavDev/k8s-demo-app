#!/bin/sh
cat <<CONFIG > /usr/share/nginx/html/config.json
{
  "appName": "$APP_NAME",
  "appVersion": "$APP_VERSION",
  "environment": "$ENVIRONMENT"
}
CONFIG
exec nginx -g "daemon off;"
