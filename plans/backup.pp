# @summary Backup the core user settings for puppet infrastructure
#
# This plan can backup data as outlined at insert doc
# 
plan peadm::backup (
  Peadm::SingleTargetSpec $primary_host,

  # Which data to backup
  Boolean                 $backup_orchestrator    = true,
  Boolean                 $backup_rbac            = true,
  Boolean                 $backup_activity        = true,
  Boolean                 $backup_ca_ssl          = true,
  Boolean                 $backup_puppetdb        = false,
  Boolean                 $backup_classification  = true,
  String                  $output_directory       = '/tmp',
) {
  peadm::assert_supported_bolt_version()
  $cluster = run_task('peadm::get_peadm_config', $primary_host).first.value
  $arch = peadm::assert_supported_architecture(
    $primary_host,
    $cluster['params']['replica_host'],
    $cluster['params']['primary_postgresql_host'],
    $cluster['params']['replica_postgresql_host'],
    $cluster['params']['compiler_hosts'],
  )
  $primary_postgresql_host = $cluster['params']['primary_postgresql_host']
  # I need the actual hostname for the certificate in a remote puppetdb backup. If a user sends primary host as IP it will fail
  $primary_host_fqdn = $cluster['params']['primary_host']
  $timestamp = Timestamp.new().strftime('%F_%T')
  $backup_directory = "${output_directory}/pe-backup-${timestamp}"
# This is a workaround to deal with the permissions requiring us to allow pg dump to run as pe-postgres and pe-puppetdb but not wanting to
# leave permissions open on the backup. A temporary directory is created for the dump and then the dumps are move into the main backup at
# which point this directory is removed
  $database_backup_directory = "${output_directory}/pe-backup-databases-${timestamp}"
  # Create backup folder
  apply($primary_host){
    file { $backup_directory :
      ensure => 'directory',
      owner  => 'root',
      group  => 'root',
      mode   => '0770'
    }
    file { $database_backup_directory :
      ensure => 'directory',
      owner  => 'pe-puppetdb',
      group  => 'pe-postgres',
      mode   => '0770'
    }
  }

  # Create an array of the names of databases and whether they have to be backed up to use in a lambda later
  $database_to_backup = [ $backup_orchestrator, $backup_activity, $backup_rbac, $backup_puppetdb]
  $database_names     = [ 'pe-orchestrator' , 'pe-activity' , 'pe-rbac' , 'pe-puppetdb' ]

  if $backup_classification {
    out::message('# Backing up classification')
    run_task('peadm::backup_classification', $primary_host,
    directory => $backup_directory,
    )
  }

  if $backup_ca_ssl {
    out::message('# Backing up ca and ssl certificates')
    run_command("/opt/puppetlabs/bin/puppet-backup create --dir=${backup_directory} --scope=certs", $primary_host)
  }

  # Check if /etc/puppetlabs/console-services/conf.d/secrets/keys.json exists and if so back it up
  out::message('# Backing up ldap secret key if it exists')
  run_command("test -f /etc/puppetlabs/console-services/conf.d/secrets/keys.json && cp -rp /etc/puppetlabs/console-services/conf.d/secrets/keys.json ${backup_directory} || echo secret ldap key doesnt exist" , $primary_host) # lint:ignore:140chars

  # IF backing up orchestrator back up the secrets too /etc/puppetlabs/orchestration-services/conf.d/secrets/
  if $backup_orchestrator {
    out::message('# Backing up orchestrator secret keys')
    run_command("cp -rp /etc/puppetlabs/orchestration-services/conf.d/secrets ${backup_directory}/", $primary_host)
  }

  $database_to_backup.each |Integer $index, Boolean $value | {
    if $value {
    out::message("# Backing up database ${database_names[$index]}")
      # If the primary postgresql host is set then pe-puppetdb needs to be remotely backed up to primary.
      if $database_names[$index] == 'pe-puppetdb' and $primary_postgresql_host {
        run_command("/opt/puppetlabs/server/bin/pg_dump \"sslmode=verify-ca host=${primary_postgresql_host} user=pe-puppetdb sslcert=/etc/puppetlabs/puppetdb/ssl/${primary_host_fqdn}.cert.pem sslkey=/etc/puppetlabs/puppetdb/ssl/${primary_host_fqdn}.private_key.pem sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem dbname=pe-puppetdb\" -Fd -Z3 -j4 -f ${backup_directory}/puppetdb_$(date +%F_%T)" , $primary_host) # lint:ignore:140chars
      } else {
        run_command("sudo -u pe-postgres /opt/puppetlabs/server/bin/pg_dump -Fd -Z3 -j4 \"${database_names[$index]}\" -f \"${database_backup_directory}/${database_names[$index]}_$(date +%F_%T)\"" , $primary_host) # lint:ignore:140chars
        run_command("mv \"${database_backup_directory}/${database_names[$index]}*\" \'${backup_directory}/\'", $primary_host )
      }
    }
  }

    apply($primary_host){
    file { $database_backup_directory :
      ensure => 'absent',
      force  => true
    }
  }
}
