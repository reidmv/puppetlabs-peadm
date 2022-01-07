# @summary Backup the core user settings for puppet infrastructure
#
# This plan can backup data as outlined at insert doc 
# 
plan peadm::backup (
  # Standard
  Peadm::SingleTargetSpec           $primary_host,
  Optional[Peadm::SingleTargetSpec] $replica_host            = undef,

  # Large
  Optional[TargetSpec]              $compiler_hosts          = undef,

  # Extra Large
  Optional[Peadm::SingleTargetSpec] $primary_postgresql_host = undef,
  Optional[Peadm::SingleTargetSpec] $replica_postgresql_host = undef,

  # Which data to backup
  Boolean                            $backup_orchestrator    = true,
  Boolean                            $backup_rbac            = true,
  Boolean                            $backup_activity        = true,
  Boolean                            $backup_ca_ssl          = true,
  Boolean                            $backup_puppetdb        = false,
  Boolean                            $backup_classification  = true,
  String                             $output_directory       = '/tmp',
){

  $timestamp = Timestamp.new().strftime('%F_%T')
  $backup_directory = "${output_directory}/pe-backup-${timestamp}"
  # Create backup folder
  apply_prep($primary_host)
  apply($primary_host){
    file { $backup_directory :
      ensure => 'directory',
      owner  => 'root',
      group  => 'pe-postgres',
      mode   => '0770'
    }
  }
  # Create an array of the names of databases and whether they have to be backed up to use in a lambda later
  $database_to_backup = [ $backup_orchestrator, $backup_activity, $backup_rbac, $backup_puppetdb]
  $database_names     = [ 'pe-orchestrator' , 'pe-activity' , 'pe-rbac' , 'pe-puppetdb' ]

  peadm::assert_supported_bolt_version()

  # Ensure input valid for a supported architecture
  $arch = peadm::assert_supported_architecture(
    $primary_host,
    $replica_host,
    $primary_postgresql_host,
    $replica_postgresql_host,
    $compiler_hosts,
  )

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
        run_command("sudo -u pe-puppetdb /opt/puppetlabs/server/bin/pg_dump \"sslmode=verify-ca host=${primary_postgresql_host} sslcert=/etc/puppetlabs/puppetdb/ssl/${primary_host}.cer.pem sslkey=/etc/puppetlabs/puppetdb/ssl/${primary_host}.private_key.pem sslrootcert=/etc/puppetlabs/puppet/ssl/certs/ca.pem dbname=pe-puppetdb\" -f /tmp/puppetdb_$(date +%F_%T).bin || echo \"Failed to dump database puppetdb\"; exit 1" , $primary_host) # lint:ignore:140chars
      } else {
        run_command("sudo -u pe-postgres /opt/puppetlabs/server/bin/pg_dump -Fc \"${database_names[$index]}\" -f \"${backup_directory}/${database_names[$index]}_$(date +%F_%T).bin\" || echo \"Failed to dump database ${database_names[$index]}\"; exit 1" , $primary_host) # lint:ignore:140chars
      }
    }
  }
}
