# bento backup — supercronic crontab template.
# Rendered by entrypoint.sh from /etc/supercronic/crontab.tpl by substituting
# ${BACKUP_CRON} from the container env.

${BACKUP_CRON} /usr/local/bin/backup.sh
