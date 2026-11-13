class trilio::dms::config inherits trilio::dms {
    tag 'dmsconfig'

      $dms_rabbitmq_url = dms_rabbitmq_url($oslomsg_rpc_hosts, $oslomsg_rpc_username, $oslomsg_rpc_password,
                                           $oslomsg_rpc_port, $oslomsg_rpc_use_ssl)
      # Heat may hand these over as strings; ERB treats "false" as true.
      $barbican_ssl_verify_real = str2bool("${barbican_ssl_verify}")
      $rabbitmq_queue_durable_real = str2bool("${rabbitmq_queue_durable}")

      # Global tuning for every s3vaultfuse mount DMS launches. Per-target
      # bucket, endpoint and keys come from Barbican, not from here.
      $s3vaultfuse_defaults = {
        'vault_storage_type'            => 's3',
        'vault_s3_max_pool_connections' => 50,
        'vault_s3_read_timeout'         => 30,
        'vault_s3_max_attempts'         => 3,
        'vault_s3_auth_version'         => 'DEFAULT',
        'vault_s3_signature_version'    => 'default',
        'vault_s3_ssl'                  => 'True',
        'vault_s3_ssl_verify'           => 'True',
        'vault_s3_region_name'          => 'us-east-1',
        'vault_segment_size'            => 33554432,
        'vault_cache_size'              => 16,
        'queue_depth'                   => 100,
        'worker_pool_size'              => 10,
        'vault_retry_count'             => 2,
        'vault_enable_threadpool'       => 'True',
        'vault_threaded_filesystem'     => 'True',
        'max_uploads_pending'           => 20,
        'vault_logging_level'           => 'error',
        'log_file'                      => '/var/log/triliovault/triliovault-object-store.log',
        'log_config_append'             => '/etc/triliovault-object-store/object_store_logging.conf',
        'trace_function_calls'          => 'False',
        'bucket_object_lock'            => 'False',
        'use_manifest_suffix'           => 'False',
        'azure_immutability_enabled'    => 'False',
        'metadata_cache_max_items'      => 32,
        'vault_cache_username'          => 'nova',
      }
      $s3vaultfuse_global_real = merge($s3vaultfuse_defaults, $s3vaultfuse_global)

      file { '/etc/triliovault-dms/':
          ensure => 'directory',
          owner  => '42436',
          group  => '42436',
          mode   => '0755',
      }->
      file { '/etc/triliovault-dms/server.conf':
          ensure  => present,
          content => template('trilio/triliovault_dms_server_conf.erb'),
          owner   => '42436',
          group   => '42436',
          mode    => '0640',
      }->
      file { '/etc/triliovault-dms/s3vaultfuse-global.conf':
          ensure  => present,
          content => template('trilio/s3vaultfuse_global_conf.erb'),
          owner   => '42436',
          group   => '42436',
          mode    => '0644',
      }

      # s3vaultfuse-global.conf points log_config_append here, so the
      # directory must exist even though the object-store service is gone.
      file { '/etc/triliovault-object-store/':
          ensure => 'directory',
          owner  => '42436',
          group  => '42436',
      }->
      file { '/etc/triliovault-object-store/object_store_logging.conf':
          ensure  => present,
          content => template('trilio/object_store_logging_conf.erb'),
          owner   => '42436',
          group   => '42436',
          mode    => '0644',
      }

      file { '/etc/fuse.conf':
          ensure  => present,
          content => template('trilio/fuse.conf.erb'),
          mode    => '0644',
      }
}
