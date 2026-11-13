class trilio::dms (
  $oslomsg_rpc_hosts               = any2array(hiera('oslo_messaging_rpc_node_names', undef)),
  $oslomsg_rpc_password            = hiera('oslo_messaging_rpc_password'),
  $oslomsg_rpc_port                = hiera('oslo_messaging_rpc_port', '5672'),
  $oslomsg_rpc_username            = hiera('oslo_messaging_rpc_user_name', 'guest'),
  $oslomsg_rpc_use_ssl             = hiera('oslo_messaging_rpc_use_ssl', '0'),
  # Must equal nova's OS-EXT-SRV-ATTR:host on computes; DMAPI addresses
  # mount requests to dms.<that host>. The WLM/DMAPI client uses the same lookup.
  $node_id                         = hiera('nova::host', hiera('fqdn_canonical')),
  $auth_url                        = undef,
  $rabbitmq_queue_type             = 'classic',
  $rabbitmq_queue_durable          = false,
  $barbican_ssl_verify             = true,
  $barbican_ca_bundle              = '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem',
  $worker_threads                  = 10,
  $log_level                       = 'INFO',
  $s3vaultfuse_global              = {},
  $step                            = lookup('step'),
) {
    tag 'dmsconfig'

      class {'trilio::dms::config':}
}
