# @summary Restore the core user settings for puppet infrastructure from backup
#
# This plan can restore data to puppet infrastructure for DR and rebuilds
# 
plan peadm::restore (
  # Standard
  Peadm::SingleTargetSpec           $primary_host,
  # Which data to restore
  Boolean                            $restore_orchestrator    = true,
  Boolean                            $restore_rbac            = true,
  Boolean                            $restore_activity        = true,
  Boolean                            $restore_ca_ssl          = true,
  Boolean                            $restore_puppetdb        = false,
  Boolean                            $restore_classification  = true,
  String                             $input_directory         = '/tmp',
  String                             $working_directory       = '/tmp',
  String                             $backup_timestamp,
){
  peadm::assert_supported_bolt_version()
  $cluster = run_task('peadm::get_peadm_config', $primary_host).first
  $arch = peadm::assert_supported_architecture(
    $primary_host,
    $cluster['replica_host'],
    $cluster['primary_postgresql_host'],
    $cluster['replica_postgresql_host'],
    $cluster['compiler_hosts'],
  )
  $servers = [$primary_host , $cluster['replica_host'] ].filter | $server_hosts | { $server_hosts =~  NotUndef }
  $cluster_servers_undef = $servers + $cluster['compiler_hosts'] + [ $cluster['primary_postgresql_host'], $cluster['replica_postgresql_host']] # lint:ignore:140chars
  $cluster_servers= cluster_servers_undef.filter | $server_hosts | { $server_hosts =~  NotUndef }

  $backup_directory = "${input_directory}/pe-backup-${backup_timestamp}"
  # Check backup exists folder

  # Create an array of the names of databases and whether they have to be backed up to use in a lambda later
  $database_to_restore = [ $restore_orchestrator, $restore_activity, $restore_rbac, $restore_puppetdb]
  $database_names      = [ 'pe-orchestrator' , 'pe-activity' , 'pe-rbac' , 'pe-puppetdb' ]

  peadm::assert_supported_bolt_version()

  if $restore_classification {

    out::message('# Restoring classification')
    run_task('peadm::backup_classification', $primary_host,
      directory => $working_directory
    )
    out::message('# Backed up current classification to ${working_directory}/classification_backup.json')

    run_task('peadm::transform_classification', $primary_host,
      source_directory => $backup_directory,
      working_directory => $working_directory
    )

    run_task('peadm::restore_classification', $primary_host,
    classification_file => "${working_directory}/classification_backup.json",
    )
  }

  if $restore_ca_ssl {
    out::message('# Restoring ca and ssl certificates')
    run_command("/opt/puppetlabs/bin/puppet-backup restore ${backup_directory}/ --scope=certs", $primary_host)
  }

  ## shutdown services Primary and replica
  servers.each | String $host | {
  run_task('service', $host,
    action  => 'stopped',
    service => 'pe-console-services'
  )
    run_task('service', $host,
    action  => 'stopped',
    service => 'pe-nginx'
  )
      run_task('service', $host,
    action  => 'stopped',
    service => 'pe-puppetserver'
  )
      run_task('service', $host,
    action  => 'stopped',
    service => 'pxp-agent'
  )
      run_task('service', $host,
    action  => 'stopped',
    service => 'pe-orchestration-services'
  )
  }
# On every infra server
  cluster_servers.each | String $host | {
        run_task('service', $host,
    action  => 'stopped',
    service => 'puppet'
  )
        run_task('service', $host,
    action  => 'stopped',
    service => 'pe-puppetdb'
  )
  }

  # Restore secrets/keys.json if it exists
  out::message('# Restoring ldap secret key if it exists')
  run_command("test -f ${backup_directory}//keys.json && cp -rp ${backup_directory}/keys.json /etc/puppetlabs/console-services/conf.d/secrets/ || echo secret ldap key doesnt exist" , $primary_host) # lint:ignore:140chars

  # IF restoring orchestrator restore the secrets too /etc/puppetlabs/orchestration-services/conf.d/secrets/
  if $backup_orchestrator {
    out::message('# Restoring orchestrator secret keys')
    run_command("cp -rp ${backup_directory}/secrets/* /etc/puppetlabs/orchestration-services/conf.d/secrets ", $primary_host)
  }

  $database_to_restore.each |Integer $index, Boolean $value | {
    if $value {
    out::message("# Restoring database ${database_names[$index]}")
      # If the primary postgresql host is set then pe-puppetdb needs to be remotely backed up to primary.
      if $database_names[$index] == 'pe-puppetdb' and $primary_postgresql_host {
        # Drop pglogical extensions and schema if present
        run_command("su - pe-postgres -s /bin/bash -c \"/opt/puppetlabs/server/bin/psql --tuples-only -d '${database_names[$index]}' -c 'DROP SCHEMA IF EXISTS pglogical CASCADE;'\"", $primary_postgresql_host) # lint:ignore:140chars
        run_command("su - pe-postgres -s /bin/bash -c \"/opt/puppetlabs/server/bin/psql -d '${database_names[$index]}' -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'\"", $primary_postgresql_host) # lint:ignore:140chars
        # Restore database
        run_command("sudo -u pe-puppetdb /opt/puppetlabs/server/bin/pg_restore -d \"sslmode=verify-ca host=${primary_postgresql_host} sslcert=/etc/puppetlabs/puppetdb/ssl/${primary_host}.cert.pem sslkey=/etc/puppetlabs/puppetdb/ssl/${primary_host}.private_key.pem sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem dbname=pe-puppetdb\" --format template1 ${backup_directory}/puppetdb_*.bin" , $primary_host) # lint:ignore:140chars
        # Drop pglogical extension and schema (again) if present after db restore
        run_command("su - pe-postgres -s'/bin/bash -c \"/opt/puppetlabs/server/bin/psql --tuples-only -d '${database_names[$index]}' -c 'DROP SCHEMA IF EXISTS pglogical CASCADE;'\"",$primary_postgresql_host) # lint:ignore:140chars
        run_command("su - pe-postgres -s /bin/bash -c \"/opt/puppetlabs/server/bin/psql -d '${database_names[$index]}' -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'\"",$primary_postgresql_host) # lint:ignore:140chars
        if $replica_postgresql_host {
          run_task('enterprise_tasks::reinitialize_replica', $replica_postgresql_host,
            database => 'pe-puppetdb'
          )
        }
      } else {
        # Drop pglogical extensions and schema if present
        run_command("su - pe-postgres -s '/bin/bash' -c \"/opt/puppetlabs/server/bin/psql --tuples-only -d '${database_names[$index]}' -c 'DROP SCHEMA IF EXISTS pglogical CASCADE;'\"", $primary_host) # lint:ignore:140chars
        run_command("su - pe-postgres -s /bin/bash -c \"/opt/puppetlabs/server/bin/psql -d '${database_names[$index]}' -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'\"", $primary_host) # lint:ignore:140chars
        # Restore database
        run_command("sudo -u pe-postgres /opt/puppetlabs/server/bin/pg_restore -d ${database_names[$index]} -Cc \"${backup_directory}/${database_names[$index]}_*.bin\"",$primary_host) # lint:ignore:140chars
        # Drop pglogical extension and schema (again) if present after db restore
        run_command("su - pe-postgres -s '/bin/bash' -c \"/opt/puppetlabs/server/bin/psql --tuples-only -d '${database_names[$index]}' -c 'DROP SCHEMA IF EXISTS pglogical CASCADE;'\"",$primary_host) # lint:ignore:140chars
        run_command("su - pe-postgres -s /bin/bash -c \"/opt/puppetlabs/server/bin/psql -d '${database_names[$index]}' -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'\"",$primary_host) # lint:ignore:140chars
        if $replica_primary_host {
          run_task('enterprise_tasks::reinitialize_replica', $replica_primary_host,
            database => $database_names[$index]
          )
        }
      }
    }
  }

  ## Restart services
  ## shutdown services Primary and replica
  servers.each | String $host | {
        run_task('service', $host,
    action  => 'start',
    service => 'pe-orchestration-services'
  )
      run_task('service', $host,
    action  => 'start',
    service => 'pxp-agent'
  )
      run_task('service', $host,
    action  => 'start',
    service => 'pe-puppetserver'
  )
      run_task('service', $host,
    action  => 'start',
    service => 'pe-nginx'
  )
  run_task('service', $host,
    action  => 'start',
    service => 'pe-console-services'
  )
  }
# On every infra server
  cluster_servers.each | String $host | {
        run_task('service', $host,
    action  => 'start',
    service => 'puppet'
  )
        run_task('service', $host,
    action  => 'start',
    service => 'pe-puppetdb'
  )
  }
}
