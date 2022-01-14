#!/bin/sh

# Puppet Task Name: backup_databases

datetime=
sudo -u pe-postgres /opt/puppetlabs/server/bin/pg_dump -Fc "$PT_database" -f "${PT_directory}/${PT_database}_$(date +%Y%m%d%S).bin" || echo "Failed to dump database $PT_database"
echo "${PT_directory}/${PT_database}_$(date +%Y%m%d%S).bin"